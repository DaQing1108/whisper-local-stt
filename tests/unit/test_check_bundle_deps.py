"""tests/unit/test_check_bundle_deps.py

ci/check_bundle_deps.py 的解析邏輯測試，用 fixture 字串模擬 PyInstaller
xref-*.html 的片段，不需要真的跑一次 PyInstaller 打包。

完整正確性（腳本真的能從實際 gui.spec 重打包結果抓到回歸）已在
2026-07-10 用手動 add/rebuild/revert 循環驗證過：乾淨版通過、暫時把
pyannote.audio 加回 hiddenimports 後正確失敗。這裡只鎖定 regex 解析邏輯
本身，避免未來改動這支腳本時，在不重跑打包的情況下也能抓到解析邏輯壞掉。
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
        html = _xref_entry("faster_whisper", "Package") + _xref_entry("torch", "Package")
        assert find_forbidden_packages(html) == []

    def test_pyannote_included_as_package_is_flagged(self):
        """pyannote.audio 被收錄為 Package → 必須被抓到。"""
        html = _xref_entry("pyannote.audio", "Package")
        result = find_forbidden_packages(html)
        assert ("pyannote.audio", "Package") in result

    def test_pyannote_as_missing_module_is_not_flagged(self):
        """pyannote 出現在 xref 裡但被分類為 MissingModule（真的沒被收錄）→ 不算回歸。"""
        html = _xref_entry("pyannote", "MissingModule")
        assert find_forbidden_packages(html) == []

    def test_all_three_forbidden_packages_detected(self):
        html = (
            _xref_entry("pyannote", "NamespacePackage")
            + _xref_entry("pyannote.audio", "Package")
            + _xref_entry("pyannote.core", "Package")
        )
        result = find_forbidden_packages(html)
        names = {name for name, _ in result}
        assert names == {"pyannote", "pyannote.audio", "pyannote.core"}

    def test_unrelated_torch_lightning_never_flagged(self):
        """torch/lightning 系列刻意不在 FORBIDDEN 清單內（見模組 docstring），
        即使被收錄為 Package 也不該出現在結果裡。"""
        html = (
            _xref_entry("torch", "Package")
            + _xref_entry("lightning", "Package")
            + _xref_entry("pytorch_lightning", "Package")
            + _xref_entry("lightning_fabric", "Package")
        )
        assert find_forbidden_packages(html) == []
