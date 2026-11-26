# Results, reports, gates and exit codes

## Result kinds

| Kind | Meaning | In the score |
|------|---------|--------------|
| Killed | A test failed | detected |
| Crash | The test process crashed (kept apart from Killed) | detected |
| Timeout | The run exceeded a time limit ([usage.md](usage.md#timeouts)): that of the whole run, or under `xcodebuild` the limit until the first test or the limit for one test; `detail` says which and with which numbers. A mutant that makes a test many times slower without making it endless is a Timeout as well; the process group and the test host app on the simulator are stopped | detected |
| Survived | The tests passed, and there is a record that the mutant was evaluated as active | not detected |
| NotReached | The baseline never evaluated the mutant's switch; the mutant is not run | not detected |
| CompileError | The mutant does not compile and was removed from the build | not counted |
| NotActivated | The tests passed but there is no record that the mutant was active: a fault of the tool or the test infrastructure | not counted |
| RunnerError | The run could not be judged, even after one retry. Includes a failure or timeout without an activation record, and a run whose test count differs from the baseline | not counted |
| Accepted | Listed in `xcmutate.accepted.json` and not detected | not counted |

Candidates that were never made into mutants are "ignored" and carry a reason ([operators.md](operators.md#positions-that-are-never-mutated)).

## Two scores

- Overall score (`score`) = detected / (detected + Survived + NotReached).
- Score among reached mutants (`reachedScore`) = detected / (detected + Survived). It says how well the assertions work on the code that the tests do run. The difference between the two is the code that the tests do not run.

In JSON both are ratios (`0.75`), not percentages. `--fail-under` takes a percentage.

## How a verdict is reached

Whether the tests passed or failed comes from the exit code of `xcodebuild`, the summary that `xcrun xcresulttool get test-results summary` gives for the result bundle, and the activation record. It is not read from the log of `xcodebuild`.

Text is read for three other things:

- Whether a failure is a crash. A failure in the result bundle is a crash when its message holds "crash", "unexpected exit", "signal " or "exited with". Killed and Crash both count as detected.
- When to stop a run early. A run under `xcodebuild` is stopped when the log says that the host is restarted after an unexpected exit (Crash), or when the log shows no test starting or ending for too long (Timeout). The log then also says which test was running, and whether it had already failed an assertion (Killed). See [usage.md](usage.md#timeouts).
- Known infrastructure messages in the log. They only turn a result without a verdict into a RunnerError with a reason.

- A detection requires the record that the mutant was evaluated as active. A failure or timeout without it is a RunnerError and is retried once.
- A run whose total number of tests (skipped ones included) differs from the baseline is not judged. "All tests passed" when no test or only some tests ran would be a false survivor. The exception is a crash, which legitimately stops the remaining tests: with a crash marker the verdict is Crash. The number of *skipped* tests is not compared, because a mutant may change the condition of an `XCTSkip`, and that is an effect of the mutant.
- A baseline with zero tests stops the run.
- With `--select-tests reach`, the number of tests that ran is compared with the number of tests in the selected suites.
- A failure is attributed to the mutant only after the same tests passed without mutants (`--confirm-kills`, default `auto`; [usage.md](usage.md#failures-caused-by-state-left-behind)). With one process per mutant, after a run that did not pass, the tests of the next mutant that have not passed without mutants since are run without mutants before it; in a shared process a failing run that did not come directly after such a run is repeated after one.
- With `--shared-process`, a mutant can be Killed by what the driver in the test process reports instead: its tests failed with the switch evaluated as active, directly after a passing run without mutants (or a second time after one), and the same tests then passed without it. The driver reports counts and test names in a separate file; log text is not parsed here either. A mutant can also be a Timeout there: its tests did not end within the limit with the switch evaluated as active, directly after the same tests had passed without mutants in that process (`detail` records this). Every other verdict of such a run still comes from a separate process, by the rules above ([usage.md](usage.md#running-faster)).

## Report formats

`--reporter <format>` chooses formats (repeatable). `--report <format>:<path>` writes a format to a path (repeatable; `-` is stdout), which is how several formats are written at once. Only one format can use stdout.

| Format | Default destination | Content |
|--------|---------------------|---------|
| `text` (default) | stdout; stderr when another format uses stdout | Counts, both scores, duration, score per file, excluded files, the list of gaps (Survived / NotReached) with location, change and stable key, warnings |
| `json` | `<work-dir>/report/mutation.json` (`--json-output <path>` also sets it) | Every mutant and result. Report version 2. See below |
| `agent` | stdout | JSON for AI agents, version 5. See [agent-integration.md](agent-integration.md) |
| `xcode` | stdout | `<absolute path>:<line>:<column>: warning: mutant survived: …`, which Xcode shows as warnings when the tool is called from a Run Script build phase. Nothing is written when no mutant is undetected: a line that Xcode reads as a warning needs a file and a line |
| `github` | stdout | Workflow commands for GitHub Actions: one `::warning file=…,line=…,col=…,title=…::…` per undetected mutant (Survived before NotReached), which GitHub shows on the line in a pull request. At most ten, the number that GitHub shows per step; a `::notice` says how many were left out. When no mutant is undetected (and the run was not cut short), one `::notice` says so and how many were detected. Paths are relative to `GITHUB_WORKSPACE`. Use `--report github:-` beside the other formats ([ci.md](ci.md)) |
| `markdown` | `<work-dir>/report/mutation.md` | Tables of counts, scores and files, up to 100 gaps, warnings. For a GitHub job summary: `--report markdown:$GITHUB_STEP_SUMMARY` (an existing file is appended to) |
| `stryker` | `<work-dir>/report/mutation-stryker.json` | The JSON schema of [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements) (`schemaVersion` 2), for viewers and dashboards that read it |
| `html` | `<work-dir>/report/mutation.html` | One HTML file that embeds the `stryker` JSON and shows it with the mutation-testing-elements web component. The component is loaded from a CDN (`https://www.unpkg.com/mutation-testing-elements` at a fixed version, checked with Subresource Integrity), so opening the file needs network access |

Reports are written even when a gate fails, the run is interrupted or `--time-limit` is reached.

### The JSON report

Top-level fields: `version`, `tool` (name and version), `startedAt` / `finishedAt`, `commit` (`sha`, and `dirty` for uncommitted changes), `root`, `scope`, `score`, `reachedScore`, `counts` per result kind, `durations`, `baseline`, `fileScores`, `files`, `results`, `ignored` (candidates that were not made into mutants) and `ignoredByReason`, `excluded` (files left out: `counts` per reason and `files`), `skippedFiles`, `testSelection`, `warnings`, and `interrupted`, `pendingKeys`, `resumedCount` for interrupted or resumed runs; `reuse` with `--reuse`; `acceptance` appears when accepted mutants are involved.

Each entry of `results` has `status`, `detail`, `durationSeconds`, `attempts`, `killedBy` (the failing tests) and `mutant`: the stable `key`, the numeric `id`, `file`, `start` / `end`, `operator`, `original` / `replacement`, `originalExpression` / `mutatedExpression` and `enclosingDecl`. With `--select-tests reach` an entry also has `selectedTests` and `coveredBy`.

With `--shared-process`, an entry has these fields:

- `sharedProcess` is `true` if the verdict comes from a process that ran several mutants (Killed, Timeout, or Survived with `--trust-shared-survivors`), and `false` if the mutant was run in a separate process.
- `killedBy` holds the failing tests as the driver in the test process reported them (at most 20 per unit).
- `directLaunch: true` marks a survivor that was confirmed in a new process started by the tool itself.

`durations` has `mutantPhaseSeconds` (wall-clock time of the mutant phase), `workers`, and `sharedProcess` with these counters:

| Field | Meaning |
|---|---|
| `processes`, `seconds` | The shared processes and their time |
| `killed`, `passed` | Mutants killed there, and mutants whose tests passed there |
| `alone` | Runs under `xcodebuild` |
| `trustedSurvivors` | Survivors reported without a second run (`--trust-shared-survivors`) |
| `units` | Unit-test targets × test-plan configurations |
| `directProcesses` | Shared processes started by the tool |
| `confirmedDirectly` | Survivors confirmed in a new process started by the tool; not counted in `alone` |
| `pausedAlone` | Mutants run alone while shared processes were paused |

With `--reuse` an entry that was not run has `reused: true` (always Killed; `killedBy` names the unchanged tests that killed it earlier, `detail` the run it comes from), and the report has `reuse`: `reusedCount`, `storedCount` (Killed results kept for later runs) and `refusal` (why nothing was taken over, when nothing was).

A mutant has two identifiers. The numeric `id` is only valid within one build. The stable key does not depend on line numbers; it is built from the file, the path of enclosing declarations and a hash of their signatures, the syntactic path inside the declaration, the operator, the original text of what is rewritten and the mutated text ([usage.md](usage.md#accept) says what changes it). Use the key for `--only`, `accept` and `--baseline-report`. The report records the scheme of its keys in `keyVersion` (currently 2).

More fields, by what they describe:

| Topic | Fields |
|---|---|
| What `--confirm-kills` cost | `durations.confirmation`: `controlRuns`, `controlSeconds`, `repeatedRuns`, `notConfirmed`, `runAgainAlone`. With `--select-tests reach`: `recheckedSurvivors` and `recheckedDetected` (mutants that passed their narrowed tests and were run against all selected tests, and how many of them that run detected). With `--confirm-kills full`: `detectionsRunAgainstAll` and `detectionsNotConfirmedByAll` |
| `--shared-process auto` | `durations.sharedProcessChoice`: `used` (whether shared processes were used), `mutants`, `launchSeconds`, `startupRunSeconds`, `secondRunSeconds` (when the second run at the start runs only the mutants' suites), `units` (the numbers the choice was made from) and `reason` (the choice in one sentence, also in the text report) |
| Shared processes | `durations.sharedProcess.withoutStartupRuns` (shared processes that did not repeat the two runs without mutants), `narrowedStartupRuns` (shared processes whose second run without mutants at the start ran only the suites of their mutants) and `timedOut` (mutants reported as Timeout from a shared process) |
| Results that rest on narrowed tests | `narrowedOnly: true` on a result: the verdict rests on the narrowed tests alone. On a Survived (only with `--no-recheck-survivors`), the mutant passed the tests that reach it and was not run against the others. On a Killed, Crash or Timeout (the normal case with `--select-tests reach`; not with `--confirm-kills full`), the tests that reach the mutant detected it |
| Test selection | `testSelection.skipTesting`, `testSelection.unmatchedFiles`, `testSelection.recheckSurvivors` (whether survivors of narrowed tests were rechecked), `testSelection.survivedNarrowedOnly` and `testSelection.detectedNarrowedOnly` (how many results of each kind are marked), `testSelection.detectedNarrowedOnlyShared` (how many of the latter were detected inside a shared process) |
| Compile errors | `collateral: true` on a CompileError that was removed with its whole declaration |
| Scope | The scope `files` when the files were named on the command line |
| Samples and time limits | `sampling` (`limit`, `candidates`, and `omittedKeys`: the stable keys of the mutants that were left out) when `--max-mutants` left mutants out. `timeLimitReached: true` when `--time-limit` cut the run short (`interrupted` is true as well, and `pendingKeys` lists what was not run) |

Columns in `text`, `json`, `agent`, `xcode` and `github` count UTF-8 bytes. The `stryker` and `html` formats use UTF-16 code units, as their schema requires.

### Status mapping for `stryker` and `html`

| xcmutate | mutation-testing-elements |
|---------------|---------------------------|
| Killed, Crash | `Killed` (Crash is noted in `statusReason`) |
| Timeout | `Timeout` |
| Survived | `Survived` |
| NotReached | `NoCoverage` |
| CompileError | `CompileError` |
| RunnerError, NotActivated, Accepted, ignored candidates | `Ignored` (not in the score; the reason is in `statusReason`) |
| Not run because of an interrupt | `Pending` |

## The progress file

`--progress-file <path>` writes what the run is doing while it runs, one JSON object per line ([JSON Lines](https://jsonlines.org)). A program, a CI job or a coding agent can follow it without reading the lines meant for people. The file is new for every run; with `--resume` the lines are appended. The action writes it as `progress.jsonl` next to the reports and uploads it with them.

Every line has `version` (currently 1), `event` and `time` (ISO 8601, UTC). Within a version, fields may be added; a field is not removed or given another meaning without a new version. The version is that of this file only: the report for agents (`--reporter agent`, version 5) and the JSON report (version 2) have their own.

| `event` | When | Other fields |
|---|---|---|
| `phaseStart` | A phase begins: `work copy`, `build` (again for a rebuild without mutants that do not compile), `baseline`, `mutants`, `final baseline` | `phase` |
| `phaseEnd` | A phase ends (when the next begins, or at the end of the run) | `phase`, `seconds` |
| `heartbeat` | Nothing has been printed for a minute; the same line goes to standard error (`build: still running after 3m00s (812 source files compiled so far)`) | `phase`, `seconds` (since the phase began), `hint` when something can be seen of its progress: the source files compiled so far, the tests that ended so far, the mutants that have a result, or how far a shared process is in its runs without mutants at the start |
| `mutant` | A mutant has its result | `index` and `total` (as in `[3/33]`), `id`, `key`, `file`, `line`, `operator`, `status` (as in the JSON report), `seconds`, `how` (where the verdict came from, as in the line on standard error: `shared process 1`, `alone: …`, or empty), `remainingSeconds` and `remainingReliable` (the estimate of the time left; false when it is still partly a guess, printed as "roughly") |
| `message` | Every line that the tool prints to standard error while it runs, warnings among them | `text` |
| `runEnd` | The run is over, also when it stopped early | `exitCode` ([Gates and exit codes](#gates-and-exit-codes)); `message` for an error in the options (exit code 64) |

A file that ends without `runEnd` belongs to a run that is still going, or to a process that was killed.

The heartbeat comes after a minute without any other line: often enough that a run does not look stopped (the build of a large app printed nothing else for eight minutes), and at most sixty extra lines in an hour.

## Warnings

Warnings appear on stderr, in the text report and in `warnings` of the JSON reports. Read them before the score: a run with many unevaluated mutants has a score that means little.

| Kind | Meaning |
|------|---------|
| `testSelectionFallback` | `--select-tests auto` found no test file for at least one mutated file (the message names them) and ran all tests (or `--only-testing`) |
| `reachSelectionUnavailable` | `--select-tests reach` could not attribute reach to tests with certainty; nothing was narrowed. Results are valid, the run was slower |
| `noReach` | The baseline reached no switch at all: the tests do not run the code, or the test process cannot write the trace file |
| `runnerError` | Some mutants could not be evaluated |
| `notActivated` | Some mutants passed without an activation record |
| `stateLeak` | After the run of the mutant named in the message (`key`: the mutant of the last run that did not pass), the tests failed once without mutants: that run left state behind (a file, UserDefaults, a database). The tests were run again without mutants until they passed, so the state was not counted as a detection of the next mutant; make the test clean up also when it fails. Also: the final baseline failed or ran a different number of tests (with `--confirm-kills none`, or after a mutant whose tests passed) |
| `dependentTests` | With `--select-tests reach`: the named suites do not pass when they are run by themselves without mutants, although they pass in a run of all tests (they need what other tests leave in the process). Their mutants were run against all selected tests, and no failure of these suites alone was counted as a detection. The results are valid; the run was slower for those mutants |
| `unconfirmedKill` | `--confirm-kills all`: a mutant failed once and passed when run again right after the tests had passed without mutants. It is reported as Survived |
| `sharedDestination` | Several workers run on one destination (macOS); what they detect side by side is run again alone at the end |
| `testPlanChoice` | The scheme has several test plans and `--test-plan` was not given: which `.xctestrun` file was used, and which were not |
| `sharedProcessUnavailable` | `--shared-process` was not used, with the reason (a UI test target in the selection, tests that do not pass twice in one process, test counts that do not add up to the baseline's, a driver that did not start). Results are valid; every mutant ran in a separate process |
| `directLaunchUnavailable` | With `--shared-process`, the tool stopped starting the test host itself and let `xcodebuild` start it, with the reason (the process ended or ran out of time before or during the runs without mutants, the tests did not pass, or ran in another number, in a host that the tool started), the test that had started last, the host's last output, the cause when it is a known one (tests that use `XCTContext.runActivity` where XCTest does not let the tool allow activities; a test that sent the app to the background, where a host started by the tool is suspended and ended), how the process ended according to the simulator's log, with the meaning of the termination code where Apple documents it (`0x2182bad2`: a background task did not complete in time), and the directory under `<work-dir>/logs` that holds the host's output and the launch record ([usage.md](usage.md#running-faster)). Results are valid, the run was slower |
| `reuseStore` | The results for `--reuse` could not be written; the next run takes nothing over |
| `workerDropped` | A destination (the only one, or a worker of `--workers`) was not used, or not used any further: the tests did not pass on it without mutants (at the start, or after a mutant's run, three times in a row). The message says what each of those runs showed (the tests that failed; for a run without a result, the test that was running when it ended), where the logs are, where a picture of the simulator's screen was saved, and what to check (first: a system dialog on the simulator, such as a permission request). The results that exist are valid; mutants that no destination could run are RunnerError, are not in the score, and make the run end with exit code 7 |
| `hostEndsInTests` | Two or more processes started by the tool ended without a result while a test of the same class was the last that had started. The runs were made again and the verdicts stand; the message names the class and the records kept (`logs/direct-*`, with crash reports). Look for a crash in those tests themselves or in their set-up and tear-down |
| `possibleStateLeak` | A process ended without a result directly after a mutant's run that did not pass. That run may have left data of the app on the destination (files, a database, settings). The run was made again, and no verdict depends on it; the message names the mutant |
| `acceptedButKilled` / `staleAccepted` | An accepted mutant is detected now / no longer exists. Remove it from `xcmutate.accepted.json` (the warning names the key) |
| `unknownKey` | A key given to `--only` matches no mutant. Keeps a gate from passing |
| `excludedChangedFile` | A file in the diff was excluded from mutation |
| `excludedTestCode` | A file outside the test directories imports a test framework and was excluded as test code |
| `sinceWholeFile` / `sinceUnknownPath` / `sinceNothingMutated` | `--since`: a file whose changes git hides counts as changed in every line / the diff names a path that does not exist / Swift files changed and none is mutated, with the reason |
| `skippedFile` | A file was not mutated because the tool's parser rejects it (the message says what that means). Shown on stderr and in every report. Keeps a gate from passing |
| `disableComment` | A disable comment names an unknown operator. Such a directive disables nothing. Also printed before the run |
| `config` | The config file has an unknown key |
| `interrupted` | The run was interrupted; results are partial |
| `timeLimit` | `--time-limit` was reached; results are partial, and `pendingKeys` lists the mutants that were not run. Keeps a gate from being confirmed |
| `sampled` | `--max-mutants` left mutants out: the report covers a sample, chosen by stable key |
| `survivorsNotRechecked` | `--no-recheck-survivors`: some mutants are reported as Survived after passing only the tests that reach them (`narrowedOnly`). A test that reads state left by another test could still detect them |
| `limitsNotInUse` | The limit until the first test and the limit for one test are not in use, because no output of the baseline showed when its tests start. A mutant that hangs the start of the host or one test is waited for with the limit of the whole run. The stop at the first crash is in use |

## Gates and exit codes

Without a gate option, `run` exits with 0 when it completes, whether mutants survived or not. The exception is a run in which mutants could not be run at all: it ends with exit code 7 even without a gate (below).

| Option | Fails when |
|--------|-----------|
| `--fail-on-survived` | Any mutant is not detected (Survived or NotReached; Accepted does not count) |
| `--fail-under <percent>` | The overall score is below the value (passes when there is no mutant to score) |
| `--baseline-report <earlier JSON report>` (alias `--baseline`) | A mutant is not detected now and was not among the undetected mutants (Survived, NotReached, Accepted) of the earlier report, matched by stable key. The rules are below |

`--baseline-report` suits pull requests better than a global threshold, because it fails only for new gaps. Its rules:

- Pass a JSON report produced on the main branch by a run of whole files. A report made with `--since` or `--only` is refused (exit code 64), because it knows nothing about any other mutant.
- A report of a sample (`--max-mutants`), or of a run that `--time-limit` cut short, is accepted, because it lists what it did not examine.
- Not counted as new: mutants in files that existed at the earlier report's commit and that the earlier run did not mutate (a warning says how many), and mutants whose state the earlier report does not know (not run because that run was interrupted, RunnerError, NotActivated; stderr says how many).
- Counted as new: the gaps of a file that did not exist then, or that git cannot show to have existed (no commit in the report, another repository). The gaps of a renamed file are new too, since a key holds the path.
- A file that is not a JSON report of this tool, or whose stable keys follow another scheme than the tool's (`keyVersion`), is refused with exit code 64.
- A mutant that the earlier sample left out keeps its key only while its code is unchanged. Once the code changes, it is a new mutant and counts.

Exit codes of `run`:

| Code | Meaning |
|-----:|---------|
| 0 | Completed; every mutant that was due could be run, and every requested gate passed. Also: `--time-limit` was reached and no gate was requested |
| 1 | An error that the tool did not expect (a report that cannot be written, a defect). The message says what |
| 2 | Stopped by an error of the tool or the infrastructure: the project does not build, `--prepare` failed, static verification failed, the canary failed, `--resume` was refused, the work directory is not usable or in use (`[work-dir]`), none of the `--only` keys names a mutant (`[only]`), a file cannot be read (`[read]`). stderr names the step (`[build]` …) and the log file |
| 3 | `--fail-on-survived`: undetected mutants exist |
| 4 | `--fail-under`: the score is below the threshold |
| 5 | `--baseline-report`: undetected mutants that the earlier report does not have |
| 6 | The tests fail without any mutant, or no test ran (`[baseline]`). Fix the project |
| 7 | Not everything could be examined. **With or without a gate**: mutants could not be run (RunnerError, NotActivated). **With a gate**, also: something the gate needs is missing. The details are below |
| 64 | Invalid options |
| 130 | Interrupted (Ctrl-C, SIGTERM). The reports for the finished part were written |

More on exit code 7:

- Without a gate, it means that mutants could not be run. The scores of such a report are those of the mutants that were judged. Every report shows the count beside its score: `INCOMPLETE: …` in the text report, `unevaluatedCount` in the JSON and agent reports, and the separate status `RuntimeError` in the Stryker and HTML reports.
- With a gate, it also means that the gate cannot be confirmed. The causes are mutants without a verdict (RunnerError, NotActivated), mutants removed with their whole declaration because the instrumented declaration does not compile (`collateral`), files that the parser rejects (`skippedFile`), `--only` keys that name nothing, and mutants that were not run before `--time-limit`. The message lists which.

**A gate and a sample.** With `--max-mutants` the gates look at the mutants of the sample only. A gate that fails names a real gap; a gate that passes says nothing about the mutants that were left out, and the exit code does not show the difference (the `sampled` warning and `sampling` in the report do).

**What a gate does not count.** A mutant that does not compile by itself (CompileError without `collateral`) is a property of the mutant, not a gap, and does not fail a gate. `--fail-under` passes when there is no mutant to score; that is why "nothing could be examined" has its own exit code (7) and not a pass.

When several gates fail, all are printed to stderr and the smallest code is used. `instrument` exits with 2 when static verification fails.
