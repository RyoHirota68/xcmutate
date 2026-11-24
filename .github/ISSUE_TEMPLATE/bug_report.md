---
name: Bug report
about: A wrong verdict, a run that stops, or anything that does not work as documented
labels: bug
---

<!-- Please do not paste code or names from a private project. Describe the shape of the code instead, or reduce it to a small example. For a vulnerability, see SECURITY.md instead of opening an issue. -->

## What happened

<!-- What you ran, what you expected, and what you got instead. -->

## Versions

- xcmutate: <!-- xcmutate --version -->
- Xcode: <!-- xcodebuild -version -->
- macOS, and Apple silicon or Intel:
- Destination: <!-- an iOS simulator (which iOS version), or macOS -->
- Kind of project: <!-- Xcode project, workspace, or Swift package; XCTest or Swift Testing; tests hosted by an app or not -->

## The command

```
xcmutate run …
```

## Steps to reproduce

<!-- The smallest project or file that shows the problem is the most helpful. `xcmutate list --show-ignored <file>` is enough for a problem with which mutants are made. -->

## The relevant part of the output

<!-- The lines of standard error around the problem, and the part of the report that is wrong. For a wrong verdict: the entry of that mutant in the JSON report (`--reporter json`), including `status`, `detail` and `mutant.key`. For a run that stopped: the message and the tail of the log file it names. -->

```
```

## Warnings in the report

<!-- The `warnings` of the report, if any (for example workerDropped, stateLeak, sharedProcessUnavailable, directLaunchUnavailable). -->
