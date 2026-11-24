#!/bin/bash
# Runs a part of the load fixture (scripts/make-load-fixture.sh) and prints where the time of the run went.
#
#   scripts/measure-load.sh <load-fixture-dir> <SIMULATOR-UDID> <label> [run options...]
#
# The mutated files hold mutants of every kind that costs something: killed ones, survivors, two that never end,
# three that crash the test host, and code that runs once per process. The report goes to
# .build/load/<label>.json, the log to .build/load/<label>.log, the work directory to .build/load/work.
# Set XCMUTATE_BIN to measure another build of the tool (an earlier version, for a comparison), and
# LOAD_FILES to mutate other files of the fixture.
set -uo pipefail

if [[ $# -lt 3 ]]; then
  sed -n '2,10p' "$0" >&2
  exit 64
fi
FIXTURE="$(cd "$1" && pwd)"
UDID="$2"
LABEL="$3"
shift 3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
BIN="${XCMUTATE_BIN:-}"
if [[ -z "$BIN" ]]; then
  swift build --product xcmutate >/dev/null || exit 1
  BIN="$ROOT/.build/debug/xcmutate"
fi
OUT="$ROOT/.build/load"
mkdir -p "$OUT"

FILES=(SampleApp/SideEffects/SideEffectCases.swift SampleApp/Infrastructure/OncePerProcess.swift
       SampleApp/Infrastructure/TestKindCases.swift SampleApp/Operators/ReturnAndClosureCases.swift
       SampleApp/Equivalence/EquivalenceCases.swift)
# LOAD_FILES="a.swift b.swift": other files (a shorter run)
if [[ -n "${LOAD_FILES:-}" ]]; then read -r -a FILES <<<"$LOAD_FILES"; fi

START=$(date +%s)
(cd "$FIXTURE" && "$BIN" run --root . --project SampleApp.xcodeproj --scheme SampleApp --destination "id=$UDID" \
    --only-testing SampleAppTests --prepare "'$XCODEGEN' generate --quiet" --work-dir "$OUT/work" --no-caffeinate \
    --reporter text --reporter json --json-output "$OUT/$LABEL.json" "$@" "${FILES[@]}") >"$OUT/$LABEL.log" 2>&1
STATUS=$?
echo "$LABEL: exit status $STATUS after $(( $(date +%s) - START ))s (log: $OUT/$LABEL.log)"
[[ -f "$OUT/$LABEL.json" ]] || exit "$STATUS"

python3 - "$OUT/$LABEL.json" "$OUT/$LABEL.log" <<'PY'
import json
import re
import sys
from collections import Counter

report = json.load(open(sys.argv[1]))
log = open(sys.argv[2], errors="replace").read()
d = report["durations"]
print("  verdicts: " + ", ".join(f"{k} {v}" for k, v in sorted(Counter(r["status"] for r in report["results"]).items())))
print(f"  baseline {d.get('baselineSeconds', 0):.0f}s ({report['baseline']['testCount']} tests), mutant phase {d.get('mutantPhaseSeconds', 0):.0f}s "
      f"for {d.get('executedMutants', 0)} mutants, final baseline {d.get('finalBaselineSeconds', 0):.0f}s, total {d['totalSeconds']:.0f}s")
c = d.get("confirmation")
if c:
    print(f"  runs without mutants between mutants: {c['controlRuns']} ({c['controlSeconds']:.0f}s); mutants run a second time: {c['repeatedRuns']}")
s = d.get("sharedProcess")
if s:
    print(f"  shared processes: {s['processes']} ({s['seconds']:.0f}s), {s['killed']} killed there, {s['passed']} passed there, "
          f"{s.get('confirmedDirectly', 0)} confirmed in a new process, {s['alone']} runs under xcodebuild")
slow = sorted((r for r in report["results"] if r.get("durationSeconds")), key=lambda r: -r["durationSeconds"])[:5]
for r in slow:
    m = r["mutant"]
    print(f"    {r['durationSeconds']:6.1f}s {r['status']:8} {m['file'].split('/')[-1]}:{m['start']['line']} {m['operator']}")
for w in report.get("warnings", []):
    print(f"  warning [{w['kind']}]: {w['message'][:200]}")
# How far off the printed estimates of the remaining time were: for every progress line, the estimate against
# the time the run really still took (taken from the modification order of the lines is not possible; the lines
# carry no clock, so only the first estimate and the first one after half of the mutants are shown)
estimates = re.findall(r"\[(\d+)/(\d+)\] .*?(about|roughly) ([0-9hms]+) left", log)
if estimates:
    first, middle = estimates[0], estimates[len(estimates) // 2]
    print(f"  remaining time as printed: after mutant {first[0]}: {first[2]} {first[3]}; after mutant {middle[0]}: {middle[2]} {middle[3]}")
PY
exit "$STATUS"
