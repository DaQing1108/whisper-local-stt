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

from llm_post import has_llm_key, llm_punctuate
from sse import broadcast

# ── mlx-whisper 可用性偵測 ────────────────────────────────────
try:
    import mlx_whisper as _mlx_check  # noqa: F401
    _HAS_MLX = True
except ImportError:
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

CHUNK_SECONDS = 30 * 60  # 30 分鐘一段

# ── 領域 initial_prompt ───────────────────────────────────────
_BASE_PROMPT = "以下是台灣繁體中文的會議記錄，請使用繁體中文輸出。"

DOMAIN_PROMPTS: dict[str, str] = {
    "media": (
        "以下是台灣媒體科技公司的會議記錄，請使用繁體中文輸出。"
        "涉及專業術語包含：ASR、DGX、RNG、timecode、字幕、後製、"
        "歐拉密、健康2.0、TVBS、context window、LLM、API、Edge端。"
    ),
    "medical": (
        "以下是台灣醫療會議記錄，請使用繁體中文輸出。"
        "涉及醫療術語、病名、藥名及臨床程序。"
    ),
    "legal": (
        "以下是台灣法律會議記錄，請使用繁體中文輸出。"
        "涉及法條、訴訟程序及法律術語。"
    ),
    "tech": (
        "以下是台灣科技公司的技術會議記錄，請使用繁體中文輸出。"
        "涉及軟體開發、雲端架構、AI 模型及系統設計術語。"
    ),
    "general": _BASE_PROMPT,
}


def build_prompt(domain: str, extra_terms: str = "") -> str:
    base = DOMAIN_PROMPTS.get(domain, _BASE_PROMPT)
    if extra_terms:
        return base + f"此次會議的專有名詞包含：{extra_terms}。"
    return base


def _strip_prompt_echo(text: str, prompt: str) -> str:
    """移除 Whisper 把 initial_prompt 誤當轉錄內容輸出的情況。"""
    if not text or not prompt:
        return text
    # 把 prompt 拆成關鍵短語，任何一段出現在輸出就代表是 prompt echo
    markers = [s.strip() for s in prompt.replace("。", "。\n").splitlines() if len(s.strip()) > 4]
    for marker in markers:
        if marker in text:
            after = text.split(marker, 1)[-1].strip()
            # marker 後若有真實內容就保留，否則整段都是 prompt echo → 回傳空
            return after if len(after) > 5 else ""
    # 整段文字幾乎等於 prompt（允許少量差異）→ 也過濾掉
    prompt_clean = prompt.replace("以下是", "").replace("，請使用繁體中文輸出。", "").strip()
    if prompt_clean and text.strip() in prompt:
        return ""
    return text


# ── mlx subprocess 轉錄腳本 ──────────────────────────────────
_MLX_SCRIPT = """
import sys, json
import mlx_whisper

wav_path       = sys.argv[1]
repo           = sys.argv[2]
language       = sys.argv[3] if sys.argv[3] != '__auto__' else None
initial_prompt = sys.argv[4] if len(sys.argv) > 4 else ''

kwargs = {}
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


def _transcribe_file(wav_path: str, model_name: str, opts: dict) -> dict:
    """優先 mlx-whisper subprocess；失敗或未安裝時 fallback faster-whisper。"""
    language       = opts.get("language") or None
    initial_prompt = opts.get("initial_prompt", "")

    if _HAS_MLX:
        try:
            data = _transcribe_mlx_subprocess(wav_path, model_name, language, initial_prompt)
            segs = data.get("segments", [])
            text = _punctuate_segments(segs) if segs else data.get("text", "").strip()
            return {"text": text, "language": data.get("language", "?"), "segments": segs}
        except Exception as e:
            print(f"[Whisper] mlx 失敗（{e}），切換 faster-whisper", flush=True)

    # Fallback: faster-whisper
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
    **kwargs,
) -> tuple[str, str, dict]:
    """
    把音訊 bytes 轉為 WAV，切成 CHUNK_SECONDS 段分批轉錄。
    回傳 (full_text, detected_lang, info_dict)。
    """
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp_in:
        tmp_in.write(audio_bytes)
        tmp_in_path = tmp_in.name

    tmp_wav = tmp_in_path + ".wav"
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", tmp_in_path,
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
        print(f"[Whisper] initial_prompt: {prompt[:60]}…", flush=True)

        opts: dict = {"initial_prompt": prompt}
        if language and language != "auto":
            opts["language"] = language

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
            if has_llm_key():
                broadcast("status", {"msg": "⏳ 語音辨識完畢，正在啟動 LLM 進行語意糾錯與標點處理..."})
            full_text = llm_punctuate(full_text, extra_terms)
            return full_text, lang, info

        # 長音檔：切段
        chunk_frames = int(CHUNK_SECONDS * framerate)
        n_chunks     = math.ceil(total_frames / chunk_frames)
        texts: list[str] = []
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
                finally:
                    Path(chunk_path).unlink(missing_ok=True)
                if progress_cb:
                    progress_cb(i + 1, n_chunks, seg_text)

        full_text = "\n".join(texts)
        if has_llm_key():
            broadcast("status", {"msg": "⏳ 全文轉錄完畢，正在啟動 LLM 進行語意糾錯與標點處理..."})
        full_text = llm_punctuate(full_text, extra_terms)
        return full_text, lang, info

    finally:
        Path(tmp_in_path).unlink(missing_ok=True)
        Path(tmp_wav).unlink(missing_ok=True)
