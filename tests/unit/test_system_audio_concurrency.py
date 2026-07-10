"""tests/unit/test_system_audio_concurrency.py

Regression test：混音擷取（mic+system）進行中時，第二個 with_mic=false 的
system-audio-only 啟動請求必須被擋下，不能繞過 409 guard 啟動第二個 Swift
subprocess。

MixedAudioCapture 內部持有自己的 SystemAudioCapture 實例，但從未指派給
system_audio 模組層級的 _capture 單例——修正前，start_capture() 與
routes.py 的路由層 guard 都只檢查 _capture，漏了 _mixed_capture，導致這個
情境會靜默通過。

這裡直接測 guard 邏輯本身（monkeypatch _mixed_capture 模擬運行中狀態），
不觸碰真正的 Swift subprocess / TCC 權限——依 CLAUDE.md 既有記錄，實際音訊
擷取無法在 dev/test 環境驗證，guard 邏輯本身才是這次要保證正確的部分。
"""
import unittest
from unittest.mock import MagicMock

import app as flask_app
import system_audio


def _fake_running_mixed_capture():
    fake = MagicMock()
    fake.is_running = True
    return fake


class TestStartCaptureGuardsAgainstMixedCapture(unittest.TestCase):
    """system_audio.start_capture() 本身的 guard（defense-in-depth 層）。"""

    def setUp(self):
        self._original_mixed = system_audio._mixed_capture
        self._original_capture = system_audio._capture

    def tearDown(self):
        system_audio._mixed_capture = self._original_mixed
        system_audio._capture = self._original_capture

    def test_start_capture_raises_when_mixed_capture_running(self):
        system_audio._mixed_capture = _fake_running_mixed_capture()
        system_audio._capture = None
        with self.assertRaises(RuntimeError) as ctx:
            system_audio.start_capture(on_chunk=lambda *_: None)
        self.assertIn("已在運行中", str(ctx.exception))

    def test_start_capture_does_not_construct_new_capture_when_blocked(self):
        """guard 必須在建立新 SystemAudioCapture 之前就擋下，不能先建立再丟例外。"""
        system_audio._mixed_capture = _fake_running_mixed_capture()
        system_audio._capture = None
        try:
            system_audio.start_capture(on_chunk=lambda *_: None)
        except RuntimeError:
            pass
        # _capture 必須維持 None，證明沒有任何新的 SystemAudioCapture 被指派進去
        self.assertIsNone(system_audio._capture)


class TestSystemAudioStartRouteGuardsAgainstMixedCapture(unittest.TestCase):
    """/api/system-audio/start 路由層的 guard（第一道防線，回 409）。"""

    def setUp(self):
        self._original_mixed = system_audio._mixed_capture
        self._original_capture = system_audio._capture
        flask_app.app.config["TESTING"] = True
        self.client = flask_app.app.test_client()

    def tearDown(self):
        system_audio._mixed_capture = self._original_mixed
        system_audio._capture = self._original_capture

    def test_system_audio_only_request_blocked_during_mixed_session(self):
        system_audio._mixed_capture = _fake_running_mixed_capture()
        system_audio._capture = None
        resp = self.client.post(
            "/api/system-audio/start",
            json={"model": "small", "language": "zh", "domain": "general", "with_mic": False},
        )
        self.assertEqual(resp.status_code, 409)
        self.assertIn("已在運行中", resp.get_json()["error"])


if __name__ == "__main__":
    unittest.main()
