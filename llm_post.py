"""llm_post.py — LLM 標點後處理與同音詞糾錯。

支援 Claude / Gemini / OpenAI，優先順序：
  ANTHROPIC_API_KEY > GEMINI_API_KEY > OPENAI_API_KEY
費用估算（120 分鐘會議 ≈ 8000 tokens）：
  Claude Haiku  ≈ NT$0.03
  Gemini Flash  ≈ NT$0.01
  GPT-4o-mini   ≈ NT$0.05
未設定任何 key 時靜默跳過。
"""
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
    ("claude", "ANTHROPIC_API_KEY"),
    ("openai", "OPENAI_API_KEY"),
]


def has_llm_key() -> bool:
    return any(os.environ.get(env) for _, env in _LLM_PROVIDERS)


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
    if not text.strip():
        return text

    for provider, env_var in _LLM_PROVIDERS:
        api_key = os.environ.get(env_var, "")
        if api_key:
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
        logging.info("[LLM:%s] 標點後處理完成（%d → %d 字）", provider, len(text), len(refined))
        return refined

    except Exception as e:
        logging.warning("[LLM:%s] 標點後處理失敗，使用原始輸出：%s", provider, e)
        return text
