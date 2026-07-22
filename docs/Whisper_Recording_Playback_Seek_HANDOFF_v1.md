# HANDOFF — Whisper Swift Recording Playback Review (Segment-Level Seek)

**Handoff date:** 2026-07-23
**From:** Claude Code session (this conversation)
**To:** A fresh Claude Code session/account picking this up cold
**Branch:** `whisper-swift` (active development branch; `main` = Whisper Classic, frozen)
**Starting commit:** `178449d` (`docs: record real UI verification of diarization (HANDOFF v2 Task 1)`)
**Repo:** `whisper-local-stt` — this worktree lives at `.worktrees/swiftui-python-poc` off the main repo checkout

---

## Read this first, in this order

1. `CLAUDE.md` (this worktree's root) — technical invariants for this project. Not much of it is directly relevant to this task (it's mostly about the Python Worker/PyInstaller side), but skim it — this task is pure SwiftUI, so if you find yourself needing to touch the Worker or protocol at all, that's a signal you've misunderstood the scope.
2. `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift` — specifically `togglePlayback` (line ~391), `restore` (line ~236, the history-entry-load/switch handler that already does `audioPlayer?.stop(); audioPlayer = nil`), and the button row around line 38. Read the actual current code before assuming line numbers are still accurate — this file has changed several times recently (Diarization button additions).
3. `macos/WhisperApp/Sources/WhisperApp/TranscriptionHistoryStore.swift` line ~4 — `TranscriptionSegment` struct (`start: Double, end: Double, text: String, speaker: String?`). This already has everything needed; no data model changes required.
4. `macos/WhisperApp/Sources/WhisperApp/ContentView.swift` line ~39 — `@State var audioPlayer: AVAudioPlayer?`, the shared player instance.

## BLUF

Whisper Swift already has basic whole-file audio playback (`togglePlayback`: a single play/pause button that plays the entire recording from wherever `AVAudioPlayer` currently is) and every completed transcription already has time-stamped `segments` with `start`/`end`/`text` (and optionally `speaker`, from the recently-completed Diarization feature). What's missing is the ability to **click a specific line of transcript and have playback jump to that moment**, plus a visual indicator of which segment is currently playing. This is a trust-building feature (lets the user spot-check the STT against the actual audio) and matches what competitors (Notion AI Meeting, Otter) already do.

This was scoped down significantly from an initial assumption that it needed a bigger redesign — the PRD originally listed this as "Not started," but investigation this session found the actual gap is much smaller: audio retention and basic playback already work, only the segment-tap-to-seek layer is missing.

## What NOT to do

- Do NOT touch the Python Worker, `worker_entrypoint.py`, `worker_protocol.py`, or any JSONL command/event. This feature needs zero backend involvement — `segments` are already delivered to the SwiftUI side by existing `transcribe`/`diarize` responses. If you find yourself wanting to add a new Worker command for this, stop — you've misunderstood the scope.
- Do NOT replace or redesign the existing `TextEditor`-based free-text transcript editor (`transcriptDraft`). Users can currently hand-edit the transcript and save it (`saveDraft`) — that must keep working exactly as-is. The segment-level seek UI is meant to be an **additional, separate, read-only** list alongside the existing editor, not a replacement for it.
- Do NOT remove or bypass the existing `restore(_ entry:)` cleanup (`audioPlayer?.stop(); audioPlayer = nil` when switching history entries). Any new per-segment playback-tracking state (e.g., a `Timer`) you add must be torn down at the same point, or you'll get a Timer from entry A still firing after the user has switched to entry B.
- Do NOT assume `entry.segments` is always non-empty. Some history entries may have empty or missing segments (this wasn't rigorously confirmed this session — see stop conditions below). Gate the new UI on `!entry.segments.isEmpty` and fall back to the existing whole-file play/pause button when empty, exactly like the existing "辨識講者" button already does (`.disabled(entry.segments.isEmpty || ...)` in the same file).
- Do NOT write SwiftUI view-level unit tests as a blocking requirement. This codebase has no precedent for testing View composition directly (state/logic like `WorkerSupervisor` methods are unit tested; View bodies are not) — match that existing boundary rather than inventing new test infrastructure for this one feature.

---

## The execution spec

**Risk level:** L1 (pure SwiftUI, no Worker/protocol changes, single-file-dominant)
**ESAEV entry point:** Approve → Execute (this spec went through spec-writer's diagnosis and quality review; verdict was "✅ 可直接交付" — directly deliverable, no outstanding `⚠️ 待確認` blockers)

### Problem background & goal

`ContentView+Results.swift` currently only has whole-file "播放/暫停" (`togglePlayback`). The transcript is a freeform, hand-editable text box (`transcriptDraft`) with no per-line structure, so there's no way to click a sentence and jump playback to that moment.

**Target end-state:** For a transcription result that has non-empty `segments`, a read-only, clickable list of segments appears (each showing `[MM:SS] text`, plus a speaker label if present). Clicking a segment seeks `audioPlayer.currentTime` to that segment's `start` and begins playback. While playing, the segment currently under the playhead is visually highlighted, updating as playback progresses.

**Explicitly not this task's goal:**
- Word-level (sub-segment) sync — segment-level only.
- Any change to the Worker, protocol, or `TranscriptionSegment`'s data shape — the existing fields are sufficient.
- Any change to the existing free-text editing/save flow.
- Handling anything beyond the empty-segments fallback (no new elaborate error states).

### Scope

**Allowed to modify:**
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift` — new clickable segment-list view, seek-on-tap logic, playback-position tracking (likely a `Timer` polling `audioPlayer.currentTime`, since `AVAudioPlayer` has no native time-changed callback)
- `macos/WhisperApp/Sources/WhisperApp/ContentView.swift` — new `@State` if needed to track the currently-playing segment index/id and the polling `Timer`
- Nothing else should be required. If you find yourself needing to touch other files, treat that as a signal to stop and reconsider scope, not push through.

**Forbidden to modify:**
- `TranscriptionHistoryStore.swift`'s `TranscriptionSegment`/`TranscriptionHistoryEntry` structs (the existing fields are sufficient)
- Any Worker/protocol file (`worker_entrypoint.py`, `worker_protocol.py`, `WorkerSupervisor.swift`'s command/event surface)
- The existing `togglePlayback` whole-file play/pause behavior, `transcriptDraft` free-text editing, `saveDraft`, or `restore`'s existing cleanup

**Needs explicit human approval before proceeding if encountered:**
- Any new external dependency (shouldn't be needed — `AVFoundation` already covers this)
- Any change to `TranscriptionSegment`'s shape

### System constraints

- `AVAudioPlayer` has no native "time did change" callback. Track playback position with a `Timer` (e.g., firing every 0.2–0.5s) that reads `audioPlayer.currentTime` and finds which segment's `[start, end)` range it falls in.
- The `Timer` must be invalidated whenever: playback stops, playback pauses (arguable — decide whether to keep tracking while paused so the highlight stays put, or stop the timer entirely; either is fine, just be deliberate), the user switches to a different history entry (`restore`), or the view disappears. An orphaned timer polling a stale player is the main failure mode to avoid here.
- Clicking a segment while the player is paused should start playback (not just seek and leave it paused) — matches the "clicking it means you want to hear it" expectation already implied by the existing UX.

### Acceptance criteria

**Positive (must pass):**
- [ ] A transcription result with non-empty `segments` shows a read-only, clickable list below/alongside the existing transcript editor, each row showing `[MM:SS] text` (and speaker label if `segment.speaker != nil`)
- [ ] Clicking any segment sets `audioPlayer.currentTime` to that segment's `start` and starts playback, regardless of prior play/pause state
- [ ] While playing, the segment containing the current playhead position is visually distinguished (e.g., background highlight or bold), and this updates as playback advances
- [ ] When `entry.segments.isEmpty`, the new list does not appear; the existing whole-file play/pause button behaves exactly as before

**Negative (must not break):**
- [ ] Existing `togglePlayback` (whole-file play/pause) behavior unchanged
- [ ] Existing `TextEditor`/`transcriptDraft` free-editing and `saveDraft` unaffected
- [ ] Existing 154 Swift tests (as of commit `178449d`) still pass
- [ ] No orphaned `Timer` continues firing after switching history entries or after the view disappears (verify by inspection — this codebase has no automated test precedent for this kind of thing, per the "what not to do" note above)

**Quality gates:**
- [ ] `swift build` clean
- [ ] `swift test` passing (154+ — should not decrease; new tests are welcome but not required per the View-testing boundary noted above)
- [ ] Manual verification: play a multi-segment recording, click several different segments, confirm seek + highlight-tracking both work — **this is real playback/visual behavior, not something the implementing session can self-certify from reading code; if you can build+run the app yourself (see build notes below), do the real click-through; if not, say explicitly what you could and couldn't verify**

### Verification commands

```bash
cd macos/WhisperApp && swift build && swift test
```

If you build and run the actual app to verify manually (recommended, not required — see AC above), the correct build scripts are:
```bash
bash scripts/build_worker_runtime.sh   # PyInstaller worker bundle -> dist/WhisperWorker
bash scripts/build_swiftui_app.sh      # Swift app + codesign -> dist/Whisper Swift.app
```
**Do NOT use `package.sh`** — that builds Whisper *Classic* (a different app, `APP_NAME="Whisper STT"`), not Whisper Swift. This was a real mistake in an earlier handoff this session; don't repeat it. After building, `cp -R "dist/Whisper Swift.app" ~/Applications/`, `xattr -cr` it, and the user must manually approve it once via System Settings (Gatekeeper cannot be scripted around).

### Stop conditions — escalate to the user, do not push through

- Any need to touch the Worker, protocol, or `TranscriptionSegment`'s data shape
- Discovering that a meaningful number of existing history entries have empty/missing `segments` despite showing a rendered transcript — this would mean the "gate the new UI on non-empty segments" assumption undersells how often the fallback path actually triggers, and is worth surfacing rather than silently accepting
- Timer-based position tracking causing a measurable performance or memory problem
- Two consecutive failed attempts at the same test/build error

### Completion report format

1. Summary of changes (files touched, the UI approach taken for the segment list, how position-tracking/highlighting was implemented)
2. Verification evidence (`swift build`/`swift test` output; and explicitly state what manual click-through verification was or wasn't performed, and why)
3. Scope confirmation (changes stayed within the allowed list above)
4. Known residual risk
5. Anything left undone, and why

### Division of labor: commit locally, but do NOT push

**Commit your work locally in this worktree once `swift build`/`swift test` pass, but do not `git push`.** Write the completion report above as a real markdown file (a HANDOFF v2-style doc, same spirit as `docs/Whisper_Phase3_Diarization_Integration_HANDOFF_v2.md`) so the next session doesn't have to re-derive what you did from the diff alone. The session that reviews this (likely the one that wrote this handoff) will independently re-run the full test suite and re-verify the key behaviors itself before pushing to `origin/whisper-swift` and updating the Notion PRD / README checkpoint — this is a deliberate second-check step, not a sign your work is distrusted by default. This is the same division of labor that worked well for the Diarization feature earlier in this branch's history (commit `dc4fe04` was implemented and left unpushed; the reviewing session re-ran everything against real audio before pushing).

---

## Prior art

This is a fresh feature area — no prior commits specific to this yet. For context on how a similarly-scoped recent SwiftUI-only addition went in this same file, see commit `64e33bc` (`feat(swift): add diarization model download button`), which added a new button + state-driven visibility condition to the same results workspace with a similarly small diff.

This document is being added on top as an uncommitted file — commit it yourself once reviewed, or ask the user first if unsure.
