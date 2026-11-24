#!/bin/bash
# Checks `--reuse`: a run that takes over results must give the same verdict for every mutant as a full run of
# the same state. Run on a copy of Fixtures/LogicKit (a Swift package, on macOS; no simulator) and, when a simulator
# is given, also on a copy of Fixtures/SampleApp (app-hosted tests; one source file, with --shared-process).
#
#   scripts/verify-reuse.sh [<SIMULATOR-UDID>]
#
# States, each run once with --reuse and once without, and compared with scripts/compare-reports.py:
#   1. nothing changed since the run that stored the results   → every Killed is taken over
#   2. a test file was added (it kills mutants that survived)   → every Killed is taken over, the survivors are run
#   3. an existing test file was changed (a test was removed)   → mutants killed by tests of that file are run again
#   4. product code was changed (a function was added)          → nothing is taken over
#
# The copies live in .build/reuse-check (git repositories of their own); nothing in Fixtures/ is modified.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${XCMUTATE_BIN:-}"
if [[ -z "$BIN" ]]; then
  swift build --product xcmutate >/dev/null
  BIN="$ROOT/.build/debug/xcmutate"
fi
CHECK="$ROOT/.build/reuse-check"
UDID="${1:-}"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
rm -rf "$CHECK"
mkdir -p "$CHECK/reports"
FAILED=0
PROJECT=""
RUN_ARGS=()

copy() { # fixture directory name
  PROJECT="$1"
  cp -R "$ROOT/Fixtures/$1" "$CHECK/$1"
  rm -rf "$CHECK/$1/SampleApp.xcodeproj"
  cd "$CHECK/$1"
  git init -q
  git add -A
  git -c user.name=check -c user.email=check@example.invalid commit -qm "$1"
}
run() { # report name, extra arguments...
  local name="$PROJECT-$1"
  shift
  "$BIN" run --root . "${RUN_ARGS[@]}" --shared-process \
    --reporter json --json-output "$CHECK/reports/$name.json" "$@" > "$CHECK/reports/$name.log" 2>&1 || { echo "run $name failed; see $CHECK/reports/$name.log" >&2; exit 1; }
}
reused() { python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print((r.get('reuse') or {}).get('reusedCount', 0))" "$CHECK/reports/$PROJECT-$1.json"; }
killed() { python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(r['counts'].get('Killed', 0))" "$CHECK/reports/$PROJECT-$1.json"; }
check() { # state, expected number of results taken over: all | some | none | <n>
  local state="$1" expected="$2"
  run "$state-full" --work-dir "$CHECK/work-$PROJECT-full"
  run "$state-reuse" --work-dir "$CHECK/work-$PROJECT-reuse" --reuse
  local count; count=$(reused "$state-reuse")
  local same=ok
  python3 "$ROOT/scripts/compare-reports.py" "$CHECK/reports/$PROJECT-$state-full.json" "$CHECK/reports/$PROJECT-$state-reuse.json" > "$CHECK/reports/$PROJECT-$state-compare.txt" || same=DIFFERENT
  local counted=ok
  case "$expected" in
    none) [[ "$count" -eq 0 ]] || counted="expected none" ;;
    some) [[ "$count" -gt 0 && "$count" -lt "$(killed "$state-full")" ]] || counted="expected some but not all" ;;
    all) [[ "$count" -eq "$(killed "$state-full")" ]] || counted="expected every Killed" ;;
    *) [[ "$count" -eq "$expected" ]] || counted="expected $expected" ;;
  esac
  echo "$PROJECT $state: $(grep -m1 'have the same verdict' "$CHECK/reports/$PROJECT-$state-compare.txt") [$same]; Killed $(killed "$state-full"), taken over $count [$counted]"
  [[ "$same" == ok && "$counted" == ok ]] || FAILED=1
}
store() { # the run that stores the results (nothing to take over yet)
  run "0-store" --work-dir "$CHECK/work-$PROJECT-reuse" --reuse
  STORED=$(killed "0-store")
  echo "$PROJECT 0-store: Killed $STORED, taken over $(reused 0-store)"
}
finish() {
  "$BIN" clean --work-dir "$CHECK/work-$PROJECT-full" >/dev/null 2>&1 || true
  "$BIN" clean --work-dir "$CHECK/work-$PROJECT-reuse" >/dev/null 2>&1 || true
}

# --- LogicKit: a package, on macOS
copy LogicKit
RUN_ARGS=(--package . --scheme LogicKit --destination 'platform=macOS')
store
check "1-unchanged" all

cat > Tests/LogicKitTests/ShippingBoundaryTests.swift <<'SWIFT'
import LogicKit
import Testing

@Suite struct ShippingBoundaryTests {
    @Test func freeFromThreeThousandAndForEmptyOrders() {
        #expect(Pricing.shipping(for: 3_000, itemCount: 1) == 0)
        #expect(Pricing.shipping(for: 2_999, itemCount: 1) == 500)
        #expect(Pricing.shipping(for: 100, itemCount: 0) == 0)
    }
}
SWIFT
check "2-test-file-added" "$STORED"

# Remove one test from the existing test file: mutants that only it killed must come out as survivors
python3 - <<'PY'
p = "Tests/LogicKitTests/PricingTests.swift"
s = open(p).read()
start = s.index("    func testLinesWithoutQuantityAreIgnored()")
end = s.index("    func testTaxCountsTaxableLinesOnly()")
open(p, "w").write(s[:start] + s[end:])
PY
check "3-test-file-changed" some

cat >> Sources/LogicKit/Pricing.swift <<'SWIFT'

extension Pricing {
    public static func isFree(_ amount: Int) -> Bool { amount == 0 }
}
SWIFT
check "4-product-changed" none
finish

# --- SampleApp: app-hosted tests on a simulator, one source file
if [[ -n "$UDID" ]]; then
  copy SampleApp
  RUN_ARGS=(--project SampleApp.xcodeproj --scheme SampleApp --destination "id=$UDID" --only-testing SampleAppTests
            --prepare "'$XCODEGEN' generate --quiet" SampleApp/Operators/OperatorCases.swift)
  store
  check "1-unchanged" all

  cat > SampleAppTests/ReuseAddedTests.swift <<'SWIFT'
import Testing
@testable import SampleApp

@MainActor
@Suite struct ReuseAddedTests {
    @Test func unlinkedMasterHasNoVariant() {
        #expect(NewOperators.variantSetting(masterId: nil, settings: [:]) == .noVariant)
    }
}
SWIFT
  check "2-test-file-added" "$STORED"

  python3 - <<'PY'
p = "SampleAppTests/NewOperatorTests.swift"
s = open(p).read()
start = s.index("    @Test func o2CombineTested()")
end = s.index("    @Test func o3Conditions()")
open(p, "w").write(s[:start] + s[end:])
PY
  check "3-test-file-changed" some

  cat >> SampleApp/Operators/OperatorCases.swift <<'SWIFT'

extension NewOperators {
    static func isBlank(_ text: String) -> Bool { text.isEmpty }
}
SWIFT
  check "4-product-changed" none
  finish
fi

if [[ $FAILED -ne 0 ]]; then
  echo "verify-reuse: FAILED (reports in $CHECK/reports)"
  exit 1
fi
echo "verify-reuse: every state gave the same verdicts with and without --reuse"
