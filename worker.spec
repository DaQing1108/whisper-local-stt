from pathlib import Path
from PyInstaller.utils.hooks import collect_data_files

project_dir = Path(SPECPATH)

a = Analysis(
    ["worker_entrypoint.py"],
    pathex=[str(project_dir)],
    binaries=[],
    datas=[("bin/ffmpeg", "bin")] + collect_data_files("faster_whisper"),
    hiddenimports=[
        "faster_whisper", "ctranslate2", "huggingface_hub",
        "tokenizers", "av", "opencc",
    ],
    excludes=[
        "mlx", "mlx_whisper", "torch", "tkinter", "PyQt5", "PyQt6", "wx",
        "pandas", "matplotlib", "scipy", "pytest", "numba", "llvmlite",
        "PIL", "sqlalchemy",
    ],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [], exclude_binaries=True,
    name="WhisperWorker", console=True, strip=False, upx=False,
)
coll = COLLECT(
    exe, a.binaries, a.datas,
    strip=False, upx=False, name="WhisperWorker",
)
