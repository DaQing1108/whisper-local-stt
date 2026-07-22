from types import SimpleNamespace
from unittest.mock import patch

import pytest

from diarization_model_runtime import DiarizationModelManager
from diarization_service import ModelNotReadyError, _merge_speakers, _speaker_label, diarize


def _cached_manager(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)
    manager.segmentation_model_path.parent.mkdir(parents=True)
    manager.segmentation_model_path.write_bytes(b"fake-onnx")
    manager.embedding_model_path.write_bytes(b"fake-onnx")
    return manager


def test_diarize_raises_model_not_ready_when_uncached(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)
    with pytest.raises(ModelNotReadyError):
        diarize("audio.wav", [], manager=manager)


def test_speaker_label_wraps_past_alphabet():
    assert _speaker_label(0) == "Speaker A"
    assert _speaker_label(25) == "Speaker Z"
    assert _speaker_label(26) == "Speaker 27"


def test_merge_speakers_assigns_max_overlap_speaker():
    segments = [
        {"start": 0.0, "end": 5.0, "text": "hello"},
        {"start": 20.0, "end": 25.0, "text": "world"},
    ]
    speaker_segments = [
        SimpleNamespace(start=0.0, end=19.12, speaker=0),
        SimpleNamespace(start=19.12, end=34.0, speaker=1),
    ]
    augmented = _merge_speakers(segments, speaker_segments)
    assert augmented[0]["speaker"] == "Speaker A"
    assert augmented[1]["speaker"] == "Speaker B"
    assert augmented[0]["text"] == "hello"


def test_merge_speakers_leaves_speaker_none_when_no_overlap():
    segments = [{"start": 100.0, "end": 101.0, "text": "silence"}]
    speaker_segments = [SimpleNamespace(start=0.0, end=1.0, speaker=0)]
    augmented = _merge_speakers(segments, speaker_segments)
    assert augmented[0]["speaker"] is None


def test_diarize_runs_pipeline_and_merges_when_cached(tmp_path):
    manager = _cached_manager(tmp_path)
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"fake")

    fake_segment = SimpleNamespace(start=0.0, end=10.0, speaker=0)
    fake_result = SimpleNamespace(sort_by_start_time=lambda: [fake_segment])
    fake_pipeline = SimpleNamespace(process=lambda samples: fake_result)

    with patch("diarization_service._build_pipeline", return_value=fake_pipeline), \
         patch("diarization_service._read_audio", return_value=[0.0] * 16000):
        result = diarize(str(audio_path), [{"start": 0.0, "end": 1.0, "text": "hi"}], manager=manager)

    assert result == [{"start": 0.0, "end": 1.0, "text": "hi", "speaker": "Speaker A"}]
