import Darwin
import Foundation

/// Reads and writes Time Machine exclusions and TMSkipper's ownership marker.
public protocol ExclusionStore {
    /// True if the item itself carries a Time Machine exclusion (set by anyone).
    func isExcluded(_ url: URL) -> Bool
    /// TMSkipper's marker on the item (a rule id), or nil if TMSkipper did not exclude it.
    func marker(of url: URL) -> String?
    /// Excludes the item and records `marker` as its owner.
    func exclude(_ url: URL, marker: String) throws
    /// Removes the exclusion and the marker.
    func include(_ url: URL) throws
}

extension ExclusionStore {
    /// True if the item or one of its ancestors is excluded.
    public func isExcludedIncludingAncestors(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while true {
            if isExcluded(current) { return true }
            let parent = current.deletingLastPathComponent()
            if parent.fsPath == current.fsPath { return false }
            current = parent
        }
    }
}

/// The real store: the documented Foundation API for the exclusion, an extended attribute for the marker.
///
/// `isExcludedFromBackup` writes the same "sticky" attribute as `tmutil addexclusion`
/// in about a millisecond, instead of ~11 seconds.
public struct SystemExclusionStore: ExclusionStore {
    public static let markerAttribute = "io.github.manuelminelle.tmskipper.rule"

    public init() {}

    /// Attribute written by `isExcludedFromBackup` and `tmutil addexclusion`.
    public static let exclusionAttribute = "com.apple.metadata:com_apple_backup_excludeItem"

    /// Reads the attribute directly: right after a change, `resourceValues(forKeys:)` can return a cached value.
    public func isExcluded(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, Self.exclusionAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    public func marker(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let length = getxattr(path, Self.markerAttribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, Self.markerAttribute, &buffer, length, 0, XATTR_NOFOLLOW)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    /// Writes the marker first: if the process stops between the two writes, a marker without an
    /// exclusion is ignored by `list` and `reset` and fixed by the next scan, while an exclusion
    /// without a marker could never be listed or reset.
    public func exclude(_ url: URL, marker: String) throws {
        let bytes = Array(marker.utf8)
        let result = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path!, Self.markerAttribute, bytes, bytes.count, 0, XATTR_NOFOLLOW)
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try setExcluded(url, true)
        } catch {
            _ = url.withUnsafeFileSystemRepresentation { removexattr($0!, Self.markerAttribute, XATTR_NOFOLLOW) }
            throw error
        }
    }

    public func include(_ url: URL) throws {
        try setExcluded(url, false)
        let result = url.withUnsafeFileSystemRepresentation { path in
            removexattr(path!, Self.markerAttribute, XATTR_NOFOLLOW)
        }
        if result != 0 && errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Sets the exclusion through Foundation, then checks the attribute.
    ///
    /// The setter is not reliable when called from several threads at once (measured: 10 failed
    /// clears out of 1,600 with 8 threads, none out of 700 on one thread). TMSkipper is
    /// single-threaded; the check is a second line of defence.
    private func setExcluded(_ url: URL, _ excluded: Bool) throws {
        var target = URL(filePath: url.fsPath)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try target.setResourceValues(values)
        guard isExcluded(url) != excluded else { return }
        if excluded {
            throw POSIXError(.EIO, userInfo: [NSLocalizedDescriptionKey: "the exclusion attribute was not written"])
        }
        let result = url.withUnsafeFileSystemRepresentation { path in
            removexattr(path!, Self.exclusionAttribute, XATTR_NOFOLLOW)
        }
        if result != 0 && errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
