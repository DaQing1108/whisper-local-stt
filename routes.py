"""routes.py — Flask 路由定義。"""
from __future__ import annotations

import json
import logging
import os
import threading
import time as _time
import traceback
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue

from flask import Blueprint, Response, jsonify, make_response, request, stream_with_context

import integrations
import sparkle_updater
import sse as _sse
from constants import ENV_PATH as _ENV_PATH
from transcribe_common import DOMAIN_LABELS, is_hallucination as _is_hallucination
from version import __version__
from whisper_core import TranscriptionError, is_model_cached, run_whisper, warmup_model_async, _warmup_state, _warmup_lock

bp = Blueprint("main", __name__)

# HTML_PAGE 由 app.py 在建立 Blueprint 後注入
HTML_PAGE: str = ""

# 最後一次轉錄結果 — 記憶體 + 磁碟雙重持久化
_LAST_RESULT_FILE = Path(".last_result.json")
_last_transcript: dict | None = None


def _load_last_transcript() -> None:
    global _last_transcript
    if _LAST_RESULT_FILE.exists():
        try:
            _last_transcript = json.loads(_LAST_RESULT_FILE.read_text(encoding="utf-8"))
        except Exception as e:
            logging.warning("[cache] .last_result.json 損毀，已刪除：%s", e)
            _LAST_RESULT_FILE.unlink(missing_ok=True)


def _save_last_transcript(data: dict) -> None:
    global _last_transcript
    _last_transcript = data
    try:
        _LAST_RESULT_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    except Exception as e:
        logging.warning("[LastResult] 磁碟寫入失敗：%s", e)


_load_last_transcript()

# 副檔名對照表
_EXT_MAP = {
    "ogg": ".ogg", "wav": ".wav", "mp3": ".mp3",
    "mp4": ".mp4", "m4a": ".m4a", "flac": ".flac",
    "webm": ".webm", "mpeg": ".mp3",
}


@bp.route("/api/version")
def api_version():
    return jsonify({"version": __version__})


@bp.route("/api/updates/status")
def updates_status():
    return jsonify(sparkle_updater.status())


@bp.route("/api/updates/check", methods=["POST"])
def updates_check():
    result = sparkle_updater.check_for_updates()
    return jsonify(result), 200 if result.get("ok") else 503


# ── P0-2: 模型下載狀態 ────────────────────────────────────────

@bp.route("/api/model-status")
def model_status():
    model_name = request.args.get("model", "large")
    cached = is_model_cached(model_name)
    with _warmup_lock:
        state = _warmup_state.get(model_name, "cached" if cached else "unknown")
    return jsonify(cached=cached, state=state, model=model_name)


@bp.route("/api/warmup-model", methods=["POST"])
def warmup_model_route():
    model_name = (request.json or {}).get("model", "large")
    warmup_model_async(model_name)
    return jsonify(status="started", model=model_name)


@bp.route("/")
def index():
    r = make_response(HTML_PAGE)
    r.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    r.headers["Pragma"] = "no-cache"
    r.headers["Expires"] = "0"
    return r


@bp.route("/preferences")
def preferences():
    from flask import render_template
    return render_template("preferences.html")


@bp.route("/api/validate-obsidian-path", methods=["POST"])
def validate_obsidian_path():
    data = request.json or {}
    raw_path = data.get("path", "").strip()
    if not raw_path:
        return jsonify(ok=False, error="路徑不能為空"), 400
    expanded = os.path.expanduser(raw_path)
    if os.path.isdir(expanded):
        return jsonify(ok=True, expanded=expanded)
    return jsonify(ok=False, error=f"找不到目錄：{expanded}"), 200


@bp.route("/events")
def events():
    q: Queue = Queue(maxsize=50)
    with _sse._sse_lock:
        _sse._sse_queues.append(q)

    def generator():
        yield "data: connected\n\n"
        try:
            while True:
                try:
                    msg = q.get(timeout=25)
                    yield msg
                except Empty:
                    yield ": ping\n\n"
        except (BrokenPipeError, GeneratorExit, ConnectionResetError):
            pass
        finally:
            with _sse._sse_lock:
                if q in _sse._sse_queues:
                    _sse._sse_queues.remove(q)

    return Response(
        stream_with_context(generator()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@bp.route("/transcribe", methods=["POST"])
def transcribe():
    """接收音訊後立刻回傳 202，在背景執行緒跑 Whisper，結果透過 SSE 推送。"""
    audio = request.files.get("audio")
    if not audio:
        return jsonify(error="沒有收到音訊"), 400

    model_name    = request.form.get("model", "large")
    language      = request.form.get("language", "auto")
    domain        = request.form.get("domain", "general")
    extra_terms   = request.form.get("extra_terms", "")
    save_obsidian = request.form.get("obsidian", "false").lower() == "true"

    ext = ".webm"
    if audio.filename:
        fname_ext = Path(audio.filename).suffix.lower()
        if fname_ext:
            ext = fname_ext
    elif audio.content_type:
        for key, val in _EXT_MAP.items():
            if key in audio.content_type:
                ext = val
                break

    audio_bytes = audio.read()

    def _worker():
        domain_label = DOMAIN_LABELS.get(domain, domain)

        if not _sse._transcribe_sem.acquire(blocking=False):
            _sse.broadcast("status", {"msg": "⏳ 系統正在處理另一份音檔，請稍候排隊…"})
            _sse._transcribe_sem.acquire()

        try:
            _sse.broadcast("status", {"msg": f"⏳ 轉錄中（模型：{model_name}，領域：{domain_label}）…"})

            def on_progress(done: int, total: int, seg_text: str):
                if total <= 1:
                    return
                pct = int(done / total * 100)
                start_min = (done - 1) * 30
                end_min   = min(done * 30, total * 30)
                _sse.broadcast("status", {
                    "msg": f"⏳ 轉錄進度：{pct}%（第 {done}/{total} 段，{start_min}–{end_min} 分鐘）"
                })
                if seg_text:
                    _sse.broadcast("chunk", {"text": seg_text, "chunk": done, "total": total})

            try:
                text, lang, info = run_whisper(
                    audio_bytes, ext, model_name, language,
                    progress_cb=on_progress,
                    domain=domain,
                    extra_terms=extra_terms,
                )
            except BrokenPipeError:
                _sse.broadcast("status", {"msg": "⚠️ 轉錄中斷，請重試"})
                _sse.broadcast("done",   {"ok": False, "error_code": "BROKEN_PIPE", "error": "broken_pipe"})
                return
            except TranscriptionError as e:
                logging.error("[Whisper] 轉錄錯誤 %s: %s", e.code, e)
                _sse.broadcast("status", {"msg": f"❌ 轉錄失敗"})
                _sse.broadcast("done",   {"ok": False, "error_code": e.code, "error": str(e)})
                return
            except Exception as e:
                logging.error("[Whisper] 轉錄失敗\n%s", traceback.format_exc())
                _sse.broadcast("status", {"msg": f"❌ 轉錄失敗"})
                _sse.broadcast("done",   {"ok": False, "error_code": "TRANSCRIPTION_FAILED", "error": str(e)})
                return

            if not text:
                _sse.broadcast("status", {"msg": "⚠️ 沒有偵測到語音內容"})
                _sse.broadcast("done",   {"ok": False, "error_code": "EMPTY_TRANSCRIPT", "error": "empty"})
                return

            _save_last_transcript({
                "text":     text,
                "language": lang,
                "time":     datetime.now().strftime("%H:%M:%S"),
                "segments": info.get("segments", []),
            })
            _sse.broadcast("status",     {"msg": f"✅ 轉錄完成（偵測語言：{lang}）"})
            _sse.broadcast("transcript", _last_transcript)

            obsidian_file = ""
            if save_obsidian and os.environ.get("OBSIDIAN_MEETING_PATH"):
                _sse.broadcast("status", {"msg": "💾 存入 Obsidian Vault…"})
                obsidian_file = integrations.save_to_obsidian(text, lang, info)
                if obsidian_file:
                    _sse.broadcast("status", {"msg": f"✅ 已存入 Obsidian：{Path(obsidian_file).name}"})
                else:
                    _sse.broadcast("status", {"msg": "⚠️ Obsidian 存檔失敗"})

            _sse.broadcast("done", {"ok": True, "text": text, "language": lang,
                                    "obsidian_file": obsidian_file})
        finally:
            _sse._transcribe_sem.release()

    threading.Thread(target=_worker, daemon=True).start()
    return jsonify(status="processing"), 202


# ── Chunked recording session state ──────────────────────────────
_chunk_sessions: dict[str, dict] = {}
_chunk_sessions_lock = threading.Lock()
_SESSION_TTL = 300  # seconds — abandon sessions from disconnected clients


def _chunk_prev_context(session_id: str, chunk_index: int) -> str:
    """Lock-safe lookup of the previous chunk tail for use as Whisper initial_prompt."""
    with _chunk_sessions_lock:
        sess = _chunk_sessions.get(session_id)
        prev = sess["chunks"].get(chunk_index - 1, "") if sess else ""
    return prev[-100:].strip() if prev else ""


def _chunk_session_update(session_id: str, chunk_index: int, text: str, lang: str) -> dict | None:
    """Write completed chunk into session. Returns a snapshot dict or None if session is gone."""
    with _chunk_sessions_lock:
        sess = _chunk_sessions.get(session_id)
        if not sess:
            return None
        sess["chunks"][chunk_index] = text
        sess["langs"][chunk_index]  = lang
        sess["done_count"] += 1
        sess["last_active"] = _time.time()
        return {
            "total":     sess["total"],
            "done":      sess["done_count"],
            "live_mode": sess.get("live_mode", False),
            "all_done":  sess["total"] is not None and sess["done_count"] >= sess["total"],
        }


def _session_ttl_cleaner() -> None:
    """Background thread: evict sessions idle longer than _SESSION_TTL seconds."""
    while True:
        _time.sleep(60)
        cutoff = _time.time() - _SESSION_TTL
        with _chunk_sessions_lock:
            stale = [sid for sid, s in _chunk_sessions.items()
                     if s.get("last_active", 0) < cutoff]
            for sid in stale:
                del _chunk_sessions[sid]
                logging.warning("[Session] TTL evicted stale session %s", sid[:8])


threading.Thread(target=_session_ttl_cleaner, daemon=True).start()


@bp.route("/api/upload-chunk", methods=["POST"])
def upload_chunk():
    """接收錄音分段，背景轉錄，每段完成後 SSE 推送 chunk_done。
    最後一段完成且全段完成後，合併全文推送 transcript + done。"""
    audio = request.files.get("audio")
    if not audio:
        return jsonify(error="沒有收到音訊"), 400

    session_id  = request.form.get("session_id", "unknown")
    chunk_index = int(request.form.get("chunk_index", 0))
    is_last     = request.form.get("is_last", "false").lower() == "true"
    model_name  = request.form.get("model", "large")
    language    = request.form.get("language", "auto")
    domain      = request.form.get("domain", "general")
    extra_terms = request.form.get("extra_terms", "")
    save_obsidian = request.form.get("obsidian", "false").lower() == "true"
    live_mode = request.form.get("mode", "standard") == "live"

    ext = Path(audio.filename).suffix.lower() if audio.filename else ".webm"
    audio_bytes = audio.read()

    with _chunk_sessions_lock:
        if session_id not in _chunk_sessions:
            _chunk_sessions[session_id] = {
                "chunks":           {},
                "langs":            {},
                "total":            None,
                "done_count":       0,
                "last_active":      _time.time(),
                "model":            model_name,
                "language":         language,
                "domain":           domain,
                "extra_terms":      extra_terms,
                "save_obsidian":    save_obsidian,
                "live_mode":        live_mode,
                "segments_by_chunk": {},
                "chunk_durations":   {},
            }
        sess = _chunk_sessions[session_id]
        if is_last:
            sess["total"] = chunk_index + 1

    def _worker():
        domain_label = DOMAIN_LABELS.get(domain, domain)

        if not _sse._transcribe_sem.acquire(blocking=False):
            _sse._transcribe_sem.acquire()

        try:
            _sse.broadcast("status", {
                "msg": f"⏳ 轉錄第 {chunk_index + 1} 段（模型：{model_name}，領域：{domain_label}）…"
            })

            context = _chunk_prev_context(session_id, chunk_index)

            try:
                from whisper_core import transcribe_audio as _transcribe_audio
                logging.debug("[Chunk %d] 開始轉錄 bytes=%d ext=%s", chunk_index, len(audio_bytes), ext)
                text, lang, info = _transcribe_audio(
                    audio_bytes, ext, model_name, language,
                    domain=domain, extra_terms=extra_terms,
                    initial_prompt_override=context or None,
                    skip_llm=True,  # LLM 在 _finish_session 全文合併後統一處理
                )
                logging.debug("[Chunk %d] 完成 text_len=%d lang=%s", chunk_index, len(text), lang)
            except TranscriptionError as e:
                logging.error("[Chunk %d] 轉錄錯誤 %s: %s", chunk_index, e.code, e)
                _sse.broadcast("status", {"msg": f"❌ 第 {chunk_index + 1} 段轉錄失敗"})
                _sse.broadcast("done",   {"ok": False, "error_code": e.code, "error": str(e)})
                with _chunk_sessions_lock:
                    _chunk_sessions.pop(session_id, None)
                return
            except Exception as e:
                logging.error("[Chunk %d] 轉錄失敗\n%s", chunk_index, traceback.format_exc())
                _sse.broadcast("status", {"msg": f"❌ 第 {chunk_index + 1} 段轉錄失敗"})
                _sse.broadcast("done",   {"ok": False, "error": str(e)})
                with _chunk_sessions_lock:
                    _chunk_sessions.pop(session_id, None)
                return

            if _is_hallucination(text):
                text = ""
                info = {}  # discard hallucinated segments too

            with _chunk_sessions_lock:
                sess = _chunk_sessions.get(session_id)
                if sess is not None:
                    sess["segments_by_chunk"][chunk_index] = info.get("segments", [])
                    sess["chunk_durations"][chunk_index] = info.get("duration_seconds", 0)

            snap = _chunk_session_update(session_id, chunk_index, text, lang)
            if snap is None:
                return  # session already cleaned up

            _sse.broadcast("chunk_done", {
                "session_id":  session_id,
                "chunk_index": chunk_index,
                "chunk_total": snap["total"] or "?",
                "text":        text,
                "language":    lang,
                "live_mode":   snap["live_mode"],
            })

            if snap["all_done"]:
                _finish_session(session_id)

        finally:
            _sse._transcribe_sem.release()

    threading.Thread(target=_worker, daemon=True).start()
    return jsonify(status="processing", session_id=session_id, chunk_index=chunk_index), 202


@bp.route("/api/finish-session", methods=["POST"])
def finish_session_endpoint():
    """當最後一段音訊為空（已在計時器 flush 時送出），強制結束 session。"""
    session_id = request.form.get("session_id", "")
    if not session_id:
        return jsonify(error="missing session_id"), 400

    with _chunk_sessions_lock:
        sess = _chunk_sessions.get(session_id)
        if sess is None:
            return jsonify(status="not_found"), 200
        # 若 total 尚未設定，以目前已完成的 chunk 數作為 total
        done = sess.get("done_count", 0)
        if sess["total"] is None:
            sess["total"] = done
        all_done = done >= sess["total"] and sess["total"] > 0

    if all_done:
        threading.Thread(target=_finish_session, args=(session_id,), daemon=True).start()
    else:
        # 可能還有 worker 在跑，讓最後的 worker 觸發 _finish_session
        # 但要確保 total 已設定，這樣 all_done 條件能成立
        pass

    return jsonify(status="ok"), 200


def _finish_session(session_id: str) -> None:
    """所有段落轉錄完畢：合併全文 → LLM 標點 → Obsidian → SSE transcript + done。"""
    with _chunk_sessions_lock:
        sess = _chunk_sessions.pop(session_id, None)
    if not sess:
        return

    total = sess["total"] or len(sess["chunks"])
    texts = [sess["chunks"].get(i, "") for i in range(total)]
    langs = [sess["langs"].get(i, "?") for i in range(total)]
    lang  = next((l for l in langs if l not in ("?", "")), "?")

    full_text = "\n".join(t for t in texts if t).strip()
    logging.info("[Session %s] total=%d chunks=%d full_text_len=%d", session_id[:8], total, len(texts), len(full_text))
    if not full_text:
        _sse.broadcast("status", {"msg": "⚠️ 沒有偵測到語音內容"})
        _sse.broadcast("done",   {"ok": False, "error_code": "EMPTY_TRANSCRIPT", "error": "empty"})
        return

    from llm_post import has_llm_key, llm_punctuate
    if has_llm_key():
        _sse.broadcast("status", {"msg": "⏳ 全文合併完畢，正在啟動 LLM 進行語意糾錯與標點處理…"})
    full_text = llm_punctuate(full_text, sess.get("extra_terms", ""))

    segments_by_chunk = sess.get("segments_by_chunk", {})
    chunk_durations   = sess.get("chunk_durations", {})
    all_segments: list[dict] = []
    cumulative = 0.0
    for i in sorted(segments_by_chunk):
        offset = cumulative
        for seg in segments_by_chunk[i]:
            all_segments.append({
                "text":  seg["text"],
                "start": seg["start"] + offset,
                "end":   seg["end"] + offset,
            })
        cumulative += chunk_durations.get(i, 0)

    info = {"model": sess["model"], "domain": sess["domain"],
            "extra_terms": sess["extra_terms"], "duration_seconds": cumulative,
            "segments": all_segments}

    _save_last_transcript({
        "text":     full_text,
        "language": lang,
        "time":     datetime.now().strftime("%H:%M:%S"),
        "segments": [],
    })
    _sse.broadcast("status",     {"msg": f"✅ 全部轉錄完成（偵測語言：{lang}）"})
    _sse.broadcast("transcript", _last_transcript)

    obsidian_file = ""
    if sess.get("save_obsidian") and os.environ.get("OBSIDIAN_MEETING_PATH"):
        _sse.broadcast("status", {"msg": "💾 存入 Obsidian Vault…"})
        obsidian_file = integrations.save_to_obsidian(full_text, lang, info)
        if obsidian_file:
            _sse.broadcast("status", {"msg": f"✅ 已存入 Obsidian：{Path(obsidian_file).name}"})
        else:
            _sse.broadcast("status", {"msg": "⚠️ Obsidian 存檔失敗"})

    _sse.broadcast("done", {"ok": True, "text": full_text, "language": lang,
                            "obsidian_file": obsidian_file})


@bp.route("/upload", methods=["POST"])
def upload():
    data    = request.json or {}
    text    = data.get("text", "").strip()
    lang    = data.get("language", "?")
    page_id = data.get("page_id") or os.getenv("NOTION_PAGE_ID", "")
    token   = os.getenv("NOTION_TOKEN", "")

    if not text:
        return jsonify(error="沒有文字"), 400
    if not token:
        return jsonify(error="缺少 NOTION_TOKEN，請先在 .env 設定"), 400
    if not page_id:
        return jsonify(error="缺少 Notion 頁面 ID"), 400

    try:
        from notion_client import Client
        notion  = Client(auth=token)
        blocks  = integrations.build_notion_blocks(text, lang)
        for i in range(0, len(blocks), 100):
            notion.blocks.children.append(block_id=page_id, children=blocks[i:i+100])
        return jsonify(ok=True, blocks=len(blocks))
    except Exception as e:
        return jsonify(error=str(e)), 500


@bp.route("/config", methods=["GET"])
def get_config():
    token   = os.getenv("NOTION_TOKEN", "")
    page_id = os.getenv("NOTION_PAGE_ID", "")
    ready   = bool(token and page_id)
    label   = page_id[:8] + "…" if len(page_id) > 8 else page_id
    if ready:
        try:
            from notion_client import Client
            notion = Client(auth=token)
            page   = notion.pages.retrieve(page_id=page_id)
            props  = page.get("properties", {})
            title_prop = None
            for key in ("title", "Name", "名稱", "標題"):
                if key in props:
                    title_prop = props[key]
                    break
            if title_prop is None:
                for v in props.values():
                    if isinstance(v, dict) and v.get("type") == "title":
                        title_prop = v
                        break
            if title_prop:
                tl = title_prop.get("title", [])
                if tl:
                    label = tl[0]["plain_text"]
        except Exception as e:
            logging.warning("[Config] Notion 標題抓取失敗：%s", e)
    page_id_preview = (page_id[:8] + "…") if page_id else ""
    llm_prompt = os.getenv("LLM_CUSTOM_PROMPT", "")
    llm_prompt_preview = llm_prompt[:50] + "…" if len(llm_prompt) > 50 else llm_prompt
    return jsonify(
        ready=ready,
        page_label=label,
        page_id_preview=page_id_preview,
        has_anthropic_key=bool(os.getenv("ANTHROPIC_API_KEY")),
        has_openai_key=bool(os.getenv("OPENAI_API_KEY")),
        obsidian_path=os.getenv("OBSIDIAN_MEETING_PATH", ""),
        llm_prompt_preview=llm_prompt_preview,
        llm_prompt=llm_prompt,
    )


@bp.route("/api/config/health", methods=["GET"])
def config_health():
    """啟動健檢：回傳各功能的設定狀態與 TCC 權限，讓前端在啟動時提示使用者補設定。"""
    missing = []
    if not os.getenv("ANTHROPIC_API_KEY"):
        missing.append({"key": "ANTHROPIC_API_KEY", "feature": "會議記錄自動整理"})
    if not os.getenv("OBSIDIAN_MEETING_PATH"):
        missing.append({"key": "OBSIDIAN_MEETING_PATH", "feature": "Obsidian 存檔"})
    if not os.getenv("NOTION_TOKEN") or not os.getenv("NOTION_PAGE_ID"):
        missing.append({"key": "NOTION_TOKEN / NOTION_PAGE_ID", "feature": "Notion 存檔"})

    permissions = _check_tcc_permissions()
    return jsonify(ok=len(missing) == 0, missing=missing, permissions=permissions)


def _check_tcc_permissions() -> dict:
    """偵測 macOS TCC 權限狀態（螢幕錄製、麥克風）。
    只在 .app 環境下有意義；Terminal 模式永遠回傳 unknown。
    """
    result = {"screen_recording": "unknown", "microphone": "unknown"}
    try:
        # 透過 system_audio_sc.py 的 TCC guard 偵測螢幕錄製狀態
        import system_audio_sc as _sc
        status = _sc.check_tcc_status()  # 回傳 "granted" / "denied" / "unknown"
        result["screen_recording"] = status
    except Exception:
        pass
    try:
        # 麥克風：透過 AVCaptureDevice 的授權狀態（需 pyobjc）
        import objc  # noqa: F401
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio  # type: ignore
        auth = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)
        # 0=notDetermined, 1=restricted, 2=denied, 3=authorized
        result["microphone"] = "granted" if auth == 3 else ("denied" if auth == 2 else "unknown")
    except Exception:
        pass
    return result


@bp.route("/config", methods=["POST"])
def save_config():
    data    = request.json or {}
    token   = data.get("token", "").strip()
    page_id = data.get("page_id", "").strip()
    anthropic_key  = data.get("anthropic_key", "").strip()
    openai_key     = data.get("openai_key", "").strip()
    obsidian_path  = data.get("obsidian_path", "").strip()
    llm_prompt     = data.get("llm_prompt", None)  # None = 未傳入（不更新）

    label = ""
    if token and page_id:
        try:
            from notion_client import Client
            notion = Client(auth=token)
            page   = notion.pages.retrieve(page_id=page_id)
            props  = page.get("properties", {})
            tp     = props.get("title", props.get("Name", {}))
            tl     = tp.get("title", [])
            label  = tl[0]["plain_text"] if tl else page_id
        except Exception as e:
            return jsonify(error=f"Notion 連線失敗：{e}"), 400
    elif token or page_id:
        # 只填一個的情況
        return jsonify(error="請同時填寫 Token 與頁面 ID"), 400

    def _sanitize(val: str) -> str:
        return val[:512].replace("\n", "").replace("\r", "").replace("\0", "")

    # 局部更新 .env（統一寫到 Application Support，保留其他已有的 key）
    env_path = _ENV_PATH
    env_path.parent.mkdir(parents=True, exist_ok=True)
    existing: dict[str, str] = {}
    if env_path.exists():
        for raw in env_path.read_text(encoding="utf-8").splitlines():
            raw = raw.strip()
            if raw and not raw.startswith("#") and "=" in raw:
                k, _, v = raw.partition("=")
                existing[k.strip()] = v.strip()

    if token:
        existing["NOTION_TOKEN"]   = _sanitize(token)
        os.environ["NOTION_TOKEN"] = _sanitize(token)
    if page_id:
        existing["NOTION_PAGE_ID"]   = _sanitize(page_id)
        os.environ["NOTION_PAGE_ID"] = _sanitize(page_id)
    if anthropic_key:
        existing["ANTHROPIC_API_KEY"]   = _sanitize(anthropic_key)
        os.environ["ANTHROPIC_API_KEY"] = _sanitize(anthropic_key)
    if openai_key:
        existing["OPENAI_API_KEY"]   = _sanitize(openai_key)
        os.environ["OPENAI_API_KEY"] = _sanitize(openai_key)
    if obsidian_path:
        expanded = os.path.expanduser(_sanitize(obsidian_path))
        existing["OBSIDIAN_MEETING_PATH"]   = expanded
        os.environ["OBSIDIAN_MEETING_PATH"] = expanded
    if llm_prompt is not None:
        if not isinstance(llm_prompt, str):
            return jsonify(error="llm_prompt 必須為字串"), 400
        cleaned = llm_prompt.strip()[:2000]
        if cleaned:
            existing["LLM_CUSTOM_PROMPT"]   = cleaned
            os.environ["LLM_CUSTOM_PROMPT"] = cleaned
        else:
            existing.pop("LLM_CUSTOM_PROMPT", None)
            os.environ.pop("LLM_CUSTOM_PROMPT", None)

    env_path.write_text(
        "\n".join(f"{k}={v}" for k, v in existing.items()) + "\n",
        encoding="utf-8",
    )

    return jsonify(
        ok=True,
        page_label=label or page_id,
        has_anthropic_key=bool(existing.get("ANTHROPIC_API_KEY")),
        has_openai_key=bool(existing.get("OPENAI_API_KEY")),
    )


@bp.route("/api/system-audio/start", methods=["POST"])
def system_audio_start():
    """啟動 ScreenCaptureKit 系統音訊即時轉錄（in-process pyobjc，TCC 屬於主 app）。"""
    import system_audio as _sa
    import system_audio_sc as _sc

    if (_sa.get_capture() and _sa.get_capture().is_running) or \
       (_sc.get_sc_capture() and _sc.get_sc_capture().is_running):
        return jsonify(error="系統音訊擷取已在運行中"), 409

    data = request.json or {}
    model_name  = data.get("model", "large")
    language    = data.get("language", "auto")
    domain      = data.get("domain", "general")
    extra_terms = data.get("extra_terms", "")
    with_mic    = data.get("with_mic", False)
    session_id  = data.get("session_id", f"sysaudio_{int(__import__('time').time())}")

    # Register session so _finish_session works
    _workers_done = threading.Event()
    with _chunk_sessions_lock:
        _chunk_sessions[session_id] = {
            "chunks":            {},
            "langs":             {},
            "total":             None,
            "done_count":        0,
            "pending_workers":   0,
            "_workers_done":     _workers_done,
            "last_active":       _time.time(),
            "model":             model_name,
            "language":          language,
            "domain":            domain,
            "extra_terms":       extra_terms,
            "save_obsidian":     data.get("save_obsidian", False),
            "live_mode":         True,
            "segments_by_chunk": {},
        }

    def _on_chunk(wav_bytes: bytes, chunk_index: int) -> None:
        with _chunk_sessions_lock:
            sess = _chunk_sessions.get(session_id)
            if sess is not None:
                sess["pending_workers"] += 1

        def _worker():
            domain_label = DOMAIN_LABELS.get(domain, domain)
            if not _sse._transcribe_sem.acquire(blocking=False):
                _sse._transcribe_sem.acquire()
            try:
                _sse.broadcast("status", {"msg": f"⏳ 轉錄系統音訊 第 {chunk_index + 1} 段…"})
                context = _chunk_prev_context(session_id, chunk_index)
                try:
                    from whisper_core import transcribe_audio as _transcribe_audio
                    text, lang, chunk_info = _transcribe_audio(
                        wav_bytes, ".wav", model_name, language,
                        domain=domain, extra_terms=extra_terms,
                        initial_prompt_override=context or None,
                        skip_llm=True,  # LLM 在 stop 後全文合併統一處理
                    )
                except Exception as exc:
                    logging.error("[SysAudio chunk %d] 轉錄失敗: %s", chunk_index, exc)
                    text, lang, chunk_info = "", "?", {}

                if _is_hallucination(text):
                    text = ""
                    chunk_info = {}  # discard hallucinated segments too

                sys_audio_chunk_sec = 15
                offset = chunk_index * sys_audio_chunk_sec
                with _chunk_sessions_lock:
                    sess = _chunk_sessions.get(session_id)
                    if sess is not None:
                        sess["segments_by_chunk"][chunk_index] = [
                            {"text": s["text"], "start": s["start"] + offset, "end": s["end"] + offset}
                            for s in chunk_info.get("segments", [])
                        ]

                snap = _chunk_session_update(session_id, chunk_index, text, lang)
                if snap is None:
                    return  # session already cleaned up

                _sse.broadcast("chunk_done", {
                    "session_id":  session_id,
                    "chunk_index": chunk_index,
                    "chunk_total": "?",
                    "text":        text,
                    "language":    lang,
                    "live_mode":   True,
                })
            finally:
                _sse._transcribe_sem.release()
                with _chunk_sessions_lock:
                    sess = _chunk_sessions.get(session_id)
                    if sess is not None:
                        sess["pending_workers"] -= 1
                        if sess["pending_workers"] <= 0:
                            sess["_workers_done"].set()

        threading.Thread(target=_worker, daemon=True).start()

    def _on_tcc_error(error_code: str) -> None:
        _sse.broadcast("done", {
            "ok": False,
            "error_code": error_code,
            "error": "螢幕錄製權限未授予",
        })
        with _chunk_sessions_lock:
            _chunk_sessions.pop(session_id, None)

    try:
        if with_mic:
            _sa.start_mixed_capture(_on_chunk)
        else:
            _sa.start_capture(_on_chunk, on_error=_on_tcc_error)
    except RuntimeError as e:
        with _chunk_sessions_lock:
            _chunk_sessions.pop(session_id, None)
        return jsonify(error=str(e)), 503

    return jsonify(ok=True, session_id=session_id)


@bp.route("/api/system-audio/stop", methods=["POST"])
def system_audio_stop():
    """停止系統音訊擷取，合併全文推送最終結果。"""
    import system_audio as _sa
    import time as _time

    data = request.json or {}
    session_id = data.get("session_id", "")

    _sa.stop_capture()
    _sa.stop_mixed_capture()

    if session_id:
        # 取出 session 的 workers_done Event（由 _on_chunk worker 在完成時 set）
        with _chunk_sessions_lock:
            sess_ref = _chunk_sessions.get(session_id)
            workers_done_event = sess_ref.get("_workers_done") if sess_ref else None

        def _finalize():
            # 等待所有 in-flight worker 完成（最多 30 秒），用 Event 取代 sleep 輪詢
            if workers_done_event is not None:
                workers_done_event.wait(timeout=30)

            with _chunk_sessions_lock:
                sess = _chunk_sessions.pop(session_id, None)
            if not sess:
                return
            chunks = sess.get("chunks", {})
            full_text = "\n".join(chunks[i] for i in sorted(chunks) if chunks[i]).strip()
            lang = sess.get("language", "zh")
            if full_text:
                ts = datetime.now().strftime("%H:%M:%S")
                _save_last_transcript({"text": full_text, "language": lang, "time": ts, "segments": []})
                _sse.broadcast("transcript", {"text": full_text, "language": lang, "time": ts, "segments": []})
                obsidian_file = ""
                if sess.get("save_obsidian") and os.environ.get("OBSIDIAN_MEETING_PATH"):
                    segments_by_chunk = sess.get("segments_by_chunk", {})
                    sys_segments = [
                        seg
                        for i in sorted(segments_by_chunk)
                        for seg in segments_by_chunk[i]
                    ]
                    info = {
                        "time":     ts,
                        "model":    sess.get("model", "unknown"),
                        "domain":   sess.get("domain", "general"),
                        "segments": sys_segments,
                    }
                    obsidian_file = integrations.save_to_obsidian(full_text, lang, info)
                    if obsidian_file:
                        _sse.broadcast("status", {"msg": f"✅ 已存入 Obsidian：{Path(obsidian_file).name}"})
                _sse.broadcast("done", {"ok": True, "text": full_text, "language": lang, "obsidian_file": obsidian_file})
            else:
                _sse.broadcast("done", {"ok": False, "error_code": "EMPTY_TRANSCRIPT", "error": "empty"})

        threading.Thread(target=_finalize, daemon=True).start()

    return jsonify(ok=True)


@bp.route("/api/health")
def health():
    return jsonify(ok=True, version=__version__)


@bp.route("/api/test/inject-chunk", methods=["POST"])
def test_inject_chunk():
    """測試專用：直接注入 WAV bytes 模擬麥克風／系統音訊 chunk，繞過硬體。
    僅在 Flask debug 模式或 WHISPER_TEST=1 時啟用。
    """
    import os as _os
    from flask import current_app
    if not current_app.debug:
        return jsonify(error="只在 debug 模式下可用"), 403

    session_id = request.form.get("session_id", f"test_{int(_time.time())}")
    chunk_index = int(request.form.get("chunk_index", 0))
    wav_file = request.files.get("wav")
    if not wav_file:
        return jsonify(error="缺少 wav 檔案"), 400

    wav_bytes = wav_file.read()
    with _chunk_sessions_lock:
        if session_id not in _chunk_sessions:
            _chunk_sessions[session_id] = {
                "chunks": {}, "langs": {}, "total": None,
                "done_count": 0, "last_active": _time.time(),
                "model": request.form.get("model", "large"),
                "language": request.form.get("language", "zh"),
                "domain": request.form.get("domain", "general"),
                "extra_terms": request.form.get("extra_terms", ""),
                "save_obsidian": request.form.get("save_obsidian", "false") == "true",
                "live_mode": False,
            }

    def _worker():
        try:
            from whisper_core import transcribe_audio as _ta
            sess = _chunk_sessions.get(session_id, {})
            text, lang, _ = _ta(
                wav_bytes, ".wav",
                sess.get("model", "large"),
                sess.get("language", "zh"),
                domain=sess.get("domain", "general"),
                extra_terms=sess.get("extra_terms", ""),
                skip_llm=True,
            )
            if _is_hallucination(text):
                text = ""
            _chunk_session_update(session_id, chunk_index, text, lang)
            _sse.broadcast("chunk_done", {
                "session_id": session_id,
                "chunk_index": chunk_index,
                "text": text,
                "language": lang,
            })
        except Exception as exc:
            logging.error("[test_inject_chunk] 失敗: %s", exc)

    threading.Thread(target=_worker, daemon=True).start()
    return jsonify(ok=True, session_id=session_id, chunk_index=chunk_index)


@bp.route("/api/last_transcript", methods=["GET"])
def last_transcript():
    if _last_transcript:
        return jsonify(ok=True, **_last_transcript)
    return jsonify(ok=False)


@bp.route("/api/export", methods=["GET"])
def export_transcript():
    """匯出最後一次轉錄結果為 .srt / .md / .txt。"""
    fmt = request.args.get("format", "txt").lower()
    if fmt not in ("srt", "md", "txt"):
        return jsonify(error="format 必須為 srt、md 或 txt"), 400
    if not _last_transcript:
        return jsonify(error="尚無轉錄結果"), 404

    text: str = _last_transcript.get("text", "")
    segments: list = _last_transcript.get("segments", [])

    if fmt == "srt":
        content = _build_srt(segments, text)
        mime = "text/plain"
        filename = "transcript.srt"
    elif fmt == "md":
        content = _build_md(segments, text)
        mime = "text/markdown"
        filename = "transcript.md"
    else:
        content = text
        mime = "text/plain"
        filename = "transcript.txt"

    from flask import Response
    resp = Response(content, mimetype=mime)
    resp.headers["Content-Disposition"] = f'attachment; filename="{filename}"'
    return resp


def _build_srt(segments: list, fallback_text: str) -> str:
    """把 Whisper segments 轉換成 SRT 格式。若無 segments，整段文字當作第一條。"""
    def _fmt_time(sec: float) -> str:
        h = int(sec // 3600)
        m = int((sec % 3600) // 60)
        s = int(sec % 60)
        ms = int((sec - int(sec)) * 1000)
        return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

    if not segments:
        return f"1\n00:00:00,000 --> 00:00:01,000\n{fallback_text}\n"

    lines = []
    for i, seg in enumerate(segments, 1):
        try:
            start_sec = float(seg.get("start", 0))
            end_sec   = float(seg.get("end", start_sec + 1))
        except (TypeError, ValueError):
            start_sec, end_sec = 0.0, 1.0
        start = _fmt_time(start_sec)
        end   = _fmt_time(end_sec)
        txt   = seg.get("text", "").strip()
        lines.append(f"{i}\n{start} --> {end}\n{txt}\n")
    return "\n".join(lines)


def _build_md(segments: list, fallback_text: str) -> str:
    """把 segments 轉換成帶時間戳的 Markdown。"""
    if not segments:
        return fallback_text

    lines = []
    for seg in segments:
        start = seg.get("start", 0)
        m = int(start // 60)
        s = int(start % 60)
        txt = seg.get("text", "").strip()
        lines.append(f"**[{m:02d}:{s:02d}]** {txt}")
    return "\n\n".join(lines)


@bp.route("/api/save_to_obsidian", methods=["POST"])
def save_to_obsidian_route():
    from integrations import save_to_obsidian as _save
    data = request.json or {}
    text = data.get("text", "").strip()
    lang = data.get("lang", "zh")
    meta = data.get("meta", {})

    if not text:
        return jsonify(error="沒有內容可存"), 400

    fpath = _save(text, lang, meta)
    if not fpath:
        return jsonify(error="OBSIDIAN_MEETING_PATH 未設定或寫入失敗"), 500

    import os
    return jsonify(ok=True, filename=os.path.basename(fpath), path=fpath)
