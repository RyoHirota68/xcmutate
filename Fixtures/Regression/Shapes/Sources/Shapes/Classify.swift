/// The function ends with a call to a function that does not return, declared in another file.
/// Wrapping that call for removal made the function not compile, and every mutant of it was removed.
public func classify(_ n: Int) -> String {
    if n < 0 { return "neg" }
    if n == 0 { return "zero" }
    if n > 0 { return "pos" }
    abortWith("unreachable")
}
