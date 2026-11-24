import Foundation
import XCTest
@testable import StateLeak

/// A test that cleans up at its end, and therefore not when it throws half-way: the run of the mutant in
/// `Leak.parse` leaves the file behind, and the next run of the test fails on it (and removes it).
final class LeakTests: XCTestCase {
    func testParseWritesAuditLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcmutate-regression-state-leak.log")
        let line = Data("parsed\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try handle.close()
        } else {
            try line.write(to: url)
        }
        let value = try XCTUnwrap(Leak.parse("42"))
        XCTAssertEqual(value, 42)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        try FileManager.default.removeItem(at: url)
    }

    func testIsLarge() {
        XCTAssertTrue(Leak.isLarge(500))
        XCTAssertFalse(Leak.isLarge(5))
    }
}
