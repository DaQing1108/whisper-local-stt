import tarfile
from unittest.mock import patch

from diarization_model_runtime import DiarizationModelManager


def test_status_reports_needs_download_when_cache_dir_empty(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)
    status = manager.status()
    assert status == {
        "cached": False,
        "segmentation_cached": False,
        "embedding_cached": False,
        "status": "needs_download",
    }


def test_status_reports_cached_when_both_files_present(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)
    manager.segmentation_model_path.parent.mkdir(parents=True)
    manager.segmentation_model_path.write_bytes(b"fake-onnx")
    manager.embedding_model_path.write_bytes(b"fake-onnx")

    status = manager.status()
    assert status["cached"] is True
    assert status["status"] == "cached"


def test_status_is_not_cached_when_only_one_file_present(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)
    manager.embedding_model_path.write_bytes(b"fake-onnx")

    status = manager.status()
    assert status["embedding_cached"] is True
    assert status["segmentation_cached"] is False
    assert status["cached"] is False
    assert status["status"] == "needs_download"


def _make_fake_segmentation_archive(archive_path, models_dir):
    """建立一個真的 tar.bz2，內含 <dir>/model.onnx，模擬下載回來的檔案。"""
    inner_dir = models_dir / "_fixture_src" / "sherpa-onnx-pyannote-segmentation-3-0"
    inner_dir.mkdir(parents=True)
    (inner_dir / "model.onnx").write_bytes(b"fake-onnx")
    with tarfile.open(archive_path, "w:bz2") as tar:
        tar.add(inner_dir, arcname="sherpa-onnx-pyannote-segmentation-3-0")


def test_warmup_downloads_only_missing_files_and_extracts_segmentation_archive(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)

    def fake_urlretrieve(url, dest_path):
        if str(dest_path).endswith(".tar.bz2"):
            _make_fake_segmentation_archive(dest_path, tmp_path)
        else:
            dest_path.write_bytes(b"fake-onnx")

    with patch("diarization_model_runtime.urllib.request.urlretrieve", side_effect=fake_urlretrieve) as mock_retrieve:
        status = manager.warmup()

    assert status["cached"] is True
    assert manager.segmentation_model_path.is_file()
    assert manager.embedding_model_path.is_file()
    # 兩個檔案各下載一次；下載完的 .tar.bz2 archive 應該被清掉，不留在 models_dir 底層
    assert mock_retrieve.call_count == 2
    assert not (tmp_path / "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2").exists()


def test_warmup_skips_download_when_already_cached(tmp_path):
    manager = DiarizationModelManager(models_dir=tmp_path)
    manager.segmentation_model_path.parent.mkdir(parents=True)
    manager.segmentation_model_path.write_bytes(b"fake-onnx")
    manager.embedding_model_path.write_bytes(b"fake-onnx")

    with patch("diarization_model_runtime.urllib.request.urlretrieve") as mock_retrieve:
        status = manager.warmup()

    mock_retrieve.assert_not_called()
    assert status["cached"] is True
