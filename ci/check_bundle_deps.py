"""ci/check_bundle_deps.py — 確認 pyannote 沒有被打包進 PyInstaller bundle。

CLAUDE.md NEVER #4：pyannote/torch/speechbrain 等重量級 ML 依賴不能被 PyInstaller
直接打包，必須靠 diarize.py 的 subprocess 隔離。這支腳本檢查 gui.spec 的
hiddenimports 有沒有意外重新把 pyannote 拉回 bundle（2026-07-10 發生過一次
這樣的回歸，見 commit 9af0494）。

純 Python 程式碼會被編譯進 PyInstaller 的 PYZ 封存檔，不會在 dist/*.app 底下
以資料夾形式出現，所以不能用 find 檢查檔案系統——要讀 PyInstaller 自己產生的
依賴分析報告（build/<name>/xref-<name>.html），確認目標套件的 moduletype
不是 Package/SourceModule 等「已收錄」的分類。

刻意不檢查 torch/lightning/pytorch_lightning/lightning_fabric：這幾個目前仍
透過 ctranslate2.converters（faster_whisper 的依賴鏈）存在於 bundle 裡，是
已知、獨立追蹤的問題（見 task chip），不是這次要防的回歸，加進來只會造成
這個檢查永遠失敗、失去訊號價值。
"""
from __future__ import annotations

import glob
import re
import sys

FORBIDDEN = ["pyannote", "pyannote.audio", "pyannote.core"]
INCLUDED_TYPES = {"Package", "SourceModule", "Extension", "NamespacePackage"}


def find_forbidden_packages(xref_html: str) -> list[tuple[str, str]]:
    """回傳 xref_html 裡被實際收錄（非 MissingModule）的目標套件清單。"""
    found = []
    for name in FORBIDDEN:
        m = re.search(
            r'<a name="' + re.escape(name) + r'"></a>.*?<span class="moduletype">([^<]+)</span>',
            xref_html, re.S,
        )
        if m and m.group(1) in INCLUDED_TYPES:
            found.append((name, m.group(1)))
    return found


def main() -> int:
    xref_paths = sorted(glob.glob("build/*/xref-*.html"))
    if not xref_paths:
        print("找不到 build/*/xref-*.html，PyInstaller 分析報告未產生", file=sys.stderr)
        return 1
    if len(xref_paths) > 1:
        print(f"警告：找到 {len(xref_paths)} 份 xref 報告，取第一份 {xref_paths[0]}", file=sys.stderr)

    with open(xref_paths[0], encoding="utf-8", errors="ignore") as f:
        content = f.read()

    found = find_forbidden_packages(content)

    if found:
        print("❌ 發現 pyannote 被重新打包進 bundle（gui.spec hiddenimports 回歸）：")
        for name, kind in found:
            print(f"   {name}: {kind}")
        return 1

    print("✅ Bundle 分析乾淨，pyannote 未被收錄")
    return 0


if __name__ == "__main__":
    sys.exit(main())
