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

    @Test func neverWritesThroughASymbolicLink() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.folder("Documents")
        let link = sandbox.url("projects/web/node_modules")
        try sandbox.folder("projects/web")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = SystemExclusionStore()

        #expect(throws: (any Error).self) { try store.exclude(link, marker: "node-modules") }
        #expect(!store.isExcluded(target), "the exclusion went to the link's target")
        #expect(store.marker(of: link) == nil)

        // An exclusion made by someone else on the target survives an include through the link.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var targetURL = target
        try targetURL.setResourceValues(values)
        #expect(throws: (any Error).self) { try store.include(link) }
        #expect(store.isExcluded(target), "the exclusion of the link's target was removed")
    }

    @Test func writesToTheFolderEvenIfItIsRenamedMidWrite() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder("projects/app/build")
        let moved = sandbox.url("projects/app/build-moved")
        let victim = try sandbox.folder("Documents")
        var store = SystemExclusionStore()
        store.willSetExclusion = {
            try? FileManager.default.moveItem(at: folder, to: moved)
            try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: victim)
        }

        try store.exclude(folder, marker: "gradle-build")

        #expect(!store.isExcluded(victim), "the exclusion went to the folder put in its place")
        #expect(store.isExcluded(moved))
        #expect(store.marker(of: moved) == "gradle-build")
    }

    @Test func refusesAFolderReplacedMidWrite() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder("projects/app/build")
        let victim = try sandbox.folder("Documents")
        var store = SystemExclusionStore()
        store.willSetExclusion = {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: victim)
        }

        #expect(throws: (any Error).self) { try store.exclude(folder, marker: "gradle-build") }
        #expect(!store.isExcluded(victim), "the exclusion went to the folder put in its place")
    }

    @Test(.enabled(if: Git.locate() != nil))
    func gitTrackedFoldersInOneQuery() throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.folder("repo")
        try sandbox.file("repo/build/kept.txt", "tracked")
        try sandbox.file("repo/out/page.html", "untracked")
        try sandbox.file("repo/with space/dist/a.js", "tracked")
        try sandbox.file("repo/buildx/b.txt", "tracked, but not inside build")
        try run("git", "-C", repository.fsPath, "init", "-q")
        try run("git", "-C", repository.fsPath, "add", "build/kept.txt", "with space/dist/a.js", "buildx/b.txt")
        let git = try #require(Git.locate())

        let folders = ["repo/build", "repo/out", "repo/with space/dist"].map(sandbox.url)
        #expect(git.trackedFolders(among: folders, repository: repository)
            == [sandbox.url("repo/build").fsPath, sandbox.url("repo/with space/dist").fsPath])
    }

    @Test(.enabled(if: Git.locate() != nil))
    func gitIndexStateChangesWhenSomethingIsCommitted() throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.folder("repo")
        try sandbox.file("repo/a.txt", "a")
        try sandbox.file("repo/build/b.txt", "b")
        try run("git", "-C", repository.fsPath, "init", "-q")
        #expect(GitIndexState(repository: repository) == .absent)

        try run("git", "-C", repository.fsPath, "add", "a.txt")
        let staged = try #require(GitIndexState(repository: repository))
        #expect(GitIndexState(repository: repository) == staged)

        try run("git", "-C", repository.fsPath, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "a")
        try run("git", "-C", repository.fsPath, "add", "build/b.txt")
        try run("git", "-C", repository.fsPath, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "b")
        #expect(GitIndexState(repository: repository) != staged)

        // A worktree's `.git` is a file naming its git folder.
        let worktree = sandbox.url("worktree")
        try run("git", "-C", repository.fsPath, "worktree", "add", "-q", worktree.fsPath)
        #expect(FileSystem.info(worktree.appending(path: ".git"))?.isRegularFile == true)
        let before = try #require(GitIndexState(repository: worktree))
        #expect(before != .absent)
        try sandbox.file("worktree/build/c.txt", "c")
        try run("git", "-C", worktree.fsPath, "add", "build/c.txt")
        #expect(GitIndexState(repository: worktree) != before)
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
