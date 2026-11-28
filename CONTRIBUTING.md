# Contributing

Thank you for looking into xcmutate. The first section says which contributions fit the project. The rest explains how to build the tool, how its checks are organized and what a change is expected to come with.

## What to contribute, and how

The project is maintained by one person in spare time. A reply to an issue or a pull request can take a week or two, and no deadline is promised. The maintainer merges and releases; releases have no fixed schedule.

Welcome without asking first:

- bug fixes, and reports of bugs that can be reproduced;
- corrections to the documentation;
- more verification: a fixture case, a regression package, a check script.

Welcome, but open an issue before you write code:

- a new option, a new mutation operator, or a new report format. The tool already has many options, so each new one needs a problem that the existing ones do not solve;
- running tests with something other than `xcodebuild` (`swift test`, another build system). This would be a good addition. The checks behind each verdict rely on what `xcodebuild` reports, so the design has to say how they are kept.

Not accepted:

- a change that weakens the checks behind a verdict, that is, a path on which a mutant is reported as Killed or Survived without the evidence that [docs/verification.md](docs/verification.md#what-each-verdict-needs) lists. If you want this as an option that is off by default, open an issue first;
- support for languages other than Swift.

Every pull request must say which checks were run and show their result lines. [What to run for which change](#what-to-run-for-which-change) lists them, and the pull-request template asks for them. The long checks do not run in CI, so this is the only record. A pull request without results is sent back.

You may use AI tools to write a contribution. The same two conditions apply as for any other: you can explain what the change does, and you ran the checks yourself and pasted the results. What decides is whether the results are there.

No DCO sign-off and no CLA are needed. By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).

Everyone taking part is expected to follow the [code of conduct](CODE_OF_CONDUCT.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Get the source with git

```bash
git clone https://github.com/RyoHirota68/xcmutate.git
```

**Clone the repository; do not work from a downloaded source archive (zip).** The tool works on git repositories, and several check scripts run it on fixtures inside this one. Outside a git repository they fail: `scripts/verify-regressions.sh`, for example, ends every one of its runs with exit code 64.

## Environment

| | Verified with |
|---|---|
| macOS | 27.0, Apple silicon |
| Xcode | 27.2 (Swift 6.4.2). `Package.swift` needs Swift tools 6.3; building and the unit tests were also checked with Xcode 26.6 |
| For the fixture | An iOS simulator (iPhone 16, iOS 27.2 was used) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`, or set `XCODEGEN` to its path) |
| For the Muter check | Network access to GitHub; optionally an iOS simulator |

## Build and unit tests

```bash
swift build
swift test
```

`swift test` takes a minute or two and needs no simulator. Its output contains lines such as `xcmutate: state left behind: …`. Tests write them on purpose, and they are not failures; the last line says whether the tests passed.

Three kinds of tests deserve a note:

- `ExecutionOracleTests` compile and run small programs with `xcrun swiftc`. For each mutant they check that switching it on gives the same output as rewriting the source naively for that one mutant, and that with all mutants off the output equals the original's. Add a case here when you change how switches are embedded or nested.
- `FixtureExpectationTests` generate mutants for the fixture's sources and compare them with `Fixtures/SampleApp/expected.json` (which mutants exist, which candidates are ignored and why). They do not run the fixture's tests.
- Verdict rules are tested as tables against the pure function `Judgement.classify`.

## The fixture: `Fixtures/SampleApp`

An iOS app project made of small cases, each written to produce a known result.

- `SampleApp/` is the app (SwiftUI and UIKit; default actor isolation `MainActor`, Swift 6, `InternalImportsByDefault`, warnings as errors), `LegacyKit/` a Swift 5 framework, `Packages/SampleKit` a local package, `SampleAppTests/` unit tests hosted by the app (XCTest and Swift Testing), `SampleAppUITests/` a UI test target that must stay out of mutant runs.
- `SampleAppUnitATests/` and `SampleAppUnitBTests/` are two more unit-test targets, run by the scheme `SampleAppUnits` through the test plan `Units.xctestplan`, which has two configurations (Japanese and English). They cover `SampleApp/Units/UnitCases.swift` and exist for `--shared-process` with several targets and configurations.
- `SampleApp.xcodeproj` is not committed; `project.yml` generates it.
- Japanese text in the fixture is intentional. Comments, strings and test names in Japanese are there to check byte positions with multi-byte characters and display names of tests. Do not translate them. The `note` fields of `expected.json` are also in Japanese.

### The full check

```bash
scripts/verify-fixture.sh <SIMULATOR-UDID>                         # about 70 minutes
scripts/verify-fixture.sh <SIMULATOR-UDID> --shared-process        # about 9 minutes; the verdicts must be the same
scripts/verify-fixture.sh <SIMULATOR-UDID> --select-tests reach    # the same with test selection by reach
scripts/verify-fixture-units.sh <SIMULATOR-UDID> [--shared-process]  # two test-plan configurations, two unit-test targets
```

It runs every mutant with `xcmutate run` and compares each result with `expected.json`, together with the number of builds, the excluded files and the kinds of warnings. Every expectation must match, and no result may lack an expectation (the units script checks the `unitsExpected` fields). After a run with `--shared-process`, compare its report with the default mode's using `scripts/compare-reports.py`: every verdict must be the same. You provide the simulator and boot it first (`xcrun simctl boot <UDID>`); otherwise `xcodebuild` boots and shuts it down for every mutant and the run takes several times longer. Everything it produces stays under `.build/`.

Smaller steps, useful while working:

```bash
scripts/build-fixture.sh                 # build-for-testing of the original sources
scripts/build-fixture.sh --instrumented  # the same with all mutants embedded (into .build/fixture-instrumented)
```

### Adding a case

1. Add the code to a file under `Fixtures/SampleApp/SampleApp/` (or `LegacyKit/`, `Packages/SampleKit`) and mark the line with a trailing comment `// @case <marker>`. Markers are short and unique (`EB1`, `N3-sorted`).
2. Add or adjust tests in `SampleAppTests/` so that the result you intend (Killed, Survived, NotReached …) follows.
3. Add the expectation to `expected.json` under `cases`: an entry with `id`, `title`, `file` and `mutants`. Each element of `mutants` names the `marker` of the line, the `operator`, the `original` text, when needed the `occurrence` (order among mutants of the same operator on the line, starting at 1), and `expected` (`Killed`, `Survived`, `Timeout`, `NotReached`, `Ignored` with its reason, `CompileError`; `killKind: crash` for a crash). Look at a neighboring case for the exact shape. Add a `note` when the reason for an outcome is not obvious.
4. Run `swift test` (the generation side) and then the full check.

Write the intended outcome first and then run. If the run disagrees, find out why before changing the expectation; recording whatever came out defeats the purpose.

## Checking against Muter's verification code

```bash
scripts/verify-muter-fixtures.sh [<SIMULATOR-UDID>]
```

This fetches Muter at a fixed commit into `.build/external/muter` (nothing of it is committed here), runs its mutation examples and sample projects through xcmutate, and compares with Muter's unit-test expectations and regression snapshots. The macOS projects need no simulator; the iOS sample runs only when a UDID is given. A summary is written to `.build/muter-reports/summary.txt`. [docs/verification.md](docs/verification.md#muters-verification-data) says what to expect.

## Checking `--reuse`

```bash
scripts/verify-reuse.sh [<SIMULATOR-UDID>]
```

On a copy of `Fixtures/LogicKit` (and of `Fixtures/SampleApp` when a simulator is given) it runs four states with and without `--reuse` and compares the verdicts: nothing changed, a test file added, a test file changed, product code changed. It also checks how many results were taken over in each.

## Regressions found by reviews

```bash
scripts/verify-regressions.sh            # about 10 minutes; macOS only, no simulator
```

`Fixtures/Regression` holds small Swift packages that reproduce wrong results found by reviews and adversarial tests of the tool ([docs/verification.md](docs/verification.md#reproductions-of-the-wrong-results-that-were-found)): a file that one mutant's run leaves behind (`StateLeak`), a singleton that a mutant no longer empties and workers that collide on one Mac (`SharedState`), code that was dropped from the run or stopped it (`Shapes`), a mutant that only a test of another suite detects (`StateAcrossSuites`), and a suite that passes only after another suite has run (`DependentSuites`). Each has an `expected.json`; the script runs them with one process per mutant, with `--shared-process` and with `--workers`, and compares. `--confirm-kills none` shows the wrong results again.

## Guards on the simulator

```bash
scripts/verify-fixture-guards.sh <SIMULATOR-UDID>     # about an hour for the seven ways of running; name one or two for less
```

It copies the fixture, adds the cases of `Fixtures/GuardCases` (mutants that crash the host in a row, a suite that needs another suite, state that hides a mutant, a loop that does not end) and compares each way of running with the expected verdicts there. Run it after changes to the order of runs, to the checks between mutants, to timeouts, and to how a run under `xcodebuild` is stopped.

## Options for CI, the action and the release archive

```bash
scripts/verify-time-limit.sh     # about 8 minutes; macOS only: --time-limit, --resume after it, --max-mutants
scripts/verify-action.sh         # about 5 minutes; macOS only: the steps of the GitHub Action, outside GitHub
scripts/make-release.sh          # about 10 minutes: builds the universal archive and checks it; uploads nothing
```

`verify-action.sh` runs `action/*.sh` with the environment variables that a GitHub runner sets, against a small package with a pull-request-like change. It cannot check what only GitHub does (the expressions in `action.yml`, the cache and artifact actions, how annotations are shown); a change to `action.yml` therefore needs a run in a test repository. [docs/ci.md](docs/ci.md) keeps the list of what is unverified; update it when you verify something.

## A fixture with a long test run

```bash
scripts/make-load-fixture.sh <dir outside the repository> --tests 1000 --seconds 30 --twin-tests
scripts/measure-load.sh <that dir> <SIMULATOR-UDID> <label> --select-tests reach --shared-process
```

The fixture's 105 tests take a fifth of a second, which hides every cost that grows with the length of a test run: the runs without mutants between mutants, the runs at the start of a shared process, the timeout of a mutant that never ends. `make-load-fixture.sh` writes a copy of the fixture with tests that only take time (and, with host options, a test host that behaves like the ones that cannot be started without `xcodebuild`); `measure-load.sh` runs five of its files and prints where the time went. The measurements with long test runs in [docs/speed.md](docs/speed.md) were made this way. The normal checks do not use it.

## Checks on generated and public code

```bash
scripts/verify-generated-programs.sh     # about 5 minutes: 30 generated programs, all mutants off and one mutant on
scripts/verify-public-corpus.sh          # about 3 minutes after the first fetch: 4 public repositories at fixed commits
```

Neither needs a simulator or `xcodebuild`. The first compares runs: the instrumented program with all mutants off against the original, and with one mutant on against the program with that change written into the source. The second instruments about 500 files of public code (fetched into `.build/corpus`, never copied into this repository) and type-checks Alamofire and Kingfisher as whole modules after instrumentation: a shape of code that no longer compiles once it is instrumented shows up there. Run both before a release and after changing an operator or the embedding; they are too slow for every `swift test`.

## The tool on itself

```bash
scripts/self-mutation.sh                 # one to two hours without StableKey.swift, which alone takes as long; macOS only
```

Runs the tool on the files that decide verdicts and lists the mutants that its own tests do not detect. [docs/verification.md](docs/verification.md#the-tool-on-its-own-source) has the last result.

## Measuring operators on real code

```bash
scripts/operator-campaign.sh        # about 1.5 hours; macOS only, no simulator
```

It fetches public packages at fixed commits into `.build/campaign` (nothing of them is committed), runs them with every operator on, and summarizes per operator. The rule for defaults and the result of the last run are in [docs/operators.md](docs/operators.md#the-rule). When you add an operator or change what one does, run it, read the new survivors, and put the summary per operator in the pull request.

## What to run for which change

| Change | Run |
|--------|-----|
| Documentation only | Check that relative links and anchors resolve |
| `Sources/`, `Tests/`, `scripts/` | `swift test`, the full fixture check and `scripts/verify-regressions.sh` |
| Operators, embedding (what is mutated and how it is written) | Also `scripts/verify-generated-programs.sh` and `scripts/verify-public-corpus.sh` |
| Verdicts, the journal, the stable key, gates | Also `scripts/self-mutation.sh` on the files you changed |
| Operators, embedding, verdicts, test selection | Also `scripts/verify-muter-fixtures.sh`, and say in the pull request what changed in its summary |
| Shared processes, starting test hosts, workers | The full fixture check in the default mode and with `--shared-process`, `scripts/verify-fixture-units.sh` both ways, `scripts/verify-muter-fixtures.sh` both ways (`MUTER_RUN_ARGS=--shared-process`), and `scripts/compare-reports.py` on each pair |
| The order of runs, the runs without mutants, timeouts (anything whose cost grows with the length of the tests) | Also `scripts/measure-load.sh` before and after, with and without `--shared-process`, and `scripts/compare-reports.py` on each pair |
| `--reuse` | `scripts/verify-reuse.sh <SIMULATOR-UDID>` |
| Interrupting, `--time-limit`, `--resume`, `--max-mutants` | `scripts/verify-time-limit.sh` |
| `--select-tests impact`, `--write-impact-map` | `scripts/verify-impact.sh` |
| `init`, run options in the config file | `scripts/verify-init.sh`, and `init` on the fixture app with a simulator of your own |
| `--confirm-kills restore` | The full fixture check with `--confirm-kills restore` on a simulator of your own |
| `action.yml`, `action/`, `examples/` | `scripts/verify-action.sh`; say in the pull request that the change was not run on GitHub, or where it was |
| `scripts/make-release.sh`, `packaging/`, `.github/workflows/release.yml`, `Package.swift` | `scripts/make-release.sh` |
| `Fixtures/SampleApp` | `swift test` and the full fixture check |

Neither long check runs in CI ([docs/ci.md](docs/ci.md) explains why), so please state in the pull request which ones you ran and the result line.

## Conventions

- Names derived from the tool's name come from `ToolNaming` (`Sources/MutatorCore/ToolNaming.swift`). Do not spell `xcmutate`, `__xcmutate` or `XCMUTATE_` in new source code.
- xcodebuild always gets an explicit `-derivedDataPath` under the work directory or `.build/`. Nothing may be written to `~/Library/Developer/Xcode/DerivedData`, and nothing in the user's working tree may be modified.
- Messages printed to the user are in English. So are comments, except in the fixture as noted above.
- A new operator needs: cases in the fixture with intended outcomes, an entry in [docs/operators.md](docs/operators.md), and evidence for its default. An operator is on by default only if, on real code, at most 5% of its mutants fail to compile and at most 10% of the reached ones are equivalent, on at least 20 reached mutants; a new operator starts off. [docs/operators.md](docs/operators.md#the-rule) shows how that is measured.
- **Do not report what was not measured.** If a change makes a verdict depend on something that is not observed (a log line, an assumption about timing), it needs a self-check that fails loudly instead.
- Record decisions. When you decide against something after measuring, write the numbers down in the pull request, and in [docs/speed.md](docs/speed.md#what-does-not-help) when users would otherwise try the same thing.

## Commits and pull requests

- Commit messages in English, imperative mood, one logical change per commit. Say what was verified when it is not obvious.
- Keep pull requests focused. Link the issue with `Closes #<number>`, and say whether the change alters anything for existing users (options, output, exit codes, report formats, stable keys).
- `README.ja.md` is the Japanese version of the README. If you cannot write Japanese, change `README.md` only and say so in the pull request; the maintainer brings the Japanese version in line.
- A typo or a documentation-only change needs no checks: write "docs only" in the pull request.
- For anything a user can notice, add a line to an "Unreleased" section at the top of `CHANGELOG.md` (create the section if it is not there).
- Do not include names, paths or identifiers from private projects in code, tests, fixtures, documentation or commit messages. Describe a private project by its shape ("a large UIKit app with …"), not by its name.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
