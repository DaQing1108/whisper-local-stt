#!/usr/bin/env python3
"""Live Phase 1 smoke test against worker_entrypoint.py and real Whisper models."""
from __future__ import annotations

import argparse
import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from uuid import uuid4


def command(request_id: str, name: str, payload: dict) -> str:
    return json.dumps({
        "protocol": "whisper.worker",
        "version": 1,
        "type": "command",
        "request_id": request_id,
        "command": name,
        "payload": payload,
    }, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--model", default="tiny")
    parser.add_argument("--cancel", action="store_true")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--worker-executable", type=Path)
    args = parser.parse_args()

    if not args.audio.is_absolute() or not args.audio.is_file():
        parser.error("audio must be an existing absolute path")

    root = Path(__file__).resolve().parent.parent
    worker_command = (
        [str(args.worker_executable.resolve())]
        if args.worker_executable
        else [sys.executable, "-u", str(root / "worker_entrypoint.py")]
    )
    process = subprocess.Popen(
        worker_command,
        cwd=root,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    diagnostics: list[str] = []
    output_lines: queue.Queue[str | None] = queue.Queue()

    def capture_stderr() -> None:
        assert process.stderr
        diagnostics.extend(process.stderr)

    stderr_thread = threading.Thread(target=capture_stderr, daemon=True)
    stderr_thread.start()

    def capture_stdout() -> None:
        assert process.stdout
        for output_line in process.stdout:
            output_lines.put(output_line)
        output_lines.put(None)

    stdout_thread = threading.Thread(target=capture_stdout, daemon=True)
    stdout_thread.start()
    request_id = f"smoke-{uuid4().hex[:8]}"
    deadline = time.monotonic() + args.timeout
    sent_transcribe = False
    sent_cancel = False
    terminal: dict | None = None

    try:
        assert process.stdin
        while time.monotonic() < deadline:
            remaining = max(deadline - time.monotonic(), 0)
            try:
                line = output_lines.get(timeout=remaining)
            except queue.Empty:
                break
            if line is None:
                break
            event = json.loads(line)
            print(json.dumps(event, ensure_ascii=False), flush=True)
            name = event["event"]
            if name == "ready" and not sent_transcribe:
                process.stdin.write(command(request_id, "transcribe", {
                    "audio_path": str(args.audio),
                    "model_name": args.model,
                    "language": "zh",
                    "skip_llm": True,
                }))
                process.stdin.flush()
                sent_transcribe = True
            elif name == "accepted" and args.cancel and not sent_cancel:
                process.stdin.write(command(f"cancel-{request_id}", "cancel", {
                    "job_id": event["payload"]["job_id"],
                }))
                process.stdin.flush()
                sent_cancel = True
            elif name in {"completed", "cancelled", "failed"}:
                terminal = event
                break
    finally:
        if process.stdin:
            process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)
        stderr_thread.join(timeout=1)
        stdout_thread.join(timeout=1)

    if terminal is None:
        print("worker produced no terminal event", file=sys.stderr)
        print("".join(diagnostics)[-4000:], file=sys.stderr)
        return 1
    expected = "cancelled" if args.cancel else "completed"
    if terminal["event"] != expected:
        print("".join(diagnostics)[-4000:], file=sys.stderr)
        return 1
    if not args.cancel and not terminal["payload"].get("text", "").strip():
        print("completed event has empty transcript", file=sys.stderr)
        return 1
    print(f"PASS: real Worker reached {expected} with model={args.model}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
