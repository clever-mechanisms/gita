#!/bin/bash
# Runs the local quality gate's analyses and uploads them to SonarQube.
# Credentials come from the untracked .sonar.txt (SONAR_URL, SONAR_PROJECT_ID, SONAR_API_TOKEN) or the environment
# (SONAR_HOST_URL, SONAR_PROJECT_KEY, SONAR_TOKEN). The token is passed through the environment, never the command line.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
if [[ -f .sonar.txt ]]; then
  # shellcheck disable=SC1091
  source .sonar.txt
fi
export SONAR_HOST_URL=${SONAR_HOST_URL:-${SONAR_URL:?set SONAR_URL in .sonar.txt}}
export SONAR_TOKEN=${SONAR_TOKEN:-${SONAR_API_TOKEN:?set SONAR_API_TOKEN in .sonar.txt}}
PROJECT_KEY=${SONAR_PROJECT_KEY:-${SONAR_PROJECT_ID:?set SONAR_PROJECT_ID in .sonar.txt}}
command -v sonar-scanner >/dev/null || { echo "missing sonar-scanner (brew install sonar-scanner)" >&2; exit 2; }

OUT=build/quality
# The gate writes sonar-issues.json, sonar-coverage.xml, lcov.info and the jscpd report; its result is reported by
# SonarQube too, so a failing gate still uploads.
scripts/quality.sh "$@" || echo "Local gate failed; uploading the analysis anyway."
swiftlint lint --quiet --reporter json >"$OUT/swiftlint.json" || true
periphery scan --skip-build --index-store-path .build/periphery/debug/index/store --exclude-tests \
  --retain-codable-properties --relative-results --quiet --disable-update-check --format json \
  >"$OUT/periphery.json" || true
python3 scripts/sonar-reports.py "$OUT/swiftlint.json" "$OUT/periphery.json" "$OUT/jscpd/jscpd-report.json" \
  "$OUT/sonar-external.json"

REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
sonar-scanner -Dsonar.projectKey="$PROJECT_KEY" -Dsonar.projectVersion="$REVISION" -Dsonar.qualitygate.wait=true
