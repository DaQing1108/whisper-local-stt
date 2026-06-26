"""gui.py — pywebview 原生視窗入口點。

啟動方式：
    python3 gui.py
打包方式：
    pyinstaller gui.spec
"""
from __future__ import annotations

import os
import sys
import threading
import time

# cwd 設為專案目錄（.app 和 Terminal 模式都統一）
_APP_DIR = os.path.dirname(os.path.abspath(__file__))
os.chdir(_APP_DIR)
# 確保 Resources 目錄也加入 sys.path（.app 打包後 import 需要）
if _APP_DIR not in sys.path:
    sys.path.insert(0, _APP_DIR)

# 使用者資料目錄（rebuild 不會清除）
_USER_DATA_DIR = os.path.join(
    os.path.expanduser("~"), "Library", "Application Support", "WhisperSTT"
)
os.makedirs(_USER_DATA_DIR, exist_ok=True)
# 讓 routes.py 的 Path(".env") 指向使用者資料目錄
os.chdir(_USER_DATA_DIR)
# 但 Python import 仍需要 _APP_DIR
if _APP_DIR not in sys.path:
    sys.path.insert(0, _APP_DIR)

# 確保 Homebrew ffmpeg 在 PATH（.app 環境不繼承 shell PATH）
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")

# 將 stderr 導向 log 檔（存在使用者目錄，方便排查）
import logging
_LOG_FILE = os.path.join(_USER_DATA_DIR, "whisper_app.log")
logging.basicConfig(
    filename=_LOG_FILE,
    level=logging.WARNING,
    format="%(asctime)s %(levelname)s %(message)s",
)
sys.stderr = open(_LOG_FILE, "a")

from dotenv import load_dotenv
# 優先載入使用者目錄的 .env，再 fallback 到 bundle 內
load_dotenv(os.path.join(_USER_DATA_DIR, ".env"))
load_dotenv(os.path.join(_APP_DIR, ".env"))

from version import __version__

PORT = int(os.environ.get("PORT", 5001))
URL  = f"http://localhost:{PORT}"


def _free_port() -> None:
    """釋放 PORT 上的舊程序（避免 .app 重複開啟時 port 衝突）。"""
    import signal, subprocess
    try:
        result = subprocess.run(
            ["lsof", "-ti", f"tcp:{PORT}"],
            capture_output=True, text=True
        )
        for pid in result.stdout.strip().splitlines():
            try:
                os.kill(int(pid), signal.SIGTERM)
            except Exception:
                pass
        time.sleep(0.5)
    except Exception:
        pass


def _start_flask() -> None:
    """在背景執行緒啟動 Flask + Waitress。"""
    import warnings
    warnings.filterwarnings("ignore")

    from flask import Flask
    from ui import HTML_PAGE
    import routes

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 1 * 1024 * 1024 * 1024  # 1 GB
    routes.HTML_PAGE = HTML_PAGE
    app.register_blueprint(routes.bp)

    from waitress import serve
    serve(app, host="127.0.0.1", port=PORT, threads=16)


def _wait_for_server(timeout: int = 15) -> bool:
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(URL, timeout=1)
            return True
        except Exception:
            time.sleep(0.3)
    return False


def _patch_wkwebview_media_permission() -> None:
    """Inject WKUIDelegate method to auto-grant microphone access in WKWebView.

    pywebview's cocoa backend does not implement
    webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:
    so getUserMedia() always fails. This patch adds the method via objc runtime.
    """
    try:
        import objc
        from Foundation import NSObject
        from WebKit import WKWebView  # type: ignore

        # The selector was introduced in macOS 12.0
        sel = b"webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"

        def _grant_media(_self, webview, origin, frame, capture_type, handler):
            # WKPermissionDecisionGrant = 1 (allow microphone / camera)
            handler(1)

        objc.classAddMethod(WKWebView, sel, _grant_media)
    except Exception as exc:
        # pyobjc not available or macOS < 12 — silently skip
        import logging
        logging.warning("[gui] WKWebView media patch failed: %s", exc)


def _open_preferences() -> None:
    """在獨立視窗開啟偏好設定頁（⌘, 觸發）。
    pywebview 6.x 的 create_window 在 cocoa platform 內部用 AppHelper.callAfter
    排入主執行緒，JS bridge 回呼呼叫此函數是安全的。
    """
    import webview
    existing = [w for w in webview.windows if w.title and "偏好設定" in w.title]
    if existing:
        existing[0].show()
        return
    webview.create_window(
        title    = "Whisper STT — 偏好設定",
        url      = f"{URL}/preferences",
        width    = 560,
        height   = 620,
        resizable= False,
    )


def main() -> None:
    import webview

    _patch_wkwebview_media_permission()
    _free_port()

    # Flask 在 daemon 執行緒跑，視窗關掉後自動結束
    t = threading.Thread(target=_start_flask, daemon=True)
    t.start()

    if not _wait_for_server():
        logging.error("❌ 伺服器啟動失敗（Flask 未在 15 秒內回應），請確認 port %s 未被佔用", PORT)
        try:
            import tkinter as tk
            from tkinter import messagebox
            root = tk.Tk()
            root.withdraw()
            messagebox.showerror(
                "Whisper STT 啟動失敗",
                f"伺服器未能在 15 秒內啟動。\n\n"
                f"請確認 port {PORT} 未被其他程式佔用，\n"
                f"或查看 Console.app 的錯誤記錄。"
            )
            root.destroy()
        except Exception as tk_err:
            logging.debug("tkinter 錯誤對話框不可用：%s", tk_err)
        sys.exit(1)

    class _Api:
        def open_preferences(self) -> None:
            _open_preferences()

    window = webview.create_window(
        title        = f"Whisper AI 會議記錄 v{__version__}",
        url          = URL,
        width        = 960,
        height       = 800,
        min_size     = (720, 600),
        resizable    = True,
        text_select  = True,
        confirm_close= True,
        js_api       = _Api(),
    )

    # ⌘, 開啟偏好設定視窗
    def _inject_keybinding() -> None:
        window.evaluate_js("""
        document.addEventListener('keydown', function(e) {
          if ((e.metaKey || e.ctrlKey) && e.key === ',') {
            e.preventDefault();
            window.pywebview.api.open_preferences();
          }
        });
        """)

    window.events.loaded += _inject_keybinding

    webview.start(
        debug        = False,
        http_server  = False,
        private_mode = False,  # 保留 cookie/permission 狀態，避免每次重問
    )


if __name__ == "__main__":
    main()
