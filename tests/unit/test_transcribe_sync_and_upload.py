"""tests/unit/test_transcribe_sync_and_upload.py

補上 /api/transcribe-sync 與 Notion /upload 兩個核心端點的自動化測試。
兩者先前只有 build_notion_blocks() 純函式或空音訊路徑被人工 curl 驗證過，
端點本身（missing-token/missing-page-id/exception 分支、transcribe-sync 的
happy path 與逾時/例外路徑）從未被任何測試觸發。
"""
import base64
import os
import unittest
from unittest.mock import patch, MagicMock

import app as flask_app
from whisper_core import TranscriptionError


def _client():
    flask_app.app.config["TESTING"] = True
    return flask_app.app.test_client()


# ── /api/transcribe-sync ──────────────────────────────────────────

class TestTranscribeSync(unittest.TestCase):

    def test_empty_audio_returns_400(self):
        """空 audio_b64 → 400，對照 CLAUDE.md 手動 curl 驗證的同一個案例。"""
        resp = _client().post(
            "/api/transcribe-sync",
            json={"audio_b64": "", "model": "base", "language": "中文"},
        )
        self.assertEqual(resp.status_code, 400)
        data = resp.get_json()
        self.assertFalse(data["ok"])
        self.assertIn("沒有收到音訊", data["error"])

    def test_invalid_base64_returns_400(self):
        """audio_b64 不是合法 base64 → 400，不應該讓 base64.b64decode 的例外往外拋。"""
        resp = _client().post(
            "/api/transcribe-sync",
            json={"audio_b64": "!!!not-valid-base64!!!", "model": "base", "language": "en"},
        )
        self.assertEqual(resp.status_code, 400)
        data = resp.get_json()
        self.assertFalse(data["ok"])
        self.assertIn("格式錯誤", data["error"])

    def test_happy_path_returns_transcript(self):
        """mock run_whisper，驗證成功路徑回傳 text/language，狀態碼 200。"""
        fake_audio = base64.b64encode(b"\x00\x01fake-audio-bytes").decode()
        with patch("routes.run_whisper", return_value=("測試逐字稿", "zh", [])) as mock_run:
            resp = _client().post(
                "/api/transcribe-sync",
                json={"audio_b64": fake_audio, "model": "base", "language": "中文"},
            )
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertTrue(data["ok"])
        self.assertEqual(data["text"], "測試逐字稿")
        self.assertEqual(data["language"], "zh")
        # 語言別名轉換：「中文」應轉成 ISO code "zh" 才傳給 run_whisper
        mock_run.assert_called_once()
        called_language = mock_run.call_args[0][3]
        self.assertEqual(called_language, "zh")

    def test_transcription_error_returns_500(self):
        """run_whisper 拋 TranscriptionError → 500，錯誤訊息透傳給呼叫端。"""
        fake_audio = base64.b64encode(b"fake").decode()
        with patch("routes.run_whisper",
                   side_effect=TranscriptionError("MODEL_LOAD_FAILED", "模型載入失敗")):
            resp = _client().post(
                "/api/transcribe-sync",
                json={"audio_b64": fake_audio, "model": "base", "language": "en"},
            )
        self.assertEqual(resp.status_code, 500)
        data = resp.get_json()
        self.assertFalse(data["ok"])
        self.assertIn("模型載入失敗", data["error"])

    def test_unknown_language_alias_passthrough(self):
        """非別名表內的語言字串（例如已是 ISO code）原樣傳給 run_whisper，不誤轉。"""
        fake_audio = base64.b64encode(b"fake").decode()
        with patch("routes.run_whisper", return_value=("hello", "en", [])) as mock_run:
            resp = _client().post(
                "/api/transcribe-sync",
                json={"audio_b64": fake_audio, "model": "base", "language": "en"},
            )
        self.assertEqual(resp.status_code, 200)
        called_language = mock_run.call_args[0][3]
        self.assertEqual(called_language, "en")


# ── Notion /upload ─────────────────────────────────────────────────

class TestNotionUpload(unittest.TestCase):

    def setUp(self):
        self._saved = {k: os.environ.pop(k, None) for k in ("NOTION_TOKEN", "NOTION_PAGE_ID")}

    def tearDown(self):
        for k, v in self._saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)

    def test_missing_text_returns_400(self):
        resp = _client().post("/upload", json={"text": "", "language": "zh"})
        self.assertEqual(resp.status_code, 400)
        self.assertIn("沒有文字", resp.get_json()["error"])

    def test_missing_token_returns_400(self):
        resp = _client().post("/upload", json={"text": "hello", "language": "en"})
        self.assertEqual(resp.status_code, 400)
        self.assertIn("NOTION_TOKEN", resp.get_json()["error"])

    def test_missing_page_id_returns_400(self):
        os.environ["NOTION_TOKEN"] = "secret_test"
        resp = _client().post("/upload", json={"text": "hello", "language": "en"})
        self.assertEqual(resp.status_code, 400)
        self.assertIn("頁面 ID", resp.get_json()["error"])

    def test_happy_path_calls_notion_client(self):
        """mock notion_client.Client，驗證成功路徑呼叫 blocks.children.append 並回傳 blocks 數。"""
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        mock_client_instance = MagicMock()
        with patch("notion_client.Client", return_value=mock_client_instance) as mock_client_cls:
            resp = _client().post(
                "/upload",
                json={"text": "[00:00] 第一句\n[00:05] 第二句", "language": "zh"},
            )
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertTrue(data["ok"])
        self.assertGreater(data["blocks"], 0)
        mock_client_cls.assert_called_once_with(auth="secret_test")
        mock_client_instance.blocks.children.append.assert_called()

    def test_notion_api_exception_returns_500(self):
        """notion_client 呼叫拋例外 → 500，錯誤訊息透傳，不洩漏 stack trace。"""
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        mock_client_instance = MagicMock()
        mock_client_instance.blocks.children.append.side_effect = Exception("notion API rate limited")
        with patch("notion_client.Client", return_value=mock_client_instance):
            resp = _client().post(
                "/upload",
                json={"text": "hello world", "language": "en"},
            )
        self.assertEqual(resp.status_code, 500)
        self.assertIn("rate limited", resp.get_json()["error"])

    def test_page_id_from_request_overrides_env(self):
        """request body 帶 page_id 時優先於 NOTION_PAGE_ID 環境變數。"""
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "env-page-id"
        mock_client_instance = MagicMock()
        with patch("notion_client.Client", return_value=mock_client_instance):
            resp = _client().post(
                "/upload",
                json={"text": "hello", "language": "en", "page_id": "request-page-id"},
            )
        self.assertEqual(resp.status_code, 200)
        call_kwargs = mock_client_instance.blocks.children.append.call_args
        self.assertEqual(call_kwargs.kwargs.get("block_id"), "request-page-id")


if __name__ == "__main__":
    unittest.main()
