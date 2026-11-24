import Testing
@testable import SampleApp

/// 7.4 async / throws / 並行性。
@MainActor
@Suite struct ConcurrencyTests {
    @Test func a1AwaitInCondition() async {
        let repo = Repository()
        await repo.add(1)
        await repo.add(2)
        #expect(await Concurrency.busyCode(repo) == 0)
        await repo.add(3)
        #expect(await Concurrency.busyCode(repo) == 1)
    }

    @Test func a2TryInCondition() throws {
        #expect(try Concurrency.positiveCode("0") == 0)
        #expect(try Concurrency.positiveCode("1") == 1)
        #expect(throws: ParseError.self) { try Concurrency.positiveCode("x") }
    }

    @Test(.timeLimit(.minutes(1)))
    func a3Continuation() async {
        #expect(await Concurrency.delayedValue(0) == -1)
        #expect(await Concurrency.delayedValue(5) == 5)
    }

    @Test func a4Isolation() async {
        let repo = Repository()
        for i in 0..<2 { await repo.add(i) }
        #expect(await !repo.isFull())
        await repo.add(2)
        #expect(await repo.isFull())

        let store = Store()
        #expect(!store.hasItems())
        store.count = 1
        #expect(store.hasItems())

        #expect(Concurrency.isLarge(100))
        #expect(!Concurrency.isLarge(99))
    }

    @Test func a5DefaultMainActorIsolation() {
        #expect(!Concurrency.defaultIsolated(10))
        #expect(Concurrency.defaultIsolated(9))
    }

    @Test func a6TaskClosure() async {
        #expect(await !Concurrency.spawnCheck(5))
        #expect(await Concurrency.spawnCheck(6))
    }

    @Test func a7ImportVariants() {
        #expect(InternalImportCase.isBlank("  "))
        #expect(!InternalImportCase.isBlank(" a "))
        #expect(NoImportCase.isZero(0))
        #expect(!NoImportCase.isZero(1))
        #expect(!SwiftUIOnlyCase.isWide(600))
        #expect(SwiftUIOnlyCase.isWide(601))
    }
}
