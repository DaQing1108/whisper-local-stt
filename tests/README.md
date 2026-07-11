# Whisper STT 測試說明

## 執行方式

### Unit Tests（每次改完 code 就跑）

```bash
# 不需要 server，184 個測試，約 40s
/Users/daqingliao/Library/Python/3.9/bin/pytest tests/unit/ -v
```

### Integration Tests（需要 server）

```bash
# 啟動 server（測試模式）
WHISPER_TEST=1 python3 app.py &

# 跑 integration tests
/Users/daqingliao/Library/Python/3.9/bin/pytest tests/integration/ -v -m integration
```

### E2E Tests（需要 server + Playwright）

```bash
pip install playwright pytest-playwright
playwright install chromium

WHISPER_TEST=1 python3 app.py &
/Users/daqingliao/Library/Python/3.9/bin/pytest tests/e2e/ -v -m e2e
```

### Accuracy Tests（release 前手動執行）

```bash
# 先準備 tests/accuracy/reference/*.wav 參考音檔
/Users/daqingliao/Library/Python/3.9/bin/pytest tests/accuracy/ -v --run-accuracy
```

---

## 測試結構

```
tests/
├── conftest.py                     # 共用 fixtures（WAV 產生、server 連線）
├── unit/                           # 不需要 server，純函式測試
│   ├── test_hallucination.py       # is_hallucination() 幻覺偵測
│   ├── test_prompts.py             # build_prompt() × domain/extra_terms
│   ├── test_llm_post.py            # LLM timeout、key 驗證、meta-response 防護
│   └── test_notion_blocks.py       # build_notion_blocks() 格式結構
├── integration/                    # 需要 WHISPER_TEST=1 server
│   ├── test_mic_flow.py            # chunk 注入 → 轉錄 → finish session
│   └── test_system_audio_flow.py   # 系統音訊流程 + Obsidian 存檔
├── e2e/
│   └── test_ui.py                  # Playwright UI 自動化
├── accuracy/                       # release 前執行，需要 --run-accuracy
│   ├── reference/                  # 放參考 WAV 音檔
│   └── test_cer.py                 # 字元錯誤率（CER）回歸
└── manual_checklist.md             # 手動測試清單（TCC、真實語音）
```

---

## Release 流程

1. `pytest tests/unit/` — 184 個 unit tests 全過
2. `WHISPER_TEST=1 python3 app.py & pytest tests/integration/ -m integration`
3. `pytest tests/accuracy/ --run-accuracy` — CER 準確率回歸（需先備妥 `tests/accuracy/reference/*.wav`）
4. `bash package.sh` — 打包 + smoke test
5. 照 `manual_checklist.md` 手動跑（5-10 分鐘）
