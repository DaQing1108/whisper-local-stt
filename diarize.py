"""diarize.py — 說話者分離 Beta（pyannote.audio 3.x）

使用方式：
  from diarize import diarize_audio, apply_diarization

需要 HuggingFace token 授權 pyannote 模型（一次性設定）：
  export HF_TOKEN=hf_xxxx
  或存入 .env 的 HF_TOKEN 欄位

注意：首次執行會下載模型（~250MB），之後會快取於 ~/.cache/huggingface
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from typing import NamedTuple

log = logging.getLogger(__name__)


class Segment(NamedTuple):
    start: float
    end: float
    speaker: str


def is_available() -> bool:
    """回傳 True 若系統 Python 有 pyannote.audio 且 HF_TOKEN 已設定。"""
    if not bool(os.environ.get("HF_TOKEN", "").strip()):
        return False
    # 檢查 pyannote 套件目錄是否存在（不 import，避免 timeout）
    import site
    sp = "/Users/daqingliao/Library/Python/3.9/lib/python/site-packages"
    return os.path.isdir(os.path.join(sp, "pyannote", "audio"))


def diarize_audio(audio_path: str, num_speakers: int | None = None) -> list[Segment]:
    """對音檔執行說話者分離，回傳 Segment 列表。

    Args:
        audio_path: 16kHz mono WAV 路徑
        num_speakers: 已知說話者數量（None 自動偵測）

    Returns:
        list of Segment(start, end, speaker)

    Raises:
        RuntimeError: HF_TOKEN 未設定或 pyannote 無法載入
    """
    hf_token = os.environ.get("HF_TOKEN", "").strip()
    if not hf_token:
        raise RuntimeError(
            "說話者分離需要 HuggingFace Token。"
            "請至偏好設定填入 HF Token，或設定 HF_TOKEN 環境變數。"
        )

    # 用系統 Python 執行 pyannote，避免 PyInstaller bundle 的依賴衝突
    python_exec = "/usr/bin/python3"
    script = _DIARIZE_WORKER_SCRIPT

    log.warning("[Diarize] 呼叫系統 Python 執行說話者分離：%s", audio_path)
    result = subprocess.run(
        [python_exec, "-c", script, audio_path, hf_token,
         str(num_speakers) if num_speakers else ""],
        capture_output=True,
        text=True,
        timeout=300,
    )

    if result.returncode != 0:
        log.warning("[Diarize] subprocess stderr: %s", result.stderr[-500:])
        raise RuntimeError(f"說話者分離失敗：{result.stderr[-200:]}")

    raw = result.stdout.strip().split("\n")[-1]
    data = json.loads(raw)
    segments = [Segment(d["start"], d["end"], d["speaker"]) for d in data]
    log.warning("[Diarize] 完成，%d 個片段，%d 位說話者",
                len(segments), len({s.speaker for s in segments}))
    return segments


_DIARIZE_WORKER_SCRIPT = """
import sys, os, json
audio_path, hf_token, num_spk_str = sys.argv[1], sys.argv[2], sys.argv[3]
os.environ['HF_TOKEN'] = hf_token

import speechbrain.utils.importutils as _sbi
_orig_ensure = _sbi.LazyModule.ensure_module
def _safe_ensure(self, stacklevel=0):
    try: return _orig_ensure(self, stacklevel)
    except ImportError: return None
_sbi.LazyModule.ensure_module = _safe_ensure

import torch
import lightning_fabric.utilities.cloud_io as _lf_io
def _patched(path, map_location=None, **kw):
    return torch.load(path, map_location=map_location, weights_only=False)
_lf_io._load = _patched

from pyannote.audio import Pipeline
pipeline = Pipeline.from_pretrained('pyannote/speaker-diarization-3.1')
params = {}
if num_spk_str:
    params['num_speakers'] = int(num_spk_str)
diarization = pipeline(audio_path, **params)
segs = [{'start': round(t.start,3), 'end': round(t.end,3), 'speaker': s}
        for t, _, s in diarization.itertracks(yield_label=True)]
print(json.dumps(segs))
"""


def apply_diarization(
    transcript: str,
    segments: list[Segment],
    whisper_segments: list[dict] | None = None,
) -> str:
    """將說話者標籤套入逐字稿。

    優先使用 whisper_segments（含 start/end 時間）精確對應說話者；
    若無 whisper_segments 則 fallback 至 [MM:SS] 時間戳記模式。

    Args:
        transcript: 原始逐字稿文字
        segments: diarize_audio 的回傳值
        whisper_segments: Whisper 的 segment 列表（{text, start, end}）

    Returns:
        帶有說話者標籤的逐字稿
    """
    if not segments:
        return transcript

    # 建立說話者 ID 映射（SPEAKER_00 → 說話者 A）
    speaker_ids = sorted({s.speaker for s in segments})
    labels = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    speaker_map = {sp: f"說話者 {labels[i]}" for i, sp in enumerate(speaker_ids)}

    # ── 精確模式：使用 Whisper segment 時間點對應說話者 ──────────────
    if whisper_segments:
        result: list[str] = []
        last_label: str | None = None
        for ws in whisper_segments:
            text = ws.get("text", "").strip()
            if not text:
                continue
            mid = (ws.get("start", 0) + ws.get("end", 0)) / 2
            speaker = _speaker_at(segments, mid)
            label = speaker_map.get(speaker, "")
            if label and label != last_label:
                if result:
                    result.append("")
                result.append(f"**{label}**")
                last_label = label
            result.append(text)
        return "\n".join(result)

    # ── Fallback：依 [MM:SS] 時間戳記插入說話者標籤 ─────────────────
    import re
    lines = transcript.strip().split("\n")
    fallback: list[str] = []
    last_speaker: str | None = None

    for line in lines:
        if not line.strip():
            fallback.append(line)
            continue

        ts_match = re.match(r"^\[(\d+):(\d+)\]", line)
        if ts_match:
            m, s = int(ts_match.group(1)), int(ts_match.group(2))
            t = m * 60 + s
            speaker = _speaker_at(segments, t)
            label = speaker_map.get(speaker, "")
            if label and label != last_speaker:
                fallback.append(f"\n**{label}**")
                last_speaker = label
        elif last_speaker is None and segments:
            label = speaker_map.get(segments[0].speaker, "")
            if label:
                fallback.append(f"**{label}**")
                last_speaker = label

        fallback.append(line)

    return "\n".join(fallback)


def _speaker_at(segments: list[Segment], t: float) -> str:
    """找出時間點 t 對應的說話者。"""
    best = segments[0].speaker
    best_dist = abs(segments[0].start - t)
    for seg in segments:
        if seg.start <= t <= seg.end:
            return seg.speaker
        dist = min(abs(seg.start - t), abs(seg.end - t))
        if dist < best_dist:
            best_dist = dist
            best = seg.speaker
    return best
