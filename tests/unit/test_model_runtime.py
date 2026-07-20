from model_runtime import ModelRuntimeManager


def test_repository_id_targets_same_faster_whisper_cache_used_by_inference_child():
    assert ModelRuntimeManager.repository_id("base") == "Systran/faster-whisper-base"
    assert ModelRuntimeManager.repository_id("large-v3") == "Systran/faster-whisper-large-v3"
