"""transcribe_common.py — 三條音訊管線共用的常數與工具函式。"""
from __future__ import annotations

import logging
import re
import unicodedata
from collections import Counter

# Whisper phantom output during near-silence: only timestamps, no speech words.
_TIMESTAMP_ONLY_RE = re.compile(r'^[\s\[\]\d:.–\-]+$')

# Short (2-8 char) substring that repeats 3+ times back-to-back, anywhere in the text
# (unlike the phrase-level rule below, which only checks substrings anchored at index 0).
_SHORT_REPEAT_RE = re.compile(r'(.{2,8}?)\1{2,}')

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

# Fixed fake-subtitle credits Whisper emits from training-data artifacts. Deliberately
# excludes generic sign-offs (謝謝觀看／下次見／歡迎訂閱…): a presenter in a recorded video
# really says those, and dropping them would delete genuine content.
_FAKE_SUBTITLE_MAX_LEN = 40
_FAKE_SUBTITLE_RES = [re.compile(p) for p in (
    r'字幕志[願愿]者',
    r'字幕由.{0,12}提供',
    r'Amara\.org',
    r'請不吝點贊',
    r'请不吝点赞',
    r'明鏡與點點欄目',
)]

# Consecutive identical segments (after normalisation) kicking in at this run length / size.
_REPEAT_RUN_MIN = 3
_REPEAT_MIN_NORMALIZED_LEN = 4
_NORMALIZE_RE = re.compile(r'[\W_]+')

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
    5. Phrase-level 重複（僅比對從文字開頭算起的子串，重複覆蓋 > 60%）
    6. 含數字的短片語重複（不限文字開頭位置，如「1個,1個,1個,1個,1個,1個。」這種
       Whisper 卡在數字計數迴圈的已知幻覺模式；規則 5 只比對開頭子串會漏掉這類
       出現在文字中段的重複）
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

    # 6. Digit-bearing short-phrase repetition, not anchored at text start.
    #    Only flags units containing a digit: this catches Whisper's known numeric
    #    counting-loop hallucination (e.g. "1個,1個,1個,1個,1個,1個。") without
    #    colliding with legitimate repeated phrases like "我們可以 我們可以 ..."
    #    (no digit) or digit runs inside real numbers like phone numbers (unit
    #    length >= 2 excludes a single repeated digit such as "1111").
    short_repeat = _SHORT_REPEAT_RE.search(text)
    if short_repeat and any(ch.isdigit() for ch in short_repeat.group(1)):
        logging.warning(
            "[Hallucination] chunk rejected: digit-bearing unit '%s' repeats in '%s'",
            short_repeat.group(1), short_repeat.group(0)[:60],
        )
        return True

    return False


def _is_fake_subtitle(text: str) -> bool:
    return len(text) <= _FAKE_SUBTITLE_MAX_LEN and any(r.search(text) for r in _FAKE_SUBTITLE_RES)


def _collapse_consecutive_repeats(segments: list[dict]) -> tuple[list[dict], int]:
    """Keep only the first of ≥3 consecutive segments whose normalised text is identical
    (and ≥4 chars once punctuation/whitespace/underscores are stripped). Returns (kept, dropped)."""
    kept: list[dict] = []
    dropped = 0
    index = 0
    while index < len(segments):
        key = _NORMALIZE_RE.sub('', segments[index].get("text", ""))
        end = index + 1
        while end < len(segments) and _NORMALIZE_RE.sub('', segments[end].get("text", "")) == key:
            end += 1
        run = end - index
        if run >= _REPEAT_RUN_MIN and len(key) >= _REPEAT_MIN_NORMALIZED_LEN:
            kept.append(segments[index])
            dropped += run - 1
            logging.warning(
                "[CleanSegments] consecutive-repeat rule dropped %d segment(s) repeating '%s'",
                run - 1, key[:10],
            )
        else:
            kept.extend(segments[index:end])
        index = end
    return kept, dropped


def clean_segments(segments: list[dict]) -> list[dict]:
    """移除空白、hallucination、重複 timestamp、連續重複與固定假字幕的 phantom segments。

    在 segment list 層級做後處理，補上 is_hallucination() 對單一 chunk
    全文偵測的盲點（個別 segment 可能太短不觸發全文偵測，但大量空白
    segment 堆疊後會產生逐字稿的垃圾輸出）。
    """
    cleaned: list[dict] = []
    seen_keys: set[tuple] = set()
    fake_subtitles = 0

    for seg in segments:
        text = seg.get("text", "").strip()

        # 空白 / 近空 segment（≤ 1 字元）直接丟棄
        if len(text) <= 1:
            continue

        # 單一 segment 的 hallucination 偵測（對超過 20 字的 segment 才跑）
        if len(text) >= 20 and is_hallucination(text):
            continue

        # 固定假字幕（如「字幕志願者 …」），只丟短段落
        if _is_fake_subtitle(text):
            fake_subtitles += 1
            continue

        # 重複 timestamp 去重：相同 start 時間 + 相同 text → 只保留第一個
        key = (round(seg.get("start", 0), 1), text)
        if key in seen_keys:
            continue
        seen_keys.add(key)

        cleaned.append(seg)

    if fake_subtitles:
        logging.warning("[CleanSegments] fake-subtitle rule dropped %d segment(s)", fake_subtitles)
    cleaned, _ = _collapse_consecutive_repeats(cleaned)

    if len(cleaned) < len(segments):
        logging.info(
            "[CleanSegments] removed %d/%d phantom/hallucination segments",
            len(segments) - len(cleaned), len(segments),
        )

    return cleaned
