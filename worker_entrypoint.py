"""JSONL stdin/stdout entrypoint for the standalone Python transcription Worker."""
from __future__ import annotations

import contextlib
import json
import os
import resource
import shutil
import sys
import threading
import time
import traceback
import wave
from datetime import datetime
from pathlib import Path
from typing import Callable, TextIO
from uuid import uuid4

from transcription_jobs import JobRegistry, TranscriptionCancelled
from transcription_service import TranscriptionRequest, TranscriptionService
from worker_protocol import EventEnvelope, ProtocolError, decode_command, encode_event


class WorkerRuntime:
    def __init__(
        self,
        transcriber: Callable,
        stdout: TextIO,
        stderr: TextIO,
        model_manager=None,
        diarization_manager=None,
    ):
        self._transcriber = transcriber
        self._stdout = stdout
        self._stderr = stderr
        self._registry = JobRegistry()
        self._write_lock = threading.Lock()
        self._threads: set[threading.Thread] = set()
        self._threads_lock = threading.Lock()
        self._model_manager = model_manager
        self._diarization_manager = diarization_manager

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
            self.emit(command.request_id, "capabilities", {"diarization": self._diarization_capability()})
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
        elif command.command == "diarization_warmup":
            self._diarization_warmup(command.request_id)
        elif command.command == "diarize":
            self._diarize(command.request_id, dict(command.payload))

    def _diarization_capability(self) -> dict:
        if self._diarization_manager is None:
            return {
                "available": False,
                "code": "BUNDLED_RUNTIME_UNAVAILABLE",
                "message": "Diarization manager is not available in this Worker build.",
            }
        status = self._diarization_manager.status()
        return {
            "available": status["cached"],
            "code": "READY" if status["cached"] else "NEEDS_DOWNLOAD",
            "message": (
                "Diarization models are ready." if status["cached"]
                else "Diarization models need to be downloaded before use."
            ),
        }

    def _run_diarization_job(self, request_id: str, work: Callable[[], tuple[str, dict]]) -> None:
        """Shared background-job plumbing for diarization_warmup/diarize: registers a job in
        self._registry so it mutually excludes transcribe AND other diarization jobs (the
        same active_count check both already use), and runs off the stdin-reading thread so
        a slow diarize (~0.4x realtime) never blocks ping/cancel/transcribe from being read."""
        if self._registry.active_count:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "WORKER_BUSY", "message": "another job is active",
            })
            return
        job_id = uuid4().hex
        self._registry.register(job_id)

        def run_job() -> None:
            self._registry.mark_running(job_id)
            try:
                event, event_payload = work()
                self.emit(request_id, event, event_payload)
            except Exception as exc:
                self.emit(request_id, "failed", {
                    "job_id": job_id, "code": getattr(exc, "code", "DIARIZATION_FAILED"), "message": str(exc),
                })
            finally:
                self._registry.unregister(job_id)
                with self._threads_lock:
                    self._threads.discard(threading.current_thread())

        thread = threading.Thread(target=run_job, daemon=True, name=f"diarization-{job_id[:8]}")
        with self._threads_lock:
            self._threads.add(thread)
        try:
            thread.start()
        except BaseException as exc:
            with self._threads_lock:
                self._threads.discard(thread)
            self._registry.unregister(job_id)
            self.emit(request_id, "failed", {
                "job_id": job_id, "code": "THREAD_START_FAILED", "message": str(exc),
            })
            raise

    def _diarization_warmup(self, request_id: str) -> None:
        if self._diarization_manager is None:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "MODEL_MANAGER_UNAVAILABLE", "message": "diarization manager unavailable",
            })
            return

        def work() -> tuple[str, dict]:
            try:
                return "diarization_ready", self._diarization_manager.warmup()
            except Exception as exc:
                exc.code = "MODEL_WARMUP_FAILED"
                raise

        self._run_diarization_job(request_id, work)

    def _diarize(self, request_id: str, payload: dict) -> None:
        if self._diarization_manager is None:
            self.emit(request_id, "failed", {
                "job_id": request_id, "code": "MODEL_MANAGER_UNAVAILABLE", "message": "diarization manager unavailable",
            })
            return

        def work() -> tuple[str, dict]:
            from diarization_service import ModelNotReadyError, diarize

            try:
                segments = diarize(
                    str(payload["audio_path"]),
                    list(payload["segments"]),
                    manager=self._diarization_manager,
                    num_speakers=payload.get("num_speakers"),
                )
            except ModelNotReadyError as exc:
                exc.code = "MODEL_NOT_READY"
                raise
            return "diarized", {"segments": segments}

        self._run_diarization_job(request_id, work)

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
    from diarization_model_runtime import DiarizationModelManager
    runtime = WorkerRuntime(
        run_whisper, sys.stdout, sys.stderr,
        ModelRuntimeManager(), DiarizationModelManager(),
    )
    runtime.emit("worker", "ready", {"status": "ready"})
    for line in sys.stdin:
        if line.strip():
            runtime.handle_line(line)
    return 0 if runtime.shutdown() else 1


SLOW_INFERENCE_RATIO = 3
SLOW_WAV_KEEP = 10
SLOW_WAV_MAX_BYTES = 200 * 1024 * 1024
SLOW_WAV_PREFIX = "slow-"
DIAG_LOG_NAME = "inference.jsonl"
DIAG_LOG_MAX_BYTES = 5 * 1024 * 1024


def _cpu_seconds() -> float:
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_utime + usage.ru_stime


def _diagnostics_dir() -> Path:
    override = os.environ.get("WHISPER_DIAGNOSTICS_DIR")
    if override and os.path.isabs(override):
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "WhisperSwiftUI" / "Diagnostics"


def _wav_duration_seconds(wav_path: str) -> float | None:
    try:
        with wave.open(wav_path, "rb") as wav:
            rate = wav.getframerate()
            return wav.getnframes() / rate if rate else None
    except Exception:
        return None


def _prune_slow_wavs(directory: Path) -> None:
    kept = sorted(directory.glob(f"{SLOW_WAV_PREFIX}*.wav"), key=lambda p: p.name)
    for stale in kept[:-SLOW_WAV_KEEP]:
        stale.unlink(missing_ok=True)


def _prepare_diagnostics_dir() -> Path:
    directory = _diagnostics_dir()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    return directory


def _append_diagnostics_record(record: dict) -> None:
    """Append one JSON line (rotating at DIAG_LOG_MAX_BYTES). May raise."""
    directory = _prepare_diagnostics_dir()
    log_path = directory / DIAG_LOG_NAME
    try:
        if log_path.stat().st_size > DIAG_LOG_MAX_BYTES:
            os.replace(log_path, directory / (DIAG_LOG_NAME + ".1"))
    except FileNotFoundError:
        pass
    fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    os.chmod(log_path, 0o600)


def _swallow_diagnostics_errors(action: Callable[[], None]) -> None:
    """Run a diagnostics action; never raises, never touches stdout."""
    try:
        action()
    except Exception as exc:
        try:
            print(f"inference diagnostics failed: {exc}", file=sys.stderr)
        except Exception:
            pass


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat()


def _save_slow_wav(wav_path: str, record: dict) -> None:
    directory = _prepare_diagnostics_dir()
    if os.path.getsize(wav_path) > SLOW_WAV_MAX_BYTES:
        record["wav_saved"] = False
        record["wav_skipped"] = "too_large"
        return
    name = f"{SLOW_WAV_PREFIX}{datetime.now().strftime('%Y%m%dT%H%M%S%f')}.wav"
    target = directory / name
    try:
        shutil.copy2(wav_path, target)
        os.chmod(target, 0o600)
    except Exception as exc:
        target.unlink(missing_ok=True)
        record["wav_saved"] = False
        record["wav_skipped"] = f"copy_failed: {exc}"
        return
    record["wav_saved"] = name
    _prune_slow_wavs(directory)


def _record_inference_finish(
    pid: int, wav_path: str, model_name: str, segment_count: int,
    load_seconds: float, infer_seconds: float, elapsed: float, cpu: float,
) -> None:
    audio_seconds = _wav_duration_seconds(wav_path)
    record = {
        "event": "finish",
        "timestamp": _now_iso(),
        "pid": pid,
        "audio_seconds": audio_seconds,
        "model": model_name,
        "load_seconds": round(load_seconds, 3),
        "infer_seconds": round(infer_seconds, 3),
        "elapsed_seconds": round(elapsed, 3),
        "segments": segment_count,
        "cpu_seconds": round(cpu, 3),
    }
    if audio_seconds is not None and infer_seconds > audio_seconds * SLOW_INFERENCE_RATIO:
        record["slow"] = True
        try:
            _save_slow_wav(wav_path, record)
        except Exception as exc:
            record["wav_saved"] = False
            record["wav_skipped"] = f"copy_failed: {exc}"
    _append_diagnostics_record(record)


def run_inference_child(args: list[str]) -> int:
    """Run faster-whisper inside the bundled executable for hard cancellation."""
    if len(args) != 4:
        print("usage: --inference-child WAV MODEL LANGUAGE INITIAL_PROMPT", file=sys.stderr)
        return 2
    wav_path, model_name, language_arg, initial_prompt = args
    pid = os.getpid()
    started_at = time.monotonic()
    started_cpu = _cpu_seconds()
    _swallow_diagnostics_errors(lambda: _append_diagnostics_record({
        "event": "start",
        "timestamp": _now_iso(),
        "pid": pid,
        "audio_seconds": _wav_duration_seconds(wav_path),
        "model": model_name,
        "prompt_chars": len(initial_prompt),
    }))
    try:
        from faster_whisper import WhisperModel

        model = WhisperModel(model_name, device="cpu", compute_type="int8")
        loaded_at = time.monotonic()
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
        inferred_at = time.monotonic()
    except Exception as exc:
        _swallow_diagnostics_errors(lambda: _append_diagnostics_record({
            "event": "error",
            "timestamp": _now_iso(),
            "pid": pid,
            "error": f"{type(exc).__name__}: {str(exc)[:200]}",
        }))
        raise
    print(json.dumps({
        "text": " ".join(segment["text"] for segment in segments).strip(),
        "language": info.language,
        "segments": segments,
    }, ensure_ascii=False))
    sys.stdout.flush()
    _swallow_diagnostics_errors(lambda: _record_inference_finish(
        pid, wav_path, model_name, len(segments),
        loaded_at - started_at, inferred_at - loaded_at,
        inferred_at - started_at, _cpu_seconds() - started_cpu,
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
