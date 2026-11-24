/// A function that does not return, declared in another file than the one that calls it.
func abortWith(_ message: String) -> Never {
    fatalError(message)
}
