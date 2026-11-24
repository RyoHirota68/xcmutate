import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// `--resume` continues a journal only when everything that decides what its observations mean is unchanged.
@Suite struct ResumeFingerprintTests {
    private func configuration(_ change: (inout RunConfiguration) -> Void = { _ in }) -> RunConfiguration {
        let xcode = XcodeOptions(container: [], scheme: "S", destination: "platform=macOS", testPlan: nil, extraBuildArguments: [],
                                 extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
        var config = RunConfiguration(root: URL(fileURLWithPath: "/nonexistent/root"), files: [], changedLines: nil, onlyKeys: [], xcode: xcode,
                                      prepareCommand: nil, workDirectory: URL(fileURLWithPath: "/nonexistent/work"))
        change(&config)
        return config
    }

    private func parts(_ change: (inout RunConfiguration) -> Void = { _ in }) -> [String] {
        RunSession(config: configuration(change)).fingerprintParts([])
    }

    @Test func optionsThatDecideVerdictsAreInTheFingerprint() {
        let base = parts()
        #expect(base == parts())
        #expect(base != parts { $0.trustSharedSurvivors = true })
        #expect(base != parts { $0.sharedProcess = true })
        #expect(base != parts { $0.directLaunch = false })
        #expect(base != parts { $0.workers = 2 })
        #expect(base != parts { $0.additionalDestinations = ["id=X"] })
        #expect(base != parts { $0.confirmKills = .all })
        #expect(base != parts { $0.confirmKills = .none })
        #expect(base != parts { $0.reuse = true })
        #expect(base != parts { $0.selectTestsByReach = true })
        // With reach, whether survivors of narrowed tests are run against every test decides what a pass means
        #expect(parts { $0.selectTestsByReach = true; $0.recheckSurvivors = true } != parts { $0.selectTestsByReach = true; $0.recheckSurvivors = false })
        #expect(base != parts { $0.timeoutFactor = 5 })
        #expect(base != parts { $0.xcode.skipTesting = ["A"] })
        #expect(base != parts { $0.copyRoot = URL(fileURLWithPath: "/nonexistent") })
    }

    /// A pass that was recorded in a shared process under `--trust-shared-survivors` is not a verdict without it.
    @Test func aTrustedPassIsNotFinalWithoutTheOption() {
        let summary = TestSummary(result: "Passed", totalTestCount: 3, passedTests: 3, failedTests: 0, skippedTests: 0, expectedFailures: 0, failures: [])
        var observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: 0, timedOut: false, summary: summary, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 1, timeoutSeconds: 10)
        observation.sharedProcess = true
        #expect(!MutantExecutor.isFinal(observation, status: .survived, trustSharedSurvivors: false))
        #expect(MutantExecutor.isFinal(observation, status: .survived, trustSharedSurvivors: true))
        #expect(MutantExecutor.isFinal(observation, status: .killed, trustSharedSurvivors: false))
        observation.sharedProcess = false
        #expect(MutantExecutor.isFinal(observation, status: .survived, trustSharedSurvivors: false))
        observation.sharedProcess = nil
        #expect(MutantExecutor.isFinal(observation, status: .survived, trustSharedSurvivors: false))
    }
}
