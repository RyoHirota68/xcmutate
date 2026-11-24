#!/bin/bash
# A smoke test of the instrumentation on public Swift code: four repositories at fixed commits (MIT and Apache 2.0),
# fetched into .build/corpus and never copied into this repository. Their build scripts, plugins and tests are
# not run; the Swift files are only read.
#
#   1. Every file: `instrument` does not crash (P1), its output still parses (P2), keeps the lines (P6) and is the
#      same when made twice (P7).
#   2. Whole modules that need no other module (Alamofire, Kingfisher): the original type-checks, and so does the
#      instrumented module, with the default operators. A shape of code that no longer compiles once it is
#      instrumented shows up here and nowhere else short of a real project.
#
#   scripts/verify-public-corpus.sh          # about 3 minutes after the first fetch
#
# Needs network access (the first time), python3 and swiftc. No simulator, no xcodebuild.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
JOBS="${JOBS:-3}"
BIN="${XCMUTATE_BIN:-}"
if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  BIN="$ROOT/.build/debug/xcmutate"
fi
CORPUS="$ROOT/.build/corpus"
OUT="$ROOT/.build/corpus-check"
mkdir -p "$CORPUS"
rm -rf "$OUT"
mkdir -p "$OUT"

# name, repository, commit (the default branches on 2026-11-21), licence
fetch() {
  local name="$1" url="$2" commit="$3"
  if [ "$(git -C "$CORPUS/$name" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then return 0; fi
  rm -rf "$CORPUS/$name"
  mkdir -p "$CORPUS/$name"
  # No hooks, no submodules, no LFS, no tags: the files of one commit and nothing else
  (cd "$CORPUS/$name" && git init -q . && git -c core.hooksPath=/dev/null fetch -q --depth 1 --no-tags "$url" "$commit" \
     && GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null checkout -q FETCH_HEAD) || { echo "could not fetch $name ($url)"; return 1; }
}
fetch Alamofire https://github.com/Alamofire/Alamofire dea4bab91767a971d6e112bc955c6a82295589b7 || exit 1              # MIT
fetch Kingfisher https://github.com/onevcat/Kingfisher 4203444ccbf482c885e0b601fa50b9a609660ef4 || exit 1              # MIT
fetch swift-argument-parser https://github.com/apple/swift-argument-parser d225b6fe8aed45478d1e36e770bf269c5d48d3a9 || exit 1  # Apache 2.0
fetch swift-algorithms https://github.com/apple/swift-algorithms 8fdd7fe21dc07a4538d6b3b7c873f497ab4d60fe || exit 1    # Apache 2.0

failures=0

# 1. File by file
(cd "$CORPUS" && find Alamofire Kingfisher swift-argument-parser swift-algorithms -name '*.swift' -type f -not -path '*/.git/*' | sort) > "$OUT/files.txt"
python3 -I scripts/fuzz/corpus_check.py "$BIN" "$CORPUS" "$OUT/files.txt" "$OUT/files" --default-ops --jobs "$JOBS" >/dev/null || { echo "the file check did not run to its end"; exit 1; }
python3 -I - "$OUT/files/results.jsonl" <<'PY' || failures=$((failures + 1))
import collections, json, sys

counts = collections.Counter()
problems = []
for line in open(sys.argv[1], encoding="utf-8"):
    result = json.loads(line)
    counts["files"] += 1
    counts["mutants"] += result.get("mutants", 0)
    if result.get("skipped"):
        counts[f"files skipped ({result['skipped']})"] += 1
    bad = [name for name in ("P1", "P2", "P6", "P7") if str(result.get(name, "ok")).startswith("fail")]
    if result.get("verification_failed"):
        bad.append("static verification")
    if result.get("dup_keys"):
        bad.append("duplicate keys")
    if bad:
        problems.append(f"{result['file']}: {', '.join(bad)} {result.get('stderr', '')[:200]} {result.get('p2_new') or ''} {result.get('p6_lines') or ''}")
for name, value in counts.items():
    print(f"{name}: {value}")
if problems:
    print(f"{len(problems)} file(s) with problems:")
    for problem in problems[:40]:
        print("  " + problem)
    sys.exit(1)
print("files: no crash, no syntax error, no shifted line, no difference between two runs")
PY

# 2. Whole modules
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
module() {
  local name="$1" directory="$2"
  shift 2
  local out="$OUT/module-$name"
  mkdir -p "$out"
  # Without the code samples of the documentation catalogue (they are not part of the module)
  (cd "$CORPUS" && find "$directory" -name '*.swift' -type f -not -path '*.docc/*' | sort) > "$out/files.txt"
  (cd "$CORPUS" && tr '\n' '\0' < "$out/files.txt" | xargs -0 "$BIN" instrument --root "$CORPUS" --output-dir "$out/instrumented" --manifest "$out/manifest.json") > "$out/instrument.log" 2>&1
  (cd "$CORPUS" && tr '\n' '\0' < "$out/files.txt" | xargs -0 xcrun swiftc -typecheck -module-name "$name" -suppress-warnings "$@") > "$out/original.log" 2>&1
  (cd "$out/instrumented" && tr '\n' '\0' < "$out/files.txt" | xargs -0 xcrun swiftc -typecheck -module-name "$name" -suppress-warnings "$@") > "$out/instrumented.log" 2>&1
  python3 -I - "$name" "$out" <<'PY' || failures=$((failures + 1))
import json, re, sys

name, out = sys.argv[1], sys.argv[2]
pattern = re.compile(r"^(.*?):(\d+):(\d+): error: (.*)$")

def errors(path):
    found = set()
    for line in open(path, errors="replace"):
        match = pattern.match(line)
        if match:
            found.add((match.group(1), int(match.group(2)), match.group(4)))
    return found

original = errors(out + "/original.log")
instrumented = errors(out + "/instrumented.log")
mutants = {entry["file"]: entry["mutants"] for entry in json.load(open(out + "/manifest.json"))["files"]}
total = sum(len(v) for v in mutants.values())
if original:
    print(f"{name}: the original module does not type-check here ({len(original)} errors); nothing to compare")
    sys.exit(1)
new = sorted(instrumented - original)
print(f"{name}: {len(mutants)} files, {total} mutants, {len(new)} errors after instrumentation")
for path, line, message in new[:20]:
    near = [(m["id"], m["operator"], m["original"][:40]) for m in mutants.get(path, []) if m["regionLines"]["start"] <= line <= m["regionLines"]["end"]][:3]
    print(f"  {path}:{line}: {message[:160]} {near}")
sys.exit(1 if new or total == 0 else 0)
PY
}
module Alamofire Alamofire/Source -swift-version 5 -parse-as-library
module Kingfisher Kingfisher/Sources -swift-version 5 -parse-as-library

if [ "$failures" -gt 0 ]; then
  echo "public corpus: $failures check(s) failed (details in $OUT)"
  exit 1
fi
echo "public corpus: all checks passed"
