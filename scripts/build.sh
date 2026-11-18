#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-native}"
if [[ "$ARCH" == universal ]]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64
else
  swift build -c "$CONFIG"
fi
if [[ "$ARCH" == universal ]]; then BIN=$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path); else BIN=$(swift build -c "$CONFIG" --show-bin-path); fi
APP="build/app.noindex/Gita.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
scripts/strings.sh compile "$APP/Contents/Resources"
if [[ "${REQUIRE_LOCALIZATIONS:-0}" == 1 ]]; then scripts/strings.sh check; fi
cp "$BIN/Gita" "$APP/Contents/MacOS/Gita"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/gita-agent" "$APP/Contents/Helpers/gita-agent"
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
product_value() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" Config/Product.xcconfig | tail -1 | sed -E 's/\$\(\)//g; s/[[:space:]]+$//'; }
product_setting() { product_value "$1" | sed -E 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
PRODUCT_NAME=$(product_setting PRODUCT_NAME)
BUNDLE_ID=$(product_value PRODUCT_BUNDLE_IDENTIFIER)
VERSION=$(product_setting MARKETING_VERSION)
MINIMUM_SYSTEM=$(product_setting MACOSX_DEPLOYMENT_TARGET)
URL_SCHEME=$(product_setting URL_SCHEME)
WEBSITE_HOST=$(product_setting GITA_WEBSITE_HOST)
for setting in PRODUCT_NAME BUNDLE_ID VERSION MINIMUM_SYSTEM URL_SCHEME; do
  [[ -n "${!setting}" ]] || { printf 'Config/Product.xcconfig: missing %s\n' "$setting" >&2; exit 1; }
done
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { printf 'Config/Product.xcconfig: invalid bundle identifier\n' >&2; exit 1; }
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
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>$PRODUCT_NAME</string><key>CFBundleTypeRole</key><string>Viewer</string><key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array></dict></array>
</dict></plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"
# App icon from the Gitá icon kit; regenerate Resources/AppIcon.icns with scripts/artwork.swift. macOS 26 and later
# frame an icon that comes only as an .icns in grey at small sizes (Notifications, list rows), so the build also
# compiles it into Assets.car, named by CFBundleIconName; the .icns stays for the systems that read only it.
ICONS=$(mktemp -d)
trap 'rm -rf "$ICONS"' EXIT
CATALOG="$ICONS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$CATALOG" "$ICONS/compiled"
iconutil -c iconset Resources/AppIcon.icns -o "$ICONS/AppIcon.iconset"
cp "$ICONS"/AppIcon.iconset/*.png "$CATALOG/"
{
  printf '{"images":['
  separator=
  for size in 16 32 128 256 512; do
    for scale in 1 2; do
      suffix=; [[ $scale == 2 ]] && suffix=@2x
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
  cat "$ICONS/actool.log" >&2; exit 1
fi
cp "$ICONS/compiled/Assets.car" "$ICONS/compiled/AppIcon.icns" "$APP/Contents/Resources/"
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
# Signing. Local builds are ad-hoc signed. A distributable build signs with a Developer ID, the hardened runtime and
# a secure timestamp when GITA_SIGN_IDENTITY names the certificate ("Developer ID Application: Name (TEAMID)"),
# and is notarized and stapled when GITA_NOTARY_PROFILE names a `xcrun notarytool store-credentials` profile.
# The script only passes these names to codesign and notarytool; it never reads credentials itself.
SIGN_IDENTITY=${GITA_SIGN_IDENTITY:-}
NOTARY_PROFILE=${GITA_NOTARY_PROFILE:-}
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  codesign "${SIGN[@]}" --identifier "$BUNDLE_ID.agent" "$APP/Contents/Helpers/gita-agent"
  codesign "${SIGN[@]}" --identifier "$BUNDLE_ID" "$APP"
else
  [[ -z "$NOTARY_PROFILE" ]] || { printf 'GITA_NOTARY_PROFILE needs GITA_SIGN_IDENTITY\n' >&2; exit 1; }
  codesign --force --sign - --identifier "$BUNDLE_ID.agent" "$APP/Contents/Helpers/gita-agent"
  codesign --force --sign - --identifier "$BUNDLE_ID" --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
codesign --verify --deep --strict "$APP"
if [[ -n "$NOTARY_PROFILE" ]]; then
  ARCHIVE="build/$(product_value ZIP_BASENAME)-$(product_value MARKETING_VERSION).zip"
  rm -f "$ARCHIVE"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ARCHIVE"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
  printf 'Notarized and stapled: %s\n' "$ARCHIVE"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
printf 'Built %s (%s, %s)\n' "$APP" "$CONFIG" "$ARCH"
