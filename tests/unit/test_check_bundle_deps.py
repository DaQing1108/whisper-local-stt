"""tests/unit/test_check_bundle_deps.py

ci/check_bundle_deps.py 的解析邏輯測試，用 fixture 字串模擬 PyInstaller
xref-*.html 的片段，不需要真的跑一次 PyInstaller 打包。

完整正確性（腳本真的能從實際 gui.spec 重打包結果抓到回歸）已分兩階段驗證過：
2026-07-10 手動 add/rebuild/revert 循環驗證 pyannote 家族（乾淨版通過、暫時把
pyannote.audio 加回 hiddenimports 後正確失敗）；2026-07-11 驗證 torch 排除
（xref 分析確認 torch=ExcludedModule，並用「封鎖 torch import + 實際跑一次
WhisperModel 轉錄」的方式確認 ctranslate2/faster_whisper 整條鏈路不受影響）。
這裡只鎖定 regex 解析邏輯本身，避免未來改動這支腳本時，在不重跑打包的情況下
也能抓到解析邏輯壞掉。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "ci"))

from check_bundle_deps import find_forbidden_packages  # noqa: E402


def _xref_entry(name: str, moduletype: str) -> str:
    return f'<a name="{name}"></a>\n<span class="moduletype">{moduletype}</span>'


class TestFindForbiddenPackages:
    def test_clean_bundle_no_forbidden_packages(self):
        """乾淨的 bundle：目標套件完全不在 xref 裡（NOT FOUND，不是 MissingModule）。"""
        html = _xref_entry("faster_whisper", "Package") + _xref_entry("mlx_whisper", "Package")
        assert find_forbidden_packages(html) == []

    def test_torch_excluded_module_is_not_flagged(self):
        """torch 被正確排除時 moduletype 是 ExcludedModule，不算回歸（這是目前的正常狀態）。"""
        html = _xref_entry("torch", "ExcludedModule")
        assert find_forbidden_packages(html) == []

    def test_torch_included_as_package_is_flagged(self):
        """torch 若被重新收錄為 Package → 必須被抓到（防止 excludes 設定被意外移除）。"""
        html = _xref_entry("torch", "Package")
        result = find_forbidden_packages(html)
        assert ("torch", "Package") in result

    def test_pyannote_included_as_package_is_flagged(self):
        """pyannote.audio 被收錄為 Package → 必須被抓到。"""
        html = _xref_entry("pyannote.audio", "Package")
        result = find_forbidden_packages(html)
        assert ("pyannote.audio", "Package") in result

    def test_pyannote_as_missing_module_is_not_flagged(self):
        """pyannote 出現在 xref 裡但被分類為 MissingModule（真的沒被收錄）→ 不算回歸。"""
        html = _xref_entry("pyannote", "MissingModule")
        assert find_forbidden_packages(html) == []

    def test_all_forbidden_packages_detected_together(self):
        html = (
            _xref_entry("pyannote", "NamespacePackage")
            + _xref_entry("pyannote.audio", "Package")
            + _xref_entry("pyannote.core", "Package")
            + _xref_entry("torch", "Package")
        )
        result = find_forbidden_packages(html)
        names = {name for name, _ in result}
        assert names == {"pyannote", "pyannote.audio", "pyannote.core", "torch"}

    def test_lightning_family_not_independently_checked(self):
        """lightning/pytorch_lightning/lightning_fabric 不在 FORBIDDEN 清單內——
        這幾個只透過 torch 自己的內部機制間接可達，torch 一旦被排除它們就不會
        出現在 xref 裡，不需要逐一列舉檢查。"""
        html = (
            _xref_entry("lightning", "Package")
            + _xref_entry("pytorch_lightning", "Package")
            + _xref_entry("lightning_fabric", "Package")
        )
        assert find_forbidden_packages(html) == []
