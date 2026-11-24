#!/usr/bin/env python3
"""Processes Muter's mutation input examples (Tests/fixtures/MutationExamples) with xcmutate and checks whether
(1) instrumentation and static verification pass, (2) instrumentation introduces no new compile errors, and
(3) the mutants expected by Muter's unit tests are created.

    python3 scripts/muter/compare-examples.py <xcmutate> <muter checkout> <work directory>
"""
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

binary, muter, work = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
root = muter / "Tests/fixtures/MutationExamples"
expected = json.load(open(Path(__file__).resolve().parents[2] / "Fixtures/muter/expected-examples.json"))
op_map = expected["operatorMap"]
muter_ops = {v: k for k, vs in op_map.items() for v in vs}
work.mkdir(parents=True, exist_ok=True)

files = sorted(str(p.relative_to(root)) for p in root.rglob("*.swift"))
failures = []
rows = []


def errors(path):
    out = subprocess.run(["xcrun", "swiftc", "-typecheck", "-parse-as-library", str(path)],
                         capture_output=True, text=True).stderr
    msgs = set()
    for line in out.splitlines():
        m = re.match(r"^\S+?:\d+:\d+: error: (.*)$", line)
        if m:
            msgs.add(m.group(1))
    return msgs


for f in files:
    listing = json.loads(subprocess.run([binary, "list", "--format", "json", "--root", str(root), str(root / f)],
                                        capture_output=True, text=True, check=True).stdout)
    entry = listing["files"][0]
    mutants = entry["mutants"]
    out_dir = work / "instrumented"
    inst = subprocess.run([binary, "instrument", "--root", str(root), "--output-dir", str(out_dir), str(root / f)],
                          capture_output=True, text=True)
    static_ok = inst.returncode == 0 and entry["verification"]["missingIDs"] == [] and not entry["verification"]["hasSyntaxError"]
    before, after = errors(root / f), errors(out_dir / f)
    new_errors = sorted(after - before)
    if not static_ok:
        failures.append(f"{f}: static verification failed: {inst.stderr.strip()}")
    if new_errors:
        failures.append(f"{f}: instrumentation introduced compile errors: {new_errors}")

    # Comparison against Muter's expectations (counts per operator and line)
    exp = expected["files"].get(f)
    matched = missing = 0
    missing_list, extra_list = [], []
    if exp:
        ours = defaultdict(list)
        for m in mutants:
            if m["operator"] in muter_ops:
                ours[muter_ops[m["operator"]]].append(m)
        for op, positions in exp.items():
            if op == "test":
                continue
            pool = list(ours.get(op, []))
            for line, col in positions:
                cand = [m for m in pool if m["regionLines"]["start"] <= line <= m["regionLines"]["end"]]
                if cand:
                    pool.remove(min(cand, key=lambda m: abs(m["end"]["column"] - col)))
                    matched += 1
                else:
                    missing += 1
                    key = f"{f}:{line}"
                    reason = expected["intendedDifferences"].get(key)
                    missing_list.append((op, line, col, reason))
                    if not reason:
                        failures.append(f"{f}: Muter expects {op} at {line}:{col}, xcmutate does not create it")
            for m in pool:
                extra_list.append((op, m["start"]["line"], m["operator"]))
        # Mutants of operator kinds that Muter does not have
    others = [m for m in mutants if m["operator"] not in muter_ops]
    rows.append({
        "file": f, "mutants": len(mutants), "ignored": len(entry["ignored"]), "staticOK": static_ok,
        "compileErrorsBefore": len(before), "compileErrorsAfter": len(after), "newCompileErrors": new_errors,
        "muterExpected": sum(len(v) for k, v in exp.items() if k != "test") if exp else None,
        "matched": matched if exp else None, "missing": missing_list, "extraSameOperator": extra_list,
        "otherOperators": len(others), "referencedByMuterTests": exp is not None,
    })

print(json.dumps({"files": rows, "failures": failures}, ensure_ascii=False, indent=2))
total_exp = sum(r["muterExpected"] or 0 for r in rows)
total_matched = sum(r["matched"] or 0 for r in rows)
print(f"\nexamples: {len(rows)} files, Muter expectations matched {total_matched}/{total_exp}, failures {len(failures)}", file=sys.stderr)
sys.exit(1 if failures else 0)
