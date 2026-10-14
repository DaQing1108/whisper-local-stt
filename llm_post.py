"""llm_post.py — LLM 標點後處理與同音詞糾錯。

支援 Claude / Gemini / OpenAI，優先順序：
  ANTHROPIC_API_KEY > GEMINI_API_KEY > OPENAI_API_KEY
費用估算（120 分鐘會議 ≈ 8000 tokens）：
  Claude Haiku  ≈ NT$0.03
  Gemini Flash  ≈ NT$0.01
  GPT-4o-mini   ≈ NT$0.05
未設定任何 key 時靜默跳過。
"""
# NOTE: provider 優先順序須與 integrations._call_llm 保持一致
from __future__ import annotations

import logging
import os
import unicodedata
from collections import Counter

_LLM_PUNCT_PROMPT = """\
你是繁體中文（台灣）會議記錄的標點符號與用字專家。
以下文字是 ASR 語音辨識的原始輸出（每行一個自然停頓段落）。
請執行以下處理：
1. 將所有簡體中文字詞轉換為繁體中文（台灣慣用寫法），例如「信息」→「資訊」、「打印」→「列印」、「程序」→「程式」
2. 在適當位置加入逗號（，）區分子句
3. 修正句尾標點（句號。問號？感嘆號！）
4. 保留每行的換行結構
5. 除了簡繁轉換外，不要修改其他詞彙內容

只輸出修正後的文字，不要加解釋。\
"""

_LLM_PROVIDERS = [
    ("claude",  "ANTHROPIC_API_KEY"),
    ("gemini",  "GEMINI_API_KEY"),
    ("openai",  "OPENAI_API_KEY"),
]


_KEY_MIN_LEN = {"claude": 20, "gemini": 20, "openai": 20}


def _is_valid_key(provider: str, key: str) -> bool:
    """Reject obviously fake keys (test placeholders, too short)."""
    if not key or len(key) < _KEY_MIN_LEN.get(provider, 20):
        return False
    lower = key.lower()
    for placeholder in ("test", "fake", "dummy", "example", "your_key", "xxx", "abc"):
        if placeholder in lower:
            return False
    return True


def has_llm_key() -> bool:
    return any(
        _is_valid_key(p, os.environ.get(env, ""))
        for p, env in _LLM_PROVIDERS
    )


def _llm_call_chunk(chunk: str, provider: str, api_key: str, extra_terms: str = "") -> str:
    import json as _json
    import urllib.request as _req

    custom = os.environ.get("LLM_CUSTOM_PROMPT", "").strip()
    system_prompt = custom[:2000] if custom else _LLM_PUNCT_PROMPT
    if extra_terms:
        system_prompt += (
            f"\n5. 此次會議專有名詞與期望的拼寫包含：{extra_terms}。"
            "如果 ASR 原始輸出包含這些專有名詞的同音錯字、發音相近字或簡寫，"
            "請優先將其糾正為正確的拼寫項目（例如若有「拜登套斯」或「bag and pulse」，"
            "請更正為「Bag & Pulse」）。"
        )

    if provider == "claude":
        payload = _json.dumps({
            "model":      "claude-haiku-4-5",
            "max_tokens": 4096,
            "system":     system_prompt,
            "messages":   [{"role": "user", "content": chunk}],
        }).encode()
        req = _req.Request(
            "https://api.anthropic.com/v1/messages",
            data=payload,
            headers={
                "Content-Type":      "application/json",
                "x-api-key":         api_key,
                "anthropic-version": "2023-06-01",
            },
        )
        with _req.urlopen(req, timeout=20) as resp:
            return _json.loads(resp.read())["content"][0]["text"]

    elif provider == "gemini":
        body = _json.dumps({
            "system_instruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"parts": [{"text": chunk}]}],
        }).encode()
        for model in ("gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"):
            try:
                req = _req.Request(
                    f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}",
                    data=body,
                    headers={"Content-Type": "application/json"},
                )
                with _req.urlopen(req, timeout=20) as resp:
                    return _json.loads(resp.read())["candidates"][0]["content"]["parts"][0]["text"]
            except Exception:
                continue
        raise RuntimeError("所有 Gemini 模型均不可用")

    else:  # openai
        payload = _json.dumps({
            "model": "gpt-4o-mini",
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": chunk},
            ],
            "temperature": 0,
        }).encode()
        req = _req.Request(
            "https://api.openai.com/v1/chat/completions",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
        )
        with _req.urlopen(req, timeout=20) as resp:
            return _json.loads(resp.read())["choices"][0]["message"]["content"]


_LLM_TOTAL_TIMEOUT = 30  # 整體 LLM 後處理上限（秒）

# ── LLM 輸出驗證：輸出不像「原文加標點」時該段退回原文 ─────────────────
# 後設回覆（拒答、要求補資料、自我說明）常見樣式；原文本身含有時不算。
_META_REPLY_MARKERS = (
    "無法處理", "請提供", "我會按照", "作為AI", "作為一個", "ASR", "語音辨識原始輸出",
    "I cannot", "I can't", "As an AI", "Please provide",
)
PUNCT_LENGTH_RATIO_MIN = 0.7   # 去標點與空白後，輸出字數 ÷ 原文字數 的下限
PUNCT_LENGTH_RATIO_MAX = 1.3   # 上限
PUNCT_LINE_CHECK_MIN_LINES = 3  # 原文至少幾行才檢查行數
PUNCT_LINE_DIFF_MAX = 0.2       # 非空行數差異上限（相對原文）


def _content_length(text: str) -> int:
    """去除空白與標點後的字數。"""
    return sum(
        1 for ch in text
        if not ch.isspace() and not unicodedata.category(ch).startswith("P")
    )


def _non_empty_lines(text: str) -> int:
    return sum(1 for line in text.split("\n") if line.strip())


def is_plausible_punctuation(
    original: str, output: str, check_structure: bool = True,
) -> tuple[bool, str]:
    """判斷 LLM 輸出是否像「原文加標點」；回傳 (是否通過, reason 代碼)。

    reason：ok / meta_reply / length_ratio / line_count。
    check_structure=False 時只檢查後設回覆：使用者自訂 prompt（LLM_CUSTOM_PROMPT）可能
    刻意刪贅字或改寫，長度與行數本來就會變。
    """
    original_folded, output_folded = original.casefold(), output.casefold()
    for marker in _META_REPLY_MARKERS:
        folded = marker.casefold()
        if folded in output_folded and folded not in original_folded:
            return False, "meta_reply"
    if not check_structure:
        return True, "ok"

    original_len, output_len = _content_length(original), _content_length(output)
    if original_len == 0:
        if output_len:
            return False, "length_ratio"
    else:
        ratio = output_len / original_len
        if not PUNCT_LENGTH_RATIO_MIN <= ratio <= PUNCT_LENGTH_RATIO_MAX:
            return False, "length_ratio"

    original_lines = _non_empty_lines(original)
    if original_lines >= PUNCT_LINE_CHECK_MIN_LINES:
        if abs(_non_empty_lines(output) - original_lines) / original_lines > PUNCT_LINE_DIFF_MAX:
            return False, "line_count"
    return True, "ok"


def _validated_chunks(chunks: list[str], outputs: list[str], provider: str) -> list[str]:
    """逐段驗證 LLM 輸出；不通過的段落改用原文。log 只記 reason 代碼與數量。"""
    check_structure = not os.environ.get("LLM_CUSTOM_PROMPT", "").strip()
    rejected: Counter = Counter()
    results = []
    for chunk, output in zip(chunks, outputs):
        ok, reason = is_plausible_punctuation(chunk, output, check_structure)
        if ok:
            results.append(output)
        else:
            rejected[reason] += 1
            results.append(chunk)
    if rejected:
        logging.warning(
            "[LLM:%s] %d/%d 段輸出未通過驗證，改用原文：%s",
            provider, sum(rejected.values()), len(chunks),
            ", ".join(f"{reason}={count}" for reason, count in sorted(rejected.items())),
        )
    return results


def _llm_punctuate_inner(text: str, extra_terms: str, provider: str, api_key: str) -> str:
    MAX_CHARS = 1500
    lines = text.split("\n")
    chunks: list[str] = []
    buf: list[str] = []
    buf_len = 0
    for line in lines:
        if buf_len + len(line) > MAX_CHARS and buf:
            chunks.append("\n".join(buf))
            buf, buf_len = [], 0
        buf.append(line)
        buf_len += len(line)
    if buf:
        chunks.append("\n".join(buf))

    outputs = [_llm_call_chunk(c, provider, api_key, extra_terms) for c in chunks]
    refined = "\n".join(_validated_chunks(chunks, outputs, provider))

    if len(refined) > len(text) * 3:
        logging.warning("[LLM:%s] 回傳疑似 meta-response（%d → %d 字），改用原始輸出",
                        provider, len(text), len(refined))
        return text

    logging.info("[LLM:%s] 標點後處理完成（%d → %d 字）", provider, len(text), len(refined))
    return refined


def llm_punctuate(text: str, extra_terms: str = "") -> str:
    """自動選擇可用的 LLM provider 精修標點與同音詞糾錯。失敗或逾時時回傳原文。"""
    import threading

    if len(text.strip()) < 10:
        return text

    for provider, env_var in _LLM_PROVIDERS:
        api_key = os.environ.get(env_var, "")
        if _is_valid_key(provider, api_key):
            break
    else:
        return text

    result_box: list[str] = []
    error_box:  list[Exception] = []

    def _worker():
        try:
            result_box.append(_llm_punctuate_inner(text, extra_terms, provider, api_key))
        except Exception as e:
            error_box.append(e)

    t = threading.Thread(target=_worker, daemon=True)
    t.start()
    t.join(timeout=_LLM_TOTAL_TIMEOUT)

    if t.is_alive():
        logging.warning("[LLM:%s] 標點後處理超過 %ds，使用原始輸出", provider, _LLM_TOTAL_TIMEOUT)
        return text
    if error_box:
        logging.warning("[LLM:%s] 標點後處理失敗，使用原始輸出：%s", provider, error_box[0])
        return text
    return result_box[0] if result_box else text
