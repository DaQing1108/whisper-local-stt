"""sse.py — SSE 廣播狀態與轉錄排隊 semaphore。"""
from __future__ import annotations

import json
import threading
from queue import Empty, Queue

_sse_queues: list[Queue] = []
_sse_lock = threading.Lock()

# 同時只允許一個轉錄任務，避免多個 mlx-whisper subprocess 競爭 Neural Engine
_transcribe_sem = threading.Semaphore(1)


def broadcast(event: str, data: dict) -> None:
    msg = f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
    with _sse_lock:
        dead = []
        for q in _sse_queues:
            try:
                q.put_nowait(msg)
            except Exception:
                dead.append(q)
        for q in dead:
            _sse_queues.remove(q)
