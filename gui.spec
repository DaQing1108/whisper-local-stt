# gui.spec — PyInstaller 打包設定
# 執行：pyinstaller gui.spec

import sys
from pathlib import Path

block_cipher = None
project_dir  = Path(SPECPATH)
sparkle_framework = project_dir / 'Sparkle.framework'
sparkle_datas = [(str(sparkle_framework), 'Sparkle.framework')] if sparkle_framework.exists() else []

a = Analysis(
    ['gui.py'],
    pathex=[str(project_dir)],
    binaries=[],
    datas=[
        # 專案所有 .py（routes / whisper_core / sse / ui / integrations / llm_post / version）
        ('*.py',           '.'),
        ('.env',           '.'),
        ('.env.example',   '.') if (project_dir / '.env.example').exists() else ('gui.py', '.'),
        # bin/ 目錄（ffmpeg + system_audio_capture）
        ('bin',            'bin'),
        # 前端資源（ui.py 組裝器在執行期讀取）
        ('templates',      'templates'),
        ('static',         'static'),
    ] + sparkle_datas,
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
        'sounddevice',
        'numpy',
        'objc',
        'Foundation',
        'PyObjCTools.AppHelper',
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
    name='Whisper STT.app',
    icon='AppIcon.icns' if Path(SPECPATH, 'AppIcon.icns').exists() else None,
    bundle_identifier='com.via.whisper-ai',
    info_plist={
        'NSMicrophoneUsageDescription':   'Whisper STT 需要麥克風進行會議錄音',
        'NSScreenCaptureUsageDescription': 'Whisper STT 需要螢幕錄製權限以擷取系統音訊（Teams / Zoom 等會議聲音）',
        'CFBundleShortVersionString':     '1.6.8',
        'CFBundleName':                   'Whisper STT',
        'LSMinimumSystemVersion':         '12.0',
        'NSHighResolutionCapable':        True,
        'SUFeedURL':                      'https://github.com/DaQing1108/whisper-local-stt/releases/latest/download/appcast.xml',
        'SUPublicEDKey':                  'TqckZdtuk2dvHruKRwDkDgMu2XqRtyH0KhViZxj33lg=',
    },
)
