#!/bin/bash
# Full compiler extraction; source/format or strict shipping validation; CLT compile.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1
usage() {
  printf '%s\n' 'Usage: scripts/strings.sh extract [--allow-drop] | check [--source] | compile OUTPUT_RESOURCE_DIR' >&2
  exit 2
}
[[ $# -gt 0 ]] || usage
COMMAND=$1
shift
case "$COMMAND" in
  extract)
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == --allow-drop ) ]] || usage
    source "$ROOT/scripts/toolchain.sh"
    mkdir -p "$ROOT/build"
    STRINGS_WORK=$(mktemp -d "$ROOT/build/strings-extract.XXXXXX")
    trap 'rm -rf -- "$STRINGS_WORK"' EXIT
    mkdir "$STRINGS_WORK/data"
    # A fresh scratch directory is mandatory: incremental emission contains only
    # changed files. Building the executable also compiles all GitaCore and GitaUI sources.
    swift build --scratch-path "$STRINGS_WORK/build" --product Gita \
      -Xswiftc -emit-localized-strings \
      -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS_WORK/data"
    python3 "$ROOT/scripts/catalogs.py" merge "$STRINGS_WORK/data" "$@"
    ;;
  check)
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == --source ) ]] || usage
    python3 "$ROOT/scripts/catalogs.py" check "$@"
    ;;
  compile)
    [[ $# -eq 1 && -n "$1" ]] || usage
    python3 "$ROOT/scripts/catalogs.py" compile "$1"
    ;;
  *) usage ;;
esac
