"""tests/unit/test_diarize_integration.py

說話者分離主流程整合測試：
- whisper_core.run_whisper keep_wav 參數行為
- diarize.apply_diarization 正確性
- routes /api/diarize AC 驗收
"""
import os
import wave
import struct
import tempfile
import unittest
from unittest.mock import patch, MagicMock
from pathlib import Path


# ── helpers ────────────────────────────────────────────────────

def _make_wav_bytes(duration_sec: float = 0.1) -> bytes:
    """建立最小有效 WAV bytes（16kHz mono PCM16）。"""
    sample_rate = 16000
    num_samples = int(sample_rate * duration_sec)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        with wave.open(f.name, 'w') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(struct.pack(f"<{num_samples}h", *([0] * num_samples)))
        f.seek(0)
        data = f.read()
    Path(f.name).unlink(missing_ok=True)
    return data


# ── AC-4 whisper_core.run_whisper keep_wav ─────────────────────

class TestKeepWav(unittest.TestCase):

    def test_keep_wav_false_is_default(self):
        """keep_wav 預設為 False，確保舊呼叫者不受影響。"""
        import inspect
        from whisper_core import run_whisper
        params = inspect.signature(run_whisper).parameters
        self.assertEqual(params["keep_wav"].default, False)

    def test_keep_wav_flag_exists_in_signature(self):
        """AC-4 結構性驗證：run_whisper 接受 keep_wav 參數。"""
        import inspect
        from whisper_core import run_whisper
        params = inspect.signature(run_whisper).parameters
        self.assertIn("keep_wav", params, "run_whisper 應有 keep_wav 參數")
        self.assertEqual(params["keep_wav"].default, False, "keep_wav 預設應為 False")


# ── apply_diarization ──────────────────────────────────────────

class TestApplyDiarization(unittest.TestCase):

    def _make_segments(self):
        from diarize import Segment
        return [
            Segment(0.0, 2.0, "SPEAKER_00"),
            Segment(2.5, 5.0, "SPEAKER_01"),
            Segment(5.5, 8.0, "SPEAKER_00"),
        ]

    def test_empty_segments_returns_original(self):
        """沒有 segments 時原樣回傳。"""
        from diarize import apply_diarization
        result = apply_diarization("hello world", [])
        self.assertEqual(result, "hello world")

    def test_speaker_labels_inserted_with_timestamps(self):
        """有時間戳記的逐字稿 + segments → 兩位說話者標籤都出現。"""
        from diarize import apply_diarization
        # [MM:SS] 格式觸發時間戳記匹配
        transcript = "[00:00] 第一段內容\n[00:03] 第二段內容"
        segs = self._make_segments()  # SPEAKER_00 0-2s, SPEAKER_01 2.5-5s
        result = apply_diarization(transcript, segs)
        self.assertIn("說話者 A", result)
        self.assertIn("說話者 B", result)

    def test_speaker_map_two_speakers_distinct(self):
        """兩位說話者映射不同標籤（A ≠ B）。"""
        from diarize import apply_diarization, Segment
        segs = [Segment(0.0, 1.0, "SPEAKER_00"), Segment(2.0, 3.0, "SPEAKER_01")]
        transcript = "[00:00] 第一句\n[00:02] 第二句"
        result = apply_diarization(transcript, segs)
        self.assertIn("說話者 A", result)
        self.assertIn("說話者 B", result)
        self.assertNotIn("說話者 C", result)

    def test_whisper_segments_mode_two_speakers(self):
        """whisper_segments 精確模式：依時間中點對應說話者，正確插入兩個標籤。"""
        from diarize import apply_diarization, Segment
        segs = [Segment(0.0, 3.0, "SPEAKER_00"), Segment(3.5, 6.0, "SPEAKER_01")]
        w_segs = [
            {"text": "第一句話", "start": 0.0, "end": 2.5},
            {"text": "第二句話", "start": 4.0, "end": 5.5},
        ]
        result = apply_diarization("", segs, whisper_segments=w_segs)
        self.assertIn("說話者 A", result)
        self.assertIn("說話者 B", result)
        self.assertIn("第一句話", result)
        self.assertIn("第二句話", result)
        # A 應在 B 之前
        self.assertLess(result.index("說話者 A"), result.index("說話者 B"))

    def test_empty_transcript_returns_empty(self):
        """空逐字稿 + segments → labeled 仍為空字串。"""
        from diarize import apply_diarization
        segs = self._make_segments()
        result = apply_diarization("", segs)
        self.assertEqual(result, "")


# ── AC-5 routes /api/diarize（mock pyannote）──────────────────

class TestDiarizeRoute(unittest.TestCase):

    def setUp(self):
        os.environ.setdefault("HF_TOKEN", "hf_test_token")

    def test_diarize_route_path_outside_tmp_blocked(self):
        """audio_path 在 tmp 目錄外時回傳 400（path traversal 防護）。"""
        import app as flask_app
        client = flask_app.app.test_client()
        resp = client.post(
            "/api/diarize",
            json={"audio_path": "/etc/passwd", "transcript": "test"},
            content_type="application/json",
        )
        self.assertEqual(resp.status_code, 400)
        self.assertIn("error", resp.get_json())

    def test_diarize_route_missing_audio_path(self):
        """audio_path 檔案不存在時回傳 400。"""
        import app as flask_app
        import tempfile
        client = flask_app.app.test_client()
        resp = client.post(
            "/api/diarize",
            json={"audio_path": tempfile.gettempdir() + "/nonexistent_xyzzy.wav", "transcript": "test"},
            content_type="application/json",
        )
        self.assertEqual(resp.status_code, 400)
        self.assertIn("error", resp.get_json())

    def test_diarize_route_no_hf_token(self):
        """HF_TOKEN 未設定時回傳 400。"""
        import app as flask_app
        client = flask_app.app.test_client()
        original = os.environ.pop("HF_TOKEN", None)
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                f.write(_make_wav_bytes())
                wav_path = f.name
            resp = client.post(
                "/api/diarize",
                json={"audio_path": wav_path, "transcript": "test"},
                content_type="application/json",
            )
            self.assertEqual(resp.status_code, 400)
        finally:
            Path(wav_path).unlink(missing_ok=True)
            if original:
                os.environ["HF_TOKEN"] = original


if __name__ == "__main__":
    unittest.main()
