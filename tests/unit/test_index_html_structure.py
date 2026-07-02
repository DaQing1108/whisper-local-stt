"""Structural regression tests for templates/index.html (UI static redesign Phase 1).

Guards the AC from HANDOFF_CLAUDE_WHISPER_UI_STATIC_REDESIGN_PHASE1.md:
- the five semantic zones exist
- every id static/app.js binds via getElementById still exists in the template
- .record-area (the drag & drop target app.js caches once at load) is present
"""
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
HTML = (ROOT / "templates" / "index.html").read_text(encoding="utf-8")
JS = (ROOT / "static" / "app.js").read_text(encoding="utf-8")

HTML_IDS = set(re.findall(r'id="([a-zA-Z0-9_-]+)"', HTML))
JS_ELEMENT_IDS = set(re.findall(r"getElementById\('([a-zA-Z0-9_-]+)'\)", JS))

SEMANTIC_ZONE_CLASSES = [
    "app-shell",
    "app-toolbar",
    "capture-panel",
    "context-bar",
    "results-workspace",
    "workspace-actions",
]


class TestFiveSegmentStructure:
    @pytest.mark.parametrize("class_name", SEMANTIC_ZONE_CLASSES)
    def test_semantic_zone_class_present(self, class_name):
        assert f'class="{class_name}' in HTML or f' {class_name}"' in HTML or f' {class_name} ' in HTML, (
            f"expected semantic zone class .{class_name} in templates/index.html"
        )

    def test_record_area_present_for_drag_drop(self):
        """app.js does `document.querySelector('.record-area')` once at load —
        renaming/removing this class silently breaks drag & drop."""
        assert 'class="record-area"' in HTML


class TestJsDomWiringIntact:
    def test_no_duplicate_ids(self):
        ids = re.findall(r'id="([a-zA-Z0-9_-]+)"', HTML)
        dupes = {i for i in ids if ids.count(i) > 1}
        assert not dupes, f"duplicate ids found: {dupes}"

    def test_every_js_referenced_id_exists_in_html(self):
        # sse-banner is created dynamically via document.createElement, not in the template.
        dynamic_ids = {"sse-banner"}
        # Preferences-only ids live in templates/preferences.html, not this template.
        preferences_ids = {
            "anthropic-key", "anthropic-key-status", "config-status",
            "llm-save-status", "notion-page-id", "notion-token",
            "openai-key", "openai-key-status",
        }
        missing = JS_ELEMENT_IDS - HTML_IDS - dynamic_ids - preferences_ids
        assert not missing, f"static/app.js references ids missing from templates/index.html: {missing}"
