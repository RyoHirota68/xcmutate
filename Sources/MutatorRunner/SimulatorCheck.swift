import Foundation
import MutatorCore

/// Looks up whether the iOS simulator named by `--destination` is booted, so that `run` can warn before a slow run.
///
/// When the simulator is not booted, `xcodebuild test-without-building` boots it for each invocation and shuts it
/// down again afterwards, which was measured at about 26 s per mutant instead of about 5 s. This type only reads
/// `xcrun simctl list devices -j`. It never boots or shuts down anything: on a shared machine the simulator may
/// belong to someone else.
public enum SimulatorCheck {
    public struct Device: Equatable, Sendable {
        public var udid: String
        public var name: String
        public var state: String
        public var isBooted: Bool { state == "Booted" }
    }

    /// The key-value pairs of an `xcodebuild -destination` value (`platform=iOS Simulator,name=iPhone 16,OS=18.0`).
    static func fields(ofDestination destination: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in destination.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// The one simulator that the destination names, or `nil` when it cannot be decided: the destination is not a
    /// simulator (macOS, a physical device, `generic/…`), the id is not a known simulator, or a name matches
    /// no device or more than one.
    public static func device(forDestination destination: String, simctlJSON: Data) -> Device? {
        guard let root = try? JSONSerialization.jsonObject(with: simctlJSON) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        let fields = fields(ofDestination: destination)
        var candidates: [(runtime: String, device: Device)] = []
        for (runtime, devices) in runtimes {
            for entry in devices {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String, let state = entry["state"] as? String,
                      (entry["isAvailable"] as? Bool) != false else { continue }
                candidates.append((runtime, Device(udid: udid, name: name, state: state)))
            }
        }
        if let id = fields["id"] {
            return candidates.first { $0.device.udid.caseInsensitiveCompare(id) == .orderedSame }?.device
        }
        guard let name = fields["name"], let platform = fields["platform"], platform.hasSuffix("Simulator") else { return nil }
        var matches = candidates.filter { $0.device.name == name }
        if let os = fields["OS"], os != "latest" {
            // Runtime identifiers look like `com.apple.CoreSimulator.SimRuntime.iOS-18-0`.
            let suffix = "-" + os.replacingOccurrences(of: ".", with: "-")
            matches = matches.filter { $0.runtime.hasSuffix(suffix) }
        }
        return matches.count == 1 ? matches[0].device : nil
    }

    /// The warning for a simulator that is not booted; `nil` when it is booted.
    public static func warning(for device: Device) -> String? {
        guard !device.isBooted else { return nil }
        return """
        warning: the simulator \(device.name) (\(device.udid)) is not booted (state: \(device.state)). \
        xcodebuild boots a simulator that is not running for each test run and shuts it down again afterwards, \
        so every mutant pays for a boot and the run becomes several times slower. Boot it first and leave it running: \
        xcrun simctl boot \(device.udid)
        """
    }

    /// The platform that a destination builds for, or nil when it cannot be told: `platform=macOS`,
    /// `platform=iOS Simulator,…`, `generic/platform=iOS`, or `id=<UDID>` of a simulator (its runtime says which).
    /// The id of a Mac or of a physical device is not looked up.
    public static func platform(forDestination destination: String, simctlJSON: () -> Data?) -> TargetPlatform? {
        var fields = fields(ofDestination: destination)
        if let generic = fields["generic/platform"] { fields["platform"] = generic }
        if let platform = fields["platform"] { return TargetPlatform(destinationPlatform: platform, variant: fields["variant"]) }
        guard let id = fields["id"], let data = simctlJSON(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        for (runtime, devices) in runtimes where devices.contains(where: { ($0["udid"] as? String)?.caseInsensitiveCompare(id) == .orderedSame }) {
            // `com.apple.CoreSimulator.SimRuntime.iOS-18-0`
            guard let name = runtime.split(separator: ".").last?.split(separator: "-").first else { return nil }
            let os = name == "xrOS" ? "visionOS" : String(name)
            return TargetPlatform(destinationPlatform: os + " Simulator")
        }
        return nil
    }

    public static func platform(forDestination destination: String) -> TargetPlatform? {
        platform(forDestination: destination) {
            (try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"], timeout: 60)).flatMap { $0.status == 0 ? Data($0.output.utf8) : nil }
        }
    }

    /// The simulator that the destination names, read from `xcrun simctl list devices -j`; nil if it is not one simulator.
    public static func simulator(forDestination destination: String) -> Device? {
        let fields = fields(ofDestination: destination)
        guard fields["id"] != nil || fields["name"] != nil else { return nil }
        guard let result = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"], timeout: 60), result.status == 0 else { return nil }
        return device(forDestination: destination, simctlJSON: Data(result.output.utf8))
    }

    /// Reads the simulator list and returns the warning, if any. Any failure (no `simctl`, a timeout) means no warning.
    public static func warning(forDestination destination: String) -> String? {
        let fields = fields(ofDestination: destination)
        guard fields["id"] != nil || fields["name"] != nil else { return nil }
        guard let result = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"], timeout: 60), result.status == 0,
              let device = device(forDestination: destination, simctlJSON: Data(result.output.utf8)) else { return nil }
        return warning(for: device)
    }
}
