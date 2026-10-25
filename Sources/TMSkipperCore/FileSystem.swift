import Darwin
import Foundation

/// `SF_DATALESS` from <sys/stat.h>: the item is a placeholder whose content lives in the cloud.
private let dataLessFlag: UInt32 = 0x4000_0000

extension URL {
    /// Absolute file-system path without a trailing slash.
    public var fsPath: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// What `lstat` says about an item. Symbolic links are never followed.
public struct ItemInfo: Sendable {
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    public var isDataless: Bool
    public var size: Int64
}

public enum FileSystem {
    /// Information about the item itself (a symbolic link is reported as such), or nil if it does not exist.
    public static func info(_ url: URL) -> ItemInfo? {
        var st = stat()
        let result = url.withUnsafeFileSystemRepresentation { lstat($0!, &st) }
        guard result == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        return ItemInfo(
            isDirectory: type == S_IFDIR,
            isRegularFile: type == S_IFREG,
            isSymbolicLink: type == S_IFLNK,
            isDataless: st.st_flags & dataLessFlag != 0,
            size: Int64(st.st_size)
        )
    }

    /// Reads at most `maxBytes` from a regular file without ever blocking.
    ///
    /// Project folders can hold anything, so named pipes, sockets and devices (which would block
    /// the scan forever), symbolic links and iCloud placeholders (which would be downloaded) are
    /// refused with nil. The type is checked on the open descriptor, so a file swapped after an
    /// earlier `lstat` is caught too.
    public static func readPrefix(of url: URL, maxBytes: Int) -> Data? {
        guard let info = info(url), info.isRegularFile, !info.isDataless else { return nil }
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & dataLessFlag == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var total = 0
        while total < maxBytes {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, maxBytes - total) }
            if count <= 0 { break }
            total += count
        }
        return Data(buffer.prefix(total))
    }

    /// A child of a directory.
    public struct Entry: Sendable {
        public var name: String
        public var url: URL
        public var isDirectory: Bool
        public var isSymbolicLink: Bool
    }

    /// Entries of a directory, hidden ones included. Symbolic links are reported, not followed.
    public static func entries(of directory: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        )
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            return Entry(
                name: url.lastPathComponent,
                url: directory.appending(path: url.lastPathComponent),
                isDirectory: !isLink && (values?.isDirectory ?? false),
                isSymbolicLink: isLink
            )
        }
    }

    /// Shell-style wildcard match ("*", "?", "[...]") of a single name.
    public static func matches(_ name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// Approximate disk usage of a directory tree (allocated size, hard links counted once per path).
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Human-readable byte count, e.g. "1.2 GB".
    public static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
