import Foundation
@testable import MutatorCore
import Testing

/// A test process hands its environment to the processes it starts. A child that holds another embedding
/// (another token, or none) must not switch a mutant on because the parent's mutant has the same number.
@Suite(.serialized) struct EmbeddingTokenTests {
    static let program = """
    func isLarge(_ x: Int) -> Bool { return x > 100 }
    print(isLarge(100))

    """

    @Test func namesCarryTheToken() {
        let plain = Instrumenter.EnvironmentNames()
        #expect(plain.active == "XCMUTATE_ACTIVE")
        #expect(plain.trace == "XCMUTATE_TRACE")
        let named = Instrumenter.EnvironmentNames(token: "ABC1")
        #expect(named.active == "XCMUTATE_ACTIVE_ABC1")
        #expect(named.trace == "XCMUTATE_TRACE_ABC1")
        #expect(named.testTrace == "XCMUTATE_TRACE_TESTS_ABC1")
        #expect(named.shared == "XCMUTATE_SHARED_ABC1")
        let a = Instrumenter.EnvironmentNames.token(forWorkDirectory: "/work/a")
        let b = Instrumenter.EnvironmentNames.token(forWorkDirectory: "/work/b")
        #expect(a != b)
        #expect(a == Instrumenter.EnvironmentNames.token(forWorkDirectory: "/work/a"))
        #expect(a.allSatisfy { $0.isASCII && ($0.isNumber || $0.isUppercase) })
    }

    @Test(.enabled(if: swiftcAvailable), .timeLimit(.minutes(5)))
    func aProgramOfAnotherEmbeddingIgnoresTheVariables() throws {
        try withTemporaryDirectory { directory in
            let result = FileProcessor(options: GeneratorOptions(operators: [.boundary])).process(source: Self.program, file: "main.swift", firstID: 0)
            let mutant = try #require(result.mutants.only)
            let names = Instrumenter.EnvironmentNames(token: "T1")
            let instrumented = Instrumenter.instrument(source: Self.program, mutants: result.mutants, names: names)
            let build = try compileSwift(instrumented, in: directory, name: "tokened")
            try #require(build.status == 0, "\(build.output)")
            func output(_ environment: [String: String]) throws -> String {
                try #require(runProcess(build.executable, [], environment: environment)).output
            }
            #expect(try output([:]) == "false\n")
            // Its own name: the mutant is on (`x >= 100`)
            #expect(try output([names.active: String(mutant.id)]) == "true\n")
            // The plain name and the name of another embedding: ignored
            #expect(try output([Instrumenter.environmentVariable: String(mutant.id)]) == "false\n")
            #expect(try output([Instrumenter.EnvironmentNames(token: "T2").active: String(mutant.id)]) == "false\n")
            // The record file too: nothing is written for another embedding's variable
            let foreign = directory.appendingPathComponent("foreign.trace").path
            _ = try output([Instrumenter.traceEnvironmentVariable: foreign])
            #expect(!FileManager.default.fileExists(atPath: foreign))
            let own = directory.appendingPathComponent("own.trace").path
            _ = try output([names.trace: own, names.active: String(mutant.id)])
            #expect(try String(contentsOfFile: own, encoding: .utf8) == "A \(mutant.id)\n")
        }
    }
}
