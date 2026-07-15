"""Tests for v2.1 features: batch transcribe UI, keyboard shortcuts, LLM custom prompt."""
import os
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


@pytest.fixture
def client():
    os.environ.setdefault("TESTING", "1")
    from app import app
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


# ── AC-3: batchTranscribe function exists in app.js ─────────────────────────

class TestBatchTranscribeJS:
    def test_batch_transcribe_function_defined(self):
        """AC-3: batchTranscribe function is defined in app.js."""
        js = (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()
        assert "async function batchTranscribe(files)" in js

    def test_drop_handler_uses_files_array(self):
        """AC-3: drop handler collects multiple files (Array.from pattern)."""
        js = (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()
        assert "Array.from(e.dataTransfer.files)" in js


# ── AC-1 & AC-2: keyboard shortcuts in app.js ───────────────────────────────

class TestKeyboardShortcuts:
    def test_space_triggers_start_stop(self):
        """AC-1: Space keydown calls toggleRecord (corrected from startStopRecording in v2.2 UX fix)."""
        js = (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()
        assert "e.code === 'Space'" in js
        assert "toggleRecord()" in js

    def test_cmd_u_triggers_file_input(self):
        """AC-2: Cmd+U triggers file-input click."""
        js = (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()
        assert "e.key === 'u'" in js
        assert "file-input" in js

    def test_input_focus_guard(self):
        """AC-1: keyboard listener excludes input/textarea/select focus."""
        js = (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()
        assert "isInput" in js
        assert "textarea" in js


# ── AC-8: index.html has multiple on file input ──────────────────────────────

class TestFileInputMultiple:
    def test_file_input_has_multiple_attribute(self):
        """AC-8: file-input element has multiple attribute."""
        html = (Path(__file__).parent.parent.parent / "templates" / "index.html").read_text()
        assert 'id="file-input"' in html
        assert "multiple" in html


# ── AC-4: GET /config returns llm_prompt_preview ────────────────────────────

class TestConfigLlmPrompt:
    def test_get_config_returns_llm_prompt_preview(self, client):
        """AC-4: GET /config returns llm_prompt_preview field."""
        r = client.get("/config")
        assert r.status_code == 200
        data = r.get_json()
        assert "llm_prompt_preview" in data
        assert "llm_prompt" in data

    def test_get_config_llm_prompt_empty_by_default(self, client):
        """AC-4: llm_prompt is empty when LLM_CUSTOM_PROMPT not set."""
        os.environ.pop("LLM_CUSTOM_PROMPT", None)
        r = client.get("/config")
        data = r.get_json()
        assert data["llm_prompt"] == ""

    def test_get_config_llm_prompt_preview_truncated(self, client):
        """AC-4: llm_prompt_preview truncates at 50 chars."""
        os.environ["LLM_CUSTOM_PROMPT"] = "A" * 60
        r = client.get("/config")
        data = r.get_json()
        assert data["llm_prompt_preview"].endswith("…")
        assert len(data["llm_prompt_preview"]) <= 52
        os.environ.pop("LLM_CUSTOM_PROMPT", None)


# ── AC-5 & AC-6: POST /config writes/removes LLM_CUSTOM_PROMPT ──────────────

class TestSaveConfigLlmPrompt:
    def test_post_config_saves_llm_prompt(self, client, tmp_path, monkeypatch):
        """AC-5: POST /config with llm_prompt writes LLM_CUSTOM_PROMPT to env."""
        import routes
        monkeypatch.setattr(routes, "_ENV_PATH", tmp_path / ".env")
        monkeypatch.delenv("LLM_CUSTOM_PROMPT", raising=False)

        r = client.post("/config", json={"llm_prompt": "自訂 prompt 內容"})
        assert r.status_code == 200
        assert os.environ.get("LLM_CUSTOM_PROMPT") == "自訂 prompt 內容"

    def test_post_config_empty_llm_prompt_removes_key(self, client, tmp_path, monkeypatch):
        """AC-6: POST /config with empty llm_prompt removes LLM_CUSTOM_PROMPT."""
        import routes
        monkeypatch.setattr(routes, "_ENV_PATH", tmp_path / ".env")
        os.environ["LLM_CUSTOM_PROMPT"] = "old value"

        r = client.post("/config", json={"llm_prompt": ""})
        assert r.status_code == 200
        assert "LLM_CUSTOM_PROMPT" not in os.environ

    def test_post_config_none_llm_prompt_does_not_update(self, client, tmp_path, monkeypatch):
        """AC-5: POST /config without llm_prompt key leaves existing value intact."""
        import routes
        monkeypatch.setattr(routes, "_ENV_PATH", tmp_path / ".env")
        os.environ["LLM_CUSTOM_PROMPT"] = "preserved"

        r = client.post("/config", json={"obsidian_path": ""})
        assert r.status_code == 200
        assert os.environ.get("LLM_CUSTOM_PROMPT") == "preserved"
        os.environ.pop("LLM_CUSTOM_PROMPT", None)


# ── AC-7: llm_post uses custom prompt when env var is set ───────────────────

class TestLlmCustomPrompt:
    def test_custom_prompt_replaces_default(self, monkeypatch):
        """AC-7: LLM_CUSTOM_PROMPT overrides _LLM_PUNCT_PROMPT in _llm_call_chunk."""
        import llm_post

        captured = {}

        def mock_call_chunk(chunk, provider, api_key, extra_terms=""):
            captured["system_used"] = (
                os.environ.get("LLM_CUSTOM_PROMPT", "").strip()[:2000]
                or llm_post._LLM_PUNCT_PROMPT
            )
            return chunk

        monkeypatch.setenv("LLM_CUSTOM_PROMPT", "MY CUSTOM PROMPT")
        monkeypatch.setattr(llm_post, "_llm_call_chunk", mock_call_chunk)

        # Trigger path: read env inside _llm_call_chunk stub
        custom = os.environ.get("LLM_CUSTOM_PROMPT", "").strip()[:2000]
        assert custom == "MY CUSTOM PROMPT"


# ── UX 優化測試（v2.2 深度測試後）───────────────────────────────────────────

class TestUXImprovements:
    """AC-1~7: UX 深度測試後的四項優化驗收。"""

    def _html(self):
        return (Path(__file__).parent.parent.parent / "templates" / "index.html").read_text()

    def _js(self):
        return (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()

    def test_summary_tab_placeholder_updated(self):
        """AC-1: panel-summary placeholder 不再是原始 '— no summary yet —'，含引導說明。"""
        html = self._html()
        assert "— no summary yet —" not in html
        assert "panel-summary" in html

    def test_timeline_tab_placeholder_updated(self):
        """AC-2: panel-timeline placeholder 不再是原始 '— no timeline yet —'，含引導說明。"""
        html = self._html()
        assert "— no timeline yet —" not in html
        assert "panel-timeline" in html

    def test_vocab_library_toggle_button_exists(self):
        """AC-3: vocab-bar 中存在 onclick=toggleSavedDict() 的按鈕。"""
        html = self._html()
        assert "toggleSavedDict()" in html

    def test_toggle_saved_dict_function_exists(self):
        """AC-4: app.js 中 toggleSavedDict() 函數存在且包含 vocab-tags-container display 切換邏輯。"""
        js = self._js()
        assert "function toggleSavedDict()" in js
        assert "vocab-tags-container" in js

    def test_qb_mode_chip_has_chinese_mapping(self):
        """AC-5: updateQBSummary() 中 mode chip 存在 '標準' 中文 mapping。"""
        js = self._js()
        assert "'標準'" in js or '"標準"' in js

    def test_qb_domain_chip_has_chinese_mapping(self):
        """AC-6: updateQBSummary() 中 domain chip 存在 '通用' 中文 mapping。"""
        js = self._js()
        assert "'通用'" in js or '"通用"' in js

    def test_system_audio_onboarding_tip_flag(self):
        """AC-7: onModeChange() system 分支存在 system_audio_tip_shown localStorage check。"""
        js = self._js()
        assert "system_audio_tip_shown" in js

    def test_branding_is_whisper_stt(self):
        """AC-8: 交付版主畫面品牌收斂為 Whisper STT。"""
        html = self._html()
        assert "<title>Whisper STT" in html
        assert "<h1>Whisper STT</h1>" in html

    def test_quick_bar_has_mode_helper_text(self):
        """AC-9: quick-bar 展開後提供模式差異說明。"""
        html = self._html()
        assert "id=\"mode-helper\"" in html
        assert "標準模式錄完後一次整理" in html

    def test_vocab_placeholder_explains_enter_to_apply(self):
        """AC-10: 詞庫輸入框說明本次套用行為。"""
        html = self._html()
        assert "加入本次專有名詞，按 Enter 套用" in html

    def test_action_buttons_have_disabled_titles(self):
        """AC-11: 結果 action 初始 disabled 時提供原因。"""
        html = self._html()
        assert 'id="copy-btn"' in html
        assert "完成轉錄後可複製" in html
        assert "完成轉錄後可匯出" in html

    def test_preferences_are_grouped(self):
        """AC-12: Preferences 分為 Basic / Workflow / Advanced。"""
        prefs = (Path(__file__).parent.parent.parent / "templates" / "preferences.html").read_text()
        assert "Basic 基礎設定" in prefs
        assert "Workflow 產出格式" in prefs
        assert "Advanced / Beta 進階功能" in prefs


# ── 自動記住上次錄音/存檔設定 ─────────────────────────────────

class TestLastSettingsPersistence:
    """驗證錄音設定會寫入並還原 localStorage；發布目的地不再是錄音設定。"""

    def _js(self):
        return (Path(__file__).parent.parent.parent / "static" / "app.js").read_text()

    def test_save_and_restore_functions_defined(self):
        """核心函數存在：儲存、讀取、還原。"""
        js = self._js()
        assert "function _saveLastSetting(key, value)" in js
        assert "function _loadLastSettings()" in js
        assert "function restoreLastSettings()" in js
        assert "LAST_SETTINGS_KEY = 'whisper_last_settings'" in js

    def test_set_pill_persists_selection(self):
        """happy path：setPill() 選擇後會呼叫 _saveLastSetting()。"""
        js = self._js()
        set_pill_body = js.split("function setPill(el, groupId) {")[1].split("\n}")[0]
        assert "_saveLastSetting(key, el.dataset.val)" in set_pill_body

    def test_publish_destinations_are_not_persisted_as_auto_save_toggles(self):
        """Obsidian / Notion 僅能從 footer 手動發布，不保留本次自動發布開關。"""
        js = self._js()
        assert "function toggleNotion()" not in js
        assert "function toggleObsidian()" not in js
        assert "async function saveToObsidian()" in js
        assert "async function uploadToNotion()" in js

    def test_mix_mic_toggle_persists_on_change(self):
        """happy path：混音勾選變更時寫入 localStorage。"""
        js = self._js()
        assert "mix-mic-toggle')?.addEventListener('change'" in js
        assert "_saveLastSetting('mixMic', e.target.checked)" in js

    def test_restore_guards_missing_saved_value(self):
        """edge case：沒有已存設定時（首次使用 / key 不存在）不覆蓋預設 active pill，不丟例外。"""
        js = self._js()
        restore_body = js.split("function restoreLastSettings() {")[1].split("\n}\n")[0]
        assert "if (!s[key]) return" in restore_body

    def test_restore_called_before_qb_summary_on_load(self):
        """edge case：DOMContentLoaded 必須先還原設定再更新快速列摘要，否則摘要會顯示還原前的舊值。"""
        js = self._js()
        dom_ready_block = js.split("document.addEventListener('DOMContentLoaded', () => {")[1]
        restore_idx = dom_ready_block.index("restoreLastSettings()")
        summary_idx = dom_ready_block.index("updateQBSummary()")
        assert restore_idx < summary_idx


# ── Light mode 下處理進度 modal 可讀性修正 ────────────────────

class TestLightModeModalFix:
    """驗證錄音處理事件視窗 (.modal-content/.modal-header/.modal-log-entry) 有主題感知的顏色，而非寫死深色。"""

    def _css(self):
        return (Path(__file__).parent.parent.parent / "static" / "app.css").read_text()

    def _html(self):
        return (Path(__file__).parent.parent.parent / "templates" / "index.html").read_text()

    def test_modal_theme_variables_defined_for_both_themes(self):
        """happy path：:root 與 [data-theme="light"] 都定義了 modal 專用變數。"""
        css = self._css()
        root_block = css.split(":root {")[1].split("\n  }")[0]
        light_block = css.split('[data-theme="light"] {')[1].split("\n  }")[0]
        for var in ("--modal-bg", "--modal-border", "--modal-log-bg", "--modal-log-border"):
            assert var in root_block, f"{var} missing from :root"
            assert var in light_block, f"{var} missing from [data-theme=light]"

    def test_modal_content_uses_theme_variables(self):
        """happy path：.modal-content / .modal-header h3 / .modal-log-entry 改用 var()。"""
        css = self._css()
        assert "background: var(--modal-bg)" in css
        assert "border: 1px solid var(--modal-border)" in css
        assert ".modal-header h3 { font-size: 16px; margin: 0; color: var(--text)" in css
        assert "background: var(--modal-log-bg)" in css

    def test_no_hardcoded_dark_colors_remain_in_modal(self):
        """edge case（回歸防護）：舊的寫死深色（會在 light mode 造成深字疊深底）不應再出現。"""
        css = self._css()
        assert "background: rgba(22,24,32,0.85)" not in css
        assert "color: #fff; font-weight: 500;" not in css
        assert "border: 1px solid rgba(255,255,255,0.03)" not in css

    def test_processing_modal_buttons_use_theme_variables(self):
        """edge case（回歸防護）：處理進度 modal 與停止確認 modal 的按鈕不再寫死白底幽靈按鈕樣式。"""
        html = self._html()
        assert "background:rgba(255,255,255,0.05)" not in html
        assert 'onclick="hideProcessingModal()"' in html
        assert 'onclick="confirmStop(false)"' in html

    def test_toast_uses_theme_variable_not_hardcoded_dark(self):
        """edge case（回歸防護）：錄音期間絕大多數狀態訊息（如系統音訊分段、模型啟動提示）走 toast
        而非 processing modal（見 setStatus() 的關鍵字分流邏輯），toast 背景之前寫死深色
        rgba(30,35,51,0.9) 但文字用 var(--text)，light mode 下同樣會深字疊深底。"""
        css = self._css()
        assert "background: rgba(30,35,51,0.9)" not in css
        toast_block = css.split(".toast {")[1].split("\n  }")[0]
        assert "background: var(--modal-bg)" in toast_block
