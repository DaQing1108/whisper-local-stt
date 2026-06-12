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

# 確保 cwd 是專案目錄（打包後 sys.executable 路徑不同）
os.chdir(os.path.dirname(os.path.abspath(__file__)))

from dotenv import load_dotenv
load_dotenv()

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


def main() -> None:
    import webview

    _free_port()

    # Flask 在 daemon 執行緒跑，視窗關掉後自動結束
    t = threading.Thread(target=_start_flask, daemon=True)
    t.start()

    if not _wait_for_server():
        print("❌ 伺服器啟動失敗", file=sys.stderr)
        sys.exit(1)

    window = webview.create_window(
        title        = f"Whisper AI 會議記錄 v{__version__}",
        url          = URL,
        width        = 960,
        height       = 800,
        min_size     = (720, 600),
        resizable    = True,
        text_select  = True,
        confirm_close= True,      # 關閉前詢問（對應錄音中的 beforeunload）
    )

    # macOS：隱藏標題列讓 UI 佔滿視窗
    webview.start(debug=False, http_server=False)


if __name__ == "__main__":
    main()
