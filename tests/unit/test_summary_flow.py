"""Tests for summary state, edit priority, and Obsidian summary output."""
from __future__ import annotations

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


@pytest.fixture(autouse=True)
def reset_summary_state(monkeypatch):
    import routes
    import integrations
    routes._last_summary = None
    monkeypatch.setattr(integrations, "build_destination_summary", lambda text, destination: ("anthropic", f"{destination} 專屬摘要：{text}"))
    yield
    routes._last_summary = None


class TestSummaryState:
    def test_effective_summary_prefers_generated_when_not_edited(self):
        import routes
        state = routes._summary_payload(
            status="ready",
            provider="anthropic",
            generated_summary="AI draft",
            edited_summary="",
            is_summary_edited=False,
        )
        assert routes._effective_summary(state) == "AI draft"

    def test_effective_summary_prefers_edited_when_present(self):
        import routes
        state = routes._summary_payload(
            status="ready",
            provider="anthropic",
            generated_summary="AI draft",
            edited_summary="Human edited",
            is_summary_edited=True,
        )
        assert routes._effective_summary(state) == "Human edited"

    def test_last_summary_endpoint_returns_false_when_empty(self, client):
        r = client.get("/api/last_summary")
        assert r.status_code == 200
        assert r.get_json()["ok"] is False

    def test_last_summary_endpoint_returns_effective_summary(self, client):
        import routes
        routes._save_last_summary(routes._summary_payload(
            status="ready",
            provider="anthropic",
            generated_summary="AI draft",
            edited_summary="",
            is_summary_edited=False,
        ))
        r = client.get("/api/last_summary")
        assert r.status_code == 200
        data = r.get_json()
        assert data["ok"] is True
        assert data["effective_summary"] == "AI draft"


class TestUpdateSummary:
    def test_update_summary_returns_404_without_existing_summary(self, client):
        r = client.post("/api/update_summary", json={"edited_summary": "Edited"})
        assert r.status_code == 404

    def test_update_summary_marks_summary_edited(self, client):
        import routes
        routes._save_last_summary(routes._summary_payload(
            status="ready",
            provider="anthropic",
            generated_summary="AI draft",
            edited_summary="",
            is_summary_edited=False,
        ))
        r = client.post("/api/update_summary", json={"edited_summary": "Human edited"})
        assert r.status_code == 200
        data = r.get_json()
        assert data["effective_summary"] == "Human edited"
        assert data["edited_summary"] == "Human edited"
        assert data["is_summary_edited"] is True

    def test_update_summary_reset_to_generated_clears_edited_flag(self, client):
        import routes
        routes._save_last_summary(routes._summary_payload(
            status="ready",
            provider="anthropic",
            generated_summary="AI draft",
            edited_summary="Human edited",
            is_summary_edited=True,
        ))
        r = client.post("/api/update_summary", json={"edited_summary": "AI draft"})
        assert r.status_code == 200
        data = r.get_json()
        assert data["effective_summary"] == "AI draft"
        assert data["edited_summary"] == ""
        assert data["is_summary_edited"] is False


class TestSaveToObsidianUsesEffectiveSummary:
    def test_save_to_obsidian_route_writes_separate_transcript_and_destination_summary(self, client, tmp_obsidian_vault, monkeypatch):
        import routes
        import integrations

        monkeypatch.setenv("OBSIDIAN_MEETING_PATH", str(tmp_obsidian_vault))
        routes._save_last_summary(routes._summary_payload(
            status="ready",
            provider="anthropic",
            generated_summary="AI draft",
            edited_summary="Human edited",
            is_summary_edited=True,
        ))

        r = client.post("/api/save_to_obsidian", json={
            "text": "這是一段測試逐字稿",
            "lang": "zh",
            "meta": {},
        })
        assert r.status_code == 200
        data = r.get_json()
        assert data["ok"] is True
        meeting_path = Path(data["path"])
        contents = meeting_path.read_text(encoding="utf-8")
        assert "## 逐字稿" in contents
        assert "這是一段測試逐字稿" in contents
        assert "Human edited" not in contents
        summary_path = Path(data["summary_path"])
        assert summary_path.exists()
        assert 'meeting_id: "' in summary_path.read_text(encoding="utf-8")
        assert "obsidian 專屬摘要：這是一段測試逐字稿" in summary_path.read_text(encoding="utf-8")

    def test_second_publish_updates_the_original_meeting_file(self, client, tmp_obsidian_vault, monkeypatch):
        import routes

        monkeypatch.setenv("OBSIDIAN_MEETING_PATH", str(tmp_obsidian_vault))
        routes._save_last_summary(routes._summary_payload(
            status="ready",
            meeting_id="meeting-123",
            generated_summary="初版摘要",
        ))
        first = client.post("/api/save_to_obsidian", json={
            "text": "初版逐字稿", "summary": "初版摘要", "lang": "zh", "meeting_id": "meeting-123", "meta": {},
        })
        assert first.status_code == 200
        first_data = first.get_json()
        second = client.post("/api/save_to_obsidian", json={
            "text": "修正版逐字稿", "summary": "修正版摘要", "lang": "zh", "meeting_id": "meeting-123", "meta": {},
        })
        assert second.status_code == 200
        second_data = second.get_json()
        assert second_data["updated"] is True
        assert second_data["path"] == first_data["path"]
        contents = Path(second_data["path"]).read_text(encoding="utf-8")
        assert "meeting_id: \"meeting-123\"" in contents
        assert "修正版逐字稿" in contents
        assert "初版逐字稿" not in contents
        summary_contents = Path(second_data["summary_path"]).read_text(encoding="utf-8")
        assert "obsidian 專屬摘要：修正版逐字稿" in summary_contents
        assert "修正版摘要" not in summary_contents

    def test_stale_meeting_id_does_not_create_a_new_file(self, client, tmp_obsidian_vault, monkeypatch):
        import routes

        monkeypatch.setenv("OBSIDIAN_MEETING_PATH", str(tmp_obsidian_vault))
        routes._save_last_summary(routes._summary_payload(status="ready", meeting_id="current-meeting"))
        response = client.post("/api/save_to_obsidian", json={
            "text": "舊 session 內容", "lang": "zh", "meeting_id": "stale-meeting", "meta": {},
        })
        assert response.status_code == 409
        assert list(tmp_obsidian_vault.glob("*.md")) == []

    def test_legacy_summary_state_is_upgraded_on_first_publish(self, client, tmp_obsidian_vault, monkeypatch):
        import routes

        monkeypatch.setenv("OBSIDIAN_MEETING_PATH", str(tmp_obsidian_vault))
        routes._save_last_summary(routes._summary_payload(status="ready", generated_summary="既有摘要"))
        first = client.post("/api/save_to_obsidian", json={
            "text": "既有逐字稿", "lang": "zh", "meta": {},
        })
        assert first.status_code == 200
        meeting_id = first.get_json()["meeting_id"]
        assert meeting_id
        assert routes._last_summary["meeting_id"] == meeting_id
        second = client.post("/api/save_to_obsidian", json={
            "text": "更新後逐字稿", "lang": "zh", "meta": {},
        })
        assert second.status_code == 200
        assert second.get_json()["updated"] is True
        assert second.get_json()["path"] == first.get_json()["path"]
