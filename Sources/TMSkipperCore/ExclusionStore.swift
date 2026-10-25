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
///
/// Every write goes to an item opened without following symbolic links. The Foundation setter takes
/// a path and follows a symbolic link at its end (verified): a folder replaced by a link between the
/// scan's checks and the write would otherwise get the marker while the link's target got the
/// exclusion, leaving an exclusion that `list` and `reset` cannot see, and removing one would clear
/// the target's exclusion, made by someone else.
public struct SystemExclusionStore: ExclusionStore {
    public static let markerAttribute = "io.github.manuelminelle.tmskipper.rule"

    /// Called right before the Foundation setter runs. Tests use it to replace the item mid-write.
    var willSetExclusion: (() -> Void)?

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
        try withItem(url) { item in
            let bytes = Array(marker.utf8)
            guard fsetxattr(item.descriptor, Self.markerAttribute, bytes, bytes.count, 0, 0) == 0 else { throw Self.lastError() }
            do {
                try setExcluded(item, true)
            } catch {
                fremovexattr(item.descriptor, Self.markerAttribute, 0)
                throw error
            }
        }
    }

    public func include(_ url: URL) throws {
        try withItem(url) { item in
            try setExcluded(item, false)
            if fremovexattr(item.descriptor, Self.markerAttribute, 0) != 0 && errno != ENOATTR { throw Self.lastError() }
        }
    }

    /// An item opened without following a symbolic link: its descriptor stays on the same item
    /// whatever happens to the path.
    private struct OpenItem {
        var descriptor: Int32
        var device: dev_t
        var inode: ino_t

        /// The item's current path, following renames, or nil if it has none any more.
        var path: String? {
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }

        /// True if `path` names this item and not, say, a symbolic link put in its place.
        func isNamed(by path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && st.st_dev == device && st.st_ino == inode
        }

        var isExcluded: Bool { fgetxattr(descriptor, SystemExclusionStore.exclusionAttribute, nil, 0, 0, 0) >= 0 }
    }

    private func withItem(_ url: URL, _ body: (OpenItem) throws -> Void) throws {
        // O_NOFOLLOW refuses a symbolic link; O_NONBLOCK keeps a named pipe from blocking the open.
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw POSIXError(.ELOOP, userInfo: [NSLocalizedDescriptionKey: "it is a symbolic link"])
            }
            throw Self.lastError()
        }
        defer { close(descriptor) }
        var st = stat()
        guard fstat(descriptor, &st) == 0 else { throw Self.lastError() }
        try body(OpenItem(descriptor: descriptor, device: st.st_dev, inode: st.st_ino))
    }

    /// Sets the exclusion through Foundation on the opened item, then checks the attribute on it.
    ///
    /// The setter only takes a path, so it gets the item's current one, resolved from the descriptor
    /// right before the call: a folder renamed meanwhile is still the one written. Something put in
    /// its place within that instant could still receive the write; the check afterwards reports it.
    ///
    /// The setter is not reliable when called from several threads at once (measured: 10 failed
    /// clears out of 1,600 with 8 threads, none out of 700 on one thread). TMSkipper is
    /// single-threaded; the check is a second line of defence.
    private func setExcluded(_ item: OpenItem, _ excluded: Bool) throws {
        willSetExclusion?()
        guard let path = item.path, item.isNamed(by: path) else {
            throw POSIXError(.ENOENT, userInfo: [NSLocalizedDescriptionKey: "the item was deleted or replaced"])
        }
        var target = URL(filePath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try target.setResourceValues(values)
        guard item.isNamed(by: path) else {
            throw POSIXError(.EIO, userInfo: [
                NSLocalizedDescriptionKey: "the item was replaced while its exclusion was written: check \(path) with tmutil isexcluded",
            ])
        }
        guard item.isExcluded != excluded else { return }
        if excluded {
            throw POSIXError(.EIO, userInfo: [NSLocalizedDescriptionKey: "the exclusion attribute was not written"])
        }
        if fremovexattr(item.descriptor, Self.exclusionAttribute, 0) != 0 && errno != ENOATTR {
            throw Self.lastError()
        }
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
