import Foundation
@testable import TMSkipperCore

/// A temporary folder tree, deleted when released.
final class Sandbox {
    let root: URL

    /// `base` is the temporary folder by default. macOS excludes it from backups by path, so a test
    /// that asks `tmutil isexcluded` needs another base, such as the home folder.
    init(base: URL = FileManager.default.temporaryDirectory) throws {
        root = base
            .appending(path: "tmskipper-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "") throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    func config(guarded: [String] = [], rules: [Rule] = Rule.defaults, cacheDirTag: Bool = true) -> Config {
        Config(
            roots: [url("projects")],
            rules: rules,
            cacheDirTagEnabled: cacheDirTag,
            guardedPaths: guarded.map(url)
        )
    }
}

/// In-memory exclusions, keyed by path.
final class FakeStore: ExclusionStore {
    /// Path → marker (nil for exclusions made by someone else).
    var exclusions: [String: String?] = [:]
    /// Paths whose exclusion cannot be removed.
    var failingIncludes: Set<String> = []

    func isExcluded(_ url: URL) -> Bool { exclusions[url.fsPath] != nil }
    func marker(of url: URL) -> String? { exclusions[url.fsPath] ?? nil }
    func exclude(_ url: URL, marker: String) throws { exclusions[url.fsPath] = .some(marker) }
    func include(_ url: URL) throws {
        if failingIncludes.contains(url.fsPath) { throw POSIXError(.EPERM) }
        exclusions[url.fsPath] = nil
    }

    func excludeByOthers(_ url: URL) { exclusions[url.fsPath] = .some(nil) }
    var excludedPaths: Set<String> { Set(exclusions.keys) }
}

/// Git stand-in: folders listed in `tracked` contain tracked files.
struct FakeGit: GitClient {
    var tracked: Set<String> = []
    var ignored: [String: [String]] = [:]

    func hasTrackedFiles(in folder: URL, repository: URL) -> Bool? { tracked.contains(folder.fsPath) }
    func trackedFolders(among folders: [URL], repository: URL) -> Set<String>? {
        Set(folders.map(\.fsPath)).intersection(tracked)
    }
    func ignoredDirectories(in repository: URL) -> [String]? { ignored[repository.fsPath] ?? [] }
}

/// Git stand-in that cannot answer, counting how often it is asked.
final class FailingGit: GitClient {
    var calls = 0

    func hasTrackedFiles(in folder: URL, repository: URL) -> Bool? {
        calls += 1
        return nil
    }

    func trackedFolders(among folders: [URL], repository: URL) -> Set<String>? {
        calls += 1
        return nil
    }

    func ignoredDirectories(in repository: URL) -> [String]? { nil }
}

/// Spotlight stand-in: returns `items` as excluded.
struct FakeIndex: ExclusionIndex {
    var items: [URL]
    func excludedItems() -> [URL]? { items }
}

/// Git stand-in that counts the grouped queries; folders listed in `tracked` contain tracked files.
final class CountingGit: GitClient {
    var tracked: Set<String> = []
    var groupedCalls = 0

    func hasTrackedFiles(in folder: URL, repository: URL) -> Bool? { tracked.contains(folder.fsPath) }
    func trackedFolders(among folders: [URL], repository: URL) -> Set<String>? {
        groupedCalls += 1
        return Set(folders.map(\.fsPath)).intersection(tracked)
    }
    func ignoredDirectories(in repository: URL) -> [String]? { [] }
}
