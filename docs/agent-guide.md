# xcmutate: guide for coding agents

You are asked to find and close the gaps in the tests of a Swift / Xcode project with xcmutate. This guide is the full procedure. `xcmutate agent-guide` prints it for the installed version of the tool.

xcmutate makes mutants: copies of the code with one small change each. It runs the tests against each mutant. A mutant that no test detects is a gap. Close gaps by writing tests, one function at a time, and report what is left.

## Rules

Keep these throughout. When a rule and a step seem to conflict, the rule wins.

- Do not change production code. If you find a real bug, do not fix it: report it and ask.
- Do not write a test that pins behavior which may be wrong. If the code disagrees with its comment, its documentation or its callers, report that and ask (step 5).
- Do not delete, skip or weaken existing tests.
- Do not run `xcmutate accept` on your own. Show the user the candidate and your reason, and ask.
- Do not start a run that you expect to take more than 15 minutes without asking first.
- Do not create, erase or delete simulators. Use the one the user names. Do not add `--workers` unless the user agrees.
- Do not add `--no-recheck-survivors`, `--trust-shared-survivors` or `--confirm-kills none`. They trade correct results for speed.
- Do not commit, push or open a pull request unless the user asked for it.

## 1. Find out how to run the project

Look for instructions first (`CLAUDE.md`, `AGENTS.md`, the README, a CI workflow that calls `xcodebuild` or `xcmutate`) and use what they say. Otherwise find out:

1. What kind of project it is. A `Package.swift` at the root: `--package .`. An `.xcworkspace`: `--workspace <path>`. Only an `.xcodeproj`: `--project <path>`. Exactly one of the three is required.
2. The scheme. Run `xcodebuild -list` (in the package directory, or with `-workspace` / `-project`). For a package it is usually the product's name when the package declares exactly one product, and `<package name>-Package` otherwise. A line `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.` in its output is harmless.
3. The destination.
   - Code that does not need iOS (a package, a framework without UIKit): `--destination 'platform=macOS'`.
   - An app, or tests hosted by an app: an iOS simulator, as `--destination 'id=<UDID>'`. Ask the user which simulator to use. It must be booted before the run (`xcrun simctl boot <UDID>`); ask before you boot one.
4. The unit-test target. UI tests are not supported. If the scheme has a UI test target, leave it out with `--only-testing <UnitTestTarget>`.
5. The base of the diff: the branch this work will be merged into, usually `origin/main` or `origin/develop`. If the repository has no remote, use the local branch (`main`).
6. Whether the project needs a step before it builds (for example `xcodegen generate`). If so, pass it as `--prepare '<command>'`. Files that git ignores are not in the tool's work copy; create them in `--prepare` too.

If you cannot decide one of these, ask the user. Do not guess a simulator or a scheme.

If the repository has no config file (`xcmutate.yml`, or `xcmutate.config.json` of an earlier version) with a `run` object or `profiles` yet, and the user agrees to a few minutes of trial runs, run `xcmutate init --yes` once before the first run (with `--destination 'id=<UDID>'` for an app on a simulator, and `--scheme` if there are several). It builds, tries a sample of mutants in the default and the faster modes, and writes the options it found to be safe and fastest, with the reasons as comments. Then use `--profile pr` in the commands below, and leave out the options that the profile holds. It never writes a gate or an option that makes verdicts weaker. If the file already has run options, or is `xcmutate.config.json` (which `--force` would replace with `xcmutate.yml`), `init` writes nothing and shows what it would write; do not pass `--force` without asking.

## 2. Estimate before you run

Count the mutants of the change:

```sh
xcmutate list --since <base>
```

Without file arguments, `list --since` looks at the files that `run --since` would mutate. Uncommitted changes count. Give `list` the same `--package` as the run: with a subdirectory (`--package Shop`), both look only at the files below it. The last line gives the totals (`16 mutants, 1 ignored, 3 files`). If it says 0 mutants, tell the user that the change has no code that the tool mutates, and stop.

"Ignored" candidates are places that the tool deliberately does not mutate (for example a call that is the return value of its function). They are not gaps. `xcmutate list --since <base> --show-ignored` shows them with the reason, and so does `ignored[]` in `agent.json`.

Estimate the time as mutants × time per mutant, plus the build and two runs of all tests:

| Tests | Time per mutant, default mode |
|---|---|
| A package on macOS, tests under a second | about 2 to 4 s |
| Unit tests hosted by an app on a simulator, tests under a second | about 5 to 11 s |
| A test run that takes longer | at least the time of one run of the tests |

The times include the extra run that follows each detected mutant.

If the estimate is 15 minutes or less, go on without asking, and put the count and the estimate in your final report. If it is more, tell the user the count and the estimate, offer the options of step 3, and wait for an answer.

## 3. The first run

```sh
OUT="$(mktemp -d -t xcmutate)"
xcmutate run --since <base> \
  <--package . | --workspace X.xcworkspace | --project X.xcodeproj> --scheme <scheme> \
  --destination '<destination>' \
  [--only-testing <UnitTestTarget>] \
  --max-mutants 50 --time-limit 20m \
  --reporter agent --json-output "$OUT/report.json" \
  --progress-file "$OUT/progress.jsonl" \
  > "$OUT/agent.json"
```

- `--since <base>` limits the run to the lines changed since the merge base with `<base>`. Uncommitted changes and untracked files count.
- `--max-mutants 50` and `--time-limit 20m` bound the first run. With more than 50 mutants the tool examines a sample; the report says how many were left out. When the time is up the tool stops and reports what it has; `pendingCount` says how many were not run.
- `agent.json` is the report you read: the gaps, and the result of every mutant by key (`results[]`). `report.json` is the full report; `accept` reads it in step 7. Progress goes to standard error.
- The tool works on a copy of the repository and does not modify the working tree.
- `progress.jsonl` says how far the run is, one JSON object per line. If you expect the run to take more than a few minutes and can run it in the background, do so, and read the last lines of the file every few minutes. Tell the user the phase (`phaseStart`: build, baseline, mutants), how many mutants have a result (`index` and `total` of the last `mutant` line) and the time left (`remainingSeconds`). A `heartbeat` line comes when nothing else has happened for a minute; its `hint` says how far a long build or baseline is. The run is over when a `runEnd` line with `exitCode` is there; then read `agent.json`.

To make a long run shorter, in this order:

1. Name fewer tests: `--only-testing <Target>/<Class>`.
2. Add `--shared-process`: many mutants run in one test process. If it cannot be used, a warning says why and the run goes on without it.
3. If one run of all tests takes more than a few seconds, add `--select-tests reach --shared-process`: each mutant runs only the suites that execute it.

When a run takes minutes, add `--reuse` to it and to the later runs: mutants that were already killed are not run again. Make the last run before your report without it.

## 4. Read the result

Check the exit code first.

| Exit code | Meaning | What to do |
|---|---|---|
| 0 | The run completed | Read the report |
| 2 | The tool or the build failed (`[build]`, `[work-dir]`, `[only]`, …) | Read the message and the log it names. Fix the command, or report the problem |
| 3, 4, 5 | A gate failed | These appear only if you passed a gate option (`--fail-on-survived`, `--fail-under`, `--baseline-report`) |
| 6 | The tests fail, or none ran, without any mutant | Stop. Report the failing tests. Do not go on until the tests pass |
| 7 | Some mutants could not be run | Read the `workerDropped` and `runnerError` warnings. This says nothing about the tests. Usually the simulator is the cause; report it |
| 64 | The options are wrong | Read the message and fix the command |
| 130 | Interrupted | The report covers what finished. `--resume` with the same options continues |

Then read `warnings`, `unevaluatedCount`, `interrupted` and `pendingCount` in `agent.json` before the gaps. A report with mutants that were not judged is incomplete; say so in your report.

| Warning | What it means for you |
|---|---|
| `workerDropped`, `runnerError` | Mutants could not be run. Report what the message says (often a system dialog on the simulator) |
| `stateLeak`, `dependentTests` | A test leaves state behind, or needs another suite to run first. Results are valid; name the test in your report |
| `testSelectionFallback`, `reachSelectionUnavailable`, `sharedProcessUnavailable`, `directLaunchUnavailable` | A faster mode was not used. The run was slower; the results are valid |
| `sampled`, `timeLimit` | The report covers part of the mutants. Say how many were left out |
| `unknownKey` | A key given to `--only` no longer exists, because the code it names changed (step 6) |
| `noReach` | No test runs any of the changed code (or the test process could not write its record). Every gap is `notReached`. Check that the tests you selected are the ones for this code |
| `excludedChangedFile`, `skippedFile` | A changed product file was not mutated. Report it; do not treat the file as covered |

Test files and the package manifest are never mutated; that needs no report.

The gaps are in `scopes[]`, one entry per function:

| Field | Content |
|---|---|
| `file`, `startLine`, `endLine`, `source` | The function, with its source |
| `gaps[].key` | The stable key of the mutant. Use it with `--only` |
| `gaps[].gap` | `notReached`: no test runs this code. `notDetected`: tests run it and still pass |
| `gaps[].line`, `column`, `mutator`, `original`, `replacement` | The change |
| `gaps[].coveredBy` | With `--select-tests reach`: the tests that run this code |
| `obligations[<mutator>]` | What a test must tell apart to detect this kind of change |
| `counts` | How many mutants had each result |
| `results[]` | `key` and `status` of every mutant of the run |
| `score`, `reachedScore` | Ratios between 0 and 1. Accepted mutants are not counted in them |

## 5. Close the gaps

Work function by function. Read the function, its comments and its existing tests.

**Before you write a test, decide which is right: the code as it is, or the mutant.** A surviving mutant is sometimes the correct version. If a comment, the documentation, the name of the function or its callers say what the mutant does (the comment says "100 or more" and the code tests `> 100`), the code may have a bug. Do not write a test that fixes the current behavior in place. Report the disagreement and ask.

Otherwise:

- `notReached`: add a test that executes the code. Do this first; the other gaps of the function then become `notDetected` or disappear.
- `notDetected`: read `obligations[<mutator>]`. Add the input it describes, or make an existing assertion stricter. For `boundary`, use the boundary value itself as an input.

Write new tests in the same file and style as the existing ones. Tests you write must:

- assert behavior that a caller can observe (a return value, a thrown error, a change of state). Do not assert private state or the order of internal calls;
- fail on the mutated code and pass on the original;
- be named after the behavior, not after the mutant;
- clean up only what they created.

## 6. Check each gap again

```sh
xcmutate run <--package … | --workspace … | --project …> --scheme <scheme> --destination '<destination>' \
  --reporter agent --only '<key>' --only '<key>' > "$OUT/recheck.json"
```

`--since` is not needed here: the keys select the mutants.

The result of each key is in `results[]` of `recheck.json` (`key`, `status`). A gap is closed when its status is `Killed`, `Crash` or `Timeout`; its key is then gone from `scopes[].gaps[]` as well. Do not match mutants by the `#<number>` of the progress lines: the numbers change from run to run.

If a gap is still there, the test does not tell the two versions apart. Change the input or the assertion instead of adding similar tests.

A key names the code as it was. After that product code has changed, the key no longer exists: the run warns `unknownKey`, and stops with exit code 2 when none of the keys exists. The gap is not closed by that. Run step 3 again to get the current gaps and keys.

## 7. Mutants that no test can detect

Some mutants are equivalent: no input tells them apart from the original. Example: `>` changed to `>=` where both branches return the same value when the sides are equal.

Do not write a test that pins an implementation detail to kill such a mutant. List it in your report with the key and the reason why no input can observe the change, and ask the user. If the user agrees:

```sh
xcmutate accept '<key>' --reason "<why no input can observe it>" --report "$OUT/report.json"
```

This writes `xcmutate.accepted.json` at the root of the repository, a file meant to be committed. To check that it took effect, run step 3 again: `counts` shows `Accepted`, and the key is gone from the gaps. The mutant is still run, and its progress line says `Survived (accepted)`. An accepted mutant is left out of the score, so say "N accepted" beside any score you report.

If you are not sure that a mutant is equivalent, report it as undecided.

## 8. Finish

Before you report, and also before you stop to ask a question, run step 3 once more without `--reuse`, so that the numbers you give are current. After the user has answered, run it again only if code or tests changed since.

Report, in this order:

1. The run: the command, how many mutants (and how many ignored), the estimate and how long it took, and whether the report was complete (sampled, cut short, mutants not run).
2. Gaps closed, with the tests you added or changed (file and test name).
3. Gaps left, each with its location and why it is left.
4. Places where the code and its comment or documentation disagree. You did not write tests for them and did not fix them.
5. Mutants you believe are equivalent, each with the key and the reason. Ask whether to accept them.
6. Warnings that the user should act on.
7. What the score covers. It counts only the mutants that the tool makes. Some kinds of change are off by default, among them arithmetic operators (`+`, `-`, `*`, `/`), so a changed line without a mutant has not been shown to be tested. Name such lines if the change has them.

Tell the user that `xcmutate clean` removes the tool's work directory. Do not run it yourself.
