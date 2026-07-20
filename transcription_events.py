"""Transport-independent event contract for transcription work."""
from __future__ import annotations

from typing import Protocol


class EventSink(Protocol):
    def __call__(self, event: str, data: dict) -> None:
        """Publish one structured transcription event."""


class NullEventSink:
    def __call__(self, _event: str, _data: dict) -> None:
        """Discard events for callers that do not expose progress."""


NULL_EVENT_SINK = NullEventSink()
