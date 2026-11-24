# Getting started

This guide takes you through the loop of the tool: run it, read the report, write a test for a gap, and check that the test closes it. Section 1 does one loop on a package with two functions. Section 2 does it again on a slightly larger package, whose report also shows code that no test runs, and explains each part of the report. Both are Swift packages on macOS, so nothing but Xcode is needed and each run takes seconds. The last section shows the same loop for an app on an iOS simulator.

Every option is described in the [reference](usage.md). Words such as *reached* and *selection* are explained in its [glossary](usage.md#glossary).

## Before you start

- `xcmutate` is on your `PATH` ([install.md](install.md)).
- The project is in a git repository. The tool copies the files that git knows into a work directory and mutates the copy. Your working tree is not modified by `run`. (Outside a git repository, `run` needs the Swift files named as arguments, and `--since` cannot be used.)
- Xcode is installed and selected (`xcode-select -p`).

## 1. A first loop

### The package

A package with two small functions and one test. Skip this step if you want to use a package of your own.

```bash
mkdir Shop && cd Shop
mkdir -p Sources/Shop Tests/ShopTests
```

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shop",
    products: [.library(name: "Shop", targets: ["Shop"])],
    targets: [
        .target(name: "Shop"),
        .testTarget(name: "ShopTests", dependencies: ["Shop"]),
    ]
)
```

`Sources/Shop/Price.swift`:

```swift
public func isExpensive(_ price: Int) -> Bool {
    price > 100
}

public func label(for price: Int) -> String {
    isExpensive(price) ? "premium" : "standard"
}
```

`Tests/ShopTests/PriceTests.swift`:

```swift
import Testing
import Shop

@Test func labels() {
    #expect(label(for: 250) == "premium")
    #expect(label(for: 20) == "standard")
}
```

Commit it:

```bash
printf '.build/\n' > .gitignore
git init && git add -A && git commit -m "Shop"
```

### The run

```bash
xcmutate run --package . --scheme Shop --destination 'platform=macOS'
```

- `--package .` names the package directory. For an Xcode project use `--project` or `--workspace` instead.
- `--scheme` is the scheme that `xcodebuild` builds and tests. `xcodebuild -list` in the package directory shows the schemes. It is usually the product's name when the package declares exactly one product, and `<package name>-Package` when it declares none or several.

There is no `--since` here, so every line of the package is mutated. On a real project you will almost always pass `--since <branch>` to mutate only the lines you changed.

While it runs, the tool prints its progress to standard error: the baseline, a line that starts with `timeouts:` (the limits after which a run is stopped, taken from the baseline), and one line per mutant. The report follows on standard output:

```
xcmutate 0.13.0: 2 mutants (scope: all)
  Killed 1, Survived 1
  mutation score: 50.0% (detected / (detected + survived + not reached))
  among reached:  50.0% (detected / (detected + survived))
  time: total 9s, build 2s (1 build), baseline 1.6s, 2.0s per mutant (2 run)
  tests run: all tests
  files not mutated: package-manifest 1, test-code 1
    Package.swift (package-manifest)

Survived / not reached:
  Sources/Shop/Price.swift:2:11 [Survived] boundary `>` -> `>=`  (isExpensive(_:))
    key: Sources/Shop/Price.swift::isExpensive(_:)::boundary::3cdaf5b521d8a78f
```

The tool made two mutants. The test caught one of them, which swaps "premium" and "standard" (Killed). It did not catch the other: with `price > 100` changed to `price >= 100`, both assertions still pass, because neither uses a price of exactly 100 (Survived). The line under the gap is its key, which names the mutant.

### Closing the gap

Add a test for that boundary to `PriceTests.swift`:

```swift
@Test func exactlyOneHundredIsNotExpensive() {
    #expect(isExpensive(100) == false)
}
```

Then check just that mutant again. Pass the key from the report to `--only`:

```bash
xcmutate run --package . --scheme Shop --destination 'platform=macOS' \
  --only 'Sources/Shop/Price.swift::isExpensive(_:)::boundary::3cdaf5b521d8a78f'
```

```
xcmutate 0.13.0: 1 mutant (scope: only)
  Killed 1
```

The gap is closed. `run` works on a copy of the repository, so it does not modify your files, and the new test did not have to be committed first: the work copy includes uncommitted changes.

## 2. A larger package: reading the report

This package has more mutants, and some code that no test runs. Its report shows both kinds of gap.

### The package

Create it next to `Shop`, not inside it:

```bash
cd ..
mkdir PriceKit && cd PriceKit
mkdir -p Sources/PriceKit Tests/PriceKitTests
```

`Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PriceKit",
    products: [.library(name: "PriceKit", targets: ["PriceKit"])],
    targets: [
        .target(name: "PriceKit"),
        .testTarget(name: "PriceKitTests", dependencies: ["PriceKit"]),
    ]
)
```

`Sources/PriceKit/Cart.swift`:

```swift
public struct Cart {
    public private(set) var prices: [Int] = []
    public private(set) var log: [String] = []

    public init() {}

    public mutating func add(_ price: Int) {
        guard price > 0 else { return }
        prices.append(price)
    }

    /// The sum of the prices, with 10% off from 1,000 upward.
    public func total() -> Int {
        let sum = prices.reduce(0, +)
        if sum >= 1000 {
            return sum - sum / 10
        }
        return sum
    }

    public mutating func checkout() -> Int {
        let amount = total()
        record("checkout \(amount)")
        prices.removeAll()
        return amount
    }

    mutating func record(_ line: String) {
        log.append(line)
    }
}
```

`Tests/PriceKitTests/CartTests.swift`:

```swift
import XCTest
@testable import PriceKit

final class CartTests: XCTestCase {
    func testTotalOfSmallCart() {
        var cart = Cart()
        cart.add(300)
        cart.add(200)
        XCTAssertEqual(cart.total(), 500)
    }

    func testDiscountOnLargeCart() {
        var cart = Cart()
        cart.add(2000)
        XCTAssertEqual(cart.total(), 1800)
    }
}
```

Commit it:

```bash
printf '.build/\n' > .gitignore
git init && git add -A && git commit -m "PriceKit"
```

### The run

```bash
xcmutate run --package . --scheme PriceKit --destination 'platform=macOS'
```

The report:

```
xcmutate 0.13.0: 11 mutants (scope: all)
  Killed 4, Survived 3, NotReached 4
  mutation score: 36.4% (detected / (detected + survived + not reached))
  among reached:  57.1% (detected / (detected + survived))
  time: total 25s, build 2s (1 build), baseline 1.5s, 2.7s per mutant (7 run)
  tests run: all tests
  files not mutated: package-manifest 1, test-code 1
    Package.swift (package-manifest)

Survived / not reached:
  Sources/PriceKit/Cart.swift:8:15 [Survived] guard-removal `price > 0` -> `true`  (Cart.add(_:))
    key: Sources/PriceKit/Cart.swift::Cart.add(_:)::guard-removal::ff3c273c99a4d589
  Sources/PriceKit/Cart.swift:8:21 [Survived] boundary `>` -> `>=`  (Cart.add(_:))
    key: Sources/PriceKit/Cart.swift::Cart.add(_:)::boundary::75d7e31db850b6ad
  Sources/PriceKit/Cart.swift:15:16 [Survived] boundary `>=` -> `>`  (Cart.total())
    key: Sources/PriceKit/Cart.swift::Cart.total()::boundary::f309fc6b68d464a4
  Sources/PriceKit/Cart.swift:23:9 [NotReached] side-effect-removal remove `record("checkout \(amount)")`  (Cart.checkout())
    key: Sources/PriceKit/Cart.swift::Cart.checkout()::side-effect-removal::78101b9fd80cd9b2
  …
```

### Reading the report

The tool made 11 mutants. The tests detected 4 of them (Killed). The other 7 went undetected.

The 7 undetected mutants are listed under "Survived / not reached". The first package had only Survived; here there are two kinds, and they call for different work:

| In the report | What happened | What to do |
|---|---|---|
| `[NotReached]` | No test ran this code. The mutant was not run, because no test could have failed | Write a test that calls the code. Here: nothing tests `checkout()` |
| `[Survived]` | Tests ran the mutated code and still passed | Make a test notice the change: a new input, or a stricter assertion |

Each gap has one line with the file, line and column, the operator (the kind of change), the change itself, and the enclosing function. For example:

```
Sources/PriceKit/Cart.swift:15:16 [Survived] boundary `>=` -> `>`  (Cart.total())
```

On line 15, `sum >= 1000` was turned into `sum > 1000`, and both tests still passed. They use sums of 500 and 2,000. Neither tells `>=` from `>`: only a sum of exactly 1,000 does.

As in section 1, the line below each gap is its *stable key*. It names the mutant without line numbers, so it stays valid when you edit other parts of the file. You pass it to `--only` and to `accept`.

The report has two scores. The *mutation score* counts unreached code as undetected. The score *among reached* leaves it out, so it says how well the assertions work on the code that the tests do run.

When the report has warnings, read them before the score. They say when a result is less complete than it looks ([reports.md](reports.md#warnings)).

### Closing a gap

Add a test for the boundary to `CartTests.swift`:

```swift
    func testDiscountStartsAtExactlyOneThousand() {
        var cart = Cart()
        cart.add(1000)
        XCTAssertEqual(cart.total(), 900)
    }
```

Then run only that mutant again. Copy its key from the report:

```bash
xcmutate run --package . --scheme PriceKit --destination 'platform=macOS' \
  --only 'Sources/PriceKit/Cart.swift::Cart.total()::boundary::f309fc6b68d464a4'
```

```
xcmutate 0.13.0: 1 mutant (scope: only)
  Killed 1
```

The gap is closed.

A few rules keep these tests useful:

- Assert behavior that a caller can observe, not internal state.
- Name the test after the behavior, not after the mutant.
- Do not change the code under test to make a mutant go away.

## 3. A mutant that no test can detect

Some mutants are *equivalent*: no input tells them apart from the original. A common example is `>` turned into `>=` where both branches give the same value when the two sides are equal.

Do not write a test that pins an implementation detail to kill such a mutant. Record it with a reason instead:

```bash
xcmutate accept '<key>' --reason "equivalent: both branches return the same value when a == b"
```

This writes the key and the reason to `xcmutate.accepted.json` at the root of the repository. Commit the file and review it like code. In later runs the mutant is reported as Accepted and counts neither in the score nor as a gap ([usage.md](usage.md#accept)).

## 4. Your own app, on a simulator

The loop is the same. Three things are different.

First, mutate only your change. `--since origin/main` keeps the mutants on lines changed since the merge base with `origin/main`. Uncommitted changes count as changed.

Second, name a booted simulator. The tool does not choose or boot a simulator for you.

```bash
xcrun simctl list devices           # choose a simulator and copy its UDID
xcrun simctl boot <SIMULATOR-UDID>  # boot it and leave it running

xcmutate run --since origin/main \
  --workspace App.xcworkspace --scheme App \
  --destination 'id=<SIMULATOR-UDID>' \
  --only-testing AppTests
```

If the simulator is not running, `xcodebuild` boots it for every mutant and shuts it down again. That makes a run several times slower (about 26 s instead of 5 s per mutant in one measurement).

Third, leave UI tests out. UI test targets are not supported. `--only-testing AppTests` (your unit-test target) keeps them out of the run.

When tests were selected with `--only-testing`, the list of gaps is headed "Survived / not reached (among the selected tests only)": a test that was not selected might still reach or detect the mutant.

Two more things can stop a first run on an app:

- Files that git ignores (generated sources, local `.xcconfig` files) are not in the work copy. Create them with `--prepare` ([usage.md](usage.md#when-the-build-cannot-find-a-file)).
- A permission dialog on a new simulator blocks the tests. Grant the permissions first ([usage.md](usage.md#run)).

## Where to go next

- If the run is slow: by default every mutant costs one launch of the tests (2.7 s per mutant in the run of section 2, about 5 to 8 s on a simulator). Adding `--shared-process` runs many mutants in one test process; the run of section 2 then takes about 6 s instead of about 24 s, with the same result. [speed.md](speed.md) says which options help for short and for long test suites.
- For CI, [ci.md](ci.md) covers gates, exit codes, a GitHub Action and a plain shell script.
- Everything else: [usage.md](usage.md) (all options), [reports.md](reports.md) (formats, warnings, exit codes), [configuration.md](configuration.md) (what is mutated), [operators.md](operators.md) (the changes the tool makes).
