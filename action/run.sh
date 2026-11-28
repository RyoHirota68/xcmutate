#!/bin/bash
# Step of the GitHub Action (action.yml): runs the tool, writes the Markdown report to the job summary, prints the
# undetected mutants as annotations, and records the exit code for the last step (so that the reports are uploaded
# before the job fails).
#
# Environment: the INPUT_* variables of action.yml, and GitHub's GITHUB_OUTPUT, GITHUB_STEP_SUMMARY,
# GITHUB_EVENT_NAME, GITHUB_BASE_REF.
set -uo pipefail

REPORTS="${INPUT_REPORT_DIRECTORY:-mutation-report}"
mkdir -p "$REPORTS"
# Reports of an earlier run in the same directory (a self-hosted runner, a restored cache) must not be taken for
# the reports of this one when this one fails before it writes any
for old in mutation.json mutation.md mutation.html progress.jsonl; do
  if [[ -e "$REPORTS/$old" ]]; then rm -f "${REPORTS:?}/$old"; fi
done
arguments=(run)

containers=0
if [[ -n "${INPUT_PROJECT:-}" ]]; then arguments+=(--project "$INPUT_PROJECT"); containers=$((containers + 1)); fi
if [[ -n "${INPUT_WORKSPACE:-}" ]]; then arguments+=(--workspace "$INPUT_WORKSPACE"); containers=$((containers + 1)); fi
if [[ -n "${INPUT_PACKAGE:-}" ]]; then arguments+=(--package "$INPUT_PACKAGE"); containers=$((containers + 1)); fi
if [[ "$containers" != 1 ]]; then
  echo "::error::give exactly one of the inputs project, workspace and package."
  echo "exit-code=64" >>"$GITHUB_OUTPUT"
  exit 0
fi
arguments+=(--scheme "$INPUT_SCHEME" --destination "${INPUT_DESTINATION:-platform=macOS}")

# The lines to look at: what the pull request changes, unless the workflow says otherwise
SINCE="${INPUT_SINCE:-}"
if [[ -z "$SINCE" && "${GITHUB_EVENT_NAME:-}" == pull_request* && -n "${GITHUB_BASE_REF:-}" ]]; then
  SINCE="origin/$GITHUB_BASE_REF"
fi
if [[ -n "$SINCE" && "$SINCE" != "none" ]]; then
  if ! git rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null; then
    # A checkout with the default depth has only the merge commit of the pull request
    branch="${SINCE#origin/}"
    git fetch --no-tags --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" || true
  fi
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    echo "::warning::the checkout is shallow: \"git diff\" against $SINCE may show more than the pull request changes. Use actions/checkout with fetch-depth: 0."
  fi
  arguments+=(--since "$SINCE")
fi

if [[ -n "${INPUT_SELECT_TESTS:-}" && "$INPUT_SELECT_TESTS" != "none" ]]; then arguments+=(--select-tests "$INPUT_SELECT_TESTS"); fi
if [[ "${INPUT_SHARED_PROCESS:-false}" == "true" ]]; then arguments+=(--shared-process); fi
if [[ "${INPUT_SHARED_PROCESS:-false}" == "auto" ]]; then arguments+=(--shared-process auto); fi
if [[ -n "${INPUT_BASELINE_REPORT:-}" ]]; then arguments+=(--baseline-report "$INPUT_BASELINE_REPORT"); fi
if [[ -n "${INPUT_FAIL_UNDER:-}" ]]; then arguments+=(--fail-under "$INPUT_FAIL_UNDER"); fi
if [[ "${INPUT_FAIL_ON_SURVIVED:-false}" == "true" ]]; then arguments+=(--fail-on-survived); fi
if [[ "${INPUT_STOP_WHEN_GATE_DECIDED:-false}" == "true" ]]; then arguments+=(--stop-when-gate-decided); fi
if [[ -n "${INPUT_PROFILE:-}" ]]; then arguments+=(--profile "$INPUT_PROFILE"); fi
if [[ -n "${INPUT_MAX_MUTANTS:-}" ]]; then arguments+=(--max-mutants "$INPUT_MAX_MUTANTS"); fi
if [[ -n "${INPUT_TIME_LIMIT:-}" ]]; then arguments+=(--time-limit "$INPUT_TIME_LIMIT"); fi
if [[ -n "${INPUT_WORK_DIR:-}" ]]; then arguments+=(--work-dir "$INPUT_WORK_DIR"); fi
if [[ -n "${INPUT_PACKAGE_CACHE:-}" && -d "${INPUT_PACKAGE_CACHE}" ]]; then arguments+=(--package-cache "$INPUT_PACKAGE_CACHE"); fi

# The progress file is uploaded with the reports: for a job that was cancelled or timed out, it shows how far the run got
arguments+=(--no-caffeinate --progress-file "$REPORTS/progress.jsonl" --reporter text --report "json:$REPORTS/mutation.json" --report "markdown:$REPORTS/mutation.md" --report "html:$REPORTS/mutation.html")
if [[ "${INPUT_ANNOTATIONS:-true}" == "true" ]]; then arguments+=(--report "github:-"); fi

# Further arguments: one per line, taken as they are (no word splitting, so values may hold spaces)
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  if [[ -n "$line" ]]; then arguments+=("$line"); fi
done <<<"${INPUT_ARGS:-}"

# Files: one per line when the input has several lines (a path may then hold spaces), otherwise separated by spaces.
# A line or word that is not the path of a file is expanded as a shell pattern.
if [[ "${INPUT_FILES:-}" == *$'\n'* ]]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    if [[ -e "$line" ]]; then
      arguments+=("$line")
    else
      matches=()
      while IFS= read -r match; do matches+=("$match"); done < <(compgen -G "$line" || true)
      if [[ ${#matches[@]} -gt 0 ]]; then arguments+=("${matches[@]}"); else arguments+=("$line"); fi
    fi
  done <<<"$INPUT_FILES"
else
  for file in ${INPUT_FILES:-}; do arguments+=("$file"); done
fi

printf 'xcmutate'; printf ' %q' "${arguments[@]}"; printf '\n'
xcmutate "${arguments[@]}"
status=$?

# The package cache is filled from the first build, for the workflow's cache step to keep
if [[ -n "${INPUT_PACKAGE_CACHE:-}" && ! -d "$INPUT_PACKAGE_CACHE" && -d "${INPUT_WORK_DIR:-}/DerivedData/SourcePackages" ]]; then
  mkdir -p "$(dirname "$INPUT_PACKAGE_CACHE")"
  cp -Rc "$INPUT_WORK_DIR/DerivedData/SourcePackages" "$INPUT_PACKAGE_CACHE" 2>/dev/null || cp -R "$INPUT_WORK_DIR/DerivedData/SourcePackages" "$INPUT_PACKAGE_CACHE" || true
fi

if [[ -f "$REPORTS/mutation.md" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$REPORTS/mutation.md" >>"$GITHUB_STEP_SUMMARY"; fi
{
  echo "exit-code=$status"
  if [[ -f "$REPORTS/mutation.json" ]]; then
    echo "report=$REPORTS/mutation.json"
    /usr/bin/python3 - "$REPORTS/mutation.json" <<'PY' || true
import json, sys
report = json.load(open(sys.argv[1]))
score = report.get("score")
print("score=" + ("" if score is None else f"{score:.4f}"))
print("undetected=" + str(sum(1 for result in report.get("results", []) if result["status"] in ("Survived", "NotReached"))))
PY
  fi
} >>"$GITHUB_OUTPUT"
exit 0
