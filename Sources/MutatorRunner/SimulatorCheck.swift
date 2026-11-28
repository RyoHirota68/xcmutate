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
            matches = matches.filter { runtimeVersion($0.runtime) == os }
        }
        return matches.count == 1 ? matches[0].device : nil
    }

    /// The simulators that a destination by name (`platform=… Simulator,name=…[,OS=…]`) matches; nil when it is not
    /// such a destination. More than one, or none, means that the destination does not name one simulator here.
    public static func candidates(forDestination destination: String, simctlJSON: Data) -> [Device]? {
        let fields = fields(ofDestination: destination)
        guard fields["id"] == nil, let name = fields["name"], let platform = fields["platform"], platform.hasSuffix("Simulator"),
              let root = try? JSONSerialization.jsonObject(with: simctlJSON) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        var result: [Device] = []
        for (runtime, devices) in runtimes {
            if let os = fields["OS"], os != "latest", runtimeVersion(runtime) != os { continue }
            for entry in devices where entry["name"] as? String == name && (entry["isAvailable"] as? Bool) != false {
                if let udid = entry["udid"] as? String { result.append(Device(udid: udid, name: name, state: entry["state"] as? String ?? "")) }
            }
        }
        return result.sorted { $0.udid < $1.udid }
    }

    /// Why `--workers` cannot create simulators like the one of a destination by name, or nil when it names one.
    public static func workersRefusal(forDestination destination: String, simctlJSON: Data) -> String? {
        guard let found = candidates(forDestination: destination, simctlJSON: simctlJSON), found.count != 1 else { return nil }
        if found.isEmpty {
            return "--workers: the destination \(destination) names no simulator on this Mac (`xcrun simctl list devices` lists them); give one that exists, by its name and OS or as id=<UDID>"
        }
        return "--workers: the destination \(destination) names \(found.count) simulators on this Mac (\(found.map { "\($0.udid) \($0.state)" }.joined(separator: ", "))), so it is not known which one to create workers like; give one of them as id=<UDID>, or add OS=<version>"
    }

    /// The OS version of a runtime identifier: `com.apple.CoreSimulator.SimRuntime.iOS-18-0` → `18.0`. Some runtimes
    /// carry more after the version (`…SimRuntime.iOS-27-2-iPhone19-4`); the version is the numbers after the platform.
    static func runtimeVersion(_ runtime: String) -> String? {
        guard let last = runtime.split(separator: ".").last else { return nil }
        let numbers = last.split(separator: "-").dropFirst().prefix { $0.allSatisfy(\.isNumber) }
        return numbers.isEmpty ? nil : numbers.joined(separator: ".")
    }

    /// A destination that names the simulator `udid` by its name and OS version (`platform=iOS Simulator,name=iPhone
    /// 16,OS=18.0`), which works on another Mac with a simulator of that name, unlike its UDID; nil when that would
    /// not name this one simulator (another simulator has the same name and version, or the runtime is not known).
    public static func destinationByName(udid: String, simctlJSON: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: simctlJSON) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        for (runtime, devices) in runtimes {
            guard let entry = devices.first(where: { ($0["udid"] as? String)?.caseInsensitiveCompare(udid) == .orderedSame }),
                  let name = entry["name"] as? String, !name.contains(","), let version = runtimeVersion(runtime),
                  let platform = runtime.split(separator: ".").last?.split(separator: "-").first else { continue }
            let os = platform == "xrOS" ? "visionOS" : String(platform)
            let destination = "platform=\(os) Simulator,name=\(name),OS=\(version)"
            return device(forDestination: destination, simctlJSON: simctlJSON)?.udid.caseInsensitiveCompare(udid) == .orderedSame ? destination : nil
        }
        return nil
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
