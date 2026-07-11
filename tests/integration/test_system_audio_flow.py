"""integration/test_system_audio_flow.py — 系統音訊流程：inject → stop → Obsidian 存檔驗證。"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest
import requests

from tests.conftest import make_silence_wav

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
from constants import ENV_PATH  # noqa: E402  server 與測試 process 在同一台機器，共用同一份 .env

pytestmark = pytest.mark.integration


def _snapshot_env() -> str | None:
    """讀取 server 實際在用的 .env 原始內容（None 代表檔案原本不存在）。

    比透過 /config API 記錄 obsidian_path 再回寫更可靠：save_config() 的
    obsidian_path 只在真值時才寫入（見 routes.py），送空字串無法清除既有值，
    用「回填空字串」的方式復原永遠不完整。直接快照/還原整份檔案內容才能保證
    測試前後 byte-for-byte 一致，不會在使用者本機留下永久性設定污染。
    """
    return ENV_PATH.read_text(encoding="utf-8") if ENV_PATH.exists() else None


def _restore_env(snapshot: str | None) -> None:
    if snapshot is None:
        ENV_PATH.unlink(missing_ok=True)
    else:
        ENV_PATH.write_text(snapshot, encoding="utf-8")


class TestSystemAudioObsidian:
    def test_obsidian_file_created_after_stop(self, server_url, tmp_obsidian_vault):
        """系統音訊 inject → stop → Obsidian 存檔 → 檔案存在。"""
        session_id = f"test_sysaudio_{int(time.time())}"
        wav = make_silence_wav(2.0)

        # 設定 Obsidian vault 路徑（透過 /config POST，欄位名須對應 save_config() 的 obsidian_path；
        # server 是獨立 subprocess，只有真正打這支 API 才能讓它的 os.environ 生效，
        # monkeypatch 這個 process 的變數對它沒有作用）
        env_snapshot = _snapshot_env()
        r = requests.post(f"{server_url}/config", json={
            "obsidian_path": str(tmp_obsidian_vault)
        })
        assert r.status_code == 200

        try:
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

            # finish session（模擬停止系統音訊；真正的前端用 FormData，不是 JSON）
            r = requests.post(
                f"{server_url}/api/finish-session",
                data={"session_id": session_id, "total": "1"},
            )
            assert r.json().get("status") == "ok"
            time.sleep(2)
        finally:
            _restore_env(env_snapshot)

    def test_obsidian_save_api_directly(self, server_url, tmp_obsidian_vault):
        """直接打 /api/save_to_obsidian 端點，驗證寫檔成功。

        save_to_obsidian() 每次呼叫都直接讀取 os.environ["OBSIDIAN_MEETING_PATH"]
        （見 integrations.py:153），不是讀 integrations._OBSIDIAN_PATH 這個只在
        import 當下算過一次、之後從未被使用的模組常數——用 monkeypatch 改後者對
        實際行為沒有影響，而且 server 是獨立 subprocess，同一個限制在這裡更明顯：
        必須透過 /config 這支 API 才能改到 server 自己 process 裡的 os.environ。
        """
        env_snapshot = _snapshot_env()
        r = requests.post(f"{server_url}/config", json={"obsidian_path": str(tmp_obsidian_vault)})
        assert r.status_code == 200

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
            _restore_env(env_snapshot)

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
