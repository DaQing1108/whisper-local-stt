"""JSONL stdin/stdout entrypoint for the standalone Python transcription Worker."""
from __future__ import annotations

import contextlib
import json
import sys
import threading
import traceback
from pathlib import Path
from typing import Callable, TextIO
from uuid import uuid4

from transcription_jobs import JobRegistry, TranscriptionCancelled
from transcription_service import TranscriptionRequest, TranscriptionService
from worker_protocol import EventEnvelope, ProtocolError, decode_command, encode_event


class WorkerRuntime:
    def __init__(self, transcriber: Callable, stdout: TextIO, stderr: TextIO, model_manager=None):
        self._transcriber = transcriber
        self._stdout = stdout
        self._stderr = stderr
        self._registry = JobRegistry()
        self._write_lock = threading.Lock()
        self._threads: set[threading.Thread] = set()
        self._threads_lock = threading.Lock()
        self._model_manager = model_manager

    def emit(self, request_id: str, event: str, payload: dict) -> None:
        line = encode_event(EventEnvelope(request_id, event, payload))
        with self._write_lock:
            self._stdout.write(line)
            self._stdout.flush()

    def handle_line(self, line: str) -> None:
        try:
            command = decode_command(line)
        except ProtocolError as exc:
            self.emit("protocol", "protocol_error", {"code": exc.code, "message": str(exc)})
            return

        if command.command == "ping":
            self.emit(command.request_id, "pong", {})
        elif command.command == "capabilities":
            self.emit(command.request_id, "capabilities", {
                "diarization": {
                    "available": False,
                    "code": "BUNDLED_RUNTIME_UNAVAILABLE",
                    "message": (
                        "Diarization is disabled because the packaged Worker "
                        "does not include torch and pyannote.audio."
                    ),
                },
            })
        elif command.command == "cancel":
            job_id = str(command.payload["job_id"])
            snapshot = self._registry.cancel(job_id)
            if snapshot:
                self.emit(command.request_id, "status", {
                    "job_id": job_id, "status": "cancelling",
                })
            else:
                self.emit(command.request_id, "failed", {
                    "job_id": job_id, "code": "JOB_NOT_FOUND", "message": "job not found",
                })
        elif command.command == "transcribe":
            self._start_transcription(command.request_id, dict(command.payload))
        elif command.command == "model_status":
            self._model_status(command.request_id, str(command.payload["model_name"]))
        elif command.command == "warmup_model":
            self._warmup_model(command.request_id, str(command.payload["model_name"]))

    def _model_status(self, request_id: str, model_name: str) -> None:
        if self._model_manager is None:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "MODEL_MANAGER_UNAVAILABLE", "message": "model manager unavailable",
            })
            return
        self.emit(request_id, "model_status", self._model_manager.status(model_name))

    def _warmup_model(self, request_id: str, model_name: str) -> None:
        if self._registry.active_count:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "WORKER_BUSY", "message": "transcription is active",
            })
            return
        if self._model_manager is None:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "MODEL_MANAGER_UNAVAILABLE", "message": "model manager unavailable",
            })
            return
        try:
            payload = self._model_manager.warmup(model_name)
            self.emit(request_id, "model_ready", payload)
        except Exception as exc:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "MODEL_WARMUP_FAILED", "message": str(exc),
            })

    def _start_transcription(self, request_id: str, payload: dict) -> None:
        job_id = uuid4().hex
        if self._registry.active_count:
            self.emit(request_id, "failed", {
                "job_id": job_id, "code": "WORKER_BUSY", "message": "worker already has an active job",
            })
            return

        audio_path = Path(str(payload["audio_path"]))
        if not audio_path.is_file():
            self.emit(request_id, "failed", {
                "job_id": job_id, "code": "AUDIO_NOT_FOUND", "message": "audio_path is not a file",
            })
            return

        cancellation = self._registry.register(job_id)
        self.emit(request_id, "accepted", {"job_id": job_id, "status": "queued"})

        def run_job() -> None:
            self._registry.mark_running(job_id)

            def event_sink(event: str, data: dict) -> None:
                event_name = event if event in {"status", "progress"} else "status"
                self.emit(request_id, event_name, data)

            def progress(done: int, total: int, text: str) -> None:
                self.emit(request_id, "progress", {
                    "job_id": job_id, "done": done, "total": total, "text": text,
                })

            try:
                service = TranscriptionService(self._transcriber, event_sink)
                request = TranscriptionRequest(
                    audio_bytes=audio_path.read_bytes(),
                    ext=audio_path.suffix or ".wav",
                    model_name=str(payload["model_name"]),
                    language=payload.get("language"),
                    job_id=job_id,
                    progress_cb=progress,
                    cancellation=cancellation,
                    options={
                        "domain": payload.get("domain", "general"),
                        "extra_terms": payload.get("extra_terms", ""),
                        "skip_llm": bool(payload.get("skip_llm", False)),
                    },
                )
                with contextlib.redirect_stdout(self._stderr):
                    result = service.transcribe(request)
                final_job = self._registry.finish(job_id)
                if final_job and final_job.is_cancelled:
                    raise TranscriptionCancelled(job_id)
                self.emit(request_id, "completed", {
                    "job_id": job_id,
                    "text": result.text,
                    "language": result.language,
                    "info": result.info,
                })
            except TranscriptionCancelled:
                self.emit(request_id, "cancelled", {"job_id": job_id})
            except Exception as exc:
                print(traceback.format_exc(), file=self._stderr, flush=True)
                self.emit(request_id, "failed", {
                    "job_id": job_id,
                    "code": getattr(exc, "code", "TRANSCRIPTION_FAILED"),
                    "message": str(exc),
                })
            finally:
                self._registry.unregister(job_id)
                with self._threads_lock:
                    self._threads.discard(threading.current_thread())

        thread = threading.Thread(target=run_job, daemon=True, name=f"worker-{job_id[:8]}")
        with self._threads_lock:
            self._threads.add(thread)
        try:
            thread.start()
        except BaseException as exc:
            with self._threads_lock:
                self._threads.discard(thread)
            self._registry.unregister(job_id)
            print(traceback.format_exc(), file=self._stderr, flush=True)
            self.emit(request_id, "failed", {
                "job_id": job_id, "code": "WORKER_THREAD_FAILED", "message": str(exc),
            })

    def wait_for_idle(self, timeout: float = 5) -> bool:
        with self._threads_lock:
            threads = list(self._threads)
        for thread in threads:
            thread.join(timeout)
        return self._registry.active_count == 0

    def shutdown(self, timeout: float = 5) -> bool:
        self._registry.cancel_all()
        return self.wait_for_idle(timeout)


def run_worker(stdin: TextIO, stdout: TextIO, stderr: TextIO, transcriber: Callable) -> int:
    runtime = WorkerRuntime(transcriber, stdout, stderr)
    runtime.emit("worker", "ready", {"status": "ready"})
    for line in stdin:
        if line.strip():
            runtime.handle_line(line)
    return 0 if runtime.shutdown() else 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--inference-child":
        return run_inference_child(sys.argv[2:])
    from whisper_core import run_whisper
    from model_runtime import ModelRuntimeManager
    runtime = WorkerRuntime(run_whisper, sys.stdout, sys.stderr, ModelRuntimeManager())
    runtime.emit("worker", "ready", {"status": "ready"})
    for line in sys.stdin:
        if line.strip():
            runtime.handle_line(line)
    return 0 if runtime.shutdown() else 1


def run_inference_child(args: list[str]) -> int:
    """Run faster-whisper inside the bundled executable for hard cancellation."""
    if len(args) != 4:
        print("usage: --inference-child WAV MODEL LANGUAGE INITIAL_PROMPT", file=sys.stderr)
        return 2
    wav_path, model_name, language_arg, initial_prompt = args
    from faster_whisper import WhisperModel

    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    segments_raw, info = model.transcribe(
        wav_path,
        language=None if language_arg == "__auto__" else language_arg,
        beam_size=5,
        initial_prompt=initial_prompt or None,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
    )
    segments = [
        {"text": segment.text, "start": segment.start, "end": segment.end}
        for segment in segments_raw
    ]
    print(json.dumps({
        "text": " ".join(segment["text"] for segment in segments).strip(),
        "language": info.language,
        "segments": segments,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
