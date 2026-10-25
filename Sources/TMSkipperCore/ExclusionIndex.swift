import Foundation

/// Finds excluded items outside the roots. `cp -R`, `ditto` and `mv` carry the exclusion and the
/// marker along (verified), so a `dist` copied out as a delivery would stay out of the backups.
public protocol ExclusionIndex {
    /// Items carrying a Time Machine exclusion, or nil if the index cannot be queried.
    func excludedItems() -> [URL]?
}

/// Spotlight, which Time Machine itself queries for sticky exclusions at the start of a backup.
/// It indexes the exclusion attribute (`com_apple_backup_excludeItem`) but not hidden folders,
/// nor folders inside them or excluded from Spotlight, so it finds most copies but not all.
public struct SpotlightIndex: ExclusionIndex {
    /// Only this folder is searched: other volumes and other users' folders are left alone.
    public var scope: URL

    public init(scope: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.scope = scope
    }

    public func excludedItems() -> [URL]? {
        let arguments = ["-0", "-onlyin", scope.fsPath, "com_apple_backup_excludeItem == '*'"]
        guard let output = Subprocess.run(URL(filePath: "/usr/bin/mdfind"), arguments, timeout: 30),
              output.status == 0
        else { return nil }
        return output.data.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { $0.hasPrefix("/") }
            .map { URL(filePath: $0) }
    }
}
