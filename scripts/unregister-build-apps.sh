#!/bin/zsh
# Unregister built, staged, or verified .app copies from Launch Services so Spotlight and
# Launch Services only ever track the single installed copy in /Applications.
# lsregister returns non-zero when a build product was never registered.
set -eu
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in "$@"; do
  "$lsregister" -u "$app" >/dev/null 2>&1 || true
done
