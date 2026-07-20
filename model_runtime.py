"""Model cache inspection and explicit faster-whisper warmup for the bundled Worker."""
from __future__ import annotations

from pathlib import Path


class ModelRuntimeManager:
    def __init__(self):
        pass

    @staticmethod
    def repository_id(model_name: str) -> str:
        return f"Systran/faster-whisper-{model_name}"

    def status(self, model_name: str) -> dict:
        repository = self.repository_id(model_name)
        try:
            from huggingface_hub import scan_cache_dir
            cache = scan_cache_dir()
            cached = any(repo.repo_id == repository and repo.revisions for repo in cache.repos)
        except Exception:
            cached = False
        return {
            "model_name": model_name,
            "cached": cached,
            "loaded": False,
            "status": "cached" if cached else "needs_download",
        }

    def warmup(self, model_name: str) -> dict:
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id=self.repository_id(model_name))
        return self.status(model_name)
