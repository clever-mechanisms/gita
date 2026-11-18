#!/bin/bash
# The local quality gate, run before every push (scripts/install-hooks.sh) and before a SonarQube scan.
# It mirrors the SonarQube quality gate, so a green run here should mean a green gate there:
#   format · lint · secrets · warnings-as-errors build · tests + coverage · complexity/Halstead/size/CRAP ·
#   dead code · duplication · string catalogs.
# Limits: cyclomatic < 15, cognitive < 22, Halstead difficulty < 80, lines of code per file < 500,
#         line coverage > 80%, CRAP < 25, dead code 0, duplicated code 0.
# Usage: scripts/quality.sh [--no-tests]   (--no-tests skips the test, coverage and CRAP steps)
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
export PYTHONDONTWRITEBYTECODE=1

RUN_TESTS=1
[[ "${1:-}" == --no-tests ]] && RUN_TESTS=0
OUT=build/quality
mkdir -p "$OUT"
FAILED=()

step() {
  local name=$1
  shift
  printf '\n\033[1m==> %s\033[0m\n' "$name"
  if "$@"; then printf '    ok\n'; else FAILED+=("$name"); printf '    FAILED: %s\n' "$name"; fi
}

require() {
  command -v "$1" >/dev/null || { printf 'missing tool: %s (%s)\n' "$1" "$2" >&2; exit 2; }
}
require swiftlint "brew install swiftlint"
require periphery "scripts/install-periphery.sh"
require npx "brew install node"

SWIFT_PATHS=(Package.swift Sources Tests Tools/QualityMetrics/Package.swift Tools/QualityMetrics/Sources
  Tools/QualityMetrics/Tests)

format_check() { swift format lint --strict --recursive --parallel "${SWIFT_PATHS[@]}"; }
lint() { swiftlint lint --strict --quiet; }
secrets() { python3 scripts/secret-scan.py; }
strings_check() { scripts/strings.sh check --source; }
script_tests() { python3 -m unittest discover -s scripts/tests 2>&1 | tail -3; [[ ${PIPESTATUS[0]} -eq 0 ]]; }

tests_with_coverage() {
  swift test --no-parallel --enable-code-coverage -Xswiftc -warnings-as-errors 2>&1 | tee "$OUT/test.log" | grep -E '✘|error:|Test run with' || true
  [[ ${PIPESTATUS[0]} -eq 0 ]] || return 1
  local bin profile objects=()
  bin=$(swift build --show-bin-path)
  profile=$(dirname "$(swift test --show-codecov-path)")/default.profdata
  for bundle in "$bin"/*.xctest; do
    objects+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
  done
  xcrun llvm-cov export -format=lcov -instr-profile "$profile" "${objects[@]}" \
    -ignore-filename-regex='(/Tests/|/\.build/|/Tools/)' >"$OUT/lcov.info"
}

build_only() { swift build --build-tests -Xswiftc -warnings-as-errors 2>&1 | grep -E 'error|warning:' ; [[ ${PIPESTATUS[0]} -eq 0 ]]; }

metrics() {
  swift build -c release --package-path Tools/QualityMetrics --product quality-metrics >/dev/null || return 1
  local tool=Tools/QualityMetrics/.build/release/quality-metrics coverage=()
  [[ $RUN_TESTS == 1 ]] && coverage=(--lcov "$OUT/lcov.info" --sonar-coverage "$OUT/sonar-coverage.xml")
  "$tool" --root "$PWD" --coverage-exclude /main.swift ${coverage[@]+"${coverage[@]}"} --sonar-issues "$OUT/sonar-issues.json" \
    Sources
}

# The metrics tool is its own package: it is measured against its own tests.
tool_metrics() {
  local package=Tools/QualityMetrics tool=Tools/QualityMetrics/.build/release/quality-metrics coverage=()
  if [[ $RUN_TESTS == 1 ]]; then
    swift test --package-path "$package" --enable-code-coverage 2>&1 | grep -E '✘|error:|Test run with' || true
    [[ ${PIPESTATUS[0]} -eq 0 ]] || return 1
    local bin profile objects=()
    bin=$(swift build --package-path "$package" --show-bin-path)
    profile=$(dirname "$(swift test --package-path "$package" --show-codecov-path)")/default.profdata
    for bundle in "$bin"/*.xctest; do
      objects+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
    done
    xcrun llvm-cov export -format=lcov -instr-profile "$profile" "${objects[@]}" \
      -ignore-filename-regex='(/Tests/|/\.build/)' >"$OUT/tool-lcov.info"
    coverage=(--lcov "$OUT/tool-lcov.info")
  fi
  "$tool" --root "$PWD" --coverage-exclude /main.swift ${coverage[@]+"${coverage[@]}"} "$package/Sources"
}

# Periphery needs an index store, which only SwiftPM's native build system writes; it builds in its own scratch
# directory so it never invalidates the main build. Test targets are excluded: code only tests use is dead.
# Codable properties are retained because removing a decoded field would loosen response validation.
dead_code() {
  swift build --build-system native --scratch-path .build/periphery --enable-index-store 2>&1 \
    | grep -E 'error:' ; [[ ${PIPESTATUS[0]} -eq 0 ]] || return 1
  periphery scan --skip-build --index-store-path .build/periphery/debug/index/store --exclude-tests \
    --retain-codable-properties --relative-results --strict --quiet --disable-update-check
}

duplication() { npx --yes jscpd@4.0.5 --config .jscpd.json; }

step "Format (swift format)" format_check
step "Lint (SwiftLint)" lint
step "Secrets and Keychain" secrets
step "String catalogs" strings_check
step "Script tests (catalog tooling)" script_tests
if [[ $RUN_TESTS == 1 ]]; then
  step "Build and test with coverage (warnings are errors)" tests_with_coverage
else
  step "Build (warnings are errors)" build_only
fi
step "Complexity, Halstead, file size, coverage and CRAP" metrics
step "Metrics tool: its own tests, coverage and CRAP" tool_metrics
step "Dead code (Periphery)" dead_code
step "Duplicated code (jscpd)" duplication

if ((${#FAILED[@]})); then
  printf '\n\033[31mQuality gate failed:\033[0m %s\n' "$(IFS=,; echo "${FAILED[*]}")"
  exit 1
fi
printf '\n\033[32mQuality gate passed.\033[0m\n'
