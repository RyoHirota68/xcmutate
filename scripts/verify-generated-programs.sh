#!/bin/bash
# Generates Swift programs from a grammar (scripts/fuzz/gen.py), instruments them and compares runs:
#   P4  with all mutants off, the instrumented program prints what the original prints;
#   P5  with one mutant on, it prints what the program with that one change written into the source prints.
# Every operator is enabled. Needs python3 and swiftc; no simulator, no xcodebuild.
#
#   scripts/verify-generated-programs.sh             # seeds 2000 to 2029 (about 5 minutes with 3 jobs)
#   scripts/verify-generated-programs.sh 2000 2200   # another range (seeds from 2000 on give the same programs for good)
#
# Results and the programs of failing seeds stay in .build/generated-programs.
set -uo pipefail
cd "$(dirname "$0")/.."
FROM="${1:-2000}"
TO="${2:-2030}"
JOBS="${JOBS:-3}"
BIN="${XCMUTATE_BIN:-}"
if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  BIN="$PWD/.build/debug/xcmutate"
fi
OUT="$PWD/.build/generated-programs"
rm -rf "$OUT"
mkdir -p "$OUT"
# The names of the helper's variables must not reach the programs from the environment of the caller
env -u XCMUTATE_ACTIVE -u XCMUTATE_TRACE python3 scripts/fuzz/exec_check.py "$BIN" scripts/fuzz/gen.py "$OUT" "$FROM" "$TO" \
  --p5-every 2 --p5-max 20 --reached-only --jobs "$JOBS" >/dev/null || { echo "the check did not run to its end"; exit 1; }
python3 - "$OUT/results.jsonl" <<'PY'
import collections, json, sys

counts = collections.Counter()
problems = []
for line in open(sys.argv[1], encoding="utf-8"):
    result = json.loads(line)
    counts["programs"] += 1
    counts["mutants embedded"] += result.get("mutants", 0)
    status = result.get("status")
    if status == "gen-invalid":
        # The generator made a program that does not compile: nothing to compare (a defect of the generator)
        counts["programs the generator got wrong (skipped)"] += 1
        continue
    if status != "ok":
        problems.append(f"seed {result['seed']}: {status}: {result.get('errors') or result.get('stderr', '')[:300]} {(result.get('suspects') or [])[:3]}")
        continue
    if result.get("P4") != "ok":
        problems.append(f"seed {result['seed']}: P4: the instrumented program behaves differently with all mutants off {result.get('p4_diff')}")
    p5 = result.get("P5")
    if p5:
        counts["mutants compared with the rewritten source"] += p5["checked"]
        counts["of them with another output than the original"] += p5["killed"]
        for failure in p5["fail"]:
            problems.append(f"seed {result['seed']}: P5: switch and rewritten source differ: {failure}")
for name, value in counts.items():
    print(f"{name}: {value}")
if counts["programs"] == 0:
    problems.append("no program was checked")
if problems:
    print(f"{len(problems)} problem(s):")
    for problem in problems:
        print("  " + problem)
    sys.exit(1)
print("generated programs: no difference found")
PY
