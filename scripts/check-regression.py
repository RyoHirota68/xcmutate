#!/usr/bin/env python3
"""Compares a JSON report of xcmutate with the expectations of a regression fixture.

usage: check-regression.py <report.json> <expected.json> [--label <text>]

expected.json:
  "statuses":  {"<declaration>::<operator>": "<status>"}  every mutant of that declaration and operator must have
               the status (or a list of statuses: those of its mutants, in any order); every mutant in the report
               must be named here (so a mutant that disappears from the run, or a new one, is noticed)
  "warnings":  kinds of warnings that the report must hold
  "noWarnings": kinds that it must not hold
  "narrowedOnly": ["<declaration>::<operator>"]  exactly the Survived mutants of these must be marked `narrowedOnly`
               (Survived after the tests that reach them only); absent: no survivor may be marked
  "narrowedDetections": [...]  when present: exactly the detected mutants of these must be marked `narrowedOnly`
               (detected by the tests that reach them, not run against all tests)
  "details":   {"<declaration>::<operator>": ["<text>", ...]}  the detail of every mutant of that key must contain
               one of the texts (for example the limit that stopped a run)
  "maxSeconds": {"<declaration>::<operator>": <seconds>}  no mutant of that key may have taken longer
  "exitStatus" is checked by the calling script.
"""
import json
import sys


def main() -> int:
    arguments = sys.argv[1:]
    label = ""
    if "--label" in arguments:
        index = arguments.index("--label")
        label = arguments[index + 1] + ": "
        del arguments[index:index + 2]
    report_path, expected_path = arguments
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    with open(expected_path, encoding="utf-8") as handle:
        expected = json.load(handle)

    problems = []
    found = {}
    for result in report.get("results", []):
        key = result["mutant"]["key"]
        parts = key.split("::")
        name = "::".join(parts[1:3]) if len(parts) >= 4 else key
        found.setdefault(name, []).append(result)
    for name, results in found.items():
        want = expected.get("statuses", {}).get(name)
        got = sorted(result["status"] for result in results)
        if want is None:
            problems.append(f"unexpected mutants of {name}: {got}")
        elif isinstance(want, list):
            # The statuses of the mutants of this declaration and operator, in any order
            if got != sorted(want):
                details = "; ".join(f"{r['mutant']['start']['line']}: {r['status']} ({r.get('detail') or 'no detail'})" for r in results)
                problems.append(f"{name}: {got}, expected {sorted(want)} [{details}]")
        else:
            for result in results:
                if result["status"] != want:
                    problems.append(f"{result['mutant']['key']}: {result['status']}, expected {want} ({result.get('detail') or 'no detail'})")
    for name in expected.get("statuses", {}):
        if name not in found:
            problems.append(f"no mutant for {name}")
    marked = sorted(name for name, results in found.items() if any(result.get("narrowedOnly") and result["status"] == "Survived" for result in results))
    if marked != sorted(expected.get("narrowedOnly", [])):
        problems.append(f"survivors marked as not run against all tests: {marked}, expected {sorted(expected.get('narrowedOnly', []))}")
    if "narrowedDetections" in expected:
        detected = sorted(name for name, results in found.items()
                          if any(result.get("narrowedOnly") and result["status"] in ("Killed", "Crash", "Timeout") for result in results))
        if detected != sorted(expected["narrowedDetections"]):
            problems.append(f"detections marked as resting on narrowed tests: {detected}, expected {sorted(expected['narrowedDetections'])}")
    for name, texts in expected.get("details", {}).items():
        for result in found.get(name, []):
            detail = result.get("detail") or ""
            if not any(text in detail for text in texts):
                problems.append(f"{result['mutant']['key']}: the detail names none of {texts}: {detail or 'no detail'}")
    for name, limit in expected.get("maxSeconds", {}).items():
        for result in found.get(name, []):
            if result.get("durationSeconds", 0) > limit:
                problems.append(f"{result['mutant']['key']}: took {result['durationSeconds']:.1f} s, more than {limit} s (was a limit inside the run not in use?)")
    # The tests named for a detection are identifiers, never a display name of Swift Testing or a line about a process
    for results in found.values():
        for result in results:
            for test in result.get("killedBy", []):
                if " " in test or test.startswith('"'):
                    problems.append(f"{result['mutant']['key']}: killedBy holds a name that is not the identifier of a test: {test}")
    kinds = {warning["kind"] for warning in report.get("warnings", [])}
    for kind in expected.get("warnings", []):
        if kind not in kinds:
            problems.append(f"no warning of kind {kind} (got: {sorted(kinds)})")
    for kind in expected.get("noWarnings", []):
        if kind in kinds:
            problems.append(f"warning of kind {kind} must not be there")

    if problems:
        print(f"{label}FAILED")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"{label}ok ({len(report.get('results', []))} mutants as expected)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
