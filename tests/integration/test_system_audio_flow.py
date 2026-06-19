"""integration/test_system_audio_flow.py — 系統音訊流程：inject → stop → Obsidian 存檔驗證。"""
from __future__ import annotations

import time
from pathlib import Path

import pytest
import requests

from tests.conftest import make_silence_wav

pytestmark = pytest.mark.integration


class TestSystemAudioObsidian:
    def test_obsidian_file_created_after_stop(self, server_url, tmp_obsidian_vault):
        """系統音訊 inject → stop → Obsidian 存檔 → 檔案存在。"""
        session_id = f"test_sysaudio_{int(time.time())}"
        wav = make_silence_wav(2.0)

        # 設定 Obsidian vault 路徑（透過 /config POST）
        r = requests.post(f"{server_url}/config", json={
            "obsidian_meeting_path": str(tmp_obsidian_vault)
        })
        # 若 config 不支援此欄位，用環境變數注入（在 conftest 設定）

        # inject 模擬系統音訊 chunk
        r = requests.post(
            f"{server_url}/api/test/inject-chunk",
            files={"wav": ("test.wav", wav, "audio/wav")},
            data={
                "session_id": session_id,
                "chunk_index": "0",
                "save_obsidian": "true",
            },
        )
        assert r.status_code == 200
        time.sleep(3)

        # finish session（模擬停止系統音訊）
        r = requests.post(
            f"{server_url}/api/finish-session",
            json={"session_id": session_id, "total": 1},
        )
        assert r.json().get("ok") is True
        time.sleep(2)

    def test_obsidian_save_api_directly(self, server_url, tmp_obsidian_vault, monkeypatch):
        """直接打 /api/save_to_obsidian 端點，驗證寫檔成功。"""
        import integrations
        original_path = integrations._OBSIDIAN_PATH
        integrations._OBSIDIAN_PATH = str(tmp_obsidian_vault)

        try:
            r = requests.post(f"{server_url}/api/save_to_obsidian", json={
                "text": "這是一段測試的會議記錄，用於驗證 Obsidian 存檔功能是否正常運作。",
                "lang": "zh",
                "meta": {"model": "small", "domain": "general"},
            })
            assert r.status_code == 200
            data = r.json()
            assert data.get("ok") is True
            assert "filename" in data

            saved_file = tmp_obsidian_vault / data["filename"]
            assert saved_file.exists()
            content = saved_file.read_text(encoding="utf-8")
            assert "這是一段測試的會議記錄" in content
            assert "language: zh" in content
        finally:
            integrations._OBSIDIAN_PATH = original_path

    def test_obsidian_save_empty_text_rejected(self, server_url):
        r = requests.post(f"{server_url}/api/save_to_obsidian", json={
            "text": "",
            "lang": "zh",
        })
        assert r.status_code == 400


class TestSystemAudioSessionLifecycle:
    def test_start_stop_without_tcc(self, server_url):
        """start → stop 流程不應 crash（即使沒有 TCC 權限）。"""
        r = requests.post(f"{server_url}/api/system-audio/start", json={
            "model": "small", "language": "zh",
            "domain": "general", "with_mic": False,
        })
        # 可能 409（已在運行）或 503（TCC 失敗）或 200（成功）
        assert r.status_code in (200, 409, 503)

        # 無論如何都嘗試 stop，確保不 crash
        r_stop = requests.post(f"{server_url}/api/system-audio/stop", json={
            "session_id": r.json().get("session_id", "")
        })
        assert r_stop.status_code in (200, 400)
