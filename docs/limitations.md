# Limitations, what is not verified, and known issues

This page collects in one place what the tool does not do, what has not been tried yet, and the problems that are known. The limits of a single option are described with that option, in [usage.md](usage.md) and [speed.md](speed.md).

## Limitations

- UI tests are not supported. Leave UI test targets out with `--only-testing` or `--skip-testing`.
- Linux is not supported: the tool drives `xcodebuild`.
- Tests are started through `xcodebuild` only. A project whose tests are run with `swift test` or another build system has to offer a scheme that `xcodebuild` can test.
- By default every mutant costs one launch of the test host: about 5 to 8 s on an iOS simulator with an app-hosted test target. `--shared-process` reduces this, with conditions ([speed.md](speed.md)).
- Mutation is syntactic: the tool does not know types. Some mutants do not compile; they are found and removed, at the cost of a rebuild. Some are equivalent; record them with `accept`.
- Files that git ignores, files outside the repository and git submodules are not in the work copy. Create them with `--prepare`.
- `--shared-process` needs tests that pass twice in a row in one process, and no UI test target in the selection. Tests that send the app to the background (by opening another app or a URL) need `xcodebuild` to start the host; the tool switches to it by itself, with a warning.
- Only one run can use a work directory at a time, which by default means one run per checkout. Give parallel runs a `--work-dir` each.
- Mutating a whole large app in one go is not practical. Use `--since`, a nightly run, or a sample with `--max-mutants`.

## Not yet verified

Toolchains and platforms:

- Runs were verified with Xcode 27.2 (macOS and an iOS simulator) and with Xcode 26.6 (a Swift package on macOS, and a small iOS app on a simulator, on GitHub-hosted runners). The prebuilt binary is built with Xcode 26.6 and was checked under both. [install.md](install.md#what-you-need) has the details.
- With Xcode 26.6, only a small iOS app (5 mutants) has been run on a simulator.
- Xcode versions older than 26.6 have not been tried.
- macOS versions other than 26 and 27 have not been tried. `Package.swift` declares macOS 14 as the minimum.
- The x86_64 (Intel) half of the universal release binary has only been started under Rosetta (`--version`). It has not run on a project.
- Physical devices, and watchOS, tvOS and visionOS destinations, have not been tried.

Distribution and CI:

- Parts of the GitHub Action. It ran on GitHub with a Swift package and with an iOS app on a simulator, from the release binary and from the sources, on a pull request and with a failing gate. Not tried on GitHub: `baseline-report`, `package-cache`, `select-tests` and `shared-process` on a simulator, and the example workflows as they are written ([ci.md](ci.md#what-has-been-verified)).

Speed:

- The speed of `--workers` was last measured with an earlier development version. Its verdicts were checked with this version ([speed.md](speed.md)).

## Known issues

- **A test process that ends without a result.** In the checks of this version, a test process started by the tool ended without a result three times in about twenty runs. The cause is unknown. The tool repeats such a run, and the verdicts were right each time. If the same mutant loses its process twice in a row, the tool cannot tell that from a real crash and reports a Crash.
- **A Crash reported as a Timeout.** A mutant that crashes the host was reported once as a Timeout. The same mutant was then run 120 more times and was a Crash every time; the cause is unknown. Since then, a crash report that the host writes during a run makes the run a Crash. Since 0.14.0, so does the host's own line `*** Terminating app due to uncaught exception` in the log, when no test started or ended after it: on a busy Mac a run of a large app had neither the restart of `xcodebuild` nor a crash report in time. Only a line that names the host's process ID counts: a process that a test starts can write into the same log (a `Fatal error:` line from such a process was seen there), and Swift's `Fatal error:` line does not name a process. A crash that leaves neither in time would still be a Timeout. Both count as detected.

- **Crash reports pile up.** Every mutant that crashes the test host leaves a crash report (`.ips`) in `~/Library/Logs/DiagnosticReports`, named after the host (a run of one file of a large app left eight). The tool reads them and does not delete them: the folder belongs to the system and holds reports of other programs. They can be removed by hand, for example `rm ~/Library/Logs/DiagnosticReports/<host name>-*.ips`.

[verification.md](verification.md) says what the verdicts are checked against.
