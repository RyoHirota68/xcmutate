#!/bin/bash
# Runs the fixture code of Muter (muter-mutation-testing/muter, MIT License) through xcmutate.
#
#   scripts/verify-muter-fixtures.sh [<iOS simulator UDID>]
#
# 1. Fetch Muter at a pinned commit into .build/external/muter (it is not vendored into this repository)
# 2. Mutation input examples (Tests/fixtures/MutationExamples): instrumentation, static verification, compilation, and comparison against the expectations of Muter's unit tests
# 3. Run `run` on the sample projects (Repositories/). The macOS projects and the SwiftPM packages need no simulator.
#    ExampleApp (iOS) is run only when a UDID is passed
# 4. Compare the results of BonMot, FFCParserCombinator and ProjectWithConcurrency against the snapshots of Muter's regression tests
#
# Artifacts: the work copies and DerivedData go to ~/Library/Caches/xcmutate/verify-muter.noindex (changeable with the MUTER_WORK environment variable;
# removed by `xcmutate clean --all`); the reports and comparison results go to .build/muter-reports.
#
# Why the work directory is not placed under the repository's .build: if the repository is under ~/Desktop, ~/Documents or ~/Downloads,
# then in tests hosted by a macOS app (ExampleMacOSApp) the rebuilt app tries to open files in that folder and
# hangs waiting for an OS confirmation (the XCTest step that looks up the location of a failed test hangs in open, and a mutant that should be
# Killed becomes Timeout). This does not happen with xcmutate's default work directory (under ~/Library/Caches)
set -uo pipefail

MUTER_COMMIT=5c854098e61d1a093ef9c4e53a5ebc6de07b3a32
UDID="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MUTER="$ROOT/.build/external/muter"
WORK="${MUTER_WORK:-$HOME/Library/Caches/xcmutate/verify-muter.noindex}"
# MUTER_REPORTS: where the reports go. MUTER_RUN_ARGS: extra arguments for every `run` (for example `--shared-process`).
# To check a faster way of running against one process per mutant, run the script twice and compare the reports:
#   scripts/verify-muter-fixtures.sh <UDID>
#   MUTER_REPORTS=.build/muter-reports-shared MUTER_RUN_ARGS=--shared-process scripts/verify-muter-fixtures.sh <UDID>
#   for p in BonMot FFCParserCombinator ...; do scripts/compare-reports.py .build/muter-reports/$p.json .build/muter-reports-shared/$p.json; done
REPORTS="${MUTER_REPORTS:-$ROOT/.build/muter-reports}"
case "$REPORTS" in /*) ;; *) REPORTS="$ROOT/$REPORTS" ;; esac
EXTRA_RUN_ARGS=(${MUTER_RUN_ARGS:-})
mkdir -p "$REPORTS" "$WORK"

if [[ ! -d "$MUTER/.git" ]] || [[ "$(git -C "$MUTER" rev-parse HEAD 2>/dev/null)" != "$MUTER_COMMIT" ]]; then
  mkdir -p "$MUTER"
  git -C "$MUTER" init -q
  git -C "$MUTER" remote add origin https://github.com/muter-mutation-testing/muter.git 2>/dev/null || true
  git -C "$MUTER" fetch -q --depth 1 origin "$MUTER_COMMIT"
  git -C "$MUTER" checkout -q FETCH_HEAD
fi

BIN="${XCMUTATE_BIN:-}"
if [[ -z "$BIN" ]]; then
  swift build --product xcmutate >/dev/null || exit 1
  BIN="$ROOT/.build/debug/xcmutate"
fi
SUMMARY="$REPORTS/summary.txt"
: > "$SUMMARY"
note() { echo "$*" | tee -a "$SUMMARY"; }

note "== MutationExamples"
python3 scripts/muter/compare-examples.py "$BIN" "$MUTER" "$WORK/examples" > "$REPORTS/examples.json"
note "examples: exit $? (details: $REPORTS/examples.json)"

# run <name> <expected exit> <run arguments...>
run_project() {
  local name="$1" expected="$2"
  shift 2
  local start=$(date +%s)
  (cd "$MUTER/Repositories/$name" && "$BIN" run --root . --work-dir "$WORK/$name" \
    --reporter text --reporter json --json-output "$REPORTS/$name.json" ${EXTRA_RUN_ARGS[@]+"${EXTRA_RUN_ARGS[@]}"} "$@") > "$REPORTS/$name.log" 2>&1
  local status=$?
  local result="ok"
  [[ $status -ne $expected ]] && result="UNEXPECTED (expected exit $expected)"
  note "$name: exit $status in $(( $(date +%s) - start ))s $result — $(grep -E '^  (Killed|Survived|NotReached|Timeout|Crash|\(no mutants\))' "$REPORTS/$name.log" | head -1 | sed 's/^ *//')"
}

MAC='platform=macOS'
note "== Repositories"
run_project ProjectWithConcurrency 0 --project ProjectWithConcurrency.xcodeproj --scheme ProjectWithConcurrency --destination "$MAC" --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0
# A project whose tests fail without any mutant: exit code 6 (baseline failure)
run_project ProjectWithFailures 6 --project ProjectWithFailingTests.xcodeproj --scheme ProjectWithFailingTests --destination "$MAC" --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0
run_project EmptyExampleApp 0 --project EmptyExampleApp.xcodeproj --scheme EmptyExampleApp --destination "$MAC"
run_project ExampleMacOSApp 0 --project ExampleMacOSApp.xcodeproj --scheme ExampleMacOSApp --destination "$MAC" --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0
run_project ProjectWithTimeout 0 --package . --scheme ProjectWithTimeout --destination "$MAC"
# As in Muter's acceptance tests, the timeout is set to 1 second. The tests wait 2 seconds before calling the target function, so
# the run stops before the mutant is evaluated as active. xcmutate does not count this as detected (Timeout) but as RunnerError
(cd "$MUTER/Repositories/ProjectWithTimeout" && "$BIN" run --root . --package . --scheme ProjectWithTimeout --destination "$MAC" \
  --timeout-factor 0 --timeout-constant 1 --work-dir "$WORK/ProjectWithTimeout" --reporter json --json-output "$REPORTS/ProjectWithTimeout-1s.json") > "$REPORTS/ProjectWithTimeout-1s.log" 2>&1
note "ProjectWithTimeout (timeout 1s): $(python3 -c "import json;print(json.load(open('$REPORTS/ProjectWithTimeout-1s.json'))['counts'])")"
run_project FFCParserCombinator 0 --project FFCParserCombinator.xcodeproj --scheme FFCParserCombinator-Package --destination "$MAC" \
  --build-arg=SWIFT_VERSION=5.0 --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0
# BonMot: match the exclusions in Muter's muter.conf.yml. Remove the .xcodeproj from the work copy so that it is built as a package with xcodebuild
BONMOT_FILES=$(cd "$MUTER/Repositories/BonMot" && find Sources -name '*.swift' | grep -vE '/(Composable|Image\+Tinting|StringStyle)\.swift$' | sort)
run_project BonMot 0 --package . --scheme BonMot --destination "$MAC" --prepare 'mv BonMot.xcodeproj BonMot.xcodeproj.disabled' \
  --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0 $BONMOT_FILES
if [[ -n "$UDID" ]]; then
  run_project ExampleApp 0 --project ExampleApp.xcodeproj --scheme ExampleApp --destination "id=$UDID" --build-arg=IPHONEOS_DEPLOYMENT_TARGET=18.0
else
  note "ExampleApp: skipped (no simulator UDID given)"
fi

note "== Regression snapshots"
SNAP="$MUTER/RegressionTests/__Snapshots__/RegressionTests"
for pair in "BonMot:test_bonMot.bonmot.json" "FFCParserCombinator:test_parseCombinator.parsercombinator.json" "ProjectWithConcurrency:test_projectWithConcurrency.projectwithconcurrency.json"; do
  name="${pair%%:*}"; snap="${pair#*:}"
  python3 scripts/muter/compare-regression.py "$REPORTS/$name.json" "$SNAP/$snap" > "$REPORTS/$name-compare.json"
  note "$name: $(python3 scripts/muter/summarize.py "$REPORTS/$name-compare.json")"
done
echo "summary: $SUMMARY"
