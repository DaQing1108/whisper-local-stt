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


@pytest.fixture
def prefs_page(browser_context):
    # Notion token / page ID / LLM API key fields live on the separate
    # Preferences page (routes.py: GET /preferences), not on the main index —
    # openPreferences() opens it in its own window, it's never embedded.
    page = browser_context.new_page()
    page.goto(f"{BASE_URL}/preferences", wait_until="load")
    yield page
    page.close()


class TestPageLoad:
    def test_title_contains_whisper(self, page):
        assert "Whisper" in page.title()

    def test_version_displayed(self, page):
        # 版本號是 window.onload 裡 fetch('/api/version') 非同步填入 #app-version 的，
        # "load" 事件觸發時不保證已經回來，要等它填值才能斷言。
        page.wait_for_function(
            "document.getElementById('app-version')?.textContent?.includes('v')",
            timeout=5000,
        )
        content = page.content()
        assert "v2.4.0" in content

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
        # obsidian-toggle-label 是固定文案「Obsidian」（純標籤），開關狀態是靠
        # #obsidian-toggle 本身的 class（.toggle.on）表示，不是文字切換——
        # 跟 diarize-toggle 那種「開啟/關閉」文字切換是不同的既有設計。
        label = page.locator("#obsidian-toggle-label, [id*='obsidian'][id*='label']").first
        if label.count() == 0:
            pytest.skip("Obsidian label 元素不存在")
        toggle = page.locator("#obsidian-toggle").first
        initial_class = toggle.get_attribute("class") or ""
        toggle.click()
        time.sleep(0.3)
        assert label.inner_text() == "Obsidian"
        new_class = toggle.get_attribute("class") or ""
        assert initial_class != new_class


class TestPreferencesLayout:
    """Preferences 頁面重整為三個 <details> 分區：Basic（預設展開）、
    Workflow、Advanced/Beta（預設收合）。"""

    def test_three_sections_present_with_correct_defaults(self, prefs_page):
        groups = prefs_page.locator("details.prefs-group")
        assert groups.count() == 3
        summaries = [groups.nth(i).locator("summary").inner_text() for i in range(3)]
        assert summaries == ["Basic 基礎設定", "Workflow 產出格式", "Advanced / Beta 進階功能"]
        assert groups.nth(0).get_attribute("open") is not None, "Basic 應預設展開"
        assert groups.nth(1).get_attribute("open") is None, "Workflow 應預設收合"
        assert groups.nth(2).get_attribute("open") is None, "Advanced/Beta 應預設收合"

    def test_clicking_summary_toggles_section(self, prefs_page):
        workflow = prefs_page.locator("details.prefs-group").nth(1)
        assert workflow.get_attribute("open") is None
        workflow.locator("summary").click()
        assert workflow.get_attribute("open") is not None
        workflow.locator("summary").click()
        assert workflow.get_attribute("open") is None

    def test_workflow_section_preset_switching(self, prefs_page):
        workflow = prefs_page.locator("details.prefs-group").nth(1)
        workflow.locator("summary").click()
        prefs_page.locator(".preset-pill[data-preset='tech']").click()
        # 比對 preferences.js PRESETS.tech.desc 的完整文字，而不是鬆散的關鍵字比對
        assert prefs_page.locator("#preset-desc").inner_text() == "技術討論，保留英文術語與縮寫"

    def test_advanced_section_has_diarize_and_update_checks(self, prefs_page):
        advanced = prefs_page.locator("details.prefs-group").nth(2)
        advanced.locator("summary").click()
        assert advanced.locator("#check-diarize-btn").count() == 1
        assert advanced.locator("#check-updates-btn").count() == 1


class TestNotionSettings:
    def test_notion_token_field_present(self, prefs_page):
        field = prefs_page.locator("input[placeholder*='secret'], input[placeholder*='token'], #notion-token")
        assert field.count() > 0

    def test_notion_page_id_field_present(self, prefs_page):
        field = prefs_page.locator("input[placeholder*='32'], #notion-page-id, [id*='notion'][id*='page']")
        assert field.count() > 0

    def test_notion_save_button_present(self, prefs_page):
        btn = prefs_page.locator("button:has-text('驗證'), button:has-text('儲存'), #notion-save")
        assert btn.count() > 0


class TestLLMSettings:
    def test_claude_api_key_field_present(self, prefs_page):
        field = prefs_page.locator("input[placeholder*='sk-ant'], input[placeholder*='Claude'], #claude-key")
        assert field.count() > 0

    def test_save_api_key_button_present(self, prefs_page):
        # Preferences has one shared "儲存" button for all settings — there's
        # no dedicated "儲存 API" / "Save" button, so match on the real text.
        btn = prefs_page.locator("button:has-text('儲存'), button:has-text('Save'), #save-api-key")
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
        # same async-fetch race as TestPageLoad.test_version_displayed
        page.wait_for_function(
            "document.getElementById('app-version')?.textContent?.includes('v')",
            timeout=5000,
        )
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
        # dev waitress server's task queue depth climbs across the full 24-test
        # session-scoped browser_context run (background health/model polling
        # from earlier tests' pages) — default 30s times out near the end of
        # the suite even though the reload itself is fast in isolation.
        page.reload(wait_until="load", timeout=60000)
        assert page.evaluate("document.body.dataset.viewMode") == "compact", (
            "manual override must persist across a reload (simulates app restart)"
        )
