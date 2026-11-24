#!/bin/bash
# Runs the guard cases (Fixtures/GuardCases) on an iOS simulator, in every way of running, and compares the verdicts
# with the expected-*.json files there. The cases are shapes that once gave
# wrong verdicts, placed so that they are run alone while shared processes are paused (after
# a row of mutants that crash the host): suites that need another suite, state that hides a mutant, a test that
# does not end.
#
#   scripts/verify-fixture-guards.sh <SIMULATOR-UDID> [mode...]
#
# Modes (default: the first seven): default shared reach reach-shared reach-shared-xcodebuild reach-full
# reach-shared-full, and three that are run only when named:
#   blind-default, blind-reach-shared   as if no output of the baseline had shown when its tests start: without
#                narrowing the run must warn that two limits are not in use; with it the times must come from the
#                result bundle
#   end-once     (reach + shared process) the test GuardZEndOnceTests ends its process in its GUARD_END_AFTER-th run
#                (default 1000: never, which only counts the runs); the verdicts must not change, and what a process
#                started by the tool left is listed (logs/direct-*)
# The copy of the fixture goes to $GUARD_FIXTURE (default: a new directory under $TMPDIR), reports and logs to
# .build/guards/. Set XCMUTATE_BIN to use an executable that is already built.
set -uo pipefail
if [[ $# -lt 1 ]]; then
  sed -n '2,12p' "$0" >&2
  exit 64
fi
UDID="$1"
shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
BIN="${XCMUTATE_BIN:-}"
if [[ -z "$BIN" ]]; then
  swift build --product xcmutate >/dev/null || exit 1
  BIN="$ROOT/.build/debug/xcmutate"
fi
OUT="$ROOT/.build/guards"
mkdir -p "$OUT"
FIXTURE="${GUARD_FIXTURE:-}"
if [[ -z "$FIXTURE" ]]; then
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/xcmutate-guard-fixture.XXXXXX")"
  rmdir "$FIXTURE"
  scripts/make-guard-fixture.sh "$FIXTURE" >/dev/null || exit 1
fi
MODES=("$@")
if [[ ${#MODES[@]} -eq 0 ]]; then MODES=(default shared reach reach-shared reach-shared-xcodebuild reach-full reach-shared-full); fi

failures=0
COUNTER="$FIXTURE.end-once"
for mode in "${MODES[@]}"; do
  blind=""
  limits="in use"
  rm -f "$COUNTER"
  case "$mode" in
    blind-default) options=(); expected=expected-blind.json; blind=1; limits="not in use" ;;
    blind-reach-shared) options=(--select-tests reach --shared-process); expected=expected-narrowed.json; blind=1 ;;
    end-once) options=(--select-tests reach --shared-process); expected=expected-narrowed.json; echo "${GUARD_END_AFTER:-1000}" > "$COUNTER" ;;
    default) options=(); expected=expected-all-tests.json ;;
    shared) options=(--shared-process); expected=expected-all-tests.json ;;
    reach) options=(--select-tests reach); expected=expected-narrowed.json ;;
    reach-shared) options=(--select-tests reach --shared-process); expected=expected-narrowed.json ;;
    reach-shared-xcodebuild) options=(--select-tests reach --shared-process --no-direct-launch); expected=expected-narrowed.json ;;
    reach-full) options=(--select-tests reach --confirm-kills full); expected=expected-all-tests.json ;;
    reach-shared-full) options=(--select-tests reach --shared-process --confirm-kills full); expected=expected-all-tests.json ;;
    *) echo "unknown mode $mode" >&2; exit 64 ;;
  esac
  START=$(date +%s)
  (cd "$FIXTURE" && env ${blind:+XCMUTATE_IGNORE_BASELINE_TEST_LINES=1} "$BIN" run --root . --project SampleApp.xcodeproj --scheme SampleApp --destination "id=$UDID" \
      --only-testing SampleAppTests --prepare "'$XCODEGEN' generate --quiet" --work-dir "$OUT/work" --no-caffeinate \
      --reporter text --report "json:$OUT/$mode.json" ${options[@]+"${options[@]}"} SampleApp/Guards/GuardCases.swift) >"$OUT/$mode.log" 2>&1
  status=$?
  echo "$mode: exit status $status after $(( $(date +%s) - START ))s"
  # The limits inside a run must be in use (the run says so; without them it warns), also though the app reaches a
  # mutated function while it starts
  if [[ "$limits" == "in use" ]] && ! grep -q "timeouts: [0-9]* s until the first test starts" "$OUT/$mode.log"; then
    echo "guards ($mode): FAILED: the run does not say that the limits inside a run are in use"
    grep "warning: The limit" "$OUT/$mode.log" | cut -c1-300
    status=1
  fi
  if [[ "$limits" == "not in use" ]] && ! grep -q "warning: The limit until the first test and the limit for one test are not in use" "$OUT/$mode.log"; then
    echo "guards ($mode): FAILED: the run does not warn that the limits inside a run are not in use"
    status=1
  fi
  grep "timeouts: [0-9]* s until the first test starts" "$OUT/$mode.log" | cut -c1-260 | sed 's/^/  /'
  if [[ "$mode" == end-once ]]; then
    echo "  runs of the test that ends its process when asked: $(( ${GUARD_END_AFTER:-1000} - $(cat "$COUNTER" 2>/dev/null || echo 0) )) (asked to end in run ${GUARD_END_AFTER:-1000})"
    echo "  kept from processes started by the tool: $(ls "$OUT/work/logs" 2>/dev/null | grep '^direct-' | tr '\n' ' ')"
    grep "ended without a result" "$OUT/$mode.log" | cut -c1-400 | sed 's/^/  /'
    rm -rf "$OUT/end-once-logs"; mkdir -p "$OUT/end-once-logs"
    for kept in "$OUT/work/logs"/direct-*; do [[ -d "$kept" ]] && cp -R "$kept" "$OUT/end-once-logs/"; done
    rm -f "$COUNTER"
  fi
  if [[ "$status" != 0 ]] || ! python3 scripts/check-regression.py "$OUT/$mode.json" "Fixtures/GuardCases/$expected" --label "guards ($mode)"; then
    echo "  log: $OUT/$mode.log"
    failures=$((failures + 1))
  fi
done
"$BIN" clean --work-dir "$OUT/work" >/dev/null 2>&1 || true
if [[ "$failures" -gt 0 ]]; then
  echo "$failures guard check(s) failed"
  exit 1
fi
echo "all guard checks passed"
