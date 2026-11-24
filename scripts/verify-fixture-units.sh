#!/bin/bash
# Runs the cases of the fixture that need several test-plan configurations and several unit-test targets
# (Fixtures/SampleApp/SampleApp/Units/UnitCases.swift, scheme SampleAppUnits, test plan Units.xctestplan:
# configurations Japanese and English, targets SampleAppUnitATests and SampleAppUnitBTests) and compares the
# results against the `unitsExpected` fields of Fixtures/SampleApp/expected.json.
#
#   scripts/verify-fixture-units.sh <SIMULATOR-UDID> [additional run arguments...]
#
# Run it once without arguments and once with --shared-process, then compare the two reports:
#   scripts/verify-fixture-units.sh <UDID>
#   UNITS_REPORT=.build/fixture-units-shared.json scripts/verify-fixture-units.sh <UDID> --shared-process
#   scripts/compare-reports.py .build/fixture-units-report.json .build/fixture-units-shared.json
#
# The caller prepares the simulator (boot it first). Artifacts are placed in .build/.
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
REPORT="${UNITS_REPORT:-.build/fixture-units-report.json}"

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
  --scheme SampleAppUnits \
  --destination "id=$UDID" \
  --prepare "'$XCODEGEN' generate --quiet" \
  --work-dir .build/mutator-work-units \
  --reporter text --reporter json --json-output "$REPORT" \
  "$@" \
  Fixtures/SampleApp/SampleApp/Units/UnitCases.swift
STATUS=$?
set -e
echo "run finished with status $STATUS in $(( $(date +%s) - START ))s"
if [[ $STATUS -ne 0 ]]; then exit $STATUS; fi

python3 scripts/compare-fixture.py "$REPORT" Fixtures/SampleApp --units
