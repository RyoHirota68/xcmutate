import Darwin
import Foundation

/// A work copy that keeps the user's working tree clean (docs/how-it-works.md).
///
/// Only the files tracked by git and the untracked files that are not ignored (`git ls-files -co --exclude-standard`) are
/// copied, as APFS clones (`clonefile`). `.git`, `.build`, DerivedData and the like are not copied.
/// Uncommitted changes are copied as they are, so tests run against the state of the working tree.
/// Reading and writing source files as they are, byte for byte.
///
/// `String(contentsOf:)` drops a byte order mark, and the instrumented file would be written without it. Here the
/// text keeps it as its first scalar (the parser treats it as trivia), and it is written back.
public enum SourceText {
    public struct NotUTF8: Error, CustomStringConvertible {
        public var path: String
        public var description: String { "\(path) is not valid UTF-8; the compiler does not accept such a file either (convert it, or exclude it)" }
    }

    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // Decoding repairs invalid bytes; the text is the file only if it encodes back to the same bytes
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data) else { throw NotUTF8(path: url.path) }
        return text
    }

    public static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

enum WorkCopy {
    static func create(from root: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let files = try listFiles(root: root)
        var copied = 0
        for relative in files {
            let source = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            // Skip deleted files and submodule directories
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue
                    || (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil else { continue }
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                try fm.copyItem(at: source, to: target)
            }
            copied += 1
        }
        return copied
    }

    static func listFiles(root: URL) throws -> [String] {
        let result = try Subprocess.capture(["git", "-C", root.path, "ls-files", "-z", "-co", "--exclude-standard"])
        if result.status == 0 {
            return result.output.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        }
        // Not under git: everything except directories that look like build artifacts
        let skip: Set<String> = [".git", ".build", "DerivedData", "build", ".swiftpm", "xcuserdata"]
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if skip.contains(url.lastPathComponent) { enumerator?.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return files
    }
}
