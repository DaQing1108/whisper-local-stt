"""diarization_model_runtime.py — Model cache inspection and download for the
sherpa-onnx (ONNX Runtime, no torch) speaker diarization models.

Mirrors the status()/warmup() shape of model_runtime.ModelRuntimeManager, but
these models are GitHub Release assets (not a Hugging Face repo), so they get
their own cache directory and download path instead of huggingface_hub.
See docs/Whisper_Phase3_Diarization_ONNX_Runtime_Spike_v2.md for the spike
that established this direction.
"""
from __future__ import annotations

import tarfile
import urllib.request
from pathlib import Path

from constants import USER_DATA_DIR

_RELEASE_BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
_SEGMENTATION_TAG = "speaker-segmentation-models"
_SEGMENTATION_ASSET = "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
_SEGMENTATION_DIR_NAME = "sherpa-onnx-pyannote-segmentation-3-0"
_EMBEDDING_TAG = "speaker-recongition-models"
_EMBEDDING_ASSET = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

DEFAULT_MODELS_DIR = USER_DATA_DIR / "models" / "diarization"


class DiarizationModelManager:
    def __init__(self, models_dir: Path | None = None):
        self._models_dir = models_dir or DEFAULT_MODELS_DIR

    @property
    def segmentation_model_path(self) -> Path:
        return self._models_dir / _SEGMENTATION_DIR_NAME / "model.onnx"

    @property
    def embedding_model_path(self) -> Path:
        return self._models_dir / _EMBEDDING_ASSET

    def status(self) -> dict:
        segmentation_cached = self.segmentation_model_path.is_file()
        embedding_cached = self.embedding_model_path.is_file()
        cached = segmentation_cached and embedding_cached
        return {
            "cached": cached,
            "segmentation_cached": segmentation_cached,
            "embedding_cached": embedding_cached,
            "status": "cached" if cached else "needs_download",
        }

    def warmup(self) -> dict:
        self._models_dir.mkdir(parents=True, exist_ok=True)
        if not self.segmentation_model_path.is_file():
            self._download_and_extract_segmentation()
        if not self.embedding_model_path.is_file():
            self._download_embedding()
        return self.status()

    def _download_and_extract_segmentation(self) -> None:
        url = f"{_RELEASE_BASE}/{_SEGMENTATION_TAG}/{_SEGMENTATION_ASSET}"
        archive_path = self._models_dir / _SEGMENTATION_ASSET
        urllib.request.urlretrieve(url, archive_path)
        with tarfile.open(archive_path, "r:bz2") as tar:
            tar.extractall(self._models_dir)
        archive_path.unlink(missing_ok=True)

    def _download_embedding(self) -> None:
        url = f"{_RELEASE_BASE}/{_EMBEDDING_TAG}/{_EMBEDDING_ASSET}"
        urllib.request.urlretrieve(url, self.embedding_model_path)
