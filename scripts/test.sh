#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
# UI tests share the main thread; running suites one at a time keeps their waits from timing out under load.
swift test --no-parallel "$@"
