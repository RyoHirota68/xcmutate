import Foundation
import MutatorCore

/// Work directories (the copy of the sources, DerivedData, results, logs, journal and reports of `run`).
///
/// The default location is `~/Library/Caches/xcmutate/<hash of --root>.noindex`: one per root, so a
/// worktree-per-branch workflow leaves one behind for every worktree. `xcmutate clean` removes them.
/// The name ends in `.noindex` so that Spotlight does not index the copy and the build products.
public enum WorkDirectoryInfo {
    /// Marker file written into every work directory. `clean` refuses to delete a directory without it
    /// (unless it is under the default cache root), so a mistyped `--work-dir` cannot delete something else.
    public static let fileName = ToolNaming.workDirectoryMarkerFileName

    public struct Info: Codable, Sendable {
        public var tool: String
        public var toolVersion: String
        /// The `--root` this directory was used for.
        public var root: String
        public var lastUsedAt: String
    }

    public struct Entry: Sendable {
        public var url: URL
        public var info: Info?
        public var sizeBytes: Int64
        /// The root no longer exists (e.g. a removed worktree).
        public var isOrphan: Bool { info.map { !FileManager.default.fileExists(atPath: $0.root) } ?? false }
    }

    public static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/" + ToolNaming.cacheDirectoryName)
    }

    public static func defaultDirectory(forRoot root: URL) -> URL {
        cacheRoot.appendingPathComponent(String(stableHash(root.path), radix: 16) + ".noindex")
    }

    /// Hash that does not change between runs (FNV-1a).
    public static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func write(to directory: URL, root: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = Info(tool: ToolInfo.name, toolVersion: ToolInfo.version, root: root.path,
                        lastUsedAt: ISO8601DateFormatter().string(from: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(info).write(to: directory.appendingPathComponent(fileName))
    }

    public static func read(_ directory: URL) -> Info? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    public static func isUnderCacheRoot(_ directory: URL) -> Bool {
        let root = CanonicalPath.of(cacheRoot) + "/"
        return CanonicalPath.of(directory).hasPrefix(root)
    }

    /// Whether the directory is one of the tool's own: under the default cache root, or with a marker file that
    /// this tool wrote. `run` empties such a directory and `clean` deletes it; neither touches any other.
    public static func isOwn(_ directory: URL) -> Bool {
        isUnderCacheRoot(directory) || read(directory)?.tool == ToolInfo.name
    }

    /// Whether `clean` may delete this directory.
    public static func isRemovable(_ directory: URL) -> Bool { isOwn(directory) }

    public static func entry(_ directory: URL) -> Entry {
        Entry(url: directory, info: read(directory), sizeBytes: size(of: directory))
    }

    /// Every directory under the default cache root (including those made by versions before `.noindex`).
    public static func listDefault() -> [Entry] {
        let children = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }.map(entry)
    }

    /// Disk usage in bytes (`du -sk`; APFS clones are counted at their full size, so this is an upper bound).
    public static func size(of directory: URL) -> Int64 {
        guard let result = try? Subprocess.capture(["/usr/bin/du", "-sk", directory.path], timeout: 600),
              let first = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first, let kilobytes = Int64(first) else { return 0 }
        return kilobytes * 1024
    }

    public static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// One spelling for a path, whether or not what it names exists yet.
///
/// `URL.standardizedFileURL` and `resolvingSymlinksInPath()` rewrite `/private/tmp/x` to `/tmp/x` only when `x`
/// exists. A work directory that the first run creates therefore had one path in that run and another in the next
/// (`--resume` compares paths and refused), and a path that does not exist yet did not compare as lying inside a
/// directory that does. Here the deepest existing directory is resolved with `realpath` and the rest is appended.
public enum CanonicalPath {
    public static func of(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let base = realpath(existing.path, &buffer) != nil
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : existing.path
        return rest.reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
    }
}

/// The lock files that `xcodebuild` leaves in the temporary directory for the package state of a DerivedData directory
/// (`<path of SourcePackages with / as _>_Package.resolved.lock`, `…_workspace-state.json.lock`): a pair per DerivedData
/// directory, which `xcodebuild` never removes. Only the names made from the given directory are touched.
public enum PackageLockFiles {
    static func names(derivedData: URL, among names: [String]) -> [String] {
        let paths = Set([derivedData.standardizedFileURL.path, derivedData.resolvingSymlinksInPath().path, CanonicalPath.of(derivedData)])
        let prefixes = paths.map { ($0 + "/SourcePackages").replacingOccurrences(of: "/", with: "_") + "_" }
        return names.filter { name in name.hasSuffix(".lock") && prefixes.contains { name.hasPrefix($0) } }.sorted()
    }

    /// The lock files of the DerivedData directories that `xcodebuild` makes below `location` (the user default
    /// `IDECustomDerivedDataLocation`: `<location>/<name>-<hash>/SourcePackages`).
    static func names(under location: URL, among names: [String]) -> [String] {
        let paths = Set([location.standardizedFileURL.path, location.resolvingSymlinksInPath().path, CanonicalPath.of(location)])
        let prefixes = paths.map { $0.replacingOccurrences(of: "/", with: "_") + "_" }
        return names.filter { name in name.hasSuffix(".lock") && name.contains("_SourcePackages_") && prefixes.contains { name.hasPrefix($0) } }.sorted()
    }

    /// Removes those of `under(location)`, once nothing builds there any more.
    public static func remove(under location: URL) {
        let directory = FileManager.default.temporaryDirectory
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names(under: location, among: all) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes them, once nothing builds in `derivedData` any more.
    public static func remove(derivedData: URL) {
        let directory = FileManager.default.temporaryDirectory
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names(derivedData: derivedData, among: all) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
