#!/bin/bash
# Runs the steps of the GitHub Action (action.yml, action/*.sh) on this Mac, with the environment that a GitHub
# runner would give them, against a small package on macOS. It checks the shell of the steps; it cannot check
# what only GitHub does (expressions in action.yml, actions/cache, actions/upload-artifact, how annotations are shown).
#
#   scripts/verify-action.sh
#
# Everything goes to .build/action-check/. The tool is built from this checkout (the "source" path of install.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
OUT="$REPO/.build/action-check"
mkdir -p "$OUT"
failures=0
check() { if "$@"; then echo "  ok: $CHECK"; else echo "  FAILED: $CHECK"; failures=$((failures + 1)); fi; }

# A repository of its own with a pull-request-like change: a base commit, then a changed line
PROJECT="$OUT/project"
if [[ -d "$PROJECT" ]]; then find "$PROJECT" -mindepth 1 -delete; fi
mkdir -p "$PROJECT/Sources/Sample" "$PROJECT/Tests/SampleTests"
cat >"$PROJECT/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Sample", products: [.library(name: "Sample", targets: ["Sample"])],
                      targets: [.target(name: "Sample"), .testTarget(name: "SampleTests", dependencies: ["Sample"])])
SWIFT
cat >"$PROJECT/Sources/Sample/Age.swift" <<'SWIFT'
public func isAdult(_ age: Int) -> Bool { age >= 18 }
public func isChild(_ age: Int) -> Bool { age < 13 }
SWIFT
cat >"$PROJECT/Sources/Sample/Old Age.swift" <<'SWIFT'
public func isSenior(_ age: Int) -> Bool { age > 64 }
SWIFT
cat >"$PROJECT/Tests/SampleTests/AgeTests.swift" <<'SWIFT'
import XCTest
@testable import Sample
final class AgeTests: XCTestCase {
    func testAdult() { XCTAssertTrue(isAdult(30)); XCTAssertFalse(isAdult(3)) }
    func testChild() { XCTAssertTrue(isChild(3)); XCTAssertFalse(isChild(13)); XCTAssertTrue(isChild(12)) }
}
SWIFT
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid add -A
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid commit -q -m base
git -C "$PROJECT" update-ref refs/remotes/origin/main HEAD
git -C "$PROJECT" checkout -q -b change
# The pull request changes isAdult (whose boundary no test tries) and leaves isChild alone
sed -i '' 's/age >= 18 }/age >= 20 }/' "$PROJECT/Sources/Sample/Age.swift"
sed -i '' 's/isAdult(3))/isAdult(3)); XCTAssertTrue(isAdult(40))/' "$PROJECT/Tests/SampleTests/AgeTests.swift"
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid commit -q -am change

export GITHUB_OUTPUT="$OUT/github-output.txt" GITHUB_PATH="$OUT/github-path.txt" GITHUB_STEP_SUMMARY="$OUT/step-summary.md"
: >"$GITHUB_OUTPUT"; : >"$GITHUB_PATH"; : >"$GITHUB_STEP_SUMMARY"
output() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1; }

# An executable left by an earlier run of this script is of other sources: on GitHub the cache key holds a hash of
# the sources, here nothing does
if [[ -d "$OUT/tool/bin" ]]; then find "$OUT/tool/bin" -type f -name 'xcmutate*' -delete; fi

echo "== install.sh (the sources of this checkout)"
export INPUT_VERSION="" ACTION_REF="main" ACTION_PATH="$REPO" ACTION_REPOSITORY="owner/xcmutate" TOOL_DIR="$OUT/tool"
"$REPO/action/install.sh" key
CHECK="a branch ref means: build from the sources"
check bash -c "[[ '$(output key)' == source-* ]]"
CHECK="a release tag means: that release"
check bash -c "ACTION_REF=v1.2.3 GITHUB_OUTPUT=/dev/stdout '$REPO/action/install.sh' key | grep -q '^key=release-1.2.3\$'"
CHECK="the input version wins over the ref, with or without a leading v"
check bash -c "INPUT_VERSION=0.9.9 ACTION_REF=main GITHUB_OUTPUT=/dev/stdout '$REPO/action/install.sh' key | grep -q '^key=release-0.9.9\$' && INPUT_VERSION=v0.9.9 ACTION_REF=main GITHUB_OUTPUT=/dev/stdout '$REPO/action/install.sh' key | grep -q '^key=release-0.9.9\$'"
"$REPO/action/install.sh" install >"$OUT/install.log" 2>&1
CHECK="install.sh builds the tool and adds its directory to the PATH file"
check bash -c "[ -x '$OUT/tool/bin/xcmutate' ] && grep -qx '$OUT/tool/bin' '$GITHUB_PATH'"
"$REPO/action/install.sh" install >"$OUT/install-again.log" 2>&1
CHECK="a second install uses the executable that is there (what a cache hit gives)"
check grep -q "using the cached executable" "$OUT/install-again.log"
THIS="$("$OUT/tool/bin/xcmutate" --version)"
CHECK="a version that the workflow names and that cannot be downloaded is an error, and nothing else is installed in its place"
mv "$OUT/tool/bin/xcmutate" "$OUT/tool/bin/xcmutate.first"
INPUT_VERSION=v0.0.1 ACTION_REPOSITORY=owner/does-not-exist-xcmutate "$REPO/action/install.sh" install >"$OUT/install-named.log" 2>&1
named=$?
check bash -c "[ $named -ne 0 ] && grep -q '::error::xcmutate 0.0.1 could not be downloaded' '$OUT/install-named.log' && [ ! -e '$OUT/tool/bin/xcmutate' ]"
CHECK="called by a tag without a version: when the release cannot be downloaded, the sources of that tag are built, with a notice"
INPUT_VERSION="" ACTION_REF="v$THIS" ACTION_REPOSITORY=owner/does-not-exist-xcmutate "$REPO/action/install.sh" install >"$OUT/install-fallback.log" 2>&1
check bash -c "grep -q '::notice::xcmutate $THIS could not be downloaded' '$OUT/install-fallback.log' && [ -x '$OUT/tool/bin/xcmutate' ]"
CHECK="a cached executable of another version than the one asked for is not used"
INPUT_VERSION=0.0.1 ACTION_REPOSITORY=owner/does-not-exist-xcmutate "$REPO/action/install.sh" install >"$OUT/install-cached-other.log" 2>&1
check bash -c "grep -q 'the cached executable is version $THIS, not 0.0.1' '$OUT/install-cached-other.log' && grep -q '::error::' '$OUT/install-cached-other.log'"
mv "$OUT/tool/bin/xcmutate.first" "$OUT/tool/bin/xcmutate"
export PATH="$OUT/tool/bin:$PATH"

echo "== destination.sh"
INPUT_DESTINATION="platform=macOS" "$REPO/action/destination.sh" >/dev/null
CHECK="a macOS destination is handed on as it is"
check bash -c "[ '$(output destination)' = 'platform=macOS' ]"
CHECK="a simulator platform without a name or an id is an error"
check bash -c "INPUT_DESTINATION='platform=iOS Simulator' '$REPO/action/destination.sh' 2>&1 | grep -q '::error::'"
CHECK="a simulator name that no device has is an error"
check bash -c "! INPUT_DESTINATION='platform=iOS Simulator,name=No Such Device 0000' '$REPO/action/destination.sh' >'$OUT/destination.log' 2>&1 && grep -q '::error::no available simulator' '$OUT/destination.log'"

run_action() {   # run_action <label> [VAR=value...]: one run of run.sh in the project, as a pull_request event
  local label="$1"
  shift
  : >"$GITHUB_OUTPUT"; : >"$GITHUB_STEP_SUMMARY"
  (cd "$PROJECT" && env INPUT_PACKAGE=. INPUT_SCHEME=Sample INPUT_DESTINATION="platform=macOS" INPUT_WORK_DIR="$OUT/work" \
      INPUT_REPORT_DIRECTORY="$OUT/reports-$label" GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main GITHUB_WORKSPACE="$PROJECT" "$@" \
      "$REPO/action/run.sh") >"$OUT/run-$label.out" 2>"$OUT/run-$label.err"
}

echo "== run.sh: a pull request, gate on undetected mutants"
run_action gate INPUT_FAIL_ON_SURVIVED=true
CHECK="run.sh itself succeeds (the reports are uploaded before the job fails)"
check test $? -eq 0
CHECK="the exit code of the tool is recorded: 3, an undetected mutant on the changed line"
check bash -c "[ '$(output exit-code)' = 3 ]"
CHECK="only the changed lines were mutated (--since origin/<base branch>): isChild is not in the report"
check bash -c "grep -q 'isAdult' '$OUT/reports-gate/mutation.json' && ! grep -q 'isChild' '$OUT/reports-gate/mutation.json'"
CHECK="the Markdown report is in the job summary"
check grep -q "^## Mutation testing (xcmutate" "$GITHUB_STEP_SUMMARY"
CHECK="the undetected mutant is an annotation on its line, with a path relative to the workspace"
check grep -q "^::warning file=Sources/Sample/Age.swift,line=1,col=[0-9]*,title=.*::" "$OUT/run-gate.out"
CHECK="the outputs score, undetected and report are set"
check bash -c "[ -n '$(output score)' ] && [ '$(output undetected)' -ge 1 ] && [ -f '$(output report)' ]"
CHECK="the JSON, Markdown and HTML reports are in the report directory"
check test -s "$OUT/reports-gate/mutation.json" -a -s "$OUT/reports-gate/mutation.md" -a -s "$OUT/reports-gate/mutation.html"
CHECK="the progress file is in the report directory and ends with the exit code of the run (3)"
check bash -c "tail -n 1 '$OUT/reports-gate/progress.jsonl' | /usr/bin/python3 -c 'import json,sys; e=json.loads(sys.stdin.read()); sys.exit(0 if e[\"event\"] == \"runEnd\" and e[\"exitCode\"] == 3 and e[\"version\"] == 1 else 1)' && grep -q '\"event\":\"mutant\"' '$OUT/reports-gate/progress.jsonl'"
EXIT_CODE="$(output exit-code)" "$REPO/action/result.sh" >"$OUT/result.out" 2>&1
result=$?
CHECK="result.sh fails the job with that code and says why"
check bash -c "[ $result -eq 3 ] && grep -q '::error::xcmutate: mutants were not detected' '$OUT/result.out'"

echo "== run.sh: the whole file (since: none), no gate, further arguments, a limit on the number of mutants"
run_action full INPUT_SINCE=none INPUT_FILES="Sources/Sample/Old Age.swift
Sources/Sample/A*.swift" INPUT_MAX_MUTANTS=1 INPUT_ANNOTATIONS=false INPUT_ARGS="--disable-operator
return-value"
CHECK="exit code 0 without a gate"
check bash -c "[ '$(output exit-code)' = 0 ]"
CHECK="files given one per line: a path with a space and a pattern; one mutant of the three was examined (the report names the sample)"
check bash -c "[ \"\$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(len(r[\"results\"]), r[\"sampling\"][\"candidates\"])' '$OUT/reports-full/mutation.json')\" = '1 3' ]"
CHECK="no annotations when they are turned off"
check bash -c "! grep -q '^::warning' '$OUT/run-full.out'"
EXIT_CODE=0 "$REPO/action/result.sh" >/dev/null
CHECK="result.sh succeeds for exit code 0"
check test $? -eq 0

echo "== run.sh: wrong inputs"
: >"$GITHUB_OUTPUT"; : >"$GITHUB_STEP_SUMMARY"
# The reports of the run before are still in the directory, as on a runner that keeps its work space
(cd "$PROJECT" && INPUT_SCHEME=Sample INPUT_REPORT_DIRECTORY="$OUT/reports-full" "$REPO/action/run.sh") >"$OUT/run-bad.out" 2>&1
CHECK="no project, workspace or package: an error annotation and exit code 64"
check bash -c "grep -q '::error::give exactly one' '$OUT/run-bad.out' && [ '$(output exit-code)' = 64 ]"
CHECK="a run that fails does not report the numbers of the run before: no score, no report, nothing in the summary"
check bash -c "[ -z '$(output score)' ] && [ -z '$(output report)' ] && [ ! -e '$OUT/reports-full/mutation.json' ] && [ ! -s '$GITHUB_STEP_SUMMARY' ]"
: >"$GITHUB_OUTPUT"
run_action bad-args INPUT_ARGS="--only-testing SampleTests"
CHECK="an option and its value on one line of args is refused by the tool (exit code 64), as the input's description says"
check bash -c "[ '$(output exit-code)' = 64 ]"
: >"$GITHUB_OUTPUT"
run_action good-args INPUT_SINCE=none INPUT_FILES="Sources/Sample/Age.swift" INPUT_ANNOTATIONS=false INPUT_ARGS="--only-testing
SampleTests"
CHECK="on two lines they are two arguments"
check bash -c "[ '$(output exit-code)' = 0 ]"

echo "== run.sh: a baseline report, files that it did not examine, and a file that is new"
run_action base-part INPUT_SINCE=none INPUT_FILES="Sources/Sample/Age.swift" INPUT_ANNOTATIONS=false
cp "$OUT/reports-base-part/mutation.json" "$OUT/baseline-part.json"
run_action base-all INPUT_SINCE=none INPUT_ANNOTATIONS=false
cp "$OUT/reports-base-all/mutation.json" "$OUT/baseline-all.json"
run_action vs-part INPUT_SINCE=none INPUT_ANNOTATIONS=false INPUT_BASELINE_REPORT="$OUT/baseline-part.json"
CHECK="a file that existed when the baseline was made and that the baseline left out: its gaps are not new (exit code 0, with a warning)"
check bash -c "[ '$(output exit-code)' = 0 ] && grep -q 'existed when the earlier report was made' '$OUT/run-vs-part.err'"
cat >"$PROJECT/Sources/Sample/New.swift" <<'SWIFT'
public func isTeen(_ age: Int) -> Bool { age > 12 && age < 20 }
SWIFT
git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid commit -q -m "a new file without tests"
run_action vs-all INPUT_SINCE=none INPUT_ANNOTATIONS=false INPUT_BASELINE_REPORT="$OUT/baseline-all.json"
CHECK="a file that did not exist when the baseline was made: its gaps are new (exit code 5)"
check bash -c "[ '$(output exit-code)' = 5 ] && grep -q 'did not exist at its commit' '$OUT/run-vs-all.err'"
run_action vs-all-diff INPUT_ANNOTATIONS=false INPUT_BASELINE_REPORT="$OUT/baseline-all.json"
CHECK="the same as a pull request (only the changed lines): exit code 5"
check bash -c "[ '$(output exit-code)' = 5 ]"

"$OUT/tool/bin/xcmutate" clean --work-dir "$OUT/work" >/dev/null 2>&1 || true
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed (logs: $OUT)"
  exit 1
fi
echo "all checks of the action's steps passed"
