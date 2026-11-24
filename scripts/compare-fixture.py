#!/usr/bin/env python3
"""Compares xcmutate's JSON report against the fixture's expected.json.

    python3 scripts/compare-fixture.py <report.json> <fixture-dir> [--units]

Each mutant (and each excluded candidate) is matched to an expectation in expected.json by the `// @case <marker>` at the end of
its source line plus operator, original and occurrence (the order among the same operator on the same line), and the kinds of results are compared.
Exit code 1 if anything does not match or has no counterpart.

With --units the report is one of the scheme SampleAppUnits (two test-plan configurations, two unit-test targets;
scripts/verify-fixture-units.sh): only the mutants that have `unitsExpected` are compared, against that field, and the
global expectations are those under `units`.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

report = json.load(open(sys.argv[1]))
fixture = Path(sys.argv[2])
expected = json.load(open(fixture / "expected.json"))
units = "--units" in sys.argv[3:]
if units:
    for case in expected["cases"]:
        case["mutants"] = [dict(e, expected=e["unitsExpected"], killKind=e.get("unitsKillKind")) for e in case["mutants"] if "unitsExpected" in e]
    expected["global"] = expected.get("units", {})

marker_re = re.compile(r"// @case (\S+)")
line_cache = {}


def marker_of(file, line):
    if file not in line_cache:
        line_cache[file] = (fixture / file).read_text().split("\n")
    m = marker_re.search(line_cache[file][line - 1])
    return m.group(1) if m else None


# Put the generation results (run results + exclusions) into one list
items = []
for r in report["results"]:
    m = r["mutant"]
    items.append({"file": m["file"], "line": m["start"]["line"], "start": m["point"]["start"], "op": m["operator"],
                  "original": m["original"], "status": r["status"], "detail": r.get("detail"),
                  "duration": r.get("durationSeconds"), "killedBy": r.get("killedBy", [])})
for i in report["ignored"]:
    items.append({"file": i["file"], "line": i["start"]["line"], "start": i["point"]["start"], "op": i["operator"],
                  "original": i["original"], "status": "Ignored", "reason": i["reason"]})
items.sort(key=lambda x: (x["file"], x["start"]))
occ = defaultdict(int)
for it in items:
    key = (it["file"], it["line"], it["op"])
    occ[key] += 1
    it["occurrence"] = occ[key]
    it["marker"] = marker_of(it["file"], it["line"])

unmatched = list(items)
rows = []
mismatches = []
for case in expected["cases"]:
    for e in case["mutants"]:
        cands = [it for it in unmatched if it["marker"] == e["marker"] and it["op"] == e["operator"]
                 and ("original" not in e or it["original"] == e["original"])
                 and ("occurrence" not in e or it["occurrence"] == e["occurrence"])]
        label = f'{case["id"]:4} {e["marker"]:18} {e["operator"]:20} {e.get("original", "")[:12]:12}'
        want = e["expected"]
        if e.get("killKind") == "crash":
            want = "Crash"
        if len(cands) != 1:
            mismatches.append(f"{label} expected {want}: matched {len(cands)} results")
            continue
        it = cands[0]
        unmatched.remove(it)
        got = it["status"]
        # For results that vary with the execution environment (simulator OS version, etc.), the allowed results can be listed
        ok = got == want or got in e.get("acceptable", [])
        if want == "Ignored" and e.get("reason") and it.get("reason") != e["reason"]:
            ok = False
            got = f'Ignored({it.get("reason")})'
        rows.append((ok, label, want, got, it))
        if not ok:
            detail = it.get("detail") or ""
            mismatches.append(f"{label} expected {want}, got {got} {detail[:160]}")

# Global expectations (`global` in expected.json): number of builds, files excluded from the targets, kinds of warnings
g = expected.get("global", {})
if "buildCount" in g and report.get("durations", {}).get("buildCount") != g["buildCount"]:
    mismatches.append(f'buildCount: expected {g["buildCount"]}, got {report.get("durations", {}).get("buildCount")} '
                      "(compile errors of all mutants should be collected in one build)")
if "excludedFiles" in g:
    got = {f["file"]: f["reason"] for f in report.get("excluded", {}).get("files", [])}
    if got != g["excludedFiles"]:
        mismatches.append(f'excluded files: expected {g["excludedFiles"]}, got {got}')
for kind in g.get("warningKinds", []):
    if not any(w["kind"] == kind for w in report.get("warnings", [])):
        mismatches.append(f"expected a warning of kind {kind}; got {[w['kind'] for w in report.get('warnings', [])]}")
for w in report.get("warnings", []):
    if w["kind"] not in g.get("warningKinds", []):
        mismatches.append(f'unexpected warning [{w["kind"]}] {w["message"][:200]}')

for it in unmatched:
    mismatches.append(f'unexpected result: {it["file"]}:{it["line"]} [{it["marker"]}] {it["op"]} {it["original"][:30]} -> {it["status"]}')

total = len(rows) + sum(1 for m in mismatches if "matched" in m)
matched = sum(1 for r in rows if r[0])
print()
print(f"fixture comparison: {matched}/{total} expectations matched, {len(unmatched)} results without expectations")
counts = report.get("counts", {})
print("counts: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
d = report.get("durations", {})
if d:
    avg = d.get("mutantPhaseSeconds", d["mutantSeconds"]) / d["executedMutants"] if d.get("executedMutants") else 0
    print(f'durations: total {d["totalSeconds"]:.0f}s, build {d["buildSeconds"]:.0f}s ({d["buildCount"]} builds), '
          f'baseline {d["baselineSeconds"]:.1f}s, {avg:.1f}s per mutant ({d["executedMutants"]} run)')
slow = sorted((it for it in items if it.get("duration")), key=lambda x: -x["duration"])[:5]
if slow:
    print("slowest: " + ", ".join(f'{it["marker"]}:{it["op"]}={it["duration"]:.1f}s' for it in slow))
if mismatches:
    print("\nmismatches:")
    for m in mismatches:
        print("  " + m)
    sys.exit(1)
