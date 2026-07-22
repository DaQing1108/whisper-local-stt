"""Versioned JSONL contract shared by SwiftUI and the Python Worker."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

PROTOCOL_NAME = "whisper.worker"
PROTOCOL_VERSION = 1
COMMANDS = frozenset({
    "transcribe", "cancel", "ping", "capabilities", "model_status", "warmup_model",
    "diarization_warmup", "diarize",
})
EVENTS = frozenset({
    "ready", "accepted", "status", "progress", "completed",
    "failed", "cancelled", "pong", "capabilities", "model_status", "model_ready", "protocol_error",
    "diarization_ready", "diarized",
})
_JOB_EVENTS = EVENTS.difference({
    "ready", "pong", "capabilities", "model_status", "model_ready", "protocol_error",
    "diarization_ready", "diarized",
})
_FORBIDDEN_AUDIO_FIELDS = frozenset({"audio_b64", "audio_bytes", "audio_data", "binary"})


class ProtocolError(ValueError):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


@dataclass(frozen=True)
class CommandEnvelope:
    request_id: str
    command: str
    payload: Mapping[str, object]


@dataclass(frozen=True)
class EventEnvelope:
    request_id: str
    event: str
    payload: Mapping[str, object]


def _require_identifier(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 128:
        raise ProtocolError("INVALID_ENVELOPE", f"{field} must be a non-empty string up to 128 chars")
    return value


def decode_command(line: str) -> CommandEnvelope:
    try:
        raw = json.loads(line)
    except (TypeError, json.JSONDecodeError) as exc:
        raise ProtocolError("INVALID_JSON", "command must be one JSON object per line") from exc

    if not isinstance(raw, dict):
        raise ProtocolError("INVALID_ENVELOPE", "command envelope must be an object")
    if raw.get("protocol") != PROTOCOL_NAME or raw.get("version") != PROTOCOL_VERSION:
        raise ProtocolError("UNSUPPORTED_PROTOCOL", "unsupported protocol name or version")
    if raw.get("type") != "command":
        raise ProtocolError("INVALID_ENVELOPE", "type must be command")

    request_id = _require_identifier(raw.get("request_id"), "request_id")
    command = raw.get("command")
    if command not in COMMANDS:
        raise ProtocolError("UNKNOWN_COMMAND", f"unsupported command: {command}")
    payload = raw.get("payload", {})
    if not isinstance(payload, dict):
        raise ProtocolError("INVALID_PAYLOAD", "payload must be an object")
    forbidden = _FORBIDDEN_AUDIO_FIELDS.intersection(payload)
    if forbidden:
        raise ProtocolError("BINARY_NOT_ALLOWED", f"audio must use audio_path, not {sorted(forbidden)[0]}")

    if command == "transcribe":
        audio_path = payload.get("audio_path")
        if not isinstance(audio_path, str) or not Path(audio_path).is_absolute():
            raise ProtocolError("INVALID_AUDIO_PATH", "transcribe requires an absolute audio_path")
        if not isinstance(payload.get("model_name"), str) or not payload["model_name"]:
            raise ProtocolError("INVALID_PAYLOAD", "transcribe requires model_name")
        language = payload.get("language")
        if language is not None and not isinstance(language, str):
            raise ProtocolError("INVALID_PAYLOAD", "language must be a string or null")
        for field in ("domain", "extra_terms"):
            if field in payload and not isinstance(payload[field], str):
                raise ProtocolError("INVALID_PAYLOAD", f"{field} must be a string")
        if "skip_llm" in payload and not isinstance(payload["skip_llm"], bool):
            raise ProtocolError("INVALID_PAYLOAD", "skip_llm must be a boolean")
    elif command == "cancel":
        _require_identifier(payload.get("job_id"), "job_id")
    elif command in {"model_status", "warmup_model"}:
        model_name = payload.get("model_name")
        if not isinstance(model_name, str) or not model_name:
            raise ProtocolError("INVALID_PAYLOAD", f"{command} requires model_name")
    elif command == "diarize":
        audio_path = payload.get("audio_path")
        if not isinstance(audio_path, str) or not audio_path:
            raise ProtocolError("INVALID_PAYLOAD", "diarize requires audio_path")
        if not isinstance(payload.get("segments"), list):
            raise ProtocolError("INVALID_PAYLOAD", "diarize requires a segments array")

    return CommandEnvelope(request_id=request_id, command=command, payload=payload)


def encode_event(event: EventEnvelope) -> str:
    _require_identifier(event.request_id, "request_id")
    if event.event not in EVENTS:
        raise ProtocolError("UNKNOWN_EVENT", f"unsupported event: {event.event}")
    if not isinstance(event.payload, Mapping):
        raise ProtocolError("INVALID_PAYLOAD", "event payload must be an object")
    if event.event in _JOB_EVENTS:
        _require_identifier(event.payload.get("job_id"), "job_id")
    try:
        encoded = json.dumps({
            "protocol": PROTOCOL_NAME,
            "version": PROTOCOL_VERSION,
            "type": "event",
            "request_id": event.request_id,
            "event": event.event,
            "payload": dict(event.payload),
        }, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise ProtocolError("INVALID_PAYLOAD", "event payload must be JSON serializable") from exc
    return encoded + "\n"
