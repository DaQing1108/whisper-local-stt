"""JSONL v1 protocol contract tests."""
import json

import pytest

from worker_protocol import (
    PROTOCOL_NAME,
    PROTOCOL_VERSION,
    EventEnvelope,
    ProtocolError,
    decode_command,
    encode_event,
)


def _command(command, payload=None, **updates):
    envelope = {
        "protocol": PROTOCOL_NAME,
        "version": PROTOCOL_VERSION,
        "type": "command",
        "request_id": "request-1",
        "command": command,
        "payload": payload if payload is not None else {},
    }
    envelope.update(updates)
    return json.dumps(envelope)


def test_decode_transcribe_command_uses_absolute_audio_path():
    command = decode_command(_command("transcribe", {
        "audio_path": "/tmp/audio.wav", "model_name": "base", "language": "zh",
    }))

    assert command.command == "transcribe"
    assert command.payload["audio_path"] == "/tmp/audio.wav"


@pytest.mark.parametrize("field", ["audio_b64", "audio_bytes", "audio_data", "binary"])
def test_decode_rejects_binary_audio_fields(field):
    with pytest.raises(ProtocolError, match="audio_path") as error:
        decode_command(_command("transcribe", {
            "audio_path": "/tmp/audio.wav", "model_name": "base", field: "data",
        }))
    assert error.value.code == "BINARY_NOT_ALLOWED"


def test_decode_rejects_relative_audio_path():
    with pytest.raises(ProtocolError) as error:
        decode_command(_command("transcribe", {
            "audio_path": "audio.wav", "model_name": "base",
        }))
    assert error.value.code == "INVALID_AUDIO_PATH"


def test_decode_cancel_requires_job_id():
    with pytest.raises(ProtocolError) as error:
        decode_command(_command("cancel"))
    assert error.value.code == "INVALID_ENVELOPE"


@pytest.mark.parametrize("command", ["model_status", "warmup_model"])
def test_model_commands_require_model_name(command):
    assert decode_command(_command(command, {"model_name": "base"})).command == command
    with pytest.raises(ProtocolError) as error:
        decode_command(_command(command, {}))
    assert error.value.code == "INVALID_PAYLOAD"


def test_model_events_do_not_require_transcription_job_id():
    line = encode_event(EventEnvelope(
        "model-1", "model_status", {"model_name": "base", "status": "cached"},
    ))
    assert json.loads(line)["event"] == "model_status"


def test_decode_rejects_wrong_version_and_unknown_command():
    with pytest.raises(ProtocolError) as version_error:
        decode_command(_command("ping", version=2))
    assert version_error.value.code == "UNSUPPORTED_PROTOCOL"

    with pytest.raises(ProtocolError) as command_error:
        decode_command(_command("delete_everything"))
    assert command_error.value.code == "UNKNOWN_COMMAND"


def test_decode_rejects_non_json_and_non_object_payload():
    with pytest.raises(ProtocolError) as json_error:
        decode_command("not-json")
    assert json_error.value.code == "INVALID_JSON"

    with pytest.raises(ProtocolError) as payload_error:
        decode_command(_command("ping", payload=[]))
    assert payload_error.value.code == "INVALID_PAYLOAD"


def test_encode_event_is_exactly_one_json_line_and_preserves_unicode():
    line = encode_event(EventEnvelope(
        request_id="request-1",
        event="status",
        payload={"job_id": "job-1", "message": "轉錄中"},
    ))

    assert line.endswith("\n")
    assert line.count("\n") == 1
    decoded = json.loads(line)
    assert decoded["protocol"] == PROTOCOL_NAME
    assert decoded["version"] == PROTOCOL_VERSION
    assert decoded["payload"]["message"] == "轉錄中"


def test_encode_rejects_unknown_event():
    with pytest.raises(ProtocolError) as error:
        encode_event(EventEnvelope("request-1", "mystery", {}))
    assert error.value.code == "UNKNOWN_EVENT"


def test_job_event_requires_job_id():
    with pytest.raises(ProtocolError) as error:
        encode_event(EventEnvelope("request-1", "completed", {"text": "done"}))
    assert error.value.code == "INVALID_ENVELOPE"


def test_encode_normalizes_non_json_payload_error():
    with pytest.raises(ProtocolError) as error:
        encode_event(EventEnvelope(
            "request-1", "failed", {"job_id": "job-1", "value": object()},
        ))
    assert error.value.code == "INVALID_PAYLOAD"


@pytest.mark.parametrize("field,value", [
    ("domain", 123), ("extra_terms", []), ("skip_llm", "false"),
])
def test_decode_rejects_invalid_transcribe_option_types(field, value):
    with pytest.raises(ProtocolError) as error:
        decode_command(_command("transcribe", {
            "audio_path": "/tmp/audio.wav", "model_name": "base", field: value,
        }))
    assert error.value.code == "INVALID_PAYLOAD"
