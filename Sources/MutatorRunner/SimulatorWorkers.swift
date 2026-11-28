import Darwin
import Foundation
import MutatorCore

/// Simulators that `run --workers N` creates for itself and removes again.
///
/// A worker simulator is a new device of the same device type and runtime as the destination the user gave. Its
/// name is `xcmutate-<pid of the run>-w<n>`, so that a later run (or `clean`) can tell which ones were left
/// behind by a run that no longer exists. The simulator the user named is never created, booted, shut down or
/// deleted by this type.
public enum SimulatorWorkers {
    public static let namePrefix = ToolNaming.toolName + "-"

    public struct Device: Equatable, Sendable {
        public var udid: String
        public var name: String
    }

    /// `xcmutate-<pid>-w<n>`
    public static func name(processID: Int32, index: Int) -> String {
        "\(namePrefix)\(processID)-w\(index)"
    }

    /// The process ID in a worker simulator's name; nil for any other name.
    public static func owner(ofName name: String) -> Int32? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let parts = name.dropFirst(namePrefix.count).split(separator: "-")
        guard parts.count == 2, parts[1].hasPrefix("w"), Int(parts[1].dropFirst()) != nil else { return nil }
        return Int32(parts[0])
    }

    /// Device type and runtime of a simulator, from `xcrun simctl list devices -j`.
    public static func template(udid: String, simctlJSON: Data) -> (deviceType: String, runtime: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: simctlJSON) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        for (runtime, devices) in runtimes {
            for entry in devices where (entry["udid"] as? String)?.caseInsensitiveCompare(udid) == .orderedSame {
                guard let type = entry["deviceTypeIdentifier"] as? String else { return nil }
                return (type, runtime)
            }
        }
        return nil
    }

    /// Worker simulators whose owning process no longer exists.
    public static func orphans(simctlJSON: Data, isAlive: (Int32) -> Bool) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: simctlJSON) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [Device] = []
        for devices in runtimes.values {
            for entry in devices {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String, let owner = owner(ofName: name),
                      !isAlive(owner) else { continue }
                result.append(Device(udid: udid, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    static func simctl(_ arguments: [String], timeout: TimeInterval = 300, ignoresInterrupt: Bool = false) -> (status: Int32, output: String)? {
        try? Subprocess.capture(["/usr/bin/xcrun", "simctl"] + arguments, timeout: timeout, ignoresInterrupt: ignoresInterrupt)
    }

    static func listJSON() -> Data? {
        guard let result = simctl(["list", "devices", "-j"], timeout: 60), result.status == 0 else { return nil }
        return Data(result.output.utf8)
    }

    /// The worker simulators left behind by runs that no longer exist (`clean --dry-run`).
    public static func orphanNames() -> [String] {
        guard let json = listJSON() else { return [] }
        return orphans(simctlJSON: json) { pid in kill(pid, 0) == 0 || errno == EPERM }.map(\.name)
    }

    /// Deletes worker simulators left behind by runs that no longer exist. Returns their names.
    @discardableResult
    public static func removeOrphans() -> [String] {
        guard let json = listJSON() else { return [] }
        let found = orphans(simctlJSON: json) { pid in kill(pid, 0) == 0 || errno == EPERM }
        for device in found { delete(device.udid) }
        return found.map(\.name)
    }

    /// Creates and boots `count` simulators like the one with `udid`. Throws if the template cannot be read or a
    /// device cannot be created; devices created before the failure are deleted.
    static func create(count: Int, like udid: String) throws -> [Device] {
        guard let json = listJSON(), let template = template(udid: udid, simctlJSON: json) else {
            throw RunError.stage("workers", "the simulator \(udid) was not found in `xcrun simctl list devices`, so no worker simulators like it can be created; give one --destination per worker instead", log: nil)
        }
        var created: [Device] = []
        for index in 1...max(count, 1) where count > 0 {
            let name = name(processID: getpid(), index: index)
            guard let result = simctl(["create", name, template.deviceType, template.runtime]), result.status == 0 else {
                created.forEach { delete($0.udid) }
                throw RunError.stage("workers", "could not create the worker simulator \(name) (\(template.deviceType), \(template.runtime))", log: nil)
            }
            let udid = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            created.append(Device(udid: udid, name: name))
        }
        for device in created {
            _ = simctl(["boot", device.udid])
            _ = simctl(["bootstatus", device.udid, "-b"], timeout: 600)
        }
        return created
    }

    // MARK: Privacy

    /// What the privacy settings of a simulator say about some apps, as `simctl privacy` actions.
    public struct Privacy: Equatable, Sendable {
        /// `(grant|revoke, service, bundle identifier)`, in the order of the database.
        public var actions: [[String]] = []
        /// Decisions that `simctl privacy` cannot make (a service it has no name for, a limited access), as
        /// `<service> for <bundle identifier>`.
        public var notCopied: [String] = []
    }

    /// TCC services by the names that `simctl privacy` uses for them. Location is not kept in the TCC database and
    /// cannot be read from it.
    static let privacyServices: [String: String] = [
        "kTCCServiceAll": "all", "kTCCServiceCalendar": "calendar", "kTCCServiceAddressBook": "contacts", "kTCCServicePhotos": "photos",
        "kTCCServicePhotosAdd": "photos-add", "kTCCServiceMediaLibrary": "media-library", "kTCCServiceMicrophone": "microphone",
        "kTCCServiceMotion": "motion", "kTCCServiceReminders": "reminders", "kTCCServiceSiri": "siri",
    ]

    /// The actions for the rows `service|client|auth_value` of a simulator's TCC database that concern `bundles`:
    /// allowed (2) is a grant, denied (0) a revoke; anything else cannot be copied.
    static func privacy(tccRows: String, bundles: [String]) -> Privacy {
        var result = Privacy()
        for line in tccRows.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, bundles.contains(fields[1]) else { continue }
            if let service = privacyServices[fields[0]], fields[2] == "2" || fields[2] == "0" {
                result.actions.append([fields[2] == "2" ? "grant" : "revoke", service, fields[1]])
            } else {
                result.notCopied.append("\(fields[0]) for \(fields[1])")
            }
        }
        return result
    }

    /// The privacy decisions of simulator `udid` (booted or not) about `bundles`, read from its TCC database without
    /// changing it; nil when the database cannot be read.
    static func privacy(of udid: String, bundles: [String]) -> Privacy? {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/Library/TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return Privacy() }   // nothing was ever decided
        guard let result = try? Subprocess.capture(["/usr/bin/sqlite3", "-readonly", database.path, "SELECT service, client, auth_value FROM access WHERE client_type = 0"], timeout: 30),
              result.status == 0 else { return nil }
        return privacy(tccRows: result.output, bundles: bundles)
    }

    /// Gives the booted simulators `targets` the privacy decisions of simulator `source` about the apps `bundles`, so
    /// that a test host there meets no permission dialog that it does not meet on `source` (a dialog over the app stops
    /// shared processes). Returns what could not be copied, nil when everything was.
    static func copyPrivacy(from source: String, to targets: [String], bundles: [String]) -> String? {
        guard !bundles.isEmpty, !targets.isEmpty else { return nil }
        guard let decisions = privacy(of: source, bundles: bundles) else {
            return "the privacy settings of \(source) could not be read"
        }
        var failed: [String] = []
        for target in targets {
            for action in decisions.actions {
                if simctl(["privacy", target, action[0], action[1], action[2]], timeout: 60)?.status != 0 { failed.append(action.joined(separator: " ")) }
            }
        }
        let problems = decisions.notCopied.map { "\($0) (not a service that simctl privacy can set)" } + failed.map { "simctl privacy \($0) failed" }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Shuts down and deletes a simulator that the tool created. This is clean-up: it runs to its end also after
    /// an interrupt (Ctrl-C), which stops every other child process.
    static func delete(_ udid: String) {
        _ = simctl(["shutdown", udid], timeout: 120, ignoresInterrupt: true)
        _ = simctl(["delete", udid], timeout: 120, ignoresInterrupt: true)
    }
}
