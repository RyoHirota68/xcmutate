# Usage reference

This page describes every subcommand and option. If you are new to the tool, start with [getting-started.md](getting-started.md). All examples assume that the executable is on your `PATH` as `xcmutate` ([install.md](install.md)). `xcmutate <subcommand> --help` also describes every option.

| Subcommand | Purpose |
|------------|---------|
| [`run`](#run) | Run mutation testing: build once, then test once per mutant |
| [`accept`](#accept) | Record equivalent mutants in `xcmutate.accepted.json` |
| [`clean`](#clean) | Remove work directories |
| [`list`](#list-and-instrument) | List mutants and ignored candidates without writing files |
| [`instrument`](#list-and-instrument) | Only embed the mutants into source files |
| [`agent-guide`](#agent-guide) | Print the procedure for coding agents |

## Glossary

| Term | Meaning |
|---|---|
| Mutant | A copy of the code with one mechanical change, for example `>` turned into `>=` |
| Operator | One kind of change (`boundary`, `guard-removal`, …). The JSON report calls it `operator`; the report for agents calls it `mutator` |
| Switch | The code that the tool embeds for a mutant: `isOn(3) ? mutated : original`. All switches are off unless a run turns one on |
| Baseline | A run of the tests with every mutant off. It must pass, and it records which switches the tests evaluate |
| Reached | A mutant is reached when the baseline evaluated its switch, that is, when some test ran the code. A mutant that is not reached is not run (NotReached) |
| Detected | Killed, Crash or Timeout: the tests noticed the mutant |
| Selection, selected tests | The tests that the run uses: all tests of the scheme, or what `--only-testing`, `--skip-testing` and `--select-tests auto` leave of them |
| Narrowed tests | With `--select-tests reach`: for one mutant, only the suites whose tests reached it |
| Suite | An XCTest class, or an outermost Swift Testing suite |
| Shared process | With `--shared-process`: one test process that runs several mutants one after another |
| Separate process | A test process that runs one mutant only. The progress lines call such a run `alone` |
| Driver | A small test bundle of the tool that runs your tests inside a shared process |
| Unit | One unit-test target in one test-plan configuration. A shared process serves one unit |
| Recheck | With `--select-tests reach`: the run against all selected tests that a mutant gets after it passed its narrowed tests |
| Canary | The first mutant of a run. If no record arrives that it was switched on, the run stops |
| Stable key | The identifier of a mutant that does not depend on line numbers. Used with `--only` and `accept` |
| Work directory, work copy | The directory outside your repository where the tool keeps its copy of the sources (the work copy), the build and the reports |

## run

```bash
# Mutants on the lines changed since the merge base with origin/main, on one simulator
xcmutate run --since origin/main \
  --project App.xcodeproj --scheme App \
  --destination 'id=<SIMULATOR-UDID>' \
  --only-testing AppTests \
  --reporter text --reporter json

# A SwiftPM package on macOS
xcmutate run --package . --scheme MyPackage --destination 'platform=macOS'

# Re-run chosen mutants only (keys come from a report)
xcmutate run --workspace App.xcworkspace --scheme App --destination 'id=<SIMULATOR-UDID>' \
  --only 'Sources/Cart.swift::Cart.total(of:)::boundary::3b1155b105444109'
```

`--destination` and exactly one of `--project`, `--workspace` or `--package` are required. `--package` also requires `--scheme`; with a project or workspace you will want `--scheme` as well. `run` copies the files that git knows. Outside a git repository, name the Swift files to mutate as arguments.

Three things to do before a run on a simulator:

- Name the simulator by id (`id=<UDID>`, from `xcrun simctl list devices`). The tool does not choose, boot or shut down the simulator you name.
- **Boot the simulator first and leave it running: `xcrun simctl boot <UDID>`.** A simulator that `xcodebuild` has to boot itself is shut down again when the test run ends, so every mutant then includes a boot: about 26 s per mutant instead of about 5 s on the fixture. `run` warns when the simulator it was given is not booted.
- **Grant on the simulator what the app asks for.** On a new simulator, the first use of the camera, of notifications or of the location makes the system show a dialog over the app, and the tests wait behind it. The tool then sees its runs without mutants fail, gives the destination up after three of them, and the remaining mutants are not run. Grant the permissions beforehand: `xcrun simctl privacy <UDID> grant camera <bundle id>`.


### Run options in the config file: `run` and `profiles`

The config file `xcmutate.yml` (YAML, at the root; [configuration.md](configuration.md) has its other keys) can hold the options of `run`: those under `run` apply to every run, those under `profiles.<name>` with `run --profile <name>`. The command line wins over the profile, the profile over `run`, `run` over the defaults; an option given on the command line replaces the file's value of that key (all values of a repeatable one). `xcmutate init` writes such a file, with the reason for each choice as a comment.

```yaml
run:
  workspace: App.xcworkspace
  scheme: App
  destination: "platform=iOS Simulator,name=iPhone 17,OS=27.2"
  onlyTesting: [AppTests]       # UI test targets are not supported
profiles:
  pr:
    since: origin/main
    selectTests: reach
    sharedProcess: auto
    failOnSurvived: true
    stopWhenGateDecided: true
  nightly:
    selectTests: reach
    sharedProcess: true
    writeImpactMap: .build/xcmutate/impact.json
    timeLimit: 3h
```

| Key | Option | Value |
|---|---|---|
| `workspace / project / package` | [`--workspace / --project / --package`](#options) | string |
| `scheme` | [`--scheme`](#options) | string |
| `destination` | [`--destination`](#options) | string or list of strings |
| `testPlan` | [`--test-plan`](#options) | string |
| `onlyTesting / skipTesting` | [`--only-testing / --skip-testing`](#--only-testing) | string or list |
| `onlyTestConfiguration` | [`--only-test-configuration`](#options) | string or list |
| `buildArg` | [`--build-arg`](#options) | string or list (a value that starts with `-` is passed as `--build-arg=<value>`) |
| `packageCache` | [`--package-cache`](#options) | path |
| `since` | [`--since`](#what-a-run-does) | string |
| `selectTests` | [`--select-tests`](#selecting-tests) | `none`, `auto`, `reach`, `impact` |
| `impactMap / writeImpactMap` | [`--impact-map / --write-impact-map`](#choosing-the-tests-from-an-earlier-run---select-tests-impact) | path |
| `sharedProcess` | [`--shared-process`](#--shared-process) | `true`, `false` or `auto` ([`auto`](#--shared-process-auto)) |
| `workers` | [`--workers`](#--workers-n) | number |
| `confirmKills` | [`--confirm-kills`](#failures-caused-by-state-left-behind) | `auto`, `all`, `full`, `restore` |
| `failUnder` | [`--fail-under`](reports.md#gates-and-exit-codes) | number |
| `failOnSurvived` | [`--fail-on-survived`](reports.md#gates-and-exit-codes) | `true` / `false` |
| `baselineReport` | [`--baseline-report`](reports.md#gates-and-exit-codes) | path |
| `stopWhenGateDecided` | [`--stop-when-gate-decided`](reports.md#gates-and-exit-codes) | `true` / `false` |
| `timeLimit` | [`--time-limit`](#interrupting-and-resuming) | string (`45m`) |
| `maxMutants` | [`--max-mutants`](ci.md#keeping-a-run-inside-a-time-budget) | number |
| `reporter` | [`--reporter`](reports.md) | string or list |
| `report` | [`--report`](reports.md) | string or list (`json:out/m.json`) |
| `workDir` | [`--work-dir`](#options) | path |

- A value is turned into its option and read by the same parser as the command line, so it is checked the same way, and it is part of what `--resume` compares.
- Values are read with the types of JSON (YAML 1.2): only `true` and `false` are booleans, only decimal numbers are numbers, and anything else without quotes is a string. `yes`, `no`, `on` and `off` are strings, so `failOnSurvived: yes` stops the run (YAML 1.1 would have read it as true); `timeLimit: 3h` is a string, while `timeLimit: 90` is a number and stops the run with a hint to write `"90"`. A key that is there twice, a merge key (`<<`), a number out of range and a tag other than the standard ones stop the run. A key whose children are all commented out (`run:` alone) counts as empty.
- The run prints which keys came from the file and from where (`settings from xcmutate.yml: scheme=App (config), sharedProcess=auto (profile pr)`), and the JSON report keeps it as `settings`.
- An unknown key raises a warning (kind `config`); a value of the wrong type, or a profile that does not exist, stops the run with exit code 64. The messages end with a link to this section.
- The path keys (`packageCache`, `impactMap`, `writeImpactMap`, `baselineReport`, `workDir`) are relative to the directory of the config file, wherever the run is started from, and a leading `~/` is the home directory. (On the command line, paths are relative to the current directory.)
- `--no-recheck-survivors`, `--trust-shared-survivors` and `--confirm-kills none`, which make verdicts weaker, cannot be set in the file (`confirmKills: none` stops the run with exit code 64). They can be given on the command line. Neither can `--prepare`, which runs a shell command: a file in the repository cannot make the tool run one ([SECURITY.md](../SECURITY.md)).
- In the action: `profile: pr`. The action's inputs are options on the command line, so they win over the profile.
- The tool reads `xcmutate.yml` or `xcmutate.yaml` at the root. `xcmutate.config.json`, the JSON file of versions up to 0.14, is still read, with the same keys; there, keys that start with `_` are explanations and are not read. When more than one of the three is at the root, the tool stops with exit code 64 and names them. With a YAML file and `xcmutate.config.json`, `xcmutate init --force` moves the settings of the JSON file into the YAML file and removes it; with two YAML files, keep one. `--config <path>` reads a path that ends in `.json` as JSON and any other as YAML.

### What a run does

1. It selects files and makes mutants. The files are the ones given as arguments, or else the Swift files known to git minus tests, generated code and the `exclude` patterns ([configuration.md](configuration.md#which-files-are-mutated)). With `--since <ref>`, only mutants on lines changed since `git merge-base <ref> HEAD` are kept. Uncommitted changes and untracked files count as changed.
2. It makes a work copy. Files that git tracks, and untracked files that are not ignored, are cloned (APFS clones) into `<work-dir>/src`, uncommitted changes included. `run` does not modify your working tree, so nothing has to be restored after Ctrl-C or a crash.
3. It runs `--prepare` (a shell command such as `xcodegen generate`) in the copy, embeds the mutants and verifies the result statically.
4. It builds once with `xcodebuild build-for-testing`. Mutants that the compiler diagnostics point to are marked CompileError and removed, and the build is repeated ([Mutants that do not compile](#mutants-that-do-not-compile)).
5. It runs the baseline: the tests with every mutant off. A failing baseline stops the run (exit code 6). The baseline also records which switches were evaluated.
6. It runs each reached mutant with `xcodebuild test-without-building`, with one mutant switched on through an environment variable. Mutants that the baseline did not reach are not run (NotReached). After each mutant the observation is appended to `<work-dir>/journal/observations.jsonl`.
7. It runs the baseline once more. If it fails now, state left behind by a mutant or a flaky test may have influenced the results: warning `stateLeak`.
8. It judges and reports ([reports.md](reports.md)).

When mutants could not be run (RunnerError, NotActivated), the scores are those of the mutants that were judged. Every report shows their number beside its score (`INCOMPLETE: …` in the text report, `unevaluatedCount` in JSON), and the run ends with exit code 7, with or without a gate. Mutants that `--time-limit` left out do not count here: without a gate such a run still ends with 0. The usual cause is a destination on which the tests stopped passing without mutants. The warning `workerDropped` says what those runs showed, where their logs are, where a picture of the simulator's screen was saved, and what to check.

Every run of a mutant under `xcodebuild` keeps its log in `<work-dir>/logs` (`mutant-<id>.log`, then `mutant-<id>-run2.log` and so on). What a process started by the tool left when it failed is in `logs/direct-*`, with the crash report of the host if one was written. The next run in the same work directory moves `logs` to `logs-previous`.

`caffeinate -i` runs for the duration of the run, because sleep would turn wall-clock timeouts into false Timeouts. `--no-caffeinate` turns that off.

### Options

Target and build:

| Option | Meaning |
|--------|---------|
| `--root <dir>` | Directory to copy and mutate. Default: the git top-level directory of the current directory |
| `--project <path>` / `--workspace <path>` | Xcode project or workspace, relative to the current directory |
| `--package <dir>` | SwiftPM package directory. `xcodebuild` runs there without `-project` / `-workspace`. When it is a subdirectory of the repository and neither `--root` nor file arguments are given, only the Swift files below it are mutated (also with `--since`); the root, and with it the paths, the keys, the accepted file and the config file, stays the top of the repository. If the directory also contains an `.xcodeproj`, `xcodebuild` prefers it; move it away in the copy with `--prepare 'mv X.xcodeproj X.xcodeproj.disabled'` |
| `--scheme <name>` | Scheme to build and test (required). `xcodebuild -list` shows the schemes. For a Swift package it is usually the product's name when the package declares exactly one product, and `<package name>-Package` when it declares none or several |
| `--destination <value>` | `xcodebuild -destination` value: `'id=<UDID>'`, `'platform=macOS'`. Repeatable: one worker per destination; the build and the baseline use the first |
| `--test-plan <name>` | Test plan |
| `--prepare <command>` | Shell command run in the work copy before building. It receives the original `--root` in `XCMUTATE_ORIGINAL_ROOT` |
| `--build-arg=<arg>` / `--test-arg=<arg>` | Extra argument for `build-for-testing` / `test-without-building` (repeatable) |
| `--keep-warnings-as-errors` | By default the build gets `SWIFT_TREAT_WARNINGS_AS_ERRORS=NO` and `GCC_TREAT_WARNINGS_AS_ERRORS=NO`, because mutated code produces warnings. This flag stops that |
| `--package-cache <dir>` | An existing `SourcePackages` directory, cloned into `<work-dir>/DerivedData/SourcePackages` before the first build. Avoids fetching packages again |
| `--work-dir <dir>` | Work directory. Default: `~/Library/Caches/xcmutate/<hash of root>.noindex`. `run` deletes `src`, `logs`, `results` and `traces` inside it, so it only accepts a directory that does not exist, is empty, or is a work directory of the tool ([configuration.md](configuration.md#the-work-directory)) |
| `--copy-scope git-root\|root` | What is copied. Default `git-root`: the whole git repository that contains `--root`, so that references such as `../Shared/Base.xcconfig` still resolve |

Which mutants:

| Option | Meaning |
|--------|---------|
| `<files>…` | Swift files to mutate, instead of the default selection |
| `--since <ref>` | Only lines changed since the merge base with this ref |
| `--only <key>` | Only the mutants with these stable keys (repeatable). A key that names no mutant is a warning (`unknownKey`) and keeps a gate from passing. When none of the keys names a mutant, the run stops with exit code 2 |
| `--exclude <pattern>` | File pattern to exclude, in addition to the config file (repeatable) |
| `--arid <pattern>`, `--disable-operator <name>`, `--enable-operator <name>` | Added to what the config file says (repeatable) |
| `--max-switches-per-expression <n>` | Default 12, or the config file |
| `--config <path>` | Config file. Default: `<root>/xcmutate.yml` (or `xcmutate.config.json` of versions up to 0.14). A path that ends in `.json` is read as JSON, any other as YAML |
| `--accepted <path>` | Accepted mutants file. Default: `<root>/xcmutate.accepted.json` |
| `--max-mutants <n>` | Examine at most `n` mutants, chosen by their stable keys. The score and the gates are those of the sample ([ci.md](ci.md#keeping-a-run-inside-a-time-budget)) |

Which tests:

| Option | Meaning |
|--------|---------|
| `--only-testing <id>` / `--skip-testing <id>` | Passed as `-only-testing:` / `-skip-testing:` (repeatable). UI test targets must be left out this way: the variable that switches a mutant on does not reach the app that a UI test launches |
| `--select-tests none\|auto\|reach` | [Selecting tests](#selecting-tests). Default `none` |
| `--no-recheck-survivors` | With `--select-tests reach`: skip the recheck. Survivors are then marked and can be false ([Selecting tests](#selecting-tests)) |
| `--only-test-configuration <name>` | Run only this configuration of the test plan (repeatable). Otherwise `xcodebuild` runs the tests once per configuration for every mutant |

Execution:

| Option | Meaning |
|--------|---------|
| `--shared-process` | Run several mutants in one test process ([Running faster](#running-faster)). Off by default. `--shared-process auto`: only when the baseline's times say that it saves time for the number of mutants |
| `--trust-shared-survivors` | With `--shared-process`: report a mutant whose tests passed in a shared process as Survived without the run in a new process. Can report survivors that a clean process kills |
| `--no-direct-launch` | With `--shared-process`: let `xcodebuild` start every test process |
| `--select-tests impact`, `--impact-map <file>`, `--write-impact-map <file>` | Choose the tests from an impact map that an earlier run wrote ([Choosing the tests from an earlier run](#choosing-the-tests-from-an-earlier-run---select-tests-impact)) |
| `--no-stop-at-first-failure` | With `--shared-process`: run a mutant that runs by itself against all selected tests to the end under `xcodebuild`, not in the driver stopped at its first failing test ([Running faster](#running-faster)) |
| `--no-narrow-gate` | With `--shared-process` and `--select-tests reach`: run all selected tests in both runs without mutants at the start of a shared process, not only the mutants' suites in the second |
| `--workers <n>` | Number of destinations that run mutants at the same time ([Running faster](#running-faster)). Default: the number of `--destination` options |
| `--reuse` | Do not run mutants that an earlier run found Killed, while nothing that the result rests on has changed ([Reusing results](#reusing-results)). Off by default |
| `--confirm-kills auto\|all\|full\|restore\|none` | How far the tool goes to make sure that a failing run is caused by the mutant ([Failures caused by state left behind](#failures-caused-by-state-left-behind)). Default `auto` |
| `--timeout-factor <x>` / `--timeout-constant <seconds>` | [Timeouts](#timeouts). Defaults 3 and 30 |
| `--max-rebuilds <n>` / `--max-bisect-builds <n>` | Limits for compile-error handling. Defaults 5 and 16 |
| `--stop-when-gate-decided` | Stop as soon as the result of the gates can no longer change ([reports.md](reports.md#gates-and-exit-codes)). Needs a gate |
| `--resume`, `--time-limit <duration>` | [Interrupting and resuming](#interrupting-and-resuming). A duration is `90s`, `45m`, `2h` or `1h30m`; a bare number is seconds |
| `--keep-results` | Keep the `.xcresult` bundle of every mutant |
| `--no-caffeinate` | Do not keep the Mac awake |

Output and gates are described in [reports.md](reports.md): `--reporter <format>`, `--report <format>:<path>`, `--json-output <path>`, `--progress-file <path>` (the progress of the run, line by line, for a program or a coding agent), `--fail-under <percent>`, `--fail-on-survived` and `--baseline-report <path>`.

### Selecting tests

By default every selected test runs for every mutant, which is slow in a large app. There are three ways to run fewer.

#### `--only-testing`

You name the tests: `--only-testing <Target>/<Class>`. The results then hold "among the selected tests". A test that was not selected might still reach or detect a mutant.

#### `--select-tests auto`

The tool selects tests by naming convention. For a mutated file `Foo.swift` it looks in test files for types named `FooTests`, `FooTest` or `FooSpec` (XCTest classes and Swift Testing `@Suite` types). Symbols such as `+` are ignored, so `UIView+Layout.swift` matches `UIViewLayoutTests`.

It narrows only when every mutated file has a test file of its name. When one has none, or the test target cannot be decided, all tests (or the `--only-testing` tests) run for every mutant, and the warning `testSelectionFallback` names the files. The report's `testSelection` says what was used. As with `--only-testing`, a mutant that only an unselected test would reach or kill is reported as a gap "among the selected tests".

#### `--select-tests reach`

The tool selects tests by what they executed.

1. The baseline runs all selected tests once and records which test was running when each switch was evaluated.
2. Each mutant is run against only the suites of the tests that reached it. Each result carries the suites that were run (`selectedTests`) and the tests that reached the mutant (`coveredBy`).
3. A mutant that passes its narrowed tests is run once more against all selected tests, in a new process, before it is reported as Survived. This is the recheck.

Use `reach` together with `--shared-process`. Without it, a mutant that only one test reaches is not narrowed (see below).

`reach` costs two runs of all selected tests (the two baselines), so it helps when that run is long. On a production app with about 7,000 tests (90 s), a mutant took 7.6 s instead of 88 s. On the fixture, whose tests take under a second, it makes no difference.

A mutant is narrowed only when it is certain which tests reached it. It is run against all selected tests instead in these cases:

- It was reached outside any test (app launch, between tests).
- A suite name does not map to exactly one suite of the result bundle, or the test counts of the suites do not add up.
- The record shows tests overlapping (parallel execution). Then nothing is narrowed, and the warning `reachSelectionUnavailable` is raised.
- Only one test evaluated its switch, and `--shared-process` is off. The switch may be in code that runs once per process, such as the initial value of a `static let`, a `lazy var` of a long-lived object, or the `init` of a singleton. The test that touched it first evaluated the switch, while the tests that can detect the mutant read the stored value, possibly in another suite. One run of the tests cannot tell such code from ordinary code that one test calls. A shared process can, because its driver runs the tests twice without mutants and compares how often each switch was evaluated.
- A shared process sent the mutant back, because its switch is evaluated before the tests start or not equally often in two runs without mutants.

Narrowing assumes that a test which does not run the mutated code is not affected by the mutant. That is false where one test leaves the mutant's effect in the process and a test of another suite reads it:

```swift
final class Limits { static let shared = Limits(); var limit = 10
    func reload(strict: Bool) { limit = strict ? 10 : 20 } }   // mutant: ? 20 : 10
func isValid(_ n: Int) -> Bool { n < Limits.shared.limit }

// LimitsTests:    Limits.shared.reload(strict: true); XCTAssertGreaterThan(Limits.shared.limit, 0)   ← the only test that runs reload
// ValidatorTests: XCTAssertFalse(isValid(15))   ← fails with the mutant on, when it runs after LimitsTests in the same process
```

With every test run for the mutant, it is Killed by `ValidatorTests`. Narrowed to `LimitsTests`, it passes. The recheck exists for this case: every Survived of the report is one that a run of all selected tests gives too. (`Fixtures/Regression/StateAcrossSuites` is this example.)

The recheck costs one run of all selected tests per mutant that passes its narrowed tests. Mutants that their narrowed tests kill cost nothing extra. [speed.md](speed.md#what-the-recheck-of-survivors-costs) has measurements.

`--no-recheck-survivors` skips the recheck. A mutant that passed only its narrowed tests is then reported as Survived, which in the situation above is a false Survived. Such a result is marked in every report: `narrowedOnly: true` in the JSON report and in the report for agents, "not run against all tests" in the other reports, the count in `testSelection.survivedNarrowedOnly`, and a `survivorsNotRechecked` warning.

State of another suite can also work the other way and hide a mutant from the tests that reach it. Suppose a suite that runs first sets a custom threshold in a singleton, and the mutant changes the code that falls back to a default threshold. In a run of all tests the default is never used and the mutant survives. Run by itself, the suite that reaches the mutant has no custom threshold and fails: narrowed, the mutant is Killed. (`Fixtures/Regression/HiddenByOtherSuite` is this example.) So:

- A Survived is the verdict of a run of all selected tests. A Killed, Crash or Timeout with narrowed tests means that the suites which reach the mutant detect it.
- Such detections carry `narrowedOnly: true` in the JSON report. With narrowed tests this is the normal case: in one run on a large app, more than nine in ten detections carried it. The text report counts them in one line.
- `--confirm-kills full` runs every mutant that its narrowed tests detect once more against all selected tests, and that run decides. It costs one run of all tests per detected mutant, so it is meant for a nightly run or for numbers that are published.
- A shared process has run all selected tests before it runs a mutant's narrowed tests, so the state of the other suites is present there. It can still decide whether a mutant's effect shows.

A failure of narrowed tests is a detection only if those suites pass by themselves. A suite can pass in a run of all tests and fail when only it is run, because an earlier suite sets something up for it. So the first time a combination of suites fails with a mutant, the tool runs it once by itself without mutants. If it fails there too, the suites are named in a `dependentTests` warning and the mutants that they reach are run against all selected tests.


#### Choosing the tests from an earlier run: `--select-tests impact`

With a long test run, every run of all selected tests in a run costs that time again: the baseline, the first run at the start of a shared process, the mutants that run alone against all tests, the recheck of survivors and the final baseline. `--select-tests impact` makes the selection itself small, from what an earlier run recorded.

1. A run of whole files (a nightly run on the main branch) with `--select-tests reach --write-impact-map impact.json` writes, for every mutated file, the suites whose tests evaluated a switch in it, and the commit.
2. A later run with `--select-tests impact --impact-map impact.json` takes the files changed since that commit (committed, uncommitted and untracked) and selects the suites that the map gives for them, and the suites declared in changed test files (also ones that the map does not know yet). Then it runs as with `--select-tests reach`, on that selection: its own baseline, narrowing, rechecks and final baseline.

The whole selection runs instead, and the warning `impactFallback` says why, when a changed file is not a Swift file (resources, storyboards, project settings; documentation and `.github/` do not count), is not in the map (a new file, or one without mutants when the map was made), has code that ran outside the tests (app launch) or was reached by a suite that cannot be named for certain, is a test helper that declares no tests, or declares tests outside a type; and when the map cannot be read or its commit is not an ancestor of `HEAD`.

Only the choice of tests comes from the map. Every verdict comes from the run's own runs, so the map cannot give a wrong Killed. The results hold among the selected suites, as with `--only-testing`, and the warning `impactSelection` says so: a test outside them may still reach or detect a mutant. A suite is in the map for a file when it evaluated a switch in that file. One that runs only lines of the file without mutants is not, and neither is one that reads a value that code of the file stored (the reasons for the recheck in [What narrowing assumes](#selecting-tests)). Keep the full run as the reference, and make a new map regularly.
### Running faster

[speed.md](speed.md) has the measurements and says when each option helps. [how-it-works.md](how-it-works.md#several-mutants-in-one-process---shared-process) explains the mechanism of the shared process. This section says what the options do.

#### `--shared-process`

The test host is launched once and runs many mutants. Off by default. It needs an iOS simulator or macOS as the destination, tests that pass twice in a row in one process, and no UI test target in the selection. When it cannot be used, the warning `sharedProcessUnavailable` says why, and every mutant is run as without the option.

```bash
xcmutate run --since origin/main --workspace App.xcworkspace --scheme App \
  --destination 'id=<SIMULATOR-UDID>' --only-testing AppTests --shared-process
```

The tool compiles a small driver and starts your test host with it. Nothing is added to your test target. The driver runs your tests twice without any mutant; both runs must pass with the baseline's number of tests. With `--select-tests reach` the second of them runs only the suites that the process's mutants reach, and the run says so (`--no-narrow-gate` makes both runs of all tests; [how-it-works.md](how-it-works.md#several-mutants-in-one-process---shared-process) says why this does not change verdicts). Then, for each mutant, it switches the mutant on, runs its tests, and switches it off. After a failing run it runs the same tests once more without the mutant.

| In the shared process | Result |
|---|---|
| Tests failed with the switch evaluated as active, directly after the same tests had passed without mutants, and passed again without the mutant | Killed (final) |
| Tests failed after another mutant's passing run, passed without the mutant, failed again with it, passed again without it | Killed (final) |
| Tests failed after another mutant's passing run and passed when the mutant was run again | Run under `xcodebuild`, in a separate process: the first failure came from what the earlier mutant left in the process |
| Tests passed | Run again in a new process, with the mutant on from the start; that run decides. With `--trust-shared-survivors`: Survived without the second run |
| The switch is evaluated before the tests start (app launch), or not equally often in the two runs without mutants (a `static let`, a cache, anything computed once per process) | Run under `xcodebuild`, in a separate process |
| The tests did not end in time with the mutant on, its switch had been evaluated as active, and the same tests had passed without mutants in this process directly before | Timeout (final) |
| The tests did not end in time after another mutant's passing run | The mutant becomes the first one of the next shared process. A run that does not end there is a Timeout |
| Crash, a different number of tests, no evaluation as active, tests that still fail after the mutant is switched off | Run under `xcodebuild`, in a separate process |

A Crash is therefore always the verdict of a run under `xcodebuild`.

A mutant that has to run by itself against all selected tests (its switch is evaluated before the tests start or unequally often, the tests that reach it are not known, or nothing is narrowed) runs in a process with the tool's driver, with the mutant on from the start, and the run stops at its first failing test. Up to that test it is the run of all tests in the driver's order, which the first run without mutants of every shared process has shown to pass, so the failure is the same evidence of a Killed as in a run to the end (the switch evaluated as active, the tests passed without mutants on the destination since the last run that did not pass). A run of all tests that passes is a Survived as before. Whatever else happens (a crash, a hang, another number of tests) goes to a run under `xcodebuild` to the end. Such a Killed says so in its detail ("the run of all selected tests was stopped at its first failing test (312 of 6904 tests had run)"), carries `stoppedAtFirstFailure: true` in the JSON report, and is counted in the text report and in the time breakdown. On an app whose tests take 15 minutes, this is what such a mutant costs when it is detected early. It is not done when the `.xctestrun` file asks for the tests in random order (`TestExecutionOrdering`; the warning `randomTestOrder` says so), with several unit-test targets or test-plan configurations, or with `--no-stop-at-first-failure`.

The progress line says where each verdict came from (`shared process 1`, `new process`, `alone`, `alone: <reason>`), and the report has `sharedProcess` and `directLaunch` per result.

With several unit-test targets or test-plan configurations, each unit gets its own shared process, and every mutant goes through each unit. A mutant is Killed if its tests fail in one unit. It is a candidate survivor if its tests pass in every unit whose tests evaluate its switch.

When crashes and hangs cost more shared processes than kills save, the tool runs the next mutants alone until that changes. So code in which most mutants crash costs about what it costs without the option.

By default the tool starts the test host itself, without `xcodebuild`. It does so for the shared processes and for the new process that confirms a survivor. The first process it starts on a destination is a control: the tests must pass in it without mutants, in the baseline's number. If they do not, the tool goes back to `xcodebuild` for the rest of the run and reports it with the warning `directLaunchUnavailable`. The verdicts are not affected, but each survivor's second run then costs a full `xcodebuild` launch.

The same happens when a process that the tool started ends while the app is in the background. A test that opens another app or a URL sends the app there. Under `xcodebuild` a test host keeps running in the background; a host started by the tool is suspended, and the system ends it when a background task of the app does not finish within about 30 seconds. The warning names the test that was running when the app went to the background.

Some XCTest features need the test session of Xcode, which such a host does not have. [how-it-works.md](how-it-works.md#hosts-started-by-the-tool) lists what is known to work and describes the files that are kept when the tool could not start your host.

#### `--shared-process auto`

The tool decides after the baseline whether to use shared processes, and the run says which it chose and why (also in the text report and in `durations.sharedProcessChoice` of the JSON report). A shared process saves at least one launch of the test host per mutant. It costs, once per unit, a launch and the two runs of the tests without mutants at its start (with `--select-tests reach`, the second of them runs only the mutants' suites). Shared processes are used when the launches that the mutants would save are at least that cost:

```
mutants × launch  ≥  units × (2 × tests of one run without mutants + launch)
```

The launch is the time the baseline needed until its first test started. The tests of a run are those of the whole selection in the baseline, or, for the second run with `--select-tests reach`, those of the suites that reach the mutants. A run that is continued with `--resume` keeps the choice of the run it continues. [speed.md](speed.md#letting-the-tool-decide---shared-process-auto) says where the rule comes from. When shared processes are chosen, everything above applies, including the warnings.

#### `--workers <n>`

Mutants run on `n` destinations at once. The default is the number of `--destination` options, usually 1.

```bash
xcmutate run … --destination 'id=<UDID-1>' --destination 'id=<UDID-2>'   # your own simulators
xcmutate run … --destination 'id=<UDID>' --workers 2                      # the tool creates one more
```

- With repeated `--destination`, nothing is created or deleted.
- With one simulator and `--workers <n>`, the tool creates `n − 1` simulators of the same device type and runtime, named `xcmutate-<pid>-w<n>`, boots them, gives them the privacy settings that the first simulator has for the app under test (read from its privacy database: what it allows is granted, what it denies is revoked), and deletes them at the end, also after Ctrl-C. What `simctl privacy` cannot set (the camera, a limited access, the location) is named in the warning `workerPrivacy`; a permission dialog on a worker can stop shared processes there. A destination by name (`platform=iOS Simulator,name=…`) must name one simulator on the Mac; otherwise the run stops before the build and lists the matching ones. If a run dies without cleaning up, the next `run --workers` and `xcmutate clean` delete worker simulators whose process no longer exists.
- On `platform=macOS` the workers share the destination, and their test processes can fail each other (a port, a lock file). So every mutant that is detected while they run side by side is run again alone at the end, and that run decides (`sharedDestination`). `--workers` saves time there only on mutants that survive.
- The build and the baseline run once, on the first destination. Every other worker first runs the tests once without mutants. A worker where that fails is not used (`workerDropped`).
- A Timeout seen while several workers are running is run again alone after the workers are done.
- After a RunnerError the destination is checked with a run of the tests without mutants. A destination where they no longer pass is dropped, and its mutant goes to another worker.

The two options combine: each worker runs its own shared processes.

### Reusing results

`--reuse` keeps the mutants that a run killed in `<work-dir>/reuse/killed.json`. A later run with `--reuse` in the same work directory does not run a mutant again when its Killed cannot have changed. Off by default. It is meant for the loop "run, write tests for the survivors, run again".

A stored Killed is taken over only if all of this holds:

| Condition | How it is checked |
|---|---|
| Same tool, same Xcode, same way of building and testing | Tool version, `xcodebuild -version`, scheme, destination, test plan, build and test arguments, build settings, `--prepare`, `--only-testing` / `--skip-testing`, `--select-tests` |
| No file outside the tests changed | Every file of the repository that is not on the test side, byte for byte. One change anywhere and nothing is taken over |
| No shared test code changed | The test-side files that declare no tests (helpers, mocks, resources) |
| The mutant is the same | Same stable key, and the same tokens in the declaration that encloses it |
| A test that killed it is unchanged and still runs | Every file that declares or extends the test's type, or one of its superclasses, is byte-identical, and the baseline of this run ran a test with that identifier |

Survived, NotReached, Crash, Timeout and everything else are always run again. In the report, a result that was taken over has `reused: true`, and `reuse` at the top has `reusedCount`, `storedCount` and, when nothing was taken over, `refusal` with the reason.

The option assumes three things that it does not check: a test does not depend on code written in another file that declares tests, tests do not depend on each other's order or leftovers, and nothing outside the repository changed (the Xcode version is checked; the operating system and the simulator runtime are not). So make a full run without `--reuse` regularly, and when a reused result surprises you.

### Failures caused by state left behind

A test can fail because of what an earlier run left behind, and not because of the mutant that is on. Reported as Killed, such a mutant hides a gap.

```swift
func testParseWritesAuditLine() throws {
    try append("parsed", to: auditFile)               // a file with a fixed name
    let value = try XCTUnwrap(Parser.parse("42"))     // mutant A returns nil: the test ends here…
    XCTAssertEqual(try lines(of: auditFile).count, 1) // …the next run finds two lines: this fails for mutant B, whatever B is
    try FileManager.default.removeItem(at: auditFile) // …and removes the file, so nothing is left to see afterwards
}
```

A failure is therefore attributed to the mutant only when every test of the mutant's run has passed without mutants on that destination since the last run there that did not pass. `--confirm-kills` says how far the tool goes to establish that:

| | One process per mutant | Shared process | Several workers |
|---|---|---|---|
| `auto` (default) | After a run that did not pass (failed tests, a crash, a timeout, a RunnerError), the tests of the next mutant are run once without mutants on that destination before it | A failing run that did not come directly after a passing run of the same tests without mutants is repeated after one; only a second failure is Killed | What workers detect while they share one destination is run again alone at the end |
| `all` | As `auto`, and a failing run that came after another mutant's passing run is repeated after a run without mutants; it must fail again | Every failing run is repeated | What workers detect while running side by side is always run again alone at the end |
| `none` | A failing run counts as it is | The failing run and the run without the mutant after it | n/a |
| `full` | As `auto`, and with `--select-tests reach` a mutant that its narrowed tests detect is run once more against all selected tests ([Selecting tests](#selecting-tests)) | The same | The same |
| `restore` | As `auto`, but the run without mutants after a run that did not pass is replaced by putting the destination back (below) | The same, for the runs before a new shared process | As `auto` (one worker only) |

`--confirm-kills restore` is for an iOS simulator with app-hosted unit tests and one worker. Right before the baseline, the tool installs the host app and takes a copy (APFS clones) of the app's data container, its App Group containers and the simulator's keychain. After a run that did not pass, it stops the app and the simulator's preferences and keychain daemons, and puts the copy back instead of running the tests without mutants; the pasteboard's text is put back too. Then it compares what the copy does not cover with the state at the copy: the keychain by access group, the pasteboard, the app's privacy permissions, its notifications, the App Groups of other apps that are not Apple's, and the number of records in Photos, Contacts and Calendar. When any of them differs, or putting back fails, the tests are run without mutants as with `auto`; the warning `restoreFellBack` counts such cases with their reasons. The mode assumes that the tests depend on nothing outside the simulator (a server, a file on the Mac) and give the same result from the same state; choose it only when that holds. It also puts back the keychain of the whole simulator, so use a simulator that serves only these tests. On macOS, for tests without a host app, and with several workers it is not used (warning `restoreUnavailable`), and the runs are made as with `auto`. The final baseline and the recheck of survivors are not replaced. `durations.confirmation` has `restoredStates` and `restoreFallbacks`.

A mutant whose tests are narrowed needs a run without mutants of its own suites only, and suites that have already passed since the last failing run are not run again. State that fails a test outside the next mutant's suites is noticed later: when a mutant with that test comes up, or by the run of all selected tests after the last mutant. It is never counted as a detection.

When the run without mutants fails, the earlier run did leave something behind. The tool reports it with the mutant that caused it (`stateLeak`), runs the tests again without mutants until they pass (three times at most) and goes on. A destination where they do not pass again is dropped. When none is left, the remaining mutants are RunnerError.

State can also outlast the process. A new process does not clear the app's data on the simulator (files, a database, settings), so a mutant's run can leave something there that makes a test of the next process fail, or ends that process. Because the tool runs a mutant only after its tests have passed without mutants, this costs repeated runs and does not make a wrong verdict. A process that ends without a result right after a failing run is reported with the warning `possibleStateLeak`.

With one process per mutant, every detected mutant is followed by one more launch of the test host. In a shared process the checks add little ([speed.md](speed.md#what-the-runs-without-mutants-cost)). `--confirm-kills none` saves the time and brings back the wrong results above.

`auto` does not rule out three cases. `all` rules out the first two.

- With one process per mutant, a mutant whose tests pass leaves state on the destination. For example, the product code that removes a cache file is mutated away, no test notices, and the stale file fails a test of the next mutant.
- With several simulators as workers, tests share something outside the simulator, such as a port on the Mac.
- In a shared process, state that fails no test without a mutant does so together with a later mutant. Only a separate process tells, so the reference for a doubtful result is a run without `--shared-process` (with `--only <key>`).

### Timeouts

A mutant that turns a loop endless is detected by the clock, and the whole timeout is waited for. The timeout is taken from the baseline. "Factor" and "constant" are `--timeout-factor` (default 3) and `--timeout-constant` (default 30 s).

| Run | Timeout |
|---|---|
| All selected tests under `xcodebuild` | baseline duration × factor + constant. With `n` workers the first term is multiplied by 1 + 0.25 × (n − 1) |
| Narrowed tests under `xcodebuild`, or in a new process started by the tool | (what the baseline spent outside the tests + what these suites took in the baseline) × factor + constant, and never more than the line above |
| Under `xcodebuild`, until the first test starts | what the baseline needed until its first test started × factor + constant, and never more than the limit of the whole run |
| Under `xcodebuild`, once the first test has started | the limit of the whole run less factor × what the baseline needed to get to its first test; at least the constant |
| Under `xcodebuild`, one test | no test or suite starting or ending for longer than the longest such time of the baseline × factor + constant. Used only where it is at most half of the line above |
| One run inside a shared process, all selected tests | the longer of the two runs without mutants × factor + 10 s |
| One run inside a shared process, narrowed tests | what these suites took in the baseline × factor + 10 s + a tenth of the line above |

With a baseline of 44 s for 1,105 tests, a mutant that never ends costs 161 s in a run of all selected tests under `xcodebuild`. Narrowed, it costs 50 s under `xcodebuild` and 22 s in a shared process.

Notes on the limits under `xcodebuild`:

- The start of the first test is read from the log of `xcodebuild` and from the baseline's trace file. If neither shows it, the time the baseline spent outside its tests is used, and the longest suite stands in for "one test". A run prints the limits in use, and warns (`limitsNotInUse`) when the limit until the first test and the limit for one test are not.
- A run that is stopped before its first test, or by the limit for one test, is repeated once before it counts as a Timeout. A host can be slow to start for reasons that have nothing to do with the mutant.
- A run that is stopped counts as a Timeout only with the record that the mutant was evaluated while active. Otherwise it is a RunnerError.
- A run is also stopped when `xcodebuild` writes that it restarts the host after an unexpected exit. The result is a Crash, confirmed by a second run like every Crash. It is named with the test that was running when the host ended, if the log shows exactly one. When that test had failed an assertion before the host ended, the mutant is Killed.
- When a limit stops a run after its tests have started, the tool looks for a crash report that the host wrote during the run on that simulator. With one, the run is a Crash. Without one, the run is also a Crash when the log has the host's own line `*** Terminating app due to uncaught exception` (with the host's name and process ID before it) and no test started or ended after it. The `detail` of the result quotes the line.

A mutant that only makes a test slow can be a Timeout too: a test that takes 0.1 s in the baseline and 40 s with the mutant is stopped by a limit of 30 s. The `detail` of a Timeout says which limit stopped the run and with which numbers. The time reported for such a mutant includes the run that was stopped and the run that was made again. If you see a Timeout that you do not believe, run that mutant alone (`--only <key>`) and raise `--timeout-constant`.

The remaining time in each progress line is an estimate. While fewer than three runs of a kind that is still to come have been seen, the line says `roughly` instead of `about`. Mutants that crash or hang come last and cost many times what the others cost, so the estimate can go up.

### Mutants that do not compile

Mutation is syntactic, so some mutants do not type-check. When the build fails, the tool finds the mutants responsible, marks them CompileError and rebuilds without them. It widens the search step by step:

1. the mutated branch that contains the diagnostic's line and column: that mutant only;
2. the switches on the diagnostic's line: all mutants on that line;
3. the declaration containing the line: all its mutants, with `collateral: true` in the JSON report;
4. no match (inside a macro expansion, another file): bisection, up to `--max-bisect-builds` builds.

The mutants of step 3 were not examined, so they keep a gate from passing ([reports.md](reports.md#gates-and-exit-codes)). Put `// xcmutate:disable` … `enable` around the declaration to leave it out knowingly, and please report the shape of code that caused it.

A build failure without any compiler error (a wrong scheme, a script phase, linking, signing), or one that persists with every suspect removed, is not caused by a mutant, and the run stops with exit code 2. The message shows the error lines of the log.

### When the build cannot find a file

The work copy contains what git tracks plus untracked files that are not ignored. Ignored files (generated sources, local `.xcconfig` or `.plist` files, `Pods`) and anything outside the repository are missing. When the build log has a "file not found" error, the tool points this out and suggests creating the file in `--prepare`:

```bash
--prepare 'cp "$XCMUTATE_ORIGINAL_ROOT/Config/Local.xcconfig" Config/ && xcodegen generate'
```

### Interrupting and resuming

- After each mutant the observation (exit code, test summary, activation record, duration) is appended to the journal and synced. Verdicts are recomputed from observations whenever the journal is read.
- Ctrl-C, SIGTERM or SIGHUP stops the child processes, writes the reports for what has finished and exits with 130. The report has `interrupted: true` and the keys that were not run in `pendingKeys`. A second Ctrl-C exits at once.
- `--time-limit <duration>` does the same when the time is up, counted from the start of the run. The report also has `timeLimitReached: true` and a `timeLimit` warning. The exit code is 0 without a gate. With a gate it is the code of a gate that the results so far already fail, and otherwise 7. If the time is up during the build or the baseline, there is no report and the exit code is 2.
- `--stop-when-gate-decided` does the same when the result of the requested gates can no longer change. The report has `gateDecidedEarly: true`, `gateDecision` and a `gateDecided` warning, and the exit code is the gate's result.
- `--resume` with the same options skips the recorded mutants and runs the rest. The build and the baseline are repeated. The time limit is not compared, so a run that the limit cut short can be continued with another limit, or none.
- `--resume` is refused (exit code 2), with a message that says what changed, when the tool version, the repository state (HEAD, uncommitted changes, contents of untracked files), the list of mutants, the baseline's test count, or an option that decides results has changed. Those options are the `xcodebuild` arguments, `--prepare`, the timeouts, `--select-tests`, `--no-recheck-survivors`, `--max-mutants`, `--shared-process` (and `auto`), `--trust-shared-survivors`, `--no-direct-launch`, `--no-narrow-gate`, `--no-stop-at-first-failure`, `--workers` and the destinations, `--confirm-kills`, `--reuse` and `--copy-scope`. Changes to files that git ignores, and the Xcode version, are not covered.
- `run` takes a lock on its work directory. A second run with the same work directory stops with exit code 2 and names the process that holds it. Give parallel runs of one checkout a `--work-dir` each.

## init

`xcmutate init` finds out how the project is built and tested, tries it, and writes the run options into `xcmutate.yml` ([the keys](#run-options-in-the-config-file-run-and-profiles)).

```bash
xcmutate init                                   # a package: tests on macOS
xcmutate init --destination 'id=<SIMULATOR-UDID>' --scheme App
xcmutate init --yes --dry-run                   # print the file; take defaults instead of stopping at open choices
xcmutate init --path Sources/Cart               # take the sample of the trials from the files below Sources/Cart
```

1. It finds the workspace, project or package at the top of the repository and its scheme (with several schemes it stops and lists them, unless `--yes` takes the one named after the project), the default branch, and the cores and memory of the Mac.
2. It builds for testing and reads the `.xctestrun` file: the unit-test targets (UI test targets are left out with `onlyTesting`), the test-plan configurations (with several, the first is chosen with `onlyTestConfiguration`), whether the tests are hosted by an app, whether they run in random order.
3. It runs a sample of mutants (`--sample`, default 10) twice with `run`: in the default mode, and with `--select-tests reach --shared-process` (and `--confirm-kills restore` for app-hosted tests on a simulator). The sample is taken from the Swift files given as arguments, else from those below `--path <directory>`, else from those below the current directory when it is inside the repository (tests, generated code and the `exclude` patterns left out), and only from the root from the whole repository. A run that does not pass without mutants stops `init` with the reason. On a simulator the trials use one of their own, created like the given one with its privacy settings for the app under test (as the worker simulators of `--workers` get them), and deleted at the end.
4. It writes a `run` object (container, scheme, destination, test targets, and `buildArg`, `packageCache` and `workDir` when they were given to `init`) and two profiles: `pr` (`since` the default branch, `selectTests: reach`, `sharedProcess: auto` and `confirmKills: restore` when the trial allowed them) and `nightly` (`selectTests: reach`, `sharedProcess`, `writeImpactMap`, `timeLimit`, `workers` by the cores and memory). Each choice has its reason in a comment above it, and a comment says roughly how long a pull request with 50 mutants takes after the build: the time per mutant run, for the share of the sample's mutants that were run, plus what does not grow with the number of mutants (the baseline, the final baseline, the runs without mutants at the start of a shared process).

- The destination of a simulator is written by its name and OS version (`platform=iOS Simulator,name=…,OS=…`), which other Macs can resolve, unless another simulator has the same name and version; then it is the UDID.
- `workers` is written only when the privacy settings of the simulator could be given to another simulator (read from its privacy database; a camera permission, for one, cannot be set with `simctl privacy`).
- The impact map goes outside what git tracks and outside any work directory (`clean` removes those): `.build/xcmutate/impact.json` when git ignores `.build`, else `~/Library/Caches/xcmutate/impact-<repository>-<hash of its path>.json`. A map inside the tracked tree would make the working tree dirty.
- Paths given to `init` (`--package-cache`, `--work-dir`) are written relative to the directory of the config file, unless they were given as absolute or from `~/`.
- The trials work in the temporary directory, or in the `--work-dir` given, which `init` locks as a run does. When `init` stops on a failure, it removes its builds and copies and keeps only the logs that the message names; a full disk is said as such, with the free space. The next `init` removes what an earlier one left, and the simulators of trials that were killed.

A faster mode is written only when its trial gave the same verdicts as the default mode for every mutant of the sample, was faster per mutant run (the runs without mutants at the start of a shared process left out; `sharedProcess: auto` weighs them against the number of mutants of each run), and no warning said that it could not be used. `init` never writes an option that makes verdicts weaker (`--no-recheck-survivors`, `--trust-shared-survivors`, `--confirm-kills none`) and never a gate; the `pr` profile carries examples as commented-out keys.

The file it writes:

- It starts with comments that link to the description of its keys (for the version that wrote it).
- An existing `xcmutate.yml` keeps its other keys and its comments. When it already has `run` or `profiles`, `init` writes nothing, shows what it would write and ends with exit code 1; `--force` replaces those two keys. (A file in flow style, `{…}`, cannot be edited by lines; it is then written anew from its values, without its comments, and `init` says so.)
- When `xcmutate.config.json` of an earlier version is at the root (alone, or beside the YAML file, or with `--config` naming a YAML file), `init` writes nothing, shows the YAML file it would write, and ends with exit code 1. That file holds the settings of the JSON file that the YAML file does not have, its `_` explanations as comments, and the run options of `init` in place of the JSON file's `run` and `profiles` (the message names them). With `--force` it writes the YAML file and removes `xcmutate.config.json` (git still has it), so that the root has one config file. `--config xcmutate.config.json` keeps writing JSON instead, with the reasons under `_why`.
- Writing again replaces what `init` wrote before: the header, the paragraph with the estimate, `run` and `profiles`.

## accept

Some mutants cannot be detected by any test, because no input tells them apart from the original (equivalent mutants). Record them with a reason instead of writing a test that pins implementation details:

```bash
xcmutate accept '<stable key>' --reason "equivalent: when a == b either branch returns the same value" \
  --report <JSON report of the run>
```

This writes the key, the reason, the location (with `--report`) and the date into `<root>/xcmutate.accepted.json`. Commit the file and review it like code.

- In later runs such a mutant is Accepted when it is not detected. It counts neither in the score nor as a gap.
- An accepted mutant that is detected again raises `acceptedButKilled`, and an entry whose mutant no longer exists raises `staleAccepted`. Remove those entries.
- `accept` does not check that the mutant really is undetectable. With `--report` it warns about a key that the report does not hold, or holds as detected.

A key has the form `file::declaration::operator::hash`. The hash covers the parameter types and `where` clauses of the enclosing declarations, the position of the mutated node inside its declaration, the original text of what is rewritten, and the mutated text. A key stays the same through edits elsewhere in the file, added or reordered declarations, blank lines, comments and indentation. It changes when the expression itself changes, when a statement is added before it in the same function, or when the file is renamed or moved. The acceptance then lapses (`staleAccepted`); judge the mutant again.

## clean

There is one work directory per `--root`, and with DerivedData inside it can take gigabytes. Removing a git worktree does not remove its work directory.

```bash
xcmutate clean                    # the work directory of the current repository
xcmutate clean --root <dir>       # the one for run --root <dir>
xcmutate clean --work-dir <dir>   # a directory given to run --work-dir
xcmutate clean --orphans          # those whose root no longer exists
xcmutate clean --all              # everything under ~/Library/Caches/xcmutate
xcmutate clean --all --dry-run    # only show what would be removed, with sizes
```

Every form of `clean` also deletes worker simulators whose run no longer exists. A work directory that a run is using is skipped. `--all` removes the work directories of every checkout on the machine, so on a shared machine look at `--all --dry-run` first. A directory given with `--work-dir` is removed only if it contains the marker file that `run` writes (`xcmutate-workdir.json`).

## list and instrument

```bash
xcmutate list --show-ignored Sources/Foo.swift Sources/Bar.swift   # mutants and ignored candidates
xcmutate list --keys Sources/Foo.swift                             # with the stable key of each mutant
xcmutate list --format json Sources/*.swift
xcmutate list --since origin/main                                  # the files that changed since the ref
xcmutate list --since origin/main --package Shop                   # only those below the package directory, as run --package Shop
xcmutate instrument --output-dir <dir> --manifest <dir>/mutants.json Sources/*.swift
xcmutate instrument --in-place --manifest mutants.json Sources/*.swift   # use on a copy
```

- `instrument` needs file arguments. `list` needs file arguments or `--since <ref>`; with `--since` alone it looks at the files that `run --since` would mutate. Give `list` the same `--package` as `run`: a subdirectory limits those files to the ones below it, as for `run`. It cannot list a whole project.
- Paths and stable keys are relative to `--root`, and the config file is looked up there. The default root is the same as for `run`.
- Without a destination, both also make the mutants of every branch of `#if os(…)`. `run` leaves out the branches that its destination does not compile.
- `instrument` verifies before writing: exactly one switch per mutant id, no syntax error, the same number of lines as before. A file that fails is not written, and the exit code is 2.
- `instrument --in-place` overwrites the files you name.
- Both accept `--arid`, `--disable-operator`, `--enable-operator`, `--max-switches-per-expression` and `--config`.

## agent-guide

```bash
xcmutate agent-guide
```

Prints the procedure that a coding agent follows to find and close gaps: how to work out the scheme and the destination, how to estimate and bound the first run, how to read the report for agents, and what to ask the user before doing. Without options it reads nothing from the project. The text is the one in [agent-guide.md](agent-guide.md), for the installed version. [agent-integration.md](agent-integration.md) says how to hand it to an agent.

```bash
xcmutate agent-guide --install
```

Writes the file through which an agent finds the guide by itself, at the root of the git repository (the current directory outside a repository): the Claude Code skill if there is a `.claude/` folder, the Codex skill if there is an `.agents/` folder, a section in `AGENTS.md` if there is that file, each of them when there are several, and a new `AGENTS.md` when there is none. It prints one line per file.

| Option | Meaning |
|--------|---------|
| `--install` | Write the files that the project calls for, as above |
| `--install-for <target>` | Write one target instead: `claude` (`.claude/skills/mutation-test-loop/SKILL.md`), `codex` (`.agents/skills/mutation-test-loop/SKILL.md`) or `agents-md` (the section in `AGENTS.md`) |
| `--user` | With `--install-for claude` or `codex`: write the skill below the home directory (`~/.claude/skills/…`, `~/.agents/skills/…`) instead of the repository |
| `--force` | Replace a skill file that differs from what the tool writes. Without it such a file is left alone and the exit code is 2 |

In `AGENTS.md` only the part between the tool's two marker comments is written; the rest of the file is not touched. A file that is up to date is not written.

## Known pitfall: macOS app-hosted tests and `~/Desktop`

For tests hosted by a macOS app, a `--work-dir` under `~/Desktop`, `~/Documents` or `~/Downloads` can make the freshly built app wait for the system's folder-access consent when a test fails. The mutant is then reported as Timeout instead of Killed, after the full timeout. The default work directory under `~/Library/Caches` is not affected.
