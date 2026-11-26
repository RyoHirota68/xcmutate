# Changelog

Notable changes to xcmutate. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change options and report formats; such changes are listed under "Changed".

<!-- Releasing: replace "Unreleased" in the heading of the version being released with the date of the tag (YYYY-MM-DD). New work goes into a "## [Unreleased]" section above the latest version. -->

## [0.14.0] - 2026-11-26

### Added

- `list --package <dir>`: the same narrowing as `run --package <dir>`, so that `list --since` counts the mutants that the run will make. Without the option `list` behaves as before.
- `--shared-process auto` (and `shared-process: auto` in the action): after the baseline, the tool uses shared processes only when the launches that the mutants would save are at least what the start of a shared process costs (a launch and two runs of the tests per unit). The run, the text report and `durations.sharedProcessChoice` in the JSON report say which it chose and why. `--resume` keeps the choice. The default is unchanged ([speed.md](docs/speed.md#letting-the-tool-decide---shared-process-auto)).
- A heartbeat: when a phase prints nothing for a minute (the build, the baseline, a shared process in its runs without mutants at the start, a long run of one mutant), one line says which phase is still running, for how long, and how far it has got where a log shows it (source files compiled, tests ended, mutants with a result). The build of a large app had printed nothing else for eight minutes.
- `--progress-file <path>`: the progress of the run as JSON Lines (version 1): phases, heartbeats, every printed line, every mutant's result with the estimate of the time left, and the exit code at the end. The action writes it as `progress.jsonl` with the reports and uploads it with them. The guide for agents tells the agent to follow it in a long run ([reports.md](docs/reports.md#the-progress-file)).
- With one process per mutant, the run says at the end when the runs without mutants after failing runs took 30% or more of the mutant phase, and that `--shared-process` makes these runs inside the process.

### Fixed

- A mutant that made the host end with an uncaught exception could be a Timeout when, on a busy Mac, `xcodebuild` had not yet said that it restarts the host and no crash report was written in time. The host's own line `*** Terminating app due to uncaught exception` in the log now makes such a run a Crash, when the line carries the host's name and process ID and no test started or ended after it; the result's detail quotes the line. Lines that do not name the process (Swift's `Fatal error:`, `libc++abi:`), which a process that a test starts can also write to the log, are not taken.
- A host that the tool started for `--shared-process` and that a test sent to the background (by opening another app or a URL) was ended by the system after about 30 seconds when a background task was in progress (termination code `0x2182bad2`), and the warning said only that `simctl` does not say how the app ended. Under `xcodebuild` such a host keeps running. The driver now writes down when the app goes to the background and which test was running; a process that ends there makes the tool go back to `xcodebuild`, also after the runs at the start of the process, and the warning names the test and the cause. The launch record keeps the simulator's log lines about the process's visibility and runningboardd's reason, and termination codes that Apple documents are explained.
- The estimate of the remaining time with `--shared-process` said "roughly 0s left" while the first shared process was running, and then jumped to many minutes. It now counts the time of a process that is still running, its start and its runs without mutants included.

### Changed

- `--select-tests reach --shared-process`: the second of the two runs without mutants at the start of a shared process runs only the suites that the process's mutants reach; the first still runs every selected test and is what is compared with the baseline. The run says so for each such process, and `durations.sharedProcess.narrowedStartupRuns` counts them. `--no-narrow-gate` makes both runs of all tests, as before. On an app with 6,900 tests (87 s) and one file whose mutants about 45 tests reach, this halves the start of a shared process. A suite outside the mutants' suites that changes how often a switch is evaluated sends the mutant to a separate process, as before (`Fixtures/Regression/OnceOutsideGate`).
- `--reporter github` writes one `::notice` when no mutant is undetected, instead of nothing. The `xcode` format still writes nothing then.
- The report for agents gives `fixes` only for the kinds of gap that it holds; with every mutant detected, `fixes` is empty.
- `--package` with a subdirectory of the repository limits the default files to mutate to that directory, with and without `--since` (when neither `--root` nor file arguments are given). The root stays the top of the repository, so paths, stable keys, the accepted file, the config file and the work directory do not change. The action's `package` input does the same.

## [0.13.0] - 2026-11-24

The first public version.

### What it does

- Mutation testing of a diff. `run --since <ref>` mutates the lines changed since a git ref and reports every mutant that no test detects, as NotReached (no test runs the code) or Survived (tests run it and still pass).
- One build for all mutants. Mutants are embedded as runtime switches, in a copy of the repository. `run` does not modify the working tree.
- Xcode projects, workspaces and Swift packages, through `xcodebuild`: app-hosted unit tests on an iOS simulator and tests on macOS, with XCTest and Swift Testing.
- 27 mutation operators, 19 of them on by default. The defaults follow a rule that was applied to measurements on public packages.
- Verdicts that need evidence. A mutant is reported as Survived only with a record that it was switched on and a full test count. It is reported as Killed only if the same tests have passed without mutants since the last failing run. Mutants that could not be judged are reported as such and are not counted.
- Test selection. `--only-testing`, `--select-tests auto` (by naming convention) and `--select-tests reach` (by the suites that executed each mutant, with a recheck of survivors against all selected tests).
- Faster modes, off by default. `--shared-process` (several mutants per test process), `--workers` (several destinations at once) and `--reuse` (skip mutants that an earlier run killed).
- Reports: text, JSON, a compact JSON for coding agents, Markdown, HTML, the mutation-testing-elements schema, and warnings for Xcode and for GitHub Actions.
- Gates and exit codes for CI: `--fail-on-survived`, `--fail-under`, `--baseline-report` ("no new gaps"), `--time-limit` and `--max-mutants`.
- Interrupting and resuming a run (`--resume`), and recording equivalent mutants with a reason (`accept`).
- A GitHub Action, example workflows and a shell script for CI, and a procedure for coding agents that runs the loop "find gaps, write tests, re-check". `agent-guide` prints it, and `agent-guide --install` writes a Claude Code skill, a Codex skill or a section in `AGENTS.md` so that the agent finds it by itself.

### Known limits

- Runs were verified with Xcode 27.2 (macOS and an iOS simulator) and with Xcode 26.6 (a Swift package on macOS, and a small iOS app on a simulator). The prebuilt binary is built with Xcode 26.6 and was checked under both. Building from source needs Swift 6.3 or newer (checked with Xcode 26.6 and 27.2).
- UI tests are not supported.
- By default every mutant costs one launch of the test host. The faster modes are opt-in.
- Not tested: the x86_64 half of the release binary on a project (it was only started under Rosetta), and parts of the action on GitHub (`baseline-report`, `package-cache`, and the example workflows as they are written).

[docs/limitations.md](docs/limitations.md) lists all limitations, what is not verified yet, and the known issues.
