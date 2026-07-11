"""system_audio_sc.py — macOS 螢幕錄製 TCC 授權狀態偵測。

只做靜態偵測，不做實際音訊擷取。pyobjc/ScreenCaptureKit in-process 擷取
（SCKitAudioCapture）在 libdispatch 層會觸發 SIGABRT，已改用
system_audio.py 的 Swift subprocess 方案取代（CLAUDE.md NEVER #1），
本檔案僅保留 check_tcc_status() 這個 TCC guard 用途。
"""
from __future__ import annotations


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
