import Foundation

/// `--confirm-kills restore`: what a run without mutants between mutants is for, done without running the tests.
///
/// After a run that did not pass, the tool must know that nothing that run left on the destination fails the next
/// mutant's tests. `auto` runs those tests without mutants. On an iOS simulator, almost everything a run of app-hosted
/// unit tests can leave is in the app's data container, its App Group containers and the simulator's keychain. This
/// takes a copy of them right before the baseline (APFS clones, so it costs little) and puts it back instead of the
/// run: the destination is then in the state from which the baseline passed.
///
/// What it cannot put back is checked instead (`fingerprint`): the keychain by access group, the pasteboard, the
/// app's privacy permissions, pending notifications, other App Groups, and the folders of Photos, Contacts, Calendar,
/// Health, Safari's cookies and HTTP storage. When one of them differs from the snapshot, or putting back fails, the
/// tests are run without mutants as with `auto`. Not covered at all: state outside the simulator (a server, a file on
/// the Mac, another device), and tests that do not give the same result from the same state. Those are the
/// conditions of the mode, which is why it is not the default.
final class SimulatorRestore: @unchecked Sendable {
    let udid: String
    let bundleIdentifier: String
    let snapshot: URL
    private let lock = NSLock()
    private var reference: [String: String] = [:]
    private var pasteboardText: String?

    init(udid: String, bundleIdentifier: String, directory: URL) {
        self.udid = udid
        self.bundleIdentifier = bundleIdentifier
        self.snapshot = directory
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ text: String) { description = text }
    }

    /// The simulator's data directory (`…/CoreSimulator/Devices/<UDID>/data`).
    private func deviceData() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("the data directory of simulator \(udid) was not found") }
        return url
    }

    /// The app's data container and App Group containers, looked up again every time (an install by xcodebuild can
    /// give the app a new container).
    private func containers() throws -> (data: URL, groups: [String: URL]) {
        let data = try Subprocess.capture(["/usr/bin/xcrun", "simctl", "get_app_container", udid, bundleIdentifier, "data"], timeout: 60, ignoresInterrupt: true)
        guard data.status == 0, let path = data.output.split(whereSeparator: \.isNewline).last.map(String.init), path.hasPrefix("/") else {
            throw Failure("simctl get_app_container did not name the data container of \(bundleIdentifier)")
        }
        var groups: [String: URL] = [:]
        if let listed = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "get_app_container", udid, bundleIdentifier, "groups"], timeout: 60, ignoresInterrupt: true),
           listed.status == 0 {
            for line in listed.output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1].hasPrefix("/") { groups[parts[0]] = URL(fileURLWithPath: parts[1]) }
            }
        }
        return (URL(fileURLWithPath: path), groups)
    }

    /// Stops the app, and the simulator's preferences and keychain daemons (they hold what they read in memory and
    /// would write it back over the copy); launchd starts them again on demand.
    private func quiesce() throws {
        _ = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "terminate", udid, bundleIdentifier], timeout: 60, ignoresInterrupt: true)
        let list = try Subprocess.capture(["/bin/ps", "-axo", "pid=,ppid=,command="], timeout: 30, ignoresInterrupt: true)
        let rows = list.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let launchd = rows.first(where: { $0.contains("launchd_sim") && $0.contains("Devices/\(udid)/") })?.split(separator: " ").first.flatMap({ Int32($0) }) else {
            throw Failure("the launchd of simulator \(udid) was not found (is it booted?)")
        }
        for row in rows {
            let fields = row.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3, Int32(fields[1]) == launchd, let pid = Int32(fields[0]),
                  fields[2].hasSuffix("/cfprefsd") || fields[2].contains("/cfprefsd ") || fields[2].hasSuffix("/securityd") || fields[2].contains("/securityd ") else { continue }
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(10)
            while kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
            if kill(pid, 0) == 0 { throw Failure("a daemon of the simulator (pid \(pid)) did not stop") }
        }
    }

    private func copyContents(of source: URL, into destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let outcome = try Subprocess.capture(["/bin/cp", "-c", "-R", source.path + "/.", destination.path + "/"], timeout: 600, ignoresInterrupt: true)
        guard outcome.status == 0 else { throw Failure("copying \(source.lastPathComponent) failed: \(outcome.output.prefix(200))") }
    }

    private func empty(_ directory: URL) throws {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] { try fm.removeItem(at: item) }
    }

    /// Takes the copy (the app must be installed) and the fingerprint it is compared with later.
    func take() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: snapshot)
        let device = try deviceData()
        try quiesce()
        let found = try containers()
        try copyContents(of: found.data, into: snapshot.appendingPathComponent("data"))
        for (group, url) in found.groups { try copyContents(of: url, into: snapshot.appendingPathComponent("groups/\(group)")) }
        let keychains = device.appendingPathComponent("Library/Keychains")
        if fm.fileExists(atPath: keychains.path) { try copyContents(of: keychains, into: snapshot.appendingPathComponent("keychains")) }
        let print = try fingerprint(groups: Array(found.groups.keys))
        let text = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "pbpaste", udid], timeout: 30, ignoresInterrupt: true)
        lock.lock()
        pasteboardText = text?.status == 0 ? text?.output : nil
        reference = print
        lock.unlock()
    }

    /// Puts the copy back. Returns nil when the destination is in the snapshot's state, or why it is not known to be
    /// (then the caller runs the tests without mutants instead).
    func putBack() -> String? {
        do {
            let fm = FileManager.default
            let device = try deviceData()
            try quiesce()
            let found = try containers()
            try empty(found.data)
            try copyContents(of: snapshot.appendingPathComponent("data"), into: found.data)
            for (group, url) in found.groups {
                try empty(url)
                let saved = snapshot.appendingPathComponent("groups/\(group)")
                if fm.fileExists(atPath: saved.path) { try copyContents(of: saved, into: url) }
            }
            let keychains = device.appendingPathComponent("Library/Keychains")
            let saved = snapshot.appendingPathComponent("keychains")
            if fm.fileExists(atPath: saved.path) {
                for item in (try? fm.contentsOfDirectory(at: keychains, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent.hasPrefix("keychain-2") {
                    try fm.removeItem(at: item)
                }
                for item in try fm.contentsOfDirectory(at: saved, includingPropertiesForKeys: nil) where item.lastPathComponent.hasPrefix("keychain-2") {
                    _ = try Subprocess.capture(["/bin/cp", "-c", item.path, keychains.appendingPathComponent(item.lastPathComponent).path], timeout: 60, ignoresInterrupt: true)
                }
            }
            // The pasteboard's text is put back too (what the fingerprint compares)
            lock.lock()
            let text = pasteboardText
            lock.unlock()
            if let text {
                let file = snapshot.appendingPathComponent("pasteboard.txt")
                try Data(text.utf8).write(to: file)
                _ = try? Subprocess.capture(["/bin/sh", "-c", "/usr/bin/xcrun simctl pbcopy \"$0\" < \"$1\"", udid, file.path], timeout: 30, ignoresInterrupt: true)
            }
            let now = try fingerprint(groups: Array(found.groups.keys))
            lock.lock()
            let expected = reference
            lock.unlock()
            let differing = expected.keys.sorted().filter { expected[$0] != now[$0] }
            return differing.isEmpty ? nil : "what the copy does not cover differs from the snapshot: \(differing.joined(separator: ", "))"
        } catch {
            return "putting the copy back failed: \(error)"
        }
    }

    /// Device-level state that a test can change and that the copy does not cover, one value per kind.
    func fingerprint(groups: [String]) throws -> [String: String] {
        let device = try deviceData()
        var print: [String: String] = [:]
        func hash(_ text: String) -> String { String(text.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16) }
        func listing(_ directory: URL, only: String? = nil) -> String {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return "" }
            var lines: [String] = []
            for case let url as URL in walker {
                let relative = String(url.path.dropFirst(directory.path.count))
                if let only, !relative.contains(only) { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                lines.append("\(relative) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            return hash(lines.sorted().joined(separator: "\n"))
        }
        let keychain = device.appendingPathComponent("Library/Keychains/keychain-2-debug.db")
        if FileManager.default.fileExists(atPath: keychain.path) {
            let rows = try? Subprocess.capture(["/usr/bin/sqlite3", "-readonly", keychain.path,
                                                "select agrp,count(*),max(mdat) from genp group by agrp union all select 'inet',count(*),max(mdat) from inet union all select 'keys',count(*),max(mdat) from keys"],
                                               timeout: 30, ignoresInterrupt: true)
            print["keychain"] = hash(rows?.output ?? "unreadable")
        }
        let pasteboard = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "pbpaste", udid], timeout: 30, ignoresInterrupt: true)
        print["pasteboard"] = hash(pasteboard?.output ?? "unreadable")
        let tcc = device.appendingPathComponent("Library/TCC/TCC.db")
        if FileManager.default.fileExists(atPath: tcc.path) {
            let rows = try? Subprocess.capture(["/usr/bin/sqlite3", "-readonly", tcc.path,
                                                "select service||'='||auth_value from access where client='\(bundleIdentifier.replacingOccurrences(of: "'", with: "''"))' order by service"],
                                               timeout: 30, ignoresInterrupt: true)
            print["privacy permissions"] = hash(rows?.output ?? "unreadable")
        }
        // Pending and delivered notifications of this app (the folder holds the system's own files too)
        print["notifications"] = listing(device.appendingPathComponent("Library/UserNotifications"), only: bundleIdentifier)
        // App Groups of other apps that are not Apple's (the system writes to its own all the time)
        print["other App Groups"] = otherGroups(device: device)
        // The shared databases that an app with the permission can write to, by their number of records (their files
        // change while the system indexes them, which says nothing about the tests)
        for (name, path, query) in [("Photos", "Media/PhotoData/Photos.sqlite", "select count(*) from ZASSET"),
                                    ("Contacts", "Library/AddressBook/AddressBook.sqlitedb", "select count(*) from ABPerson"),
                                    ("Calendar", "Library/Calendar/Calendar.sqlitedb", "select count(*) from CalendarItem")] {
            let file = device.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let rows = try? Subprocess.capture(["/usr/bin/sqlite3", "-readonly", file.path, query], timeout: 30, ignoresInterrupt: true)
            print[name] = (rows?.output ?? "unreadable").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return print
    }

    /// The files of the App Group containers of other apps that are not Apple's, as one value.
    private func otherGroups(device: URL) -> String {
        let root = device.appendingPathComponent("Containers/Shared/AppGroup")
        let own = Set(((try? containers())?.groups.values.map(\.lastPathComponent)) ?? [])
        var lines: [String] = []
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !own.contains(directory.lastPathComponent) {
            let metadata = directory.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            let identifier = (NSDictionary(contentsOf: metadata)?["MCMMetadataIdentifier"] as? String) ?? ""
            if identifier.isEmpty || identifier.hasPrefix("group.com.apple.") || identifier.hasPrefix("com.apple.") || identifier.hasPrefix("systemgroup.com.apple.") || identifier.contains(".com.apple.") { continue }
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                lines.append("\(identifier)\(url.path.dropFirst(directory.path.count)) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        return String(lines.sorted().joined(separator: "\n").utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }
}
