#!/usr/bin/env python3
"""Compares the counts of a JSON report with the expected ones and writes a short summary.

usage: check-smoke.py <report.json> <expected counts as JSON, for example '{"Killed": 18, "Survived": 5, "Ignored": 1}'>

Used by .github/workflows/smoke.yml. The summary goes to standard output and, when GITHUB_STEP_SUMMARY is set, to
that file as well. Exit status 1 when the counts differ.
"""
import json
import os
import sys


def main() -> int:
    report_path, expected_text = sys.argv[1], sys.argv[2]
    expected = json.loads(expected_text)
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    counts = report["counts"]
    warnings = [(warning["kind"], warning["message"]) for warning in report.get("warnings", [])]
    lines = ["## Smoke run", "", f"Tool: {report['tool']['name']} {report['tool']['version']}",
             f"Counts: {counts}", f"Expected: {expected}", f"Warnings: {len(warnings)}"]
    lines += [f"- `{kind}`: {message}" for kind, message in warnings]
    text = "\n".join(lines) + "\n"
    print(text, end="")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text)
    if counts != expected:
        print(f"the verdicts differ from the expected ones: {counts} != {expected}")
        return 1
    print("the verdicts are the expected ones")
    return 0


if __name__ == "__main__":
    sys.exit(main())
