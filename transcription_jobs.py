"""Job identity and cooperative cancellation primitives."""
from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Optional


class TranscriptionCancelled(Exception):
    def __init__(self, job_id: str):
        self.job_id = job_id
        super().__init__(f"transcription job cancelled: {job_id}")


class CancellationToken:
    def __init__(self, job_id: str):
        self.job_id = job_id
        self._cancelled = threading.Event()

    @property
    def is_cancelled(self) -> bool:
        return self._cancelled.is_set()

    def cancel(self) -> None:
        self._cancelled.set()

    def raise_if_cancelled(self) -> None:
        if self.is_cancelled:
            raise TranscriptionCancelled(self.job_id)


@dataclass(frozen=True)
class JobSnapshot:
    job_id: str
    status: str
    is_cancelled: bool


class JobRegistry:
    def __init__(self):
        self._jobs: dict[str, tuple[CancellationToken, str]] = {}
        self._lock = threading.Lock()

    def register(self, job_id: str) -> CancellationToken:
        with self._lock:
            if job_id in self._jobs:
                raise ValueError(f"job already registered: {job_id}")
            token = CancellationToken(job_id)
            self._jobs[job_id] = (token, "queued")
            return token

    def mark_running(self, job_id: str) -> Optional[JobSnapshot]:
        with self._lock:
            entry = self._jobs.get(job_id)
            if not entry:
                return None
            token, status = entry
            if status != "cancelling":
                status = "running"
                self._jobs[job_id] = (token, status)
            return JobSnapshot(job_id, status, token.is_cancelled)

    def cancel(self, job_id: str) -> Optional[JobSnapshot]:
        with self._lock:
            entry = self._jobs.get(job_id)
            if not entry:
                return None
            token, _status = entry
            token.cancel()
            self._jobs[job_id] = (token, "cancelling")
            return JobSnapshot(job_id, "cancelling", True)

    def cancel_all(self) -> list[JobSnapshot]:
        with self._lock:
            snapshots = []
            for job_id, (token, _status) in list(self._jobs.items()):
                token.cancel()
                self._jobs[job_id] = (token, "cancelling")
                snapshots.append(JobSnapshot(job_id, "cancelling", True))
            return snapshots

    def unregister(self, job_id: str) -> None:
        with self._lock:
            self._jobs.pop(job_id, None)

    def finish(self, job_id: str) -> Optional[JobSnapshot]:
        """Atomically close the cancellable window and return its final state."""
        with self._lock:
            entry = self._jobs.pop(job_id, None)
            if not entry:
                return None
            token, status = entry
            return JobSnapshot(job_id, status, token.is_cancelled)

    def get(self, job_id: str) -> Optional[JobSnapshot]:
        with self._lock:
            entry = self._jobs.get(job_id)
            if not entry:
                return None
            token, status = entry
            return JobSnapshot(job_id, status, token.is_cancelled)

    @property
    def active_count(self) -> int:
        with self._lock:
            return len(self._jobs)
