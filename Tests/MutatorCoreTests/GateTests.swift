import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// The gates that decide the exit status: what counts as "could not be examined", reading an
/// earlier report (the key scheme), and cases that running the tool on its own code found untested.
@Suite struct GateTests {
    private func report(_ statuses: [(MutantStatus, String)]) -> RunReport { ConfigJournalAndReportTests.report(statuses) }

    // MARK: Not everything could be examined

    /// Every kind of gate refuses to pass while mutants have no verdict (not only --fail-on-survived).
    @Test func everyGateIsIncompleteWhileMutantsHaveNoVerdict() {
        let unevaluated = report([(.killed, "A.swift"), (.runnerError, "A.swift")])
        #expect(Gate(failOnSurvived: true).evaluate(unevaluated).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(Gate(failUnder: 50).evaluate(unevaluated).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(Gate(earlierUndetected: []).evaluate(unevaluated).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(Gate().evaluate(unevaluated).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(Gate().evaluate(unevaluated).first?.message.hasPrefix("the report is incomplete: 1 of 2 mutants could not be run") == true)
        #expect(Gate().evaluate(report([(.killed, "A.swift"), (.compileError, "A.swift")])).isEmpty)
        #expect(!Gate().isRequested)
        #expect(Gate(failUnder: 0).isRequested)
        #expect(Gate(earlierUndetected: []).isRequested)
        let notActivated = report([(.killed, "A.swift"), (.notActivated, "A.swift")])
        #expect(Gate(failUnder: 50).evaluate(notActivated).map(\.exitCode) == [ExitCodes.incomplete])
    }

    /// A gate that already failed is reported as it is; "incomplete" is not added to it.
    @Test func aFailedGateIsNotAlsoIncomplete() {
        let both = report([(.survived, "A.swift"), (.runnerError, "A.swift")])
        #expect(Gate(failOnSurvived: true).evaluate(both).map(\.exitCode) == [ExitCodes.survived])
    }

    /// A file that could not be parsed is not "0 mutants, gate passed".
    @Test func aSkippedFileKeepsAGateFromPassing() {
        var skipped = report([(.killed, "A.swift")])
        skipped.skippedFiles = ["Sources/Future.swift": "parse-error"]
        #expect(skipped.unexamined.count == 1)
        #expect(skipped.unexamined[0].contains("Sources/Future.swift (parse-error)"))
        let failures = Gate(failOnSurvived: true, earlierUndetected: nil).evaluate(skipped)
        #expect(failures.map(\.exitCode) == [ExitCodes.incomplete])
        #expect(failures.first?.message.contains("Sources/Future.swift") == true)
        #expect(Gate(failUnder: 100).evaluate(skipped).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(Gate().evaluate(skipped).isEmpty)
        // With no mutant at all (the only file was skipped): still not a pass
        var empty = report([])
        empty.skippedFiles = ["Sources/Future.swift": "parse-error"]
        #expect(Gate(failUnder: 100, failOnSurvived: true).evaluate(empty).map(\.exitCode) == [ExitCodes.incomplete])
    }

    /// Mutants removed with their whole declaration were not examined; a mutant that does not compile itself was.
    @Test func mutantsRemovedWithTheirDeclarationKeepAGateFromPassing() {
        var removed = report([(.killed, "A.swift"), (.compileError, "A.swift"), (.compileError, "A.swift")])
        #expect(Gate(failOnSurvived: true).evaluate(removed).isEmpty)
        removed.results[1].collateral = true
        #expect(removed.collateralCount == 1)
        let failures = Gate(failOnSurvived: true).evaluate(removed)
        #expect(failures.map(\.exitCode) == [ExitCodes.incomplete])
        #expect(failures.first?.message.contains("A.swift: Cart.total()") == true)
    }

    /// Keys given with --only that name nothing.
    @Test func unknownOnlyKeysKeepAGateFromPassing() {
        var unknown = report([(.killed, "A.swift")])
        unknown.warnings = [RunWarning(kind: "unknownKey", message: "--only: no mutant with key x", key: "x")]
        #expect(Gate(failUnder: 100).evaluate(unknown).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(Gate().evaluate(unknown).isEmpty)
    }

    // MARK: The earlier report (--baseline-report)

    @Test func theEarlierReportMustUseTheSameKeyScheme() throws {
        let current = try JSONEncoder().encode(JSONReport(report: report([(.survived, "A.swift")])))
        let json = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        #expect(json["keyVersion"] as? Int == MutantKeyScheme.version)
        #expect(MutantKeyScheme.version == 2)
        #expect(try Gate.earlierReport(current).undetected.count == 1)
        // A report with keys of another scheme: refused, with the reason
        var old = json
        old["keyVersion"] = 1
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: Gate.GateError.self) { try Gate.earlierReport(oldData) }
        do {
            _ = try Gate.earlierReport(oldData)
        } catch {
            #expect("\(error)".contains("scheme 1"))
            #expect("\(error)".contains("Make the earlier report again"))
        }
        #expect(throws: Gate.GateError.self) { try Gate.undetectedKeys(inReport: Data(#"{"results": [], "keyVersion": 99}"#.utf8)) }
        #expect(throws: Gate.GateError.self) { try Gate.earlierReport(Data("{}".utf8)) }
    }

    /// The mutants that an interrupted run did not get to are not "detected before".
    @Test func mutantsThatTheEarlierRunDidNotJudgeAreNotNewGaps() throws {
        var interrupted = report([(.killed, "A.swift"), (.survived, "A.swift"), (.runnerError, "A.swift"), (.accepted, "A.swift"), (.notActivated, "A.swift")])
        interrupted.interrupted = true
        interrupted.pendingKeys = ["A.swift::trial()::boundary::1", "A.swift::trial()::boundary::2"]
        let earlier = try Gate.earlierReport(JSONEncoder().encode(JSONReport(report: interrupted)))
        #expect(earlier.interrupted)
        // Accepted counts as undetected before (docs/reports.md)
        #expect(earlier.undetected == [interrupted.results[1].mutant.key, interrupted.results[3].mutant.key])
        #expect(earlier.unknown == ["A.swift::trial()::boundary::1", "A.swift::trial()::boundary::2", interrupted.results[2].mutant.key, interrupted.results[4].mutant.key])
        // A complete report knows everything
        let complete = try Gate.earlierReport(JSONEncoder().encode(JSONReport(report: report([(.killed, "A.swift"), (.survived, "A.swift")]))))
        #expect(!complete.interrupted)
        #expect(complete.unknown.isEmpty)
    }

    /// An entry of the earlier report that cannot be read is skipped; the entries after it still count.
    @Test func aBrokenEntryOfTheEarlierReportIsSkipped() throws {
        let data = Data(#"{"keyVersion": 2, "results": [{"mutant": {"key": "a"}}, {"status": "Survived", "mutant": {"key": "b"}}, {"status": "Survived"}, {"status": "NotReached", "mutant": {"key": "c"}}]}"#.utf8)
        #expect(try Gate.undetectedKeys(inReport: data) == ["b", "c"])
    }

    /// The list of new undetected mutants is cut after ten, and says so.
    @Test func theListOfNewUndetectedMutantsIsCutAfterTen() {
        let eleven = report(Array(repeating: (MutantStatus.survived, "A.swift"), count: 11))
        let ten = report(Array(repeating: (MutantStatus.survived, "A.swift"), count: 10))
        #expect(Gate(earlierUndetected: []).evaluate(eleven).first?.message.hasSuffix("…") == true)
        #expect(Gate(earlierUndetected: []).evaluate(eleven).first?.message.contains("11 mutants") == true)
        #expect(Gate(earlierUndetected: []).evaluate(ten).first?.message.hasSuffix("…") == false)
    }

    // MARK: The accepted file

    @Test func theAcceptedFileRecordsTheKeyScheme() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("xcmutate.accepted.json")
            // Written by hand: no keyVersion
            try Data(#"{"version": 1, "accepted": [{"key": "A.swift::f()::boundary::0123456789abcdef", "reason": "r", "acceptedAt": "2026-11-20T00:00:00Z"}]}"#.utf8).write(to: url)
            var file = try AcceptedFile.load(url)
            #expect(file.keyVersion == nil)
            file.accepted = [AcceptedFile.Entry(key: "k", reason: "r", location: nil, acceptedAt: "2026-11-22T00:00:00Z")]
            try file.save(url)
            let saved = try AcceptedFile.load(url)
            #expect(saved.keyVersion == MutantKeyScheme.version)
        }
    }
}
