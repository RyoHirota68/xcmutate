/// The first branch is not compiled in a run on macOS. Its mutants were reported as NotReached.
public func screenScale(_ points: Int) -> Int {
    #if os(iOS)
    if points > 100 { return points * 3 }
    return points * 2
    #else
    return points
    #endif
}
