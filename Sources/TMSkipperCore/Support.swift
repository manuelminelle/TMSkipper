import Darwin
import Foundation
import os

public enum Identity {
    /// Reverse-DNS identifier: unified-log subsystem and LaunchAgent label.
    public static let identifier = "io.github.manuelminelle.tmskipper"
    public static let version = "0.2.0"

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

/// Runs a helper program (git, mdfind) and collects its standard output.
public enum Subprocess {
    /// The exit status and output, or nil if the program could not start. After `timeout` seconds
    /// the program is killed: one that never returns (huge repository, broken file system, a named
    /// pipe where a file should be) must not stall the agent.
    public static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval
    ) -> (status: Int32, data: Data)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data)
    }
}

extension String {
    /// The text with control characters (terminal escape sequences) and invisible format characters
    /// (bidirectional overrides, which reorder what is shown) replaced by "?". File names come from
    /// untrusted folders. The zero-width joiner of emoji sequences is kept: it cannot reorder text.
    public var terminalSafe: String {
        String(String.UnicodeScalarView(unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control: "?"
            case .format: scalar == "\u{200D}" ? scalar : "?"
            default: scalar
            }
        }))
    }
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

/// The roots and guarded paths of the last applied scan. When the config stops listing one, the
/// next scan still finds the exclusions TMSkipper left there and removes them, and `list` and
/// `reset` still see them.
public struct ScanLocations: Codable, Sendable, Equatable {
    public var roots: [String]
    public var guardedPaths: [String]

    public init(roots: [String] = [], guardedPaths: [String] = []) {
        self.roots = roots
        self.guardedPaths = guardedPaths
    }

    public init(_ config: Config) {
        self.init(roots: config.roots.map(\.fsPath), guardedPaths: config.guardedPaths.map(\.fsPath))
    }

    public static var fileURL: URL { Identity.supportDirectory.appending(path: "locations.json") }

    public func save() throws {
        try FileManager.default.createDirectory(at: Identity.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    public static func load() -> ScanLocations? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ScanLocations.self, from: data)
    }
}

/// For each repository holding TMSkipper exclusions, the state of its git index at the last applied
/// scan that found none of them holding tracked files. While the index stays the same, nothing new
/// can have been committed into them, and git is not asked again.
public struct VerifiedRepositories: Codable, Sendable, Equatable {
    /// Repository path → state of its index.
    public var indexes: [String: GitIndexState]

    public init(indexes: [String: GitIndexState] = [:]) {
        self.indexes = indexes
    }

    public static var fileURL: URL { Identity.supportDirectory.appending(path: "repositories.json") }

    public func save() throws {
        try FileManager.default.createDirectory(at: Identity.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    public static func load() -> VerifiedRepositories? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(VerifiedRepositories.self, from: data)
    }
}
