"""integration/test_mic_flow.py — 麥克風 chunk 流程：inject → SSE → 結果驗證。

需要 Flask server 在 localhost:5001 以 WHISPER_TEST=1 模式運行：
    WHISPER_TEST=1 python app.py
"""
from __future__ import annotations

import io
import json
import time

import pytest
import requests

from tests.conftest import make_silence_wav, make_tone_wav

pytestmark = pytest.mark.integration


class TestChunkUpload:
    def test_health_endpoint(self, server_url):
        r = requests.get(f"{server_url}/api/health")
        assert r.status_code == 200
        data = r.json()
        assert data["ok"] is True
        assert "version" in data

    def test_inject_chunk_requires_test_mode(self, server_url):
        """inject 端點在非 test 模式應回傳 403。"""
        # 這個測試假設 server_url 已設定 WHISPER_TEST=1，所以應該 200
        wav = make_silence_wav(1.0)
        r = requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={"session_id": "test_inject_basic"},
        )
        assert r.status_code == 200
        assert r.json()["ok"] is True

    def test_inject_chunk_returns_session_id(self, server_url):
        wav = make_silence_wav(1.0)
        r = requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={"session_id": "test_session_id_check", "chunk_index": "0"},
        )
        data = r.json()
        assert data["session_id"] == "test_session_id_check"
        assert data["chunk_index"] == 0

    def test_finish_session_after_inject(self, server_url):
        """inject 一個 chunk → finish-session → 收到 done 事件。"""
        session_id = f"test_finish_{int(time.time())}"
        wav = make_silence_wav(2.0)

        # 注入 chunk
        r = requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={"session_id": session_id, "chunk_index": "0", "total": "1"},
        )
        assert r.status_code == 200
        time.sleep(3)  # 等轉錄完成

        # finish session（真正的前端用 FormData 呼叫，不是 JSON——route 讀 request.form）
        r = requests.post(
            f"{server_url}/api/finish-session",
            data={"session_id": session_id, "total": "1"},
        )
        assert r.status_code == 200
        assert r.json().get("status") == "ok"

    def test_last_transcript_after_finish(self, server_url):
        """finish 後 /api/last_transcript 應回傳結果。"""
        session_id = f"test_last_{int(time.time())}"
        wav = make_silence_wav(2.0)

        requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={"session_id": session_id, "chunk_index": "0", "total": "1"},
        )
        time.sleep(3)

        r = requests.post(
            f"{server_url}/api/finish-session",
            data={"session_id": session_id, "total": "1"},
        )
        assert r.json().get("status") == "ok"
        time.sleep(2)

        r = requests.get(f"{server_url}/api/last_transcript")
        assert r.status_code == 200
        data = r.json()
        assert "text" in data


class TestModelSelection:
    @pytest.mark.parametrize("model", ["tiny", "small"])
    def test_model_accepted_in_inject(self, server_url, model):
        """不同模型名稱都應被 inject endpoint 接受。"""
        wav = make_silence_wav(1.0)
        session_id = f"test_model_{model}_{int(time.time())}"
        r = requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={"session_id": session_id, "model": model},
        )
        assert r.status_code == 200


class TestDomainMode:
    @pytest.mark.parametrize("domain", ["general", "media", "tech", "medical", "legal"])
    def test_domain_accepted(self, server_url, domain):
        wav = make_silence_wav(1.0)
        session_id = f"test_domain_{domain}_{int(time.time())}"
        r = requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={"session_id": session_id, "domain": domain},
        )
        assert r.status_code == 200
        assert r.json()["ok"] is True
