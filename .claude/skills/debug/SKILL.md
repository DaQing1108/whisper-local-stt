---
name: debug
description: Server-side debug protocol for Whisper AI (and any Flask/pywebview app on a fixed port). Enforces 4-step environment verification before touching code.
version: 1.0.0
---

# /debug — Server Debug Protocol

When this skill is invoked, execute ALL four steps in order before suggesting any code change.

## Step 1 — Which process is actually serving requests?

```bash
lsof -i :5001
```

Confirm:
- How many PIDs are listed?
- Is each one `python3`, a `.app` binary (`Whisper AI`), or something else?
- If **multiple PIDs** exist: the old one must be killed before continuing.

```bash
# Kill stale server (replace PID with actual value)
kill -9 <OLD_PID>
```

Do NOT proceed to the next step until exactly one process owns port 5001.

## Step 2 — What does the log actually say?

```bash
tail -30 whisper_server.log
# or, if running as .app:
tail -30 whisper_app.log
```

- Read the **full** traceback, not just the last line.
- Note the **timestamp** — confirm it's from this session, not a previous crash.
- If the log is empty or the timestamp is stale, the error hasn't happened yet in this process.

## Step 3 — Are UI version and code version the same?

```bash
grep __version__ version.py
```

Compare against what the app's title bar or footer shows.

| Situation | Action |
|-----------|--------|
| Version matches | Continue to Step 4 |
| Version mismatch | Run `bash package.sh` first, then retest |
| `.app` is stale | `kill -9 <APP_PID>`, run `bash package.sh`, launch new `.app` |

**Never fix code when the running process is not the one you just edited.**

## Step 4 — Apply the fix to source, then rebuild

1. Edit the source file (e.g. `whisper_core.py`, `gui.py`, `ui.py`).
2. Run `bash package.sh` — this kills any old server, rebuilds, signs, deploys, and validates.
3. After launch, re-run `lsof -i :5001` to confirm only one new PID is running.
4. Reproduce the original error to verify it's gone.

## Quick Reference

```bash
# Diagnostic one-liner
lsof -i :5001 && tail -20 whisper_server.log

# Full rebuild + redeploy
bash package.sh

# Manual kill if package.sh isn't available
kill -9 $(lsof -ti :5001)
```

## Why this exists

In a session where `ffmpeg not found` appeared 6 times: each fix was applied to source files while the `.app` binary (a different process on the same port) was still running old code. The source was correct; the running process was not. Every test hit the old process. `lsof -i :5001` at the start would have caught this immediately.

**Rule**: a fix applied to the wrong process achieves nothing.

---

## Symptom → Root Cause Tree

Use this BEFORE forming a hypothesis. Same error message ≠ same root cause.

### ⚠️ 未偵測到語音內容 / No speech detected

```
Step 1: Check log for -3801
├── YES → TCC denied (Screen Recording permission)
│         Check: System Settings → Privacy → Screen Recording → Whisper STT ON?
│         If ON but still failing → signing issue, run package.sh (uses WhisperSTT Local cert)
│         After rebuild → toggle permission OFF then ON once
│
└── NO new log entries at all
    ├── Recording < 1 second? → No chunk produced (need > 1s)
    └── Any "chunk RMS=X" lines?
        ├── RMS > 100 + "Hallucination rejected" → Audio captured OK, content is not speech
        │   → Test with clear spoken-word YouTube (news/podcast, no background music)
        └── RMS < 100 → Audio is silent
            → Confirm system volume is up and YouTube is actually playing
```

### 🔴 SIGABRT / App crash on system audio start

```
Check routes.py system_audio_start:
└── Calling _sc.start_sc_capture()? → REVERT to _sa.start_capture(_on_chunk, on_error=_on_tcc_error)
    pyobjc SCKit causes libdispatch assertion failure (confirmed v1.6.1, NEVER use for capture)
```

### 🔄 Code fix has no effect

```
→ Run /debug Step 1 immediately
→ Almost always: edited source but running old .app
→ lsof -i :5001 will show the stale PID
```

### ❓ Session summary says "X caused Y" — verify before acting

Cross-session summaries can misattribute causes (e.g. "filter caused empty audio" was actually TCC denial).
Before reverting a fix based on a summary, check the log timestamps to confirm the causal chain.
