#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="build/app.noindex/Gita.app"
DEST="/Applications/Gita.app"
ID=dev.clevermechanisms.Gita
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist") == "$ID" ]]
codesign --verify --deep --strict "$SOURCE"
STAGE=$(mktemp -d /Applications/.gita-install.XXXXXX.noindex)
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$SOURCE" "$STAGE/Gita.app"
codesign --verify --deep --strict "$STAGE/Gita.app"
if [[ -e "$DEST" ]]; then
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist") == "$ID" ]]
fi
PIDS=$(pgrep -f '^/Applications/Gita.app/Contents/MacOS/Gita' || true)
if [[ -n "$PIDS" ]]; then kill $PIDS; for i in {1..30}; do if ! pgrep -f '^/Applications/Gita.app/Contents/MacOS/Gita' >/dev/null; then break; fi; sleep 0.1; done; fi
if [[ -e "$DEST" ]]; then mv "$DEST" "$STAGE/Previous.app"; fi
if ! mv "$STAGE/Gita.app" "$DEST"; then [[ ! -e "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" "$DEST"; exit 1; fi
codesign --verify --deep --strict "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$SOURCE" 2>/dev/null || true
open "$DEST" "$@"
printf 'Installed %s\n' "$DEST"
