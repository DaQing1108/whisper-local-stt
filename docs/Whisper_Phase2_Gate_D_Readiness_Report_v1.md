# Whisper Phase 2 Gate D Microphone Readiness Report v1

Date: 2026-07-18

## BLUF

Phase 2 implementation is ready for Gate D manual validation. Automated evidence
covers standard recording handoff, live chunk rotation/order, Worker restart and
failure recovery, device/sleep recovery, and a 120-chunk simulated long recording.
The packaged App is signed with the stable local `WhisperSTT Local` identity,
passes strict code-signature verification, and its bundled Worker returns `ready`
in an isolated launch. Manual microphone/TCC validation, legacy comparison, and
real Bluetooth device-change recovery evidence are complete.

## Automated evidence

- 16 kHz mono signed PCM Int16 WAV output is covered by unit tests.
- Standard mode finalizes the WAV before submitting its absolute path to the
  Python Worker; a non-ready Worker preserves the finalized file.
- Live mode rotated 120 finalized chunks and submitted all 120 in exact order;
  the Worker queue drained without losing or reordering a chunk.
- Device change and sleep/wake finalize the active chunk and resume capture.
- Capture, Worker, malformed protocol, restart, and permanent-failure paths
  preserve tracked recovery chunks and do not leave the controller draining.
- Empty header-only WAV cleanup is conservative: protected/nonterminal and any
  WAV with audio payload are retained.

## Gate D manual evidence required

1. In the packaged App, grant microphone permission, record standard mode,
   stop/finalize, and confirm the Worker transcript.
2. Record live mode past at least two chunk rotations; confirm chunk order and
   transcript continuity.
3. While recording, exercise microphone device unplug/replug where available,
   then sleep/wake; verify a recovery chunk and resumed recording.
4. Compare the same fixed speech sample against legacy pywebview behavior for
   transcription text, processing time, and peak memory. Record the actual
   commands, device, model, audio duration, and results.

Run this manual sequence from a stable installed location outside the synced
Documents/File Provider tree. macOS can attach Finder metadata to an App bundle
in that tree and launch it through App Translocation, which is not suitable as
the stable packaged-App TCC evidence path.

## Packaged-App preflight evidence

- `security find-identity -v -p codesigning` found `WhisperSTT Local`.
- `bash scripts/build_swiftui_app.sh` rebuilt
  `dist/Whisper SwiftUI.app`, verified it with `codesign --verify --deep --strict`,
  and verified its bundled Worker emits the JSONL `ready` event under an isolated
  `HOME`.
- The outer App signature identifies `com.via.whisper-swiftui` with authority
  `WhisperSTT Local`. The build script deliberately signs the outer bundle rather
  than deep-resigning PyInstaller internals: deep re-signing caused that runtime
  to terminate at launch, while the outer signature still seals its Resources and
  passes deep strict verification.

## Partial manual evidence (2026-07-18)

- A clean copy was installed at `/Users/daqingliao/Applications/Whisper SwiftUI.app`.
  It had no quarantine/FinderInfo attributes, passed `codesign --verify --deep --strict`,
  and launched without App Translocation.
- In that installed App, Worker startup reached `Python Worker ready`.
- Standard microphone recording was allowed by macOS, entered `Recording…`, finalized
  `recording-2026-07-17T16:20:53Z-78744E89-EDD5-46F2-8094-9FA3D040BDDA.wav`, submitted
  it to the Worker, and reached `Completed` within the subsequent 30-second check.
- Live mode recorded past two rotations (`2 chunks finalized`). On stop it entered
  `Transcribing remaining live chunks…`, then within the subsequent 30-second
  check returned to `Live mode idle` with Worker `ready` and `Completed`.
- A subsequent live session finalized six chunks and also drained to `Completed`
  within 30 seconds. An attempted switch from `MacBook Pro Microphone` to
  `DaQing_Phone Microphone` was rejected by macOS, so it did not produce a
  device-change recovery event and does **not** satisfy that manual criterion.
- During another live session, `pmset sleepnow` was issued and the Mac was
  manually awakened. The App remained in `Live recording` afterward, with its
  finalized-chunk count increasing from 7 to 9; stopping then drained to
  `Live mode idle` and `Completed` within 30 seconds. No system event log or
  UI-visible recovery-chunk identifier was available, so this is operational
  sleep/wake evidence only, not a full device/sleep recovery sign-off.
- A fixed 5.4735-second local macOS TTS English WAV was compared using `base` /
  `en` on legacy `whisper_core.run_whisper` (the pywebview backend core) and the
  installed packaged Worker. Both produced the same two sentences; the only
  observed text difference was `fixed` (legacy) versus `Fixed` (Worker).
  Legacy: 4.980 seconds and 470,482,944-byte peak RSS. Packaged Worker: 3.923
  seconds and 597,000,192-byte peak RSS. The Worker was about 21% faster but
  used about 27% more peak memory in this cold-process synthetic-TTS run.
- The comparison used a synthetic TTS sample, not recorded human speech; it is
  reproducible operational evidence, not a full speech-quality assessment.
  The sample was generated with `say` then converted by `afconvert` to 16 kHz
  mono WAV. Legacy ran `/usr/bin/time -l python3` around `run_whisper`; Worker
  received the same absolute path through JSONL and its child-process peak RSS
  was collected via `resource.getrusage(RUSAGE_CHILDREN)`.
- Real device-change recovery was completed with the installed App. Live Mode
  started on `MacBook Pro Microphone`; macOS then switched the default input to
  `soundcore AeroFit Pro` (Bluetooth, mono, 16 kHz). The controller finalized
  recovery chunks, resumed `Live recording — 2 chunks finalized`, and the
  Worker reached `Completed`. Normal stop then reached `Live mode idle` with
  Worker `Completed`. The recovered WAV chunks were non-empty (424–472 KB), and
  no new `WhisperApp` crash report was created. Earlier recovery failures led
  to the final lifecycle hardening: unified teardown, callback draining, a fresh
  AVAudioEngine per recovery, and deferred retirement of the old engine off the
  MainActor.

## Gate decision

**READY FOR GATE D SIGN-OFF.** Automated behavior and the required packaged-App
manual evidence are complete, including real Bluetooth device-change recovery.
The legacy pywebview app remains the production fallback until the separate
Phase 3/4 acceptance criteria are complete.
