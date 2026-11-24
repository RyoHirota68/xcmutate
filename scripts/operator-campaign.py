#!/usr/bin/env python3
"""Summarizes the reports of scripts/operator-campaign.sh per operator.

    scripts/operator-campaign.py <campaign directory> [<classification.tsv>]

Reads <campaign directory>/reports/*.json and prints a Markdown summary: per operator and in total, how many
mutants were made and how they ended (Killed, Crash, Timeout, Survived, NotReached, CompileError, other), the share
that does not compile and the share of the reached mutants that was detected; then the same per package.
Writes <campaign directory>/survivors.md: every survivor with its source lines, grouped by operator, for reading.

With a classification file (tab-separated: package, stable key, class, reason; class is one of `gap`, `equivalent`,
`undecided`), the summary also counts the classes per operator, and survivors.md marks what is not classified yet.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

STATUSES = ["Killed", "Crash", "Timeout", "Survived", "NotReached", "CompileError"]


def percent(part, whole):
    if whole == 0:
        return "–"
    value = 100 * part / whole
    return f"{value:.0f}%" if value == 0 or value >= 10 else f"{value:.1f}%"


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    campaign = Path(sys.argv[1])
    classes = {}
    if len(sys.argv) > 2:
        for line in Path(sys.argv[2]).read_text().splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and not line.startswith("#") and parts[0] != "package":
                classes[(parts[0], parts[1])] = (parts[2], parts[3] if len(parts) > 3 else "")

    per_operator = defaultdict(lambda: defaultdict(int))
    per_package = defaultdict(lambda: defaultdict(int))
    per_both = defaultdict(lambda: defaultdict(int))
    class_counts = defaultdict(lambda: defaultdict(int))
    survivors = defaultdict(list)
    durations = {}
    for path in sorted((campaign / "reports").glob("*.json")):
        package = path.stem
        report = json.loads(path.read_text())
        durations[package] = report["durations"]
        root = Path(report["root"])
        for result in report["results"]:
            mutant = result["mutant"]
            operator = mutant["operator"]
            status = result["status"] if result["status"] in STATUSES else "other"
            for table, key in ((per_operator, operator), (per_package, package), (per_both, (operator, package))):
                table[key][status] += 1
                table[key]["total"] += 1
            if status == "Survived":
                survivors[operator].append((package, root, result))
                cls = classes.get((package, mutant["key"]), ("unclassified", ""))[0]
                class_counts[operator][cls] += 1

    def row(name, counts):
        detected = counts["Killed"] + counts["Crash"] + counts["Timeout"]
        reached = detected + counts["Survived"]
        cells = [name, counts["total"]] + [counts[s] for s in STATUSES] + [counts["other"],
                 percent(counts["CompileError"], counts["total"]), percent(detected, reached)]
        return "| " + " | ".join(str(c) for c in cells) + " |"

    header = "| {} | Mutants | " + " | ".join(STATUSES) + " | Other | Does not compile | Detected among reached |"
    rule = "|---|" + "---:|" * (len(STATUSES) + 4)
    total = defaultdict(int)
    for counts in per_operator.values():
        for key, value in counts.items():
            total[key] += value

    print("## Per operator, all packages\n")
    print(header.format("Operator"))
    print(rule)
    for operator in sorted(per_operator, key=lambda o: -per_operator[o]["total"]):
        print(row(f"`{operator}`", per_operator[operator]))
    print(row("**All**", total))

    if classes or class_counts:
        print("\n## Survivors by what they are\n")
        print("| Operator | Reached (detected + survived) | Survived | Test gap | Equivalent | Undecided | Not classified | Equivalent among reached |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|")
        for operator in sorted(per_operator, key=lambda o: -per_operator[o]["total"]):
            counts = per_operator[operator]
            reached = counts["Killed"] + counts["Crash"] + counts["Timeout"] + counts["Survived"]
            c = class_counts[operator]
            classified = c["gap"] + c["equivalent"] + c["undecided"]
            if reached == 0:
                share = "–"
            elif c["unclassified"] == 0 or classified == 0:
                share = f"{100 * c['equivalent'] / reached:.1f}%"
            else:
                # A sample was classified: assume the same share of equivalent mutants among the survivors not read
                share = f"about {100 * c['equivalent'] / classified * counts['Survived'] / reached:.0f}% (from {classified} of {counts['Survived']} survivors)"
            print(f"| `{operator}` | {reached} | {counts['Survived']} | {c['gap']} | {c['equivalent']} | {c['undecided']} | {c['unclassified']} | {share} |")

    print("\n## Per package\n")
    print(header.format("Package"))
    print(rule)
    for package in sorted(per_package):
        print(row(package, per_package[package]))

    print("\n## Per package and operator (mutants / detected / survived / not reached / does not compile)\n")
    packages = sorted(per_package)
    print("| Operator | " + " | ".join(packages) + " |")
    print("|---|" + "---|" * len(packages))
    for operator in sorted(per_operator, key=lambda o: -per_operator[o]["total"]):
        cells = []
        for package in packages:
            c = per_both[(operator, package)]
            cells.append("–" if c["total"] == 0 else f"{c['total']} / {c['Killed'] + c['Crash'] + c['Timeout']} / {c['Survived']} / {c['NotReached']} / {c['CompileError']}")
        print(f"| `{operator}` | " + " | ".join(cells) + " |")

    print("\n## Time\n")
    print("| Package | Whole run | Builds | Mutant phase | Mutants run | Shared processes | Killed there | Confirmed in a new process | Runs under xcodebuild |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for package in sorted(durations):
        d = durations[package]
        shared = d.get("sharedProcess") or {}
        print(f"| {package} | {d['totalSeconds']:.0f} s | {d['buildCount']} ({d['buildSeconds']:.0f} s) | {d.get('mutantPhaseSeconds', d['mutantSeconds']):.0f} s | "
              f"{d['executedMutants']} | {shared.get('processes', '–')} | {shared.get('killed', '–')} | {shared.get('confirmedDirectly', '–')} | {shared.get('alone', '–')} |")

    # Survivors with context
    lines = ["# Survivors of the operator campaign", "",
             "Generated by scripts/operator-campaign.py. Each entry: package, file and line, the change, the stable key, and the source around it.", ""]
    source_cache = {}
    for operator in sorted(survivors):
        lines += [f"## {operator} ({len(survivors[operator])})", ""]
        for package, root, result in sorted(survivors[operator], key=lambda x: (x[0], x[2]["mutant"]["file"], x[2]["mutant"]["start"]["line"])):
            mutant = result["mutant"]
            path = root / mutant["file"]
            if path not in source_cache:
                try:
                    source_cache[path] = path.read_text().split("\n")
                except OSError:
                    source_cache[path] = []
            source = source_cache[path]
            line = mutant["start"]["line"]
            cls = classes.get((package, mutant["key"]))
            change = f"`{' '.join(mutant['original'].split())[:100]}` → `{' '.join(mutant['replacement'].split())[:60]}`"
            lines.append(f"### {package} {mutant['file']}:{line} — {change}")
            lines.append(f"key: `{mutant['key']}` — {'**' + cls[0] + '**: ' + cls[1] if cls else 'NOT CLASSIFIED'} — in `{mutant['enclosingDecl']}`")
            lines.append("```swift")
            for number in range(max(1, line - 4), min(len(source), line + 3) + 1):
                lines.append(f"{'>' if number == line else ' '} {number:4} {source[number - 1]}")
            lines.append("```")
            lines.append("")
    (campaign / "survivors.md").write_text("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
