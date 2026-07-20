"""Contract tests for the transport-independent Whisper event sink."""
from pathlib import Path

import whisper_core
from transcription_events import NULL_EVENT_SINK
from transcription_jobs import CancellationToken, JobRegistry, TranscriptionCancelled
from transcription_service import TranscriptionRequest, TranscriptionService


def test_whisper_core_does_not_import_sse_transport():
    source = Path(whisper_core.__file__).read_text(encoding="utf-8")
    assert "from sse import" not in source


def test_default_event_sink_is_a_noop():
    assert NULL_EVENT_SINK("status", {"msg": "ignored"}) is None


def test_service_injects_its_event_sink():
    calls = []
    sink = lambda event, data: calls.append((event, data))

    def transcriber(*args, **kwargs):
        kwargs["event_sink"]("status", {"ok": True})
        return "text", "zh", {"segments": []}

    result = TranscriptionService(transcriber, sink).transcribe(TranscriptionRequest(
        audio_bytes=b"audio", ext=".wav", model_name="base", language="zh",
        job_id="job-123",
    ))

    assert calls == [("status", {"ok": True, "job_id": "job-123"})]
    assert result.text == "text"
    assert result.language == "zh"
    assert result.info == {"segments": []}


def test_service_rejects_job_cancelled_before_inference():
    token = CancellationToken("job-cancelled")
    token.cancel()
    transcriber_called = False

    def transcriber(*_args, **_kwargs):
        nonlocal transcriber_called
        transcriber_called = True

    request = TranscriptionRequest(
        audio_bytes=b"audio", ext=".wav", model_name="base", language="zh",
        job_id=token.job_id, cancellation=token,
    )

    try:
        TranscriptionService(transcriber).transcribe(request)
    except TranscriptionCancelled as exc:
        assert exc.job_id == token.job_id
    else:
        raise AssertionError("cancelled request should not reach inference")

    assert transcriber_called is False


def test_service_discards_result_cancelled_during_inference():
    token = CancellationToken("job-running")

    def transcriber(*_args, **_kwargs):
        token.cancel()
        return "late result", "zh", {}

    request = TranscriptionRequest(
        audio_bytes=b"audio", ext=".wav", model_name="base", language="zh",
        job_id=token.job_id, cancellation=token,
    )

    try:
        TranscriptionService(transcriber).transcribe(request)
    except TranscriptionCancelled as exc:
        assert exc.job_id == token.job_id
    else:
        raise AssertionError("result completed after cancellation must be discarded")


def test_request_rejects_mismatched_cancellation_job_id():
    try:
        TranscriptionRequest(
            audio_bytes=b"audio", ext=".wav", model_name="base", language="zh",
            job_id="request-job", cancellation=CancellationToken("other-job"),
        )
    except ValueError as exc:
        assert "job_id" in str(exc)
    else:
        raise AssertionError("mismatched job identities must be rejected")


def test_job_registry_tracks_cancel_and_cleanup():
    registry = JobRegistry()
    token = registry.register("job-registry")

    assert registry.get("job-registry").status == "queued"
    assert registry.mark_running("job-registry").status == "running"
    assert registry.cancel("job-registry").status == "cancelling"
    assert token.is_cancelled is True

    registry.unregister("job-registry")
    assert registry.get("job-registry") is None
    assert registry.active_count == 0


def test_job_registry_rejects_duplicate_job_id():
    registry = JobRegistry()
    registry.register("duplicate")

    try:
        registry.register("duplicate")
    except ValueError as exc:
        assert "already registered" in str(exc)
    else:
        raise AssertionError("duplicate active job IDs must be rejected")


def test_job_registry_finish_atomically_closes_cancellable_window():
    registry = JobRegistry()
    registry.register("finished-job")
    registry.mark_running("finished-job")

    snapshot = registry.finish("finished-job")

    assert snapshot.status == "running"
    assert snapshot.is_cancelled is False
    assert registry.cancel("finished-job") is None
    assert registry.active_count == 0


def test_job_registry_cancel_all_marks_every_active_job():
    registry = JobRegistry()
    first = registry.register("first")
    second = registry.register("second")

    snapshots = registry.cancel_all()

    assert {snapshot.job_id for snapshot in snapshots} == {"first", "second"}
    assert first.is_cancelled and second.is_cancelled
