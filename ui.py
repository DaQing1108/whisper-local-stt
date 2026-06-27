"""ui.py — 組裝前端 HTML（templates/index.html + static/app.css + static/app.js）。"""
import sys
from pathlib import Path

if getattr(sys, 'frozen', False):
    # PyInstaller macOS app bundle: binary in Contents/MacOS/, data in Contents/Resources/
    _BASE = Path(sys.executable).parent.parent / 'Resources'
else:
    _BASE = Path(__file__).resolve().parent


def _read(path: str) -> str:
    return (_BASE / path).read_text(encoding="utf-8")


HTML_PAGE: str = (
    _read("templates/index.html")
    .replace("/* __APP_CSS__ */", _read("static/app.css"))
    .replace("// __APP_JS__",     _read("static/app.js"))
)
