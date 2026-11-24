public enum Leak {
    /// The mutant that returns nil here makes the test throw before it removes its file.
    public static func parse(_ text: String) -> Int? {
        return Int(text)
    }

    /// No test looks at the boundary: `>=` instead of `>` survives.
    public static func isLarge(_ value: Int) -> Bool {
        return value > 100
    }
}
