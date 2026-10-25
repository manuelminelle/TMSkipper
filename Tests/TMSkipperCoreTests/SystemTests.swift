import Foundation
import Testing
@testable import TMSkipperCore

/// Tests against the real file system attributes and the real git executable.
/// Serialized: Foundation's exclusion setter is not reliable across concurrent threads.
@Suite(.serialized) struct SystemTests {
    @Test func storeRoundTrip() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder("with spaces/node_modules")
        let store = SystemExclusionStore()

        #expect(!store.isExcluded(folder))
        try store.exclude(folder, marker: "node-modules")
        #expect(store.isExcluded(folder))
        #expect(store.marker(of: folder) == "node-modules")

        try store.include(folder)
        #expect(!store.isExcluded(folder))
        #expect(store.marker(of: folder) == nil)
    }

    @Test func exclusionIsLostWhenFolderIsRecreated() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder("node_modules")
        let store = SystemExclusionStore()
        try store.exclude(folder, marker: "node-modules")

        try FileManager.default.removeItem(at: folder)
        try sandbox.folder("node_modules")

        #expect(!store.isExcluded(folder))
    }

    @Test(.enabled(if: Git.locate() != nil))
    func gitTrackedFiles() throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.folder("repo")
        try sandbox.file("repo/build/kept.txt", "tracked")
        try sandbox.file("repo/node_modules/lib.js", "untracked")
        try sandbox.file("repo/.gitignore", "node_modules/\n")
        try run("git", "-C", repository.fsPath, "init", "-q")
        try run("git", "-C", repository.fsPath, "add", "build/kept.txt", ".gitignore")
        let git = try #require(Git.locate())

        #expect(git.hasTrackedFiles(in: sandbox.url("repo/build"), repository: repository) == true)
        #expect(git.hasTrackedFiles(in: sandbox.url("repo/node_modules"), repository: repository) == false)
        #expect(git.ignoredDirectories(in: repository) == ["node_modules"])
    }

    @Test(.enabled(if: Git.locate() != nil))
    func hostileRepositoryConfigCannotRunCode() throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.folder("repo")
        try sandbox.folder("repo/build")
        let marker = sandbox.url("payload-ran")
        let payload = try sandbox.file("payload.sh", "#!/bin/sh\ntouch '\(marker.fsPath)'\n")
        #expect(chmod(payload.fsPath, 0o755) == 0)
        try run("git", "-C", repository.fsPath, "init", "-q")
        try run("git", "-C", repository.fsPath, "config", "core.fsmonitor", payload.fsPath)
        try run("git", "-C", repository.fsPath, "config", "core.untrackedCache", "true")
        let git = try #require(Git.locate())

        _ = git.hasTrackedFiles(in: sandbox.url("repo/build"), repository: repository)
        _ = git.ignoredDirectories(in: repository)

        #expect(FileSystem.info(marker) == nil, "git ran the repository's core.fsmonitor program")
    }

    @Test(.enabled(if: Git.locate() != nil))
    func gitIgnoresTheCallersGitVariables() throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.folder("repo")
        try sandbox.file("repo/build/kept.txt", "tracked")
        let other = try sandbox.folder("other")
        try run("git", "-C", repository.fsPath, "init", "-q")
        try run("git", "-C", repository.fsPath, "add", "build/kept.txt")
        try run("git", "-C", other.fsPath, "init", "-q")
        let git = try #require(Git.locate())

        // As in a git hook or an IDE terminal that points GIT_DIR at another repository.
        setenv("GIT_DIR", other.appending(path: ".git").fsPath, 1)
        defer { unsetenv("GIT_DIR") }

        #expect(git.hasTrackedFiles(in: sandbox.url("repo/build"), repository: repository) == true)
        #expect(Git.environment(from: ["GIT_DIR": "/x", "GIT_CONFIG_COUNT": "1", "PATH": "/usr/bin"])
            == ["PATH": "/usr/bin", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"])
    }

    @Test(.enabled(if: Git.locate() != nil))
    func folderNamesAreNeverPathspecMagic() throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.folder("repo")
        try sandbox.file("repo/:(attr:none)x/build/kept.txt", "tracked")
        try run("git", "-C", repository.fsPath, "init", "-q")
        try run("git", "-C", repository.fsPath, "--literal-pathspecs", "add", ":(attr:none)x")
        let git = try #require(Git.locate())

        #expect(git.hasTrackedFiles(in: sandbox.url("repo/:(attr:none)x/build"), repository: repository) == true)
    }

    private func run(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
