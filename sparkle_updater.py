"""Sparkle updater bridge for the macOS app bundle.

The app can run without Sparkle.framework during local development. All public
functions return a small status dict instead of raising UI-facing errors.
"""
from __future__ import annotations

import logging
import os
import sys
from pathlib import Path

_controller = None
_load_error: str | None = None


def _candidate_framework_paths() -> list[Path]:
    app_dir = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    paths = [
        app_dir / "Sparkle.framework",
        app_dir / "Frameworks" / "Sparkle.framework",
        app_dir.parent / "Frameworks" / "Sparkle.framework",
        app_dir.parent.parent / "Frameworks" / "Sparkle.framework",
        Path(__file__).resolve().parent / "Sparkle.framework",
    ]

    seen: set[Path] = set()
    unique_paths: list[Path] = []
    for path in paths:
        resolved = path.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique_paths.append(path)
    return unique_paths


def _find_framework() -> Path | None:
    for path in _candidate_framework_paths():
        if path.exists():
            return path
    return None


def _ensure_controller():
    global _controller, _load_error

    if _controller is not None:
        return _controller
    if _load_error:
        return None
    if os.environ.get("SPARKLE_DISABLED") == "1":
        _load_error = "Sparkle 已被 SPARKLE_DISABLED=1 停用"
        return None

    framework = _find_framework()
    if framework is None:
        _load_error = "找不到 Sparkle.framework"
        return None

    try:
        import objc
        from Foundation import NSBundle

        bundle = NSBundle.bundleWithPath_(str(framework))
        if not bundle or not bundle.load():
            _load_error = f"Sparkle.framework 載入失敗：{framework}"
            return None

        controller_cls = objc.lookUpClass("SPUStandardUpdaterController")
        _controller = controller_cls.alloc().initWithStartingUpdater_updaterDelegate_userDriverDelegate_(
            True,
            None,
            None,
        )
        logging.info("[Sparkle] updater ready: %s", framework)
        return _controller
    except Exception as exc:
        _load_error = str(exc)
        logging.warning("[Sparkle] updater init failed: %s", exc)
        return None


def status() -> dict:
    controller = _ensure_controller()
    framework = _find_framework()
    return {
        "available": controller is not None,
        "framework_path": str(framework) if framework else "",
        "error": "" if controller is not None else (_load_error or "Sparkle 尚未啟用"),
    }


def check_for_updates() -> dict:
    controller = _ensure_controller()
    if controller is None:
        return {"ok": False, **status()}

    try:
        updater = controller.updater()
        try:
            from PyObjCTools import AppHelper

            AppHelper.callAfter(updater.checkForUpdates_, None)
        except Exception:
            updater.checkForUpdates_(None)
        return {"ok": True, **status()}
    except Exception as exc:
        logging.warning("[Sparkle] checkForUpdates failed: %s", exc)
        return {"ok": False, "available": True, "framework_path": status().get("framework_path", ""), "error": str(exc)}
