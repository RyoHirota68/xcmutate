# Limitations, what is not verified, and known issues

This page collects in one place what the tool does not do, what has not been tried yet, and the problems that are known. The limits of a single option are described with that option, in [usage.md](usage.md) and [speed.md](speed.md).

## Limitations

- UI tests are not supported. Leave UI test targets out with `--only-testing` or `--skip-testing`.
- Linux is not supported: the tool drives `xcodebuild`.
- Tests are started through `xcodebuild` only. A project whose tests are run with `swift test` or another build system has to offer a scheme that `xcodebuild` can test.
- By default every mutant costs one launch of the test host: about 5 to 8 s on an iOS simulator with an app-hosted test target. `--shared-process` reduces this, with conditions ([speed.md](speed.md)).
- Mutation is syntactic: the tool does not know types. Some mutants do not compile; they are found and removed, at the cost of a rebuild. Some are equivalent; record them with `accept`.
- Files that git ignores, files outside the repository and git submodules are not in the work copy. Create them with `--prepare`.
- `--shared-process` needs tests that pass twice in a row in one process, and no UI test target in the selection.
- Only one run can use a work directory at a time, which by default means one run per checkout. Give parallel runs a `--work-dir` each.
- Mutating a whole large app in one go is not practical. Use `--since`, a nightly run, or a sample with `--max-mutants`.

## Not yet verified

Toolchains and platforms:

- Runs were verified with Xcode 27.2 (macOS and an iOS simulator) and, once, with Xcode 26.6 (a Swift package on macOS, on a GitHub-hosted runner, with the tool built by that Xcode). [install.md](install.md#what-you-need) has the details.
- An iOS simulator with Xcode 26.6 has not been tried.
- The prebuilt binary, which is built with Xcode 27.2, has not been used with Xcode 26.
- Xcode versions older than 26.6 have not been tried.
- macOS versions other than 26 and 27 have not been tried. `Package.swift` declares macOS 14 as the minimum.
- The x86_64 (Intel) half of the universal release binary has not been tested.
- Physical devices, and watchOS, tvOS and visionOS destinations, have not been tried.

Distribution and CI:

- `brew install` has not been run. The formula was generated and inspected only ([install.md](install.md#homebrew)).
- Most of the GitHub Action. It ran once on a GitHub-hosted macOS runner (Xcode 26.6): it built the tool from source and ran it on a Swift package on macOS. Not tried on GitHub: an iOS simulator, downloading the release binary, the cache, `pull_request` events, how warnings appear on the lines of a pull request, and the example workflows ([ci.md](ci.md#what-has-been-verified)).

Speed:

- The speed of `--workers` was last measured with an earlier development version. Its verdicts were checked with this version ([speed.md](speed.md)).

## Known issues

- **A test process that ends without a result.** In the checks of this version, a test process started by the tool ended without a result three times in about twenty runs. The cause is unknown. The tool repeats such a run, and the verdicts were right each time. If the same mutant loses its process twice in a row, the tool cannot tell that from a real crash and reports a Crash.
- **A Crash reported as a Timeout.** A mutant that crashes the host was reported once as a Timeout. The same mutant was then run 120 more times and was a Crash every time; the cause is unknown. Since then, a crash report that the host writes during a run makes the run a Crash. A crash that leaves no report in time would still be a Timeout. Both count as detected.

[verification.md](verification.md) says what the verdicts are checked against.
