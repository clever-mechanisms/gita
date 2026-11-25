#!/bin/zsh
# Post-extraction verification of a packaged Gitā release ZIP.
# Extracts to a temporary .noindex directory with ditto -x -k, verifies code signature,
# notarization & Gatekeeper, universal slices, Info.plist metadata, Assets.car, ThirdParty notices,
# >= 19 .lproj bundles, and Sparkle updater (when embedded), then unregisters and deletes the
# temporary extraction on exit.
#   scripts/verify-zip.sh build/Gita-<version>-macos.zip
#   scripts/verify-zip.sh --allow-unnotarized --arch arm64 build/Gita-<version>-macos.zip
set -euo pipefail

ROOT=${0:A:h:h}
ALLOW_UNNOTARIZED=0
EXPECTED_ARCH=universal
TEAM_ID=${TEAM_ID:-PCZ6F8Q9DZ}

while (( $# > 0 )); do
  case "$1" in
    --allow-unnotarized)
      ALLOW_UNNOTARIZED=1
      shift
      ;;
    --arch)
      [[ $# -ge 2 ]] || { echo "Missing value after --arch" >&2; exit 2; }
      EXPECTED_ARCH="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/verify-zip.sh [--allow-unnotarized] [--arch universal|arm64|x86_64] <zip>"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

ZIP=${1:?Usage: scripts/verify-zip.sh [--allow-unnotarized] [--arch universal|arm64|x86_64] <zip>}
[[ -f "$ZIP" ]] || { echo "ZIP not found: $ZIP" >&2; exit 1; }

VERIFY_ROOT="$ROOT/build/Verify.noindex"
mkdir -p "$VERIFY_ROOT"
WORK_DIR=$(mktemp -d "$VERIFY_ROOT/verify.XXXXXX")
EXTRACTED_APP="$WORK_DIR/Gita.app"
cleanup() {
  if [[ -d "$EXTRACTED_APP" ]]; then
    "$ROOT/scripts/unregister-build-apps.sh" "$EXTRACTED_APP" || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  echo "ZIP verification failed: $*" >&2
  exit 1
}

echo "==> Extracting $ZIP"
/usr/bin/ditto -x -k "$ZIP" "$WORK_DIR"
[[ -d "$EXTRACTED_APP" ]] || fail "Gita.app not found inside $ZIP"

PLIST="$EXTRACTED_APP/Contents/Info.plist"
APP_BIN="$EXTRACTED_APP/Contents/MacOS/Gita"
HELPER_BIN="$EXTRACTED_APP/Contents/Helpers/gita-agent"

BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$PLIST" 2>/dev/null) || fail "missing CFBundleIdentifier"
[[ "$BUNDLE_ID" == "dev.clevermechanisms.Gita" ]] || fail "unexpected CFBundleIdentifier: $BUNDLE_ID"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null) || fail "missing CFBundleShortVersionString"
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST" 2>/dev/null) || fail "missing CFBundleVersion"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "empty version ($VERSION) or build ($BUILD)"
echo "    Bundle: $BUNDLE_ID $VERSION ($BUILD)"

echo "==> Code signature"
codesign --verify --deep --strict "$EXTRACTED_APP" || fail "codesign --verify --deep --strict failed"

if (( ! ALLOW_UNNOTARIZED )); then
  echo "==> Notarization & Gatekeeper"
  SIG=$(codesign -dvv "$EXTRACTED_APP" 2>&1)
  [[ "$SIG" == *"Authority=Developer ID Application"* ]] || fail "missing Developer ID Application authority"
  [[ "$SIG" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "unexpected TeamIdentifier (expected $TEAM_ID)"
  [[ "$SIG" == *"(runtime)"* ]] || fail "missing Hardened Runtime flag"
  xcrun stapler validate "$EXTRACTED_APP" || fail "stapler validate failed"
  SPCTL_OUT=$(spctl --assess -vv "$EXTRACTED_APP" 2>&1) || fail "spctl assessment failed: $SPCTL_OUT"
  [[ "$SPCTL_OUT" == *"Notarized Developer ID"* ]] || fail "spctl did not report Notarized Developer ID: $SPCTL_OUT"
  echo "    $SPCTL_OUT"
else
  echo "==> Skipping stapler/spctl notarization checks (--allow-unnotarized)"
fi

echo "==> Architectures"
[[ -f "$APP_BIN" ]] || fail "app executable missing: $APP_BIN"
[[ -f "$HELPER_BIN" ]] || fail "helper executable missing: $HELPER_BIN"
APP_ARCHS=$(lipo -archs "$APP_BIN")
HELPER_ARCHS=$(lipo -archs "$HELPER_BIN")
if [[ "$EXPECTED_ARCH" == "universal" ]]; then
  [[ " $APP_ARCHS " == *" x86_64 "* && " $APP_ARCHS " == *" arm64 "* ]] \
    || fail "app executable is not universal (x86_64 arm64): $APP_ARCHS"
  [[ " $HELPER_ARCHS " == *" x86_64 "* && " $HELPER_ARCHS " == *" arm64 "* ]] \
    || fail "helper executable is not universal (x86_64 arm64): $HELPER_ARCHS"
else
  [[ " $APP_ARCHS " == *" $EXPECTED_ARCH "* ]] \
    || fail "app executable missing expected architecture $EXPECTED_ARCH: $APP_ARCHS"
  [[ " $HELPER_ARCHS " == *" $EXPECTED_ARCH "* ]] \
    || fail "helper executable missing expected architecture $EXPECTED_ARCH: $HELPER_ARCHS"
fi
echo "    App: $APP_ARCHS | Helper: $HELPER_ARCHS"

echo "==> App icon & Assets.car"
[[ -f "$EXTRACTED_APP/Contents/Resources/Assets.car" ]] || fail "Contents/Resources/Assets.car is missing"
[[ -f "$EXTRACTED_APP/Contents/Resources/AppIcon.icns" ]] || fail "Contents/Resources/AppIcon.icns is missing"
ICON_NAME=$(plutil -extract CFBundleIconName raw "$PLIST" 2>/dev/null || true)
[[ "$ICON_NAME" == "AppIcon" ]] || fail "CFBundleIconName must be AppIcon (got: ${ICON_NAME:-<missing>})"
echo "    Assets.car + AppIcon.icns verified (CFBundleIconName=$ICON_NAME)"

echo "==> Third-party notices"
[[ -f "$EXTRACTED_APP/Contents/Resources/ThirdParty/ThirdParty-Notices.txt" ]] \
  || fail "Contents/Resources/ThirdParty/ThirdParty-Notices.txt is missing"
echo "    Contents/Resources/ThirdParty/ThirdParty-Notices.txt verified"

echo "==> Localizations"
LPROJ_COUNT=$(find "$EXTRACTED_APP/Contents/Resources" -maxdepth 1 -type d -name '*.lproj' | wc -l | tr -d ' ')
(( LPROJ_COUNT >= 19 )) || fail "expected >= 19 .lproj directories, found $LPROJ_COUNT"
echo "    $LPROJ_COUNT .lproj bundles"

echo "==> Updater guard"
[[ -x "$ROOT/scripts/check-updater.sh" ]] || fail "required guard missing or not executable: scripts/check-updater.sh"
"$ROOT/scripts/check-updater.sh" "$EXTRACTED_APP"

echo "==> Verified $ZIP ($VERSION build $BUILD)"
