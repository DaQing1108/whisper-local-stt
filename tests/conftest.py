"""tests/conftest.py — 共用 fixtures 與測試用 WAV 產生器。"""
from __future__ import annotations

import io
import os
import struct
import subprocess
import sys
import time
import wave
import tempfile
from pathlib import Path

import pytest
import requests

# 讓 import 找到 source 目錄
SRC = Path(__file__).parent.parent
sys.path.insert(0, str(SRC))

SERVER_URL = "http://localhost:5001"
STARTUP_TIMEOUT = 15  # 秒


# ── WAV 產生工具 ──────────────────────────────────────────────────────────────

def make_silence_wav(duration_sec: float = 1.0, sample_rate: int = 16000) -> bytes:
    """產生指定秒數的靜音 WAV bytes。"""
    n_frames = int(sample_rate * duration_sec)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00\x00" * n_frames)
    return buf.getvalue()


def make_tone_wav(freq: float = 440.0, duration_sec: float = 1.0,
                  sample_rate: int = 16000) -> bytes:
    """產生正弦波音調 WAV bytes（非靜音，可觸發 Whisper）。"""
    import math
    n_frames = int(sample_rate * duration_sec)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        frames = bytearray()
        for i in range(n_frames):
            v = int(3000 * math.sin(2 * math.pi * freq * i / sample_rate))
            frames += struct.pack("<h", v)
        wf.writeframes(bytes(frames))
    return buf.getvalue()


# ── Server fixtures ───────────────────────────────────────────────────────────

@pytest.fixture(scope="session")
def server_url():
    """等待 Flask server 就緒，回傳 base URL。"""
    deadline = time.time() + STARTUP_TIMEOUT
    while time.time() < deadline:
        try:
            r = requests.get(f"{SERVER_URL}/api/health", timeout=2)
            if r.status_code == 200:
                return SERVER_URL
        except requests.ConnectionError:
            pass
        time.sleep(1)
    pytest.skip(f"Flask server 未在 {STARTUP_TIMEOUT}s 內就緒，跳過 integration tests")


@pytest.fixture
def silence_wav():
    return make_silence_wav(1.0)


@pytest.fixture
def tone_wav():
    return make_tone_wav(440.0, 2.0)


@pytest.fixture
def tmp_obsidian_vault(tmp_path):
    """暫時性 Obsidian vault 目錄，測試結束自動清除。"""
    vault = tmp_path / "ObsidianTest"
    vault.mkdir()
    return vault
