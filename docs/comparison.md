# How xcmutate differs from Muter

[Muter](https://github.com/muter-mutation-testing/muter) is the established mutation testing tool for Swift, and xcmutate learned from its design, its issue tracker and its test data. Both embed all mutants in one build as switches, and both work on a copy of the project. The comparison rests on Muter's README and operator page at commit `5c85409` (2026-10-23, still the latest on 2026-11-24). Muter was not run, so there is no speed comparison.

What xcmutate does:

- It mutates the lines of a diff (`--since <ref>`). Muter's README selects whole files (`--files-to-mutate`).
- It reports code that no test runs (NotReached) separately from code whose change the tests miss (Survived).
- It checks its own verdicts, as described in [verification.md](verification.md#what-each-verdict-needs), and warns when a run left state behind.
- It has a CI gate for "no new gaps" (`--baseline-report`), a file of accepted equivalent mutants, a report for coding agents and the mutation-testing-elements schema. Muter's README lists plain, JSON, HTML and Xcode reports.
- It has 27 operators, 19 of them on by default. Muter's operator page describes four.
- Its verdicts are compared with Muter's test data: for 99 of the 102 mutants that both tools make, the result is the same ([verification.md](verification.md#muters-verification-data)).

When Muter is the better choice:

- You want a tool with a history. Muter has been developed since 2018, and 0.13.0 is the first release of xcmutate.
- You need UI test suites, tvOS or watchOS. Muter's README says it supports them; xcmutate does not support UI tests and was not tried on those platforms.
- Your tests are started by something other than `xcodebuild`. Muter's configuration takes any executable (`swift`, `fastlane`, `make`); xcmutate drives `xcodebuild` only (a contribution that changes this is welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md#what-to-contribute-and-how)).

## What was not compared

- Speed. Muter was not run, so the two tools were never measured under the same conditions. [speed.md](speed.md) has measurements of xcmutate on two of the sample projects that ship with Muter.
- Whether Muter has an equivalent of the checks, gates and files named above. Its README does not describe one; its source was not read again for this page.

## Where the facts about Muter come from

They were read on 2026-11-24 at commit `5c85409` (2026-10-23), which was then the latest commit on Muter's `master` branch. Its latest release tag was `16` (2023-09-16).

| Statement | Source |
|---|---|
| All mutants are embedded in one build as switches | README, "Mutant Schemata" |
| Muter works on a copy of the project | README, "How Does It Work?" |
| Files are selected with `--files-to-mutate` | README, "Available Flags", and the CI example at the top |
| The reports are plain, JSON, HTML and Xcode | README, "Available Report Formats" |
| Four operators are described | `Docs/mutation_operators.md`; the README names the same four for `--operators` |
| Developed since 2018 | The creation date of the repository |
| UI test suites, tvOS and watchOS | README, "FAQs" |
| Any executable can start the tests | README, "Configuration Options", `executable` |

[how-it-works.md](how-it-works.md#design-goals) has the design goals of xcmutate.
