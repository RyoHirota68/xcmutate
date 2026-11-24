#!/bin/bash
# Runs all mutants of the fixture (Fixtures/SampleApp) with `xcmutate run` and
# compares the results against Fixtures/SampleApp/expected.json.
#
#   scripts/verify-fixture.sh <SIMULATOR-UDID> [additional run arguments...]
#
# The caller prepares the simulator (this script neither creates a simulator nor manages its boot).
# Artifacts are placed in .build/ (work copy: .build/mutator-work, report: .build/fixture-report.json); set
# FIXTURE_WORK and FIXTURE_REPORT to other paths to run two of these at the same time on two simulators.
# Set XCMUTATE_BIN to use an executable that is already built (a copy, so that a build during a long run
# does not replace the running one); otherwise the script builds and uses .build/debug/xcmutate.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <SIMULATOR-UDID> [run options...]" >&2
  exit 64
fi
UDID="$1"
shift

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
REPORT="${FIXTURE_REPORT:-.build/fixture-report.json}"
WORK="${FIXTURE_WORK:-.build/mutator-work}"

BIN="${XCMUTATE_BIN:-}"
if [[ -z "$BIN" ]]; then
  swift build --product xcmutate >/dev/null
  BIN=".build/debug/xcmutate"
fi

START=$(date +%s)
set +e
"$BIN" run \
  --root Fixtures/SampleApp \
  --project Fixtures/SampleApp/SampleApp.xcodeproj \
  --scheme SampleApp \
  --destination "id=$UDID" \
  --only-testing SampleAppTests \
  --prepare "'$XCODEGEN' generate --quiet" \
  --work-dir "$WORK" \
  --reporter text --reporter json --json-output "$REPORT" \
  "$@"
STATUS=$?
set -e
echo "run finished with status $STATUS in $(( $(date +%s) - START ))s"
if [[ $STATUS -ne 0 ]]; then exit $STATUS; fi

python3 scripts/compare-fixture.py "$REPORT" Fixtures/SampleApp
