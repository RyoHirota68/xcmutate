# Working with coding agents

Mutation testing produces a list of precise, checkable tasks: "this change to this function goes unnoticed by the tests". A coding agent can work through such a list. There are three ways in.

## 1. Any agent: a prompt and `xcmutate agent-guide`

Give the agent this prompt, in the repository you want to work on:

```
Run "xcmutate agent-guide" and follow it to find and close the gaps in the tests
for the changes on this branch. Ask me before you change production code, accept
a mutant as equivalent, or start a run that takes more than 15 minutes.
```

`xcmutate agent-guide` prints the procedure. It comes from the installed tool, so it matches that version's options and report format, and nothing has to be copied into your project. The same text is in [agent-guide.md](agent-guide.md). In short, it tells the agent to:

1. find the scheme, the destination and the unit-test target, and ask you when it cannot decide;
2. count the mutants of the change with `xcmutate list`, estimate the time, and ask before a long run;
3. make a first run that is bounded (`--since`, `--max-mutants 50`, `--time-limit 20m`) with `--reporter agent`;
4. read the exit code and the warnings before the gaps;
5. check, before writing a test, whether the code or the mutant matches the comments and documentation, and ask you when they disagree;
6. write tests for the gaps, one function at a time, asserting behavior that a caller can observe;
7. check each gap again with `--only <key>`;
8. list mutants that it believes are equivalent, and ask you instead of accepting them;
9. report what it closed, what is left, any real bug it found, and what the score does not cover.

It also tells the agent what not to do: change production code, delete or skip tests, accept mutants on its own, create or delete simulators, or start a long run without asking.

Things that make the agent's first step easier, if you write them into the project's `CLAUDE.md`, `AGENTS.md` or similar:

- the `run` arguments for the project: `--workspace` / `--scheme`, and `--only-testing <unit-test target>`;
- which simulator to use;
- whether `--prepare` or `--package-cache` is needed.

Commit `xcmutate.accepted.json` when it appears. The work directory is under `~/Library/Caches/xcmutate/`, so nothing else is written to the repository.

## 2. Without the prompt: `xcmutate agent-guide --install`

To have the agent find the guide by itself, run this once anywhere in the repository:

```bash
xcmutate agent-guide --install
```

The command looks at the root of the git repository (the current directory outside a repository) and writes:

| The project has | What is written | Read by |
|---|---|---|
| a `.claude/` folder | the skill `.claude/skills/mutation-test-loop/SKILL.md` | Claude Code |
| an `.agents/` folder | the same skill as `.agents/skills/mutation-test-loop/SKILL.md` | Codex |
| an `AGENTS.md` | a section in `AGENTS.md` | Codex, Cursor, GitHub Copilot |
| several of these | each of them | |
| none of these | a new `AGENTS.md` with the section | |

It prints one line per file:

```
Found .claude/: wrote the Claude Code skill to .claude/skills/mutation-test-loop/SKILL.md
Found AGENTS.md: wrote the xcmutate section into AGENTS.md
```

Without a `.claude/` folder it adds a line that shows how to add the Claude Code skill as well, since Claude Code does not read `AGENTS.md`:

```
Found AGENTS.md: wrote the xcmutate section into AGENTS.md
For Claude Code, also run: xcmutate agent-guide --install-for claude
```

Neither file holds the procedure. Both tell the agent to run `xcmutate agent-guide` and follow it, so the procedure stays that of the installed version. The section in `AGENTS.md` also states the three rules of the prompt above. Claude Code picks the skill up by itself for requests such as "strengthen the tests of this branch". Commit the files to share them with your team. The idea of the loop comes from the skill of the same name in [mizchi/mutator](https://github.com/mizchi/mutator).

Running the command again is safe. In `AGENTS.md` the section stands between two marker comments; only what lies between them is replaced, and the rest of the file is not touched. A file that is up to date is not written. A skill file that differs from what the tool writes, for example one you edited, is left alone: the command says so and exits with code 2. `--force` replaces it.

To write one target instead of the ones that `--install` chooses, or to install a skill for all your projects:

```bash
xcmutate agent-guide --install-for claude          # .claude/skills/mutation-test-loop/SKILL.md
xcmutate agent-guide --install-for codex           # .agents/skills/mutation-test-loop/SKILL.md (a Codex skill)
xcmutate agent-guide --install-for agents-md       # the section in AGENTS.md
xcmutate agent-guide --install-for claude --user   # ~/.claude/skills/mutation-test-loop/SKILL.md
xcmutate agent-guide --install-for codex --user    # ~/.agents/skills/mutation-test-loop/SKILL.md
```

`--install` alone writes only into the project, never into your home directory. The places are those that the agents' own documentation names: for Claude Code [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills), for Codex [learn.chatgpt.com/docs/build-skills](https://learn.chatgpt.com/docs/build-skills) ("Where Codex loads local skills": `$REPO_ROOT/.agents/skills` and `$HOME/.agents/skills`; a `SKILL.md` must include `name` and `description`, which the skill has). xcmutate itself must be on the `PATH` ([install.md](install.md)).

## 3. The `agent` report

```bash
xcmutate run --since origin/main --workspace App.xcworkspace --scheme App \
  --destination 'id=<SIMULATOR-UDID>' --only-testing AppTests \
  --reporter text --reporter agent > gaps.json
```

stdout carries only the JSON, without indentation. Progress and the text summary go to stderr. The format (version 5) is built to cost few tokens and to tell the agent what a good test has to do:

| Field | Content |
|-------|---------|
| `scope` | What the run covered: `diff` (`--since`), `files`, `all`, or `only` (`--only`) |
| `results[]` | `key` and `status` of every mutant of the run. After a run with `--only`, this says which gaps are closed |
| `ignored[]`, `ignoredCount` | Candidates that the tool deliberately did not mutate, with `file`, `line`, `column`, `mutator`, `original`, `replacement` and `reason` (at most 50; `ignoredCount` is the number of all). Not gaps. Empty for a run with `--only` |
| `scopes[]` | Gaps grouped by enclosing function (a `let` inside the function is part of it). The function's source, with line numbers, appears once per function instead of once per gap. Functions that no test reaches at all come first |
| `scopes[].gaps[]` | `key` (stable key for `--only` and `accept`), `gap` (`notReached` or `notDetected`), `line` / `column`, `mutator`, `original` / `replacement`, `originalExpression` / `mutatedExpression` (only where they say more than `original` / `replacement`: `a > b` for `>`), and with `--select-tests reach` `coveredBy` (the tests that execute the code) |
| `obligations` | For each operator that occurs: what a test must tell apart to detect such a mutant. For `boundary`: the result changes only when both sides are exactly equal, so the boundary value itself must be an input |
| `fixes` | What to do for each kind of gap, for the kinds that the report holds (empty when every mutant was detected). `fixes.narrowedOnly` is present when a gap has `narrowedOnly: true`: that mutant passed the tests that reach it and was not run against the other tests (`--no-recheck-survivors`), so a test that already exists may detect it; run without the option before writing a test for it |
| `score`, `reachedScore`, `counts` | Ratios (0.75), and counts per result kind |
| `testSelection`, `acceptance`, `warnings`, `interrupted`, `pendingCount` | What the result is valid for, and anything that makes it less trustworthy |

When tests were narrowed (`--select-tests`, `--only-testing`), the wording is "among the selected tests": a `notReached` gap may be reached by a test that was not run.

Nothing in the report is specific to one agent. A tool of your own can read it the same way: take the keys from `scopes[].gaps[]`, and pass them to `run --only` after changing the tests.

### While the run is going

The report for agents is written at the end. While a run is going, `--progress-file <path>` writes its progress line by line: the phase, each mutant's result with the time left, a heartbeat during a long build or baseline, and the exit code at the end ([reports.md](reports.md#the-progress-file)). The guide tells the agent to run a long run in the background and to report from this file. Its version is separate from that of the report for agents.

## 4. An example from a trial

To see whether the prompt of section 1 is enough, an agent was given only that prompt, with no other instructions, in a small Swift package. Its branch added volume and coupon discounts and shipping fees. The agent ran `xcmutate agent-guide` and followed it. The tool was version 0.13.0 at an earlier commit, whose agent report had format version 4.

The first run made 16 mutants and left 6 of them undetected (4 Survived, 2 NotReached; score 62.5%). The agent added three tests: one for the boundary of a bulk order, and two for the express shipping fee, a branch that no test had run. It checked the 6 keys again with `--only`, and 2 gaps remained. This is one of them in the agent report (abridged; the fields are those of `scopes[].gaps[]`):

```json
{"gap": "notDetected", "line": 8,
 "key": "Sources/Checkout/Discount.swift::Discount.volumeDiscount(subtotal:)::boundary::020814f6b57660f0",
 "mutatedExpression": "subtotal >= volumeThreshold", "originalExpression": "subtotal > volumeThreshold"}
```

The comment on the function said "10% of the subtotal for a subtotal of `volumeThreshold` or more", which matches the mutant and not the code. The agent did not write a test that kept `>`. It reported the mismatch and asked which was right. The other gap was `percent > 100` changed to `percent >= 100` in a function that returns 100 in that branch and `percent` otherwise. When `percent` is 100, both versions return 100. The agent reported it as a candidate equivalent mutant with that reason, and asked before accepting it. It ended its first turn there, after one more full run to make the numbers in its report final.

With the developer's answers, the agent changed `>` to `>=`, added this test, and accepted the equivalent mutant with `xcmutate accept` and the reason "At percent == 100 both versions return 100; no input observes the change":

```swift
@Test func ordersOfExactlyTheVolumeThresholdGetTenPercentOff() {
    #expect(Discount.volumeDiscount(subtotal: 10_000) == 1_000)
    #expect(Discount.volumeDiscount(subtotal: 9_999) == 0)
}
```

The last run had Killed 15 and Accepted 1, and no gaps. The agent did not commit anything. The trial took two turns, and the agent did not run the `--help` of any command.
