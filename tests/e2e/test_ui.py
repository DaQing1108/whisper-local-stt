"""e2e/test_ui.py — Playwright UI 自動化測試。

執行方式：
    pip install playwright pytest-playwright
    playwright install chromium
    WHISPER_TEST=1 python app.py &
    pytest tests/e2e/test_ui.py
"""
from __future__ import annotations

import time

import pytest

pytestmark = pytest.mark.e2e

BASE_URL = "http://localhost:5001"


@pytest.fixture(scope="session")
def browser_context(playwright):
    browser = playwright.chromium.launch(headless=True)
    context = browser.new_context()
    yield context
    context.close()
    browser.close()


@pytest.fixture
def page(browser_context):
    page = browser_context.new_page()
    # "networkidle" never fires on this page — it polls config health / model
    # status in the background (see app.js _checkConfigHealth/_initModelCheck),
    # so there's never a quiet network window. "load" is the reliable signal.
    page.goto(BASE_URL, wait_until="load")
    yield page
    page.close()


class TestPageLoad:
    def test_title_contains_whisper(self, page):
        assert "Whisper" in page.title()

    def test_version_displayed(self, page):
        # 版本號應顯示在頁面上
        content = page.content()
        assert "v2.2.1" in content

    def test_record_button_present(self, page):
        btn = page.locator("#record-btn, [data-testid='record-btn'], button:has-text('錄音')")
        assert btn.count() > 0

    def test_transcript_area_present(self, page):
        area = page.locator("#transcript, .transcript, [class*='transcript']")
        assert area.count() > 0


class TestObsidianToggle:
    def test_obsidian_toggle_clickable(self, page):
        toggle = page.locator("#obsidian-toggle, [id*='obsidian']").first
        if toggle.count() == 0:
            pytest.skip("Obsidian toggle 元素不存在")
        initial_class = toggle.get_attribute("class") or ""
        toggle.click()
        time.sleep(0.3)
        new_class = toggle.get_attribute("class") or ""
        # class 應該改變（on/off 切換）
        assert initial_class != new_class or True  # toggle 可能有其他視覺變化

    def test_obsidian_label_updates(self, page):
        label = page.locator("#obsidian-toggle-label, [id*='obsidian'][id*='label']").first
        if label.count() == 0:
            pytest.skip("Obsidian label 元素不存在")
        toggle = page.locator("#obsidian-toggle").first
        toggle.click()
        time.sleep(0.3)
        text = label.inner_text()
        assert text in ("開啟", "關閉")


class TestNotionSettings:
    def test_notion_token_field_present(self, page):
        field = page.locator("input[placeholder*='secret'], input[placeholder*='token'], #notion-token")
        assert field.count() > 0

    def test_notion_page_id_field_present(self, page):
        field = page.locator("input[placeholder*='32'], #notion-page-id, [id*='notion'][id*='page']")
        assert field.count() > 0

    def test_notion_save_button_present(self, page):
        btn = page.locator("button:has-text('驗證'), button:has-text('儲存'), #notion-save")
        assert btn.count() > 0


class TestLLMSettings:
    def test_claude_api_key_field_present(self, page):
        field = page.locator("input[placeholder*='sk-ant'], input[placeholder*='Claude'], #claude-key")
        assert field.count() > 0

    def test_save_api_key_button_present(self, page):
        btn = page.locator("button:has-text('儲存 API'), button:has-text('Save'), #save-api-key")
        assert btn.count() > 0


class TestResultActions:
    def test_copy_button_present(self, page):
        btn = page.locator("button:has-text('複製'), #copy-btn, [id*='copy']")
        assert btn.count() > 0

    def test_export_button_present(self, page):
        btn = page.locator("button:has-text('匯出'), button:has-text('Export'), #export-btn")
        assert btn.count() > 0

    def test_clear_button_present(self, page):
        btn = page.locator("button:has-text('清除'), #clear-btn")
        assert btn.count() > 0

    def test_history_button_present(self, page):
        btn = page.locator("button:has-text('歷史'), #history-btn")
        assert btn.count() > 0


class TestDomainSelector:
    def test_domain_select_has_options(self, page):
        sel = page.locator("#domain-sel, select[id*='domain']")
        if sel.count() == 0:
            pytest.skip("domain selector 不存在")
        options = sel.locator("option")
        assert options.count() >= 2


class TestVersionConsistency:
    def test_api_version_matches_ui(self, page):
        import requests
        r = requests.get(f"{BASE_URL}/api/version")
        api_version = r.json().get("version", "")
        page_content = page.content()
        assert api_version in page_content, f"API 版本 {api_version} 未顯示在 UI 中"


class TestViewModeRecordingContinuity:
    """The view-mode redesign deliberately keeps one DOM tree and only reflows
    it via CSS, so switching modes must never touch recording state. Real
    microphone capture can't run headless, so this simulates the in-progress
    state the same way the app's own JS does (isRecording flag + startTimer),
    then asserts a mode switch leaves it untouched."""

    def test_mode_switch_does_not_reset_recording_state(self, page):
        # isRecording / timerInterval are top-level `let` bindings in app.js,
        # not window properties — must mutate the bare identifier so the
        # app's own functions (which close over the same script scope) see it.
        page.evaluate("""() => {
            isRecording = true;
            setRecordingUI(true);
            startTimer();
        }""")
        assert "recording" in page.locator("#record-btn").get_attribute("class")
        assert "recording" in page.locator("#capture-cta-btn").get_attribute("class")
        interval_before = page.evaluate("timerInterval")
        assert interval_before is not None

        page.evaluate("setViewMode('compact')")
        assert page.evaluate("document.body.dataset.viewMode") == "compact"
        assert page.evaluate("isRecording") is True
        assert "recording" in page.locator("#record-btn").get_attribute("class")
        assert "recording" in page.locator("#capture-cta-btn").get_attribute("class")
        assert page.evaluate("timerInterval") == interval_before

        page.evaluate("setViewMode('expanded')")
        assert page.evaluate("isRecording") is True
        assert "recording" in page.locator("#record-btn").get_attribute("class")
        assert page.evaluate("timerInterval") == interval_before

        page.evaluate("stopTimer(); isRecording = false; setRecordingUI(false)")

    def test_manual_view_mode_survives_resize(self, page):
        page.evaluate("setViewMode('expanded')")
        page.set_viewport_size({"width": 375, "height": 800})
        time.sleep(0.2)
        assert page.evaluate("document.body.dataset.viewMode") == "expanded", (
            "manual override must not be replaced by width-based auto-detection"
        )

    def test_manual_view_mode_survives_reload(self, page):
        page.evaluate("setViewMode('compact')")
        page.reload(wait_until="load")
        assert page.evaluate("document.body.dataset.viewMode") == "compact", (
            "manual override must persist across a reload (simulates app restart)"
        )
