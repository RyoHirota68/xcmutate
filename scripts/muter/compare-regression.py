#!/usr/bin/env python3
"""Compares xcmutate's JSON report against the snapshots of Muter's regression tests
(RegressionTests/__Snapshots__/RegressionTests/*.json).

    python3 scripts/muter/compare-regression.py <xcmutate report> <Muter snapshot> [file names to exclude...]

Muter's mutants are matched to xcmutate's mutants by "file name, line, operator"
(Muter's position is the end of the rewritten expression/statement; it counts as the same if it falls within the lines of xcmutate's replaced range).
Results are compared as "detected (Muter: failed / runtimeError / timeout, xcmutate: Killed / Crash / Timeout)",
"not detected (Muter: passed, xcmutate: Survived)" and "not reached (Muter: noCoverage, xcmutate: NotReached)".
"""
import json
import sys
from collections import Counter, defaultdict

report = json.load(open(sys.argv[1]))
snapshot = json.load(open(sys.argv[2]))
excluded = set(sys.argv[3:])

OP = {"equality-flip": "RelationalOperatorReplacement", "boundary": "RelationalOperatorReplacement",
      "logical-connector": "ChangeLogicalConnector", "ternary-swap": "SwapTernary",
      "side-effect-removal": "RemoveSideEffects"}


def muter_class(outcome):
    return {"failed": "detected", "runtimeError": "detected", "timeout": "detected",
            "passed": "undetected", "noCoverage": "notReached"}.get(outcome, outcome)


def our_class(status):
    return {"Killed": "detected", "Crash": "detected", "Timeout": "detected",
            "Survived": "undetected", "NotReached": "notReached"}.get(status, status)


def coarse(c):
    # Muter does not distinguish "not reached" (passed if the tests pass), so the coarse comparison merges it into undetected
    return "undetected" if c in ("undetected", "notReached") else c


ours = defaultdict(list)
for r in report["results"]:
    m = r["mutant"]
    if m["operator"] in OP:
        ours[(m["file"].split("/")[-1], OP[m["operator"]])].append(r)
ignored = defaultdict(list)
for i in report["ignored"]:
    if i["operator"] in OP:
        ignored[(i["file"].split("/")[-1], OP[i["operator"]])].append(i)

same, different, muter_only = [], [], []
items = []
for fr in snapshot["fileReports"]:
    for a in fr["appliedOperators"]:
        items.append({"file": fr["fileName"], "line": a["mutationPoint"]["position"]["line"],
                      "column": a["mutationPoint"]["position"]["column"],
                      "operator": a["mutationPoint"]["mutationOperatorId"],
                      "before": a["mutationSnapshot"]["before"], "after": a["mutationSnapshot"]["after"],
                      "muter": a["testSuiteOutcome"]})
# Pass 1: those whose range's last line matches Muter's position (the end of the expression/statement). Pass 2: those contained in the range
assigned = {}
for exact in (True, False):
    for index, item in enumerate(items):
        if index in assigned:
            continue
        pool = ours.get((item["file"], item["operator"]), [])
        line = item["line"]
        if exact:
            cand = [r for r in pool if r["mutant"]["regionLines"]["end"] == line]
        else:
            cand = [r for r in pool if r["mutant"]["regionLines"]["start"] <= line <= r["mutant"]["regionLines"]["end"]]
        if cand:
            r = min(cand, key=lambda r: abs(r["mutant"]["end"]["column"] - item["column"]))
            pool.remove(r)
            assigned[index] = r
for index, item in enumerate(items):
    r = assigned.get(index)
    if r is None:
        ign = [i for i in ignored.get((item["file"], item["operator"]), []) if i["start"]["line"] == item["line"]]
        item["reason"] = ("ignored: " + ign[0]["reason"]) if ign else ("file excluded" if item["file"] in excluded else "not generated")
        muter_only.append(item)
        continue
    item.update({"xcmutate": r["status"], "replacement": r["mutant"]["replacement"],
                 "detail": (r.get("detail") or "")[:160]})
    item["coarseSame"] = coarse(muter_class(item["muter"])) == coarse(our_class(r["status"]))
    (same if muter_class(item["muter"]) == our_class(r["status"]) else different).append(item)

ours_only = [r for rs in ours.values() for r in rs]
summary = {
    "muterMutants": sum(len(fr["appliedOperators"]) for fr in snapshot["fileReports"]),
    "matchedMutants": len(same) + len(different),
    "sameOutcome": len(same),
    "differentOutcome": len(different),
    "differentOutcomeCoarse": sum(1 for d in different if not d["coarseSame"]),
    "muterOnly": len(muter_only),
    "muterOnlyReasons": dict(Counter(i["reason"] for i in muter_only)),
    "xcmutateOnlySameOperators": len(ours_only),
    "xcmutateOnlyByOperator": dict(Counter(r["mutant"]["operator"] for r in ours_only)),
    "xcmutateTotal": len(report["results"]),
    "xcmutateCounts": report.get("counts"),
}
print(json.dumps({"summary": summary, "different": different, "muterOnly": muter_only,
                  "xcmutateOnly": [{"file": r["mutant"]["file"], "line": r["mutant"]["start"]["line"],
                                        "operator": r["mutant"]["operator"], "status": r["status"]} for r in ours_only]},
                 ensure_ascii=False, indent=2))
