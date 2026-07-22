"""diarization_service.py — sherpa-onnx speaker diarization + speaker-label merge.

Wraps sherpa_onnx.OfflineSpeakerDiarization construction and runs it against a
16kHz mono audio file, then merges the resulting speaker segments onto an
existing list of transcript segments (produced by a prior `transcribe`
command) by time overlap. See
docs/Whisper_Phase3_Diarization_ONNX_Runtime_Spike_v2.md for the config shape
this was verified against.
"""
from __future__ import annotations

from diarization_model_runtime import DiarizationModelManager

_SAMPLE_RATE = 16000
_SPEAKER_NAMES = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"


class ModelNotReadyError(RuntimeError):
    """Raised when diarization is requested before models are downloaded."""


def _speaker_label(index: int) -> str:
    if index < len(_SPEAKER_NAMES):
        return f"Speaker {_SPEAKER_NAMES[index]}"
    return f"Speaker {index + 1}"


def _build_pipeline(manager: DiarizationModelManager):
    import sherpa_onnx

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(manager.segmentation_model_path),
            ),
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(manager.embedding_model_path),
        ),
        clustering=sherpa_onnx.FastClusteringConfig(),
    )
    if not config.validate():
        raise RuntimeError("invalid sherpa_onnx diarization config")
    return sherpa_onnx.OfflineSpeakerDiarization(config)


def _read_audio(audio_path: str):
    import soundfile as sf

    samples, sample_rate = sf.read(audio_path, dtype="float32", always_2d=False)
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    if sample_rate != _SAMPLE_RATE:
        import soxr

        samples = soxr.resample(samples, sample_rate, _SAMPLE_RATE)
    return samples


def _merge_speakers(segments: list[dict], speaker_segments) -> list[dict]:
    augmented = []
    for segment in segments:
        start = float(segment["start"])
        end = float(segment["end"])
        best_speaker: int | None = None
        best_overlap = 0.0
        for speaker_segment in speaker_segments:
            overlap = min(end, speaker_segment.end) - max(start, speaker_segment.start)
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = speaker_segment.speaker
        augmented.append({
            **segment,
            "speaker": _speaker_label(best_speaker) if best_speaker is not None else None,
        })
    return augmented


def diarize(
    audio_path: str,
    segments: list[dict],
    manager: DiarizationModelManager | None = None,
) -> list[dict]:
    manager = manager or DiarizationModelManager()
    if not manager.status()["cached"]:
        raise ModelNotReadyError("diarization models are not downloaded yet")
    pipeline = _build_pipeline(manager)
    samples = _read_audio(audio_path)
    result = pipeline.process(samples).sort_by_start_time()
    return _merge_speakers(segments, result)
