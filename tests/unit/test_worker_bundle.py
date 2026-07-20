from pathlib import Path

from scripts.verify_worker_bundle import verify


def test_verifier_rejects_missing_bundle(tmp_path):
    errors = verify(tmp_path)
    assert "WhisperWorker executable is missing" in errors
    assert "bundled ffmpeg is missing" in errors
    assert not any("system Python" in error for error in errors)


def test_worker_spec_excludes_mlx_and_torch():
    spec = Path("worker.spec").read_text(encoding="utf-8")
    assert '"mlx_whisper"' in spec
    assert '"torch"' in spec
    assert '("bin/ffmpeg", "bin")' in spec
    assert 'collect_data_files("faster_whisper")' in spec
    for unnecessary in ("pandas", "matplotlib", "scipy", "numba"):
        assert f'"{unnecessary}"' in spec
