#!/bin/bash
# Runs build-for-testing on the fixture (Fixtures/SampleApp).
#
#   scripts/build-fixture.sh                # original sources as is (baseline)
#   scripts/build-fixture.sh --instrumented # version with all mutants instrumented
#
# Artifacts are placed in .build/ inside the repository (the default ~/Library/Developer/Xcode/DerivedData is not used).
# No simulator is used (it builds for generic/platform=iOS Simulator).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="baseline"
if [[ "${1:-}" == "--instrumented" ]]; then MODE="instrumented"; fi

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
mkdir -p .build/logs

if [[ "$MODE" == "baseline" ]]; then
  PROJECT_DIR="Fixtures/SampleApp"
  DERIVED=".build/DerivedData"
else
  swift build --product xcmutate >/dev/null
  PROJECT_DIR=".build/fixture-instrumented"
  DERIVED=".build/DerivedData-instrumented"
  rm -rf "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
  rsync -a --exclude SampleApp.xcodeproj Fixtures/SampleApp/ "$PROJECT_DIR/"
  (
    cd "$PROJECT_DIR"
    find SampleApp Packages -name '*.swift' -not -name Package.swift | sort \
      | xargs "$ROOT/.build/debug/xcmutate" instrument --in-place --manifest "$ROOT/.build/logs/fixture-manifest.json"
  )
fi

(cd "$PROJECT_DIR" && "$XCODEGEN" generate --quiet)

LOG=".build/logs/$MODE-build.log"
set +e
xcodebuild build-for-testing \
  -project "$PROJECT_DIR/SampleApp.xcodeproj" \
  -scheme SampleApp \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES >"$LOG" 2>&1
STATUS=$?
set -e
if [[ $STATUS -ne 0 ]]; then
  grep -E "error:" "$LOG" | sort -u | head -20 >&2
  echo "build-for-testing failed ($MODE). log: $LOG" >&2
  exit $STATUS
fi
echo "build-for-testing succeeded ($MODE)"
echo "xctestrun: $(ls "$DERIVED"/Build/Products/*.xctestrun)"
