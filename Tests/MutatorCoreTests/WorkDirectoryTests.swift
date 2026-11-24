import Foundation
@testable import MutatorRunner
import Testing

/// The work directory of `run`: what it refuses to use and the lock that keeps two runs apart.
@Suite struct WorkDirectoryTests {
    /// A scratch directory (symlinks resolved, so that paths compare equal) that is removed afterwards.
    private func withScratch(_ body: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("xcmutate-workdir-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    private func make(_ url: URL, files: [String] = []) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            let target = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: target)
        }
    }

    @Test func refusesAnExistingDirectoryThatTheToolDidNotMake() throws {
        try withScratch { base in
            let root = base.appendingPathComponent("project")
            try make(root, files: ["Package.swift"])
            let other = base.appendingPathComponent("documents")
            try make(other, files: ["src/legacy.swift", "logs/audit.log"])
            let refusal = WorkDirectoryGuard.refusal(directory: other, root: root, copyRoot: nil, home: base.appendingPathComponent("home"))
            #expect(refusal?.description.contains("was not made by") == true)
            // Nothing was touched
            #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("src/legacy.swift").path))
        }
    }

    @Test func acceptsMissingEmptyAndOwnDirectories() throws {
        try withScratch { base in
            let root = base.appendingPathComponent("project")
            try make(root, files: ["Package.swift"])
            let home = base.appendingPathComponent("home")
            let missing = base.appendingPathComponent("not-there/work")
            #expect(WorkDirectoryGuard.refusal(directory: missing, root: root, copyRoot: nil, home: home) == nil)
            let empty = base.appendingPathComponent("empty")
            try make(empty)
            #expect(WorkDirectoryGuard.refusal(directory: empty, root: root, copyRoot: nil, home: home) == nil)
            let own = base.appendingPathComponent("own")
            try make(own, files: ["src/a.swift"])
            WorkDirectoryInfo.write(to: own, root: root)
            #expect(WorkDirectoryGuard.refusal(directory: own, root: root, copyRoot: nil, home: home) == nil)
        }
    }

    /// `run` and `clean` have one rule for "made by this tool": a marker file that names
    /// another tool does not make a directory ours, and its contents are not deleted.
    @Test func aMarkerFileOfAnotherToolDoesNotMakeTheDirectoryOurs() throws {
        try withScratch { base in
            let root = base.appendingPathComponent("project")
            try make(root, files: ["Package.swift"])
            let other = base.appendingPathComponent("other")
            try make(other, files: ["logs/audit.log"])
            try Data(#"{"tool": "something-else", "toolVersion": "1", "root": "/x", "lastUsedAt": "2026-01-01T00:00:00Z"}"#.utf8)
                .write(to: other.appendingPathComponent(WorkDirectoryInfo.fileName))
            #expect(!WorkDirectoryInfo.isOwn(other))
            #expect(!WorkDirectoryInfo.isRemovable(other))
            #expect(WorkDirectoryGuard.refusal(directory: other, root: root, copyRoot: nil, home: base.appendingPathComponent("home"))?.description.contains("was not made by") == true)
        }
    }

    /// A path has one spelling whether or not its last components exist: `/private/tmp/x` and
    /// `/tmp/x` are the same directory, before and after `x` is created. (`--resume` compares paths.)
    @Test func aPathIsSpelledTheSameBeforeAndAfterItExists() throws {
        let name = "xcmutate-canonical-\(UUID().uuidString)"
        let viaPrivate = URL(fileURLWithPath: "/private/tmp/\(name)/work")
        let viaLink = URL(fileURLWithPath: "/tmp/\(name)/work")
        let before = CanonicalPath.of(viaPrivate)
        #expect(before == CanonicalPath.of(viaLink))
        #expect(before == "/private/tmp/\(name)/work")
        try FileManager.default.createDirectory(at: viaPrivate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/private/tmp/\(name)")) }
        #expect(CanonicalPath.of(viaPrivate) == before)
        #expect(CanonicalPath.of(viaLink) == before)
        // A directory that does not exist yet is seen as lying inside one that does, whichever way both are written
        let root = URL(fileURLWithPath: "/tmp/\(name)")
        let inside = URL(fileURLWithPath: "/private/tmp/\(name)/work/deeper/not-there")
        #expect(WorkDirectoryGuard.isSameOrAncestor(WorkDirectoryGuard.resolved(root), of: WorkDirectoryGuard.resolved(inside)))
    }

    @Test func refusesTheRootItsAncestorsTheHomeDirectoryAndTheFileSystemRoot() throws {
        try withScratch { base in
            let repository = base.appendingPathComponent("repo")
            let root = repository.appendingPathComponent("App")
            try make(root, files: ["Package.swift"])
            let home = base.appendingPathComponent("users/me")
            try make(home)
            func refused(_ url: URL) -> Bool {
                WorkDirectoryGuard.refusal(directory: url, root: root, copyRoot: repository, home: home) != nil
            }
            #expect(refused(root))
            #expect(refused(repository))
            #expect(refused(base))
            #expect(refused(home))
            #expect(refused(home.deletingLastPathComponent()))
            #expect(refused(URL(fileURLWithPath: "/")))
            // Even with the marker file inside: the root itself is never a work directory
            WorkDirectoryInfo.write(to: root, root: root)
            #expect(refused(root))
            // A relative spelling of the root (`--work-dir .` resolved against the current directory)
            #expect(refused(root.appendingPathComponent("Sources/..")))
        }
    }

    @Test func aDirectoryInsideTheCopiedTreeMustBeIgnoredByGit() throws {
        try withScratch { base in
            let root = base.appendingPathComponent("project")
            try make(root, files: ["Package.swift"])
            let home = base.appendingPathComponent("home")
            let inside = root.appendingPathComponent("work")
            #expect(WorkDirectoryGuard.refusal(directory: inside, root: root, copyRoot: nil, home: home)?.description.contains("git does not ignore") == true)
            #expect(WorkDirectoryGuard.refusal(directory: inside, root: root, copyRoot: nil, home: home, ignoredByGit: { _ in true }) == nil)
            // `.build` is never copied, with or without git
            #expect(WorkDirectoryGuard.refusal(directory: root.appendingPathComponent(".build/mutator-work"), root: root, copyRoot: nil, home: home) == nil)
        }
    }

    @Test func theLockIsExclusiveAndReleased() throws {
        try withScratch { base in
            let directory = base.appendingPathComponent("work")
            #expect(!WorkDirectoryLock.isHeld(directory))
            let first = try WorkDirectoryLock.acquire(directory, purpose: "run")
            #expect(WorkDirectoryLock.isHeld(directory))
            #expect(throws: WorkDirectoryLock.Busy.self) { _ = try WorkDirectoryLock.acquire(directory, purpose: "run") }
            do {
                _ = try WorkDirectoryLock.acquire(directory, purpose: "run")
            } catch let busy as WorkDirectoryLock.Busy {
                #expect(busy.holder?.contains("pid \(getpid())") == true)
            }
            first.release()
            #expect(!WorkDirectoryLock.isHeld(directory))
            let second = try WorkDirectoryLock.acquire(directory, purpose: "run")
            second.release()
        }
    }

    /// A child process started while the lock is held must not keep it after the holder lets go.
    @Test func childProcessesDoNotInheritTheLock() throws {
        try withScratch { base in
            let directory = base.appendingPathComponent("work")
            let lock = try WorkDirectoryLock.acquire(directory, purpose: "run")
            let child = try Subprocess.spawn(["/bin/sleep", "20"], logPath: base.appendingPathComponent("sleep.log").path)
            defer { child.kill() }
            lock.release()
            #expect(!WorkDirectoryLock.isHeld(directory))
        }
    }
}
