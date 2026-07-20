"""tests/unit/test_transcribe_sync_and_upload.py

補上 /api/transcribe-sync 與 Notion /upload 兩個核心端點的自動化測試。
兩者先前只有 build_notion_blocks() 純函式或空音訊路徑被人工 curl 驗證過，
端點本身（missing-token/missing-page-id/exception 分支、transcribe-sync 的
happy path 與逾時/例外路徑）從未被任何測試觸發。
"""
import base64
import io
import os
import unittest
from unittest.mock import patch, MagicMock

import app as flask_app
import routes
from transcription_service import TranscriptionResult
from whisper_core import TranscriptionError


def _client():
    flask_app.app.config["TESTING"] = True
    return flask_app.app.test_client()


class _ImmediateThread:
    def __init__(self, target, args=(), kwargs=None, **_options):
        self._target = target
        self._args = args
        self._kwargs = kwargs or {}

    def start(self):
        self._target(*self._args, **self._kwargs)


class TestTranscribeUpload(unittest.TestCase):
    def test_file_upload_uses_transcription_service_contract(self):
        service_result = TranscriptionResult("上傳逐字稿", "zh", {"segments": []})
        with patch.object(routes._transcription_service, "transcribe", return_value=service_result) as mock_run, \
             patch("routes.threading.Thread", _ImmediateThread), \
             patch("routes._save_last_transcript"), \
             patch("routes._start_summary_generation"), \
             patch("routes._sse.broadcast"):
            resp = _client().post(
                "/transcribe",
                data={
                    "audio": (io.BytesIO(b"fake-audio"), "sample.wav"),
                    "model": "base",
                    "language": "zh",
                    "domain": "tech",
                },
                content_type="multipart/form-data",
            )

        self.assertEqual(resp.status_code, 202)
        self.assertTrue(resp.get_json()["job_id"])
        service_request = mock_run.call_args.args[0]
        self.assertEqual(service_request.ext, ".wav")
        self.assertEqual(service_request.model_name, "base")
        self.assertEqual(service_request.options["domain"], "tech")
        self.assertIsNone(routes._job_registry.get(resp.get_json()["job_id"]))

    def test_cancel_active_file_job(self):
        token = routes._job_registry.register("active-job")
        try:
            resp = _client().post("/api/jobs/active-job/cancel")
            self.assertEqual(resp.status_code, 202)
            self.assertEqual(resp.get_json()["status"], "cancelling")
            self.assertTrue(token.is_cancelled)
        finally:
            routes._job_registry.unregister("active-job")

    def test_cancel_unknown_job_returns_404(self):
        resp = _client().post("/api/jobs/missing-job/cancel")
        self.assertEqual(resp.status_code, 404)
        self.assertFalse(resp.get_json()["ok"])

    def test_thread_start_failure_cleans_registered_job(self):
        active_before = routes._job_registry.active_count
        with patch("routes.threading.Thread", side_effect=RuntimeError("thread failed")):
            with self.assertRaises(RuntimeError):
                _client().post(
                    "/transcribe",
                    data={"audio": (io.BytesIO(b"fake-audio"), "sample.wav")},
                    content_type="multipart/form-data",
                )
        self.assertEqual(routes._job_registry.active_count, active_before)


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
        """mock transcription service，驗證成功路徑回傳 text/language。"""
        fake_audio = base64.b64encode(b"\x00\x01fake-audio-bytes").decode()
        service_result = TranscriptionResult("測試逐字稿", "zh", {})
        with patch.object(routes._transcription_service, "transcribe", return_value=service_result) as mock_run:
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
        service_request = mock_run.call_args.args[0]
        self.assertEqual(service_request.language, "zh")

    def test_transcription_error_returns_500(self):
        """service 拋 TranscriptionError → 500，錯誤訊息透傳給呼叫端。"""
        fake_audio = base64.b64encode(b"fake").decode()
        with patch.object(routes._transcription_service, "transcribe",
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
        with patch.object(routes._transcription_service, "transcribe", return_value=TranscriptionResult("hello", "en", {})) as mock_run:
            resp = _client().post(
                "/api/transcribe-sync",
                json={"audio_b64": fake_audio, "model": "base", "language": "en"},
            )
        self.assertEqual(resp.status_code, 200)
        service_request = mock_run.call_args.args[0]
        self.assertEqual(service_request.language, "en")


# ── Notion /upload ─────────────────────────────────────────────────

class TestNotionUpload(unittest.TestCase):

    def setUp(self):
        self._saved = {k: os.environ.pop(k, None) for k in ("NOTION_TOKEN", "NOTION_PAGE_ID")}
        import routes
        import integrations
        routes._last_summary = None
        self._destination_summary = patch.object(
            integrations,
            "build_destination_summary",
            side_effect=lambda text, destination: ("anthropic", f"{destination} 專屬摘要：{text}"),
        )
        self.destination_summary_mock = self._destination_summary.start()

    def tearDown(self):
        for k, v in self._saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)
        import routes
        routes._last_summary = None
        self._destination_summary.stop()

    @staticmethod
    def _notion_client():
        client = MagicMock()
        client.pages.create.return_value = {"id": "meeting-page-id", "url": "https://notion.so/meeting-page-id"}
        return client

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

    def test_first_publish_creates_a_child_meeting_page(self):
        """首次發布建立子頁，將完整會議內容放入該頁。"""
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        mock_client_instance = self._notion_client()
        with patch("notion_client.Client", return_value=mock_client_instance) as mock_client_cls:
            resp = _client().post(
                "/upload",
                json={"text": "[00:00] 第一句\n[00:05] 第二句", "language": "zh"},
            )
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertTrue(data["ok"])
        self.assertGreater(data["blocks"], 0)
        self.assertTrue(data["created"])
        mock_client_cls.assert_called_once_with(auth="secret_test")
        mock_client_instance.pages.create.assert_called_once()
        create_kwargs = mock_client_instance.pages.create.call_args.kwargs
        self.assertEqual(create_kwargs["parent"]["page_id"], "abc123")
        self.assertIn("children", create_kwargs)

    def test_upload_includes_confirmed_summary_before_transcript(self):
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        mock_client_instance = self._notion_client()
        with patch("notion_client.Client", return_value=mock_client_instance):
            resp = _client().post(
                "/upload",
                json={"text": "逐字稿內容", "summary": "確認後摘要", "language": "zh"},
            )
        self.assertEqual(resp.status_code, 200)
        children = mock_client_instance.pages.create.call_args.kwargs["children"]
        contents = [
            block[block["type"]]["rich_text"][0]["text"]["content"]
            for block in children
            if block["type"] in {"heading_2", "paragraph"}
        ]
        self.assertLess(contents.index("notion 專屬摘要：逐字稿內容"), contents.index("逐字稿內容"))

    def test_notion_api_exception_returns_500(self):
        """notion_client 呼叫拋例外 → 500，錯誤訊息透傳，不洩漏 stack trace。"""
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        mock_client_instance = self._notion_client()
        mock_client_instance.pages.create.side_effect = Exception("notion API rate limited")
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
        mock_client_instance = self._notion_client()
        with patch("notion_client.Client", return_value=mock_client_instance):
            resp = _client().post(
                "/upload",
                json={"text": "hello", "language": "en", "page_id": "request-page-id"},
            )
        self.assertEqual(resp.status_code, 200)
        call_kwargs = mock_client_instance.pages.create.call_args
        self.assertEqual(call_kwargs.kwargs["parent"]["page_id"], "request-page-id")

    def test_second_publish_rewrites_the_same_meeting_page(self):
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        import routes
        routes._save_last_summary(routes._summary_payload(
            status="ready",
            meeting_id="meeting-123",
            meeting_title="會議記錄｜測試",
            notion_page_id="meeting-page-id",
            notion_page_url="https://notion.so/meeting-page-id",
            generated_summary="初版摘要",
        ))
        mock_client_instance = self._notion_client()
        mock_client_instance.blocks.children.list.return_value = {
            "results": [{"id": "old-block-id"}], "has_more": False,
        }
        with patch("notion_client.Client", return_value=mock_client_instance):
            resp = _client().post(
                "/upload",
                json={"text": "修正版逐字稿", "summary": "修正版摘要", "language": "zh", "meeting_id": "meeting-123"},
            )
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertFalse(data["created"])
        self.assertEqual(data["notion_page_id"], "meeting-page-id")
        mock_client_instance.pages.create.assert_not_called()
        mock_client_instance.blocks.delete.assert_called_once_with(block_id="old-block-id")
        mock_client_instance.blocks.children.append.assert_called()

    def test_stale_meeting_id_does_not_create_a_new_notion_page(self):
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        import routes
        routes._save_last_summary(routes._summary_payload(status="ready", meeting_id="current-meeting"))
        mock_client_instance = self._notion_client()
        with patch("notion_client.Client", return_value=mock_client_instance):
            response = _client().post(
                "/upload",
                json={"text": "舊 session", "language": "zh", "meeting_id": "stale-meeting"},
            )
        self.assertEqual(response.status_code, 409)
        mock_client_instance.pages.create.assert_not_called()

    def test_destination_summary_failure_does_not_write_to_notion(self):
        os.environ["NOTION_TOKEN"] = "secret_test"
        os.environ["NOTION_PAGE_ID"] = "abc123"
        self.destination_summary_mock.side_effect = RuntimeError("LLM unavailable")
        mock_client_instance = self._notion_client()
        with patch("notion_client.Client", return_value=mock_client_instance):
            response = _client().post("/upload", json={"text": "逐字稿", "language": "zh"})
        self.assertEqual(response.status_code, 502)
        self.assertIn("Notion 會議內容產生失敗", response.get_json()["error"])
        mock_client_instance.pages.create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
