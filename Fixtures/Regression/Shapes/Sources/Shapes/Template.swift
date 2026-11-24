/// Product code that holds the text of a test file. The line `import XCTest` inside the string made the
/// whole file count as test code, and it was left out without its name being said.
public func testFileTemplate(module: String, cases: Int) -> String {
    let header = cases > 0 ? "// \(cases) cases" : "// empty"
    return """
    \(header)
    import XCTest
    @testable import \(module)
    """
}
