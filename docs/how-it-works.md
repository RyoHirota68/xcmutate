# How it works

[usage.md](usage.md#what-a-run-does) lists the steps of a run. This page explains the design behind them.

## Design goals

[Muter](https://github.com/muter-mutation-testing/muter) is the established mutation testing tool for Swift, and this project learned from its design, its issue tracker and its test data. xcmutate was written with these goals:

- Start from a diff. Every mutant costs seconds, so the normal run covers only the lines changed since a git ref.
- Build once. All mutants are compiled into one build as runtime switches (mutant schemata, the approach Muter also uses), including for app-hosted unit tests on an iOS simulator.
- Do not report what was not measured ([Self-checks](#self-checks)).
- Leave the working tree alone. `run` mutates a copy (APFS clones), so an interrupted run leaves nothing to restore.
- Report unreached code and weak assertions separately. "No test runs this line" and "tests run it but do not notice the change" are different problems.
- Give coding agents a compact JSON report that says, per function, what changed unnoticed and what a test would have to tell apart.

The list states what this tool aims for. It makes no claim about what other tools lack. What is said on this page about Muter comes from reading its source and issue tracker (commit `5c85409`, 2026-10-23, which was still its latest commit on 2026-11-24). No other mutation testing tool, Muter included, was run for a comparison.

## One build for all mutants (mutant schemata)

A mutation testing tool that rebuilds the project for every mutant spends most of its time building. xcmutate embeds every mutant into the source as a switch, builds once, and chooses the active mutant at run time through an environment variable.

```swift
// Original
if a > b && !items.isEmpty {

// Instrumented (still one line, so line numbers do not change)
if (__xcmutate.isOn(2) ? ((a > b) || !items.isEmpty) : ((__xcmutate.isOn(1) ? (a >= b) : (a > b)) && (__xcmutate.isOn(3) ? (items.isEmpty) : (!items.isEmpty)))) {
```

A helper is appended to the end of each mutated file (outline):

```swift
// xcmutate: generated helper. Do not edit.
@_silgen_name("getenv") nonisolated fileprivate func __xcmutateGetenv(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
nonisolated fileprivate enum __xcmutate {
    static let active: Int = __xcmutateGetenv("XCMUTATE_ACTIVE_<token>").flatMap { Int(String(cString: $0)) } ?? -1   // the token: one per work directory
    static let trace: __xcmutateTrace? = __xcmutateGetenv("XCMUTATE_TRACE").flatMap { __xcmutateTrace(path: String(cString: $0)) }
    @inline(__always) static func isOn(_ id: Int) -> Bool {
        if let t = trace { t.record(id, active: id == active) }   // reach and activation records, once per id
        return id == active
    }
}
```

Design points, each of which answers a failure seen in practice:

- Mutants are byte ranges, and rewriting is text splicing. Mutants are not matched to SwiftSyntax nodes by identity. Non-ASCII text (Japanese, emoji) does not shift positions.
- Nesting is built from the inside out. A mutated branch is "the original expression with this one mutant's change"; inner switches go only on the original side. Only one mutant is ever active, so this is sufficient.
- Line numbers are preserved. A mutated version of a multi-line expression is flattened to one line (newlines and comments become spaces, statement boundaries get `;`). Compiler diagnostics therefore point at original lines, which is how a mutant that does not compile is identified.
- Operator precedence is resolved with `SwiftOperators` before rewriting, including custom operators declared in other files under the same root. An expression with an operator of unknown precedence is left alone.
- The helper adds no `import`. Adding `import Foundation` clashes with the access level of imports in other files of the module ("ambiguous implicit access level for import"). The few C functions needed (`getenv`, `fopen`, `fputs`, `open`, `dup2`, …) are declared with `@_silgen_name`.
- The helper is `nonisolated` so that it can be called from any context in targets whose default actor isolation is `MainActor`.
- With every mutant off, the instrumented program behaves like the original. A candidate whose parentheses would cut an optional chain, for instance, is not made. The unit tests check this by compiling and running small programs.
- One expression carries at most 12 switches by default.
- The environment variable is read once per process; after that a switch costs an integer comparison. (With `--shared-process` the active mutant is read from a memory-mapped file at every evaluation instead; see below.)

To switch a mutant on for the tests, `run` puts `TEST_RUNNER_XCMUTATE_ACTIVE=<id>` into the environment of `xcodebuild`. `xcodebuild` strips the `TEST_RUNNER_` prefix and passes the variable to the test process, which for app-hosted unit tests is the host app on the simulator.

## Self-checks

A mutation testing tool can fail silently. Muter's issue tracker has reports of runs in which no mutant was applied and every mutant was reported as survived (issues #307 and #321, as read on 2026-11-20 at Muter commit `5c85409`; Muter itself was not run to confirm them). The checks below exist so that this tool reports a problem with itself instead of a wrong result. [verification.md](verification.md) says how the tool as a whole is checked.

| Check | What it catches |
|-------|-----------------|
| Static verification after embedding: one switch per id, no syntax error, the same number of lines | A broken rewrite, before any build |
| Baseline with all mutants off must pass | Tests that fail on their own; an instrumented build that changes behavior |
| Reach record: the baseline records which switches were evaluated | Mutants in code that no test runs (NotReached) are not run and not called survivors of tested code |
| Activation record: each mutant run records that its switch was evaluated *as active* | An environment variable that never arrived. Without the record nothing counts as detected or survived |
| Canary: the first mutant must produce an activation record | A setup in which activation cannot work at all; the run stops instead of producing hundreds of meaningless results |
| Test count equals the baseline's | Runs in which no test or only some tests ran |
| After a run that did not pass: the tests of the next mutant without mutants, before it (`--confirm-kills`); every test of a mutant's run has passed without mutants since the last run that did not pass | A file, a database row or a singleton's contents that a failing run left behind and that would fail the next mutant's tests: reported with the mutant that caused it (`stateLeak`), and not counted as a detection |
| Before a failure of narrowed tests (`--select-tests reach`) counts: the suites of that run by themselves, without mutants, once per combination of suites | A suite that passes in a run of all tests and fails when only it is run, because it needs what another suite leaves in the process. Narrowed to it, a run fails with or without the mutant. The check above did not cover this: after the baseline, which runs every test, each test counted as "has passed without mutants", although none had been run in the narrowed combination. Such suites are named (`dependentTests`) and their mutants are run against all selected tests |
| An observation is written to the journal when its run is the mutant's result, not before the checks that decide that | `--resume` taking a run as the verdict although the check that would have overturned it had not been made yet when the earlier run was cut short |
| With `--confirm-kills full`: a mutant that its narrowed tests detect is run against all selected tests | State that another suite leaves and that hides the mutant's effect in a run of all tests. Without the option such a detection is reported as what it is: detected by the tests that reach the mutant (`narrowedOnly`) |
| Final baseline after the last mutant (or, after a run that did not pass, all selected tests without mutants) | State leaked by a run that passed, state that fails a test which no later mutant ran, flaky tests (`stateLeak`) |
| A lock on the work directory | Two runs that would overwrite each other's work copy and build products |

The records are written by the test process on the simulator appending to a file on the host. Verdict rules are in one pure function (`Judgement.classify`) with table-driven tests; they are summarized in [reports.md](reports.md#how-a-verdict-is-reached).

## What a run costs

`xcodebuild build-for-testing` runs once (with `-IDEBuildingContinueBuildingAfterErrors=YES`, so that the errors of every file and target are collected in one build, and `COMPILER_INDEX_STORE_ENABLE=NO`). It runs again only when mutants that do not compile have to be removed.

Each mutant is one `xcodebuild test-without-building` with `-parallel-testing-enabled NO`, `-collect-test-diagnostics never` and its own result bundle. Measured on an iOS simulator:

| Per mutant | Fixture (app-hosted unit tests) |
|------------|-------------------:|
| Whole invocation | 5.2 s |
| The tests | 0.2 s |
| Starting `xcodebuild`, writing the result bundle | 1.1 s |
| Installing and launching the host app, attaching the test runner | 3.9 s |

So the time per mutant is dominated by a fixed cost per test process. That is why the tool is built around running few mutants (the lines of a diff) rather than all of them. Two options attack the fixed cost: `--shared-process` incurs it once for many mutants (and starts the test host without `xcodebuild`), and `--workers` spreads it over several destinations ([speed.md](speed.md)). `--reuse` avoids running at all the mutants whose Killed from an earlier run still holds ([usage.md](usage.md#reusing-results)).

## Several mutants in one process (`--shared-process`)

The default mode gives every mutant a clean process, which is simple to trust and costs a launch each time. In a shared process the launch is paid once:

- The switch. When `XCMUTATE_SHARED` names a file, the helper maps it into memory. Cell 0 holds the active mutant, and `isOn` compares against it at every evaluation, so the mutant can change while the process runs. The helper also counts in the file how often each switch was evaluated and how often it was evaluated as active; these counts replace the record file.
- The driver. The tool compiles a small driver of its own and starts the test host with it. The driver loads the project's own test bundle into the process and runs its tests itself: XCTest classes through `XCTestSuite(forBundlePath:)` and `XCTestCase.run()`, Swift Testing through its ABI entry point (`swt_abiv0_getEntryPoint`, looked up at run time). It writes one line per event to a file that the tool follows; the tool stops the host when the driver is done, when a run takes too long, or when the process dies.
- The principal class. XCTest creates one instance of the class that a test bundle names as `NSPrincipalClass` in its `Info.plist` when it loads the bundle; test targets use it for set-up that happens once. The driver loads the bundle itself, so it creates that instance too.
- Starting the host. There are two ways, with the same driver source.
  - Under `xcodebuild`, the driver is a test bundle with one XCTest test, named in a copy of the `.xctestrun` file with the same test host.
  - Without `xcodebuild` (the default), the tool starts the host itself. When the tests have no host app, it starts the `xctest` agent with the driver bundle. Otherwise it starts the app (`simctl launch` on a simulator) with the driver inserted as a dynamic library through `DYLD_INSERT_LIBRARIES`. The library's initializer waits for the app to finish launching, which is when XCTest would start the tests, and runs the session from the main run loop. The process gets the environment and arguments of the `.xctestrun` entry.
  - The first process started by the tool must pass the tests without mutants in the baseline's number. Otherwise `xcodebuild` starts everything, and what the failed process left (its output, the command and environment, the tests that had started) is kept under `logs/direct-launch-<n>` in the work directory.
- Units. A shared process serves one unit-test target in one test-plan configuration. With several, a mutant goes through each and is settled when all have judged it; the counts of the first run without mutants in the targets of each configuration must add up to the baseline's.
- What is taken from a shared process.
  - Killed: the tests failed while the switch was evaluated as active, directly after the same tests had passed without mutants, and passed again right afterwards without the mutant.
  - A failing run that came after another mutant's passing run does not count by itself, because that mutant may have left something in the process (such as a singleton that its `tearDown` no longer empties). The driver runs the tests without mutants, then the mutant again, and only a second failure is Killed.
  - A mutant whose tests passed is run once more in a new process that the tool starts, with the mutant switched on through the environment from the start, as in a run under `xcodebuild`. Only one answer is taken from that process: the tests passed, in the expected number, and the switch was recorded as active. That means Survived.
  - Everything else is decided by a run under `xcodebuild`, as in the default mode: mutants whose switch was evaluated before the tests started or a different number of times in two runs without mutants, crashes, hangs, runs with an unexpected test count, and whatever did not pass in the new process.
- The gate. Before any mutant the driver runs the tests twice without mutants. Both runs must pass with the number of tests that `xcodebuild` ran in the baseline. This is also what proves that the driver selects the same tests as `xcodebuild` would. The driver then writes down, for every switch, whether it was evaluated before the tests started, unequally often in the two runs, or equally often.
- Later processes of a unit. After a crash or a hang a new process is needed. It does not make the two runs again (with 1,200 tests they are a minute and a half each time): the tool takes the classes of the switches from the first process of the unit on that destination, sends only mutants that were evaluated equally often, and the driver runs the tests of its first mutant once without mutants before it. That run is what shows that this process works and that the destination holds nothing that fails those tests; if it fails, the process stops, and the same tests are run without mutants in a separate process before the next one (which is where state on the destination is reported). The check for evaluation before the tests start is made in every process, because it costs nothing.
- A run that does not end. The tool reads the shared region when a run is out of time: which mutant is on, and how often its switch was evaluated as active. If the mutant was on and evaluated, and the driver had said at the start of the run that the same tests had just passed without mutants in this process (or all selected tests had), the mutant is a Timeout: nothing but the mutant stands between a run that ended and one that did not, and a separate process could only wait again. Otherwise the mutant is put first in the next process, where the run before it is one without mutants. The limit of a run of narrowed tests comes from the time those tests took in the baseline ([usage.md](usage.md#timeouts)).
- Pausing. A crash or a hang costs the shared process. When, over the last twelve kills and lost processes, three or more were lost and losses outnumber kills, the next mutants are run alone until the balance has turned.

What remains a risk is a mutant that is killed only because of state that an earlier mutant left behind and that does not make the tests fail without a mutant, but does with this mutant (adversarial tests of the tool showed the simpler case, state that fails a test by itself and is cleared by the failing run, with ordinary tests; that case is now caught by the second run). No such case was found in the comparisons made so far: the same verdict for every mutant on the fixture and on Muter's sample projects, and on a production app every mutant detected, or not, in both modes. That is not proof that it cannot happen, and it is the reason why the option is not the default yet.

### Hosts started by the tool

A host that the tool starts has no test session of Xcode, and some of XCTest asks for one:

| In your tests | In a host started by the tool |
|---|---|
| `XCTContext.runActivity` | Works. The driver sets up the test configuration that XCTest asks for, through classes of XCTest that are not public (`XCTestConfiguration`). With an Xcode where they are missing, the process ends, the tool goes back to `xcodebuild`, and the warning names this cause |
| `XCTAttachment` (`add(_:)`), `XCTExpectFailure`, `measure` | Work (tried on the fixture with Xcode 27.2). Attachments and measurements are not kept |
| UI testing (`XCUIApplication`) | Not supported; leave UI test targets out |
| Anything else that needs the session | Not known. The control run decides |

When the tool could not start your host, the warning says whether the process ended or ran out of time, which test had started last, and the last lines the host wrote. The files are kept in `<work-dir>/logs/direct-launch-<n>/`:

| File | Content |
|---|---|
| `host.log` | Standard output and standard error of the host |
| `launch.txt` | The command, the environment (names of all variables; values only of those of the tool, of XCTest and of the dynamic loader), how the process ended, and the crash reports written for the host |
| `events.log` | What the driver reported (`HELLO`: it started; `CONTROL 1`: the first run without mutants ended) |
| `tests.log` | The tests that started during the runs without mutants, in order. The last line is the test that was running when the process ended or stopped |

### Why survivors are run again

A process that has already run the tests can hold state that hides a mutant. `--trust-shared-survivors` skips the run in a new process, and then reports as Survived a mutant that a clean process kills, in two situations. In the first, a value cached by an earlier run of the tests is read instead of being computed again with the mutant on. In the second, the switch is evaluated in every run of the tests, but only the first result is stored:

```swift
func configure(limit: Int) {
    if !configured { self.limit = limit > 0 ? limit : 10; configured = true }   // the mutant changes a value that is no longer stored
}
```

In a new process the mutated value is the one that is stored, and a test fails. The second run costs about a tenth of a second without a host app and one to three seconds with one, so there is little to gain from the option.

## Driving an instrumented build by hand

Useful when debugging the tool or a surprising verdict:

```bash
xcmutate instrument --in-place --manifest mutants.json Sources/*.swift     # on a copy of the project
xcodebuild build-for-testing -scheme App -destination 'generic/platform=iOS Simulator' -derivedDataPath <dir>
XCTESTRUN=$(ls <dir>/Build/Products/*.xctestrun)

# All mutants off
xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'id=<UDID>' -collect-test-diagnostics never
# Mutant 5 on
TEST_RUNNER_XCMUTATE_ACTIVE=5 xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
  -destination 'id=<UDID>' -collect-test-diagnostics never -only-testing:AppTests
```

Without `-collect-test-diagnostics never`, a failing test makes `xcodebuild` wait a long time while it gathers diagnostics.
