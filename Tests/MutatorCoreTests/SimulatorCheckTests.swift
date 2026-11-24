import Foundation
@testable import MutatorRunner
import Testing

@Suite("Simulator state check")
struct SimulatorCheckTests {
    static let json = Data("""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "AAAAAAAA-0000-0000-0000-000000000001", "name": "Phone A", "state": "Shutdown", "isAvailable": true},
        {"udid": "AAAAAAAA-0000-0000-0000-000000000002", "name": "Phone B", "state": "Booted", "isAvailable": true},
        {"udid": "AAAAAAAA-0000-0000-0000-000000000003", "name": "Gone", "state": "Shutdown", "isAvailable": false}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
        {"udid": "AAAAAAAA-0000-0000-0000-000000000004", "name": "Phone A", "state": "Booted", "isAvailable": true}
      ]
    }}
    """.utf8)

    @Test func findsTheDeviceById() {
        let device = SimulatorCheck.device(forDestination: "id=aaaaaaaa-0000-0000-0000-000000000001", simctlJSON: Self.json)
        #expect(device == SimulatorCheck.Device(udid: "AAAAAAAA-0000-0000-0000-000000000001", name: "Phone A", state: "Shutdown"))
        #expect(SimulatorCheck.device(forDestination: "platform=iOS Simulator, id=AAAAAAAA-0000-0000-0000-000000000002", simctlJSON: Self.json)?.isBooted == true)
    }

    @Test func findsTheDeviceByNameOnlyWhenItIsUnambiguous() {
        #expect(SimulatorCheck.device(forDestination: "platform=iOS Simulator,name=Phone B", simctlJSON: Self.json)?.udid.hasSuffix("2") == true)
        // Two runtimes have a "Phone A": undecided without OS, decided with it.
        #expect(SimulatorCheck.device(forDestination: "platform=iOS Simulator,name=Phone A", simctlJSON: Self.json) == nil)
        #expect(SimulatorCheck.device(forDestination: "platform=iOS Simulator,name=Phone A,OS=18.0", simctlJSON: Self.json)?.udid.hasSuffix("1") == true)
        #expect(SimulatorCheck.device(forDestination: "platform=iOS Simulator,name=Phone A,OS=17.5", simctlJSON: Self.json)?.udid.hasSuffix("4") == true)
    }

    @Test func undecidedDestinationsGiveNothing() {
        for destination in ["platform=macOS", "generic/platform=iOS Simulator", "id=00008030-000000000000002E", "platform=iOS,name=Phone B",
                            "platform=iOS Simulator,name=Nobody", "platform=iOS Simulator,name=Gone", "id=AAAAAAAA-0000-0000-0000-000000000003"] {
            #expect(SimulatorCheck.device(forDestination: destination, simctlJSON: Self.json) == nil, "\(destination)")
        }
        #expect(SimulatorCheck.device(forDestination: "id=AAAAAAAA-0000-0000-0000-000000000001", simctlJSON: Data("not json".utf8)) == nil)
    }

    @Test func warnsOnlyWhenNotBooted() throws {
        let shutdown = try #require(SimulatorCheck.device(forDestination: "id=AAAAAAAA-0000-0000-0000-000000000001", simctlJSON: Self.json))
        let message = try #require(SimulatorCheck.warning(for: shutdown))
        #expect(message.contains("is not booted (state: Shutdown)"))
        #expect(message.contains("shuts it down again"))
        #expect(message.hasSuffix("xcrun simctl boot AAAAAAAA-0000-0000-0000-000000000001"))
        let booted = try #require(SimulatorCheck.device(forDestination: "id=AAAAAAAA-0000-0000-0000-000000000002", simctlJSON: Self.json))
        #expect(SimulatorCheck.warning(for: booted) == nil)
    }
}
