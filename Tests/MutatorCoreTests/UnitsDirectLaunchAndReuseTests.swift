import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

@Suite("Units, processes started by the tool, pausing")
struct UnitsAndDirectLaunchTests {
    // MARK: Units

    static func target(_ name: String, configuration: String?) -> SharedProcess.Target {
        SharedProcess.Target(blueprintName: name, moduleName: name, bundlePath: "/p/\(name).xctest", only: [], skip: [], configurationName: configuration)
    }

    static func setup(_ targets: [SharedProcess.Target], expectedTests: Int) -> SharedProcess.Setup {
        let driver = SharedProcess.Driver(bundle: URL(fileURLWithPath: "/w/Driver.xctest"), library: URL(fileURLWithPath: "/w/libDriver.dylib"), isMacOS: false)
        return SharedProcess.Setup(units: targets.map { SharedProcess.Unit(target: $0, driver: driver) }, originalXctestrun: URL(fileURLWithPath: "/p/a.xctestrun"),
                                   switchCount: 4, expectedTests: expectedTests, launchTimeout: 60, timeoutFactor: 3, timeoutConstant: 30,
                                   placeholders: .init(developerDirectory: "/X/Developer", productsDirectory: "/p", derivedData: "/d"))
    }

    @Test func theTargetsOfEachConfigurationMustAddUpToTheBaseline() {
        // Two configurations, two targets: the result bundle counts each test once, so each configuration has 7
        let setup = Self.setup([Self.target("A", configuration: "ja"), Self.target("B", configuration: "ja"),
                                Self.target("A", configuration: "en"), Self.target("B", configuration: "en")], expectedTests: 7)
        #expect(setup.configurations == [[0, 1], [2, 3]])
        // Nothing can be said while a configuration is incomplete
        #expect(setup.countsAgree([0: 4]))
        #expect(setup.countsAgree([0: 4, 1: 3]))
        #expect(!setup.countsAgree([0: 4, 1: 2]))
        #expect(setup.countsAgree([0: 4, 1: 3, 2: 4]))
        #expect(!setup.countsAgree([0: 4, 1: 3, 2: 4, 3: 4]))
        // No configurations (format version 1): all targets together
        let plain = Self.setup([Self.target("A", configuration: nil), Self.target("B", configuration: nil)], expectedTests: 7)
        #expect(plain.configurations == [[0, 1]])
        #expect(plain.countsAgree([0: 5, 1: 2]))
        #expect(!plain.countsAgree([0: 5, 1: 3]))
    }

    @Test func severalTargetsInSeveralConfigurationsAreUnitsInTheOrderOfTheFile() throws {
        func unit(_ name: String, _ language: String) -> [String: Any] {
            ["BlueprintName": name, "ProductModuleName": name, "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/App.app",
             "TestHostBundleIdentifier": "dev.example.App", "IsAppHostedTestBundle": true,
             "TestBundlePath": "__TESTHOST__/PlugIns/\(name).xctest", "CommandLineArguments": ["-AppleLanguages", "(\(language))"],
             "EnvironmentVariables": ["TERM": "dumb", "DYLD_INSERT_LIBRARIES": "/usr/lib/libRPAC.dylib"],
             "TestingEnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/usr/lib/libRPAC.dylib",
                                             "DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks"]]
        }
        let plist: [String: Any] = ["TestConfigurations": [["Name": "Japanese", "TestTargets": [unit("ATests", "ja"), unit("BTests", "ja")]],
                                                           ["Name": "English", "TestTargets": [unit("ATests", "en"), unit("BTests", "en")]]]]
        let options = XcodeOptions(container: [], scheme: "App", destination: "id=X", testPlan: nil, extraBuildArguments: [], extraTestArguments: [],
                                   onlyTesting: [], skipTesting: [], buildSettings: [])
        let units = try SharedProcess.units(plist: plist, productsDirectory: "/p", options: options).get()
        #expect(units.map(\.label) == ["Japanese / ATests", "Japanese / BTests", "English / ATests", "English / BTests"])
        #expect(units[2].commandLineArguments == ["-AppleLanguages", "(en)"])
        // The testing environment wins over the plain one
        #expect(units[0].environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTestBundleInject") == true)
        // The copy of the .xctestrun file for one unit keeps that configuration and that target only
        let session = SharedProcess.sessionPlist(plist, productsDirectory: "/p", target: units[3], driverBundle: "/w/Driver.xctest", environment: [:])
        let configurations = try #require(session["TestConfigurations"] as? [[String: Any]])
        #expect(configurations.map { $0["Name"] as? String } == ["English"])
        #expect((configurations[0]["TestTargets"] as? [[String: Any]])?.map { $0["BlueprintName"] as? String } == ["BTests"])
    }

    // MARK: Starting the host without xcodebuild

    static let placeholders = SharedProcess.Placeholders(developerDirectory: "/X/Contents/Developer", productsDirectory: "/p", derivedData: "/d")
    static let simulatorDriver = SharedProcess.Driver(bundle: URL(fileURLWithPath: "/w/Driver.xctest"), library: URL(fileURLWithPath: "/w/libDriver.dylib"), isMacOS: false)
    static let macDriver = SharedProcess.Driver(bundle: URL(fileURLWithPath: "/w/Driver.xctest"), library: URL(fileURLWithPath: "/w/libDriver.dylib"), isMacOS: true)

    @Test func placeholdersOfTheXctestrunFileAreWrittenOut() {
        let p = Self.placeholders
        #expect(p.expand("__TESTROOT__/Debug:__PLATFORMS__/MacOSX.platform/Developer/usr/lib", host: "") == "/p/Debug:/X/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib")
        #expect(p.expand("__SHAREDFRAMEWORKS__", host: "") == "/X/Contents/SharedFrameworks")
        #expect(p.expand("__DEVELOPERUSRLIB__/libMainThreadChecker.dylib", host: "") == "/X/Contents/Developer/usr/lib/libMainThreadChecker.dylib")
        #expect(p.expand("__TESTHOST__/Frameworks:__DERIVEDDATA__/x", host: "/p/App.app") == "/p/App.app/Frameworks:/d/x")
        #expect(!SharedProcess.Placeholders.hasUnknown("/p/__pycache__/x"))
        #expect(SharedProcess.Placeholders.hasUnknown("__SOMETHINGNEW__/x"))
    }

    @Test func anAppOnASimulatorIsLaunchedWithTheDriverLibraryInserted() throws {
        var unit = Self.target("AppTests", configuration: "Japanese")
        unit.hostPath = "/p/Debug-iphonesimulator/App.app"
        unit.hostBundleIdentifier = "dev.example.App"
        unit.isAppHosted = true
        unit.commandLineArguments = ["-AppleLanguages", "(ja)"]
        unit.environment = ["DYLD_INSERT_LIBRARIES": "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/sim/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib",
                            "DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks",
                            "XCInjectBundleInto": "unused"]
        let launch = try SharedProcess.directLaunch(unit: unit, driver: Self.simulatorDriver, simulatorUDID: "UDID", placeholders: Self.placeholders,
                                                    session: ["XCMUTATE_SESSION": "/s/1", "XCMUTATE_ACTIVE": "7"]).get()
        #expect(launch.arguments == ["/usr/bin/xcrun", "simctl", "launch", "--console", "--terminate-running-process", "UDID", "dev.example.App", "-AppleLanguages", "(ja)"])
        // The driver library takes the place of XCTest's injection library; the other inserted libraries stay
        #expect(launch.environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] == "/w/libDriver.dylib:/sim/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib")
        #expect(launch.environment["SIMCTL_CHILD_DYLD_FRAMEWORK_PATH"] == "/p/Debug-iphonesimulator:/X/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks")
        #expect(launch.environment["SIMCTL_CHILD_XCMUTATE_ACTIVE"] == "7")
        #expect(launch.environment["SIMCTL_CHILD_XCTestBundlePath"] == "/p/AppTests.xctest")
        #expect(launch.environment["SIMCTL_CHILD_XCTestConfigurationFilePath"] == "/s/1/none.xctestconfiguration")
        // Coverage data of the products must not land in the directory the tool was started in
        #expect(launch.environment["SIMCTL_CHILD_LLVM_PROFILE_FILE"] == "/s/1/host.profraw")
        #expect(launch.environment.keys.allSatisfy { $0.hasPrefix("SIMCTL_CHILD_") })
        #expect(launch.simulatorApp?.bundleIdentifier == "dev.example.App")
        // Without a simulator id, or with a placeholder that is not known, the tool does not start anything itself
        #expect((try? SharedProcess.directLaunch(unit: unit, driver: Self.simulatorDriver, simulatorUDID: nil, placeholders: Self.placeholders, session: [:]).get()) == nil)
        unit.environment["OTHER"] = "__NEWPLACEHOLDER__/x"
        #expect((try? SharedProcess.directLaunch(unit: unit, driver: Self.simulatorDriver, simulatorUDID: "UDID", placeholders: Self.placeholders, session: [:]).get()) == nil)
    }

    @Test func aBundleWithoutAHostAppRunsInTheXctestAgent() throws {
        var unit = Self.target("LogicTests", configuration: nil)
        unit.hostPath = "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
        unit.environment = ["DYLD_INSERT_LIBRARIES": "__DEVELOPERUSRLIB__/libMainThreadChecker.dylib", "DYLD_LIBRARY_PATH": "__TESTROOT__/Debug"]
        let mac = try SharedProcess.directLaunch(unit: unit, driver: Self.macDriver, simulatorUDID: nil, placeholders: Self.placeholders,
                                                 session: ["XCMUTATE_SESSION": "/s/1"]).get()
        #expect(mac.arguments == ["/X/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest", "-XCTest",
                                  "XCMutateSharedProcess/testRunMutants", "/w/Driver.xctest"])
        // Nothing of the driver is inserted: the agent loads the bundle
        #expect(mac.environment["DYLD_INSERT_LIBRARIES"] == "/X/Contents/Developer/usr/lib/libMainThreadChecker.dylib")
        #expect(mac.environment["DYLD_LIBRARY_PATH"] == "/p/Debug")
        #expect(mac.environment["XCTestConfigurationFilePath"] == nil)
        #expect(mac.simulatorApp == nil)

        unit.hostPath = "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
        let simulator = try SharedProcess.directLaunch(unit: unit, driver: Self.simulatorDriver, simulatorUDID: "UDID", placeholders: Self.placeholders, session: [:]).get()
        #expect(Array(simulator.arguments.prefix(5)) == ["/usr/bin/xcrun", "simctl", "spawn", "UDID",
                                                         "/X/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"])
        #expect(simulator.environment["SIMCTL_CHILD_DYLD_LIBRARY_PATH"] == "/p/Debug")
    }

    @Test func theDriverReportsASingleRun() {
        let passed = SharedProcessTests.events("HELLO 77 1\nSINGLE pass 94 0.21\nDONE\n")
        #expect(passed.processID == 77)
        #expect(passed.single == SharedProcess.Events.End(status: "pass", activations: 0, tests: 94, seconds: 0.21, failed: []))
        #expect(passed.done)
        let failed = SharedProcessTests.events("HELLO 77 1\nSINGLE fail 94 0.21\tA/b()\tC/d()\n")
        #expect(failed.single?.status == "fail")
        #expect(failed.single?.failed == ["A/b()", "C/d()"])
        // A process that ended before the run was reported has no result
        #expect(SharedProcessTests.events("HELLO 77 1\n").single == nil)
    }

    @Test func theDriverSourceHasBothEntryPoints() {
        let source = SharedProcessDriverSource.source
        #expect(source.contains("@_cdecl(\"\(SharedProcessDriverSource.directEntryPoint)\")"))
        #expect(source.contains("func \(SharedProcessDriverSource.testName)()"))
        #expect(source.contains("plan.mode == \"single\""))
    }

    // MARK: Pausing shared processes

    @Test func sharedProcessesPauseWhenLossesOutnumberGains() {
        func unfavourable(_ text: String) -> Bool { MutantExecutor.sharingUnfavourable(text.map { $0 == "k" }) }
        // k: a mutant killed in a shared process (a launch saved); x: a process lost to a crash or a hang
        #expect(!unfavourable(""))
        #expect(!unfavourable("xx"))
        #expect(unfavourable("xxx"))
        #expect(!unfavourable("kkkxxx"))
        #expect(unfavourable("kkxxx"))
        #expect(!unfavourable("xxxkkkk"))
    }

    @Test func aConfirmationStartedByTheToolIsJudgedLikeARunAlone() {
        let baseline = BaselineEvidence(testCount: 94, passedTests: 94, skippedTests: 0)
        let summary = TestSummary(result: "Passed", totalTestCount: 94, passedTests: 94, failedTests: 0, skippedTests: 0, expectedFailures: 0, failures: [])
        var observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: 0, timedOut: false, summary: summary, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 3, timeoutSeconds: 30)
        observation.sharedProcess = false
        observation.directLaunch = true
        #expect(Judgement.classify(observation, baseline: baseline).status == .survived)
        // Without the record of the switch being active it is not a survivor
        observation.activated = false
        #expect(Judgement.classify(observation, baseline: baseline).status == .notActivated)
        // Old journals have no such field
        let old = #"{"key":"k","id":1,"attempt":1,"exitStatus":0,"timedOut":false,"activated":true,"durationSeconds":1,"timeoutSeconds":30}"#
        #expect((try? JSONDecoder().decode(MutantObservation.self, from: Data(old.utf8)))?.directLaunch == nil)
    }
}

@Suite("Operators: return-case, implicit-return-value, closure-statement-removal")
struct ReturnAndClosureOperatorTests {
    func mutants(_ source: String, _ op: MutationOperator) -> [Mutant] {
        generate(source, options: returnAndClosureOptions).mutants.filter { $0.operator == op }
    }

    // MARK: return-case

    @Test func aCaseWithArgumentsBecomesAnotherValueTheFunctionReturns() {
        let source = """
        func classify(_ x: Int?, _ limit: Int) -> Outcome {
            guard let x else { return .none }
            if x < 0 { return .failure(.invalid) }
            if x > limit { return .value(limit) }
            return .value(x)
        }
        """
        let found = mutants(source, .returnCase).map { "\($0.original) -> \($0.replacement)" }
        // `.value(limit)` and `.value(x)` need a local name, so they are never used as replacements;
        // at most two replacements per return, in order of appearance
        #expect(found == [".failure(.invalid) -> .none",
                          ".value(limit) -> .none", ".value(limit) -> .failure(.invalid)",
                          ".value(x) -> .none", ".value(x) -> .failure(.invalid)"])
    }

    @Test func noReplacementWhenNothingElseIsReturnedOrTheContextIsUnknown() {
        // Only one value is returned
        #expect(mutants("func f(_ e: E) -> R { return .failure(e) }", .returnCase).isEmpty)
        // The other returns need local names
        #expect(mutants("func f(_ a: Int, _ e: E) -> R { if a > 0 { return .ok(a) }; return .failure(e) }", .returnCase).isEmpty)
        // A closure has no declared set of returned values; `.init(…)` is not a case
        #expect(mutants("let f = { (e: E) -> R in if e.bad { return .none }; return .failure(e) }", .returnCase).isEmpty)
        #expect(mutants("func f(_ a: Int) -> R { if a > 0 { return .none }; return .init(a) }", .returnCase).isEmpty)
        // Returns of a nested function belong to that function
        let nested = """
        func outer(_ e: E) -> R {
            func inner() -> Other { return .none }
            _ = inner()
            return .failure(e)
        }
        """
        #expect(mutants(nested, .returnCase).isEmpty)
        // `try` and `await` stay outside the replaced range
        let throwing = mutants("func f(_ a: Int) throws -> R { if a > 0 { return .none }; return try .make(a) }", .returnCase)
        #expect(throwing.map(\.originalExpression) == [".make(a)"])
        #expect(throwing.map(\.replacement) == [".none"])
    }

    // MARK: implicit-return-value

    @Test func theSingleExpressionOfABodyBecomesAValueOfTheDeclaredType() {
        let source = """
        struct S {
            var items: [Int]
            var table: [Int: String]
            var total: Int { items.reduce(0, +) }
            var first: Int? { items.first }
            func names() -> [String] { items.map { String($0) } }
            subscript(index: Int) -> String? { table[index] }
            var doubled: Int {
                get { items.count * 2 }
                set { items = Array(repeating: 0, count: newValue) }
            }
            func lookup() async throws -> String { try await fetch() }
            let pick = { (x: Int) -> Int? in x > 0 ? x : nil }
        }
        """
        let found = mutants(source, .implicitReturnValue).map { "\($0.originalExpression) -> \($0.replacement)" }
        #expect(found == ["items.reduce(0, +) -> 0", "items.first -> nil", "items.map { String($0) } -> []", "table[index] -> nil",
                          "items.count * 2 -> 0", "fetch() -> \"\"", "x > 0 ? x : nil -> nil"])
    }

    @Test func constantsUnknownTypesBoolAndBuildersAreLeftAlone() {
        let source = """
        struct S {
            var title: String { "Settings" }
            var count: Int { 3 }
            var sizes: [Int] { [1, 2, 3] }
            var negative: Int { -1 }
            var isEmpty: Bool { items.isEmpty }
            var model: Model { makeModel() }
            var body: some View { Text(title) }
            @ViewBuilder func row() -> some View { Text(title) }
            func nothing() { work() }
            func two() -> Int { let a = 1; return a }
            var kind: String { if flag { "a" } else { "b" } }
            var same: [Int] { [] }
            let untyped = { x in x + 1 }
        }
        """
        #expect(mutants(source, .implicitReturnValue).isEmpty)
    }

    // MARK: closure-statement-removal

    @Test func callStatementsInClosuresThatAreNotResultBuilders() {
        let source = """
        func run(_ items: [Int], _ queue: DispatchQueue) {
            var result: [Int] = []
            items.forEach { result.append($0) }
            let parser: (Int) -> Int? = { value in
                var sum = 0
                while sum < value {
                    sum += 1
                    result.append(sum)
                }
                if sum == 0 { return nil }
                return sum
            }
            queue.async {
                notify()
            }
            Task {
                await load()
                refresh()
            }
            _ = parser(1)
        }
        """
        let found = mutants(source, .closureStatementRemoval).map(\.original)
        #expect(found == ["result.append($0)", "result.append(sum)", "notify()", "await load()", "refresh()"])
        #expect(mutants(source, .closureStatementRemoval).allSatisfy { $0.isStatement })
    }

    @Test func closuresThatCouldBeResultBuildersOrReturnTheCallAreLeftAlone() {
        let source = """
        func run(_ items: [Int]) {
            // Could be a result builder: nothing in the syntax says otherwise
            VStack {
                header()
                footer()
            }
            configure {
                first()
                second()
            }
            // One statement: it may be the value of the closure
            let mapped = items.map { transform($0) }
            Task { await load() }
            queue.sync { compute() }
            // A nested closure decides for itself
            items.forEach { item in
                Section {
                    row(item)
                    divider()
                }
            }
            // Statements that are never removed stay as they are
            items.forEach { _ in
                print("x")
                lock.unlock()
                fatalError("no")
            }
            _ = mapped
        }
        """
        let result = generate(source, options: returnAndClosureOptions)
        // `Section { … }` is itself a call statement of the `forEach` closure; what is inside it is not touched
        #expect(result.mutants.filter { $0.operator == .closureStatementRemoval }.map { String($0.original.prefix(9)) } == ["Section {"])
        // The last three are candidates with a reason; the rest are not candidates at all
        #expect(result.ignored.filter { $0.operator == .closureStatementRemoval }.map(\.reason) == [.aridCall, .synchronization, .neverReturning])
    }

    @Test func aStatementInAFunctionInsideAClosureBelongsToTheFunction() {
        let source = """
        let handler = { (x: Int) -> Int in
            func helper() { record(x) }
            helper()
            return x
        }
        """
        let all = generate(source, options: GeneratorOptions(operators: [.sideEffectRemoval, .closureStatementRemoval])).mutants
        #expect(all.map { "\($0.operator.rawValue) \($0.original)" } == ["side-effect-removal record(x)", "closure-statement-removal helper()"])
    }

    @Test func theDefaultSetFollowsTheMeasurements() {
        let defaults = GeneratorOptions().operators
        // Off: do not compile too often, or are too often equivalent, or have too little evidence yet
        for op in [MutationOperator.arithmetic, .compoundAssignment, .nilCoalescingDefault, .tryOptionalNil, .conditionRemoval,
                   .returnCase, .implicitReturnValue, .closureStatementRemoval] {
            #expect(!defaults.contains(op), "\(op.rawValue)")
        }
        #expect(defaults.count == MutationOperator.allCases.count - 8)
        #expect(defaults.contains(.guardRemoval))
        #expect(defaults.contains(.switchCaseRemoval))
        #expect(defaults.contains(.boundary))
    }

    @Test func theNewOperatorsHaveNamesAndAreInstrumentedLikeTheOthers() throws {
        #expect(MutationOperator.returnCase.rawValue == "return-case")
        #expect(MutationOperator.implicitReturnValue.rawValue == "implicit-return-value")
        #expect(MutationOperator.closureStatementRemoval.rawValue == "closure-statement-removal")
        let source = """
        func f(_ xs: [Int]) -> Int? {
            var seen: [Int] = []
            xs.forEach { seen.append($0) }
            return seen.first
        }
        var count: Int { values.count }
        """
        let result = process(options: returnAndClosureOptions, source)
        expectValidInstrumentation(result)
        let closure = try #require(result.mutants.first { $0.operator == .closureStatementRemoval })
        #expect(result.instrumented.contains("xs.forEach { if !\(Instrumenter.switchCall(closure.id)) { seen.append($0) } }"))
        let implicit = try #require(result.mutants.first { $0.operator == .implicitReturnValue })
        #expect(result.instrumented.contains("var count: Int { (\(Instrumenter.switchCall(implicit.id)) ? (0) : (values.count)) }"))
    }
}

@Suite("Reuse of results")
struct ReuseTests {
    static let product = "struct Cart { func total(_ a: Int, _ b: Int) -> Int { a + b } }\n"
    static let cartTests = """
    import XCTest
    @testable import App
    final class CartTests: BaseCase {
        func testTotal() { XCTAssertEqual(Cart().total(1, 2), 3) }
    }
    """
    static let baseCase = "import XCTest\nclass BaseCase: XCTestCase { func testNothing() {} }\n"
    static let priceTests = """
    import Testing
    @testable import App
    @Suite struct PriceTests {
        @Test func rounding() { #expect(true) }
    }
    extension PriceTests {
        @Test func more() { #expect(true) }
    }
    """
    static let helper = "import XCTest\nfunc makeCart() -> Cart { Cart() }\n"

    static func files(_ changes: [String: String?] = [:]) -> [String: String] {
        var files: [String: String] = [
            "App/Cart.swift": product, "AppTests/CartTests.swift": cartTests, "AppTests/BaseCase.swift": baseCase,
            "AppTests/PriceTests.swift": priceTests, "AppTests/Helpers.swift": helper, "AppTests/Fixtures/data.json": "{}",
            "README.md": "x",
        ]
        for (path, text) in changes { files[path] = text }
        return files
    }

    static func state(_ files: [String: String]) -> ReuseState {
        ReuseState.scan(paths: Array(files.keys)) { files[$0].map { Data($0.utf8) } }
    }

    @Test func whatAFileDeclares() {
        let cart = TestDeclarations.scan(source: Self.cartTests)
        #expect(cart.types == ["CartTests": ["BaseCase"]])
        #expect(cart.declaresTests)
        let price = TestDeclarations.scan(source: Self.priceTests)
        #expect(price.types.keys.sorted() == ["PriceTests"])
        #expect(price.declaresTests)
        #expect(!TestDeclarations.scan(source: Self.helper).declaresTests)
        let global = TestDeclarations.scan(source: "import Testing\n@Test func standsAlone() {}\nstruct Outer { struct Inner { @Test func nested() {} } }\n")
        #expect(global.topLevelTests == ["standsAlone"])
        #expect(global.types.keys.sorted() == ["Inner", "Outer"])
    }

    @Test func aDeclarationIsComparedByItsTokens() {
        let a = "func f(_ a: Int) -> Int {\n    // comment\n    return a + 1\n}\nfunc g() {}\n"
        let b = "func f(_ a: Int) -> Int {\n\n        return a   +   1 // other comment\n}\nfunc g() { changed() }\n"
        let c = "func f(_ a: Int) -> Int {\n    return a + 2\n}\n"
        #expect(TestDeclarations.tokenText(source: a, lines: LineSpan(start: 1, end: 4)) == "func f ( _ a : Int ) -> Int { return a + 1 }")
        // Comments, blank lines and spacing do not count; the line span differs with them, the tokens do not
        #expect(TestDeclarations.tokenText(source: a, lines: LineSpan(start: 1, end: 4)) == TestDeclarations.tokenText(source: b, lines: LineSpan(start: 1, end: 4)))
        #expect(TestDeclarations.tokenText(source: a, lines: LineSpan(start: 1, end: 4)) != TestDeclarations.tokenText(source: c, lines: LineSpan(start: 1, end: 3)))
    }

    @Test func testsAreTracedToTheFilesOfTheirTypeAndItsSuperclasses() {
        let state = Self.state(Self.files())
        // The subclass and the file of its superclass
        #expect(state.files(ofTest: "CartTests/testTotal()")?.keys.sorted() == ["AppTests/BaseCase.swift", "AppTests/CartTests.swift"])
        #expect(state.files(ofTest: "PriceTests/rounding()")?.keys.sorted() == ["AppTests/PriceTests.swift"])
        // A type that no test-side file declares, or no type at all: not traceable, so never a reason to reuse
        #expect(state.files(ofTest: "GhostTests/testX()") == nil)
        #expect(state.files(ofTest: "") == nil)
        #expect(state.files(ofTest: "unknownFunction()") == nil)
        // Product files, helpers and resources are not test files
        #expect(state.testFiles.keys.sorted() == ["AppTests/BaseCase.swift", "AppTests/CartTests.swift", "AppTests/PriceTests.swift"])
    }

    @Test func productAndSupportStatesSeeEveryChangeOutsideTheTests() {
        let base = Self.state(Self.files())
        // Editing or adding a file that declares tests changes neither state
        let testsOnly = Self.state(Self.files(["AppTests/PriceTests.swift": Self.priceTests + "\n// more", "AppTests/NewTests.swift": "import XCTest\nfinal class NewTests: XCTestCase { func testA() {} }\n"]))
        #expect(testsOnly.productState == base.productState)
        #expect(testsOnly.supportState == base.supportState)
        // Product code, a README, a project file: the product state
        #expect(Self.state(Self.files(["App/Cart.swift": Self.product + " "])).productState != base.productState)
        #expect(Self.state(Self.files(["README.md": "y"])).productState != base.productState)
        #expect(Self.state(Self.files(["App/New.swift": "let x = 1"])).productState != base.productState)
        // A helper or a resource of the tests: the support state
        #expect(Self.state(Self.files(["AppTests/Helpers.swift": Self.helper + " "])).supportState != base.supportState)
        #expect(Self.state(Self.files(["AppTests/Fixtures/data.json": "[]"])).supportState != base.supportState)
        #expect(Self.state(Self.files(["AppTests/Helpers.swift": Self.helper + " "])).productState == base.productState)
    }

    static func killed(_ key: String, by tests: [String]) -> MutantResult {
        let mutant = Mutant(id: 0, key: key, operator: .arithmetic, file: "App/Cart.swift", enclosingDecl: "Cart.total", region: ByteRange(start: 0, end: 1),
                            point: ByteRange(start: 0, end: 1), start: SourcePosition(line: 1, column: 1), end: SourcePosition(line: 1, column: 2),
                            original: "+", replacement: "-", originalExpression: "a + b", mutatedExpression: "a - b",
                            regionLines: LineSpan(start: 1, end: 1), scope: MutantScope(id: "Cart.total", lines: LineSpan(start: 1, end: 1)), guardOffsets: nil)
        return MutantResult(mutant: mutant, status: .killed, killedBy: tests, durationSeconds: 1, attempts: 1, detail: nil)
    }

    @Test func aKilledMutantIsReusedOnlyWhileNothingItRestsOnChanged() {
        let state = Self.state(Self.files())
        let declarations = ["k1": "d1", "k2": "d2", "k3": "d3"]
        var survived = Self.killed("k3", by: [])
        survived.status = .survived
        let store = Reuse.updated(nil, environment: "env", state: state,
                                  results: [Self.killed("k1", by: ["CartTests/testTotal()"]), Self.killed("k2", by: ["PriceTests/rounding()", "GhostTests/testX()"]), survived],
                                  declarations: declarations, commit: "abc")
        // Killed with at least one traceable test is stored; Survived is not
        #expect(store.entries.keys.sorted() == ["k1", "k2"])
        #expect(store.entries["k2"]?.killers.map(\.test) == ["PriceTests/rounding()"])
        let all: Set<String> = ["CartTests/testTotal()", "PriceTests/rounding()", "PriceTests/more()"]

        func decide(_ files: [String: String], environment: String = "env", declarations: [String: String] = declarations, tests: Set<String>? = all) -> Reuse.Decision {
            Reuse.decide(store: store, environment: environment, state: Self.state(files), declarations: declarations, baselineTests: tests)
        }
        // Nothing changed
        #expect(decide(Self.files()).reusable == ["k1": ["CartTests/testTotal()"], "k2": ["PriceTests/rounding()"]])
        // A test file changed: the mutants killed by its tests are run again, the others are not
        #expect(decide(Self.files(["AppTests/PriceTests.swift": Self.priceTests + "\n"])).reusable.keys.sorted() == ["k1"])
        // The superclass of the killing test changed
        #expect(decide(Self.files(["AppTests/BaseCase.swift": Self.baseCase + "\n"])).reusable.keys.sorted() == ["k2"])
        // A new test file: nothing that was stored depends on it
        #expect(decide(Self.files(["AppTests/NewTests.swift": "import XCTest\nfinal class NewTests: XCTestCase { func testA() {} }\n"])).reusable.count == 2)
        // The killing test no longer runs (deselected, renamed): not reused
        #expect(decide(Self.files(), tests: ["PriceTests/rounding()"]).reusable.keys.sorted() == ["k2"])
        // The declaration around the mutant differs
        #expect(decide(Self.files(), declarations: ["k1": "other", "k2": "d2"]).reusable.keys.sorted() == ["k2"])
        // Whole-store refusals: product code, test helpers, options, an unknown test list, no store
        #expect(decide(Self.files(["App/Cart.swift": Self.product + "// x"])).refusal?.contains("outside the tests") == true)
        #expect(decide(Self.files(["AppTests/Helpers.swift": "import XCTest\n"])).refusal?.contains("declare no tests") == true)
        #expect(decide(Self.files(), environment: "other").refusal != nil)
        #expect(decide(Self.files(), tests: nil).refusal != nil)
        #expect(Reuse.decide(store: nil, environment: "env", state: state, declarations: declarations, baselineTests: all).refusal != nil)
        #expect(decide(Self.files(["App/Cart.swift": Self.product + "// x"])).reusable.isEmpty)
    }

    @Test func theStoreFollowsTheLatestRun() {
        let state = Self.state(Self.files())
        let declarations = ["k1": "d1", "k2": "d2"]
        let first = Reuse.updated(nil, environment: "env", state: state,
                                  results: [Self.killed("k1", by: ["CartTests/testTotal()"]), Self.killed("k2", by: ["PriceTests/rounding()"])],
                                  declarations: declarations, commit: nil)
        // A later run with other mutants keeps the earlier entries; a mutant that was run again and survived loses its entry
        var nowSurvived = Self.killed("k1", by: [])
        nowSurvived.status = .survived
        var reused = Self.killed("k2", by: ["PriceTests/rounding()"])
        reused.reused = true
        let second = Reuse.updated(first, environment: "env", state: state, results: [nowSurvived, reused, Self.killed("k9", by: ["PriceTests/more()"])],
                                   declarations: ["k1": "d1", "k2": "d2", "k9": "d9"], commit: nil)
        #expect(second.entries.keys.sorted() == ["k2", "k9"])
        #expect(second.entries["k2"] == first.entries["k2"])
        // After a change of product code the earlier entries are gone
        let changed = Self.state(Self.files(["App/Cart.swift": Self.product + "// x"]))
        let third = Reuse.updated(second, environment: "env", state: changed, results: [Self.killed("k9", by: ["PriceTests/more()"])], declarations: ["k9": "d9"], commit: nil)
        #expect(third.entries.keys.sorted() == ["k9"])
        #expect(third.productState == changed.productState)
    }

    @Test func theTestsOfABaselineAreListedByIdentifier() {
        let json: [String: Any] = ["testNodes": [["nodeType": "Test Plan", "children": [["nodeType": "Unit test bundle", "name": "AppTests", "children": [
            ["nodeType": "Test Suite", "name": "CartTests", "children": [["nodeType": "Test Case", "nodeIdentifier": "CartTests/testTotal()"]]],
            ["nodeType": "Test Suite", "name": "価格", "children": [["nodeType": "Test Case", "nodeIdentifier": "PriceTests/rounding()", "children": [["nodeType": "Arguments"]]]]],
        ]]]]]]
        #expect(TestCaseList.parse(json) == ["CartTests/testTotal()", "PriceTests/rounding()"])
    }
}
