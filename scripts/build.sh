#!/bin/zsh
# Builds Gita.app into build/app.noindex/Gita.app (.noindex keeps build copies out of Spotlight and Launchpad).
#   scripts/build.sh                                release build (native arch)
#   CONFIG=debug scripts/build.sh                   debug build
#   CONFIG=release ARCH=universal scripts/build.sh  Apple Silicon + Intel
#   PACKAGE_ZIP=1 scripts/build.sh                  also create build/Gita-<version>-macos.zip + .sha256 + verify-zip.sh
#   GITA_SIGN_IDENTITY="Developer ID Application: …" GITA_NOTARY_PROFILE=gita-notary \
#     CONFIG=release ARCH=universal scripts/build.sh
#     signs with Developer ID, notarizes, staples, creates Gita-<version>-macos.zip + .sha256 + .release.txt,
#     runs verify-zip.sh, signs with Sparkle's shared EdDSA key, and reveals the ZIP in Finder (unless NO_REVEAL=1).
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
source "$ROOT/scripts/toolchain.sh"

CONFIG=${CONFIG:-release}
ARCH=${ARCH:-native}
SIGN_IDENTITY=${GITA_SIGN_IDENTITY:-${SIGN_IDENTITY:-}}
NOTARY_PROFILE=${GITA_NOTARY_PROFILE:-${NOTARY_PROFILE:-}}
PACKAGE_ZIP=${PACKAGE_ZIP:-0}
if [[ -n "$NOTARY_PROFILE" ]]; then
  PACKAGE_ZIP=1
fi
if [[ -z "${REQUIRE_LOCALIZATIONS+x}" ]]; then
  if [[ "$CONFIG" == release || -n "$NOTARY_PROFILE" ]]; then
    REQUIRE_LOCALIZATIONS=1
  else
    REQUIRE_LOCALIZATIONS=0
  fi
fi

case "$CONFIG" in
  release|Release) CONFIG=release ;;
  debug|Debug)     CONFIG=debug ;;
  *) printf 'CONFIG must be release or debug (got: %s)\n' "$CONFIG" >&2; exit 2 ;;
esac
case "$ARCH" in
  universal) SWIFT_ARCH_FLAGS=(--arch arm64 --arch x86_64); VERIFY_ARCH=universal ;;
  native)    SWIFT_ARCH_FLAGS=(); VERIFY_ARCH=$(uname -m) ;;
  arm64|x86_64) SWIFT_ARCH_FLAGS=(--arch "$ARCH"); VERIFY_ARCH="$ARCH" ;;
  *) printf 'ARCH must be universal, native, arm64, or x86_64 (got: %s)\n' "$ARCH" >&2; exit 2 ;;
esac

APP="$ROOT/build/app.noindex/Gita.app"
ICONS=""
cleanup() {
  if [[ -x "$ROOT/scripts/unregister-build-apps.sh" && -d "$APP" ]]; then
    "$ROOT/scripts/unregister-build-apps.sh" "$APP" || true
  fi
  if [[ -n "${ICONS:-}" && -d "$ICONS" ]]; then
    rm -rf "$ICONS"
  fi
}
trap cleanup EXIT

swift build -c "$CONFIG" "${SWIFT_ARCH_FLAGS[@]}"
BIN=$(swift build -c "$CONFIG" "${SWIFT_ARCH_FLAGS[@]}" --show-bin-path)

if [[ -x "$ROOT/scripts/unregister-build-apps.sh" && -d "$APP" ]]; then
  "$ROOT/scripts/unregister-build-apps.sh" "$APP"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

"$ROOT/scripts/strings.sh" compile "$APP/Contents/Resources"
if [[ "$REQUIRE_LOCALIZATIONS" == 1 ]]; then
  "$ROOT/scripts/strings.sh" check
fi

cp "$BIN/Gita" "$APP/Contents/MacOS/Gita"
cp "$BIN/gita-agent" "$APP/Contents/Helpers/gita-agent"

# Release: strip debug-map symbols (-S) before signing to drop /Users/ build paths while keeping crash symbols.
if [[ "$CONFIG" == release ]]; then
  strip -S "$APP/Contents/MacOS/Gita" "$APP/Contents/Helpers/gita-agent"
fi

BUILD=$(date -u +%Y%m%d%H%M)
# A source archive has no .git, and one unpacked inside another checkout must not report that checkout.
SOURCE_REVISION=unknown
SOURCE_DIRTY=false
if [[ "$(git rev-parse --show-toplevel 2>/dev/null || true)" == "$(pwd -P)" ]]; then
  SOURCE_REVISION=$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)
  CHANGES=$(git status --porcelain -- Sources Resources Package.swift Config scripts 2>/dev/null || echo unknown)
  [[ -z "$CHANGES" ]] || SOURCE_DIRTY=true
fi

# Product settings (Config/Product.xcconfig; `$()` is xcconfig's escape for `//`): raw, and escaped for the plist.
product_value() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" Config/Product.xcconfig \
    | tail -1 | sed -E 's/\$\(\)//g; s/[[:space:]]+$//'
}
product_setting() {
  product_value "$1" | sed -E 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}
PRODUCT_NAME=$(product_setting PRODUCT_NAME)
BUNDLE_ID=$(product_value PRODUCT_BUNDLE_IDENTIFIER)
VERSION=$(product_setting MARKETING_VERSION)
VERSION_RAW=$(product_value MARKETING_VERSION)
ZIP_BASENAME=$(product_value ZIP_BASENAME)
MINIMUM_SYSTEM=$(product_setting MACOSX_DEPLOYMENT_TARGET)
URL_SCHEME=$(product_setting URL_SCHEME)
WEBSITE_HOST=$(product_setting GITA_WEBSITE_HOST)

for setting in PRODUCT_NAME BUNDLE_ID VERSION MINIMUM_SYSTEM URL_SCHEME ZIP_BASENAME; do
  [[ -n "${(P)setting}" ]] || { printf 'Config/Product.xcconfig: missing %s\n' "$setting" >&2; exit 1; }
done
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { printf 'Config/Product.xcconfig: invalid bundle identifier\n' >&2; exit 1; }

SPARKLE_FEED_URL="https://getgita.app/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="TwKjQ7USQKbkf0Q0zq6N+17GXDxhmxXlxteHJn0T4jE="

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>$PRODUCT_NAME</string>
<key>CFBundleDisplayName</key><string>$PRODUCT_NAME</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Gita</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>GitaSourceRevision</key><string>$SOURCE_REVISION</string>
<key>GitaSourceDirty</key><$SOURCE_DIRTY/>
<key>GitaBuildConfiguration</key><string>$CONFIG</string>
<key>LSMinimumSystemVersion</key><string>$MINIMUM_SYSTEM</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Clever Mechanisms</string>
<key>GitaWebsiteHost</key><string>$WEBSITE_HOST</string>
<key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>SUSendProfileInfo</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>$PRODUCT_NAME</string><key>CFBundleTypeRole</key><string>Viewer</string><key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array></dict></array>
</dict></plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# App icon from the Gitā icon kit; regenerate Resources/AppIcon.icns with scripts/artwork.swift. macOS 26 and later
# frame an icon that comes only as an .icns in grey at small sizes (Notifications, list rows), so the build also
# compiles it into Assets.car, named by CFBundleIconName; the .icns stays for the systems that read only it.
ICONS=$(mktemp -d)
CATALOG="$ICONS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$CATALOG" "$ICONS/compiled"
iconutil -c iconset Resources/AppIcon.icns -o "$ICONS/AppIcon.iconset"
cp "$ICONS"/AppIcon.iconset/*.png "$CATALOG/"
{
  printf '{"images":['
  separator=
  for size in 16 32 128 256 512; do
    for scale in 1 2; do
      suffix=
      [[ $scale == 2 ]] && suffix=@2x
      printf '%s{"idiom":"mac","size":"%sx%s","scale":"%sx","filename":"icon_%sx%s%s.png"}' \
        "$separator" "$size" "$size" "$scale" "$size" "$size" "$suffix"
      separator=,
    done
  done
  printf '],"info":{"author":"xcode","version":1}}\n'
} > "$CATALOG/Contents.json"
printf '{"info":{"author":"xcode","version":1}}\n' > "$ICONS/Assets.xcassets/Contents.json"
if ! xcrun actool --compile "$ICONS/compiled" --platform macosx --minimum-deployment-target "$MINIMUM_SYSTEM" \
  --app-icon AppIcon --output-partial-info-plist "$ICONS/compiled/partial.plist" --errors --warnings \
  "$ICONS/Assets.xcassets" > "$ICONS/actool.log"; then
  cat "$ICONS/actool.log" >&2
  exit 1
fi
cp "$ICONS/compiled/Assets.car" "$ICONS/compiled/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICONS"
ICONS=""

# Bundled code fonts (Settings › General › Code font), registered per process on first use; licences beside them.
rm -rf "$APP/Contents/Resources/Fonts"; cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# Official agent logos (LobeHub Icons, MIT), drawn by AgentMarkPainter.
rm -rf "$APP/Contents/Resources/AgentMarks"; cp -R Resources/AgentMarks "$APP/Contents/Resources/AgentMarks"
# GitLab and Bitbucket marks for remotes (Simple Icons, CC0), drawn by BrandMarks.
rm -rf "$APP/Contents/Resources/ProviderMarks"; cp -R Resources/ProviderMarks "$APP/Contents/Resources/ProviderMarks"
# The built-in terminal's page and xterm.js (MIT, its licenses in Terminal/xterm/).
rm -rf "$APP/Contents/Resources/Terminal"; cp -R Resources/Terminal "$APP/Contents/Resources/Terminal"
# Review skills handed to the agent (README › Review skills: each with its license).
rm -rf "$APP/Contents/Resources/ReviewSkills"; cp -R Resources/ReviewSkills "$APP/Contents/Resources/ReviewSkills"

# Third-party notices (fail closed when Resources/ThirdParty/ is present and empty or lacks ThirdParty-Notices.txt).
THIRD_PARTY_SRC="$ROOT/Resources/ThirdParty"
if [[ -d "$THIRD_PARTY_SRC" ]]; then
  if [[ -z "$(find "$THIRD_PARTY_SRC" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    printf 'Resources/ThirdParty/ is empty; add third-party notices before building.\n' >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources/ThirdParty"
  /usr/bin/ditto "$THIRD_PARTY_SRC" "$APP/Contents/Resources/ThirdParty"
  [[ -f "$APP/Contents/Resources/ThirdParty/ThirdParty-Notices.txt" ]] \
    || { printf 'Resources/ThirdParty/ThirdParty-Notices.txt is missing.\n' >&2; exit 1; }
fi

# Embed Sparkle.framework when built by SwiftPM. Gitā is not sandboxed, so Sparkle installs updates directly
# via Autoupdate + Updater.app and its sandbox XPCServices are removed before inside-out signing.
SPARKLE=""
SPARKLE_SOURCE="$BIN/Sparkle.framework"
if [[ -d "$SPARKLE_SOURCE" ]]; then
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  mkdir -p "$APP/Contents/Frameworks"
  /usr/bin/ditto "$SPARKLE_SOURCE" "$SPARKLE"
  rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
  if ! otool -l "$APP/Contents/MacOS/Gita" | grep -A2 LC_RPATH | grep -qF "path @executable_path/../Frameworks "; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Gita"
  fi
elif grep -qF "Sparkle" "$ROOT/Package.swift" 2>/dev/null; then
  printf 'Sparkle.framework not found at %s\n' "$SPARKLE_SOURCE" >&2
  exit 1
fi

# Extended attributes (quarantine flags, Finder info) have no place in a signed bundle.
xattr -cr "$APP"

# Signing. Local builds are ad-hoc signed. A distributable build signs with a Developer ID, the hardened runtime and
# a secure timestamp when GITA_SIGN_IDENTITY / SIGN_IDENTITY names the certificate, and is notarized and stapled
# when GITA_NOTARY_PROFILE / NOTARY_PROFILE names an `xcrun notarytool store-credentials` profile.
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  if [[ -n "$SPARKLE" ]]; then
    codesign "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
    codesign "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
    codesign "${SIGN[@]}" "$SPARKLE"
  fi
  codesign "${SIGN[@]}" --identifier "$BUNDLE_ID.agent" "$APP/Contents/Helpers/gita-agent"
  codesign "${SIGN[@]}" --identifier "$BUNDLE_ID" "$APP"
else
  [[ -z "$NOTARY_PROFILE" ]] || { printf 'GITA_NOTARY_PROFILE needs GITA_SIGN_IDENTITY\n' >&2; exit 1; }
  if [[ -n "$SPARKLE" ]]; then
    codesign --force --sign - "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --sign - "$SPARKLE/Versions/B/Updater.app"
    codesign --force --sign - "$SPARKLE"
  fi
  codesign --force --sign - --identifier "$BUNDLE_ID.agent" "$APP/Contents/Helpers/gita-agent"
  codesign --force --sign - --identifier "$BUNDLE_ID" --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi

codesign --verify --deep --strict "$APP"
if [[ -n "$SPARKLE" ]]; then
  "$ROOT/scripts/check-updater.sh" "$APP"
fi

if (( PACKAGE_ZIP )); then
  ARCHIVE_NAME="${ZIP_BASENAME}-${VERSION_RAW}-macos.zip"
  ARCHIVE="$ROOT/build/$ARCHIVE_NAME"
  RELEASE_TXT="$ROOT/build/${ZIP_BASENAME}-${VERSION_RAW}-macos.release.txt"
  rm -f "$ARCHIVE" "$ARCHIVE.sha256" "$RELEASE_TXT"

  NOTARIZED=0
  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARIZE_ZIP="$ROOT/build/notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" \
      --wait --output-format json > "$ROOT/build/notarize.json" || true
    rm -f "$NOTARIZE_ZIP"
    NOTARY_ID=$(plutil -extract id raw "$ROOT/build/notarize.json")
    NOTARY_STATUS=$(plutil -extract status raw "$ROOT/build/notarize.json")
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" "$ROOT/build/notarize-log.json" >/dev/null || true
    printf 'Notarization submission %s: %s (log: build/notarize-log.json)\n' "$NOTARY_ID" "$NOTARY_STATUS"
    [[ "$NOTARY_STATUS" == Accepted ]] || exit 1
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    NOTARIZED=1
  fi

  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
  (cd "$ROOT/build" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
  SHA256=$(awk '{print $1}' "$ARCHIVE.sha256")
  SIZE=$(stat -f%z "$ARCHIVE")

  VERIFY_ARGS=(--arch "$VERIFY_ARCH")
  if (( ! NOTARIZED )); then
    VERIFY_ARGS+=(--allow-unnotarized)
  fi
  "$ROOT/scripts/verify-zip.sh" "${VERIFY_ARGS[@]}" "$ARCHIVE"

  if (( NOTARIZED )); then
    SPARKLE_BIN=""
    for candidate in \
      "$ROOT/.build/artifacts/sparkle/Sparkle/bin" \
      "$ROOT/build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"; do
      if [[ -x "$candidate/sign_update" ]]; then
        SPARKLE_BIN="$candidate"
        break
      fi
    done
    [[ -n "$SPARKLE_BIN" ]] || { printf 'Sparkle sign_update not found in .build/artifacts or DerivedData\n' >&2; exit 1; }

    # Shared Clever Mechanisms EdDSA key in login keychain: never pass --account.
    ED_SIGNATURE=$("$SPARKLE_BIN/sign_update" -p "$ARCHIVE")
    "$SPARKLE_BIN/sign_update" --verify "$ARCHIVE" "$ED_SIGNATURE" \
      || { printf 'Sparkle EdDSA signature verification failed for %s\n' "$ARCHIVE" >&2; exit 1; }
    if [[ -x "$SPARKLE_BIN/generate_keys" ]]; then
      PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" -p)
      APP_KEY=$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")
      [[ "$PUBLIC_KEY" == "$APP_KEY" ]] \
        || { printf 'Keychain EdDSA public key (%s) does not match SUPublicEDKey (%s)\n' "$PUBLIC_KEY" "$APP_KEY" >&2; exit 1; }
    fi

    DOWNLOAD_URL="https://github.com/clever-mechanisms/gita/releases/download/v${VERSION_RAW}/${ARCHIVE_NAME}"
    cat > "$RELEASE_TXT" <<EOF
version: $VERSION_RAW
build: $BUILD
filename: $ARCHIVE_NAME
zipPath: $ARCHIVE
sizeBytes: $SIZE
sha256: $SHA256
edSignature: $ED_SIGNATURE
feedURL: $SPARKLE_FEED_URL
downloadURL: $DOWNLOAD_URL
EOF
    printf 'Wrote %s\n' "$RELEASE_TXT"
    sed 's/^/  /' "$RELEASE_TXT"
  fi

  printf 'Packaged %s (%s bytes, sha256 %s)\n' "$ARCHIVE" "$SIZE" "$SHA256"
  if [[ "${NO_REVEAL:-0}" != 1 && -z "${CI:-}" ]]; then
    open -R "$ARCHIVE" || true
  fi
fi

"$ROOT/scripts/unregister-build-apps.sh" "$APP"
trap - EXIT
printf 'Built %s (%s, %s)\n' "$APP" "$CONFIG" "$ARCH"
