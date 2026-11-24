import Testing
@testable import SampleApp

/// 7.3 型・宣言の文脈。
@MainActor
@Suite struct DeclarationTests {
    @Test func d1Generic() {
        #expect(Declarations.countBelow([1, 2, 3], 2) == 1)
        #expect(Declarations.countBelow(["a", "b"], "b") == 1)
    }

    @Test func d2ProtocolExtension() {
        #expect(Exam(score: 60).isPassing)
        #expect(!Exam(score: 59).isPassing)
    }

    @Test func d3WhereClauses() {
        #expect(Box(value: "a") == Box(value: "a"))
        #expect(!Declarations.isSame(1, 2))
        #expect(Declarations.isSame(1, 1))
    }

    @Test func d4OperatorImplementation() {
        #expect(!(Version(major: 1) < Version(major: 1)))
        #expect(Version(major: 1) < Version(major: 2))
    }

    @Test func d5CustomOperator() {
        #expect(Declarations.closeEnough(1, 2))
        #expect(!Declarations.closeEnough(1, 3))
        #expect(Distances.withinOne(1, 2))
        #expect(!Distances.withinOne(1, 3))
    }

    @Test func d6MemberInitializers() {
        #expect(!Declarations.Config().isLarge)
        #expect(Declarations.Config.strict)
    }

    @Test func d7TopLevelLet() {
        #expect(!isVerboseLevel)
    }

    @Test func d8DefaultArguments() {
        #expect(!Declarations.fetch())
        #expect(!Declarations.fetchPublic())
    }

    @Test func d9DeferredLet() {
        #expect(Declarations.pickValue(2, 2) == 2)
        #expect(Declarations.pickValue(3, 2) == 1)
    }

    @Test func d10D11Constants() {
        #expect(Declarations.Level.low.rawValue == 1)
        #expect([0, 1].contains(Declarations.runtimeCheck()))
        #expect(Declarations.buildKind == "debug-ios")
    }

    #if DEBUG
    @Test func d12ActiveIfConfigBranch() {
        #expect(!Declarations.debugOnlyCheck(5))
        #expect(Declarations.debugOnlyCheck(6))
    }
    #endif

    @Test func d14LocalPackage() {
        #expect(Declarations.kitInRange(1))
        #expect(!Declarations.kitInRange(6))
        #expect(!Declarations.kitPositive(0))
        #expect(Declarations.kitPositive(1))
    }

    @Test func d15PropertyWrapper() {
        #expect(Clamped(wrappedValue: 10, max: 10).projectedValue == 0)
        let clamped = Clamped(wrappedValue: 15, max: 10)
        #expect(clamped.wrappedValue == 10)
        #expect(clamped.projectedValue == 1)
        #expect(Volume().level == 5)
    }
}
