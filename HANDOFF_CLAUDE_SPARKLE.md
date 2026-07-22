# Claude Code Handoff: Sparkle Auto Update

Date: 2026-06-26
Project: `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper`
Repo: `https://github.com/DaQing1108/whisper-local-stt.git`

## BLUF

Sparkle is integrated locally and the app packages successfully with `Sparkle.framework`.

Remaining blocker: GitHub Release upload is not done because `gh auth status` reported the `DaQing1108` token is invalid. Re-authenticate GitHub CLI, then create/upload the `v1.6.8` release assets.

## Completed

- Downloaded Sparkle `2.9.3`.
- Added `Sparkle.framework` to the project root.
- Generated Sparkle EdDSA key with:

```bash
/private/tmp/sparkle-2.9.3/bin/generate_keys --account com.via.whisper-ai
```

- Private key is stored in macOS Keychain under account `com.via.whisper-ai`.
- Public key is installed in `Info.plist` and `gui.spec`:

```text
TqckZdtuk2dvHruKRwDkDgMu2XqRtyH0KhViZxj33lg=
```

- Feed URL is installed in `Info.plist` and `gui.spec`:

```text
https://github.com/DaQing1108/whisper-local-stt/releases/latest/download/appcast.xml
```

- `bash package.sh` completed successfully.
- Installed app exists at:

```text
/Applications/Whisper STT.app
```

- Local release artifact generated:

```text
release/Whisper-STT-1.6.8.zip
```

- Local appcast generated:

```text
release/appcast.xml
```

## Files Changed By This Work

- `Info.plist`
  - Added real `SUFeedURL`.
  - Added real `SUPublicEDKey`.

- `gui.spec`
  - Preserves `Sparkle.framework` in PyInstaller input.
  - Adds Sparkle plist keys.
  - Adds `PyObjCTools.AppHelper` hidden import.

- `package.sh`
  - Detects `Sparkle.framework`.
  - Copies it into `.app/Contents/Frameworks`.
  - Updates nested `.app` validation to ignore Sparkle's legal internal `Updater.app`.

- `sparkle_updater.py`
  - New PyObjC bridge.
  - Loads `Sparkle.framework`.
  - Creates `SPUStandardUpdaterController`.
  - Exposes `status()` and `check_for_updates()`.

- `routes.py`
  - Adds `/api/updates/status`.
  - Adds `/api/updates/check`.

- `templates/preferences.html`
  - Adds "檢查更新" button in Preferences.

- `static/preferences.js`
  - Loads Sparkle status.
  - Calls update-check endpoint.

- `README.md`
  - Documents Sparkle v1 decisions and release flow.

- `release/README.md`
  - Documents current Sparkle setup state and release steps.

- `release/appcast.template.xml`
  - Template for future appcasts.

- `release/appcast.xml`
  - Current local v1.6.8 appcast.

- `release/Sparkle-2.9.3.sha256`
  - SHA-256 record for the downloaded Sparkle tarball.

## Verification Already Run

```bash
plutil -lint Info.plist
python3 -c "compile(open('gui.spec').read(), 'gui.spec', 'exec')"
bash -n package.sh
node --check static/preferences.js
python3 -c "import sparkle_updater; print(sparkle_updater.status())"
python3 -c "import os, xml.etree.ElementTree as ET; ET.parse('release/appcast.xml'); assert os.path.getsize('release/Whisper-STT-1.6.8.zip') == 215786360; print('appcast OK')"
/private/tmp/sparkle-2.9.3/bin/sign_update --account com.via.whisper-ai --verify 'release/Whisper-STT-1.6.8.zip' 'SQv11KW76K1u2KEaifE9/BzkgfakQ7X0HFIii3g7G9WZ8ZPyYWHjiWHrBhXG6HypI1xPwCuQPvqkVlJvh189DA=='
bash package.sh
```

Important result:

```text
bash package.sh
...
✅ 打包完成！v1.6.8
   /Applications/Whisper STT.app
```

The app plist after packaging contains:

```text
CFBundleShortVersionString = 1.6.8
SUFeedURL = https://github.com/DaQing1108/whisper-local-stt/releases/latest/download/appcast.xml
SUPublicEDKey = TqckZdtuk2dvHruKRwDkDgMu2XqRtyH0KhViZxj33lg=
```

## Known Verification Caveats

- `make test` currently aborts during test collection while importing `mlx_whisper`, before reaching the Sparkle changes.
- `codesign --verify --deep --strict --verbose=2 'dist/Whisper STT.app'` reports `CSSMERR_TP_NOT_TRUSTED` because the app uses the local `WhisperSTT Local` certificate. This is expected for the current local signing model.
- PyInstaller emits an internal ad-hoc signing warning, but `package.sh` then signs with `WhisperSTT Local` successfully.

## Next Actions For Claude Code

1. Re-authenticate GitHub CLI:

```bash
gh auth login -h github.com
gh auth status
```

2. Confirm the release tag does not already exist:

```bash
git tag --list 'v1.6.8'
gh release view v1.6.8 --repo DaQing1108/whisper-local-stt
```

3. Create and upload GitHub Release assets:

```bash
gh release create v1.6.8 \
  release/Whisper-STT-1.6.8.zip \
  release/appcast.xml \
  --repo DaQing1108/whisper-local-stt \
  --title "Whisper STT v1.6.8" \
  --notes "Adds Sparkle framework packaging and update-check integration."
```

If the release already exists, upload assets instead:

```bash
gh release upload v1.6.8 \
  release/Whisper-STT-1.6.8.zip \
  release/appcast.xml \
  --repo DaQing1108/whisper-local-stt \
  --clobber
```

4. Verify the public appcast URL:

```bash
curl -I https://github.com/DaQing1108/whisper-local-stt/releases/latest/download/appcast.xml
curl -L https://github.com/DaQing1108/whisper-local-stt/releases/latest/download/appcast.xml
```

5. Launch `/Applications/Whisper STT.app`, open Preferences, click `檢查更新`.

Expected result depends on release version:

- If app is already `1.6.8` and appcast also advertises `1.6.8`, Sparkle should report no newer update.
- To test an actual update prompt, build a lower installed version or publish a higher appcast version.

## Do Not Commit

- Do not commit Sparkle private keys. They are in Keychain and should stay there.
- Do not commit `release/Whisper-STT-1.6.8.zip` unless the team explicitly wants binary artifacts in git. It is already covered by `*.zip` in `.gitignore`.
- Be careful with unrelated untracked files currently visible in `git status`, such as `poc_audio/`, `.claude/skills/debug/`, `whisper_server.log`, and `WhisperAI_ProductSpec_v1.md`.

## Useful Local Paths

```text
Sparkle framework:
/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/Sparkle.framework

Sparkle tools from this run:
/private/tmp/sparkle-2.9.3/bin/generate_keys
/private/tmp/sparkle-2.9.3/bin/sign_update

Downloaded tarball:
/private/tmp/Sparkle-2.9.3.tar.xz

Installed app:
/Applications/Whisper STT.app
```
