import Foundation
@testable import MutatorCore
import SwiftParser
import Testing

@Suite("埋め込みと静的検査")
struct InstrumentationTests {
    @Test func helperIsAppendedAtTheEndAndLinesArePreserved() {
        let source = "func f(_ a: Int) -> Bool {\n    a > 0\n}"
        let result = process(source)
        expectValidInstrumentation(result)
        let lines = result.instrumented.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "func f(_ a: Int) -> Bool {")
        #expect(lines[1] == "    (__xcmutate.isOn(0) ? (a >= 0) : (a > 0))")
        #expect(lines[2] == "}")
        #expect(lines[3] == Substring(Instrumenter.helperMarker))
        #expect(result.instrumented.contains("nonisolated fileprivate enum __xcmutate"))
        #expect(result.instrumented.contains("__xcmutateGetenv(\"XCMUTATE_ACTIVE\")"))
        #expect(result.verification.helperCount == 1)
    }

    @Test func noMutantsMeansUnchangedSource() {
        let source = "let x = 1 + 2\n"
        let result = process(source)
        #expect(result.mutants.isEmpty)
        #expect(result.instrumented == source)
        #expect(result.verification.isValid)
    }

    /// ヘルパーは import を足さない（他のファイルの import とアクセスレベルが食い違うとエラーになるため）。
    @Test(arguments: ["import Foundation\n", "internal import Foundation\n", "import SwiftUI\n", ""])
    func helperNeverAddsImports(header: String) {
        let result = process(header + "func f(_ a: Int) -> Bool { a > 0 }\n")
        expectValidInstrumentation(result)
        #expect(!result.instrumented.contains("import Foundation\n@_silgen_name"))
        #expect(result.instrumented.components(separatedBy: "import ").count == header.components(separatedBy: "import ").count)
    }

    @Test func verifierDetectsMissingDuplicatedAndUnexpectedIDs() {
        let source = "func f(_ a: Int) -> Bool { a > 0 }\n"
        let good = process(source)
        let helper = Instrumenter.helperSource(importFoundation: true)

        let missing = InstrumentationVerifier.verify(original: source, instrumented: good.instrumented, expectedIDs: [0, 1])
        #expect(missing.missingIDs == [1])
        #expect(!missing.isValid)

        let duplicatedText = "func f(_ a: Int) -> Bool { (__xcmutate.isOn(0) ? (a >= 0) : (__xcmutate.isOn(0) ? (a < 0) : (a > 0))) }\n" + helper
        let duplicated = InstrumentationVerifier.verify(original: source, instrumented: duplicatedText, expectedIDs: [0])
        #expect(duplicated.duplicatedIDs == [0])

        let unexpected = InstrumentationVerifier.verify(original: source, instrumented: good.instrumented, expectedIDs: [])
        #expect(unexpected.unexpectedIDs == [0])
        #expect(!unexpected.isValid)
    }

    @Test func verifierIgnoresSwitchTextInStringsAndComments() {
        let source = "func f(_ a: Int) -> Bool { a > 0 }\n"
        let text = "let s = \"__xcmutate.isOn(0)\" // __xcmutate.isOn(0)\n" + process(source).instrumented
        let result = InstrumentationVerifier.verify(original: "let s = \"__xcmutate.isOn(0)\" // __xcmutate.isOn(0)\n" + source,
                                                    instrumented: text, expectedIDs: [0])
        #expect(result.isValid, "\(result.problems)")
    }

    @Test func verifierDetectsSyntaxErrorsAndLineChanges() {
        let source = "func f(_ a: Int) -> Bool {\n    a > 0\n}\n"
        let helper = Instrumenter.helperSource(importFoundation: true)
        let broken = "func f(_ a: Int) -> Bool {\n    (__xcmutate.isOn(0) ? (a >= 0) : (a > 0)\n}\n" + helper
        #expect(InstrumentationVerifier.verify(original: source, instrumented: broken, expectedIDs: [0]).hasSyntaxError)
        let shifted = "func f(_ a: Int) -> Bool {\n    (__xcmutate.isOn(0) ? (a >=\n 0) : (a > 0))\n}\n" + helper
        #expect(InstrumentationVerifier.verify(original: source, instrumented: shifted, expectedIDs: [0]).lineCountChanged)
        let noHelper = "func f(_ a: Int) -> Bool {\n    (__xcmutate.isOn(0) ? (a >= 0) : (a > 0))\n}\n"
        let result = InstrumentationVerifier.verify(original: source, instrumented: noHelper, expectedIDs: [0])
        #expect(result.helperCountMismatch)
        #expect(!result.isValid)
    }

    @Test func instrumentedOutputParsesForMixedSample() {
        let result = process(MixedSample.source)
        expectValidInstrumentation(result)
        #expect(result.mutants.count > 20)
    }
}

@Suite("差分によるフィルタ")
struct DiffFilterTests {
    let diff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -3 +3 @@ func f() {
    -    a > b
    +    a >= b
    @@ -10,0 +11,2 @@ func g() {
    +    let x = 1
    +    let y = 2
    @@ -20,3 +22,0 @@ func h() {
    -    removed
    diff --git a/Old.swift b/Old.swift
    deleted file mode 100644
    --- a/Old.swift
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -x
    -y
    diff --git a/New.swift b/New.swift
    new file mode 100644
    --- /dev/null
    +++ b/New.swift
    @@ -0,0 +1,4 @@
    +a
    """

    @Test func parsesUnifiedDiff() {
        let parsed = DiffFilter.parseUnifiedDiff(diff)
        #expect(parsed["Sources/A.swift"] == [3...3, 11...12, 22...23])
        #expect(parsed["New.swift"] == [1...4])
        #expect(parsed["Old.swift"] == nil)
    }

    @Test func filtersByLines() {
        let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            let x = a > b
            let y = a < b
            return x && y
        }

        """
        let all = generate(source).mutants
        #expect(all.count == 3)
        #expect(DiffFilter.filter(all, changedLines: [3...3]).map(\.original) == ["<"])
        #expect(DiffFilter.filter(all, changedLines: [1...2, 4...4]).map(\.original) == [">", "&&"])
        #expect(DiffFilter.filter(all, changedLines: []).isEmpty)
    }

    @Test func filtersByBytes() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a > b && a < b }\n"
        let all = generate(source).mutants
        let lt = try #require(all.first { $0.original == "<" })
        #expect(DiffFilter.filter(all, changedByteRanges: [lt.point]).map(\.original) == ["<"])
        #expect(DiffFilter.filter(all, changedByteRanges: [ByteRange(start: 0, end: 10)]).isEmpty)
    }

    /// 差分の範囲外のミュータントは ID を振らず、埋め込みもしない。
    @Test func processorAppliesChangedLines() {
        let source = "func f(_ a: Int) -> Bool {\n    let x = a > 0\n    return x && a < 9\n}\n"
        let result = process(source, firstID: 7, changedLines: [3...3])
        expectValidInstrumentation(result)
        #expect(result.mutants.map(\.id) == [7, 8])
        #expect(result.mutants.map(\.original) == ["&&", "<"])
        #expect(result.outOfDiffCount == 1)
        #expect(!result.instrumented.contains("a >= 0"))
    }
}

enum MixedSample {
    static let source = """
    import Foundation

    // 日本語のコメント 🎉
    protocol Shape { var area: Double { get } }
    extension Shape { var isLarge: Bool { area > 100 } }
    struct Box<T> { var v: T }
    extension Box: Equatable where T == String {}
    func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { v < lo ? lo : (v > hi ? hi : v) }
    actor Counter {
        var n = 0
        func bump() -> Bool { n += 1; return n >= 3 }
    }
    @MainActor final class VM {
        var count = 0
        var isReady = false
        func check() -> Bool { count > 0 && !isReady }
        nonisolated func pure(_ x: Int) -> Bool { x != 0 }
    }
    func work(_ items: [Int], _ limit: Int) async throws -> [Int] {
        let filtered = items.filter { $0 > limit }.sorted { $0 < $1 }
        let task = Task { filtered.count >= 2 }
        if await task.value, filtered.allSatisfy({ $0 >= 0 }) {
            return filtered.map { $0 > 1 ? $0 : 0 }
        }
        let ok: Bool
        if limit > 5 { ok = true } else { ok = false }
        return ok ? items : []
    }
    let isDebugBuild = ProcessInfo.processInfo.arguments.count > 2
    struct Config { var isLarge = isDebugBuild == true; static let flag = !isDebugBuild }

    """
}
