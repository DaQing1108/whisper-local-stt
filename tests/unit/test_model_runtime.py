from model_runtime import ModelRuntimeManager


def test_repository_id_targets_same_faster_whisper_cache_used_by_inference_child():
    assert ModelRuntimeManager.repository_id("base") == "Systran/faster-whisper-base"
    assert ModelRuntimeManager.repository_id("large-v3") == "Systran/faster-whisper-large-v3"


def test_turbo_maps_to_mobiuslabs_repository_and_others_unchanged():
    assert ModelRuntimeManager.repository_id("large-v3-turbo") == "mobiuslabsgmbh/faster-whisper-large-v3-turbo"
    assert ModelRuntimeManager.repository_id("large-v3") == "Systran/faster-whisper-large-v3"
    assert ModelRuntimeManager.repository_id("small") == "Systran/faster-whisper-small"
