"""transcribe_common.py — 三條音訊管線共用的常數與工具函式。"""
from __future__ import annotations

import logging
import re
import unicodedata
from collections import Counter

# Whisper phantom output during near-silence: only timestamps, no speech words.
_TIMESTAMP_ONLY_RE = re.compile(r'^[\s\[\]\d:.–\-]+$')

# Foreign script Unicode blocks (Cyrillic, Arabic, Thai, etc.)
# Excludes CJK, Latin, Japanese kana, Korean — these are expected in zh/en/ja context.
_FOREIGN_SCRIPT_RE = re.compile(
    r'[\u0400-\u04FF'   # Cyrillic
    r'\u0600-\u06FF'    # Arabic
    r'\u0E00-\u0E7F'    # Thai
    r'\u0900-\u097F'    # Devanagari
    r'\u0980-\u09FF'    # Bengali
    r'\u0A80-\u0AFF'    # Gujarati
    r'\u0B80-\u0BFF'    # Tamil
    r'\u10A0-\u10FF'    # Georgian
    r'\u0530-\u058F'    # Armenian
    r'\u1200-\u137F'    # Ethiopic
    r']'
)

DOMAIN_LABELS: dict[str, str] = {
    "media":   "媒體",
    "medical": "醫療",
    "legal":   "法律",
    "tech":    "科技",
    "general": "通用",
}


def is_hallucination(text: str) -> bool:
    """偵測 Whisper 重複幻覺輸出。

    偵測規則（依序）：
    1. Timestamp-only phantom（如「[00:32] [00:32]」）
    2. 中文 character-level 重複（如「好」× 200，無空格分詞無法靠 word-level 偵測）
    3. Foreign script 污染（如 Cyrillic 字元佔比 > 30%）
    4. Word-level 重複（英文/空格分詞場景）
    5. Phrase-level 重複（任意子串重複覆蓋 > 60%）
    """
    if not text or len(text) < 20:
        return False

    # 1. Timestamp-only phantom: no speech words, only markers like [00:32]
    if _TIMESTAMP_ONLY_RE.match(text.strip()):
        logging.warning("[Hallucination] chunk rejected: timestamp-only phantom '%s'", text[:60])
        return True

    # 2. Character-level repetition (catches CJK no-space repeats like 好好好好...)
    stripped = text.replace(' ', '').replace('\n', '')
    if stripped:
        char_counts = Counter(stripped)
        most_char, char_freq = char_counts.most_common(1)[0]
        total_chars = len(stripped)
        if char_freq > 10 and total_chars > 0 and char_freq / total_chars > 0.6:
            logging.warning(
                "[Hallucination] chunk rejected: char '%s' repeated %d/%d times",
                most_char, char_freq, total_chars,
            )
            return True

    # 3. Foreign script contamination (Cyrillic, Arabic, etc. in zh/en context)
    if len(text) > 20:
        foreign_count = len(_FOREIGN_SCRIPT_RE.findall(text))
        text_len = len(text.replace(' ', '').replace('\n', ''))
        if text_len > 0 and foreign_count / text_len > 0.3:
            logging.warning(
                "[Hallucination] chunk rejected: foreign script %d/%d chars",
                foreign_count, text_len,
            )
            return True

    # 4. Word-level repetition (space-delimited, works for English / mixed text)
    words = text.split()
    if words:
        counts = Counter(words)
        most_common, freq = counts.most_common(1)[0]
        if freq > 15 and freq / len(words) > 0.6:
            logging.warning("[Hallucination] chunk rejected: '%s' repeated %d/%d times",
                            most_common, freq, len(words))
            return True

    # 5. Phrase-level repetition (sliding window from text start)
    for length in range(4, min(20, len(text) // 4)):
        phrase = text[:length]
        count = text.count(phrase)
        if count > 10 and count * length > len(text) * 0.6:
            logging.warning("[Hallucination] chunk rejected: '%s' repeats %d times",
                            phrase, count)
            return True

    return False


def clean_segments(segments: list[dict]) -> list[dict]:
    """移除空白、hallucination、重複 timestamp 的 phantom segments。

    在 segment list 層級做後處理，補上 is_hallucination() 對單一 chunk
    全文偵測的盲點（個別 segment 可能太短不觸發全文偵測，但大量空白
    segment 堆疊後會產生逐字稿的垃圾輸出）。
    """
    cleaned: list[dict] = []
    seen_keys: set[tuple] = set()

    for seg in segments:
        text = seg.get("text", "").strip()

        # 空白 / 近空 segment（≤ 1 字元）直接丟棄
        if len(text) <= 1:
            continue

        # 單一 segment 的 hallucination 偵測（對超過 20 字的 segment 才跑）
        if len(text) >= 20 and is_hallucination(text):
            continue

        # 重複 timestamp 去重：相同 start 時間 + 相同 text → 只保留第一個
        key = (round(seg.get("start", 0), 1), text)
        if key in seen_keys:
            continue
        seen_keys.add(key)

        cleaned.append(seg)

    if len(cleaned) < len(segments):
        logging.info(
            "[CleanSegments] removed %d/%d phantom/hallucination segments",
            len(segments) - len(cleaned), len(segments),
        )

    return cleaned
