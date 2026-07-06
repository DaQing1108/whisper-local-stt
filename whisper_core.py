"""whisper_core.py — Whisper 轉錄引擎（mlx-whisper + faster-whisper fallback）。"""
from __future__ import annotations

import logging
import math
import os
import subprocess
import sys
import tempfile
import threading
import wave
from pathlib import Path
from typing import Optional


# ── 簡體→繁體（台灣）確定性轉換 ──────────────────────────────
_OPENCC_CONVERTER = None

def _to_traditional(text: str) -> str:
    """使用 OpenCC s2twp 將簡體中文轉為繁體中文（台灣慣用詞）。
    s2twp = Simplified → Traditional (Taiwan) with phrase conversion.
    若 opencc 未安裝則原文回傳。"""
    global _OPENCC_CONVERTER
    if not text:
        return text
    try:
        if _OPENCC_CONVERTER is None:
            import opencc
            _OPENCC_CONVERTER = opencc.OpenCC('s2twp')
        return _OPENCC_CONVERTER.convert(text)
    except ImportError:
        logging.warning("[Whisper] opencc 未安裝，跳過簡轉繁。請執行：pip install opencc-python-reimplemented")
        return text
    except Exception as e:
        logging.warning("[Whisper] opencc 轉換失敗：%s", e)
        return text


class TranscriptionError(Exception):
    """帶有 error_code 的轉錄錯誤，routes.py 可直接取用 code 推送結構化 SSE。"""
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)

from llm_post import has_llm_key, llm_punctuate
from sse import broadcast

# ── ffmpeg 路徑解析（lazy，呼叫時才找，避免 import 時 PATH 尚未設好）────
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")

_FFMPEG: str | None = None

def _get_ffmpeg() -> str:
    global _FFMPEG
    if _FFMPEG:
        return _FFMPEG
    # 優先找打包在專案目錄 bin/ 內的 ffmpeg（build_app.sh 會複製過來）
    _bundled = Path(__file__).parent / "bin" / "ffmpeg"
    candidates = [str(_bundled), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg"]
    for candidate in candidates:
        try:
            subprocess.run([candidate, "-version"], capture_output=True, check=True)
            _FFMPEG = candidate
            return candidate
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    raise TranscriptionError(
        "FFMPEG_MISSING",
        "找不到 ffmpeg。請在終端機執行：brew install ffmpeg，或重新執行 setup.sh",
    )

# ── mlx-whisper 可用性偵測 ────────────────────────────────────
# PyInstaller frozen context: Metal/MLX causes C-level crashes inside the app sandbox.
# Use faster-whisper (CPU) instead for reliability in the packaged .app.
if getattr(sys, "frozen", False):
    _HAS_MLX = False
else:
    try:
        import mlx_whisper as _mlx_check  # noqa: F401
        _HAS_MLX = True
    except (ImportError, Exception):
        _HAS_MLX = False

MLX_REPOS: dict[str, str] = {
    "tiny":   "mlx-community/whisper-tiny-mlx",
    "base":   "mlx-community/whisper-base-mlx",
    "small":  "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large":  "mlx-community/whisper-large-v3-mlx",
}

_fw_cache: dict = {}
_fw_cache_lock = threading.Lock()

# 模型暖機狀態：routes.py 的 /api/model-status 讀取
_warmup_state: dict[str, str] = {}  # model_name → "cached" | "downloading" | "error"
_warmup_lock = threading.Lock()

# faster-whisper 使用的 HuggingFace repo 名稱
_FW_REPOS: dict[str, str] = {
    "tiny":    "Systran/faster-whisper-tiny",
    "base":    "Systran/faster-whisper-base",
    "small":   "Systran/faster-whisper-small",
    "medium":  "Systran/faster-whisper-medium",
    "large":   "Systran/faster-whisper-large-v3",
    "large-v2": "Systran/faster-whisper-large-v2",
}


def is_model_cached(model_name: str) -> bool:
    """檢查 faster-whisper 模型是否已在本地快取，不觸發下載。"""
    hf_cache = Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface" / "hub"))
    repo = _FW_REPOS.get(model_name, f"Systran/faster-whisper-{model_name}")
    dir_name = "models--" + repo.replace("/", "--")
    # 快取目錄存在且有 snapshots 子目錄即視為已下載
    return (hf_cache / dir_name / "snapshots").exists()


def warmup_model_async(model_name: str) -> None:
    """在背景執行緒中下載並載入模型，狀態寫入 _warmup_state。"""
    with _warmup_lock:
        if _warmup_state.get(model_name) in ("downloading", "cached"):
            return
        _warmup_state[model_name] = "downloading"

    def _do():
        try:
            from faster_whisper import WhisperModel
            with _fw_cache_lock:
                if model_name not in _fw_cache:
                    logging.info("[Whisper] 下載/載入模型：%s", model_name)
                    _fw_cache[model_name] = WhisperModel(model_name, device="cpu", compute_type="int8")
            with _warmup_lock:
                _warmup_state[model_name] = "cached"
            logging.info("[Whisper] 模型就緒：%s", model_name)
        except Exception as e:
            logging.error("[Whisper] 模型載入失敗：%s", e)
            with _warmup_lock:
                _warmup_state[model_name] = "error"

    threading.Thread(target=_do, daemon=True).start()


CHUNK_SECONDS = 30 * 60  # 30 分鐘一段

# ── 領域 initial_prompt ───────────────────────────────────────
# initial_prompt 應放「前文語境」（自然語言），而非指令句。
# 指令句（如「請使用繁體中文輸出」）會被 Whisper 誤當轉錄內容輸出。
# 語言用 language='zh' 強制指定，不靠 prompt 引導。

DOMAIN_TERMS: dict[str, str] = {
    "media":   "ASR、DGX、RNG、timecode、字幕、後製、歐拉密、健康2.0、TVBS、context window、LLM、API、Edge端",
    "medical": "",
    "legal":   "",
    "tech":    "軟體開發、雲端架構、AI模型、系統設計",
    "general": "",
}


def build_prompt(domain: str, extra_terms: str = "") -> str:
    """回傳 initial_prompt（只放術語語境，無指令句）；無術語則回傳空字串。"""
    parts = []
    domain_terms = DOMAIN_TERMS.get(domain, "")
    if domain_terms:
        parts.append(domain_terms)
    if extra_terms:
        parts.append(extra_terms)
    return "、".join(parts) if parts else ""


def _strip_prompt_echo(text: str, prompt: str) -> str:
    """移除 Whisper 把 initial_prompt 誤當轉錄內容輸出的情況。"""
    import re as _re
    if not text or not prompt:
        return text

    def _clean(s: str) -> str:
        return _re.sub(r'[\s。，、；：？！]', '', s)

    clean_prompt = _clean(prompt)

    # 若每一行（去標點後）都是 prompt 的子字串 → 全是 prompt echo
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    if lines:
        echo_count = sum(
            1 for l in lines
            if len(_clean(l)) >= 4 and _clean(l) in clean_prompt
        )
        non_empty = [l for l in lines if len(_clean(l)) >= 4]
        if non_empty and echo_count == len(non_empty):
            return ""

    # prompt 完整字串出現在輸出開頭 → 取後面的真實內容
    markers = [s.strip() for s in prompt.replace("。", "。\n").splitlines() if len(s.strip()) > 4]
    for marker in markers:
        if marker in text:
            after = text.split(marker, 1)[-1].strip()
            return after if len(after) > 5 else ""

    return text


# ── mlx subprocess 轉錄腳本 ──────────────────────────────────
_MLX_SCRIPT = """
import sys, json
import mlx_whisper

wav_path       = sys.argv[1]
repo           = sys.argv[2]
language       = sys.argv[3] if sys.argv[3] != '__auto__' else None
initial_prompt = sys.argv[4] if len(sys.argv) > 4 else ''

kwargs = {'condition_on_previous_text': False}
if language:
    kwargs['language'] = language
if initial_prompt:
    kwargs['initial_prompt'] = initial_prompt

result   = mlx_whisper.transcribe(wav_path, path_or_hf_repo=repo, **kwargs)
segments = [{'text': s.get('text',''), 'start': s.get('start',0), 'end': s.get('end',0)}
             for s in result.get('segments', [])]
print(json.dumps({
    'text':     result.get('text', ''),
    'language': result.get('language', '?'),
    'segments': segments,
}))
"""


def _punctuate_segments(segments: list) -> str:
    Q_ENDINGS = (
        '嗎', '吗', '不是嗎', '對吗', '對不對', '對', '對嗎',
        '呢', '對話', '怎麼樣', '怎樣', '哪里', '什麼',
    )
    E_ENDINGS = ('啦', '啊', '哇', '夺')
    PUNCT_CHARS = set('。！？、…,.!?')

    lines = []
    for seg in segments:
        t = seg.get('text', '').strip()
        if not t:
            continue
        last = t[-1]
        if last in PUNCT_CHARS:
            lines.append(t)
        elif any(t.endswith(q) for q in Q_ENDINGS) or t.endswith('?'):
            lines.append(t + '？')
        elif any(t.endswith(e) for e in E_ENDINGS):
            lines.append(t + '。')
        else:
            lines.append(t + '。')
    return '\n'.join(lines)


def _transcribe_mlx_subprocess(
    wav_path: str, model_name: str, language: Optional[str], initial_prompt: str = ""
) -> dict:
    import json as _json
    repo     = MLX_REPOS.get(model_name, MLX_REPOS["small"])
    lang_arg = language or "__auto__"
    proc = subprocess.run(
        [sys.executable, "-c", _MLX_SCRIPT, wav_path, repo, lang_arg, initial_prompt],
        capture_output=True, text=True, timeout=7200,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else "mlx failed")
    last_line = [l for l in proc.stdout.strip().splitlines() if l.startswith("{")]
    if not last_line:
        raise RuntimeError("mlx 無輸出")
    return _json.loads(last_line[-1])


def _transcribe_mlx_inprocess(
    wav_path: str, model_name: str, language: Optional[str], initial_prompt: str = ""
) -> dict:
    # In a PyInstaller frozen app, sys.executable is the bootloader — running it with -c
    # spawns a new full app instance (which calls _free_port() and kills the parent).
    # Safe to call mlx_whisper directly since Metal already initialized at import time.
    import mlx_whisper
    repo   = MLX_REPOS.get(model_name, MLX_REPOS["small"])
    kwargs: dict = {"condition_on_previous_text": False}
    if language:
        kwargs["language"] = language
    if initial_prompt:
        kwargs["initial_prompt"] = initial_prompt
    result   = mlx_whisper.transcribe(wav_path, path_or_hf_repo=repo, **kwargs)
    segments = [
        {"text": s.get("text", ""), "start": s.get("start", 0), "end": s.get("end", 0)}
        for s in result.get("segments", [])
    ]
    return {"text": result.get("text", ""), "language": result.get("language", "?"), "segments": segments}


_FW_SUBPROCESS_SCRIPT = """
import sys, json
from faster_whisper import WhisperModel
wav_path    = sys.argv[1]
model_name  = sys.argv[2]
language    = sys.argv[3] if sys.argv[3] != '__auto__' else None
init_prompt = sys.argv[4] if len(sys.argv) > 4 else ''
model = WhisperModel(model_name, device='cpu', compute_type='int8')
segs_raw, info = model.transcribe(
    wav_path, language=language, beam_size=5,
    initial_prompt=init_prompt or None,
    vad_filter=True, vad_parameters={'min_silence_duration_ms': 300},
)
segments = [{'text': s.text, 'start': s.start, 'end': s.end} for s in segs_raw]
print(json.dumps({'text': ' '.join(s['text'] for s in segments).strip(),
                  'language': info.language, 'segments': segments}))
"""

_SYSTEM_PYTHON: str | None = None
_SYSTEM_PYTHON_MLX: str | None = None

_SYS_PYTHON_CANDIDATES = (
    "/Library/Developer/CommandLineTools/usr/bin/python3",
    "/usr/bin/python3",
    "/opt/homebrew/bin/python3",
    "python3",
)


def _get_system_python() -> str | None:
    """系統 python3 with faster_whisper。"""
    global _SYSTEM_PYTHON
    if _SYSTEM_PYTHON:
        return _SYSTEM_PYTHON
    for candidate in _SYS_PYTHON_CANDIDATES:
        try:
            r = subprocess.run(
                [candidate, "-c", "from faster_whisper import WhisperModel"],
                capture_output=True, timeout=10,
            )
            if r.returncode == 0:
                _SYSTEM_PYTHON = candidate
                return candidate
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return None


def _get_system_python_mlx() -> str | None:
    """系統 python3 with mlx_whisper（Apple Silicon 加速）。"""
    global _SYSTEM_PYTHON_MLX
    if _SYSTEM_PYTHON_MLX:
        return _SYSTEM_PYTHON_MLX
    for candidate in _SYS_PYTHON_CANDIDATES:
        try:
            r = subprocess.run(
                [candidate, "-c", "import mlx_whisper"],
                capture_output=True, timeout=10,
            )
            if r.returncode == 0:
                _SYSTEM_PYTHON_MLX = candidate
                return candidate
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return None


def _transcribe_mlx_system_subprocess(
    wav_path: str, model_name: str, language: Optional[str], initial_prompt: str = ""
) -> dict:
    """frozen .app 用：系統 python3 で mlx_whisper 転写 → メモリ分離 + Apple Silicon 加速。"""
    import json as _json
    py      = _get_system_python_mlx()
    repo    = MLX_REPOS.get(model_name, MLX_REPOS["small"])
    lang_arg = language or "__auto__"
    proc = subprocess.run(
        [py, "-c", _MLX_SCRIPT, wav_path, repo, lang_arg, initial_prompt],
        capture_output=True, text=True, timeout=7200,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else "mlx subprocess failed")
    last_line = [l for l in proc.stdout.strip().splitlines() if l.startswith("{")]
    if not last_line:
        raise RuntimeError("mlx subprocess 無輸出")
    return _json.loads(last_line[-1])


def _transcribe_fw_subprocess(
    wav_path: str, model_name: str, language: Optional[str], initial_prompt: str = ""
) -> dict:
    """frozen .app 用：系統 python3 で faster-whisper 転写 → WKWebView とメモリ分離。"""
    import json as _json
    py       = _get_system_python()
    lang_arg = language or "__auto__"
    proc = subprocess.run(
        [py, "-c", _FW_SUBPROCESS_SCRIPT, wav_path, model_name, lang_arg, initial_prompt],
        capture_output=True, text=True, timeout=7200,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else "fw subprocess failed")
    last_line = [l for l in proc.stdout.strip().splitlines() if l.startswith("{")]
    if not last_line:
        raise RuntimeError("fw subprocess 無輸出")
    return _json.loads(last_line[-1])


def _transcribe_file(wav_path: str, model_name: str, opts: dict) -> dict:
    """優先 mlx-whisper；frozen 時は system subprocess で分離；fallback faster-whisper。"""
    language       = opts.get("language") or None
    initial_prompt = opts.get("initial_prompt", "")

    # frozen .app: 系統 python3 subprocess（メモリ分離）で優先 mlx → fallback fw
    if getattr(sys, "frozen", False):
        if _get_system_python_mlx():
            try:
                data = _transcribe_mlx_system_subprocess(wav_path, model_name, language, initial_prompt)
                segs = data.get("segments", [])
                text = _punctuate_segments(segs) if segs else data.get("text", "").strip()
                return {"text": text, "language": data.get("language", "?"), "segments": segs}
            except Exception as e:
                print(f"[Whisper] mlx subprocess 失敗（{e}），切換 fw subprocess", flush=True)
        if _get_system_python():
            try:
                data = _transcribe_fw_subprocess(wav_path, model_name, language, initial_prompt)
                segs = data.get("segments", [])
                text = _punctuate_segments(segs) if segs else data.get("text", "").strip()
                return {"text": text, "language": data.get("language", "?"), "segments": segs}
            except Exception as e:
                print(f"[Whisper] fw subprocess 失敗（{e}），in-process fallback", file=sys.stderr, flush=True)

    # 開發模式：mlx subprocess → fallback in-process faster-whisper
    if _HAS_MLX:
        try:
            data = _transcribe_mlx_subprocess(wav_path, model_name, language, initial_prompt)
            segs = data.get("segments", [])
            text = _punctuate_segments(segs) if segs else data.get("text", "").strip()
            return {"text": text, "language": data.get("language", "?"), "segments": segs}
        except Exception as e:
            print(f"[Whisper] mlx 失敗（{e}），切換 faster-whisper", flush=True)

    # Fallback: in-process faster-whisper
    from faster_whisper import WhisperModel
    with _fw_cache_lock:
        if model_name not in _fw_cache:
            print(f"[Whisper] 載入 faster-whisper {model_name}…", flush=True)
            _fw_cache[model_name] = WhisperModel(model_name, device="cpu", compute_type="int8")
    fw_model = _fw_cache[model_name]
    raw_segs, info = fw_model.transcribe(
        wav_path,
        language=language,
        beam_size=5,
        initial_prompt=initial_prompt or None,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
    )
    segs = [{"text": s.text, "start": s.start, "end": s.end} for s in raw_segs]
    text = _punctuate_segments(segs) if segs else ""
    return {"text": text, "language": info.language, "segments": segs}


def run_whisper(
    audio_bytes: bytes,
    ext: str,
    model_name: str,
    language: Optional[str],
    progress_cb=None,
    keep_wav: bool = False,
    **kwargs,
) -> tuple[str, str, dict]:
    """
    把音訊 bytes 轉為 WAV，切成 CHUNK_SECONDS 段分批轉錄。
    回傳 (full_text, detected_lang, info_dict)。
    若 keep_wav=True，轉換後的 WAV 不刪除，路徑存於 info["wav_path"]。
    """
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp_in:
        tmp_in.write(audio_bytes)
        tmp_in_path = tmp_in.name

    tmp_wav = tmp_in_path + ".wav"
    try:
        subprocess.run(
            [_get_ffmpeg(), "-y", "-i", tmp_in_path,
             "-ar", "16000", "-ac", "1", "-f", "wav", tmp_wav],
            check=True, capture_output=True,
        )

        with wave.open(tmp_wav, 'r') as wf:
            total_frames = wf.getnframes()
            framerate    = wf.getframerate()
            total_sec    = total_frames / framerate

        domain      = kwargs.get("domain", "general")
        extra_terms = kwargs.get("extra_terms", "")
        prompt      = build_prompt(domain, extra_terms)
        # 分段錄音：用前段結尾覆蓋 initial_prompt 增加連貫性
        if kwargs.get("initial_prompt_override"):
            prompt = kwargs["initial_prompt_override"]
        print(f"[Whisper] prompt={repr(prompt[:60])}, lang={language}", flush=True)

        # language：明確指定 zh；auto 時也預設 zh（台灣繁體中文錄音）
        effective_lang = language if (language and language != "auto") else "zh"
        opts: dict = {"language": effective_lang}
        if prompt:
            opts["initial_prompt"] = prompt

        info = {
            "model":            model_name,
            "domain":           domain,
            "extra_terms":      extra_terms,
            "duration_seconds": total_sec,
        }

        if total_sec <= CHUNK_SECONDS:
            if progress_cb:
                progress_cb(0, 1, "")
            broadcast("status", {
                "msg": f"⏳ 啟動 Whisper {model_name} 模型進行語音辨識 (由於硬體效能，這可能需花費數十秒)..."
            })
            result    = _transcribe_file(tmp_wav, model_name, opts)
            full_text = _strip_prompt_echo(result.get("text", "").strip(), prompt)
            lang      = result.get("language", "?")
            info["segments"] = result.get("segments", [])
            if not kwargs.get("skip_llm") and has_llm_key():
                broadcast("status", {"msg": "⏳ 語音辨識完畢，正在啟動 LLM 進行語意糾錯與標點處理..."})
                full_text = llm_punctuate(full_text, extra_terms)
            return _to_traditional(full_text), lang, info

        # 長音檔：切段
        chunk_frames = int(CHUNK_SECONDS * framerate)
        n_chunks     = math.ceil(total_frames / chunk_frames)
        texts: list[str] = []
        all_segments: list[dict] = []
        lang = "?"

        with wave.open(tmp_wav, 'rb') as wf:
            params = wf.getparams()
            for i in range(n_chunks):
                wf.setpos(i * chunk_frames)
                frames     = wf.readframes(chunk_frames)
                chunk_path = tmp_in_path + f"_chunk{i}.wav"
                with wave.open(chunk_path, 'wb') as cw:
                    cw.setparams(params)
                    cw.writeframes(frames)
                try:
                    result   = _transcribe_file(chunk_path, model_name, opts)
                    seg_text = _strip_prompt_echo(result.get("text", "").strip(), prompt)
                    lang     = result.get("language", lang)
                    texts.append(seg_text)
                    offset = i * CHUNK_SECONDS
                    for seg in result.get("segments", []):
                        all_segments.append({
                            "text":  seg["text"],
                            "start": seg["start"] + offset,
                            "end":   seg["end"] + offset,
                        })
                finally:
                    Path(chunk_path).unlink(missing_ok=True)
                if progress_cb:
                    progress_cb(i + 1, n_chunks, seg_text)

        full_text = "\n".join(texts)
        info["segments"] = all_segments
        if not kwargs.get("skip_llm") and has_llm_key():
            broadcast("status", {"msg": "⏳ 全文轉錄完畢，正在啟動 LLM 進行語意糾錯與標點處理..."})
            full_text = llm_punctuate(full_text, extra_terms)
        return _to_traditional(full_text), lang, info

    finally:
        Path(tmp_in_path).unlink(missing_ok=True)
        if keep_wav:
            info["wav_path"] = tmp_wav
        else:
            Path(tmp_wav).unlink(missing_ok=True)

# alias for chunked upload route
transcribe_audio = run_whisper
