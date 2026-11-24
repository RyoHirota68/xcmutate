# Changelog

Notable changes to xcmutate. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change options and report formats; such changes are listed under "Changed".

<!-- Releasing: replace "Unreleased" in the heading of the version being released with the date of the tag (YYYY-MM-DD). New work goes into a "## [Unreleased]" section above the latest version. -->

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
