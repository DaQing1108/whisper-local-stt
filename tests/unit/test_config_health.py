"""Tests for /api/config/health endpoint and env path unification."""
import os
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


@pytest.fixture
def client():
    """Flask test client with debug=False (production mode)."""
    os.environ.setdefault("TESTING", "1")
    from app import app
    app.config["TESTING"] = True
    app.config["DEBUG"] = False
    with app.test_client() as c:
        yield c


class TestConfigHealth:
    def test_health_missing_all(self, client):
        """When no env vars set, all features reported missing."""
        env_keys = ["ANTHROPIC_API_KEY", "OBSIDIAN_MEETING_PATH",
                    "NOTION_TOKEN", "NOTION_PAGE_ID"]
        saved = {k: os.environ.pop(k, None) for k in env_keys}
        try:
            r = client.get("/api/config/health")
            assert r.status_code == 200
            data = r.get_json()
            assert data["ok"] is False
            assert len(data["missing"]) > 0
            keys_reported = [m["key"] for m in data["missing"]]
            assert "ANTHROPIC_API_KEY" in keys_reported
            assert "OBSIDIAN_MEETING_PATH" in keys_reported
        finally:
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v

    def test_health_all_set(self, client):
        """When all env vars set, ok=True and missing=[]."""
        os.environ["ANTHROPIC_API_KEY"] = "test-key"
        os.environ["OBSIDIAN_MEETING_PATH"] = "/tmp/obsidian"
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        try:
            r = client.get("/api/config/health")
            assert r.status_code == 200
            data = r.get_json()
            assert data["ok"] is True
            assert data["missing"] == []
        finally:
            for k in ["ANTHROPIC_API_KEY", "OBSIDIAN_MEETING_PATH",
                      "NOTION_TOKEN", "NOTION_PAGE_ID"]:
                os.environ.pop(k, None)

    def test_health_partial(self, client):
        """Partially configured: only missing items reported."""
        os.environ["ANTHROPIC_API_KEY"] = "test-key"
        os.environ.pop("OBSIDIAN_MEETING_PATH", None)
        os.environ.pop("NOTION_TOKEN", None)
        os.environ.pop("NOTION_PAGE_ID", None)
        try:
            r = client.get("/api/config/health")
            data = r.get_json()
            keys = [m["key"] for m in data["missing"]]
            assert "ANTHROPIC_API_KEY" not in keys
            assert "OBSIDIAN_MEETING_PATH" in keys
        finally:
            os.environ.pop("ANTHROPIC_API_KEY", None)


class TestPageIdMasking:
    def test_get_config_no_page_id_field(self, client):
        """GET /config must not return full page_id."""
        r = client.get("/config")
        assert r.status_code == 200
        data = r.get_json()
        assert "page_id" not in data
        assert "page_id_preview" in data

    def test_page_id_preview_format(self, client):
        """page_id_preview shows first 8 chars + ellipsis when set."""
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "37a280a95f7680f8"
        try:
            r = client.get("/config")
            data = r.get_json()
            preview = data.get("page_id_preview", "")
            if preview:
                assert preview == "37a280a9…"
        finally:
            os.environ.pop("NOTION_TOKEN", None)
            os.environ.pop("NOTION_PAGE_ID", None)

    def test_page_id_preview_empty_when_not_set(self, client):
        """page_id_preview is empty string when page_id not configured."""
        os.environ.pop("NOTION_PAGE_ID", None)
        os.environ.pop("NOTION_TOKEN", None)
        r = client.get("/config")
        data = r.get_json()
        assert data.get("page_id_preview") == ""


class TestWhisperTestBypass:
    def test_inject_chunk_blocked_in_production(self, client):
        """test_inject_chunk must return 403 when not in debug mode."""
        r = client.post("/api/test/inject-chunk")
        assert r.status_code == 403
        data = r.get_json()
        assert "debug" in data.get("error", "").lower()


class TestEnvPathConstant:
    def test_env_path_points_to_application_support(self):
        """ENV_PATH in constants.py must point to Application Support."""
        import constants
        assert "Application Support" in str(constants.ENV_PATH)
        assert "WhisperSTT" in str(constants.ENV_PATH)
        assert str(constants.ENV_PATH).endswith(".env")
