#!/bin/bash
# Installs Periphery, the quality gate's dead-code tool, into .build/tools/periphery (scripts/toolchain.sh puts it on
# PATH). Periphery went commercial and archived its open-source repository, so Homebrew disables its formula on
# 2027-08-12; this pins the last open-source release (MIT) by checksum instead. Run by CI and once per checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=3.8.0
SHA256=07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7
DEST=.build/tools/periphery

if [[ -x $DEST/periphery && $("$DEST/periphery" version 2>/dev/null) == "$VERSION" ]]; then
  echo "periphery $VERSION already in $DEST"
  exit 0
fi

download=$(mktemp -d)
trap 'rm -rf "$download"' EXIT
curl --fail --silent --show-error --location --retry 3 --output "$download/periphery.zip" \
  "https://github.com/peripheryapp/periphery/releases/download/$VERSION/periphery-$VERSION.zip"
echo "$SHA256  $download/periphery.zip" | shasum --algorithm 256 --check --quiet
rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$download/periphery.zip" -d "$DEST"
echo "periphery $("$DEST/periphery" version) installed in $DEST"
