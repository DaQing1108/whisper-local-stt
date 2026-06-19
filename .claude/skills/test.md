---
name: test
description: Run Whisper STT test suite. Use /test to run unit tests, /test integration for integration tests, /test all for everything.
---

# /test — Whisper STT 測試套件

## 使用方式

```
/test                  → unit tests（61 個，~30s，不需要 server）
/test integration      → integration tests（需要 server）
/test all              → unit + integration
/test accuracy         → CER 回歸測試（release 前）
```

## 執行流程

根據參數選擇對應目標：

**unit（預設）**：

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper
make test
```

**integration**：

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper
# 先確認 server 是否已啟動
lsof -i :5001 | grep LISTEN || echo "⚠️ Server 未啟動，請先執行：WHISPER_TEST=1 python3 app.py"
make test-integration
```

**all**：

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper
make test && make test-integration
```

**accuracy**：

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper
make test-accuracy
```

## 完成後

- 若有 FAILED：分析失敗原因，判斷是 implementation 問題還是 test 問題
- 修復後重新執行確認全部通過
- **不要修改 test 來讓它通過**，要修 implementation
