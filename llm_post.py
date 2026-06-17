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

_LLM_PUNCT_PROMPT = """\
你是繁體中文會議記錄的標點符號專家。
以下文字是 ASR 語音辨識的原始輸出（每行一個自然停頓段落）。
請在保持原文不變的前提下：
1. 在適當位置加入逗號（，）區分子句
2. 修正句尾標點（句號。問號？感嘆號！）
3. 保留每行的換行結構
4. 不要修改任何詞彙內容

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

    system_prompt = _LLM_PUNCT_PROMPT
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
        with _req.urlopen(req, timeout=60) as resp:
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
                with _req.urlopen(req, timeout=60) as resp:
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
        with _req.urlopen(req, timeout=60) as resp:
            return _json.loads(resp.read())["choices"][0]["message"]["content"]


def llm_punctuate(text: str, extra_terms: str = "") -> str:
    """自動選擇可用的 LLM provider 精修標點與同音詞糾錯。失敗時回傳原文。"""
    if len(text.strip()) < 10:  # 少於 10 字無意義，跳過 LLM
        return text

    for provider, env_var in _LLM_PROVIDERS:
        api_key = os.environ.get(env_var, "")
        if _is_valid_key(provider, api_key):
            break
    else:
        return text

    try:
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

        results = [_llm_call_chunk(c, provider, api_key, extra_terms) for c in chunks]
        refined = "\n".join(results)

        # 防護：若 LLM 回傳明顯是 meta-response（比輸入長超過 3 倍），回傳原文
        if len(refined) > len(text) * 3:
            logging.warning("[LLM:%s] 回傳疑似 meta-response（%d → %d 字），改用原始輸出",
                            provider, len(text), len(refined))
            return text

        logging.info("[LLM:%s] 標點後處理完成（%d → %d 字）", provider, len(text), len(refined))
        return refined

    except Exception as e:
        logging.warning("[LLM:%s] 標點後處理失敗，使用原始輸出：%s", provider, e)
        return text
