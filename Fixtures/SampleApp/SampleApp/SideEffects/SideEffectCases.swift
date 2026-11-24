import Foundation
import os
import UIKit

// 7.6 副作用の文の削除（RemoveSideEffects 相当）。
// 文の削除を無効にすると、これらの行にある比較などの演算子だけが対象になる。

final class Cache {
    private(set) var stored: [String: Int] = [:]
    func store(_ key: String, _ value: Int) { stored[key] = value }  // @case EB-store
}

final class Repo {
    private(set) var saved: [Int] = []
    @discardableResult func save(_ x: Int) -> Int {
        saved.append(x)  // @case SE-repo-save
        return saved.count  // @case RV-save
    }
}

class Base {
    let id: Int
    init(id: Int) { self.id = id }
}

final class Derived: Base {
    init() {
        super.init(id: 1)  // @case R6-super
    }

    convenience init(flag: Int) {
        self.init()  // @case R6-self
    }
}

nonisolated final class DeinitCounter {
    var value = 0
}

nonisolated final class Tracker {
    let counter: DeinitCounter
    var active = 0
    init(counter: DeinitCounter) { self.counter = counter }
    deinit {
        if active > 0 { counter.value += 1 }  // @case R7
    }
}

nonisolated final class SafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }  // @case SE-locked-read

    func increment() {  // @case EB-increment
        lock.lock()  // @case R8-lock
        value += 1  // @case CA-increment
        lock.unlock()  // @case R8-unlock
    }
}

enum SideEffects {
    static let logger = Logger(subsystem: "dev.xcmutate.SampleApp", category: "R9")

    // R1: 戻り値 Void の呼び出し
    static func remember(_ cache: Cache, _ key: String, _ value: Int) {
        cache.store(key, value)  // @case R1
    }

    // R2: `_ = ` で捨てる呼び出し、@discardableResult の呼び出し
    static func persist(_ repo: Repo, _ x: Int) {
        _ = repo.save(x)  // @case R2-discard
    }

    static func persistQuietly(_ repo: Repo, _ x: Int) {
        repo.save(x)  // @case R2-discardable
    }

    // R4: fatalError / preconditionFailure / Never を返す自作関数（削除の対象外）
    static func unreachable(_ code: Int) -> Never {
        fatalError("code \(code)")  // @case R4-fatal
    }

    static func failHard() -> Never {
        preconditionFailure("failed")  // @case R4-precondition
    }

    static func ensure(_ ok: Bool) {  // @case EB-ensure
        if !ok { failHard() }  // @case R4-never
    }

    // R5: guard の else 節の return（削除の対象外）
    static func firstPositive(_ xs: [Int]) -> Int? {
        guard let first = xs.first(where: { $0 > 0 }) else { return nil }  // @case R5
        return first  // @case RV-firstPositive
    }

    // R9: ログ・レイアウトの呼び出し（arid）
    static func logged(_ x: Int) -> Int {
        print("x=\(x > 0)")  // @case R9-print
        logger.info("x=\(x > 1)")  // @case R9-logger
        os_log("x=%d", x)  // @case R9-oslog
        return x  // @case RV-logged
    }

    static func relayout(_ view: UIView) {
        view.setNeedsLayout()  // @case R9-setNeedsLayout
        view.layoutIfNeeded()  // @case R9-layoutIfNeeded
    }

    // R10: `i += 1`（複合代入）。関数呼び出しではないので、文の削除の対象にしない（候補にもならない）。
    // 削除するとほぼ必ず無限ループ（Timeout）になり、待ち時間の割に得られる情報が少ないため。
    static func sumBelow(_ n: Int) -> Int {
        var i = 0
        var total = 0
        while i < n {  // @case R10-cond
            total += i  // @case CA-r10-total
            i += 1  // @case R10
        }
        return total  // @case RV-sumBelow
    }

    // R11: 削除で無限ループになる呼び出し（R10 の代わりに Timeout を確かめる）
    static func drainQueue(_ n: Int) -> Int {
        var queue = Array(0..<n)
        var total = 0
        while !queue.isEmpty {  // @case R11-cond
            total += queue[0]  // @case CA-r11-total
            queue.removeFirst()  // @case R11
        }
        return total  // @case RV-drainQueue
    }
}
