import Foundation
@testable import TMSkipperCore

/// A temporary folder tree, deleted when released.
final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
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

    func isExcluded(_ url: URL) -> Bool { exclusions[url.fsPath] != nil }
    func marker(of url: URL) -> String? { exclusions[url.fsPath] ?? nil }
    func exclude(_ url: URL, marker: String) throws { exclusions[url.fsPath] = .some(marker) }
    func include(_ url: URL) throws { exclusions[url.fsPath] = nil }

    func excludeByOthers(_ url: URL) { exclusions[url.fsPath] = .some(nil) }
    var excludedPaths: Set<String> { Set(exclusions.keys) }
}

/// Git stand-in: folders listed in `tracked` contain tracked files.
struct FakeGit: GitClient {
    var tracked: Set<String> = []
    var ignored: [String: [String]] = [:]

    func hasTrackedFiles(in folder: URL, repository: URL) -> Bool? { tracked.contains(folder.fsPath) }
    func ignoredDirectories(in repository: URL) -> [String]? { ignored[repository.fsPath] ?? [] }
}
