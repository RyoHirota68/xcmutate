import Foundation

// 7.9 戻り値と制御の流れの演算子（基本の演算子では作れない種類）。

enum VariantResult { case hasVariant, noVariant, unknown }

// O6: xcmutate.yml の aridCalls で対象外にする呼び出し
enum FixtureAnalytics {
    static func send(_ name: String, _ flag: Bool) {}
}

enum NewOperators {
    // O1: 戻り値の enum の case の置き換え（手作業の M12 相当）。物品マスタ未紐付け（nil）のテストが無い
    static func variantSetting(masterId: Int?, settings: [Int: Bool]) -> VariantResult {
        guard let masterId else {
            return .noVariant  // @case O1-unlinked
        }
        guard let enabled = settings[masterId] else {
            return .unknown  // @case O1-missing
        }
        return enabled ? .hasVariant : .noVariant  // @case O1-enabled
    }

    // O2: ループの中でフラグを立てて最後に返す形（手作業の M10 相当）。
    // 「判定不能の品目の後ろにバリエーションありの品目」の組み合わせのテストが無い
    static func combine(_ results: [VariantResult]) -> VariantResult {
        var hasUnknown = false  // @case O2-flag
        for result in results {
            switch result {
            case .hasVariant: return .hasVariant  // @case O2-has
            case .noVariant: continue  // @case O2-continue
            case .unknown: hasUnknown = true  // @case O2-unknown
            }
        }
        return hasUnknown ? .unknown : .noVariant  // @case O2-return
    }

    // O2: 同じ形で、その組み合わせのテストがあるもの
    static func combineTested(_ results: [VariantResult]) -> VariantResult {
        var hasUnknown = false  // @case O2t-flag
        for result in results {
            switch result {
            case .hasVariant: return .hasVariant  // @case O2t-has
            case .noVariant: continue  // @case O2t-continue
            case .unknown: hasUnknown = true  // @case O2t-unknown
            }
        }
        return hasUnknown ? .unknown : .noVariant  // @case O2t-return
    }

    // O3: 条件の削除（手作業の M01 相当）。空文字のテストが無い
    static func connectedHost(_ raw: String?) -> String? {
        guard let host = raw, !host.isEmpty else { return nil }  // @case O3-guard
        return host  // @case O3-return
    }

    // O3: 同じ形で、外した条件をテストが確かめるもの
    static func port(_ raw: Int?) -> Int? {
        guard let p = raw, p > 0 else { return nil }  // @case O3-port
        return p  // @case O3-port-return
    }

    // O4: continue ↔ break
    static func countBeforeNegative(_ xs: [Int]) -> Int {
        var count = 0
        for x in xs {
            if x < 0 { break }  // @case O4-break
            count += 1  // @case CA-o4-count
        }
        return count  // @case O4-return
    }

    // O5: 正規化の呼び出しを外す（手作業の M06 相当）。大文字の接続先を渡すテストが無い
    static func matchesHost(_ host: String, connected: String) -> Bool {
        host == connected.lowercased()  // @case O5-lowercased
    }

    static func normalizedCode(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }  // @case O5-trim

    // O6: 設定で arid にした呼び出し（文の削除も引数の中の式も対象外）
    static func track(_ count: Int) -> Int {
        FixtureAnalytics.send("count", count > 10)  // @case O6
        return count  // @case O6-return
    }
}
