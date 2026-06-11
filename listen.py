#!/usr/bin/env python3
"""
listen.py — 麥克風直接轉錄（無需音檔）

兩種模式：
  python3 listen.py                 # 按停即轉：一直錄，Ctrl+C 後轉錄
  python3 listen.py --stream        # 串流模式：每段話說完自動轉錄（VAD 靜音偵測）

選項：
  --upload                          # 轉錄後自動上傳 Notion
  --page-id <id>                    # 指定 Notion 頁面
  --model  tiny|base|small|medium   # Whisper 模型（預設 small）
  --language zh|en|...              # 強制語言（預設自動偵測）
  --chunk  10                       # 串流模式：每幾秒轉一次（預設 10）
"""

import argparse
import io
import os
import queue
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import sounddevice as sd
from dotenv import load_dotenv
from scipy.io import wavfile

load_dotenv()

SAMPLE_RATE = 16000  # Whisper 要求 16kHz


# ────────────────────────────────────────────────────────────────
# Whisper 載入（延遲，避免啟動慢）
# ────────────────────────────────────────────────────────────────

_model_cache = {}

def load_whisper_model(name: str):
    if name not in _model_cache:
        try:
            import whisper
        except ImportError:
            sys.exit("❌ 找不到 openai-whisper，請先執行：pip install openai-whisper")
        print(f"⏳ 載入 Whisper 模型：{name}…", flush=True)
        _model_cache[name] = whisper.load_model(name)
        print("✅ 模型就緒", flush=True)
    return _model_cache[name]


# ────────────────────────────────────────────────────────────────
# 核心：把 numpy audio array 送給 Whisper
# ────────────────────────────────────────────────────────────────

def transcribe_array(audio_np: np.ndarray, model, language: str = None) -> str:
    """直接把 numpy array 餵給 Whisper，不寫檔案。"""
    import whisper

    # Whisper 預期 float32, 範圍 [-1, 1]
    if audio_np.dtype != np.float32:
        audio_np = audio_np.astype(np.float32) / 32768.0

    # 如果是雙聲道，降為單聲道
    if audio_np.ndim > 1:
        audio_np = audio_np.mean(axis=1)

    options = {}
    if language:
        options["language"] = language

    result = model.transcribe(audio_np, **options)
    return result.get("text", "").strip(), result.get("language", "?")


# ────────────────────────────────────────────────────────────────
# 模式一：按停即轉（一次性錄音）
# ────────────────────────────────────────────────────────────────

def mode_press_to_stop(args):
    model = load_whisper_model(args.model)

    frames = []
    stop_event = threading.Event()

    def callback(indata, frame_count, time_info, status):
        if status:
            print(f"⚠️  {status}", flush=True)
        frames.append(indata.copy())

    print("🎙️  開始錄音…（按 Ctrl+C 停止並轉錄）", flush=True)
    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                        dtype="int16", callback=callback):
        try:
            while True:
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass

    if not frames:
        print("⚠️  沒有錄到任何聲音。")
        return

    audio = np.concatenate(frames, axis=0).flatten()
    duration = len(audio) / SAMPLE_RATE
    print(f"\n⏹  錄音結束，時長 {duration:.1f} 秒，開始轉錄…", flush=True)

    text, lang = transcribe_array(audio, model, language=args.language)

    if not text:
        print("⚠️  沒有偵測到語音內容。")
        return

    print(f"\n✅ 偵測語言：{lang}")
    print("─" * 50)
    print(text)
    print("─" * 50)

    if args.upload:
        _upload_text(text, lang, args)
    else:
        print("\n💡 加上 --upload 即可自動上傳 Notion")


# ────────────────────────────────────────────────────────────────
# 模式二：串流即時轉錄（VAD 靜音偵測）
# ────────────────────────────────────────────────────────────────

def mode_stream(args):
    model = load_whisper_model(args.model)

    chunk_duration = args.chunk       # 秒數觸發一次轉錄
    silence_threshold = 0.01          # RMS 低於此值視為靜音
    silence_min_sec   = 1.5           # 連續靜音超過此秒數才切割

    q: queue.Queue = queue.Queue()
    buffer = []
    full_transcript = []

    def callback(indata, frame_count, time_info, status):
        q.put(indata.copy())

    def process_loop():
        """背景執行緒：持續處理 buffer，靜音時自動轉錄一段。"""
        nonlocal buffer
        silence_frames = 0
        frames_per_check = int(SAMPLE_RATE * 0.1)   # 每 0.1 秒一次 RMS 檢查
        silence_trigger  = int(silence_min_sec / 0.1)

        while True:
            try:
                chunk = q.get(timeout=1.0)
            except queue.Empty:
                continue

            if chunk is None:   # 結束訊號
                break

            buffer.append(chunk)
            total_frames = sum(len(b) for b in buffer)

            # RMS 靜音偵測
            rms = float(np.sqrt(np.mean(chunk.astype(np.float32) ** 2))) / 32768.0
            if rms < silence_threshold:
                silence_frames += 1
            else:
                silence_frames = 0

            # 觸發轉錄條件：靜音夠久 or 累積夠多秒
            should_transcribe = (
                silence_frames >= silence_trigger
                or total_frames / SAMPLE_RATE >= chunk_duration
            )

            if should_transcribe and total_frames > SAMPLE_RATE * 0.5:
                audio = np.concatenate(buffer, axis=0).flatten()
                buffer = []
                silence_frames = 0

                text, lang = transcribe_array(audio, model, language=args.language)
                if text:
                    ts = datetime.now().strftime("%H:%M:%S")
                    print(f"\n[{ts}] {text}", flush=True)
                    full_transcript.append((ts, text))

    worker = threading.Thread(target=process_loop, daemon=True)
    worker.start()

    print(f"🎙️  串流模式（每 {chunk_duration}s / 靜音 {silence_min_sec}s 自動轉錄）")
    print("   按 Ctrl+C 結束…\n", flush=True)

    try:
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                            dtype="int16", callback=callback):
            while True:
                time.sleep(0.1)
    except KeyboardInterrupt:
        pass

    q.put(None)
    worker.join(timeout=3)

    # 處理剩餘 buffer
    if buffer:
        audio = np.concatenate(buffer, axis=0).flatten()
        text, lang = transcribe_array(audio, model, language=args.language)
        if text:
            ts = datetime.now().strftime("%H:%M:%S")
            print(f"\n[{ts}] {text}", flush=True)
            full_transcript.append((ts, text))

    if not full_transcript:
        print("\n⚠️  沒有偵測到語音內容。")
        return

    full_text = "\n".join(f"[{ts}] {t}" for ts, t in full_transcript)
    print(f"\n✅ 轉錄完成，共 {len(full_transcript)} 段。")

    if args.upload:
        _upload_text(full_text, "?", args)
    else:
        print("\n💡 加上 --upload 即可自動上傳 Notion")


# ────────────────────────────────────────────────────────────────
# Notion 上傳
# ────────────────────────────────────────────────────────────────

def _upload_text(text: str, lang: str, args) -> None:
    try:
        from notion_client import Client
    except ImportError:
        sys.exit("❌ 找不到 notion-client，請先執行：pip install notion-client")

    token = os.getenv("NOTION_TOKEN")
    if not token:
        sys.exit("❌ 缺少 NOTION_TOKEN，請先執行 python3 setup_notion.py")

    page_id = getattr(args, "page_id", None) or os.getenv("NOTION_PAGE_ID")
    if not page_id:
        sys.exit("❌ 請指定 --page-id 或在 .env 設定 NOTION_PAGE_ID")

    notion = Client(auth=token)
    now    = datetime.now().strftime("%Y-%m-%d %H:%M")
    blocks = []

    # 分隔線 + 標題
    blocks.append({"object": "block", "type": "divider", "divider": {}})
    blocks.append({
        "object": "block", "type": "heading_2",
        "heading_2": {"rich_text": [{"type": "text",
                                      "text": {"content": f"🎙️ 即時轉錄｜{now}"}}]},
    })
    blocks.append({
        "object": "block", "type": "callout",
        "callout": {
            "rich_text": [{"type": "text",
                            "text": {"content": f"偵測語言：{lang}  ｜  轉錄時間：{now}"}}],
            "icon": {"type": "emoji", "emoji": "🕐"},
            "color": "gray_background",
        },
    })

    # 正文段落（每行一個 block）
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        blocks.append({
            "object": "block", "type": "paragraph",
            "paragraph": {"rich_text": [{"type": "text", "text": {"content": line}}]},
        })

    # 分批上傳
    for i in range(0, len(blocks), 100):
        notion.blocks.children.append(block_id=page_id, children=blocks[i:i+100])

    print(f"✅ 已上傳至 Notion（{len(blocks)} blocks）")


# ────────────────────────────────────────────────────────────────
# CLI
# ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="麥克風直接轉錄，無需音檔"
    )
    parser.add_argument("--stream",   action="store_true",
                        help="串流模式：靜音偵測自動切段即時轉錄")
    parser.add_argument("--model",    default="small",
                        choices=["tiny", "base", "small", "medium", "large"])
    parser.add_argument("--language", default=None,
                        help="強制語言代碼（zh / en …），不指定則自動偵測")
    parser.add_argument("--upload",   action="store_true",
                        help="轉錄後自動上傳至 Notion")
    parser.add_argument("--page-id",  default=None,
                        help="Notion 頁面 ID（優先於 .env）")
    parser.add_argument("--chunk",    type=int, default=10,
                        help="串流模式：每幾秒觸發一次轉錄（預設 10）")
    args = parser.parse_args()

    # 測試麥克風是否可用
    try:
        devices = sd.query_devices()
        default_in = sd.default.device[0]
        if default_in is None:
            raise RuntimeError("找不到預設輸入裝置")
    except Exception as e:
        sys.exit(f"❌ 麥克風初始化失敗：{e}\n請確認系統已授予麥克風權限。")

    if args.stream:
        mode_stream(args)
    else:
        mode_press_to_stop(args)


if __name__ == "__main__":
    main()
