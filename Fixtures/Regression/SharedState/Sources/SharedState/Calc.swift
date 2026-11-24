/// No test looks at a boundary: every `>=` instead of `>` survives.
public enum Calc {
    public static func over1(_ x: Int) -> Bool {
        return x > 100
    }

    public static func over2(_ x: Int) -> Bool {
        return x > 200
    }

    public static func over3(_ x: Int) -> Bool {
        return x > 300
    }
}
