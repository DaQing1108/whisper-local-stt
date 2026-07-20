"""Application seam between transports and the Whisper inference core."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Mapping, Optional
from uuid import uuid4

from transcription_events import EventSink, NULL_EVENT_SINK
from transcription_jobs import CancellationToken


@dataclass(frozen=True)
class TranscriptionRequest:
    audio_bytes: bytes
    ext: str
    model_name: str
    language: Optional[str]
    job_id: str = field(default_factory=lambda: uuid4().hex)
    progress_cb: Optional[Callable] = None
    keep_wav: bool = False
    options: Mapping[str, object] = field(default_factory=dict)
    cancellation: Optional[CancellationToken] = None

    def __post_init__(self) -> None:
        if self.cancellation and self.cancellation.job_id != self.job_id:
            raise ValueError("cancellation token job_id must match request job_id")

    def cancellation_token(self) -> CancellationToken:
        return self.cancellation or CancellationToken(self.job_id)


@dataclass(frozen=True)
class TranscriptionResult:
    text: str
    language: str
    info: dict


class TranscriptionService:
    def __init__(self, transcriber: Callable, event_sink: EventSink = NULL_EVENT_SINK):
        self._transcriber = transcriber
        self._event_sink = event_sink

    def transcribe(self, request: TranscriptionRequest) -> TranscriptionResult:
        cancellation = request.cancellation_token()
        cancellation.raise_if_cancelled()

        def emit(event: str, data: dict) -> None:
            self._event_sink(event, {**data, "job_id": request.job_id})

        text, language, info = self._transcriber(
            request.audio_bytes,
            request.ext,
            request.model_name,
            request.language,
            progress_cb=request.progress_cb,
            keep_wav=request.keep_wav,
            event_sink=emit,
            cancellation=cancellation,
            **dict(request.options),
        )
        cancellation.raise_if_cancelled()
        return TranscriptionResult(text=text, language=language, info=info)
