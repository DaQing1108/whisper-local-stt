"""Tests for Obsidian plugin support: /api/ping endpoint and CORS headers."""
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


class TestPingEndpoint:
    def test_ping_returns_200(self, client):
        res = client.get("/api/ping")
        assert res.status_code == 200

    def test_ping_returns_whisper_stt_app_id(self, client):
        data = client.get("/api/ping").get_json()
        assert data["app"] == "whisper-stt"

    def test_ping_returns_version(self, client):
        data = client.get("/api/ping").get_json()
        assert "version" in data
        assert isinstance(data["version"], str)
        assert len(data["version"]) > 0


class TestCorsHeaders:
    def test_cors_allows_obsidian_origin(self, client):
        res = client.get(
            "/api/ping",
            headers={"Origin": "app://obsidian.md"},
        )
        assert res.status_code == 200
        assert res.headers.get("Access-Control-Allow-Origin") == "app://obsidian.md"

    def test_cors_preflight_obsidian_origin(self, client):
        res = client.options(
            "/api/ping",
            headers={
                "Origin": "app://obsidian.md",
                "Access-Control-Request-Method": "GET",
            },
        )
        assert res.status_code in (200, 204)

    def test_cors_allows_localhost_origin(self, client):
        res = client.get(
            "/api/ping",
            headers={"Origin": "http://localhost"},
        )
        assert res.status_code == 200
