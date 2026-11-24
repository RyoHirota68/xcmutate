import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// 検証用プロジェクト（Fixtures/SampleApp）のソースに対する生成結果を、expected.json と静的に突き合わせる。
///
/// 実行結果（Killed / Survived など）は scripts/verify-fixture.sh で突き合わせる。ここでは「どのミュータントが作られ、
/// どれが理由付きで除外されるか」だけを確かめる。
@Suite("検証用プロジェクトの期待結果（静的）")
struct FixtureExpectationTests {
    struct Expected: Decodable {
        var sourceRoots: [String]
        var cases: [Case]
    }

    struct Case: Decodable {
        var id: String
        var file: String
        var noCandidates: [String]?
        var mutants: [ExpectedMutant]
    }

    struct ExpectedMutant: Decodable {
        var marker: String
        var `operator`: String
        var original: String?
        var occurrence: Int?
        var expected: String
        var reason: String?
        var stage: Int?
    }

    /// 生成結果（ミュータントか、除外された候補）を1件にまとめたもの。
    struct Generated: CustomStringConvertible {
        var file: String
        var line: Int
        var marker: String?
        var op: String
        var original: String
        var occurrence: Int
        var ignoredReason: String?

        var description: String {
            "\(file):\(line) [\(marker ?? "unmarked")] \(op) `\(original)` #\(occurrence)" + (ignoredReason.map { " ignored(\($0))" } ?? "")
        }
    }

    static let fixtureRoot = repositoryRoot.appendingPathComponent("Fixtures/SampleApp")

    static func loadExpected() throws -> Expected {
        let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("expected.json"))
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    /// `run` が既定で対象にするファイル（`FileSelector`: テスト・生成コード・設定の `exclude` を外したもの）。
    static func selection() throws -> FileSelector.Selection {
        var all: [String] = []
        let rootPath = fixtureRoot.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: fixtureRoot, includingPropertiesForKeys: nil) else { return .init(included: [], excluded: []) }
        for case let file as URL in enumerator {
            if file.pathExtension == "xcodeproj" { enumerator.skipDescendants(); continue }
            if file.pathExtension == "swift" { all.append(String(file.standardizedFileURL.path.dropFirst(rootPath.count + 1))) }
        }
        let config = try MutatorConfig.load(fixtureRoot.appendingPathComponent(MutatorConfig.defaultName))
        return FileSelector.select(paths: all, patterns: config.exclude ?? []) { path in
            try? String(contentsOf: fixtureRoot.appendingPathComponent(path), encoding: .utf8)
        }
    }

    static func swiftFiles(under roots: [String]) throws -> [String] {
        let included = try selection().included
        // 対象のファイルは、すべて expected.json の sourceRoots の下にある
        for file in included { #expect(roots.contains { file.hasPrefix($0 + "/") }, "\(file) is outside sourceRoots") }
        return included
    }

    /// 7.12: 既定の除外と設定の `exclude` で外れるファイルと理由（expected.json の `global.excludedFiles`）。
    @Test func excludedFilesMatchExpectations() throws {
        struct Global: Decodable { var global: Inner; struct Inner: Decodable { var excludedFiles: [String: String] } }
        let data = try Data(contentsOf: Self.fixtureRoot.appendingPathComponent("expected.json"))
        let expected = try JSONDecoder().decode(Global.self, from: data).global.excludedFiles
        let excluded = try Self.selection().excluded.filter { $0.reason != "test-code" }
        #expect(Dictionary(uniqueKeysWithValues: excluded.map { ($0.file, $0.reason) }) == expected)
        let included = try Self.selection().included
        #expect(included.contains("SampleApp/Infrastructure/ABTest.swift"))
        #expect(included.contains("SampleApp/Excluded/Kept.swift"))
    }

    /// 行ごとの `// @case <marker>`。
    static func markers(in source: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if let range = line.range(of: "// @case ") {
                let marker = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                result[index + 1] = marker
            }
        }
        return result
    }

    static func generateAll() throws -> (generated: [Generated], markers: [String: (file: String, line: Int)], results: [FileResult]) {
        let expected = try loadExpected()
        var generated: [Generated] = []
        var allMarkers: [String: (String, Int)] = [:]
        var results: [FileResult] = []
        var nextID = 0
        // run と同じく、モジュールの全ファイルから演算子の宣言を集める
        let allFiles = try swiftFiles(under: expected.sourceRoots)
        let operatorDeclarations = OperatorDeclarations.extract(from: try allFiles.map {
            try String(contentsOf: fixtureRoot.appendingPathComponent($0), encoding: .utf8)
        })
        for file in allFiles {
            let source = try String(contentsOf: fixtureRoot.appendingPathComponent(file), encoding: .utf8)
            let markers = markers(in: source)
            for (line, marker) in markers {
                #expect(allMarkers[marker] == nil, "duplicated marker \(marker)")
                allMarkers[marker] = (file, line)
            }
            var options = try MutatorConfig.load(fixtureRoot.appendingPathComponent(MutatorConfig.defaultName))
                .generatorOptions(extraArid: [], extraDisabled: [], maxSwitches: nil)
            options.extraOperatorDeclarations = operatorDeclarations
            // The fixture is run on an iOS simulator; `run` leaves out the branches of `#if` that are not compiled there
            options.targetPlatform = TargetPlatform(os: "iOS", isSimulator: true)
            let result = FileProcessor(options: options).process(source: source, file: file, firstID: nextID)
            nextID += result.mutants.count
            results.append(result)

            var items: [(line: Int, start: Int, op: String, original: String, reason: String?)] = []
            items += result.mutants.map { ($0.start.line, $0.point.start, $0.operator.rawValue, $0.original, nil) }
            items += result.ignored.map { ($0.start.line, $0.point.start, $0.operator.rawValue, $0.original, $0.reason.rawValue) }
            items.sort { $0.start < $1.start }
            var occurrences: [String: Int] = [:]
            for item in items {
                // 同じ行・同じ演算子の中での順番（1 始まり、位置の順）
                let occurrenceKey = "\(item.line)|\(item.op)"
                occurrences[occurrenceKey, default: 0] += 1
                generated.append(Generated(
                    file: file, line: item.line, marker: markers[item.line], op: item.op, original: item.original,
                    occurrence: occurrences[occurrenceKey]!, ignoredReason: item.reason))
            }
        }
        return (generated, allMarkers, results)
    }

    @Test func everyGeneratedCandidateIsOnAMarkedLine() throws {
        let (generated, _, _) = try Self.generateAll()
        let unmarked = generated.filter { $0.marker == nil }
        #expect(unmarked.isEmpty, "candidates on unmarked lines: \(unmarked)")
    }

    @Test func instrumentationOfAllFixtureFilesIsValid() throws {
        let (_, _, results) = try Self.generateAll()
        #expect(results.allSatisfy { $0.skippedReason == nil })
        for result in results {
            #expect(result.verification.isValid, "\(result.file): \(result.verification.problems)")
        }
        // ID がファイルをまたいで重複しない。安定キーも重複しない（同名ファイル・`+` を含むファイル名でも）。
        let mutants = results.flatMap(\.mutants)
        #expect(Set(mutants.map(\.id)).count == mutants.count)
        #expect(Set(mutants.map(\.key)).count == mutants.count)
    }

    @Test func generatedCandidatesMatchExpectations() throws {
        let expected = try Self.loadExpected()
        let (generated, markers, _) = try Self.generateAll()
        var unmatched = generated

        for fixtureCase in expected.cases {
            for marker in fixtureCase.noCandidates ?? [] {
                #expect(markers[marker] != nil, "\(fixtureCase.id): marker \(marker) not found in sources")
                #expect(!generated.contains { $0.marker == marker }, "\(fixtureCase.id): marker \(marker) should have no candidates")
            }
            for expectation in fixtureCase.mutants where (expectation.stage ?? 1) == 1 {
                #expect(markers[expectation.marker] != nil, "\(fixtureCase.id): marker \(expectation.marker) not found in sources")
                let matches = unmatched.indices.filter { index in
                    let g = unmatched[index]
                    guard g.marker == expectation.marker, g.op == expectation.operator else { return false }
                    if let original = expectation.original, g.original != original { return false }
                    if let occurrence = expectation.occurrence, g.occurrence != occurrence { return false }
                    return true
                }
                guard matches.count == 1, let index = matches.first else {
                    Issue.record("\(fixtureCase.id): expectation \(expectation.marker) \(expectation.operator) \(expectation.original ?? "") #\(expectation.occurrence.map(String.init) ?? "-") matched \(matches.count) candidates")
                    continue
                }
                let g = unmatched.remove(at: index)
                if expectation.expected == "Ignored" {
                    #expect(g.ignoredReason == expectation.reason, "\(fixtureCase.id): \(g) should be ignored with reason \(expectation.reason ?? "?")")
                } else {
                    #expect(g.ignoredReason == nil, "\(fixtureCase.id): \(g) should be a mutant (expected \(expectation.expected))")
                }
            }
        }
        #expect(unmatched.isEmpty, "candidates without expectations: \(unmatched)")
    }
}
