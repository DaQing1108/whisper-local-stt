# gui.spec — PyInstaller 打包設定
# 執行：pyinstaller gui.spec

import sys
from pathlib import Path

block_cipher = None
project_dir  = Path(SPECPATH)

a = Analysis(
    ['gui.py'],
    pathex=[str(project_dir)],
    binaries=[],
    datas=[
        # 專案所有 .py（routes / whisper_core / sse / ui / integrations / llm_post / version）
        ('*.py',           '.'),
        ('.env',           '.'),
        ('.env.example',   '.') if (project_dir / '.env.example').exists() else ('gui.py', '.'),
    ],
    hiddenimports=[
        'webview',
        'webview.platforms.cocoa',
        'waitress',
        'flask',
        'faster_whisper',
        'mlx_whisper',
        'notion_client',
        'dotenv',
        'anthropic',
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=['tkinter', 'PyQt5', 'PyQt6', 'wx'],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='WhisperAI',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,   # 不顯示 Terminal 視窗
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='WhisperAI',
)

app = BUNDLE(
    coll,
    name='Whisper AI 會議記錄.app',
    icon=None,         # 換成 icon.icns 路徑可自訂圖示
    bundle_identifier='com.via.whisper-ai',
    info_plist={
        'NSMicrophoneUsageDescription': 'Whisper AI 需要麥克風進行會議錄音',
        'CFBundleShortVersionString':   '1.3.0',
        'CFBundleName':                 'Whisper AI 會議記錄',
        'LSMinimumSystemVersion':       '12.0',
        'NSHighResolutionCapable':      True,
    },
)
