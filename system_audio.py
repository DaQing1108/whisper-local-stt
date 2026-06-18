"""system_audio.py — ScreenCaptureKit system audio capture subprocess wrapper."""
from __future__ import annotations

import io
import logging
import math
import struct
import subprocess
import threading
import wave
from pathlib import Path
from typing import Callable

import numpy as np

SAMPLE_RATE = 16000
CHANNELS = 1
BYTES_PER_SAMPLE = 2
CHUNK_SECONDS = 15
CHUNK_BYTES = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE * CHUNK_SECONDS  # 480 000


def _find_binary() -> Path | None:
    """Locate the compiled system_audio_capture binary."""
    candidates = [
        Path(__file__).parent / "bin" / "system_audio_capture",
        Path(__file__).parent / "system_audio_capture",
        # PyInstaller bundle
        Path(__file__).parent.parent / "system_audio_capture",
        # Shell-script .app bundle: Resources/bin/
        Path(__file__).parent.parent / "Contents" / "Resources" / "bin" / "system_audio_capture",
    ]
    for p in candidates:
        if p.exists() and p.is_file():
            return p
    return None


_SILENCE_RMS_THRESHOLD = 100  # int16 RMS < 100 ≈ -68 dBFS → treat as silence


def _is_silence(pcm: bytes) -> bool:
    """Return True if the PCM chunk is effectively silent."""
    if len(pcm) < 2:
        return True
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    return rms < _SILENCE_RMS_THRESHOLD


def _pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(BYTES_PER_SAMPLE)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


class SystemAudioCapture:
    """Manages the Swift subprocess and delivers WAV chunks to a callback."""

    def __init__(
        self,
        on_chunk: Callable[[bytes, int], None],
        on_error: Callable[[str], None] | None = None,
    ):
        self._on_chunk = on_chunk
        self._on_error = on_error
        self._proc: subprocess.Popen | None = None
        self._reader_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None
        self._running = False
        self._chunk_index = 0
        self._lock = threading.Lock()

    # ── Public API ────────────────────────────────────────────────────────────

    def start(self) -> None:
        binary = _find_binary()
        if binary is None:
            raise RuntimeError(
                "system_audio_capture binary not found. "
                "Run build_app.sh or compile manually: "
                "swiftc system_audio_capture.swift -o bin/system_audio_capture "
                "-framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia"
            )

        self._running = True
        self._chunk_index = 0
        self._proc = subprocess.Popen(
            [str(binary)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )

        self._stderr_thread = threading.Thread(target=self._stderr_loop, daemon=True)
        self._stderr_thread.start()

        self._reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self._reader_thread.start()
        logging.info("[SystemAudio] capture started, pid=%d", self._proc.pid)

    def stop(self) -> None:
        self._running = False
        if self._proc:
            try:
                self._proc.terminate()
                self._proc.wait(timeout=3)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass
            self._proc = None
        logging.info("[SystemAudio] capture stopped")

    @property
    def is_running(self) -> bool:
        return self._running and self._proc is not None and self._proc.poll() is None

    # ── Internal ──────────────────────────────────────────────────────────────

    def _read_loop(self) -> None:
        buf = b""
        proc = self._proc
        if proc is None:
            return

        try:
            print(f"[SystemAudio] read_loop started, binary={_find_binary()}", flush=True)
            while self._running and proc.poll() is None:
                data = proc.stdout.read(8192)
                if not data:
                    break
                buf += data

                while len(buf) >= CHUNK_BYTES:
                    chunk_pcm = buf[:CHUNK_BYTES]
                    buf = buf[CHUNK_BYTES:]
                    self._emit_chunk(chunk_pcm)

            # Flush remaining audio (partial last chunk)
            if buf and len(buf) > SAMPLE_RATE * BYTES_PER_SAMPLE:  # > 0.5s
                self._emit_chunk(buf)

        except Exception as exc:
            logging.error("[SystemAudio] read_loop error: %s", exc)
        finally:
            self._running = False

    def _emit_chunk(self, pcm: bytes) -> None:
        with self._lock:
            idx = self._chunk_index
            self._chunk_index += 1
        try:
            if _is_silence(pcm):
                logging.info("[SystemAudio] chunk %d skipped (silence)", idx)
                return
            wav = _pcm_to_wav(pcm)
            self._on_chunk(wav, idx)
        except Exception as exc:
            logging.error("[SystemAudio] chunk callback error: %s", exc)

    def _stderr_loop(self) -> None:
        proc = self._proc
        if proc is None:
            return
        _tcc_reported = False
        try:
            for line in proc.stderr:
                text = line.decode(errors="replace").rstrip()
                print(f"[SystemAudio] {text}", flush=True)
                if text.startswith("ERROR:"):
                    logging.error("[SystemAudio] swift: %s", text)
                    if not _tcc_reported and ("-3801" in text or "declined TCCs" in text):
                        _tcc_reported = True
                        if self._on_error:
                            self._on_error("SCREEN_RECORDING_DENIED")
        except Exception:
            pass


# Module-level singleton (one capture session at a time)
_capture: SystemAudioCapture | None = None
_capture_lock = threading.Lock()


def get_capture() -> SystemAudioCapture | None:
    return _capture


def start_capture(
    on_chunk: Callable[[bytes, int], None],
    on_error: Callable[[str], None] | None = None,
) -> SystemAudioCapture:
    global _capture
    with _capture_lock:
        if _capture and _capture.is_running:
            raise RuntimeError("系統音訊擷取已在運行中")
        cap = SystemAudioCapture(on_chunk, on_error=on_error)
        cap.start()
        _capture = cap
        return cap


def stop_capture() -> None:
    global _capture
    with _capture_lock:
        if _capture:
            _capture.stop()
            _capture = None


# ── PCM mixing helper ─────────────────────────────────────────────────────────

def _mix_pcm(a: bytes, b: bytes) -> bytes:
    """Mix two int16 PCM streams by averaging; zero-pad shorter stream."""
    n = max(len(a), len(b)) // 2 * 2
    arr_a = np.frombuffer(a.ljust(n, b"\x00"), dtype=np.int16).astype(np.int32)
    arr_b = np.frombuffer(b.ljust(n, b"\x00"), dtype=np.int16).astype(np.int32)
    mixed = np.clip((arr_a + arr_b) // 2, -32768, 32767).astype(np.int16)
    return mixed.tobytes()


# ── MixedAudioCapture: system audio + microphone ─────────────────────────────

class MixedAudioCapture:
    """Combines ScreenCaptureKit system audio with the default microphone input.

    Chunking is timer-driven (every CHUNK_SECONDS) so mic-only audio is
    processed even when system audio is silent.  System audio is collected
    into a separate buffer and mixed in at each tick.
    """

    def __init__(self, on_chunk: Callable[[bytes, int], None]):
        self._on_chunk    = on_chunk
        self._mic_buf     = b""
        self._sys_buf     = b""
        self._mic_lock    = threading.Lock()
        self._sys_lock    = threading.Lock()
        self._mic_stream  = None
        self._running     = False
        self._chunk_index = 0
        self._timer_thread: threading.Thread | None = None
        # SystemAudioCapture collects audio into _sys_buf; no chunk callback needed
        self._sys_capture = SystemAudioCapture(self._on_sys_audio)

    def start(self) -> None:
        import sounddevice as sd

        self._running = True
        self._mic_stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="int16",
            callback=self._mic_callback,
            blocksize=4096,
        )
        self._mic_stream.start()
        self._sys_capture.start()
        self._timer_thread = threading.Thread(target=self._timer_loop, daemon=True)
        self._timer_thread.start()
        logging.info("[MixedAudio] started (system + mic, timer-driven)")

    def stop(self) -> None:
        self._running = False
        self._sys_capture.stop()
        if self._mic_stream:
            try:
                self._mic_stream.stop()
                self._mic_stream.close()
            except Exception:
                pass
            self._mic_stream = None
        # flush remainder
        self._flush_chunk(final=True)
        logging.info("[MixedAudio] stopped")

    @property
    def is_running(self) -> bool:
        return self._running

    # ── internal ──────────────────────────────────────────────────────────────

    def _mic_callback(self, indata, frames, time_info, status) -> None:
        with self._mic_lock:
            self._mic_buf += indata.tobytes()

    def _on_sys_audio(self, wav_bytes: bytes, _chunk_index: int) -> None:
        """Collect system audio WAV chunks into raw PCM buffer."""
        buf = io.BytesIO(wav_bytes)
        with wave.open(buf, "rb") as w:
            pcm = w.readframes(w.getnframes())
        with self._sys_lock:
            self._sys_buf += pcm

    def _timer_loop(self) -> None:
        import time as _time
        while self._running:
            _time.sleep(CHUNK_SECONDS)
            if self._running:
                self._flush_chunk(final=False)

    def _flush_chunk(self, final: bool = False) -> None:
        with self._mic_lock:
            mic_pcm = self._mic_buf[:CHUNK_BYTES]
            self._mic_buf = self._mic_buf[CHUNK_BYTES:]
        with self._sys_lock:
            sys_pcm = self._sys_buf[:CHUNK_BYTES]
            self._sys_buf = self._sys_buf[CHUNK_BYTES:]

        if not mic_pcm and not sys_pcm:
            return

        # If only one source has data, use it directly; otherwise mix
        if mic_pcm and sys_pcm:
            mixed = _mix_pcm(mic_pcm, sys_pcm)
        elif mic_pcm:
            mixed = mic_pcm
        else:
            mixed = sys_pcm

        idx = self._chunk_index
        self._chunk_index += 1

        if _is_silence(mixed):
            logging.info("[MixedAudio] chunk %d skipped (silence)", idx)
            return

        self._on_chunk(_pcm_to_wav(mixed), idx)


# Module-level singleton for mixed capture
_mixed_capture: MixedAudioCapture | None = None


def start_mixed_capture(on_chunk: Callable[[bytes, int], None]) -> MixedAudioCapture:
    global _mixed_capture
    with _capture_lock:
        if (_capture and _capture.is_running) or (_mixed_capture and _mixed_capture.is_running):
            raise RuntimeError("系統音訊擷取已在運行中")
        cap = MixedAudioCapture(on_chunk)
        cap.start()
        _mixed_capture = cap
        return cap


def stop_mixed_capture() -> None:
    global _mixed_capture
    with _capture_lock:
        if _mixed_capture:
            _mixed_capture.stop()
            _mixed_capture = None


def get_mixed_capture() -> MixedAudioCapture | None:
    return _mixed_capture
