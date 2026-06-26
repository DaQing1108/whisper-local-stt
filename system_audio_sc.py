"""system_audio_sc.py — ScreenCaptureKit audio capture via pyobjc (in-process).

Runs entirely inside WhisperAI so TCC permission belongs to the parent app,
eliminating the subprocess TCC grant problem.
"""
from __future__ import annotations

import ctypes
import io
import logging
import math
import struct
import threading
import wave
from typing import Callable

import numpy as np
import objc
from Foundation import NSObject, NSRunLoop, NSDate, NSDefaultRunLoopMode

# ── Load frameworks ───────────────────────────────────────────────────────────

_sc_globals: dict = {}
objc.loadBundle(
    "ScreenCaptureKit",
    bundle_path="/System/Library/Frameworks/ScreenCaptureKit.framework",
    module_globals=_sc_globals,
)
objc.loadBundle(
    "CoreMedia",
    bundle_path="/System/Library/Frameworks/CoreMedia.framework",
    module_globals=_sc_globals,
)

SCShareableContent    = objc.lookUpClass("SCShareableContent")
SCStream              = objc.lookUpClass("SCStream")
SCStreamConfiguration = objc.lookUpClass("SCStreamConfiguration")
SCContentFilter       = objc.lookUpClass("SCContentFilter")

# Register block signatures so pyobjc can call completion handlers
_BLOCK_V_V   = {"callable": {"retval": {"type": b"v"}, "arguments": {0: {"type": b"^v"}}}}
_BLOCK_V_VE  = {"callable": {"retval": {"type": b"v"}, "arguments": {0: {"type": b"^v"}, 1: {"type": b"@"}}}}
_BLOCK_V_VCE = {"callable": {"retval": {"type": b"v"}, "arguments": {0: {"type": b"^v"}, 1: {"type": b"@"}, 2: {"type": b"@"}}}}

objc.registerMetaDataForSelector(
    b"SCShareableContent", b"getShareableContentWithCompletionHandler:",
    {"arguments": {2: _BLOCK_V_VCE}},
)
objc.registerMetaDataForSelector(
    b"SCShareableContent", b"getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:",
    {"arguments": {4: _BLOCK_V_VCE}},
)
objc.registerMetaDataForSelector(
    b"SCStream", b"startCaptureWithCompletionHandler:",
    {"arguments": {2: _BLOCK_V_VE}},
)
objc.registerMetaDataForSelector(
    b"SCStream", b"stopCaptureWithCompletionHandler:",
    {"arguments": {2: _BLOCK_V_VE}},
)

_cm = ctypes.CDLL("/System/Library/Frameworks/CoreMedia.framework/CoreMedia")
_cm.CMSampleBufferGetDataBuffer.restype     = ctypes.c_void_p
_cm.CMSampleBufferGetDataBuffer.argtypes    = [ctypes.c_void_p]
_cm.CMBlockBufferGetDataLength.restype      = ctypes.c_size_t
_cm.CMBlockBufferGetDataLength.argtypes     = [ctypes.c_void_p]
_cm.CMBlockBufferCopyDataBytes.restype      = ctypes.c_int
_cm.CMBlockBufferCopyDataBytes.argtypes     = [
    ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p
]
_cm.CMSampleBufferGetNumSamples.restype     = ctypes.c_long
_cm.CMSampleBufferGetNumSamples.argtypes    = [ctypes.c_void_p]
_cm.CMSampleBufferGetFormatDescription.restype  = ctypes.c_void_p
_cm.CMSampleBufferGetFormatDescription.argtypes = [ctypes.c_void_p]
_cm.CMAudioFormatDescriptionGetStreamBasicDescription.restype  = ctypes.c_void_p
_cm.CMAudioFormatDescriptionGetStreamBasicDescription.argtypes = [ctypes.c_void_p]

# ── Constants ─────────────────────────────────────────────────────────────────

TARGET_RATE     = 16_000
CHANNELS        = 1
BYTES_PER_SAMPLE= 2
CHUNK_SECONDS   = 15
CHUNK_BYTES     = TARGET_RATE * CHANNELS * BYTES_PER_SAMPLE * CHUNK_SECONDS  # 480 000

_SILENCE_RMS_THRESHOLD = 100

SCStreamOutputTypeAudio = 1  # SCStreamOutputType.audio

# ── AudioStreamBasicDescription (C struct) ────────────────────────────────────

class _ASBD(ctypes.Structure):
    _fields_ = [
        ("mSampleRate",       ctypes.c_double),
        ("mFormatID",         ctypes.c_uint32),
        ("mFormatFlags",      ctypes.c_uint32),
        ("mBytesPerPacket",   ctypes.c_uint32),
        ("mFramesPerPacket",  ctypes.c_uint32),
        ("mBytesPerFrame",    ctypes.c_uint32),
        ("mChannelsPerFrame", ctypes.c_uint32),
        ("mBitsPerChannel",   ctypes.c_uint32),
        ("mReserved",         ctypes.c_uint32),
    ]

# ── Helpers ───────────────────────────────────────────────────────────────────

def _sample_buffer_to_pcm16(sb_ptr: int) -> bytes | None:
    """Extract raw int16 PCM from a CMSampleBuffer (float32 interleaved → int16 mono)."""
    bb_ptr = _cm.CMSampleBufferGetDataBuffer(sb_ptr)
    if not bb_ptr:
        return None
    length = _cm.CMBlockBufferGetDataLength(bb_ptr)
    if length == 0:
        return None

    buf = (ctypes.c_byte * length)()
    ret = _cm.CMBlockBufferCopyDataBytes(bb_ptr, 0, length, buf)
    if ret != 0:
        return None

    raw = bytes(buf)

    # Determine source format from FormatDescription
    fmt_ptr = _cm.CMSampleBufferGetFormatDescription(sb_ptr)
    asbd_ptr = _cm.CMAudioFormatDescriptionGetStreamBasicDescription(fmt_ptr)
    if asbd_ptr:
        asbd = _ASBD.from_address(asbd_ptr)
        src_rate     = asbd.mSampleRate
        src_channels = asbd.mChannelsPerFrame
        bits         = asbd.mBitsPerChannel
    else:
        src_rate, src_channels, bits = 48000, 2, 32

    # Parse as float32 (ScreenCaptureKit default)
    n_samples = length // (src_channels * 4)
    arr = np.frombuffer(raw, dtype=np.float32).reshape(n_samples, src_channels)

    # Mix to mono
    mono = arr.mean(axis=1)

    # Resample to TARGET_RATE if needed
    if int(src_rate) != TARGET_RATE:
        ratio     = TARGET_RATE / src_rate
        new_len   = int(len(mono) * ratio)
        indices   = np.linspace(0, len(mono) - 1, new_len)
        mono      = np.interp(indices, np.arange(len(mono)), mono)

    # Convert to int16
    pcm16 = np.clip(mono * 32767, -32768, 32767).astype(np.int16)
    return pcm16.tobytes()


def _is_silence(pcm: bytes) -> bool:
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
        w.setframerate(TARGET_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


# ── SCStream delegate (module-level, singleton class) ─────────────────────────

# Global reference to the active capture so the delegate can call back
_active_sc_capture: "SCKitAudioCapture | None" = None


class _SCStreamDelegate(NSObject):
    """ObjC delegate that receives audio sample buffers from SCStream."""

    def stream_didOutputSampleBuffer_ofType_(
        self,
        stream,      # SCStream*   → @
        sb,          # CMSampleBufferRef → @
        otype,       # SCStreamOutputType (NSInteger) → l
    ):
        if otype != SCStreamOutputTypeAudio:
            return
        cap = _active_sc_capture
        if cap is None:
            return
        try:
            pcm = _sample_buffer_to_pcm16(int(sb))
            if pcm:
                cap._ingest(pcm)
        except Exception as exc:
            logging.error("[SCCapture] sample callback error: %s", exc)

    stream_didOutputSampleBuffer_ofType_ = objc.selector(
        stream_didOutputSampleBuffer_ofType_,
        signature=b"v@:@@l",
    )


def _make_delegate() -> _SCStreamDelegate:
    return _SCStreamDelegate.alloc().init()


# ── Main capture class ────────────────────────────────────────────────────────

class SCKitAudioCapture:
    """In-process system audio capture via ScreenCaptureKit + pyobjc."""

    def __init__(self, on_chunk: Callable[[bytes, int], None]):
        self._on_chunk    = on_chunk
        self._buf         = b""
        self._buf_lock    = threading.Lock()
        self._chunk_index = 0
        self._running     = False
        self._stream      = None
        self._delegate    = None
        self._queue       = None
        self._rl_thread   = None
        self._ready       = threading.Event()
        self._error: str | None = None

    # ── Public API ────────────────────────────────────────────────────────────

    def start(self) -> None:
        self._running  = True
        self._rl_thread = threading.Thread(target=self._run_loop, daemon=True)
        self._rl_thread.start()
        if not self._ready.wait(timeout=10):
            raise RuntimeError(self._error or "SCKit 初始化逾時")
        if self._error:
            raise RuntimeError(self._error)

    def stop(self) -> None:
        global _active_sc_capture
        self._running = False
        _active_sc_capture = None
        if self._stream:
            event = threading.Event()
            def _done(err):
                event.set()
            self._stream.stopCaptureWithCompletionHandler_(_done)
            event.wait(timeout=5)
            self._stream = None
        # flush remaining buffer
        with self._buf_lock:
            tail = self._buf
            self._buf = b""
        if tail and len(tail) > TARGET_RATE * BYTES_PER_SAMPLE:
            self._emit(tail)

    @property
    def is_running(self) -> bool:
        return self._running

    # ── Internal ──────────────────────────────────────────────────────────────

    def _ingest(self, pcm: bytes) -> None:
        with self._buf_lock:
            self._buf += pcm
            while len(self._buf) >= CHUNK_BYTES:
                chunk = self._buf[:CHUNK_BYTES]
                self._buf = self._buf[CHUNK_BYTES:]
                self._emit(chunk)

    def _emit(self, pcm: bytes) -> None:
        idx = self._chunk_index
        self._chunk_index += 1
        if _is_silence(pcm):
            logging.info("[SCCapture] chunk %d skipped (silence)", idx)
            return
        self._on_chunk(_pcm_to_wav(pcm), idx)

    def _run_loop(self) -> None:
        """Run SCKit setup directly on this background thread (no main queue needed).

        SCShareableContent and SCStream completion handlers are dispatched on
        internal GCD background queues — not the main thread — so we can safely
        call setup from any thread without deadlocking the run loop.
        """
        import time as _time

        try:
            self._setup_stream()
        except Exception as exc:
            self._error = str(exc)
            self._ready.set()
            logging.error("[SCCapture] setup error: %s", exc)
            return

        if not self._ready.is_set():
            self._error = "SCKit 初始化逾時"
            self._ready.set()
            return

        if self._error:
            return

        while self._running:
            _time.sleep(0.2)

    def _setup_stream(self) -> None:
        """Called on main thread to initialise the SCStream pipeline.
        Uses threading.Event (not run-loop spinning) since SCKit
        completion handlers are dispatched on internal GCD queues.
        """
        ev1, ev2 = threading.Event(), threading.Event()
        cr: list = [None, None]
        sr: list = [None]

        # 1. Get shareable content
        def _got_content(content, error):
            cr[0] = content
            cr[1] = error
            ev1.set()

        SCShareableContent.getShareableContentWithCompletionHandler_(_got_content)
        if not ev1.wait(timeout=10):
            self._error = "getShareableContent 逾時"
            self._ready.set()
            return

        content, err = cr[0], cr[1]
        if err or not content:
            self._error = f"無法取得螢幕內容: {err}"
            self._ready.set()
            return
        displays = content.displays()
        if not displays:
            self._error = "找不到顯示器"
            self._ready.set()
            return

        # 2. Configure
        cfg = SCStreamConfiguration.alloc().init()
        cfg.setCapturesAudio_(True)
        cfg.setCaptureMicrophone_(False)
        cfg.setExcludesCurrentProcessAudio_(False)
        cfg.setSampleRate_(TARGET_RATE)
        cfg.setChannelCount_(CHANNELS)
        flt = SCContentFilter.alloc().initWithDisplay_excludingWindows_(displays[0], [])

        # 3. Delegate + stream
        global _active_sc_capture
        _active_sc_capture = self
        self._delegate = _make_delegate()
        self._stream = SCStream.alloc().initWithFilter_configuration_delegate_(
            flt, cfg, self._delegate
        )

        # 4. Audio output on a dedicated background queue
        self._queue = objc.lookUpClass("NSOperationQueue").alloc().init()
        self._stream.addStreamOutput_type_sampleHandlerQueue_error_(
            self._delegate, SCStreamOutputTypeAudio, self._queue, None
        )

        # 5. Start capture
        def _started(err):
            sr[0] = err
            ev2.set()

        self._stream.startCaptureWithCompletionHandler_(_started)
        if not ev2.wait(timeout=10):
            self._error = "startCapture 逾時"
            self._ready.set()
            return

        if sr[0]:
            self._error = f"SCStream 啟動失敗: {sr[0]}"
            self._ready.set()
            return

        logging.info("[SCCapture] ScreenCaptureKit in-process stream started")
        self._ready.set()


# ── Module-level singleton ────────────────────────────────────────────────────

_sc_capture: SCKitAudioCapture | None = None
_sc_lock = threading.Lock()


def start_sc_capture(on_chunk: Callable[[bytes, int], None]) -> SCKitAudioCapture:
    global _sc_capture
    with _sc_lock:
        if _sc_capture and _sc_capture.is_running:
            raise RuntimeError("系統音訊擷取已在運行中")
        cap = SCKitAudioCapture(on_chunk)
        cap.start()
        _sc_capture = cap
        return cap


def stop_sc_capture() -> None:
    global _sc_capture
    with _sc_lock:
        if _sc_capture:
            _sc_capture.stop()
            _sc_capture = None


def get_sc_capture() -> SCKitAudioCapture | None:
    return _sc_capture


def check_tcc_status() -> str:
    """偵測 macOS 螢幕錄製 TCC 授權狀態。
    只做靜態偵測，不呼叫 SCKit 擷取（CLAUDE.md NEVER #1）。
    回傳 "granted" / "denied" / "unknown"。
    """
    try:
        import Quartz  # type: ignore
        # CGRequestScreenCaptureAccess() 在 macOS 11+ 可用
        # 但不要呼叫它（會彈出授權對話框）；改用 CGPreflightScreenCaptureAccess()
        if hasattr(Quartz, "CGPreflightScreenCaptureAccess"):
            return "granted" if Quartz.CGPreflightScreenCaptureAccess() else "denied"
    except Exception:
        pass
    return "unknown"
