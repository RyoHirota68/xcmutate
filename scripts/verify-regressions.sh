#!/bin/bash
# Runs the regression fixtures (Fixtures/Regression) on macOS and compares the verdicts with their expected.json.
# They are the reproductions of wrong results found by the reviews of the tool (docs/verification.md).
# No simulator is used.
#
#   scripts/verify-regressions.sh              # all fixtures
#   scripts/verify-regressions.sh StateLeak    # one of them
#
# Work directories and reports go to .build/regression (removed with `xcmutate clean --work-dir` at the end).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="${XCMUTATE_BIN:-}"
OUT="$REPO/.build/regression"
ONLY="${1:-}"

if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  BIN="$REPO/.build/debug/xcmutate"
fi
mkdir -p "$OUT"
failures=0

# run <fixture> <label> <scheme> [options...]: one run of a fixture, checked against its expected.json
# (or against the file named in EXPECTED, for a mode whose verdicts are known to differ)
EXPECTED=expected.json
run() {
  local fixture="$1" label="$2" scheme="$3"
  shift 3
  if [ -n "$ONLY" ] && [ "$ONLY" != "$fixture" ]; then return; fi
  local work="$OUT/work-$fixture" report="$OUT/$fixture-$label.json" log="$OUT/$fixture-$label.log"
  (cd "$REPO/Fixtures/Regression/$fixture" && "$BIN" run --root . --package . --scheme "$scheme" --destination 'platform=macOS' \
      --no-caffeinate --work-dir "$work" --reporter json --json-output "$report" "$@") >"$log" 2>&1
  local status=$?
  local expected="$REPO/Fixtures/Regression/$fixture/$EXPECTED"
  local wanted
  wanted=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("exitStatus", 0))' "$expected")
  if [ "$status" != "$wanted" ]; then
    echo "$fixture ($label): FAILED: exit status $status, expected $wanted (log: $log)"
    failures=$((failures + 1))
    return
  fi
  if ! python3 scripts/check-regression.py "$report" "$expected" --label "$fixture ($label)"; then
    echo "  log: $log"
    failures=$((failures + 1))
  fi
}

# A file that an interrupted earlier run of the fixture's tests may have left behind
rm -f "${TMPDIR:-/tmp}/xcmutate-regression-state-leak.log" "${TMPDIR:-/tmp}/xcmutate-regression-shared.lock"

# State left behind by one mutant's run must not kill the next mutant
run StateLeak one-process-per-mutant StateLeak
run StateLeak shared-process StateLeak --shared-process
run StateLeak shared-process-to-the-end StateLeak --shared-process --no-stop-at-first-failure
# --confirm-kills restore needs an iOS simulator: on macOS the runs without mutants are made as with auto, same verdicts
run StateLeak restore-on-macos StateLeak --confirm-kills restore
# State left in a shared process by a mutant whose tests pass; workers that share the Mac
run SharedState one-process-per-mutant SharedState --skip-testing SharedStateTests/LockTests
run SharedState shared-process SharedState --skip-testing SharedStateTests/LockTests --shared-process
run SharedState workers SharedState --workers 3
run SharedState shared-process-workers SharedState --shared-process --workers 2

# Code that was dropped from the run, or that stopped it
run Shapes one-process-per-mutant Shapes --fail-under 50
run Shapes shared-process Shapes --shared-process --fail-under 50

# The mutant's effect reaches a test of another suite through state that a test leaves in the process: what
# --select-tests reach assumes away. Run against every test it is Killed; narrowed (one test evaluates the switch,
# which is narrowed only with --shared-process) it passes its own suite; by default it is then run against every test
# and Killed. With --no-recheck-survivors it is reported as Survived, marked as not run against all tests.
run StateAcrossSuites one-process-per-mutant StateAcrossSuites
run StateAcrossSuites reach StateAcrossSuites --select-tests reach
run StateAcrossSuites reach-shared StateAcrossSuites --select-tests reach --shared-process
run StateAcrossSuites reach-shared-trusted StateAcrossSuites --select-tests reach --shared-process --trust-shared-survivors
run StateAcrossSuites reach-shared-xcodebuild StateAcrossSuites --select-tests reach --shared-process --no-direct-launch
run StateAcrossSuites reach-shared-wide-gate StateAcrossSuites --select-tests reach --shared-process --no-narrow-gate
EXPECTED=expected-narrowed.json
run StateAcrossSuites reach-shared-no-recheck StateAcrossSuites --select-tests reach --shared-process --no-recheck-survivors
EXPECTED=expected.json

# A suite that needs what another suite leaves in the process: it passes in a run of all tests and fails by itself.
# Narrowed to it, a failure is not a detection.
run DependentSuites reach DependentSuites --select-tests reach
run DependentSuites reach-shared-no-recheck DependentSuites --select-tests reach --shared-process --no-recheck-survivors
run DependentSuites reach-shared-xcodebuild-no-recheck DependentSuites --select-tests reach --shared-process --no-direct-launch --no-recheck-survivors
EXPECTED=expected-shared.json
run DependentSuites reach-shared DependentSuites --select-tests reach --shared-process
run DependentSuites one-process-per-mutant DependentSuites
EXPECTED=expected.json

# What a mutant's run leaves behind is removed by another suite only: the suites of the next mutant fail by themselves
# until every test has been run once.
rm -f "${TMPDIR:-/tmp/}xcmutate-regression-leftover-elsewhere.marker" "${TMPDIR:-/tmp}/xcmutate-regression-leftover-elsewhere.marker"
run LeftoverElsewhere one-process-per-mutant LeftoverElsewhere
run LeftoverElsewhere reach LeftoverElsewhere --select-tests reach
run LeftoverElsewhere reach-shared LeftoverElsewhere --select-tests reach --shared-process
run LeftoverElsewhere restore-on-macos LeftoverElsewhere --confirm-kills restore
EXPECTED=expected-no-recheck.json
run LeftoverElsewhere reach-shared-xcodebuild-no-recheck LeftoverElsewhere --select-tests reach --shared-process --no-direct-launch --no-recheck-survivors
EXPECTED=expected.json

# What another suite leaves in the process hides a mutant's effect: the suite that reaches the mutant fails by itself
# and passes in a run of all tests. A detection by narrowed tests is marked, and --confirm-kills full asks every test
run HiddenByOtherSuite one-process-per-mutant HiddenByOtherSuite
run HiddenByOtherSuite reach-shared HiddenByOtherSuite --select-tests reach --shared-process
run HiddenByOtherSuite reach-full HiddenByOtherSuite --select-tests reach --confirm-kills full
run HiddenByOtherSuite reach-shared-full HiddenByOtherSuite --select-tests reach --shared-process --confirm-kills full
run HiddenByOtherSuite reach-shared-wide-gate HiddenByOtherSuite --select-tests reach --shared-process --no-narrow-gate
EXPECTED=expected-narrowed.json
run HiddenByOtherSuite reach HiddenByOtherSuite --select-tests reach
EXPECTED=expected.json

# A suite outside the suites of every mutant changes, once per process, how often their switches are evaluated. The
# second run without mutants at the start of a shared process runs only the mutants' suites (unless --no-narrow-gate):
# the switches are then evaluated unequally often in the two runs, and their mutants go to a process of their own.
run OnceOutsideGate one-process-per-mutant OnceOutsideGate
run OnceOutsideGate reach OnceOutsideGate --select-tests reach
run OnceOutsideGate reach-shared-to-the-end OnceOutsideGate --select-tests reach --shared-process --no-stop-at-first-failure
# The mutants that go back to run alone against all tests are run by the driver and stopped at their first failing
# test (in a host started by the tool, and under xcodebuild)
EXPECTED=expected-stopped.json
run OnceOutsideGate reach-shared OnceOutsideGate --select-tests reach --shared-process
run OnceOutsideGate reach-shared-xcodebuild OnceOutsideGate --select-tests reach --shared-process --no-direct-launch
run OnceOutsideGate reach-shared-wide-gate OnceOutsideGate --select-tests reach --shared-process --no-narrow-gate
EXPECTED=expected.json

for fixture in StateLeak SharedState Shapes StateAcrossSuites DependentSuites LeftoverElsewhere HiddenByOtherSuite OnceOutsideGate; do
  if [ -z "$ONLY" ] || [ "$ONLY" = "$fixture" ]; then "$BIN" clean --work-dir "$OUT/work-$fixture" >/dev/null 2>&1 || true; fi
done
if [ "$failures" -gt 0 ]; then
  echo "$failures regression check(s) failed"
  exit 1
fi
echo "all regression checks passed"
