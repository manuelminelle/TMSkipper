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
