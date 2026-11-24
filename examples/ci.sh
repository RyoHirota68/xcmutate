#!/bin/bash
# Mutation testing of the lines a change request touches, for a CI system other than GitHub Actions (or a
# self-hosted Mac): the same steps as the GitHub Action, as plain shell (docs/ci.md).
#
#   BASE=origin/main SCHEME=App WORKSPACE=App.xcworkspace DEVICE="iPhone 16" examples/ci.sh
#
# Needs: Xcode, the xcmutate executable on the PATH, a checkout that has the base branch.
set -uo pipefail

BASE="${BASE:-origin/main}"
REPORTS="${REPORTS:-mutation-report}"
mkdir -p "$REPORTS"

# 1. A booted simulator, named by id (one that xcodebuild has to boot is shut down after every invocation)
UDID="$(xcrun simctl list devices available | sed -n "s/^ *${DEVICE:?} (\([0-9A-F-]*\)).*/\1/p" | tail -1)"
[ -n "$UDID" ] || { echo "no simulator named $DEVICE"; exit 64; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

# 2. The run. --time-limit keeps it inside the job's limit; the report is written in any case
xcmutate run --since "$BASE" \
  --workspace "${WORKSPACE:?}" --scheme "${SCHEME:?}" --destination "id=$UDID" \
  --select-tests reach --shared-process \
  --time-limit "${TIME_LIMIT:-45m}" \
  --work-dir "${WORK_DIR:-$PWD/.build/xcmutate-work}" \
  --no-caffeinate \
  --reporter text \
  --report "json:$REPORTS/mutation.json" --report "markdown:$REPORTS/mutation.md" --report "html:$REPORTS/mutation.html" \
  --fail-on-survived
status=$?

# 3. What the exit code means for the job
case "$status" in
  0) echo "mutation testing: every mutant on the changed lines is detected" ;;
  3|4|5) echo "mutation testing: the tests have gaps (exit code $status); see $REPORTS/mutation.md" ;;
  6) echo "mutation testing: the tests fail without any mutant" ;;
  7) echo "mutation testing: not everything could be examined (mutants could not be run, or a gate could not be confirmed); this says nothing about the tests" ;;
  *) echo "mutation testing: the run did not work (exit code $status)" ;;
esac
exit "$status"
