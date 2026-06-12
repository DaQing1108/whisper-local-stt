#!/usr/bin/env python3
from __future__ import annotations
"""
app.py — Whisper 轉錄 Web UI 入口點
啟動：python3 app.py  或  python3 -m waitress --port=5001 --threads=8 app:app
開啟：http://localhost:5001
"""

import logging
import os
import signal
import socketserver
import threading
import traceback
import warnings

from dotenv import load_dotenv
from flask import Flask
from werkzeug.serving import WSGIRequestHandler

from version import __version__

load_dotenv()

# ── 從根部封殺 Broken pipe ────────────────────────────────────
try:
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
except (AttributeError, OSError):
    pass  # Windows 沒有 SIGPIPE

_SUPPRESS = ('BrokenPipeError', 'Errno 32', 'Errno 104',
             'Broken pipe', 'ConnectionReset', 'EPIPE')

_orig_handle_error = socketserver.BaseServer.handle_error


def _quiet_handle_error(self, request, client_address):
    tb = traceback.format_exc()
    if any(s in tb for s in _SUPPRESS):
        return
    _orig_handle_error(self, request, client_address)


socketserver.BaseServer.handle_error = _quiet_handle_error


class _QuietHandler(WSGIRequestHandler):
    def log_error(self, fmt, *args):
        msg = (fmt % args) if args else str(fmt)
        if any(s in msg for s in _SUPPRESS):
            return
        super().log_error(fmt, *args)


logging.getLogger('werkzeug').setLevel(logging.ERROR)
warnings.filterwarnings('ignore')

# ── Flask app ─────────────────────────────────────────────────
app = Flask(__name__)

# 注入 HTML 後再註冊 Blueprint（routes.py 依賴 HTML_PAGE）
from ui import HTML_PAGE
import routes
routes.HTML_PAGE = HTML_PAGE
app.register_blueprint(routes.bp)

# ── 入口 ──────────────────────────────────────────────────────
if __name__ == "__main__":
    import os as _os
    # 確保 cwd 是專案目錄（.app bundle 啟動時 cwd 可能是 /）
    _os.chdir(_os.path.dirname(_os.path.abspath(__file__)))

    from waitress import serve
    port = int(_os.environ.get("PORT", 5001))
    print(f"🚀 Whisper STT v{__version__} 啟動中… 開啟 http://localhost:{port}")
    serve(app, host="0.0.0.0", port=port, threads=16)
