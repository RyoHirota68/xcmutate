# Making a run faster

A run costs one build, plus an amount per mutant. That amount depends on two things, and this page keeps them apart:

- How many test processes are started. Each launch has a fixed cost that has little to do with your tests.
- How long the tests are that each step runs. No option removes this cost; options can only narrow the tests.

In a project with a short test run the first dominates, and in a project with a long one the second does. The advice for the two differs.

## How the numbers were measured

- Machine: one 12-core Apple silicon Mac with 48 GB, Xcode 27.2, an iOS 27.2 simulator. The Mac was running other builds at the same time, so read the times with a margin.
- Version: 0.13.0 unless a table or sentence says "earlier development version". Those versions were never published. Their numbers are kept where the measurement was not repeated.
- Repetitions: most numbers are from a single run. Repeated runs are noted.
- What is counted: "mutant phase" is the time from the first mutant to the last. It does not include the build or the baseline.

The projects that appear below:

- The fixture: `Fixtures/SampleApp`, an iOS app with an app-hosted unit-test target. Its 105 tests take 0.2 s, and the tests reach 377 of its mutants.
- The load fixture: the same app with 1,000 added tests that only take time (`scripts/make-load-fixture.sh`). One run of its 1,105 tests takes 31 s inside a process and 44 s under `xcodebuild`. The measurements use five files with 75 mutants.
- LogicKit: `Fixtures/LogicKit`, a Swift package without a host app (6 tests, 23 mutants).
- The app: a large production iOS app with about 7,000 tests that take 90 to 100 s.

## Where the time goes

By default every mutant gets one `xcodebuild test-without-building`, which launches the test host from scratch:

| One mutant, one process | Fixture (app-hosted) | The app, about 25 tests selected | LogicKit on a simulator (no host app) | LogicKit on macOS |
|---|---:|---:|---:|---:|
| Whole invocation | 5.0 to 5.4 s | 7.8 s | 2.0 s | 2.2 s |
| …of which the tests | 0.2 s | 0.3 s | under 0.1 s | under 0.1 s |

With short tests, almost all of the time is spent outside the tests: starting `xcodebuild`, installing and launching the host app, connecting the test runner. That cost is paid again for each mutant, so the number of launches decides the time.

With long tests the opposite is true. On the app, a run of all tests takes 88 s per mutant. And the tests are not run only once per mutant:

- a detection is followed by a run without mutants, so that state left behind is not counted as a detection of the next mutant;
- a shared process starts with two runs without mutants;
- a mutant that never ends is waited for during a multiple of the tests' time.

Each of these steps is as long as the tests it runs. The second half of this page is about them.

## What the tool can do

In the order in which the steps usually help.

### 1. Run fewer mutants: `--since`

`--since origin/main` keeps the mutants on changed lines. This saves more than any other step: the fixture has 377 reached mutants, and a typical diff has a few dozen.

### 2. Boot the simulator first

Run `xcrun simctl boot <UDID>` before the run. A simulator that `xcodebuild` has to boot is shut down after every invocation: about 26 s per mutant instead of 5 s on the fixture. `run` warns when the simulator is not booted.

### 3. Run only the tests that matter

All tests run for every mutant unless you say otherwise.

- `--only-testing <Target>/<Class>`: name them.
- `--select-tests auto`: the tests named after the mutated files.
- `--select-tests reach`: for each mutant, the suites that actually executed it.
- Leave UI test targets out. They are not supported and would only cost time.

On the app, a mutant took 7.6 to 7.8 s with either kind of selection instead of 88 s (earlier development versions). In 0.13.0, a mutant that passes its narrowed suites is also run against all selected tests; see [what the recheck of survivors costs](#what-the-recheck-of-survivors-costs).

Narrowing the tests of a mutant narrows every step that runs "its tests": its own run, the run without mutants before it, and its timeout. With a test run longer than a few seconds, `--select-tests reach` is the first option to add, and it needs `--shared-process` to work fully. Without `--shared-process`, a mutant that exactly one test reaches is not narrowed ([usage.md](usage.md#selecting-tests) explains why).

### 4. One test-plan configuration: `--only-test-configuration`

A test plan with two configurations runs the tests twice per mutant and relaunches the host each time. In one measurement, picking one of two configurations took a mutant from 12.3 s to 7.8 s. `run` prints a note when a plan has more than one configuration.

Whether one configuration is enough is your decision. It is enough when the code under test does not depend on what the configurations vary (language, region).

### 5. Several mutants per process: `--shared-process`

The test host is launched once, and a driver inside it runs the mutants one after another.

- A mutant whose tests fail there, and pass again without it, is Killed.
- A mutant whose tests pass there is run once more in a new process, with the mutant on from the start.
- A mutant that cannot be judged in a process that has already run the tests also gets a new process ([usage.md](usage.md#running-faster)).

The tool starts these processes itself, without `xcodebuild`, which keeps the second run cheap.

With short tests:

| | Version | One process per mutant | `--shared-process` | Same verdicts |
|---|---|---:|---:|---|
| Fixture, all 377 reached mutants | 0.13.0 | 4,150 s (11.0 s per mutant) | 536 s (1.4 s) | 403 of 403 |
| Fixture with `--select-tests reach` | 0.13.0 | 4,175 s | 467 s (1.2 s) | 403 of 403 |
| Fixture, two test-plan configurations × two unit-test targets, 13 mutants | 0.13.0 | 447 s (34.4 s) | 153 s (11.8 s) | 15 of 15 |
| LogicKit on macOS, 23 mutants | earlier | 54 s (2.3 s) | about 1 s (under 0.1 s) | 23 of 23 |
| BonMot (a library among Muter's sample projects, macOS), 183 mutants | earlier | 1,080 s (5.9 s) | 534 s (2.9 s) | 269 of 269 |
| FFCParserCombinator (same origin, macOS), 18 mutants, 10 of which crash | earlier | 207 s (11.5 s) | 172 s (9.6 s) | 19 of 19 |

What the option saves depends on what your mutants do:

- Killed in the shared process: about one run of the mutant's tests plus one check run of the same tests.
- Tests pass (a survivor, most of the time): one run in the shared process plus one new process. What the new process costs, apart from the tests (measured with an earlier development version):

  | Test host | Under `xcodebuild` | Started by the tool |
  |---|---:|---:|
  | No host app, macOS | 2.2 s | 0.1 s |
  | App on a simulator that the tool created for `--workers` | 5.2 s | 1.2 s |
  | App on a long-lived simulator shared with other work | 5.2 s | 3.0 to 3.4 s |

  The difference between the last two rows is the time the app itself takes to start on that simulator. The tool can remove `xcodebuild`'s share of a launch, not the app's.
- A mutant that never ends: the limit of one run of its tests, in the shared process, when the same tests had just passed there without mutants (11.5 s on the fixture, 22 s on the load fixture). The shared process is lost and a new one is started.
- A crash: the shared process is lost, and the mutant is run under `xcodebuild`, twice (a Crash must repeat). When crashes and hangs come more often than kills, the tool stops sharing for a while and runs mutants one at a time. Such code costs about what it costs without the option (FFCParserCombinator above).
- Code that runs at app launch or once per process: always a run under `xcodebuild` against all selected tests (21 of 377 mutants on the fixture).

`--trust-shared-survivors` reports a mutant whose tests passed in the shared process as Survived without the second run. The second run exists because a process that has already run the tests can hide a failure. Without it, a survivor in the report may be a mutant that a clean process would have killed ([usage.md](usage.md#running-faster) has the example). Since the second run is cheap, there is little to gain from skipping it.

`--no-direct-launch` lets `xcodebuild` start every process. The tool does this by itself, with a warning, when your tests do not pass in a host that it started.

The option is off by default. It needs tests that pass twice in a row in one process and no UI test target in the selection. When it cannot be used, the run says why and proceeds as without it.

### When `--shared-process` helps, and when it does not

The numbers above come from projects whose tests take a fraction of a second. With a long selection the option can cost time. On the app, with about 1,200 tests in the selection (about 45 s for one run), **an earlier development version was slower with the option than without it**: 8,039 s against 4,676 s for the same mutants (the second number with two workers and `--confirm-kills none`).

The time went into steps that are as long as a run of the selection: the runs without mutants between mutants, the two runs at each start of a shared process, and the waits for mutants that never end. Later changes shortened each of those steps. On the load fixture, which reproduces them:

| Load fixture, `--select-tests reach --shared-process --no-recheck-survivors`, 75 mutants | That earlier version | 0.13.0 |
|---|---:|---:|
| Mutant phase | 1,903 s (25.4 s per mutant) | 495 s (6.6 s) |

With the default recheck of survivors, the 0.13.0 run takes 954 s ([below](#what-the-recheck-of-survivors-costs)).

`--shared-process` helps when

- most mutants are killed or survive without crashing or hanging the process. Each of them saves a launch (4 to 8 s with a host app, 2 s without);
- the tests that a mutant runs are short, because they are few or because `--select-tests reach` narrows them. Inside a shared process a killed mutant costs two runs of its tests, and four when it follows a survivor;
- the tool can start your test host itself (no `directLaunchUnavailable` warning). Otherwise every survivor costs a full `xcodebuild` launch, as without the option.

It helps little, or costs time, when

- every mutant runs a long selection (no narrowing). A killed mutant then costs two to four runs of the selection inside the process. With 45 s per run, saving a 5 s launch gains nothing. Narrow first (item 3);
- most mutants crash the test host. Each costs the shared process, a new one, and two runs under `xcodebuild`;
- much of the mutated code runs once per process (`static let`, lazily built caches, app start-up). Each such mutant needs a run of all selected tests in a separate process, and another without mutants before the next mutant;
- the tests are slow and the mutants few. The two runs at the start of the first shared process (62 s on the load fixture) are needed once per unit-test target and configuration, and a handful of mutants does not earn them back.

### A large production app

The same eight files of the app were run five times with `--select-tests reach --shared-process`. They have about 200 mutants, about 180 of which the tests reach, and about 1,200 tests in the selection. The times are for the mutant phase; "per mutant" divides by the reached mutants.

| Run | Mutant phase | Per reached mutant |
|---|---:|---:|
| An earlier development version | 8,039 s | 44.7 s |
| 0.13.0, first run (during development of that version) | 5,305 s | 29.5 s |
| 0.13.0, second run | 4,184 s | 23.2 s |
| 0.13.0, third run | 4,373 s | 24.3 s |
| 0.13.0, fourth run (final version; other simulators were running at the same time) | 3,929 s | 21.8 s |

Every mutant was detected, or not, exactly as in the first run, in all four later runs. So on this app a mutant costs about 22 to 24 s, and 200 mutants take a little over an hour. Where the time goes:

- More than a third is the recheck of survivors. In the second and third runs, about 30 mutants passed their narrowed tests, and each was run against all selected tests (about 47.5 s per run). None of those runs detected anything. With `--no-recheck-survivors` the second run would take about 2,900 s, or 16 s per mutant (computed from the run, not measured), and its survivors would be marked as not run against all tests.
- Starting the test host is no longer where the time is. In the first run the tool could not start this app's host itself; from the second run on it could, and a recheck went from 54 s to 47.6 s. The tests take about 44 s of that.
- Mutants that crash the test process or never end are a large part of these files, and each costs a process and a wait. In the fourth run a mutant that crashes the app cost 17 to 20 s (up to 149 s before), and a mutant whose test never ends was stopped twice after 46 s each (220 s before).

For comparison, the conditions under which the same app was fast: on two files whose mutants are reached by about 25 tests, an earlier development version took 7.8 s per mutant with one process per mutant and 2.1 s with `--shared-process`. The difference to 22 s is not the tool's version. It is the selection (every run of "the tests" is about fifty times longer), the survivors (each one a run of all selected tests), and the share of mutants that crash or hang.

### What the runs without mutants cost

`--confirm-kills` (default `auto`; [usage.md](usage.md#failures-caused-by-state-left-behind)) runs tests without mutants, so that state left behind by one run is not counted as a detection of the next mutant. The numbers in this section were measured with an earlier development version.

- One process per mutant: after a run that did not pass, one more launch of the test host before the next mutant. On the fixture, where nothing is narrowed and the tests take 0.2 s, that was 333 runs and 1,762 s of 4,134 s (5.3 s each: the launch). On the load fixture with narrowed tests it was 25 runs and 266 s of 589 s.
- `--shared-process`: the checks are runs of the tests inside the process. Separate processes are needed only before a run under `xcodebuild`: 17 runs and 56 s of 528 s on the fixture, 9 runs and 178 s of 494 s on the load fixture.

If your run is long and most mutants are detected, this is one more reason for `--shared-process`. `--confirm-kills none` removes these runs and, with them, the protection.

### What the recheck of survivors costs

With `--select-tests reach`, a mutant that passes the tests that reach it is run once more against all selected tests before it is reported as Survived. [usage.md](usage.md#selecting-tests) says why: a test that does not run the mutated code can still read what another test left in the process.

The cost is one run of all selected tests per mutant that passes its narrowed tests. A mutant that its narrowed tests kill costs nothing extra.

| Load fixture (31 s for one run of the selection), 75 mutants, 12 of which survive | Mutant phase | The 12 runs against all tests |
|---|---:|---:|
| `--select-tests reach --shared-process` (with the recheck, as by default) | 954 s | about 38 s each, in processes that the tool starts |
| `--select-tests reach --shared-process --no-recheck-survivors` | 495 s | n/a |
| `--select-tests reach`, one process per mutant, on the variant in which two suites reach every mutant | 1,608 s | about 42 s each, under `xcodebuild`, plus one run of all tests without mutants before the first |
| The same with `--no-recheck-survivors` | 1,066 s | n/a |

The verdicts are the same with and without the recheck: this fixture has no test that reads what another left behind. The table has the times of the final check. Three earlier runs of the first row took 946 s, 946 s and 995 s; in the last of them one recheck got no result from the process that the tool had started and was repeated under `xcodebuild`.

Three things keep the cost at one run per survivor:

- With `--shared-process` a survivor needs a run in a new process anyway. That run is made against all selected tests instead of the narrowed ones, so there is one run, not two. It stops at the first failing test.
- The rechecks are made after everything else, one after the other. Under `xcodebuild`, a run of all tests has to follow a passing run of all tests without mutants. Rechecks that pass keep that state, so one such run serves them all.
- The remaining time in the progress lines counts the rechecks that are waiting.

Two shortcuts were not taken. The tests are not reordered so that a recheck fails sooner, because the order decides what a test can read from an earlier one. And several survivors are not switched on in one run, because one mutant can hide another.

What this means for a run: where the tests are good, survivors are few and the recheck is a small part. In code with many survivors (weak tests, or many equivalent mutants) it is the larger part, and the time of a run is roughly *survivors × one run of all tests*. `--no-recheck-survivors` trades that for results that say "not run against all tests".

### Timeouts

A mutant that turns a loop endless costs its whole timeout.

- For a run of all selected tests, the timeout is three times the baseline plus 30 s (161 s on the load fixture).
- For narrowed tests, it is taken from the time those tests took in the baseline: 50 s under `xcodebuild` and 22 s in a shared process on the load fixture ([usage.md](usage.md#timeouts)).

Since 0.13.0 a run under `xcodebuild` has further limits ([usage.md](usage.md#timeouts)):

- A limit until the first test starts. A mutant that hangs the start of the host app is not waited for as long as a run of every test may take.
- A limit from the first test on, so that the unused allowance for starting is not added to the time of the tests. On the fixture a mutant that never ends took 47 s under `xcodebuild` before and 36 to 38 s with these limits.
- A stop at the first crash of the host. `xcodebuild` restarts a host that crashed and goes on with the next test, as often as the host crashes. With many tests in the selection that is a long row of launches for a result that is known after the first.
- A limit for one test. The run is stopped when no test or suite has started or ended for longer than the longest such time of the baseline × factor + constant. Such a run is repeated once before it is a Timeout, so the limit is used only where two such waits are shorter than the limit of the whole run (in practice, for a long selection).

### 6. Several destinations at once: `--workers`

`--workers 2` on a simulator makes the tool create a second simulator like yours, boot it, use it and delete it. Or repeat `--destination` to use simulators that you prepared.

The speed of `--workers` was last measured with an earlier development version. With 0.13.0 the fixture check passed with `--shared-process --workers 2` (414 s against 536 s with one worker), but the table below was not repeated.

| 88 mutants of two fixture files (an earlier development version) | Mutant phase | Speed-up | Whole run (incl. creating simulators) |
|---|---:|---:|---:|
| One process per mutant, 1 worker | 462 s | n/a | 480 s |
| 2 workers | 197 s | 2.3× | 238 s |
| 3 workers | 151 s | 3.1× | 229 s |
| `--shared-process`, 1 worker | 104 s | 4.4× | 122 s |
| `--shared-process`, 2 workers | 64 s | 7.2× | 102 s |
| `--shared-process`, 3 workers | 68 s | 6.8× | 145 s |

What the table says about choosing a number:

- Each extra simulator costs about 25 s to create and boot, and about 20 s for its first test run, which installs the app. Under roughly 50 runs that need a separate process, a second worker gives little. A third gave nothing on runs of this size.
- The default is 1 and the tool never raises it. Use 2 for a long run. Use 3 only when well over a hundred mutants need a separate process, and not more than about a quarter of the physical cores.
- More than 3 workers were not measured. Memory per simulator was not measured either.
- On a shared machine, pass simulators that you reserved with repeated `--destination` rather than letting the tool create some.
- A Timeout seen while several workers run is run again alone at the end, because a busy machine makes slow mutants look like hangs. Mutants that really loop forever therefore cost two timeouts.

### 7. Reuse the work directory

The work directory (`~/Library/Caches/xcmutate/…`, or `--work-dir`) keeps DerivedData between runs. Do not delete it between runs of the same checkout. On the app, `build-for-testing` took 233 to 280 s from an empty DerivedData and 44 to 56 s afterwards. `--package-cache <dir>` saves fetching Swift packages into a new work directory. `xcmutate clean` removes work directories when you are done with a checkout.

### 8. Do not repeat what was settled: `--reuse`

When you run again after writing tests, most mutants are the ones that were killed last time. With `--reuse`, a mutant that an earlier run killed is not run again while no file outside the tests has changed and a test that killed it is unchanged ([usage.md](usage.md#reusing-results)).

On LogicKit, after adding a test file, 18 of the 20 killed mutants were taken over and only the 5 that had survived were run. After any change to product code, nothing is taken over, so the option does not help while you are still changing the code under test. Without `--shared-process` each mutant taken over saves a launch (2 to 8 s); with it, about 0.2 s.

## What you can change in the project

### Tests without a host app

A test bundle that is injected into an app needs the app installed and launched every time. A test bundle without a host (a Swift package's tests, or a framework's tests with *Host Application: None*) does not:

| One mutant, one process | App-hosted (fixture) | No host app (LogicKit) |
|---|---:|---:|
| iOS simulator | 5.2 s | 2.0 s |
| macOS | n/a | 2.2 s |

Logic that lives in a package or a framework, with its own test target, costs less than half per mutant. With `--shared-process` it came to under 0.1 s per mutant on macOS, survivors included, because a new process without a host app starts in a tenth of a second. If the code does not need iOS, `--destination 'platform=macOS'` also saves you the simulator. Run the package directly:

```bash
xcmutate run --since origin/main --package Packages/Core --scheme Core --destination 'platform=macOS' --shared-process
```

It also keeps the selection short: a package's own tests instead of all the tests of the app.

### A test plan for mutation runs

- One configuration, or pass `--only-test-configuration` (item 4).
- No UI test target in the plan or scheme that you give to the tool. It is built every time even when it is not run.
- Code coverage, test timeouts and diagnostics settings made no measurable difference to a mutant's time (5.0 s with and without), so there is no need to switch them off for speed.

### Tests that can run twice in one process

`--shared-process` begins by running your tests twice in one process. Tests that leave something behind that makes the second run fail (a singleton that must not be configured twice, a file that must not exist yet) rule the option out. Tests that clean up after themselves also keep the runs without mutants (`stateLeak`) quiet.

### Tests that do not hand state to each other

`--select-tests reach` narrows on the assumption that a test which does not run the mutated code is not affected by the mutant. A singleton that one suite configures and another reads breaks that ([usage.md](usage.md#selecting-tests)). The tool does not rely on the assumption for Survived: it runs every survivor of narrowed tests against all selected tests. So such tests make a run slower but do not make its results wrong. With `--no-recheck-survivors` they can make a Survived wrong.

### Code that runs once per process

A mutant in a `static let` initializer, in a lazily built cache, or in app start-up code is evaluated once per process. It always needs a separate process and every test (21 of 377 mutants on the fixture). There is nothing to fix in such code. It is the reason why a few mutants stay slow, and with a long test run they make up the end of a run.

### Code that exists for the tests

Helpers that only the tests call (`resetForTesting()`) produce mutants that cost time and say nothing. `excludeDeclarations` in `xcmutate.config.json` leaves them out by name ([configuration.md](configuration.md#xcmutateconfigjson)).

## What does not help

Measured and found to make no difference, so that you do not have to try:

| Tried | Result |
|---|---|
| Removing the performance-checker variables and libraries from the `.xctestrun` file; `-enableCodeCoverage NO`; `-test-timeouts-enabled NO` | 5.0 s per invocation in every variant. `xcodebuild` refuses to run a test target without the Main Thread Checker library in its testing environment |
| Several mutants in one `xcodebuild` invocation as test-plan configurations | 12 to 22% saved; each configuration still launches the host |
| `-only-testing` on `build-for-testing`, to build fewer targets | The UI test runner is built all the same |
| Fewer switches, to compile faster | The fixture with all 330 switches embedded builds in the same time as without (8 s and 9 s) |
| Keeping file modification times so that an unchanged instrumented file is not recompiled | It is recompiled all the same; on a large app a build with nothing changed still took about half a minute |
| `--select-tests reach` without `--shared-process`, for mutants that one test reaches | Not narrowed: one baseline cannot tell them from code that runs once per process. On the load fixture, where one test reaches every mutant, each mutant then costs a run of all tests and a run of all tests without mutants |
