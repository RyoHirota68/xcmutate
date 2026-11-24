import Darwin
import Foundation
import MutatorCore

/// Decides whether a directory may be used as the work directory of `run`, and keeps two processes from using
/// the same one at the same time.
///
/// `run` deletes `src`, `results`, `traces` and `logs` inside its work directory at the start. A mistyped
/// `--work-dir` (`--work-dir .`, `--work-dir ~/work`) must therefore never be accepted: the directory has to be
/// missing, empty, or one that this tool made (it holds the marker file, or it is under the default cache root).
public enum WorkDirectoryGuard {
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    static func resolved(_ url: URL) -> String { CanonicalPath.of(url) }

    static func isSameOrAncestor(_ ancestor: String, of path: String) -> Bool {
        ancestor == path || ancestor == "/" || path.hasPrefix(ancestor + "/")
    }

    /// Returns why `directory` cannot be the work directory for `root`, or nil if it can.
    /// - Parameter ignoredByGit: whether git ignores a path inside the copied tree (the copy holds every file that
    ///   git does not ignore, so a work directory there must be ignored, or the copy would contain itself).
    public static func refusal(directory: URL, root: URL, copyRoot: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               ignoredByGit: (String) -> Bool = { _ in false }) -> Refusal? {
        let fm = FileManager.default
        let path = resolved(directory)
        let option = "--work-dir \(directory.path)"
        if path == "/" { return Refusal(description: "\(option): the file system root cannot be the work directory") }
        let homePath = resolved(home)
        if isSameOrAncestor(path, of: homePath) {
            return Refusal(description: "\(option): the home directory and the directories above it cannot be the work directory (the tool deletes src, logs, results and traces inside its work directory)")
        }
        for (name, tree) in [("--root", root), ("the repository that holds --root", copyRoot ?? root)] {
            let treePath = resolved(tree)
            if isSameOrAncestor(path, of: treePath) {
                return Refusal(description: "\(option): this is \(path == treePath ? "" : "a directory above ")\(name) (\(treePath)). The tool deletes src, logs, results and traces inside its work directory; give it a directory of its own, or leave the option out")
            }
        }
        let copyPath = resolved(copyRoot ?? root)
        if path.hasPrefix(copyPath + "/"), !isUnderBuildDirectory(String(path.dropFirst(copyPath.count + 1))), !ignoredByGit(path) {
            return Refusal(description: "\(option): the directory is inside the tree that is copied (\(copyPath)) and git does not ignore it, so the copy would contain the work directory. Use a directory that git ignores (for example under .build/) or one outside the repository")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return Refusal(description: "\(option): this is a file, not a directory") }
        // The same rule as `clean`: a marker file that another tool wrote (or that says so) does not make the directory ours
        if WorkDirectoryInfo.isOwn(directory) { return nil }
        let contents = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".DS_Store" }
        if contents.isEmpty { return nil }
        return Refusal(description: "\(option): the directory exists, is not empty and was not made by \(ToolInfo.name) (no \(WorkDirectoryInfo.fileName) inside). The tool deletes src, logs, results and traces inside its work directory, so it only uses a directory that is missing, empty or its own. Nothing was deleted")
    }

    /// Directory names that the copy never holds when the root is not under git (`WorkCopy.listFiles`).
    static func isUnderBuildDirectory(_ relative: String) -> Bool {
        let skip: Set<String> = [".git", ".build", "DerivedData", "build", ".swiftpm", "xcuserdata"]
        return relative.split(separator: "/").contains { skip.contains(String($0)) }
    }

    static func gitIgnores(_ path: String, in root: URL) -> Bool {
        guard let result = try? Subprocess.capture(["git", "-C", root.path, "check-ignore", "-q", path], timeout: 60) else { return false }
        return result.status == 0
    }
}

/// An exclusive lock on a work directory, held for as long as the process lives (`flock`; the kernel releases it
/// when the process ends, however it ends). The descriptor is close-on-exec, so no child process keeps the lock.
public final class WorkDirectoryLock {
    public static let fileName = ToolNaming.toolName + ".lock"

    public struct Busy: Error, CustomStringConvertible, Equatable {
        public var directory: String
        /// What the holder wrote into the lock file (`pid <n>, <command>, since <time>`), if it could be read.
        public var holder: String?

        public var description: String {
            "the work directory \(directory) is in use by another \(ToolInfo.name) process\(holder.map { " (\($0))" } ?? ""). Two runs in one work directory would overwrite each other's build products and results. Wait for it, stop it, or give this run its own --work-dir"
        }
    }

    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Takes the lock without waiting.
    /// - Parameter purpose: what the holder is doing (`run`, `clean`), shown to a process that finds the lock taken.
    public static func acquire(_ directory: URL, purpose: String) throws -> WorkDirectoryLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw Busy(directory: directory.path, holder: "the lock file \(path) cannot be opened: \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            close(descriptor)
            throw Busy(directory: directory.path, holder: holder.flatMap { $0.isEmpty ? nil : $0 })
        }
        ftruncate(descriptor, 0)
        let text = "pid \(getpid()), \(ToolInfo.name) \(purpose), since \(ISO8601DateFormatter().string(from: Date()))\n"
        _ = text.withCString { write(descriptor, $0, strlen($0)) }
        return WorkDirectoryLock(descriptor: descriptor)
    }

    /// Whether another process holds the lock of `directory` (false if there is no lock file).
    public static func isHeld(_ directory: URL) -> Bool {
        let descriptor = open(directory.appendingPathComponent(fileName).path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
