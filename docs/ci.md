# Continuous integration

Three parts: how to run xcmutate in the CI of your project, what to choose for a large app, and the CI of this repository.

## What has been verified

**The action has run twice on a GitHub-hosted macOS runner: it built the tool from source and ran it on a Swift package on macOS. An iOS simulator and the download of the release binary have not been tried on GitHub.**

Both runs used `macos-latest` (image `macos-26-arm64`, Xcode 26.6, Swift 6.3.3) and the workflow `.github/workflows/smoke.yml`. The first, on 2026-11-23:

- The action built the tool from the checked-out source. The step took 4 min 52 s, about 4 min 15 s of it for the build.
- The tool ran on `Fixtures/LogicKit` (macOS, `--shared-process`, 23 mutants) and gave the same verdicts as with Xcode 27.2 on a Mac: Killed 18, Survived 5, no warning, exit code 0. The baseline took 4.3 s and the mutants about 11 s.
- The inputs, the outputs (`exit-code`, `score`, `undetected`, `report`), the warning annotations for the five survivors and the upload of the artifact worked. The whole job took about 5 minutes.

The second, on 2026-11-24, in this repository: the same verdicts (Killed 18, Survived 5, Ignored 1, no warning). The build from source took 9 min 21 s this time, and the whole job 10 min 45 s.

So expect 4 to 10 minutes for a build from source, and about 30 seconds for the run on a small package (build of the package and baseline included). Downloading a release binary would save the 4 minutes; that path has not been tried.

Not tried on GitHub: an iOS simulator, the release binary, the cache, `pull_request` events, how the warnings appear on the lines of a pull request, and the example workflows. For those, this is what was checked on a Mac:

| | Checked | Not checked |
|---|---|---|
| The action's steps (`action/*.sh`) | Run with the environment variables that GitHub sets, against a package on macOS: `scripts/verify-action.sh` (installation from the sources, the pull-request default of `--since`, the job summary, the annotations, the outputs, the exit codes); the simulator step alone, with a simulator given by id and by name | The expressions in `action.yml`; `actions/cache` and `actions/upload-artifact`; installation from a release; a simulator destination on a hosted runner; how GitHub shows the annotations |
| The workflows in `examples/workflows/` and `.github/workflows/` | `actionlint` 1.7.12 (without its shellcheck pass, which did not finish here): no findings. `action.yml`: parsed as YAML | Everything else. `actionlint` does not read `action.yml` or check the inputs passed to the action |
| `--reporter github` | Unit tests of the output (format, escaping, the limit of ten) | That GitHub places the warnings on the lines of a pull request |
| `--max-mutants`, `--time-limit` | Unit tests; runs on macOS | nothing |

Treat the workflows as a starting point and read the log of the first run. This section is updated as parts are verified on GitHub.

## Using xcmutate in your project's CI

### GitHub Actions: the action

The repository is an action. It installs the tool, boots the simulator, runs the tool, writes the Markdown report to the job summary, turns undetected mutants into warnings on their source lines, uploads the reports as an artifact, and then fails the job with the tool's exit code.

```yaml
name: Mutation testing
on: pull_request

jobs:
  mutation:
    runs-on: macos-latest          # must provide Xcode; building the tool from the sources needs Swift 6.3 or newer
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0           # the diff against the base branch needs its history
      - uses: RyoHirota68/xcmutate@v0.13.0   # a released version; the tag must exist
        with:
          workspace: App.xcworkspace
          scheme: App
          destination: platform=iOS Simulator,name=iPhone 16
          fail-on-survived: true
```

In a `pull_request` event the action mutates only the lines that the pull request changes (`--since origin/<base branch>`); in other events it mutates whole files unless you set `since`.

| Input | Meaning | Default |
|---|---|---|
| `project` / `workspace` / `package` | Exactly one of them, relative to the repository root | none |
| `scheme` | Scheme to build and test | required |
| `destination` | `xcodebuild` destination. A simulator given as `platform=iOS Simulator,name=<device>` (optionally `,OS=<version>`) or `id=<UDID>` is looked up, booted and passed on as `id=<UDID>` | `platform=macOS` |
| `since` | Git ref for the diff; `none` for whole files | the base branch in a pull request, otherwise nothing |
| `files` | Swift files to mutate. On one line, separated by spaces; or one per line, and then a path may hold spaces. Shell patterns are expanded | all tracked Swift files outside test directories |
| `select-tests` | `none`, `auto` or `reach` | `none` |
| `shared-process` | `true` for `--shared-process` | `false` |
| `baseline-report` | JSON report of an earlier run: fail only for mutants that are undetected now and were not then | none |
| `fail-under` | Fail when the score in percent is below this | none |
| `fail-on-survived` | `true`: fail when a mutant is not detected | `false` |
| `max-mutants` | Examine at most this many mutants ([below](#keeping-a-run-inside-a-time-budget)) | none |
| `time-limit` | Stop after this time and report what was run, e.g. `45m` | none |
| `args` | Further arguments for `xcmutate run`, one per line. An option and its value are two arguments: two lines | none |
| `version` | A release such as `0.13.0` or `v0.13.0`, or `source`. A release that is named and cannot be downloaded fails the step | the release of the action's tag; the sources when the action is used by branch or commit |
| `work-dir` | Work directory of the run | a directory under the runner's temporary directory |
| `package-cache` | A `SourcePackages` directory to seed the build with ([Caching](#caching)) | none |
| `report-directory` | Where `mutation.json`, `mutation.md` and `mutation.html` go | `mutation-report` |
| `artifact-name` | Name of the uploaded artifact; empty for none | `mutation-report` |
| `annotations` | `true`: undetected mutants become warnings on their lines | `true` |
| `token` | Token for downloading the release binary | the workflow's token |

Outputs: `exit-code`, `score` (0 to 1), `undetected` (the number of Survived and NotReached), `report` (the path of the JSON report).

**How the tool gets there.**

- For a release (`uses: …@v0.13.0`, or `version: 0.13.0`) the action downloads `xcmutate-<version>-macos-universal.tar.gz` from the release and checks its SHA-256.
- When the action is used by a branch or a commit, or with `version: source`, it builds the tool from the sources of the action's checkout with `swift build -c release`. That takes several minutes and needs Swift 6.3 or newer on the runner. If the runner's Swift is older, the action stops before the build and says why.
- If the download fails, the result depends on where the version came from. A version named in `version` fails the step, because the job would otherwise run another version than the one it asked for. A version taken from the action's tag is built from the sources of that tag instead, with a notice.
- The executable is cached with `actions/cache`, keyed by the version, or by a hash of the sources and the Swift version. A cached executable whose `--version` is not the one asked for is not used.

**Annotations.** GitHub shows at most ten warnings per step, so the action writes ten (survivors before unreached code) and a notice with the number that was left out. The job summary and the artifact have all of them.

Ready-made workflows are in [`examples/workflows/`](../examples/workflows):

| File | What it does |
|---|---|
| [`pull-request.yml`](../examples/workflows/pull-request.yml) | The lines of a pull request; fails for gaps that the main branch did not already have |
| [`nightly.yml`](../examples/workflows/nightly.yml) | Whole files on the main branch every night; its report is the baseline for the pull-request workflow |
| [`swift-package.yml`](../examples/workflows/swift-package.yml) | A Swift package on macOS, no simulator |

### "No new gaps": a baseline report

`fail-on-survived` on a diff also fails for gaps that were already there on the lines a pull request happens to touch. `baseline-report` fails only for mutants that are undetected now and were not undetected in an earlier report. Mutants are matched by their stable keys, which do not depend on line numbers.

The earlier report has to contain the mutants in question, so it must come from a run over the same files on the main branch without `--since`. That run is long. The nightly workflow makes it and keeps the JSON as an artifact, and the pull-request workflow downloads the latest one with `gh run download`. Exit code 5 then means: this pull request has an undetected mutant that main did not have.

What counts as new:

- Not new: mutants that the nightly run did not examine (not run before its time limit, left out of its sample, or in a file that existed then and that it did not mutate).
- New: the gaps of a file that did not exist at the baseline's commit.
- Also new: the gaps of a file that was only renamed, because a mutant's key holds the path of its file. Make the baseline again after renaming files. The pull-request run prints how many such mutants there are.

To tell these cases apart, the tool asks git about the baseline's commit, so the checkout must have it. A shallow clone (`actions/checkout` without `fetch-depth: 0`) does not. The run then reports this, and the gate ends with exit code 7 (it cannot be confirmed) unless something else already fails it.

When no baseline is found, the example workflow prints a warning and gates on every undetected mutant of the changed lines instead.

### Without the action: plain shell

[`examples/ci.sh`](../examples/ci.sh) is the same sequence for any CI system that gives you a Mac: boot a simulator and name it by id, run the tool with reports written to files, map the exit code. The essentials:

```bash
xcrun simctl boot "$UDID" || true; xcrun simctl bootstatus "$UDID" -b
xcmutate run --since origin/main \
  --workspace App.xcworkspace --scheme App --destination "id=$UDID" \
  --select-tests reach --shared-process --time-limit 45m \
  --no-caffeinate --reporter text \
  --report json:mutation.json --report markdown:mutation.md --report html:mutation.html \
  --fail-on-survived
```

On GitHub without the action, add `--report "markdown:$GITHUB_STEP_SUMMARY"` for the job summary and `--report github:-` for the annotations (the text report then goes to standard error).

### Exit codes

| Code | Meaning | What it says about the tests |
|---:|---|---|
| 0 | Finished; every requested gate passed (or no gate was requested) | Nothing was found, among what was examined |
| 3 | `--fail-on-survived`: a mutant was not detected | They have a gap |
| 4 | `--fail-under`: the score is below the threshold | They have gaps |
| 5 | `--baseline-report`: an undetected mutant that the earlier report does not have | The change added a gap |
| 6 | The tests fail without any mutant, or no test ran | Fix the tests or the selection first |
| 7 | Not everything could be examined: mutants could not be run (with or without a gate; the report says how many beside its score), or a gate was requested and mutants were not run before `--time-limit` or a file could not be mutated | Nothing about the tests. Do not read it as "the tests are weak". If mutants could not be run, read the `workerDropped` warning: the simulator or the tests without mutants are what failed |
| 2 | The run itself did not work: build, simulator, the tool; or the time limit was reached before the first mutant | Nothing |
| 64 | The options are wrong | Nothing |
| 130 | Interrupted (the job was canceled) | Nothing |

When several gates fail, the lowest of their codes is returned. A report is written for the codes 0, 3, 4, 5, 7 and 130.

### Keeping a run inside a time budget

In the order in which they should be tried:

1. `--since`: only the changed lines. This is what makes a pull-request run short at all.
2. Narrow the tests (`--select-tests reach`, with `--shared-process`) when a run of all tests takes more than a few seconds: [speed.md](speed.md).
3. `--time-limit 45m`: when the time is up, the running tests are stopped, the mutants that have a verdict are reported, and the others are listed in the report as not run (`pendingKeys`, `timeLimitReached: true`, a `timeLimit` warning).
   - The exit code is 0 without a gate. With a gate it is the gate's own code if the results so far already fail it (a survivor is a survivor), and otherwise 7, because a run that did not finish cannot confirm a gate.
   - Set the limit below the job's `timeout-minutes`, so that the job ends with a report instead of being canceled without one.
   - The limit counts from the start of the run and must leave room for the build and the two runs of the tests without mutants. If it is reached before the first mutant, there is no report and the exit code is 2.
   - `--resume` continues a run that the limit cut short, in the same work directory.
4. `--max-mutants 200`: examine at most that many mutants.
   - Which ones is decided by their stable keys alone (the keys with the smallest SHA-256). The same sources give the same sample in every run and on every machine, and a change elsewhere in the code moves few mutants in or out of the sample.
   - The reports say how many mutants were left out (`sampling`, a `sampled` warning).
   - **The score and the gates are those of the sample.** A survivor in the sample is a real gap, and a gate that passes says nothing about the mutants that were not examined.
   - Use it for a trend over a whole project, not as the gate of a pull request. With `--since` there are rarely enough mutants for it to matter.
   - The report of a sampled run can be the `baseline-report` of the pull-request gate. It lists the mutants that it left out, and a gap among them is not counted as new.

`--time-limit` keeps the mutants that the tool got to, in its own order; `--max-mutants` keeps a sample spread over the code. A nightly run of a large project can use both: a sample that fits the night, and the limit as a guard.

### Caching

- The tool. The action caches the executable. Without the action, cache the file itself, keyed by the version.
- Swift packages of your project. `--package-cache <SourcePackages directory>` clones an existing package checkout into the work directory's DerivedData before the first build, so packages are not fetched again (`package-cache` input of the action). The example workflows keep such a directory with `actions/cache`, keyed by the hash of `Package.resolved`; when the directory does not exist yet, the action fills it from the build of that run.
- The build. The work directory (`--work-dir`) holds the DerivedData of the instrumented build, and a later run with the same work directory builds incrementally: on a developer's Mac, 233 to 280 s from nothing against 44 to 56 s afterwards on a large app ([speed.md](speed.md)). Whether that carries over to a hosted runner **has not been tried**: a fresh checkout gives every file a new modification time, and a cache of several gigabytes takes time to restore. On a self-hosted runner, where the work directory simply stays, it does carry over; give every job that can run at the same time its own `--work-dir`, since one run locks its work directory.
- Results. `--reuse` takes over Killed results from an earlier run in the same work directory while no product code changed ([usage.md](usage.md#reusing-results)). It helps a re-run after tests were added, on a runner that keeps the work directory.

### Practical notes

- **One booted simulator, named by id.** A simulator that `xcodebuild` has to boot is shut down after every invocation, which multiplies the time per mutant. The action boots it; in plain shell, `xcrun simctl boot` and `bootstatus -b` first.
- **Grant the app's permissions on the simulator first.** A runner's simulator is new: the first use of the camera, of notifications or of the location shows a system dialog over the app, the tests hang behind the dialog regardless of the mutant, and the tool drops the destination after a few mutants (the report then says that mutants could not be run, and the exit code is 7). With the action: the input `simulator-permissions`, one `<service> <bundle id>` per line (`camera com.example.App`). In plain shell: `xcrun simctl privacy <UDID> grant camera com.example.App` after booting.
- Projects that generate their Xcode project need `--prepare 'xcodegen generate'` (or the equivalent); the command runs in the work copy. With the action, pass it through `args` (`--prepare` on one line, the command on the next).
- Files that git ignores are not in the work copy. Create them in `--prepare` ([usage.md](usage.md#when-the-build-cannot-find-a-file)).
- Accepted mutants (`xcmutate.accepted.json`, committed in your repository) do not count as undetected, so a gate does not fail for them.
- **Pin the version** (`@v0.13.0`, not a branch), so that results do not change under you.
- Xcode build phase instead of CI: `--reporter xcode` prints survivors as warnings that Xcode shows on the source lines.

## A large app

What the measurements in [speed.md](speed.md) say for an app whose unit tests take a minute or more. The numbers there come from a fixture with 1,105 tests (31 s) and from runs on a production app with about 7,000 tests (90 to 100 s). None of those runs was made in CI. They show the conditions under which a run was fast on a developer's Mac, and are not a promise for a hosted runner.

- Pull requests: `--since`, `--select-tests reach`, `--shared-process`. With a long test run, the time per mutant is the time of the tests that run for it. `reach` runs, for each mutant, the suites that execute it; it needs `--shared-process` to narrow code that a single test covers.
- Budget for the survivors. With `reach`, a mutant that passes the tests that reach it is run once more against all tests before it is reported as Survived ([usage.md](usage.md#selecting-tests) says why). Each such mutant costs one run of all tests. On the fixture with 1,105 tests, 75 mutants took 495 s without that run and 954 s with it, for 12 survivors. On a diff the survivors are few; in a nightly run over many files they are the larger part of the time. `--no-recheck-survivors` removes the cost and marks those survivors as "not run against all tests"; use it only when you accept that such a survivor may be one that all tests would have killed.
- A test plan for mutation runs: one configuration, unit tests only. Every configuration multiplies the runs; a UI test target in the scheme is built every time, and a selection that contains one is not served by `--shared-process`. Select the unit-test targets with `--only-testing`.
- A time limit below the job's timeout, so that a slow night ends with a report (`time-limit`).
- Numbers to publish, or a nightly run that has the time: `--confirm-kills full` (through `args`) also runs every mutant that its narrowed tests detect against all tests. It costs one run of all tests per detected mutant.
- The whole project, nightly: name the files that matter (`files`), and take a sample (`max-mutants`) if the run does not fit; the report of that run is the baseline of the pull-request gate.
- Hosted or self-hosted. A self-hosted Mac keeps the simulator booted and the work directory warm, which is where most of the fixed cost of a run goes (build, package fetch, first launch). On a hosted runner all of that is paid in every job; how long that takes for your app is something only a first run will show.

## This repository's CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) builds the tool and runs its unit tests (`swift build`, `swift test`) on a macOS runner. The unit tests need no simulator. [`.github/workflows/release.yml`](../.github/workflows/release.yml) builds the release archive for a tag ([install.md](install.md)). [`.github/workflows/smoke.yml`](../.github/workflows/smoke.yml), also started by hand, runs the action once on the smallest fixture package and compares the verdicts with the expected ones. Its purpose is to show whether a run works with the Xcode of the runner image. It has been run once and passed (above).

`ci.yml` runs on pushes to `main`, on pull requests, and when started by hand (`workflow_dispatch`): the "Run workflow" button on the Actions tab, or `gh workflow run ci.yml`. Pushes run it only in `RyoHirota68/xcmutate`, not in forks. `release.yml` starts when a tag `v<version>` is pushed.

`Package.swift` declares Swift tools version 6.3. On 2026-11-24 the workflow passed on GitHub's standard macOS image (`macos-26-arm64`, Xcode 26.6, Swift 6.3.3): `swift build` and 332 tests. The runner label and the Xcode version are inputs, so that they can be changed without editing the workflow:

| Input | Repository variable (used when the input is empty) | Default |
|-------|----------------------------------------------------|---------|
| `runner` | `CI_RUNNER` | `macos-latest` |
| `xcode` (selects `/Applications/Xcode_<value>.app`) | `CI_XCODE` | the runner's default Xcode |

Read the "Show toolchain" step of a run. If a later image has a Swift older than 6.3, pick a runner image and Xcode version that has it and set the two repository variables. For `push` and `pull_request` the inputs are empty and the workflow uses the repository variables, then the defaults.

### What is not in CI

`scripts/verify-fixture.sh <UDID>` runs all fixture expectations on an iOS simulator; `scripts/verify-muter-fixtures.sh` runs Muter's sample projects; `scripts/verify-regressions.sh`, `scripts/verify-action.sh` and `scripts/make-release.sh` run on macOS without a simulator. None of them is a workflow, on purpose:

- the first two need a simulator runtime, XcodeGen and, for the second, a network fetch, none of which has been tried on a hosted runner;
- together they take the better part of an hour of macOS minutes per run;
- several expectations depend on timing (timeouts, crashes), which is likely to behave differently on a loaded shared runner, and an unverified workflow that fails for such reasons would teach people to ignore it.

They are run by hand before changes to `Sources/`, `scripts/`, `action/` or `Fixtures/` are merged; [CONTRIBUTING.md](../CONTRIBUTING.md) says when. Turning the macOS-only ones into a workflow is reasonable once someone has run them on a hosted runner and seen stable results.
