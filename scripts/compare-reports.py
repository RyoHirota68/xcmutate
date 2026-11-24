#!/usr/bin/env python3
"""Compares the verdicts of two JSON reports of `xcmutate run`, mutant by mutant (by stable key).

    scripts/compare-reports.py [--by-position] [--detection-only] <reference.json> <other.json>

Used to check that a faster way of running (`--shared-process`, `--workers`, `--select-tests reach`)
gives the same verdict for every mutant as one process per mutant does.

Two comparisons are printed, because they answer different questions:

- **the same outcome**: detected (Killed, Crash, Timeout), not detected (Survived, NotReached), or not
  judged (everything else). This is what the score is made of.
- **the same verdict**: the status as written. Two runs that agree on every outcome can still differ here:
  a mutant that makes a test crash is a Crash in a run that confirms a crash by repeating it and can be
  a Killed (or the other way round) in a run made with another `--confirm-kills`, and a mutant that is
  slow rather than endless can be a Timeout in one run and a Killed in the other.

Exits with 1 if a mutant has a different verdict or exists in only one report. With `--detection-only`
a difference that stays inside one outcome does not count (use it to compare runs made with different
`--confirm-kills`). `killedBy` does not decide the exit code (a shared process reports at most 20
failing tests, and narrowed tests name fewer); the script notes when the other report names a failing
test that the reference does not.
"""
import json
import sys


def identity(mutant, by_position):
    if not by_position:
        return mutant["key"]
    return "{file}:{line}:{column} {operator} `{original}` -> `{replacement}`".format(
        file=mutant["file"], line=mutant["start"]["line"], column=mutant["start"]["column"], operator=mutant["operator"],
        original=mutant["original"], replacement=mutant["replacement"])


def outcome(status):
    if status in ("Killed", "Crash", "Timeout"):
        return "detected"
    if status in ("Survived", "NotReached"):
        return "not detected"
    return "not judged"


def load(path, by_position):
    with open(path) as f:
        report = json.load(f)
    return report, {identity(r["mutant"], by_position): r for r in report["results"]}


def main():
    arguments = sys.argv[1:]
    # Two reports of the same sources made by two versions of the tool, whose stable keys differ: match the
    # mutants by file, position, operator and change instead
    by_position = "--by-position" in arguments
    detection_only = "--detection-only" in arguments
    arguments = [a for a in arguments if a not in ("--by-position", "--detection-only")]
    if len(arguments) != 2:
        print(__doc__, file=sys.stderr)
        return 64
    reference, a = load(arguments[0], by_position)
    other, b = load(arguments[1], by_position)
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    different = [(k, a[k]["status"], b[k]["status"]) for k in a if k in b and a[k]["status"] != b[k]["status"]]
    extra_killers = [k for k in a if k in b and a[k]["status"] in ("Killed", "Crash") and b[k]["status"] == a[k]["status"]
                     and not set(b[k].get("killedBy", [])) <= set(a[k].get("killedBy", []))]
    common = len([k for k in a if k in b])
    other_outcome = [d for d in different if outcome(d[1]) != outcome(d[2])]
    other_kind = [d for d in different if outcome(d[1]) == outcome(d[2])]
    print(f"{common - len(other_outcome)} of {len(a)} mutants have the same outcome in both reports (detected / not detected / not judged)")
    print(f"{common - len(different)} of {len(a)} mutants have the same verdict in both reports (the status as written)")
    for key in only_a:
        print(f"  only in the reference: {key}")
    for key in only_b:
        print(f"  only in the other report: {key}")
    for key, first, second in other_outcome:
        print(f"  different outcome: {key}: {first} (reference) / {second}")
    for key, first, second in other_kind:
        print(f"  same outcome ({outcome(first)}), another verdict: {key}: {first} (reference) / {second}")
    if extra_killers:
        print(f"  note: {len(extra_killers)} killed mutants name a failing test that the reference does not")
    for label, report in (("reference", reference), ("other", other)):
        d = report["durations"]
        executed = d.get("executedMutants", 0)
        phase = d.get("mutantPhaseSeconds", d.get("mutantSeconds", 0))
        line = f"  {label}: total {d['totalSeconds']:.0f}s, build {d['buildSeconds']:.0f}s, mutants {phase:.0f}s"
        if executed:
            line += f" ({phase / executed:.2f}s per mutant, {executed} run)"
        if d.get("workers", 1) > 1:
            line += f", {d['workers']} workers"
        shared = d.get("sharedProcess")
        if shared:
            line += f"; shared processes {shared['processes']}: {shared['killed']} killed there, {shared['passed']} passed there, {shared['alone']} runs alone"
        print(line)
    if detection_only:
        return 1 if other_outcome or only_a or only_b else 0
    return 1 if different or only_a or only_b else 0


if __name__ == "__main__":
    sys.exit(main())
