from pathlib import Path
import plistlib


SCRIPT = (Path(__file__).parents[2] / "scripts" / "release_swiftui_app.sh").read_text()
ROOT = Path(__file__).parents[2]


def test_release_pipeline_requires_developer_id_and_never_falls_back_to_local_or_adhoc():
    assert "Developer ID Application:" in SCRIPT
    assert "WHISPER_DEVELOPER_ID_APPLICATION" in SCRIPT
    assert "WhisperSTT Local" not in SCRIPT
    assert "--sign -" not in SCRIPT


def test_release_pipeline_hardens_notarizes_staples_and_gatekeeper_checks():
    assert "--options runtime --timestamp" in SCRIPT
    assert "notarytool submit" in SCRIPT
    assert "stapler staple" in SCRIPT
    assert "stapler validate" in SCRIPT
    assert "spctl -a -vv --type execute" in SCRIPT
    assert "codesign --verify --deep --strict" in SCRIPT


def test_verified_staging_replaces_existing_app_before_final_verification():
    verify_staging = SCRIPT.index('codesign --verify --deep --strict --verbose=2 "$STAGING"')
    remove_existing = SCRIPT.index('rm -rf "$APP"')
    move_staging = SCRIPT.index('mv "$STAGING" "$APP"')
    verify_final = SCRIPT.index('codesign --verify --deep --strict --verbose=2 "$APP"')
    archive = SCRIPT.index('ditto -c -k --keepParent "$APP"')

    assert verify_staging < remove_existing < move_staging < verify_final < archive


def test_local_build_clears_quarantine_after_final_app_move():
    local_build = (Path(__file__).parents[2] / "scripts" / "build_swiftui_app.sh").read_text()
    move_app = local_build.index('mv "$STAGING" "$APP"')
    clear_quarantine = local_build.index('xattr -cr "$APP"', move_app)
    clear_finder_info = local_build.index(
        'xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true',
        clear_quarantine,
    )
    verify_final = local_build.index(
        'codesign --verify --deep --strict --verbose=2 "$APP"',
        clear_finder_info,
    )

    assert move_app < clear_quarantine < clear_finder_info < verify_final


def test_swift_product_identity_is_distinct_and_declares_screen_capture_usage():
    with (ROOT / "macos" / "WhisperApp" / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)

    assert info["CFBundleName"] == "Whisper Swift"
    assert info["CFBundleDisplayName"] == "Whisper Swift"
    assert info["CFBundleIdentifier"] == "com.via.whisper-swiftui"
    assert info["NSScreenCaptureUsageDescription"]


def test_swift_build_and_release_use_unambiguous_bundle_names():
    local_build = (ROOT / "scripts" / "build_swiftui_app.sh").read_text()

    assert 'dist/Whisper Swift.app' in local_build
    assert 'dist/Whisper Swift.app' in SCRIPT
    assert 'Whisper-Swift-notarization.zip' in SCRIPT
    assert 'Whisper SwiftUI.app' not in local_build
    assert 'Whisper SwiftUI.app' not in SCRIPT
