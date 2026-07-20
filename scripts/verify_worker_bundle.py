#!/usr/bin/env python3
"""Checks for the standalone SwiftUI Worker runtime."""
from __future__ import annotations

import argparse
from pathlib import Path


def verify(bundle: Path) -> list[str]:
    errors: list[str] = []
    if not (bundle / "WhisperWorker").is_file():
        errors.append("WhisperWorker executable is missing")
    if not (bundle / "_internal" / "bin" / "ffmpeg").is_file():
        errors.append("bundled ffmpeg is missing")
    for unnecessary in ("pandas", "matplotlib", "scipy", "numba"):
        if (bundle / "_internal" / unnecessary).exists():
            errors.append(f"unnecessary package was bundled: {unnecessary}")
    if not (bundle / "_internal" / "onnxruntime").is_dir():
        errors.append("onnxruntime required by faster-whisper VAD is missing")
    vad_model = bundle / "_internal" / "faster_whisper" / "assets" / "silero_vad_v6.onnx"
    if not vad_model.is_file():
        errors.append("faster-whisper VAD model asset is missing")

    root = Path(__file__).resolve().parent.parent
    core = (root / "whisper_core.py").read_text(encoding="utf-8")
    worker = (root / "worker_entrypoint.py").read_text(encoding="utf-8")
    frozen_block = core.split("# Frozen Worker self-spawns", 1)[1].split(
        "# 開發模式", 1
    )[0]
    if "_get_system_python" in frozen_block:
        errors.append("frozen inference still probes system Python")
    if "_transcribe_frozen_worker_subprocess" not in frozen_block:
        errors.append("frozen inference does not call the bundled child helper")
    if "--inference-child" not in core or "--inference-child" not in worker:
        errors.append("bundled inference-child contract is missing")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    errors = verify(args.bundle)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("PASS: Worker bundles Python, ffmpeg, and self-hosted inference child")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
