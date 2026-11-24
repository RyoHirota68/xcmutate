#!/bin/bash
# Runs xcmutate on its own source (macOS; no simulator): which mutants of the tool do the tool's tests detect?
# The survivors are the gaps of the tool's own tests; docs/verification.md says what the last run found and
# what was done about each gap.
#
#   scripts/self-mutation.sh                                  # the files that decide verdicts (hours: see below)
#   scripts/self-mutation.sh Sources/MutatorCore/Flattener.swift ...   # other files
#   scripts/self-mutation.sh --since origin/main              # only what a branch changed (any `run` option works)
#
# The tests that compile and run programs with swiftc, and those that run the built executable, are left out:
# they take most of the time of a test run and exercise the instrumentation, not the code mutated here.
# Each mutant is run against the suites whose tests reach it (--select-tests reach with --shared-process); against
# all 250 tests a mutant takes half a minute. Nearly every suite reaches StableKey.swift, so that file alone takes
# about two hours; the others take one to two hours together. Give the files you changed as arguments
# (The whole tool takes hours; the last run was made in pieces.)
# Reports go to .build/self-mutation (JSON, Markdown and the agent's gaps); the work directory is kept between
# runs so that the second build is fast, and is removed with `xcmutate clean --work-dir .build/self-mutation/work`.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${XCMUTATE_BIN:-}"
if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  # A copy: the run builds this package again in its work copy, but a `swift build` here must not replace the running tool
  mkdir -p .build/self-mutation
  cp .build/debug/xcmutate .build/self-mutation/xcmutate
  BIN="$PWD/.build/self-mutation/xcmutate"
fi
OUT="$PWD/.build/self-mutation"
mkdir -p "$OUT"

DEFAULT_FILES=(
  Sources/MutatorRunner/Judgement.swift
  Sources/MutatorCore/DiffFilter.swift
  Sources/MutatorCore/StableKey.swift
  Sources/MutatorRunner/Journal.swift
  Sources/MutatorRunner/Config.swift
  Sources/MutatorRunner/ControlLedger.swift
)
if [ $# -eq 0 ]; then set -- "${DEFAULT_FILES[@]}"; fi

SLOW=(ExecutionOracleTests CompilableShapesTests EmbeddingTokenTests CommandLineTests FixtureExpectationTests)
SKIP=()
for suite in "${SLOW[@]}"; do SKIP+=(--skip-testing "MutatorCoreTests/$suite"); done

# The scheme of a package with several products is <package>-Package
"$BIN" run --root . --package . --scheme xcmutate-Package --destination 'platform=macOS' \
  --work-dir "$OUT/work" --shared-process --select-tests reach "${SKIP[@]}" \
  --reporter text --report json:"$OUT/report.json" --report markdown:"$OUT/report.md" --report agent:"$OUT/gaps.json" \
  "$@"
STATUS=$?
echo "self-mutation finished with status $STATUS; reports in $OUT"
exit $STATUS
