"""ci/check_bundle_deps.py — 確認 pyannote 與 torch 沒有被打包進 PyInstaller bundle。

CLAUDE.md NEVER #4：pyannote/torch/speechbrain 等重量級 ML 依賴不能被 PyInstaller
直接打包，必須靠 diarize.py 的 subprocess 隔離。這支腳本檢查 gui.spec 的
hiddenimports/excludes 有沒有意外讓這些套件重新回到 bundle：
- pyannote 家族：2026-07-10 發生過一次回歸（hiddenimports 誤加，見 commit 9af0494）
- torch：2026-07-11 確認可安全排除（gui.spec excludes 加入 'torch'，見 commit）——
  ctranslate2.converters 對 torch 的依賴皆有防護（try/except 或函式內 lazy import），
  faster_whisper 本身無直接依賴，已用「封鎖 torch import + 實際跑一次 WhisperModel
  轉錄」的方式驗證過整條鏈路仍正常運作。torchaudio/lightning/pytorch_lightning/
  lightning_fabric/torchmetrics/functorch 只透過 torch 自己的內部機制間接可達，
  排除 torch 後這些會一併消失，不需要逐一列舉

純 Python 程式碼會被編譯進 PyInstaller 的 PYZ 封存檔，不會在 dist/*.app 底下
以資料夾形式出現，所以不能用 find 檢查檔案系統——要讀 PyInstaller 自己產生的
依賴分析報告（build/<name>/xref-<name>.html），確認目標套件的 moduletype
不是 Package/SourceModule 等「已收錄」的分類。
"""
from __future__ import annotations

import glob
import re
import sys

FORBIDDEN = ["pyannote", "pyannote.audio", "pyannote.core", "torch"]
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
        print("❌ 發現不該被打包的重量級套件回到 bundle（gui.spec hiddenimports/excludes 回歸）：")
        for name, kind in found:
            print(f"   {name}: {kind}")
        return 1

    print("✅ Bundle 分析乾淨，pyannote 與 torch 皆未被收錄")
    return 0


if __name__ == "__main__":
    sys.exit(main())
