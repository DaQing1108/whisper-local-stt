"""accuracy/test_cer.py — 字元錯誤率（CER）回歸測試。

非 CI 測試，release 前手動執行：
    pytest tests/accuracy/ -v --run-accuracy

需要預錄參考音檔放在 tests/accuracy/reference/ 目錄。
"""
from __future__ import annotations

import pytest

# 只在明確指定時執行
def pytest_addoption(parser):
    parser.addoption("--run-accuracy", action="store_true", default=False)


def pytest_collection_modifyitems(config, items):
    if not config.getoption("--run-accuracy"):
        skip = pytest.mark.skip(reason="需加 --run-accuracy 才執行")
        for item in items:
            if "accuracy" in str(item.fspath):
                item.add_marker(skip)


def _cer(reference: str, hypothesis: str) -> float:
    """計算字元錯誤率（CER）。0.0 = 完全正確，1.0 = 完全錯誤。"""
    import editdistance
    ref = reference.replace(" ", "").replace("\n", "")
    hyp = hypothesis.replace(" ", "").replace("\n", "")
    if not ref:
        return 0.0 if not hyp else 1.0
    return editdistance.eval(ref, hyp) / len(ref)


# 參考測試案例：(音檔名稱, 期望文字, 最大允許 CER)
REFERENCE_CASES = [
    # 新增音檔後在此補充
    # ("sample_zh_short.wav", "今天的會議主要討論產品路線圖", 0.15),
    # ("sample_zh_meeting.wav", "第三季目標是提升轉換率到百分之二十", 0.20),
]


@pytest.mark.parametrize("wav_file,expected_text,max_cer", REFERENCE_CASES)
def test_transcription_cer(wav_file, expected_text, max_cer):
    """對參考音檔做轉錄，驗證 CER 在閾值內。"""
    import requests
    from pathlib import Path

    ref_dir = Path(__file__).parent / "reference"
    wav_path = ref_dir / wav_file
    if not wav_path.exists():
        pytest.skip(f"參考音檔不存在：{wav_path}")

    with open(wav_path, "rb") as f:
        r = requests.post(
            "http://localhost:5001/upload",
            files={"audio": (wav_file, f, "audio/wav")},
            data={"model": "small", "language": "zh", "domain": "general"},
        )

    assert r.status_code == 200
    transcript = r.json().get("text", "")
    cer = _cer(expected_text, transcript)

    print(f"\n[CER] {wav_file}: {cer:.3f} (閾值 {max_cer})")
    print(f"  期望：{expected_text}")
    print(f"  實際：{transcript}")

    assert cer <= max_cer, f"CER {cer:.3f} 超過閾值 {max_cer}"
