import Foundation

// 戻り値とクロージャの演算子: return-case（引数付きの case を返す return）・implicit-return-value（式1つの本体）・
// closure-statement-removal（result builder ではないと構文から分かるクロージャの中の文の削除）。

enum LookupResult: Equatable { case missing, found(Int), invalid(String) }

enum ReturnAndClosure {
    // RC1: 引数付きの case を返す return を、同じ関数が返す「前後の文脈を要らない値」に置き換える。
    // `.found(value)` は局所変数を使うので置き換え先にはならない
    static func lookup(_ key: String, in table: [String: Int]) -> LookupResult {
        guard !key.isEmpty else {  // @case RC1-guard
            return .invalid("empty")  // @case RC1-invalid
        }
        guard let value = table[key] else {
            return .missing
        }
        return .found(value)  // @case RC1-found
    }

    // RC2: テストが「見つからない、ではない」ことしか確かめない。中身の違う値への置き換えは生き残る
    static func lookupLoose(_ key: String, in table: [String: Int]) -> LookupResult {
        guard let value = table[key] else {
            return .missing
        }
        if value < 0 {  // @case RC2-if
            return .invalid("negative")  // @case RC2-invalid
        }
        return .found(value)  // @case RC2-found
    }

    // IR1: 式1つの本体の値を、戻り値の型から作れる別の値にする（配列 → 空）
    static func doubled(_ values: [Int]) -> [Int] { values.map { $0 * 2 } }  // @case IR1-array

    // IR2: Optional → nil
    static func firstName(_ names: [String]) -> String? { names.first }  // @case IR2-optional

    // IR3: 値を確かめるテストが無い
    static func label(_ id: Int) -> String { "id-\(id)" }  // @case IR3-untested

    // IR4: リテラルだけの本体（定数）は対象にしない。候補にもならない
    static var prefix: String { "id-" }

    // CS1: forEach のクロージャ（1文）。forEach のクロージャは値を返さず、result builder でもない
    static func collect(_ values: [Int]) -> [Int] {
        var result: [Int] = []
        values.forEach { result.append($0) }  // @case CS1-forEach
        return result  // @case CS1-return
    }

    // CS2: return・guard のあるクロージャ（result builder の変換を受けないと構文から分かる）
    static func takeWhilePositive(_ values: [Int]) -> [Int] {
        let run: ([Int]) -> [Int]? = { input in
            var taken: [Int] = []
            for value in input {
                guard value > 0 else { break }  // @case CS2-guard
                taken.append(value)  // @case CS2-append
            }
            if taken.isEmpty { return nil }  // @case CS2-empty
            return taken
        }
        return run(values) ?? []  // @case CS2-return
    }

    // CS3: 1文だけのクロージャで、その文が値かもしれないもの（map）は対象にしない。候補にもならない
    static func mapped(_ values: [Int]) -> [Int] {
        values.map { transform($0) }  // @case CS3-map
    }

    static func transform(_ x: Int) -> Int { x + 1 }  // @case CS3-transform

    // CS4: クロージャの中でも、消してはいけない文（ロック）は理由付きで除外する
    static func drain(_ values: [Int], lock: NSLock) -> Int {
        var sum = 0
        values.forEach { value in  // @case CS4-forEach
            lock.lock()  // @case CS4-lock
            sum += value  // @case CS4-sum
            lock.unlock()  // @case CS4-unlock
        }
        return sum  // @case CS4-return
    }
}
