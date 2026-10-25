import Darwin
import Foundation
import os

public enum Identity {
    /// Reverse-DNS identifier: unified-log subsystem and LaunchAgent label.
    public static let identifier = "io.github.manuelminelle.tmskipper"
    public static let version = "0.1.0"

    /// `~/Library/Application Support/TMSkipper`, created on demand.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "TMSkipper")
    }
}

/// Unified logging. Read it with: /usr/bin/log show --last 1d --predicate 'subsystem == "io.github.manuelminelle.tmskipper"'
public enum Log {
    public static let scan = Logger(subsystem: Identity.identifier, category: "scan")
}

/// A non-blocking exclusive lock, so a scheduled scan and a manual one never run together.
public final class ScanLock {
    private let descriptor: Int32

    /// nil if another process holds the lock.
    public init?() throws {
        try FileManager.default.createDirectory(at: Identity.supportDirectory, withIntermediateDirectories: true)
        let path = Identity.supportDirectory.appending(path: "scan.lock").fsPath
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Summary of the last applied scan, shown by `tmskipper status`.
public struct LastScan: Codable, Sendable {
    public var date: Date
    public var duration: TimeInterval
    public var directoriesVisited: Int
    public var excluded: Int
    public var removed: Int
    public var skipped: Int
    public var kept: Int
    public var errors: [String]

    public init(_ report: ScanReport, date: Date = Date()) {
        self.date = date
        duration = report.duration
        directoriesVisited = report.directoriesVisited
        excluded = report.excluded.count
        removed = report.removed.count
        skipped = report.skipped.count
        kept = report.kept.count
        errors = report.errors
    }

    public static var fileURL: URL { Identity.supportDirectory.appending(path: "last-scan.json") }

    public func save() throws {
        try FileManager.default.createDirectory(at: Identity.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    public static func load() -> LastScan? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastScan.self, from: data)
    }
}
