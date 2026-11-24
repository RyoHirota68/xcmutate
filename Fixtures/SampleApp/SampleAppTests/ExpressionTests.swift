import Testing
@testable import SampleApp

/// 7.2 式の形。Swift Testing で検出する。
@MainActor
@Suite struct ExpressionTests {
    @Test func t1ImplicitReturns() {
        #expect(Expressions.isAdult(18))
        #expect(!Expressions.isAdult(17))
        #expect(Expressions.Stack(count: 0).isEmpty)
        #expect(!Expressions.Stack(count: 1).isEmpty)
        #expect(Expressions.isEven(2))
        #expect(!Expressions.isEven(3))
    }

    @Test func t2ImplicitReturnCall() {
        #expect(Expressions.total() == 42)
    }

    @Test func t3Ternaries() {
        #expect(Expressions.pick(true, true, 0, 0))
        #expect(!Expressions.pick(false, false, 2, 2))
        #expect(Expressions.nested(true, true) == 1)
        #expect(Expressions.nested(true, false) == 2)
        #expect(Expressions.nested(false, true) == 3)
    }

    @Test func t4MultibyteTextBeforeComparison() {
        #expect(Expressions.label(2, 2) == "件数👨‍👩‍👧:少ない")
        #expect(Expressions.label(3, 2) == "件数👨‍👩‍👧:多い")
    }

    /// 1回目の `a > b` は結果に影響しない（Survived）。2回目だけが検出される。
    @Test func t5SameExpressionTwice() {
        #expect(Expressions.twice(2, 2) == 0)
        #expect(Expressions.twice(3, 2) == 1)
    }

    @Test func t6SameStatementTwice() {
        #expect(Expressions.appendTwice() == ["x", "x"])
    }

    @Test func t7TightSpacingAndSemicolons() {
        #expect(Expressions.tight(2, 1) == 1)
        #expect(Expressions.tight(1, 2) == -1)
        #expect(Expressions.tight(2, 2) == 0)
    }

    @Test func t8LongExpression() {
        #expect(Expressions.longCondition(1, 1, 0, 1, 1, 6))
        #expect(!Expressions.longCondition(1, 1, 0, 2, 1, 6))
        #expect(!Expressions.longCondition(1, 1, 0, 1, 2, 6))
    }

    @Test func t9Optionals() {
        #expect(Expressions.canVote(Expressions.User(age: 18)))
        #expect(!Expressions.canVote(Expressions.User(age: 17)))
        #expect(!Expressions.canVote(nil))
        #expect(Expressions.positiveFlag(0) == 0)
        #expect(Expressions.positiveFlag(1) == 1)
    }

    @Test func t10Interpolation() {
        #expect(Expressions.describe(0) == "hasItems=false")
        #expect(Expressions.describe(1) == "hasItems=true")
    }

    @Test func t11SubscriptAndInout() {
        #expect(Expressions.mark([0, 0, 0], at: 0) == [0, 0, 1])
        #expect(Expressions.mark([0, 0, 0], at: 1) == [0, 1, 0])
        #expect(Expressions.swapped(1, 2) == (2, 1))
    }
}
