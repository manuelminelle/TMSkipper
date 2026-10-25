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

    /// The whole cycle with the default rules, the real store and the real git, checked with `tmutil`.
    @Test(.enabled(if: Git.locate() != nil))
    func endToEndWithTheRealStoreAndGit() throws {
        let sandbox = try Sandbox(base: FileManager.default.homeDirectoryForCurrentUser)
        #expect(try !isExcludedByTimeMachine(sandbox.root), "the sandbox is already excluded: tmutil cannot tell anything")
        let git = try #require(Git.locate())
        let store = SystemExclusionStore()
        func commit(_ repository: String, _ paths: String...) throws {
            let path = sandbox.url(repository).fsPath
            try run(["git", "-C", path, "add", "-f", "--"] + paths)
            try run("git", "-C", path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "commit")
        }

        try sandbox.file("projects/web-app/package.json", #"{"dependencies":{"next":"15.0.0"}}"#)
        try sandbox.file("projects/web-app/next.config.mjs")
        try sandbox.file("projects/web-app/.env.local", "SECRET=1")
        try sandbox.file("projects/web-app/node_modules/react/index.js")
        try sandbox.file("projects/web-app/.next/cache/a")
        try run("git", "-C", sandbox.url("projects/web-app").fsPath, "init", "-q")
        try commit("projects/web-app", "package.json", "next.config.mjs")
        try sandbox.file("projects/docs-site/astro.config.mjs")
        try sandbox.file("projects/docs-site/dist/index.html")
        try run("git", "-C", sandbox.url("projects/docs-site").fsPath, "init", "-q")
        try commit("projects/docs-site", ".")
        try sandbox.file("projects/release-kit/build.gradle")
        try sandbox.file("projects/release-kit/build/upload.keystore")
        try sandbox.file("projects/rust-tool/Cargo.toml")
        try sandbox.file("projects/rust-tool/target/notes.txt", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc")
        try sandbox.file("projects/ios-kit/Package.swift")
        try sandbox.file("projects/ios-kit/.build/debug/x")
        try sandbox.file("projects/py-tool/pyproject.toml")
        try sandbox.file("projects/py-tool/.venv/bin/python")
        try sandbox.file("projects/py-tool/.pytest_cache/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")
        try sandbox.file("projects/plain/dist/deliverable.zip")
        try sandbox.file("projects/client/package.json", "{}")
        try sandbox.file("projects/client/node_modules/a")
        let documents = try sandbox.folder("Documents")
        try sandbox.file("projects/linked/package.json", "{}")
        try FileManager.default.createSymbolicLink(at: sandbox.url("projects/linked/node_modules"), withDestinationURL: documents)
        try sandbox.file("projects/other/package.json", "{}")
        var excludedByOthers = try sandbox.folder("projects/other/node_modules")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedByOthers.setResourceValues(values)

        var config = sandbox.config()
        config.protectedPaths = [sandbox.url("projects/client")]
        let expected = Set([
            "projects/web-app/node_modules", "projects/web-app/.next", "projects/ios-kit/.build",
            "projects/py-tool/.venv", "projects/py-tool/.pytest_cache",
        ].map { sandbox.url($0).fsPath })

        let dryRun = FolderScanner(config: config, git: git).scan(apply: false)
        #expect(dryRun.errors.isEmpty)
        #expect(Set(dryRun.excluded.map(\.url.fsPath)) == expected)
        #expect(expected.allSatisfy { !store.isExcluded(URL(filePath: $0)) }, "a dry run wrote an exclusion")
        let skipped = Dictionary(uniqueKeysWithValues: dryRun.skipped.map { ($0.url.fsPath, $0.reason ?? "") })
        #expect(skipped == [
            sandbox.url("projects/docs-site/dist").fsPath: "contains files tracked by git",
            sandbox.url("projects/release-kit/build").fsPath: "contains upload.keystore",
            sandbox.url("projects/rust-tool/target").fsPath: "contains notes.txt",
            sandbox.url("projects/client/node_modules").fsPath: "in protectedPaths",
        ])
        #expect(dryRun.excludedByOthers.map(\.url.fsPath) == [excludedByOthers.fsPath])

        let first = FolderScanner(config: config, git: git).scan(apply: true)
        #expect(first.errors.isEmpty)
        #expect(Set(first.excluded.map(\.url.fsPath)) == expected)
        for path in expected { #expect(try isExcludedByTimeMachine(URL(filePath: path)), "\(path) is not excluded") }
        for path in ["projects/web-app/.env.local", "projects/plain/dist", "projects/docs-site/dist",
                     "projects/release-kit/build", "projects/client/node_modules", "Documents"] {
            #expect(try !isExcludedByTimeMachine(sandbox.url(path)), "\(path) is excluded")
        }

        // A second scan changes nothing and records the repositories found clean.
        let rescanner = FolderScanner(config: config, git: git, previous: ScanLocations(config))
        let second = rescanner.scan(apply: true)
        #expect(second.excluded.isEmpty && second.removed.isEmpty && second.errors.isEmpty)
        #expect(Set(second.kept.map(\.url.fsPath)) == expected)
        let verified = rescanner.verifiedRepositories(after: second)

        // A file committed, a secret added, a sentinel deleted: each exclusion is removed.
        try commit("projects/web-app", "node_modules/react/index.js")
        try sandbox.file("projects/ios-kit/.build/.env", "KEY=1")
        try FileManager.default.removeItem(at: sandbox.url("projects/py-tool/pyproject.toml"))
        let third = FolderScanner(config: config, git: git, previous: ScanLocations(config), verified: verified).scan(apply: true)
        #expect(third.errors.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: third.removed.map { ($0.url.fsPath, $0.reason ?? "") }) == [
            sandbox.url("projects/web-app/node_modules").fsPath: "now contains files tracked by git",
            sandbox.url("projects/ios-kit/.build").fsPath: "now contains .env",
            sandbox.url("projects/py-tool/.venv").fsPath: "rule python-venv no longer applies",
        ])
        #expect(try !isExcludedByTimeMachine(sandbox.url("projects/web-app/node_modules")))
        #expect(try !isExcludedByTimeMachine(sandbox.url("projects/ios-kit/.build")))
        #expect(try !isExcludedByTimeMachine(sandbox.url("projects/py-tool/.venv")))

        // `cp -R` carries the exclusion and the marker: the copy outside the roots is included again.
        let copy = sandbox.url("delivered")
        try run("cp", "-R", sandbox.url("projects/web-app/.next").fsPath, copy.fsPath)
        #expect(store.marker(of: copy) == "next")
        let fourth = FolderScanner(config: config, git: git, index: FakeIndex(items: [copy]), previous: ScanLocations(config))
            .scan(apply: true)
        #expect(fourth.removed.map(\.url.fsPath) == [copy.fsPath])
        #expect(try !isExcludedByTimeMachine(copy))

        // A root removed from the config loses its exclusions.
        try sandbox.file("projects2/app/package.json", "{}")
        try sandbox.folder("projects2/app/node_modules")
        var twoRoots = config
        twoRoots.roots.append(sandbox.url("projects2"))
        _ = FolderScanner(config: twoRoots, git: git).scan(apply: true)
        #expect(try isExcludedByTimeMachine(sandbox.url("projects2/app/node_modules")))
        let fifth = FolderScanner(config: config, git: git, previous: ScanLocations(twoRoots)).scan(apply: true)
        #expect(fifth.removed.map(\.url.fsPath) == [sandbox.url("projects2/app/node_modules").fsPath])
        #expect(try !isExcludedByTimeMachine(sandbox.url("projects2/app/node_modules")))

        // `list` and `reset` only see TMSkipper's exclusions.
        let scanner = FolderScanner(config: config, git: git)
        let remaining = Set(["projects/web-app/.next", "projects/py-tool/.pytest_cache"].map { sandbox.url($0).fsPath })
        #expect(Set(scanner.findOwned().kept.map(\.url.fsPath)) == remaining)
        let reset = scanner.reset(apply: true)
        #expect(reset.errors.isEmpty)
        #expect(Set(reset.removed.map(\.url.fsPath)) == remaining)
        #expect(scanner.findOwned().kept.isEmpty)
        for path in remaining { #expect(try !isExcludedByTimeMachine(URL(filePath: path))) }
        #expect(try isExcludedByTimeMachine(excludedByOthers), "reset removed an exclusion made by someone else")
    }

    /// What Time Machine itself reports, sticky and path-based exclusions included.
    private func isExcludedByTimeMachine(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tmutil")
        process.arguments = ["isexcluded", url.fsPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).hasPrefix("[Excluded]")
    }

    private func run(_ arguments: String...) throws {
        try run(arguments)
    }

    private func run(_ arguments: [String]) throws {
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
