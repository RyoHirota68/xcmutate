#!/bin/bash
# Checks --time-limit and --max-mutants end to end on macOS, with the regression fixture Shapes (no simulator).
#
#   scripts/verify-time-limit.sh
#
# 1. A full run (it also warms the work directory, so that the later runs take about equally long before the first
#    mutant). Its report is the reference and the baseline report of the gate below.
# 2. A full run again, with a clock: how long until the first mutant has a result, how long in all.
# 3. A run with --time-limit set to the middle of the mutant phase and a gate that the results cannot fail
#    (--baseline-report with the reference): it must stop early, report what it has, list the rest as not run,
#    and exit with 7 (the gate cannot be confirmed).
# 4. The same limit without a gate: exit code 0.
# 5. --resume without the limit: the rest is run, and every verdict equals the reference.
# 6. --max-mutants 5, twice: five mutants, the same five both times.
# 7. The report of the sample, and the report that the limit cut short, as --baseline-report of a full run: the
#    mutants that they did not examine are not counted as new gaps (exit code 0, not 5).
# 8. A run and a --resume with a work directory under /private/tmp that does not exist before the first run.
# 9. --resume of a run with narrowed tests in shared processes runs nothing again.
# 10. A run with suites that need other suites, cut short at five moments and resumed: the verdicts of a run that
#     was not cut short.
#
# Reports and logs go to .build/time-limit/.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="${XCMUTATE_BIN:-}"
OUT="$REPO/.build/time-limit"
if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  BIN="$REPO/.build/debug/xcmutate"
fi
mkdir -p "$OUT"
failures=0
check() { if "$@"; then echo "  ok: $CHECK"; else echo "  FAILED: $CHECK"; failures=$((failures + 1)); fi; }

# run <label> [options...]: one run of the fixture; the exit status is in $status, the seconds until the first
# result and until the end in $first and $total
run() {
  local label="$1"
  shift
  local started
  started=$(date +%s)
  first=""
  (cd "$REPO/Fixtures/Regression/${FIXTURE:-Shapes}" && "$BIN" run --root . --package . --scheme "${FIXTURE:-Shapes}" --destination 'platform=macOS' \
      --no-caffeinate --work-dir "$OUT/work" --reporter json --json-output "$OUT/$label.json" "$@" 2>&1; echo "exit=$?") >"$OUT/$label.log" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ -z "$first" ] && grep -q '\[1/' "$OUT/$label.log" 2>/dev/null; then first=$(( $(date +%s) - started )); fi
    sleep 1
  done
  wait "$pid"
  total=$(( $(date +%s) - started ))
  status=$(sed -n 's/^exit=//p' "$OUT/$label.log" | tail -1)
}
field() { /usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

echo "== 1. the reference"
run reference
CHECK="the full run finishes"
check test "$status" = 0
echo "== 2. a full run with a clock"
run timed
CHECK="the full run finishes again"
check test "$status" = 0 -a -n "$first"
[ -n "$first" ] || { echo "no mutant was run; see $OUT/timed.log"; exit 1; }
limit=$(( first + (total - first) / 2 ))
echo "  first result after ${first}s, end after ${total}s: the limit is ${limit}s"

echo "== 3. --time-limit ${limit}s with a gate that the results do not fail"
run limited --time-limit "${limit}s" --baseline-report "$OUT/reference.json"
CHECK="exit code 7: the gate cannot be confirmed"
check test "$status" = 7
CHECK="the message of the gate names the mutants that were not run before the limit"
check grep -q "were not run before the time limit" "$OUT/limited.log"
CHECK="the report says that the time limit was reached and lists the mutants that were not run"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get(\"timeLimitReached\"), r[\"interrupted\"], len(r[\"pendingKeys\"]) > 0, any(w[\"kind\"] == \"timeLimit\" for w in r[\"warnings\"]))' '$OUT/limited.json')\" = 'True True True True' ]"
CHECK="it has results, and results and mutants not run together are the mutants of the reference"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); f=json.load(open(sys.argv[2])); done={x[\"mutant\"][\"key\"] for x in r[\"results\"]}; print(len(done) > 0 and done | set(r[\"pendingKeys\"]) == {x[\"mutant\"][\"key\"] for x in f[\"results\"]} and not (done & set(r[\"pendingKeys\"])))' '$OUT/limited.json' '$OUT/reference.json')\" = True ]"
CHECK="the run ended near the limit (within 30 s after it)"
check test "$total" -le $(( limit + 30 ))

echo "== 4. the same limit without a gate"
run limited-no-gate --time-limit "${limit}s"
CHECK="exit code 0: the limit is a budget, not a failure"
check test "$status" = 0
CHECK="the text of the run says that the limit was reached"
check grep -q "the time limit (--time-limit ${limit}s) is reached" "$OUT/limited-no-gate.log"

echo "== 5. --resume without the limit"
run resumed --resume
CHECK="the resumed run finishes"
check test "$status" = 0
CHECK="it took results over and did not report a limit"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r[\"resumedCount\"] > 0, r.get(\"timeLimitReached\"), r[\"interrupted\"])' '$OUT/resumed.json')\" = 'True None False' ]"
CHECK="every verdict equals the reference"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; s=lambda p: sorted((x[\"mutant\"][\"key\"], x[\"status\"]) for x in json.load(open(p))[\"results\"]); print(s(sys.argv[1]) == s(sys.argv[2]))' '$OUT/resumed.json' '$OUT/reference.json')\" = True ]"

echo "== 6. --max-mutants 5"
run sample-1 --max-mutants 5
CHECK="five mutants, and the report says how many there were"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); f=json.load(open(sys.argv[2])); print(len(r[\"results\"]), r[\"sampling\"][\"limit\"], r[\"sampling\"][\"candidates\"] == len(f[\"results\"]), any(w[\"kind\"] == \"sampled\" for w in r[\"warnings\"]))' '$OUT/sample-1.json' '$OUT/reference.json')\" = '5 5 True True' ]"
run sample-2 --max-mutants 5
CHECK="the same five in a second run, with the verdicts of the reference"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; s=lambda p: sorted((x[\"mutant\"][\"key\"], x[\"status\"]) for x in json.load(open(p))[\"results\"]); print(s(sys.argv[1]) == s(sys.argv[2]) and set(s(sys.argv[1])) <= set(s(sys.argv[3])))' '$OUT/sample-1.json' '$OUT/sample-2.json' '$OUT/reference.json')\" = True ]"

echo "== 7. the report of the sample as --baseline-report of a full run"
run full-vs-sample --baseline-report "$OUT/sample-1.json"
CHECK="exit code 0: the mutants that the sample left out are not new gaps"
check test "$status" = 0
CHECK="the run says how many mutants the baseline does not know"
check grep -q "the report does not know the state of [0-9]* mutants (not run, left out of a sample" "$OUT/full-vs-sample.log"
run full-vs-limited --baseline-report "$OUT/limited-no-gate.json"
CHECK="the same with the report that the time limit cut short as baseline: exit code 0"
check test "$status" = 0

echo "== 8. --resume with a work directory under /private/tmp that the first run creates"
# CI runners use temporary directories. /private/tmp/x and /tmp/x are one directory, and the path used to be
# spelled differently once x existed, which --resume took for changed options.
FRESH="/private/tmp/xcmutate-verify-time-limit-$$"
run fresh --work-dir "$FRESH/work"
CHECK="the run in the new directory finishes"
check test "$status" = 0
run fresh-resume --resume --work-dir "$FRESH/work"
CHECK="--resume in the same directory is accepted and takes the results over"
check bash -c "[ '$status' = 0 ] && [ \"\$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r[\"resumedCount\"] > 0)' '$OUT/fresh-resume.json')\" = True ]"
"$BIN" clean --work-dir "$FRESH/work" >/dev/null 2>&1 || true
rmdir "$FRESH" 2>/dev/null || true

echo "== 9. --resume of a run with narrowed tests in shared processes"
# What a shared process killed with narrowed tests was run again by --resume: at the start of a run it is not known
# yet which mutants may be narrowed, and the observation was compared with the number of all tests.
run narrowed --select-tests reach --shared-process
CHECK="the run with --select-tests reach --shared-process finishes"
check test "$status" = 0
run narrowed-resume --select-tests reach --shared-process --resume
CHECK="--resume takes every result over and runs no mutant again, with the same verdicts"
check bash -c "[ '$status' = 0 ] && [ \"\$(/usr/bin/python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); s=lambda r: sorted((x[\"mutant\"][\"key\"], x[\"status\"]) for x in r[\"results\"]); print(b[\"durations\"][\"executedMutants\"], s(a) == s(b), b[\"resumedCount\"] > 0)' '$OUT/narrowed.json' '$OUT/narrowed-resume.json')\" = '0 True True' ]"

echo "== 10. a run that is cut short at several moments, and --resume: the verdicts of a run that was not cut short"
# A failure of narrowed tests used to be written to the journal before the check that decides whether it is a
# detection (do the suites pass by themselves?). Cut short in between and resumed, the run reported Killed for a
# mutant that survives. DependentSuites has such suites; the moments are spread over the mutant phase.
"$BIN" clean --work-dir "$OUT/work" >/dev/null 2>&1 || true
FIXTURE=DependentSuites
run dep-reference --select-tests reach
CHECK="the reference run of DependentSuites finishes"
check test "$status" = 0 -a -n "$first"
if [ -n "$first" ]; then
  # (run sets $first and $total again: keep those of the reference)
  begin=$first
  span=$(( total - first ))
  for part in 1 2 3 4 5; do
    limit=$(( begin + span * part / 6 ))
    run "dep-limit-$part" --select-tests reach --time-limit "${limit}s"
    run "dep-resume-$part" --select-tests reach --resume
    CHECK="cut short after ${limit}s and resumed: the same verdicts as the reference"
    check bash -c "[ '$status' = 0 ] && [ \"\$(/usr/bin/python3 -c 'import json,sys; s=lambda p: sorted((x[\"mutant\"][\"key\"], x[\"status\"]) for x in json.load(open(p))[\"results\"]); print(s(sys.argv[1]) == s(sys.argv[2]))' '$OUT/dep-resume-$part.json' '$OUT/dep-reference.json')\" = True ]"
  done
fi
unset FIXTURE

"$BIN" clean --work-dir "$OUT/work" >/dev/null 2>&1 || true
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed (logs: $OUT)"
  exit 1
fi
echo "all checks of --time-limit and --max-mutants passed"
