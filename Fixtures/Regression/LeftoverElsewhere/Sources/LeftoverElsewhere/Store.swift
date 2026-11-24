import Foundation

/// A file that `saveCount` leaves when it is given a positive number. Only one suite of the tests removes it.
public let markerPath = NSTemporaryDirectory() + "xcmutate-regression-leftover-elsewhere.marker"

public func saveCount(_ n: Int) {
    if n > 0 { FileManager.default.createFile(atPath: markerPath, contents: nil) }
}

// The tests never try the boundaries: both mutants survive a run of all tests.
public func isBig(_ n: Int) -> Bool { n >= 1000 }
public func isSmall(_ n: Int) -> Bool { n < 3 }
