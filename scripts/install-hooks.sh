#!/bin/bash
# Makes git run scripts/quality.sh before every push in this clone. `git push --no-verify` skips it once.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
printf 'Installed: .githooks/pre-push runs scripts/quality.sh before every push.\n'
