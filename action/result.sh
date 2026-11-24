#!/bin/bash
# Last step of the GitHub Action (action.yml): turns the tool's exit code into the result of the job, with a
# line that says what the code means. Environment: EXIT_CODE.
set -uo pipefail
code="${EXIT_CODE:-2}"
case "$code" in
  0) echo "xcmutate: finished; every requested gate passed."; exit 0 ;;
  3) echo "::error::xcmutate: mutants were not detected (--fail-on-survived). The job summary lists them." ;;
  4) echo "::error::xcmutate: the mutation score is below the threshold (--fail-under)." ;;
  5) echo "::error::xcmutate: there are undetected mutants that the baseline report does not have (--baseline-report)." ;;
  6) echo "::error::xcmutate: the tests fail without any mutant, or no test ran. Fix the tests or the selection first." ;;
  7) echo "::error::xcmutate: not everything could be examined: mutants could not be run (the report says how many, and the workerDropped warning why), or a gate was requested and mutants were not run before the time limit. This is not a statement about the tests." ;;
  64) echo "::error::xcmutate: the options are wrong (see the log of the run step)." ;;
  130) echo "::error::xcmutate: the run was interrupted." ;;
  *) echo "::error::xcmutate: the run itself did not work (exit code $code): build, simulator or the tool. See the log of the run step." ;;
esac
exit "$code"
