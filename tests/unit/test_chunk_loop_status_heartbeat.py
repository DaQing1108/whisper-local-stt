"""unit/test_chunk_loop_status_heartbeat.py — 長音檔切段轉錄時的 chunk 進度 heartbeat 測試。

Batch import 長音檔（CHUNK_SECONDS 一段）過去在每個 chunk 轉錄期間完全不 emit 任何
status 事件，導致 UI 進度長時間凍結，使用者誤判 App 掛掉。這裡驗證 run_whisper() 的
多 chunk 迴圈會在每個 chunk 開始轉錄前呼叫 event_sink("status", ...)，帶正確的
chunk index/total 資訊，讓 UI 能持續收到階段回饋。
"""
from unittest.mock import patch

import whisper_core
from tests.conftest import make_tone_wav
from whisper_core import run_whisper


class TestChunkLoopStatusHeartbeat:
    def test_emits_status_before_each_chunk_with_correct_index_and_total(self, monkeypatch):
        # CHUNK_SECONDS 壓到極小值，讓短音檔也能觸發多 chunk 路徑，不需真的產生數十分鐘音檔
        monkeypatch.setattr(whisper_core, "CHUNK_SECONDS", 0.5)

        events: list[tuple[str, dict]] = []

        def event_sink(event: str, data: dict) -> None:
            events.append((event, data))

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            return {"text": "測試內容", "language": "zh", "segments": []}

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file):
            run_whisper(
                make_tone_wav(440.0, 2.0), ".wav", "base", "zh",
                event_sink=event_sink,
            )

        status_events = [data for event, data in events if event == "status"]
        chunk_status_events = [
            data for data in status_events if "chunk" in data.get("msg", "")
        ]
        # 2 秒音檔切成 0.5 秒一段 → 4 個 chunk，每個 chunk 前都要有一次 heartbeat
        assert len(chunk_status_events) == 4
        for i, data in enumerate(chunk_status_events):
            assert f"chunk {i + 1}/4" in data["msg"]

    def test_single_chunk_path_unaffected_no_chunk_heartbeat(self, monkeypatch):
        # 音檔長度 <= CHUNK_SECONDS 時走單一分段路徑，不應該出現 chunk heartbeat 訊息
        events: list[tuple[str, dict]] = []

        def event_sink(event: str, data: dict) -> None:
            events.append((event, data))

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            return {"text": "測試內容", "language": "zh", "segments": []}

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file):
            run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                event_sink=event_sink,
            )

        chunk_status_events = [
            data for event, data in events
            if event == "status" and "chunk" in data.get("msg", "")
        ]
        assert chunk_status_events == []
