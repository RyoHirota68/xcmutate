# Mutation operators

An operator is one kind of mechanical change. There are 27; 19 are on by default. Which ones are on follows a rule applied to measurements on public packages ([below](#the-rule)). Turn operators off with `disabledOperators` / `--disable-operator` and the off-by-default ones on with `enabledOperators` / `--enable-operator` ([configuration.md](configuration.md)).

## Operators that are on by default

| Name | Change |
|------|--------|
| `equality-flip` | `==` ↔ `!=` |
| `boundary` | `<` ↔ `<=`, `>` ↔ `>=`. Only the boundary moves; `>` is never turned into `<` |
| `logical-connector` | `&&` ↔ `\|\|` (operands are parenthesized so that the shape of the expression tree is kept) |
| `negation-removal` | `!x` → `x` |
| `boolean-literal` | `true` ↔ `false` |
| `ternary-swap` | `c ? a : b` → `c ? b : a` (not made when both branches have the same text). Embedded as the condition negated, `(switch ? !(c) : c) ? a : b`, which is the same change: the ternary itself stays as written, so branches whose types only the context unifies (`return round ? Circle() : Square()` as `any Shape`) still compile |
| `side-effect-removal` | A call statement whose result is discarded is removed (see [Statement removal](#statement-removal)) |
| `return-value` | The expression of an explicit `return` becomes another value. If it is a payload-free enum case (`.none`), up to two other cases returned by the same function are used. Otherwise the declared return type decides: Optional → `nil`, array or set → `[]`, dictionary → `[:]`, `String` → `""`, number → `0` |
| `early-return` | In a function that declares `var flag = false`, sets `flag = true` inside a loop and ends with `return flag` or `return flag ? A : B`, the assignment becomes `return true` or `return A` |
| `loop-control` | An unlabeled `continue` ↔ `break` inside a loop (a `break` inside a `switch` inside a loop included) |
| `normalization-removal` | A string-normalizing call is removed: `lowercased()`, `uppercased()`, `trimmingCharacters(in:)`, `localizedLowercase`, `localizedUppercase`. When an optional chain continues around the call, the whole chain is the replaced range. The receiver is written as `String(describing: receiver)`: the same text for a `String`, and one type in both branches of the switch when the receiver is a `Character` or a `Substring` |
| `condition-negation` | A Boolean condition of an `if` / `guard` that contains no operator is negated (`if items.isEmpty` → `if !(items.isEmpty)`). Not for `while` |
| `return-negation` | The expression of a `return` in a function or getter that returns `Bool`, or its single-expression body, is negated. Not made for comparisons, logical operations, literals or `!x`, which other operators cover |
| `operand-removal` | One operand of `&&` / `\|\|` is removed: `a && b` → `true && b` and `a && true`; for `\|\|` the constant is `false` |
| `min-max` | `min` ↔ `max` with two unlabeled arguments |
| `empty-body` | The body of a function without a return value does nothing. One mutant per function. Not made when the body consists only of call statements, early-exit `guard`s and `return` (statement removal covers those one by one), nor for `init`, `deinit`, functions that return a value, or closures |
| `switch-case-removal` | One `case` of a `switch` that has a `default` stops matching, so control falls to `default`. Not made when the body equals the `default` body or differs from it only by bare `break`s and calls that are never mutated (logging, `aridCalls`), for cases with a `where` clause, for a `switch` that has only `@unknown default`, or one that contains `#if` |
| `condition-constant` | The condition of an `if` → `false`: the body is skipped, and an `else` runs instead. One mutant per `if`. Never `true`. Not made for an `if` without `else` whose body is only logging. Not for `while` |
| `guard-removal` | The condition of a single-condition `guard` → `true`: the early exit no longer happens |

## Operators that are off by default

| Name | Change | Why off |
|------|--------|---------|
| `arithmetic` | `+` ↔ `-`, `*` ↔ `/`. Not made when a string, array or dictionary literal is anywhere in an operand, when an operand is text by the name of the call that makes it (`a.lowercased() + b`, `String(n) + unit`), for `x * 0` (it would divide by zero) and when both operands are number literals | Types are unknown to a syntactic tool, so string concatenation `+` is rewritten too and fails to compile, sometimes as "too complex to type-check": 18 of 90 mutants (20%) did not compile. A cursor that no longer advances also makes loops endless (12 timeouts among 63 reached) |
| `compound-assignment` | `+=` ↔ `-=`, `*=` ↔ `/=` (not when the right side is a string, array or dictionary literal) | Same typing problem (`text += suffix`): 8 of 14 did not compile. A loop counter `i += 1` turned into `i -= 1` never ends, and each such mutant waits for its timeout |
| `nil-coalescing-default` | A numeric or string literal on the right of `??` changes (`n ?? 0` → `n ?? 1`, `s ?? "none"` → `s ?? ""`) | 2 of 26 did not compile, only 6 were reached. When both values fall on the same side of a later check, the mutant is equivalent |
| `try-optional-nil` | `try? f()` → `nil`, the result of a failing call. Not made where statement removal or `return-value` already makes the same change | 9 of 29 reached mutants (31%) were equivalent and none of its survivors was a test gap. `try?` is written where a failure is tolerable, so the code around it often gives the same result either way: `(try? existing()) ?? create()`, or one of several attempts of which an earlier one already succeeds |
| `condition-removal` | In an `if` / `guard` with two or more conditions, one expression condition at a time becomes `true` | 8 of 40 reached mutants (20%) were equivalent: conditions that only decide which of two traps fires (`guard a, b else { preconditionFailure() }`), checks that cannot fail, a check that a later step makes up for. It also found 7 real gaps (validation with several conditions of which one is never tested alone), so switch it on for such code |
| `return-case` | The expression of a `return` that is an enum case with arguments (`.failure(error)`) becomes another value that the same function returns and that needs nothing from the place where it was written: a case without arguments, or a case whose arguments are literals and such cases (`.none`, `.failure(.invalid)`). At most two per `return` | Only 8 mutants on real code so far (6 detected, 2 gaps); not enough to switch it on |
| `implicit-return-value` | The single expression of a body that returns a value (function, getter, subscript, closure with a declared return type) becomes another value by the declared type, as for `return-value`: Optional → `nil`, array or set → `[]`, dictionary → `[:]`, `String` → `""`, number → `0`. Not made when the expression is a literal (a constant), for `Bool` (`return-negation` covers it), for `try? f()`, or in a result builder | 32 mutants on real code, none failed to compile; of 19 reached, 17 detected, 1 gap, 1 equivalent. One short of the 20 reached mutants that the rule asks for |
| `closure-statement-removal` | A call statement whose result is discarded, inside a closure that syntax shows not to be a result builder (see [Statement removal](#statement-removal)) | Only 6 mutants on real code (libraries have few such closures): 3 detected, 1 gap, 2 not reached |

### The rule

An operator is on by default when, on real code, at most 5% of its mutants fail to compile (each failure costs a rebuild) and at most 10% of the mutants that the tests reach are equivalent (an equivalent survivor costs a reader time and teaches nothing). A default is changed only on at least 20 reached mutants; a new operator starts off. The share of mutants that tests detect is not part of the rule: it measures the tests, not the operator.

**How it was measured.** On 2026-11-21, with an earlier development version of the tool, every operator was switched on and run on seven public packages at fixed commits, on macOS: SwiftyJSON 5.0.2, swift-http-types 1.4.0, Expression 0.13.9, Files 4.3.0, Version 2.2.0, and BonMot and FFCParserCombinator as they ship among Muter's sample projects. That made 2,245 mutants. The tests reached 1,801 of them, detected 1,456 and let 345 survive; 45 did not compile. Every survivor of the operators in question was read and classified. "Equivalent" is therefore a judgment made by reading the code, and a survivor that could not be settled that way does not count as equivalent. `scripts/operator-campaign.sh` repeats the measurement.

The result for the operators that are on. Their share of equivalent mutants among the reached ones: `boundary` 9.6%, `side-effect-removal` 7.3%, `boolean-literal` 5.9%, `switch-case-removal` 5.5%, `guard-removal` 1.3%, the others about 3% or less. Some of these come from a sample, and `normalization-removal`, `loop-control` and `min-max` rest on fewer than 20 reached mutants.

**What the measurement does not cover.** Five of the seven packages are small libraries, and none is an app.

Your code may therefore differ. `guard-removal` in particular is on because, in the packages measured, a single-condition `guard` is mostly validation whose error path lacks a test; in code where guards mostly skip work that is already done (`guard !isLoading else { return }`), its survivors will more often be equivalent, and `--disable-operator guard-removal` (or `disabledOperators` in the config file) turns it off.

## Statement removal

`side-effect-removal` applies to function calls (with or without `try` / `await`) and to `_ = call`, when they are statements in the body of a function, initializer, accessor or subscript. Statements in closure bodies are left to `closure-statement-removal` (off by default), which takes a closure only when syntax alone shows that it is not a result builder and that the statement is not its value:

- the closure contains a statement that the result-builder transform does not accept or that switches it off (`return`, `guard`, `while`, `repeat`, `defer`, `break`, `continue`), and has two or more statements; or
- it is an argument of a call that is known to take a plain closure: `forEach`, `DispatchQueue.async` / `asyncAfter`, `addOperation`, `UIView.animate`, `performBatchUpdates`, `enumerateAttributes` and the like (a closure of one statement included, since these closures return nothing), or `Task`, `sync`, `withAnimation`, `performAndWait`, `addTask` (two or more statements only, because a single statement could be the closure's value).

Everything else in a closure (`VStack { … }`, `map { transform($0) }`, a closure passed to your own function) is not a candidate. The rules below apply to both operators. Neither applies to:

| Ignore reason | Statement |
|---------------|-----------|
| (not a candidate) | Statements at file top level, and in closure bodies other than those described above; compound assignments such as `i += 1` |
| `result-builder` | Statements inside a result builder: a declaration with an attribute that names a `@resultBuilder` type declared anywhere in the project or whose name ends in `Builder`, and `var body: some …` |
| `implicit-return` | The single expression of a body that returns a value, and the value of each branch when the body is one `switch` / `if` expression (`var title: String { switch self { case .home: text("Home") … } }`) |
| `never-returning` | `fatalError` and the like; functions declared `-> Never` in any file of the project; and any call that a value-returning body ends with on some path (it cannot return, or the original would not compile: this covers a `-> Never` function of another module) |
| `initializer-delegation` | `super.init` / `self.init` |
| `arid-call` | Logging, `layoutIfNeeded` and the like, and your `aridCalls` |
| `synchronization` | `lock`, `unlock`, `signal`, `wait`, `enter`, `leave` |
| `guard-else` | The last statement of a `guard`'s `else` block |

## Positions that are never mutated

A candidate at one of these positions is not turned into a mutant. It is kept in the list of ignored candidates with its reason (`list --show-ignored`; counts per reason in the JSON report's `ignoredByReason`).

| Reason | Position |
|--------|----------|
| `if-config-condition` | The condition of `#if` |
| `inactive-if-config` | A branch of `#if` that the destination of the run does not compile (`#if os(iOS)` in a run on macOS). Decided for `os(…)`, `targetEnvironment(simulator)` / `(macCatalyst)` and `canImport(UIKit)` / `(AppKit)`, combined with `!`, `&&` and `||`; a branch that depends on anything else (`DEBUG`, `arch`, versions) is mutated as before. Only `run` knows a destination; `list` and `instrument` mutate every branch |
| `macro-expansion` | Arguments and bodies of freestanding macros (`#Predicate`, `#Preview`, `#expect` …) |
| `attribute-argument` | Arguments of attributes (`@Clamped(max: …)`, `@Test(.enabled(if: …))`) |
| `type-context` | Generic `where` clauses, type constraints, inheritance clauses |
| `enum-case` | Raw values and default values of associated values |
| `pattern` | Patterns (`case true:`); the expression of a `where` clause is mutated |
| `key-path` / `inout-argument` | Inside key paths; `&x` |
| `deinit` | The body of `deinit` |
| `operator-declaration` | `precedencegroup` / `operator` declarations |
| `inlinable-body` | Bodies that are compiled into other modules and so cannot refer to the file-private helper: `@inlinable`, `@_alwaysEmitIntoClient`, `@export(implementation)`, `@_transparent`, `@backDeployed`, and `@inline(always)` on a declaration that other modules see (`public`, `open`, `package`, also through a `public extension`) |
| `public-default-argument` | Default arguments of `public` functions (they are compiled into the caller) |
| `frozen-property-initializer` | Initial values of stored properties of `@frozen` types |
| `arid-call` / `arid-argument` | Inside calls that are never mutated; arguments such as `animated: true` |
| `constant-condition` | A condition that is itself a Boolean literal (`while true`); changing it alters reachability analysis and can break the build |
| `unfoldable-operators` | Expressions with a custom operator whose precedence is unknown (declared in another module) |
| `optional-chain` | A range whose parentheses would cut an optional chain (`a?.b.c()` wrapped around `b.c()`) |
| `control-flow-expression` | The expression of `return switch …` / `return if …` (an `if` / `switch` expression cannot sit inside a ternary branch) |
| `same-range-as-statement` | An expression mutant whose range equals that of a statement-level mutant |
| `duplicate` | Another operator already makes the same rewrite of the same range |
| `too-many-in-expression` | Beyond the limit per expression (default 12). The diff filter is applied first; within the limit, mutants are picked across operator kinds and from the innermost range outwards |
| `cannot-flatten` | The mutated version cannot be put on one line (multi-line string literals) |
| `disabled-by-comment` | A [disable comment](configuration.md#disable-comments) |
| `excluded-declaration` | Inside a declaration whose name matches [`excludeDeclarations`](configuration.md#xcmutateconfigjson) of the config file |

A file with a parse error is not mutated at all. The tool parses every branch of `#if`, so this includes a file that the compiler accepts because the text it cannot read is in a branch that is never compiled (`#if compiler(>=99)`), and a file that uses syntax newer than the swift-syntax version of the tool. Such a file is named on stderr and in every report (warning `skippedFile`), and a gate does not pass while one exists.

Line endings are kept as they are: files with CRLF or CR line endings, with a byte order mark, or without a final line break are instrumented with the same line numbers as the original.
