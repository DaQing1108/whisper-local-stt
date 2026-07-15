"""Tests for canonical summary prompt generation."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


def test_build_summary_prompts_forbids_clarifying_questions():
    import integrations

    system_prompt, user_message = integrations.build_summary_prompts("Project update by Alex.")

    assert "不要反問使用者" in system_prompt
    assert "不要要求補資料" in system_prompt
    assert "未知" in system_prompt
    assert "不要提問" in user_message
    assert "逐字稿如下" in user_message


def test_build_meeting_summary_uses_app_summary_prompt(monkeypatch):
    import integrations

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    captured = {}

    def fake_call_llm(system_prompt: str, user_message: str) -> str:
        captured["system_prompt"] = system_prompt
        captured["user_message"] = user_message
        return "## 摘要\n測試摘要"

    monkeypatch.setattr(integrations, "_call_llm", fake_call_llm)

    provider, summary = integrations.build_meeting_summary("會議提到 summary editor 先上線。")

    assert provider == "anthropic"
    assert summary == "## 摘要\n測試摘要"
    assert "不要反問使用者" in captured["system_prompt"]
    assert "不要提問" in captured["user_message"]
    assert "meeting-notes" not in captured["system_prompt"].lower()


def test_destination_summaries_use_distinct_prompts(monkeypatch):
    import integrations

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    captured = []
    monkeypatch.setattr(integrations, "_call_llm", lambda system, user: captured.append((system, user)) or "摘要")

    integrations.build_destination_summary("同一份逐字稿", "obsidian")
    integrations.build_destination_summary("同一份逐字稿", "notion")

    assert "知識庫" in captured[0][0]
    assert "專案協作" in captured[1][0]
    assert captured[0][0] != captured[1][0]
