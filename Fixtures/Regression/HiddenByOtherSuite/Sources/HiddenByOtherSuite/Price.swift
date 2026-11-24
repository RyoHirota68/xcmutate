public final class Config {
    public static let shared = Config()
    public var custom = 0
}

/// 100 unless a custom threshold was set. In a run of all tests ASetupTests sets it to 100 before BPriceTests
/// runs, so whether the default is used makes no difference there: the mutants of this function survive.
public func threshold() -> Int { Config.shared.custom > 0 ? Config.shared.custom : 100 }
public func isExpensive(_ price: Int) -> Bool { price >= threshold() }
