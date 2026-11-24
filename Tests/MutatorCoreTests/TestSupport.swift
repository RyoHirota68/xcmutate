import Foundation
@testable import MutatorCore
import SwiftParser
import SwiftSyntax
import Testing

/// The basic operators (the tests of the other operators name theirs, so that the counts here do not change).
let basicOperatorOptions = GeneratorOptions(operators: Set(MutationOperator.allCases).subtracting(
    [.conditionNegation, .returnNegation, .operandRemoval, .arithmetic, .nilCoalescingDefault, .minMax,
     .emptyBody, .compoundAssignment, .switchCaseRemoval, .tryOptionalNil, .conditionConstant, .guardRemoval,
     .returnCase, .implicitReturnValue, .closureStatementRemoval]))

/// The operators for conditions and operands as well (without those that are off by default); the others are named by each test.
let defaultOperatorOptions = GeneratorOptions(operators: Set(MutationOperator.allCases).subtracting([.nilCoalescingDefault, .arithmetic]).subtracting(
    [.emptyBody, .compoundAssignment, .switchCaseRemoval, .tryOptionalNil, .conditionConstant, .guardRemoval,
     .returnCase, .implicitReturnValue, .closureStatementRemoval]))

/// Only return-case, implicit-return-value and closure-statement-removal.
let returnAndClosureOptions = GeneratorOptions(operators: [.returnCase, .implicitReturnValue, .closureStatementRemoval])

func generate(_ source: String, options: GeneratorOptions = basicOperatorOptions) -> GenerationResult {
    MutantGenerator(options: options).generate(source: source, filePath: "Test.swift")
}

func process(_ source: String, firstID: Int = 0, changedLines: [ClosedRange<Int>]? = nil,
             options: GeneratorOptions = basicOperatorOptions) -> FileResult {
    processWith(source, firstID: firstID, changedLines: changedLines, options: options)
}

func process(options: GeneratorOptions, _ source: String) -> FileResult {
    processWith(source, firstID: 0, changedLines: nil, options: options)
}

private func processWith(_ source: String, firstID: Int, changedLines: [ClosedRange<Int>]?, options: GeneratorOptions) -> FileResult {
    FileProcessor(options: options).process(source: source, file: "Test.swift", firstID: firstID, changedLines: changedLines)
}

/// ミュータントの書き換わる部分のテキストを、元のソースのバイト範囲から取り出す。
func pointText(_ source: String, _ range: ByteRange) -> String {
    let bytes = Array(source.utf8)
    return String(decoding: bytes[range.start..<range.end], as: UTF8.self)
}

/// 1件のミュータントだけを適用したソース（スイッチを使わない、素朴な書き換え）。
func applySingle(_ source: String, _ mutant: Mutant) -> String {
    var bytes = Array(source.utf8)
    let replacement = mutant.operator.replacesStatement || mutant.operator.guardsCase ? mutant.mutatedExpression
        : mutant.isStatement ? "" : "(\(mutant.mutatedExpression))"
    bytes.replaceSubrange(mutant.region.start..<mutant.region.end, with: Array(replacement.utf8))
    return String(decoding: bytes, as: UTF8.self)
}

func ignoredReasons(_ result: GenerationResult) -> [IgnoreReason] {
    result.ignored.map(\.reason)
}

/// 埋め込み後のテキストが構文エラーなくパースでき、静的検査が通ることを確かめる。
func expectValidInstrumentation(_ result: FileResult, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
    #expect(result.verification.isValid, "\(result.verification.problems)", sourceLocation: sourceLocation)
    #expect(!Parser.parse(source: result.instrumented).hasError, "instrumented source has syntax errors:\n\(result.instrumented)", sourceLocation: sourceLocation)
}

/// リポジトリのルート（このファイルから2つ上）。
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// `swiftc` を実行する。使えない環境では `nil`。
func runProcess(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

extension Array {
    /// 要素がちょうど1つならそれを返す。
    var only: Element? { count == 1 ? first : nil }
}

/// `xcrun` is needed by the tests that compile with `swiftc`.
let swiftcAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")

/// Runs `body` with a new temporary directory and removes it afterwards.
func withTemporaryDirectory<T>(_ prefix: String = "xcmutate-tests", _ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Compiles `source` with `swiftc` (really compiles: errors that only appear after type checking, such as a
/// missing return, are found). Returns the compiler's exit status and output, and the path of the executable.
func compileSwift(_ source: String, in directory: URL, name: String, arguments: [String] = ["-swift-version", "6"]) throws -> (status: Int32, output: String, executable: String) {
    let file = directory.appendingPathComponent("\(name).swift")
    let executable = directory.appendingPathComponent(name).path
    try source.write(to: file, atomically: true, encoding: .utf8)
    let result = try #require(runProcess("/usr/bin/xcrun", ["swiftc"] + arguments + ["-o", executable, file.path]))
    return (result.status, result.output, executable)
}
