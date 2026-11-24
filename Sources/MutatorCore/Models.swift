/// Kinds of mutation operators.
///
/// The basic set. Replacements that tend to produce equivalent mutants (e.g. `>` → `<`) are not included.
public enum MutationOperator: String, Codable, CaseIterable, Sendable {
    /// `==` ↔ `!=`
    case equalityFlip = "equality-flip"
    /// `<` ↔ `<=`, `>` ↔ `>=` (boundary change; detects off-by-one errors)
    case boundary = "boundary"
    /// `&&` ↔ `||`
    case logicalConnector = "logical-connector"
    /// `!x` → `x`
    case negationRemoval = "negation-removal"
    /// `true` ↔ `false`
    case booleanLiteral = "boolean-literal"
    /// `c ? a : b` → `c ? b : a`
    case ternarySwap = "ternary-swap"
    /// Removes a function-call statement whose return value is discarded (wrapped as `if !isOn(ID) { statement }`)
    case sideEffectRemoval = "side-effect-removal"
    /// Replaces the expression of `return <expr>` with another value that can be built from the return type (another enum case returned in the same function, `nil`, empty, 0)
    case returnValue = "return-value"
    /// Where a loop sets a flag that is returned at the end, replaces the flag assignment with an early return of "the value returned when the flag is set"
    case earlyReturn = "early-return"
    /// When an `if` / `guard` has several conditions, turns the expression conditions into `true` one at a time (removes them)
    case conditionRemoval = "condition-removal"
    /// Unlabeled `continue` ↔ `break` inside a loop
    case loopControl = "loop-control"
    /// Removes string normalization calls (such as `.lowercased()`)
    case normalizationRemoval = "normalization-removal"
    /// Negates a Bool condition of `if` / `guard` that contains no operator (`if items.isEmpty` → `if !(items.isEmpty)`)
    case conditionNegation = "condition-negation"
    /// Negates the expression of a `return <expr>` that returns Bool (including functions and getters whose body is a single expression) (`return items.contains(id)` → `return !(…)`)
    case returnNegation = "return-negation"
    /// Removes the operands of `&&` / `||` one at a time (`a && b` → `true && b`, `a && true`; `false` for `||`)
    case operandRemoval = "operand-removal"
    /// Arithmetic operators `+` ↔ `-`, `*` ↔ `/` (expressions containing string or array literals are not mutated). Disabled by default
    case arithmetic = "arithmetic"
    /// Replaces a numeric or string literal on the right-hand side of `??` with another value (`n ?? 0` → `n ?? 1`, `s ?? "none"` → `s ?? ""`)
    case nilCoalescingDefault = "nil-coalescing-default"
    /// `min` ↔ `max` with two arguments
    case minMax = "min-max"
    /// Empties the body of a function with no return value (one per function; wrapped as `if !isOn(ID) { body }`)
    case emptyBody = "empty-body"
    /// Compound assignment `+=` ↔ `-=`, `*=` ↔ `/=` (not mutated when the right-hand side is a string or array literal). Disabled by default
    case compoundAssignment = "compound-assignment"
    /// Removes one case of a `switch` that has a `default` (turns it into `case .a where !isOn(ID):` so that it falls through to default)
    case switchCaseRemoval = "switch-case-removal"
    /// `try? f()` → `nil`
    case tryOptionalNil = "try-optional-nil"
    /// Turns an `if` condition into `false` (one direction only: the body is never entered; it is never turned into `true`)
    case conditionConstant = "condition-constant"
    /// Turns the condition of a `guard` with a single condition into `true` (one direction only: the early exit no longer happens)
    case guardRemoval = "guard-removal"
    /// Replaces the expression of a `return` that is an enum case with arguments (`.failure(error)`) with another value that the
    /// same function returns and that needs nothing from its surroundings (`.none`, `.failure(.invalid)`)
    case returnCase = "return-case"
    /// Replaces the single expression of a body that returns a value (function, getter, subscript, closure with a declared return type)
    /// with another value that can be built from the return type (`nil`, empty, 0)
    case implicitReturnValue = "implicit-return-value"
    /// Removes a function-call statement whose return value is discarded inside a closure that is known not to be a result builder
    case closureStatementRemoval = "closure-statement-removal"

    /// Operators not used by default (they can be enabled with `--enable-operator` / `enabledOperators` in the config file).
    ///
    /// The rule (docs/operators.md): an operator is on by default if, on real code, at most 5% of its
    /// mutants fail to compile and at most 10% of the mutants that the tests reach are equivalent; a default is changed
    /// only on at least 20 reached mutants.
    /// - `arithmetic`: types are unknown, so the `+` of string concatenation is turned into `-` too (20% did not compile)
    /// - `compound-assignment`: same reason (`text += "a"`; 57% did not compile), and a counter turned around never ends
    /// - `nil-coalescing-default`: 8% did not compile, and it is equivalent when the default value and its replacement fall
    ///   on the same side of a later check; too few reached mutants (6) to say more
    /// - `try-optional-nil`: 31% equivalent (9 of 29 reached). `try?` is used where a failure is tolerable, and the code
    ///   around it often gives the same result either way (`(try? existing()) ?? create()`, a later attempt that succeeds)
    /// - `condition-removal`: 20% equivalent (8 of 40 reached): conditions that guard a trap, a range check that cannot
    ///   fail, a later check that catches the same input
    /// - `return-case`, `implicit-return-value`, `closure-statement-removal`: added last; fewer than 20 reached
    ///   mutants each on real code so far (8, 19 and 4), which is not enough to switch them on
    public static let disabledByDefault: Set<MutationOperator> = [.nilCoalescingDefault, .arithmetic, .compoundAssignment,
                                                                .tryOptionalNil, .conditionRemoval,
                                                                .returnCase, .implicitReturnValue, .closureStatementRemoval]

    /// Operators that replace a statement with another statement (instrumented as `if isOn(ID) { mutated version } else { original statement }`)
    public var replacesStatement: Bool { self == .earlyReturn || self == .loopControl || self == .compoundAssignment }

    /// Operators that prevent a statement (or a sequence of statements) from running (instrumented as `if !isOn(ID) { original statement }`)
    public var removesStatement: Bool { self == .sideEffectRemoval || self == .emptyBody || self == .closureStatementRemoval }

    /// Operators instrumented by adding `where !isOn(ID)` to each pattern of a `case`
    public var guardsCase: Bool { self == .switchCaseRemoval }

    /// A hint for an AI or a person writing tests: what a test that detects a mutant of this operator must distinguish.
    /// Sentences determined mechanically from the meaning of the operator alone (listed in the report's `obligations`, one per operator used).
    public var testObligation: String {
        switch self {
        case .equalityFlip:
            "`==` and `!=` give opposite results for every input: any test that executes this comparison and asserts on what depends on it detects the change. If it survives, no assertion depends on this comparison."
        case .boundary:
            "The two versions differ only when both sides are exactly equal: use the boundary value itself as an input (e.g. for `a > b`, a case where a == b) and assert on the result."
        case .logicalConnector:
            "`&&` and `||` differ only when exactly one operand is true: add a case where one side is true and the other false, and assert on the result."
        case .negationRemoval, .conditionNegation, .returnNegation:
            "The value is inverted for every input: assert on the result (or the effect of the branch taken) for at least one input. If it survives, nothing observable depends on this value in the tests."
        case .booleanLiteral:
            "The literal is flipped: assert on behaviour that depends on this flag or argument (both what happens when it is true and when it is false, if both are reachable)."
        case .ternarySwap:
            "The two branches are swapped: assert on the value for a case where the condition is true and for one where it is false (the two branches must produce observably different results)."
        case .sideEffectRemoval, .closureStatementRemoval:
            "The call is not made: assert on the effect of the call (a stored value, a sent notification, a delegate callback, a changed state), not only on the return value of the enclosing function."
        case .returnCase:
            "The function returns another of its results at this return (another enum case, or the same case with other contents): assert on the exact returned value, including what the case carries, for an input that reaches this return."
        case .implicitReturnValue:
            "The body returns a fixed other value (nil, empty or 0) instead of its expression: assert on the exact value for at least one input."
        case .returnValue:
            "The function returns a fixed other value (nil, empty, 0 or another enum case) at this return: assert on the exact returned value for an input that reaches this return."
        case .earlyReturn:
            "The loop returns as soon as the flag would be set, skipping the remaining elements: use an input where a later element changes the result (e.g. a stronger case after the first match)."
        case .conditionRemoval:
            "One condition of the list is treated as always true: add a case where only this condition is false (all the others true) and assert that the guarded code does not run / the early exit happens."
        case .loopControl:
            "`continue` and `break` differ only when later elements matter: use an input with a relevant element after the one that hits this statement."
        case .normalizationRemoval:
            "The normalization (case folding, trimming) is skipped: use an input that the normalization actually changes (mixed case, surrounding whitespace) and assert on the result."
        case .operandRemoval:
            "One operand is ignored: add a case where only this operand decides the result (for `&&`: this operand false and the other true; for `||`: this operand true and the other false)."
        case .arithmetic, .compoundAssignment:
            "The operation is replaced by its inverse (`+`/`-`, `*`/`/`): assert on the exact computed value with operands for which the two operations differ (not 0 for +/-, not 1 for */÷)."
        case .nilCoalescingDefault:
            "The fallback value is changed: add a case where the left side is nil and assert on the result that depends on the fallback."
        case .minMax:
            "`min` and `max` differ whenever the two arguments differ: use arguments that are not equal and assert on the result."
        case .emptyBody:
            "The whole function does nothing: call it and assert on any of its effects (state it updates, calls it makes, values observable afterwards)."
        case .switchCaseRemoval:
            "Values of this case are handled by `default` instead: use an input that matches this case and assert on the behaviour that differs from the default branch."
        case .tryOptionalNil:
            "The call is not made and the result is nil, as if it had thrown: add a case where the call succeeds and assert on what depends on its value (or its effect)."
        case .conditionConstant:
            "The body of the `if` never runs (its `else`, if any, always runs): add a case where the condition is true and assert on the effect of the body."
        case .guardRemoval:
            "The early exit of the `guard` never happens: add a case where the condition is false and assert on the result of the early exit (it must differ from what the rest of the function produces for that input)."
        }
    }
}

/// A range of lines (1-based, inclusive at both ends).
public struct LineSpan: Codable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func contains(_ line: Int) -> Bool { start <= line && line <= end }
}

/// The declaration enclosing a mutant (function, accessor, property, etc.). Used to show the surrounding source in reports.
public struct MutantScope: Codable, Hashable, Sendable {
    public var id: String
    public var lines: LineSpan

    public init(id: String, lines: LineSpan) {
        self.id = id
        self.lines = lines
    }
}

/// A UTF-8 byte range within a file (half-open interval `[start, end)`).
public struct ByteRange: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        precondition(start <= end, "ByteRange start must not exceed end")
        self.start = start
        self.end = end
    }

    public var length: Int { end - start }

    public func contains(_ other: ByteRange) -> Bool {
        start <= other.start && other.end <= end
    }

    /// Whether the two ranges overlap by at least one byte. A zero-length range counts as overlapping if it lies inside the other (including its ends).
    public func overlaps(_ other: ByteRange) -> Bool {
        if length == 0 { return other.start <= start && start <= other.end }
        if other.length == 0 { return start <= other.start && other.start <= end }
        return start < other.end && other.start < end
    }

    public static func < (lhs: ByteRange, rhs: ByteRange) -> Bool {
        (lhs.start, -lhs.end) < (rhs.start, -rhs.end)
    }

    public var description: String { "[\(start), \(end))" }
}

/// A position in the source (1-based; columns are in UTF-8 bytes).
public struct SourcePosition: Codable, Hashable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// A single mutant.
///
/// Syntax tree nodes are not retained (a lesson from Muter #321/#322). Positions are expressed only as UTF-8 byte ranges.
public struct Mutant: Codable, Hashable, Sendable {
    /// Numeric ID for execution (the value passed to `XCMUTATE_ACTIVE`). Reassigned on every run.
    public var id: Int
    /// Stable key that does not depend on position (line numbers). Used for caching and for matching against previous results.
    public var key: String
    public var `operator`: MutationOperator
    /// Path relative to the workspace root (as passed by the caller).
    public var file: String
    /// Path of the enclosing declaration (e.g. `Cart.total(of:)`).
    public var enclosingDecl: String
    /// Range of the expression replaced by the switch.
    public var region: ByteRange
    /// Range of the part that is actually rewritten (such as the operator token). Used by the diff filter and in reports.
    public var point: ByteRange
    public var start: SourcePosition
    public var end: SourcePosition
    /// Text of the part before rewriting (e.g. `>`).
    public var original: String
    /// Text of the part after rewriting (e.g. `>=`).
    public var replacement: String
    /// Original text of the replaced expression.
    public var originalExpression: String
    /// The expression that goes into the mutated branch of the switch (contains no newlines). An empty string for statement removal.
    public var mutatedExpression: String
    /// Lines of the range replaced by the switch (used to identify the mutant from compiler diagnostics).
    public var regionLines: LineSpan
    /// The enclosing declaration and its line range.
    public var scope: MutantScope
    /// `switch-case-removal` only: positions where `where !isOn(ID)` is inserted (UTF-8 byte offsets within the file, inside `region`).
    public var guardOffsets: [Int]?

    /// Whether this is a statement-level mutant (statement removal, statement replacement, case removal).
    /// It is instrumented in a dedicated form rather than as a ternary expression switch. No other mutant can be stacked on the same range.
    public var isStatement: Bool { `operator`.removesStatement || `operator`.replacesStatement || `operator`.guardsCase }
}

/// What a run is built for, as far as `#if os(…)`, `#if targetEnvironment(…)` and `#if canImport(UIKit / AppKit)` ask.
public struct TargetPlatform: Sendable, Equatable, Hashable {
    /// The name that `os(…)` takes: `iOS`, `macOS`, `tvOS`, `watchOS`, `visionOS`.
    public var os: String
    public var isSimulator: Bool
    public var isMacCatalyst: Bool

    public init(os: String, isSimulator: Bool = false, isMacCatalyst: Bool = false) {
        self.os = os
        self.isSimulator = isSimulator
        self.isMacCatalyst = isMacCatalyst
    }

    /// From the `platform` field of an `xcodebuild -destination` value (`iOS Simulator`, `macOS`), or nil if it is not one that is known.
    public init?(destinationPlatform platform: String, variant: String? = nil) {
        let simulator = platform.hasSuffix(" Simulator")
        let name = simulator ? String(platform.dropLast(" Simulator".count)) : platform
        guard ["iOS", "macOS", "tvOS", "watchOS", "visionOS"].contains(name) else { return nil }
        if name == "macOS", variant == "Mac Catalyst" {
            self.init(os: "iOS", isSimulator: false, isMacCatalyst: true)
        } else {
            self.init(os: name, isSimulator: simulator)
        }
    }
}

/// The reason a mutant was not created (not instrumented).
public enum IgnoreReason: String, Codable, Sendable, CaseIterable {
    case ifConfigCondition = "if-config-condition"
    /// In a branch of `#if` that is not compiled for the destination of the run (`#if os(iOS)` in a run on macOS).
    case inactiveIfConfig = "inactive-if-config"
    case macroExpansion = "macro-expansion"
    case attributeArgument = "attribute-argument"
    case typeContext = "type-context"
    case enumCase = "enum-case"
    case pattern = "pattern"
    case keyPath = "key-path"
    case inoutArgument = "inout-argument"
    case deinitializer = "deinit"
    case operatorDeclaration = "operator-declaration"
    case inlinableBody = "inlinable-body"
    case publicDefaultArgument = "public-default-argument"
    case frozenPropertyInitializer = "frozen-property-initializer"
    case aridCall = "arid-call"
    case aridArgument = "arid-argument"
    case constantCondition = "constant-condition"
    case unfoldableOperators = "unfoldable-operators"
    case disabledByComment = "disabled-by-comment"
    /// In a declaration whose name matches `excludeDeclarations` of the config file.
    case excludedDeclaration = "excluded-declaration"
    case tooManyInExpression = "too-many-in-expression"
    case cannotFlatten = "cannot-flatten"
    // Reasons specific to statement removal
    case neverReturning = "never-returning"
    case initializerDelegation = "initializer-delegation"
    case synchronization = "synchronization"
    case implicitReturn = "implicit-return"
    case resultBuilder = "result-builder"
    case guardElse = "guard-else"
    /// An expression mutant on the same range as a statement removal (two kinds of switches cannot be stacked on the same range)
    case sameRangeAsStatement = "same-range-as-statement"
    /// Part of an optional chain would be wrapped in parentheses (wrapping only `b.c()` of `a?.b.c()` cuts the chain there and changes the meaning)
    case optionalChain = "optional-chain"
    /// The expression of `return switch …` / `return if …` (a `switch` / `if` expression cannot be placed inside a ternary branch)
    case controlFlowExpression = "control-flow-expression"
    /// Another operator produced the same rewrite on the same range (merged into one)
    case duplicate = "duplicate"
}

/// A mutant candidate that was not instrumented. Kept so that it is listed in the report instead of being silently discarded.
public struct IgnoredMutant: Codable, Hashable, Sendable {
    public var `operator`: MutationOperator
    public var file: String
    public var enclosingDecl: String
    public var point: ByteRange
    public var start: SourcePosition
    public var original: String
    public var replacement: String
    public var reason: IgnoreReason
}

/// Generation options.
public struct GeneratorOptions: Sendable {
    /// Maximum number of switches in one expression (the outermost expression of a nest). The excess is excluded as `tooManyInExpression`.
    public var maxSwitchesPerExpression: Int
    /// Operators to enable.
    public var operators: Set<MutationOperator>
    /// Function names excluded together with their arguments (arid nodes).
    public var aridCallNames: Set<String>
    /// Argument labels whose boolean literals are excluded.
    public var aridArgumentLabels: Set<String>

    /// Method names treated as arid for statement removal (layout updates, etc.).
    public var aridStatementNames: Set<String> = [
        "setNeedsLayout", "layoutIfNeeded", "setNeedsDisplay", "layoutSubviews", "setNeedsUpdateConstraints",
    ]
    /// Function names known not to return (returning `Never`). Functions declared with `-> Never` in the same file are also included.
    public var neverReturningNames: Set<String> = ["fatalError", "preconditionFailure", "abort", "exit", "_exit"]
    /// Method names whose removal causes deadlocks or broken synchronization (locks, semaphores, DispatchGroup).
    public var synchronizationMethodNames: Set<String> = [
        "lock", "unlock", "tryLock", "signal", "wait", "broadcast", "enter", "leave",
    ]

    /// Arid calls added by configuration (`aridCalls` in `xcmutate.config.json` / `--arid`).
    /// A call is treated as arid if the text of the called expression matches one of these, starts with `<pattern>.` / `<pattern>(`,
    /// or its last name (method or function name) matches one of these (e.g. `Crashlytics`, `LoginAnalytics`, `sendAnalytics`).
    public var aridCallPatterns: [String] = []
    /// Names of declarations whose bodies are not mutated (`excludeDeclarations` of the config file): a name, or a
    /// pattern with `*`, compared with the name of every declaration that encloses a candidate (`DeclarationPatterns`).
    public var excludedDeclarationPatterns: [String] = []
    /// Calls removed as string normalization (`normalization-removal`).
    public var normalizationMethodNames: Set<String> = ["lowercased", "uppercased", "trimmingCharacters", "localizedLowercase", "localizedUppercase"]
    /// Operators and precedence groups declared in other files (Swift text listing only `precedencegroup` / `operator` declarations).
    /// Lets expressions containing custom operators declared in other files of the same module be folded too (`OperatorDeclarations.extract`).
    public var extraOperatorDeclarations: String = ""
    /// The platform the run builds for (`run` derives it from `--destination`). When it is known, mutants in a
    /// branch of `#if` that is not compiled for it are left out with the reason `inactive-if-config`: no test of
    /// this run can reach them, and reporting them as NotReached would ask for tests that cannot exist.
    public var targetPlatform: TargetPlatform?
    /// Names of the result builder types declared anywhere in the project (`@resultBuilder struct ViewBuilder`).
    /// A declaration with an attribute of one of these names is a builder body; names that end in `Builder` and
    /// `var body: some …` are recognized without this list.
    public var resultBuilderNames: Set<String> = []
    /// Maximum number of enum case replacements created for one return.
    public var maxReturnAlternatives: Int = 2
    /// Calls whose closure arguments return nothing and are never result builders (`closure-statement-removal` also
    /// applies to such a closure when it consists of one statement).
    public var voidClosureCallNames: Set<String> = [
        "forEach", "async", "asyncAfter", "asyncAndWait", "addOperation", "animate", "performBatchUpdates", "performWithoutAnimation",
        "enumerateAttributes", "enumerateAttribute", "enumerateObjects", "enumerateKeysAndObjects", "enumerateLines", "enumerateSubstrings",
    ]
    /// Calls whose closure arguments are never result builders but may return a value (`closure-statement-removal`
    /// applies to such a closure when it has two or more statements, where no statement can be its value).
    public var plainClosureCallNames: Set<String> = ["Task", "detached", "sync", "addTask", "withAnimation", "performAndWait"]

    public init(
        maxSwitchesPerExpression: Int = 12,
        operators: Set<MutationOperator> = Set(MutationOperator.allCases).subtracting(MutationOperator.disabledByDefault),
        aridCallNames: Set<String> = GeneratorOptions.defaultAridCallNames,
        aridArgumentLabels: Set<String> = ["animated"]
    ) {
        self.maxSwitchesPerExpression = maxSwitchesPerExpression
        self.operators = operators
        self.aridCallNames = aridCallNames
        self.aridArgumentLabels = aridArgumentLabels
    }

    public static let defaultAridCallNames: Set<String> = [
        "print", "debugPrint", "dump", "NSLog", "os_log",
        "assert", "assertionFailure", "precondition", "preconditionFailure", "fatalError",
    ]

    /// Logging method names of `Logger` and the like. Treated as arid only when the receiver expression contains `log`.
    public static let loggerMethodNames: Set<String> = [
        "log", "trace", "debug", "info", "notice", "warning", "error", "critical", "fault",
    ]
}
