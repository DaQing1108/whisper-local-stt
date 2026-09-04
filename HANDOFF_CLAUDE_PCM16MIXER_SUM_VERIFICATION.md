# Verification Report: PCM16Mixer 改用加總取代平均

Date: 2026-09-05
Handoff doc: `HANDOFF_CODEX_PCM16MIXER_SUM.md`
Executor: Claude Code (DEV session)
Branch: `handoff/2026-09-05-pcm16mixer-sum`
Base commit: `5d342b9`
Commit: `f65b146` — "fix(swift): sum PCM16 mixer channels instead of averaging"

AC Source: 未經 spec-writer，人工列出（使用者 2026-09-05 approve），見 `HANDOFF_CODEX_PCM16MIXER_SUM.md`。

## AC Results

- **AC-1** (兩軌都有訊號正常相加, `20_000 + 10_000 = 30_000`) — PASS. Covered by `sumsTwoSignalStreams()`.
- **AC-2** (核心案例：單一音源, `20_000 + 0 = 20_000` 且 `0 + 20_000 = 20_000`) — PASS. Covered by `preservesFullAmplitudeWhenOnlyLeftHasSignal()` and `preservesFullAmplitudeWhenOnlyRightHasSignal()`.
- **AC-3** (溢位 clamp: `25_000 + 20_000 → 32_767`; `-25_000 + -20_000 → -32_768`) — PASS. Covered by `clampsPositiveOverflowToInt16Max()` and `clampsNegativeOverflowToInt16Min()`.
- **AC-4** (既有測試改名 + 更新值: `sumsStreamsAndZeroPadsTheShorterInput` → `pcm16([30_000, -20_000])`) — PASS. Renamed and updated in place.
- **AC-5** (`git diff --stat 5d342b9 -- macos/WhisperApp` 只列 PCM16Mixer 兩檔) — PASS with expected caveat: against the **working tree** it also lists `MixedAudioRecordingController.swift` + its test file (the pre-existing uncommitted SPIKE, not touched by this task). Against the **committed** diff (`5d342b9..f65b146`) it lists exactly the two intended files — see Diff Summary below.
- **AC-6** (`swift test` 全綠) — PASS with documented baseline exceptions (see Test Results below): all 6 `PCM16MixerTests` pass; the two pre-existing non-target failures reproduce the documented baseline exactly.
- **AC-7** (`swift build` 乾淨無新增 warning) — PASS. `swift build 2>&1 | grep -Ei "warning:|error:"` produced no output.

## Test Results

### PCM16MixerTests (isolated filter run)

```
◇ Suite PCM16MixerTests started.
✔ Test sumsTwoSignalStreams() passed after 0.001 seconds.
✔ Test clampsPositiveOverflowToInt16Max() passed after 0.001 seconds.
✔ Test clampsNegativeOverflowToInt16Min() passed after 0.001 seconds.
✔ Test preservesFullAmplitudeWhenOnlyLeftHasSignal() passed after 0.001 seconds.
✔ Test sumsStreamsAndZeroPadsTheShorterInput() passed after 0.001 seconds.
✔ Test preservesFullAmplitudeWhenOnlyRightHasSignal() passed after 0.001 seconds.
✔ Suite PCM16MixerTests passed after 0.001 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.001 seconds.
```

### Full suite (`swift test`)

```
Test run with 206 tests in 32 suites failed after 1.414 seconds with 5 issues.
```

Failures, both matching the handoff doc's stated baseline exceptions:

1. `LiveRecordingControllerTests.repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts()` — failed under full-suite parallel load (`backend.startCount` 1 vs expected 3). Re-ran with `swift test --filter repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts` in isolation: **passed** (0.751s). This is the documented "並行 flake", not caused by this change.
2. `MixedAudioRecordingControllerTests` suite (3 issues) — this is the pre-existing uncommitted SPIKE described in the handoff doc as out-of-scope ("需 env var" `WHISPER_DEBUG_SEPARATE_TRACKS=1`). Not touched, not read beyond confirming it's the untouched file already present before this task started.

No other tests failed. This change did not introduce any new failures.

## Diff Summary

Committed diff (`5d342b9..f65b146`, scoped to `macos/WhisperApp`):
```
.../WhisperApp/Sources/WhisperApp/PCM16Mixer.swift |  2 +-
 .../Tests/WhisperAppTests/PCM16MixerTests.swift    | 44 +++++++++++++++++++++-
 2 files changed, 43 insertions(+), 3 deletions(-)
```

Working-tree diff (`git diff --stat 5d342b9 -- macos/WhisperApp`, includes pre-existing uncommitted SPIKE):
```
.../WhisperApp/MixedAudioRecordingController.swift | 60 +++++++++++++++++++---
 .../WhisperApp/Sources/WhisperApp/PCM16Mixer.swift |  2 +-
 .../MixedAudioRecordingControllerTests.swift       | 48 +++++++++++++++++
 .../Tests/WhisperAppTests/PCM16MixerTests.swift    | 44 +++++++++++++++++++++-
 4 files changed, 145 insertions(+), 9 deletions(-)
```
The two `MixedAudioRecordingController*` entries were present, uncommitted, before this task began (confirmed via `git status --short` before branching) and were never staged, edited, or committed by this task — `git add` used explicit file paths (`PCM16Mixer.swift` + `PCM16MixerTests.swift`) only, never `-A`/`.`.

## Change Detail

`Sources/WhisperApp/PCM16Mixer.swift`:
```diff
-            var mixed = Int16(clamping: (Int32(left) + Int32(right)) / 2).littleEndian
+            var mixed = Int16(clamping: Int32(left) + Int32(right)).littleEndian
```
`sample(at:in:)` (short-track zero-padding logic) untouched, as instructed.

`Tests/WhisperAppTests/PCM16MixerTests.swift`: renamed `averagesStreamsAndZeroPadsTheShorterInput` → `sumsStreamsAndZeroPadsTheShorterInput` with updated expected value, plus 5 new tests covering AC-1 (general sum), AC-2 (single-source, both directions), and AC-3 (positive/negative overflow clamp).

## Caveats

- **两轨同时大声时的削波失真 is intentionally not addressed.** This is a known, accepted tradeoff per the handoff doc — summing without averaging means two simultaneously loud sources can clip at the Int16 boundary. That is preferable to the amplitude halving this fix resolves, and is out of scope for this task.
- Stray `* 2.*` / duplicate-named files were checked (`find . -name "* 2.*" -o -name "*Contents 2*" -o -name "*Contents 3*"`): all hits are inside gitignored `.build/` and `dist/` build-artifact directories (e.g. `dist/Whisper Swift 2.app`, `.build/.../ContentView 2.dia`), unrelated to this change and not tracked by git. No deletion was necessary.

## Confirmations

- **Not pushed**: only local commits on `handoff/2026-09-05-pcm16mixer-sum`; no `git push` was run.
- **SPIKE untouched**: `MixedAudioRecordingController.swift` and `MixedAudioRecordingControllerTests.swift` were never opened, edited, staged, or committed by this task.
- **No `.env`/Keychain access**: not read or touched.
- **No package.sh / .app build / Notion / README**: none run.
- **Commit hash**: `f65b146` on branch `handoff/2026-09-05-pcm16mixer-sum` (base `5d342b9`).
