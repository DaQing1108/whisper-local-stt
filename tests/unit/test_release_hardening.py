"""Release-facing consistency checks for Whisper STT v2.4.1."""

import re
from pathlib import Path


ROOT = Path(__file__).parent.parent.parent
VERSION = "2.4.1"


def _read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_release_version_is_consistent_across_user_facing_surfaces():
    assert f'__version__ = "{VERSION}"' in _read("version.py")
    assert f"Whisper STT v{VERSION}" in _read("templates/preferences.html")
    assert f"v{VERSION}" in _read("tests/manual_checklist.md")
    assert f"<string>{VERSION}</string>" in _read("Info.plist")
    assert f"'CFBundleShortVersionString':     '{VERSION}'" in _read("gui.spec")


def test_release_brand_is_whisper_stt_on_active_app_surfaces():
    assert '<title>Whisper STT' in _read("templates/index.html")
    assert '<h1>Whisper STT</h1>' in _read("templates/index.html")
    assert 'title        = f"Whisper STT v{__version__}"' in _read("gui.py")


def test_release_guides_exist_and_cover_installation_permissions_and_recovery():
    installation = _read("docs/INSTALLATION.md")
    troubleshooting = _read("docs/TROUBLESHOOTING.md")

    for term in ("Applications", "macOS 12", "Apple Silicon", "首次轉錄"):
        assert term in installation
    for term in ("麥克風", "螢幕錄製", "port 5001", "log", "重新啟動"):
        assert term in troubleshooting


def test_disabled_result_actions_have_actionable_titles():
    html = _read("templates/index.html")
    for button_id in ("copy-btn", "export-btn", "obsidian-btn", "upload-btn"):
        tag = re.search(rf'<button[^>]+id="{button_id}"[^>]*>', html)
        assert tag, f"missing {button_id}"
        assert "disabled" in tag.group(0)
        assert re.search(r'title="[^"]{4,}"', tag.group(0))


def test_responsive_and_theme_release_guards_are_present():
    css = _read("static/app.css")
    assert '@media (max-width: 600px)' in css
    assert '[data-theme="light"]' in css
    assert 'body[data-view-mode="compact"]' in css
    assert '.quick-bar.expanded .qb-chevron { transform: rotate(180deg); }' in css
