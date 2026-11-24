#!/bin/bash
# Makes a copy of the fixture (Fixtures/SampleApp) with the cases of Fixtures/GuardCases added: suites that need
# another suite, state that hides a mutant, mutants that crash the test host in a row, and a test that does not end.
# scripts/verify-fixture-guards.sh runs it.
#
#   scripts/make-guard-fixture.sh <out-dir>
#
# <out-dir> must be outside this repository and must not exist (or be empty).
set -euo pipefail
if [[ $# -ne 1 ]]; then
  sed -n '2,8p' "$0" >&2
  exit 64
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
if [[ -e "$OUT" && -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  echo "$OUT exists and is not empty" >&2
  exit 64
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
case "$OUT/" in "$ROOT"/*) echo "the directory must be outside the repository" >&2; exit 64 ;; esac
rsync -a --exclude SampleApp.xcodeproj "$ROOT/Fixtures/SampleApp/" "$OUT/"
mkdir -p "$OUT/SampleApp/Guards"
cp "$ROOT/Fixtures/GuardCases/GuardCases.swift" "$OUT/SampleApp/Guards/GuardCases.swift"
cp "$ROOT/Fixtures/GuardCases/GuardTests.swift" "$OUT/SampleAppTests/GuardTests.swift"
# The app calls one of the guard functions while it starts (see Guards.atLaunch)
APP="$OUT/SampleApp/App/SampleApp.swift"
python3 - "$APP" <<'PY'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
anchor = "struct SampleApp: App {\n"
if source.count(anchor) != 1:
    sys.exit("the app's declaration was not found in " + path)
open(path, "w", encoding="utf-8").write(source.replace(anchor, anchor + "    init() { _ = Guards.atLaunch(1) }\n"))
PY
# The counter of the test that ends its process when asked (outside the copy that the tool makes of the sources)
COUNTER="$OUT.end-once"
python3 - "$OUT/SampleAppTests/GuardTests.swift" "$COUNTER" <<'PY'
import sys
path, counter = sys.argv[1], sys.argv[2]
source = open(path, encoding="utf-8").read()
if source.count("__GUARD_COUNTER__") != 1:
    sys.exit("the place for the counter's path was not found in " + path)
open(path, "w", encoding="utf-8").write(source.replace("__GUARD_COUNTER__", counter))
PY
# A repository of its own: the work copy is made from what git knows
git -C "$OUT" init -q
git -C "$OUT" add -A
git -C "$OUT" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "guard fixture"
echo "guard fixture at $OUT"
