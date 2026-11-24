# Security

## Reporting a vulnerability

Please report a vulnerability in the tool privately, not in a public issue. Use GitHub's private vulnerability reporting: open the Security tab of the repository and choose Report a vulnerability (`https://github.com/RyoHirota68/xcmutate/security/advisories/new`).

Include the version (`xcmutate --version`), what an attacker has to control (a repository, a config file, a report), and the steps to reproduce. The project is maintained by one person in spare time, so a first answer can take a few days.

## Supported versions

| Version | Security fixes |
|---|---|
| The latest release | Yes |
| Older releases | No; please update |

## What running the tool means

xcmutate builds and tests the project you point it at. The rest of this page says what that means, so that you can decide where to run it.

### It runs the project's code

`run` executes `xcodebuild build-for-testing` and the tests of the project: build script phases, package plugins and test code all run, with your permissions. Running it on a checkout you do not trust is running that checkout's code. In CI, treat a mutation job on a pull request from a fork like any job that builds that pull request.

### `--prepare` runs a shell command

The string given to `--prepare` is run with `/bin/sh -c` in the work copy. It can only be given on the command line: `xcmutate.config.json` cannot set it, so a file in the repository cannot make the tool run a command. This will not change. What the command reads is up to you: `--prepare 'xcodegen generate'` reads `project.yml` from the checkout.

### What is copied, and where

The work copy holds the files that git tracks and the untracked files that git does not ignore. A secret that was not added to `.gitignore` is copied too. The work directory (`~/Library/Caches/xcmutate/…` by default) keeps the copy, the build products, logs and reports until `xcmutate clean` removes it.

`run` deletes `src`, `logs`, `results` and `traces` inside its work directory. It refuses a `--work-dir` that exists, is not empty and was not made by the tool, as well as the root of the project, the home directory and the directories above them.

### Reports contain source code

The `json`, `agent`, `html` and `stryker` reports hold fragments of the project's source (the mutated expressions, and in the agent report whole functions). Think before publishing them as CI artifacts or pull-request comments of a private project.

The `html` report loads its viewer (mutation-testing-elements) from a CDN. The script is requested at a fixed version with a Subresource Integrity value, so a browser refuses a file that differs from the one the tool was built against. The page still needs network access to open.

### The embedded helper reads environment variables

Instrumented code switches a mutant on, and writes a record file, according to environment variables (`XCMUTATE_ACTIVE` and others; with a per-work-directory token in their names in builds made by `run`). Instrumentation happens in the work copy only. Do not ship code produced by `instrument --in-place`: it would carry a helper whose behavior depends on the environment.
