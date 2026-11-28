# Third-party notices

xcmutate itself is licensed under the [MIT License](LICENSE). This file lists the third-party software and material it depends on, includes, fetches or was modelled on.

## Dependencies (linked into the executable)

Resolved by Swift Package Manager from `Package.swift`; not vendored in this repository.

| Package | Version | Licence | Source |
|---------|---------|---------|--------|
| swift-syntax (`SwiftSyntax`, `SwiftParser`, `SwiftOperators`) | 604.0.0 | Apache License 2.0 with Runtime Library Exception | https://github.com/swiftlang/swift-syntax |
| swift-argument-parser (`ArgumentParser`) | 1.8.2 | Apache License 2.0 with Runtime Library Exception | https://github.com/apple/swift-argument-parser |
| Yams (`Yams`, which includes LibYAML) | 6.2.2 | MIT License | https://github.com/jpsim/Yams |

A binary distribution of xcmutate must reproduce the license texts of these packages (the `LICENSE.txt` file of each repository).

The license of Yams (its repository holds this one license file, also for the copy of LibYAML in `Sources/CYaml`):

```
The MIT License (MIT)

Copyright (c) 2016 JP Simard.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Material included in this repository

| Path | What it is | Origin | Licence |
|------|-----------|--------|---------|
| `Fixtures/muter/expected-examples.json` | Positions of the mutants that Muter's unit tests expect, transcribed from Muter's tests and snapshots (data, no source code) | https://github.com/muter-mutation-testing/muter at commit `5c854098e61d1a093ef9c4e53a5ebc6de07b3a32` | MIT License, Copyright (c) 2020 Muter. The license text is in `Fixtures/muter/LICENSE-muter.txt` |

No source file of Muter or of any other mutation testing tool is included in this repository.

## Material fetched by scripts (not included)

| Fetched by | What | Licence |
|------------|------|---------|
| `scripts/verify-muter-fixtures.sh` | The Muter repository at the commit above, into `.build/external/muter` (ignored by git). It contains Muter's mutation examples and sample projects, among them the third-party open-source projects BonMot and FFCParserCombinator | Muter: MIT. The sample projects carry their own licenses inside the Muter repository |

These are used only to check this tool's behavior against Muter's verification code. Results are summarized in `docs/verification.md`.

## Loaded at view time by generated reports

| Used by | What | Licence |
|---------|------|---------|
| The `html` report | The `mutation-testing-elements` web component, loaded by the browser from `https://www.unpkg.com/mutation-testing-elements` when the report is opened. It is not embedded in the report or in this repository | Apache License 2.0, https://github.com/stryker-mutator/mutation-testing-elements |
| The `stryker` and `html` reports | Follow the JSON schema `mutation-testing-report-schema` (schema version 2) | Apache License 2.0, same repository |

## Tools used in development (not distributed)

| Tool | Use | Licence |
|------|-----|---------|
| XcodeGen | Generates `Fixtures/SampleApp/SampleApp.xcodeproj` from `project.yml` | MIT, https://github.com/yonaskolb/XcodeGen |

## Design references

No code was copied from these projects; ideas were, and they are credited here and in the source comments where they are used.

| Project | What was taken as an idea | Licence |
|---------|---------------------------|---------|
| [mizchi/mutator](https://github.com/mizchi/mutator) (mutation testing for Vitest) | The diff-driven workflow, stable mutant keys, the report for AI agents, and the `mutation-test-loop` skill, which was rewritten for this tool's command line | MIT |
| [Muter](https://github.com/muter-mutation-testing/muter) | Mutant schemata for Swift; lessons from its issues and pull requests | MIT |
| [ericodx/swift-mutation-testing](https://github.com/ericodx/swift-mutation-testing) | Attributing reach to tests by interleaving the helper's records with the test runner's start and end lines; creating worker simulators and deleting them afterwards | MIT |
| [debugholic/litmus](https://github.com/debugholic/litmus) | Running many mutants in one test process with a driver that repeats the tests, and sending a mutant that is evaluated once per process to a process of its own | MIT |
| [Joseph-Cursio/XCMutate](https://github.com/Joseph-Cursio/XCMutate) (a fork of Muter) | Naming worker simulators after the owning process so that leftovers of a dead run can be found and removed | MIT |

Other Swift mutation testing tools were studied while this one was designed. This repository contains no code from them.
