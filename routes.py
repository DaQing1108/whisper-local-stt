"""routes.py — Flask 路由定義。"""
from __future__ import annotations

import logging
import os
import threading
import traceback
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue

from flask import Blueprint, Response, jsonify, make_response, request, stream_with_context

import integrations
import sse as _sse
from whisper_core import run_whisper

bp = Blueprint("main", __name__)

# HTML_PAGE 由 app.py 在建立 Blueprint 後注入
HTML_PAGE: str = ""

# 副檔名對照表
_EXT_MAP = {
    "ogg": ".ogg", "wav": ".wav", "mp3": ".mp3",
    "mp4": ".mp4", "m4a": ".m4a", "flac": ".flac",
    "webm": ".webm", "mpeg": ".mp3",
}


@bp.route("/")
def index():
    r = make_response(HTML_PAGE)
    r.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    r.headers["Pragma"] = "no-cache"
    r.headers["Expires"] = "0"
    return r


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

    model_name    = request.form.get("model", "small")
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
        domain_label = {"media": "媒體", "medical": "醫療", "legal": "法律",
                        "tech": "科技", "general": "通用"}.get(domain, domain)

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
                _sse.broadcast("status", {"msg": "⚠️ 轉錄中斷（Broken pipe），請重試"})
                _sse.broadcast("done",   {"ok": False, "error": "broken_pipe"})
                return
            except Exception as e:
                logging.error("[Whisper] 轉錄失敗\n%s", traceback.format_exc())
                _sse.broadcast("status", {"msg": f"❌ 轉錄失敗：{e}"})
                _sse.broadcast("done",   {"ok": False, "error": str(e)})
                return

            if not text:
                _sse.broadcast("status", {"msg": "⚠️ 沒有偵測到語音內容"})
                _sse.broadcast("done",   {"ok": False, "error": "empty"})
                return

            _sse.broadcast("status",     {"msg": f"✅ 轉錄完成（偵測語言：{lang}）"})
            _sse.broadcast("transcript", {
                "text": text, "language": lang,
                "time": datetime.now().strftime("%H:%M:%S"),
            })

            obsidian_file = ""
            if save_obsidian and integrations._OBSIDIAN_PATH:
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
        notion = Client(auth=token)
        now    = datetime.now().strftime("%Y-%m-%d %H:%M")
        blocks = [
            {"object": "block", "type": "divider", "divider": {}},
            {"object": "block", "type": "heading_2",
             "heading_2": {"rich_text": [{"type": "text",
                                           "text": {"content": f"🎙️ 即時轉錄｜{now}"}}]}},
            {"object": "block", "type": "callout",
             "callout": {
                 "rich_text": [{"type": "text",
                                 "text": {"content": f"偵測語言：{lang}  ｜  {now}"}}],
                 "icon": {"type": "emoji", "emoji": "🎤"},
                 "color": "purple_background",
             }},
        ]
        for line in text.split("\n"):
            line = line.strip()
            if line:
                blocks.append({"object": "block", "type": "paragraph",
                                "paragraph": {"rich_text": [{"type": "text",
                                                               "text": {"content": line}}]}})
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
    label   = ""
    if ready:
        try:
            from notion_client import Client
            notion = Client(auth=token)
            page   = notion.pages.retrieve(page_id=page_id)
            props  = page.get("properties", {})
            tp     = props.get("title", props.get("Name", {}))
            tl     = tp.get("title", [])
            label  = tl[0]["plain_text"] if tl else page_id
        except Exception:
            ready = False
    return jsonify(ready=ready, page_label=label, page_id=page_id)


@bp.route("/config", methods=["POST"])
def save_config():
    data    = request.json or {}
    token   = data.get("token", "").strip()
    page_id = data.get("page_id", "").strip()
    if not token or not page_id:
        return jsonify(error="請填寫 Token 與頁面 ID"), 400

    try:
        from notion_client import Client
        notion = Client(auth=token)
        page   = notion.pages.retrieve(page_id=page_id)
        props  = page.get("properties", {})
        tp     = props.get("title", props.get("Name", {}))
        tl     = tp.get("title", [])
        label  = tl[0]["plain_text"] if tl else page_id
    except Exception as e:
        return jsonify(error=f"連線失敗：{e}"), 400

    # 局部更新 .env（保留其他已有的 key）
    env_path = Path(".env")
    existing: dict[str, str] = {}
    if env_path.exists():
        for raw in env_path.read_text(encoding="utf-8").splitlines():
            raw = raw.strip()
            if raw and not raw.startswith("#") and "=" in raw:
                k, _, v = raw.partition("=")
                existing[k.strip()] = v.strip()
    existing["NOTION_TOKEN"]   = token
    existing["NOTION_PAGE_ID"] = page_id
    env_path.write_text(
        "\n".join(f"{k}={v}" for k, v in existing.items()) + "\n",
        encoding="utf-8",
    )
    os.environ["NOTION_TOKEN"]   = token
    os.environ["NOTION_PAGE_ID"] = page_id

    return jsonify(ok=True, page_label=label)
