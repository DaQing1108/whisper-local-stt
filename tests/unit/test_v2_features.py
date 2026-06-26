"""Tests for v2.0 features: export endpoint, config obsidian_path, health TCC field."""
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


# ── Export endpoint ──────────────────────────────────────────────────────────

class TestExportEndpoint:
    def test_export_no_transcript_returns_404(self, client):
        """AC-4: /api/export returns 404 when no transcript available."""
        import routes
        routes._last_transcript = None
        r = client.get("/api/export?format=txt")
        assert r.status_code == 404

    def test_export_txt(self, client):
        """AC-3: format=txt returns plain text with correct Content-Disposition."""
        import routes
        routes._last_transcript = {"text": "hello world", "segments": [], "lang": "zh"}
        r = client.get("/api/export?format=txt")
        assert r.status_code == 200
        assert b"hello world" in r.data
        assert "transcript.txt" in r.headers.get("Content-Disposition", "")

    def test_export_md(self, client):
        """AC-2: format=md returns markdown with correct Content-Disposition."""
        import routes
        routes._last_transcript = {"text": "hello world", "segments": [], "lang": "zh"}
        r = client.get("/api/export?format=md")
        assert r.status_code == 200
        assert "transcript.md" in r.headers.get("Content-Disposition", "")

    def test_export_srt_with_segments(self, client):
        """AC-1: format=srt returns valid SRT with timecodes."""
        import routes
        routes._last_transcript = {
            "text": "hello",
            "segments": [{"start": 0.0, "end": 2.5, "text": "hello"}],
            "lang": "zh",
        }
        r = client.get("/api/export?format=srt")
        assert r.status_code == 200
        body = r.data.decode()
        assert "00:00:00,000 --> 00:00:02,500" in body
        assert "transcript.srt" in r.headers.get("Content-Disposition", "")

    def test_export_srt_no_segments_fallback(self, client):
        """format=srt without segments falls back to single entry."""
        import routes
        routes._last_transcript = {"text": "fallback text", "segments": [], "lang": "zh"}
        r = client.get("/api/export?format=srt")
        assert r.status_code == 200
        assert b"fallback text" in r.data

    def test_export_invalid_format(self, client):
        """Unknown format returns 400."""
        import routes
        routes._last_transcript = {"text": "x", "segments": [], "lang": "zh"}
        r = client.get("/api/export?format=pdf")
        assert r.status_code == 400


# ── Config obsidian_path ─────────────────────────────────────────────────────

class TestConfigObsidianPath:
    def test_get_config_includes_obsidian_path(self, client):
        """AC-5: GET /config includes obsidian_path field."""
        os.environ["OBSIDIAN_MEETING_PATH"] = "/tmp/obsidian_test"
        try:
            r = client.get("/config")
            assert r.status_code == 200
            data = r.get_json()
            assert "obsidian_path" in data
            assert data["obsidian_path"] == "/tmp/obsidian_test"
        finally:
            os.environ.pop("OBSIDIAN_MEETING_PATH", None)

    def test_save_config_obsidian_path_tilde_expansion(self, client, tmp_path):
        """AC-8: obsidian_path with ~ is expanded before writing to .env."""
        from unittest.mock import patch
        import constants
        fake_env = tmp_path / ".env"
        with patch.object(constants, "ENV_PATH", fake_env), \
             patch("routes._ENV_PATH", fake_env):
            r = client.post("/config", json={"obsidian_path": "~/meetings"})
            assert r.status_code == 200
            content = fake_env.read_text()
            home = os.path.expanduser("~")
            assert f"{home}/meetings" in content

    def test_save_config_obsidian_path_sets_environ(self, client, tmp_path):
        """AC-6: After POST /config, os.environ reflects the new obsidian_path."""
        from unittest.mock import patch
        import constants
        fake_env = tmp_path / ".env"
        test_path = str(tmp_path / "obsidian_vault")
        with patch.object(constants, "ENV_PATH", fake_env), \
             patch("routes._ENV_PATH", fake_env):
            client.post("/config", json={"obsidian_path": test_path})
            assert os.environ.get("OBSIDIAN_MEETING_PATH") == test_path


# ── Health TCC field ─────────────────────────────────────────────────────────

class TestHealthTCCField:
    def test_health_includes_permissions_field(self, client):
        """AC-7: GET /api/config/health includes permissions dict."""
        r = client.get("/api/config/health")
        assert r.status_code == 200
        data = r.get_json()
        assert "permissions" in data
        perms = data["permissions"]
        assert "screen_recording" in perms
        assert "microphone" in perms
        assert perms["screen_recording"] in ("granted", "denied", "unknown")
        assert perms["microphone"] in ("granted", "denied", "unknown")


# ── Validate obsidian path endpoint ─────────────────────────────────────────

class TestValidateObsidianPath:
    def test_valid_directory(self, client, tmp_path):
        r = client.post("/api/validate-obsidian-path", json={"path": str(tmp_path)})
        assert r.status_code == 200
        assert r.get_json()["ok"] is True

    def test_nonexistent_directory(self, client):
        r = client.post("/api/validate-obsidian-path",
                        json={"path": "/nonexistent_path_xyz_123"})
        assert r.status_code == 200
        assert r.get_json()["ok"] is False

    def test_empty_path(self, client):
        r = client.post("/api/validate-obsidian-path", json={"path": ""})
        assert r.status_code == 400
