"""Own and terminate a subprocess without leaving orphan children."""
from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from typing import Optional, Sequence

from transcription_jobs import CancellationToken, TranscriptionCancelled


@dataclass(frozen=True)
class ProcessResult:
    returncode: int
    stdout: str
    stderr: str


def _stop_process_group(proc: subprocess.Popen, grace_seconds: float) -> tuple[str, str]:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        return proc.communicate(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return proc.communicate()


def run_cancellable(
    command: Sequence[str],
    cancellation: Optional[CancellationToken] = None,
    timeout_seconds: float = 7200,
    poll_seconds: float = 0.1,
    terminate_grace_seconds: float = 2,
) -> ProcessResult:
    proc = subprocess.Popen(
        list(command),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    started_at = time.monotonic()
    try:
        while True:
            if cancellation and cancellation.is_cancelled:
                _stop_process_group(proc, terminate_grace_seconds)
                raise TranscriptionCancelled(cancellation.job_id)

            elapsed = time.monotonic() - started_at
            remaining = timeout_seconds - elapsed
            if remaining <= 0:
                stdout, stderr = _stop_process_group(proc, terminate_grace_seconds)
                raise subprocess.TimeoutExpired(command, timeout_seconds, stdout, stderr)

            try:
                stdout, stderr = proc.communicate(timeout=min(poll_seconds, remaining))
                return ProcessResult(proc.returncode, stdout, stderr)
            except subprocess.TimeoutExpired:
                # A frozen inference child can exit while a multiprocessing
                # helper inherited its output pipes. Terminate that remaining
                # process group so communicate() can receive EOF instead of
                # waiting until the overall inference timeout.
                if proc.poll() is not None:
                    stdout, stderr = _stop_process_group(proc, terminate_grace_seconds)
                    return ProcessResult(proc.returncode, stdout, stderr)
                continue
    except BaseException:
        if proc.poll() is None:
            _stop_process_group(proc, terminate_grace_seconds)
        raise
