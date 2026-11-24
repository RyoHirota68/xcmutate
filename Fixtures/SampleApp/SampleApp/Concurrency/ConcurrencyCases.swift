import Foundation

// 7.4 async / throws / 並行性。ターゲット全体が既定のアクター分離 MainActor（A5）。

actor Repository {
    private var items: [Int] = []
    func add(_ x: Int) { items.append(x) }  // @case SE-repository-add
    func count() -> Int { items.count }  // @case IR-repository-count
    // A4: actor のメソッド
    func isFull() -> Bool { items.count >= 3 }  // @case A4-actor
}

// A4: @MainActor のクラスのメソッド
@MainActor final class Store {
    var count = 0
    func hasItems() -> Bool { count > 0 }  // @case A4-mainactor
}

nonisolated enum ParseError: Error { case invalid }

enum Concurrency {
    // A1: async 関数の中の `await` を含む比較
    static func busyCode(_ repo: Repository) async -> Int {
        if await repo.count() > 2 { return 1 }  // @case A1
        return 0
    }

    // A2: throws 関数の中の `try` を含む比較
    static func parse(_ s: String) throws -> Int {
        guard let v = Int(s) else { throw ParseError.invalid }
        return v  // @case RV-parse
    }

    static func positiveCode(_ s: String) throws -> Int {
        if try parse(s) > 0 { return 1 }  // @case A2
        return 0
    }

    // A3: withCheckedContinuation の中（resume を削除すると、テストのタイムアウトで止まること）
    static func delayedValue(_ v: Int) async -> Int {
        await withCheckedContinuation { continuation in  // @case SE-continuation
            continuation.resume(returning: v > 0 ? v : -1)  // @case A3
        }
    }

    // A4: nonisolated 関数
    nonisolated static func isLarge(_ x: Int) -> Bool { x >= 100 }  // @case A4-nonisolated

    // A5: 既定のアクター分離（MainActor）の関数
    static func defaultIsolated(_ x: Int) -> Bool { x < 10 }  // @case A5

    // A6: Task のクロージャ本体
    static func spawnCheck(_ x: Int) async -> Bool {
        let task = Task { x > 5 }  // @case A6
        return await task.value
    }
}
