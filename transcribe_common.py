"""transcribe_common.py — 三條音訊管線共用的常數與工具函式。"""
from __future__ import annotations

import logging
from collections import Counter

DOMAIN_LABELS: dict[str, str] = {
    "media":   "媒體",
    "medical": "醫療",
    "legal":   "法律",
    "tech":    "科技",
    "general": "通用",
}


def is_hallucination(text: str) -> bool:
    """偵測 Whisper 重複幻覺輸出（例如「我們可以看到」× 100）。

    當單一詞彙或短片語佔整段文字 60% 以上且出現 10 次以上，視為幻覺並回傳 True。
    """
    if not text or len(text) < 20:
        return False
    words = text.split()
    if not words:
        return False
    counts = Counter(words)
    most_common, freq = counts.most_common(1)[0]
    if freq > 15 and freq / len(words) > 0.6:
        logging.warning("[Hallucination] chunk rejected: '%s' repeated %d/%d times",
                        most_common, freq, len(words))
        return True
    for length in range(4, min(20, len(text) // 4)):
        phrase = text[:length]
        count = text.count(phrase)
        if count > 10 and count * length > len(text) * 0.6:
            logging.warning("[Hallucination] chunk rejected: '%s' repeats %d times",
                            phrase, count)
            return True
    return False
