import Foundation
@testable import MutatorCore
import SwiftParser
import Testing

/// Shapes of code whose instrumented form once did not compile, although the original does and every
/// mutant could be written by hand. With mutant schemata every mutated branch is compiled in the one build, so
/// "the instrumented program compiles" means: no shape here breaks the build, with or without a mutant on.
/// The program is really compiled (a missing return is only found after type checking), then run with all
/// mutants off and compared with the original.
@Suite(.serialized) struct CompilableShapesTests {
    static let program = #"""
    // The body is one `switch` / `if` expression whose branches are calls
    enum Tab { case home, settings, other }
    func loc(_ text: String) -> String { text }
    extension Tab {
        var title: String {
            switch self {
            case .home: loc("Home")
            case .settings: loc("Settings")
            default: loc("Other")
            }
        }
        var subtitle: String {
            if self == .home { loc("H") } else { loc("X") }
        }
        func name() -> String {
            switch self {
            case .home: loc("h")
            default: loc("o")
            }
        }
    }
    let pickTitle: (Tab) -> String = { tab in
        switch tab {
        case .home: loc("closure home")
        default: loc("closure other")
        }
    }

    // A function that ends, on some path, with a call that does not return, under a name that no list holds
    // (declared in another module, or a closure of type `(String) -> Never`)
    let stop: (String) -> Never = { fatalError($0) }
    func classify(_ n: Int) -> String {
        if n < 0 { return "neg" }
        if n == 0 { return "zero" }
        if n > 0 { return "pos" }
        stop("unreachable")
    }
    func pick(_ n: Int) -> Int {
        switch n {
        case 0:
            return 1
        default:
            if n > 100 {
                stop("too large")
            } else {
                do {
                    return n * 2
                }
            }
        }
    }

    // There is no value to negate
    func stub() -> Bool { fatalError("not implemented") }

    // A ternary whose branches have different types that only the context unifies
    protocol Shape { var sides: Int { get } }
    struct Circle: Shape { let sides = 0 }
    struct Square: Shape { let sides = 4 }
    func shape(_ round: Bool) -> any Shape { return round ? Circle() : Square() }
    func take(_ shape: any Shape) -> Int { shape.sides }
    func sides(_ round: Bool) -> Int { take(round ? Circle() : Square()) }
    func describe(_ value: Double?) -> String { value.map { "\($0)" } ?? "nil" }
    func optional(_ present: Bool, _ value: Double) -> String { describe(present ? value : nil) }
    func anything(_ flag: Bool) -> Any { return flag ? 1 : "one" }

    // Bodies that are compiled into other modules cannot name the file-private helper
    public struct Hot {
        @inline(always) public func isGreater(_ a: Int, _ b: Int) -> Bool { return a > b }
        @inline(always) func isLess(_ a: Int, _ b: Int) -> Bool { return a < b }
    }
    public extension Hot {
        @inline(always) func isEqual(_ a: Int, _ b: Int) -> Bool { return a == b }
    }

    // A result builder whose name does not end in `Builder`, and which has no `buildOptional`
    @resultBuilder enum Sum { static func buildBlock(_ parts: Int...) -> Int { parts.reduce(0, +) } }
    func one() -> Int { 1 }
    @Sum func built() -> Int {
        one()
        one()
    }

    // Mutants that need not fail to compile
    func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return "\(first.uppercased())\(text.dropFirst())"
    }
    func lowerTail(_ text: String) -> String {
        var result = ""
        for character in text { result += character.lowercased() }
        return text[text.startIndex...].lowercased() + result
    }
    func timesZero(_ a: Int, _ b: Int) -> Bool { a * 0 < b }
    func label(_ name: String, _ value: Int) -> String { name + "#" + String(value) }
    func constant() -> String { "t \(2 / 1 / 3)" }

    // Statements that are removed, next to the ones above that are not
    var counter = 0
    func record(_ n: Int) { counter += n }
    func bump(_ n: Int) {
        record(n)
        record(n + 1)
    }

    for tab in [Tab.home, .settings, .other] { print(tab.title, tab.subtitle, tab.name(), pickTitle(tab)) }
    for n in [-1, 0, 1, 5] { print(classify(n), pick(n)) }
    print(shape(true).sides, shape(false).sides, sides(true), sides(false), optional(true, 1.5), optional(false, 1.5), anything(true), anything(false))
    print(Hot().isGreater(2, 1), Hot().isLess(2, 1), Hot().isEqual(2, 2), built())
    print(capitalized("abc"), lowerTail("AbC"), timesZero(3, 1), label("n", 2), constant())
    bump(2)
    print(counter)

    """#

    static let all = GeneratorOptions(operators: Set(MutationOperator.allCases))

    /// The default operators and `arithmetic`. (`compound-assignment`, off by default, turns `text += x` into
    /// `text -= x`, which no rule can know to be a `String`: such a mutant is removed by the build, as designed.)
    static let defaultsAndArithmetic: GeneratorOptions = {
        var options = GeneratorOptions()
        options.operators.insert(.arithmetic)
        return options
    }()

    @Test(.enabled(if: swiftcAvailable), .timeLimit(.minutes(10)))
    func theInstrumentedProgramCompilesAndBehavesAsBefore() throws {
        try withTemporaryDirectory { directory in
            let original = try compileSwift(Self.program, in: directory, name: "original", arguments: ["-swift-version", "5"])
            try #require(original.status == 0, "the original must compile:\n\(original.output)")
            let result = FileProcessor(options: Self.defaultsAndArithmetic).process(source: Self.program, file: "main.swift", firstID: 0)
            expectValidInstrumentation(result)
            #expect(result.mutants.count > 30)
            for expected in [MutationOperator.ternarySwap, .normalizationRemoval, .arithmetic, .sideEffectRemoval, .switchCaseRemoval, .boundary] {
                #expect(result.mutants.contains { $0.operator == expected }, "no \(expected.rawValue) mutant in the program")
            }
            let instrumented = try compileSwift(result.instrumented, in: directory, name: "instrumented", arguments: ["-swift-version", "5"])
            let errors = instrumented.output.split(separator: "\n").filter { $0.contains("error:") }
            #expect(instrumented.status == 0, "the instrumented program must compile:\n\(errors.joined(separator: "\n"))")
            guard instrumented.status == 0 else { return }
            let before = try #require(runProcess(original.executable, []))
            let after = try #require(runProcess(instrumented.executable, []))
            #expect(after.output == before.output)
        }
    }

    private func mutants(_ source: String, _ operators: Set<MutationOperator>) -> GenerationResult {
        MutantGenerator(options: GeneratorOptions(operators: operators)).generate(source: source, filePath: "T.swift")
    }

    /// What exactly is left out, and with which reason, in the shapes above.
    @Test func theValueOfABodyThatIsOneExpressionIsNotRemoved() {
        let result = mutants("""
        enum Tab { case home, other
            var title: String {
                switch self {
                case .home: loc("Home")
                default: loc("Other")
                }
            }
            func log() {
                switch self {
                case .home: loc("Home")
                default: loc("Other")
                }
            }
        }

        """, [.sideEffectRemoval, .switchCaseRemoval])
        // In the getter the calls are the value; in the function without a result they are statements
        #expect(result.ignored.filter { $0.reason == .implicitReturn }.map(\.start.line) == [4, 5])
        #expect(result.mutants.filter { $0.operator == .sideEffectRemoval }.map(\.start.line) == [10, 11])
        // The other mutants of the getter are still made
        #expect(result.mutants.contains { $0.operator == .switchCaseRemoval && $0.start.line == 4 })
    }

    @Test func aCallThatAValueReturningBodyEndsWithIsNotRemoved() {
        let source = """
        func classify(_ n: Int) -> String {
            log(n)
            if n < 0 { return "neg" }
            abortWith("unreachable")
        }
        func run(_ n: Int) {
            log(n)
            finish(n)
        }

        """
        let result = mutants(source, [.sideEffectRemoval])
        #expect(result.mutants.map(\.original) == ["log(n)", "log(n)", "finish(n)"])
        #expect(result.ignored.map(\.reason) == [.neverReturning])
        #expect(result.ignored.first?.original == "abortWith(\"unreachable\")")
    }

    /// Functions declared `-> Never` in another file of the project are known by name too.
    @Test func neverReturningFunctionsOfOtherFilesAreCollected() {
        let other = "func abortWith(_ message: String) -> Never { fatalError(message) }\\n@resultBuilder struct Rows {}\\n@resultBuilder enum HTMLBuilder {}\\n"
        let declarations = ProjectDeclarations.scan(sources: ["func unrelated() {}", other])
        #expect(declarations.neverReturningNames == ["abortWith"])
        #expect(declarations.resultBuilderNames == ["Rows", "HTMLBuilder"])
        var options = GeneratorOptions(operators: [.sideEffectRemoval, .returnNegation])
        declarations.apply(to: &options)
        #expect(options.neverReturningNames.isSuperset(of: ["fatalError", "abortWith"]))
        let source = """
        func check(_ ok: Bool) {
            if !ok { abortWith("no") }
            record()
        }
        func stub() -> Bool { abortWith("later") }
        @Rows func rows() -> [Int] {
            row()
            row()
        }

        """
        let result = MutantGenerator(options: options).generate(source: source, filePath: "T.swift")
        #expect(result.mutants.map(\.original) == ["record()"])
        #expect(Set(result.ignored.map(\.reason)) == [.neverReturning, .resultBuilder])
        // Without the names of the other file the call would be wrapped for removal
        let unaware = mutants(source, [.sideEffectRemoval])
        #expect(unaware.mutants.map(\.original).contains("abortWith(\"no\")"))
    }

    @Test func bodiesCompiledIntoOtherModulesAreNotMutated() {
        let result = mutants("""
        public struct P {
            @export(implementation) public func a(_ x: Int) -> Bool { x > 1 }
            @inline(always) public func b(_ x: Int) -> Bool { x > 1 }
            @inline(always) func c(_ x: Int) -> Bool { x > 1 }
            @inline(__always) public func d(_ x: Int) -> Bool { x > 1 }
            @inlinable public func e(_ x: Int) -> Bool { x > 1 }
        }
        public extension P {
            @inline(always) func f(_ x: Int) -> Bool { x > 1 }
        }
        extension P {
            @inline(always) func g(_ x: Int) -> Bool { x > 1 }
        }

        """, [.boundary])
        #expect(result.mutants.map(\.start.line) == [4, 5, 12])
        #expect(result.ignored.map(\.start.line) == [2, 3, 6, 9])
        #expect(result.ignored.allSatisfy { $0.reason == .inlinableBody })
    }

    @Test func arithmeticMutantsThatCannotCompileAreNotMade() {
        let result = mutants("""
        func f(_ a: Int, _ b: Int, _ name: String, _ xs: [Int]) -> Int {
            let label = name + "#" + String(b)
            let all = xs + [a] + xs
            let zero = a * 0
            let ratio = a * 0.0
            let constant = 2 / 1 / 3
            return a * b + a / 2 - label.count - all.count - zero - Int(ratio) - constant
        }

        """, [.arithmetic])
        #expect(Set(result.mutants.map(\.start.line)) == [7])
    }

    // MARK: Line endings

    static let multiline = """
    // A file comment
    func f(_ a: Int, _ b: Int) -> Bool {
        let both = a > 1 &&
            b > 2 // 日本語のコメント 🎌
        // xcmutate:disable-next-line boundary
        let skipped = a > 5
        log(a)
        return both ||
            skipped
    }
    func log(_ value: Int) {}
    print(f(2, 3), f(0, 0), f(9, 0))

    """

    static let endings: [(name: String, transform: @Sendable (String) -> String)] = [
        ("LF", { $0 }),
        ("CRLF", { $0.replacingOccurrences(of: "\n", with: "\r\n") }),
        ("CR", { $0.replacingOccurrences(of: "\n", with: "\r") }),
        ("no final line break", { String($0.dropLast()) }),
        ("CRLF, no final line break", { String($0.dropLast()).replacingOccurrences(of: "\n", with: "\r\n") }),
        ("byte order mark", { "\u{FEFF}" + $0 }),
        ("byte order mark and CRLF", { "\u{FEFF}" + $0.replacingOccurrences(of: "\n", with: "\r\n") }),
    ]

    private func lineBreaks(_ text: String) -> Int {
        var count = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A, previous != 0x0D { count += 1 }
            if byte == 0x0D { count += 1 }
            previous = byte
        }
        return count
    }

    @Test(arguments: endings.indices)
    func instrumentationKeepsTheLinesWhateverTheLineEndings(_ index: Int) throws {
        let ending = Self.endings[index]
        let source = ending.transform(Self.multiline)
        let reference = FileProcessor(options: Self.all).process(source: Self.multiline, file: "main.swift", firstID: 0)
        let result = FileProcessor(options: Self.all).process(source: source, file: "main.swift", firstID: 0)
        #expect(result.skippedReason == nil, "\(ending.name)")
        #expect(result.verification.isValid, "\(ending.name): \(result.verification.problems)")
        #expect(!Parser.parse(source: result.instrumented).hasError, "\(ending.name)")
        // The same mutants on the same lines, whatever the line endings (the disable comment still applies to line 6)
        #expect(result.mutants.map { "\($0.operator.rawValue) \($0.start.line)" } == reference.mutants.map { "\($0.operator.rawValue) \($0.start.line)" }, "\(ending.name)")
        #expect(result.mutants.contains { $0.start.line == 3 && $0.end.line == 4 } || result.mutants.contains { $0.regionLines.start == 3 && $0.regionLines.end == 4 }, "\(ending.name)")
        #expect(!result.mutants.contains { $0.operator == .boundary && $0.start.line == 6 }, "\(ending.name)")
        // Every line of the original is still on its line: the text before the helper has as many line breaks
        let marker = try #require(result.instrumented.range(of: Instrumenter.helperMarker))
        let body = String(result.instrumented[..<marker.lowerBound])
        let expected = lineBreaks(source) + (source.utf8.last == 0x0A || source.utf8.last == 0x0D ? 0 : 1)
        #expect(lineBreaks(body) == expected, "\(ending.name)")
        // No line ending of another kind was added
        if ending.name.contains("CRLF") { #expect(!body.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(ending.name)") }
        if ending.name.hasPrefix("byte order mark") { #expect(result.instrumented.unicodeScalars.first == "\u{FEFF}", "\(ending.name)") }
    }

    @Test(.enabled(if: swiftcAvailable), .timeLimit(.minutes(10)))
    func aFileWithCRLFLineEndingsCompilesAndBehavesAsBefore() throws {
        try withTemporaryDirectory { directory in
            let source = Self.multiline.replacingOccurrences(of: "\n", with: "\r\n")
            let result = FileProcessor(options: Self.all).process(source: source, file: "main.swift", firstID: 0)
            try #require(result.verification.isValid)
            let original = try compileSwift(source, in: directory, name: "original", arguments: ["-swift-version", "5"])
            let instrumented = try compileSwift(result.instrumented, in: directory, name: "instrumented", arguments: ["-swift-version", "5"])
            try #require(original.status == 0 && instrumented.status == 0, "\(original.output)\n\(instrumented.output)")
            let before = try #require(runProcess(original.executable, []))
            let after = try #require(runProcess(instrumented.executable, []))
            #expect(after.output == before.output)
        }
    }
}

/// Code in a branch of `#if` that is not compiled for the destination of the run cannot be reached by any
/// test of that run: its mutants are left out with a reason instead of being reported as NotReached.
@Suite struct InactiveIfConfigTests {
    static let source = """
    public func screenScale(_ points: Int) -> Int {
        #if os(iOS)
        if points > 100 { return points * 3 }
        return points * 2
        #elseif os(macOS) && !targetEnvironment(macCatalyst)
        return points > 1 ? points : 1
        #else
        return points > 0 ? points : 0
        #endif
    }
    func debugOnly(_ n: Int) -> Bool {
        #if DEBUG
        return n > 1
        #else
        return n > 2
        #endif
    }
    func kit(_ n: Int) -> Bool {
        #if canImport(UIKit) || os(tvOS)
        return n > 3
        #elseif canImport(Glibc)
        return n > 4
        #else
        return n > 5
        #endif
    }

    """

    private func lines(_ platform: TargetPlatform?) -> (made: [Int], inactive: [Int]) {
        var options = GeneratorOptions(operators: [.boundary])
        options.targetPlatform = platform
        let result = MutantGenerator(options: options).generate(source: Self.source, filePath: "P.swift")
        return (result.mutants.map(\.start.line), result.ignored.filter { $0.reason == .inactiveIfConfig }.map(\.start.line))
    }

    @Test func branchesForOtherPlatformsAreLeftOut() {
        // Without a platform (list, instrument): everything, as before
        #expect(lines(nil).made == [3, 6, 8, 13, 15, 20, 22, 24])
        #expect(lines(nil).inactive.isEmpty)
        let mac = lines(TargetPlatform(os: "macOS"))
        // `DEBUG` is not a platform condition: both branches stay. After `canImport(Glibc)`, which is not known,
        // the `#else` branch is not known either
        #expect(mac.made == [6, 13, 15, 22, 24])
        #expect(mac.inactive == [3, 8, 20])
        let simulator = lines(TargetPlatform(os: "iOS", isSimulator: true))
        #expect(simulator.made == [3, 13, 15, 20])
        #expect(simulator.inactive == [6, 8, 22, 24])
        let tv = lines(TargetPlatform(os: "tvOS", isSimulator: true))
        #expect(tv.made == [8, 13, 15, 20])
    }

    @Test func conditionsAreEvaluatedOnlyWhereThePlatformDecides() {
        func value(_ condition: String, _ platform: TargetPlatform) -> Bool? {
            var options = GeneratorOptions(operators: [.boundary])
            options.targetPlatform = platform
            let source = "func f(_ n: Int) -> Bool {\n#if \(condition)\nreturn n > 1\n#else\nreturn n > 2\n#endif\n}\n"
            let result = MutantGenerator(options: options).generate(source: source, filePath: "P.swift")
            let first = result.mutants.contains { $0.start.line == 3 }
            let second = result.mutants.contains { $0.start.line == 5 }
            return first && second ? nil : first
        }
        let mac = TargetPlatform(os: "macOS")
        let phone = TargetPlatform(os: "iOS", isSimulator: true)
        #expect(value("os(macOS)", mac) == true)
        #expect(value("os(iOS)", mac) == false)
        #expect(value("!os(iOS)", mac) == true)
        #expect(value("os(iOS) || os(macOS)", mac) == true)
        #expect(value("os(iOS) && DEBUG", mac) == false)
        #expect(value("os(macOS) && DEBUG", mac) == nil)
        #expect(value("os(iOS) || DEBUG", mac) == nil)
        #expect(value("(os(iOS) || os(tvOS)) && targetEnvironment(simulator)", phone) == true)
        #expect(value("targetEnvironment(simulator)", TargetPlatform(os: "iOS")) == false)
        #expect(value("canImport(UIKit)", phone) == true)
        #expect(value("canImport(AppKit)", phone) == false)
        #expect(value("canImport(Combine)", phone) == nil)
        #expect(value("arch(arm64)", phone) == nil)
        #expect(value("swift(>=5.9)", phone) == nil)
        #expect(value("os(Plan9)", phone) == nil)
    }

    @Test func thePlatformComesFromTheDestination() {
        #expect(TargetPlatform(destinationPlatform: "macOS") == TargetPlatform(os: "macOS"))
        #expect(TargetPlatform(destinationPlatform: "iOS Simulator") == TargetPlatform(os: "iOS", isSimulator: true))
        #expect(TargetPlatform(destinationPlatform: "macOS", variant: "Mac Catalyst") == TargetPlatform(os: "iOS", isMacCatalyst: true))
        #expect(TargetPlatform(destinationPlatform: "Plan 9") == nil)
    }
}
