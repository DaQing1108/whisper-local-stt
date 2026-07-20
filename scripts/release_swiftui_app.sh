#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$PROJECT_DIR/macos/WhisperApp"
RUNTIME_DIR="$PROJECT_DIR/dist/WhisperWorker"
APP="$PROJECT_DIR/dist/Whisper Swift.app"
STAGING="$PROJECT_DIR/dist/Whisper Swift.release-signing"
ARCHIVE="$PROJECT_DIR/dist/Whisper-Swift-notarization.zip"
SCRATCH="${SWIFT_SCRATCH_PATH:-/tmp/whisper-swift-release}"
IDENTITY="${WHISPER_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${WHISPER_NOTARY_KEYCHAIN_PROFILE:-}"

fail() { echo "Release preflight failed: $*" >&2; exit 2; }

case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    *) fail "WHISPER_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity" ;;
esac
[[ -n "$NOTARY_PROFILE" ]] \
    || fail "WHISPER_NOTARY_KEYCHAIN_PROFILE is required"
security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\"" \
    || fail "Developer ID identity is not installed: $IDENTITY"
command -v xcrun >/dev/null || fail "xcrun is unavailable"
xcrun notarytool --version >/dev/null

if [[ "${1:-}" == "--preflight" ]]; then
    echo "Release preflight passed for $IDENTITY"
    exit 0
fi
[[ $# -eq 0 ]] || fail "unknown argument: $1"

"$PROJECT_DIR/scripts/build_worker_runtime.sh"
python3 "$PROJECT_DIR/scripts/verify_worker_bundle.py" "$RUNTIME_DIR"

cd "$PACKAGE_DIR"
CLANG_MODULE_CACHE_PATH=/tmp/whisper-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/whisper-clang-cache \
swift build -c release --scratch-path "$SCRATCH"

rm -rf "$STAGING" "$ARCHIVE"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$SCRATCH/release/WhisperApp" "$STAGING/Contents/MacOS/WhisperApp"
cp "$PACKAGE_DIR/Info.plist" "$STAGING/Contents/Info.plist"
cp "$PROJECT_DIR/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"
cp -R "$RUNTIME_DIR" "$STAGING/Contents/Resources/WhisperWorker"
xattr -cr "$STAGING"

while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$candidate"
    fi
done < <(find "$STAGING/Contents" -type f -print0)

codesign --force --options runtime --timestamp \
    --entitlements "$PACKAGE_DIR/Release.entitlements" \
    --sign "$IDENTITY" "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"
rm -rf "$APP"
mv "$STAGING" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv --type execute "$APP"
codesign -dvvv "$APP"

echo "Notarized release ready: $APP"
