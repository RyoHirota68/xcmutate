# How the tool is verified

A wrong verdict of a mutation testing tool does not show in the score, so the verdicts have to be checked some other way. This page lists what the verdicts of xcmutate are checked against, what kinds of wrong results were found on the way, and what has not been verified. The mechanisms themselves are described in [how-it-works.md](how-it-works.md#self-checks).

Everything here refers to version 0.13.0, checked with Xcode 27.2 on an iOS 27.2 simulator and on macOS 27.0.

## What each verdict needs

A mutation testing tool can report *Survived* for a mutant that was never really tested: the switch did not reach the test process, fewer tests ran, or the tests that would have failed were not selected. It can report *Killed* for a mutant whose tests failed for another reason, such as a file left behind by the previous mutant. Either mistake makes the report useless, and the score does not show it. So the tool gives no verdict without evidence for it.

| Verdict or mode | What is required | What changes it |
|---|---|---|
| Survived | A record that the mutant was switched on while the tests ran, and a run that executed as many tests as the baseline. Without them the result is an error | Nothing |
| Killed | The same tests have passed with every mutant off since the last failing run on that destination | `--confirm-kills` (below) |
| Killed with `--confirm-kills restore` (not the default) | Instead of a run without mutants after a failing run, the app's containers and the simulator's keychain are put back to a copy taken right before the baseline, and what the copy does not cover (keychain by access group, pasteboard, privacy permissions, the app's notifications, other apps' App Groups, the records of Photos, Contacts and Calendar) must equal the copy's; otherwise the tests are run as with `auto`. It rests on two assumptions that are not checked: the tests depend on nothing outside the simulator, and give the same result from the same state | Use `auto` when either assumption does not hold |
| Survived with `--select-tests reach` | A mutant that passes the suites that execute it is run against all selected tests before it is reported as Survived | `--no-recheck-survivors` skips that run; such survivors are marked in every report and can be false |
| Killed with `--select-tests reach` | The suites that reach the mutant detect it. The report marks such results (`narrowedOnly`), because state of another suite can hide a mutant in a run of all tests | `--confirm-kills full` also runs them against all selected tests, and that run decides |
| Any result with `--only-testing` or `--select-tests auto` | The result holds among the selected tests only: a test that was not selected might still reach or detect the mutant. The report states that | Nothing |
| Survived with `--shared-process` | A mutant whose tests pass in a process that ran several mutants is confirmed in a new process | `--trust-shared-survivors` skips the confirmation |
| A mutant that could not be judged | It is reported as RunnerError or NotActivated and is not counted. Every report shows the number, and the run ends with exit code 7, with or without a gate | Nothing |

`--confirm-kills` has five levels:

- `auto` (the default): after a run that did not pass, the next mutant's tests are run once with all mutants off before the mutant. This does not cover state that a *passing* run leaves behind.
- `all`: as `auto`, and a failure that follows another mutant's passing run is repeated after a run without mutants. It must fail again. This covers state left by a passing run.
- `full`: as `auto`, and with `--select-tests reach` every mutant that its narrowed tests detect is run once more against all selected tests.
- `restore`: as `auto`, but on an iOS simulator with app-hosted tests the run without mutants after a failing run is replaced by putting back a copy of the destination (the table above). The final baseline and the run of all tests that rechecks a survivor are still made.
- `none`: a failing run counts as it is. State left by one mutant can then be reported as a detection of the next.

[usage.md](usage.md#failures-caused-by-state-left-behind) describes the levels for each mode of running, and [usage.md](usage.md#selecting-tests) the test selection.

Whether tests passed or failed is taken from the exit code of `xcodebuild`, the result bundle and the activation record. It is not read from log text. The log is read only to decide when to stop a run early and which test was running then ([reports.md](reports.md#how-a-verdict-is-reached)).

## A fixture app with an expected result for every mutant

`Fixtures/SampleApp` is an iOS app made of small cases. Each case was written to produce a known result, and `expected.json` records that result before the tool runs. There are 464 expectations:

| Expectation | Count |
|---|---:|
| Mutants with an expected verdict | 403 |
| …Killed (crashes included) | 326 |
| …Survived | 47 |
| …NotReached | 24 |
| …Timeout | 4 |
| …CompileError | 2 |
| Candidates that must be ignored, each with its reason | 61 |

`scripts/verify-fixture.sh` runs every mutant and compares each result with its expectation. It also compares the number of builds, the excluded files and the kinds of warnings. A result without an expectation fails the check.

The check passes in each of these modes (464 of 464):

- one process per mutant (the default);
- `--shared-process`;
- `--select-tests reach`;
- `--select-tests reach --shared-process`;
- `--shared-process --workers 2`.

A second fixture covers two unit-test targets in a test plan with two configurations (15 expectations, in the default mode and with `--shared-process`).

## The faster modes are compared with the default, mutant by mutant

The default mode gives every mutant a clean process. It is the reference. `scripts/compare-reports.py` compares the report of each faster mode with it, one mutant at a time. For the fixture, all 403 mutants have the same verdict in all four comparisons.

The same comparison was made on the sample projects that ship with [Muter](https://github.com/muter-mutation-testing/muter) and on a large production iOS app (below).

## Reproductions of the wrong results that were found

Reviews and adversarial tests of the tool found wrong results of the following kinds. Each one is now a small Swift package in `Fixtures/Regression` with its own expected verdicts, and `scripts/verify-regressions.sh` runs them all (one process per mutant, `--shared-process`, `--workers`).

| Kind of problem | What went wrong before the fix | Reproduction |
|---|---|---|
| State left behind by a failing run | A file that one mutant's run left behind failed the next mutant's tests, which was reported as Killed | `StateLeak`, `LeftoverElsewhere` |
| State left inside a shared process | A singleton that one mutant no longer emptied failed the next mutant's tests | `SharedState` |
| Workers on one Mac | Two test processes that ran side by side failed each other | `SharedState` with `--workers` |
| Narrowed tests miss the detecting test | A mutant passed the suites that run its code, while a test of another suite would have failed on state left in the process: a false Survived | `StateAcrossSuites` |
| State of another suite hides a mutant | Narrowed tests detect a mutant that a run of all tests does not | `HiddenByOtherSuite` |
| A suite that needs another suite | A suite that only passes after another suite failed with or without the mutant when run by itself: a false Killed | `DependentSuites` |
| Code dropped from the run | Shapes of Swift code that did not compile once instrumented, or that were taken for test code, were silently left out | `Shapes` |

`scripts/verify-fixture-guards.sh` puts the same shapes on an iOS simulator, together with mutants that crash the host several times in a row and a loop that never ends. All 26 expected verdicts match in each of ten modes.

Not every finding led to a change in behavior. Two are documented limits instead: a crash is recognized by words in the failure message ([reports.md](reports.md#how-a-verdict-is-reached)), and a file that the parser rejects is named and fails a gate but is not mutated ([operators.md](operators.md#positions-that-are-never-mutated)).

## Mechanical checks of the instrumentation

Embedding mutants must not change what the program does while every mutant is off.

- Unit tests compile and run small programs with `swiftc`. With all mutants off, the output must equal the original's. With one mutant on, it must equal the output of the source with that change written in.
- `scripts/verify-generated-programs.sh` does the same for 30 generated programs.
- `scripts/verify-public-corpus.sh` instruments about 500 files from four public repositories at fixed commits and type-checks two of them as whole modules.

## Muter's verification data

`scripts/verify-muter-fixtures.sh` fetches Muter at a fixed commit and runs its mutation examples and sample projects through xcmutate.

- Of the 27 mutants that Muter's unit tests expect, xcmutate makes 24 at the same position. The other 3 are intended differences.
- Of the 105 mutants in Muter's regression snapshots, xcmutate makes 102. For 99 of them the result (detected or not) is the same. The 3 that differ are rewritten differently by the two tools (`>` becomes `<` in Muter and `>=` here).

## The tool on its own source

`scripts/self-mutation.sh` runs xcmutate on the files of its own source that decide verdicts, against its own unit tests. The last full run was made with a development version shortly before 0.13.0: 256 mutants were judged and 235 detected (91.8%). No survivor was left in the files that turn an observation into a verdict, read the config file, or decide which tests must pass before a mutant runs. For version 0.13.0 the run covered the lines changed since: 105 mutants, 81 detected. Tests were added for four of the nine survivors; the other five are equivalent or change nothing a reader of the report can see.

## A large production iOS app

The tool was run repeatedly on a large production iOS app while it was developed: first on two files, later on eight files with about 200 mutants and about 1,200 tests in the selection.

- With an earlier development version, `--shared-process` was compared with one process per mutant on those eight files. Every mutant was detected, or not, in both. A few detections had different names (Crash in one, Killed in the other).
- With version 0.13.0 the eight files were run four times with `--select-tests reach --shared-process`. Every mutant was detected, or not, exactly as in that earlier run, in all four. Once, a mutant was a Timeout where it had been a Crash.
- None of the mutants that passed their narrowed tests was detected by the run against all tests that follows.

The times of these runs are in [speed.md](speed.md#a-large-production-app).

## What has not been verified

[limitations.md](limitations.md#not-yet-verified) lists what has not been tried (toolchains, platforms, Homebrew, most of the GitHub Action, the speed of `--workers`) and the two known issues.
