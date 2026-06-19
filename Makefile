PYTEST := $(shell find /Users/$(USER)/Library/Python -name pytest -type f 2>/dev/null | head -1)
ifeq ($(PYTEST),)
PYTEST := python3 -m pytest
endif

.PHONY: test test-integration test-e2e test-accuracy help

## 預設：只跑 unit tests（不需要 server，約 30 秒）
test:
	$(PYTEST) tests/unit/ -v

## Integration tests（需先啟動 server：make server）
test-integration:
	$(PYTEST) tests/integration/ -v -m integration

## E2E tests（需先安裝 playwright：pip install pytest-playwright && playwright install chromium）
test-e2e:
	$(PYTEST) tests/e2e/ -v -m e2e

## Accuracy（CER 回歸，release 前執行）
test-accuracy:
	$(PYTEST) tests/accuracy/ -v --run-accuracy

## 啟動測試用 server
server:
	WHISPER_TEST=1 python3 app.py

## 打包
package:
	bash package.sh

help:
	@echo ""
	@echo "  make test              unit tests（61 個，30 秒，不需要 server）"
	@echo "  make test-integration  integration tests（需要 make server）"
	@echo "  make test-e2e          Playwright UI tests"
	@echo "  make test-accuracy     CER 回歸測試"
	@echo "  make server            啟動測試用 server（WHISPER_TEST=1）"
	@echo "  make package           打包 .app"
	@echo ""
