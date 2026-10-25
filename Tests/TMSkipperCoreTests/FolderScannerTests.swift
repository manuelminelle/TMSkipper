import Foundation
import Testing
@testable import TMSkipperCore

@Suite struct FolderScannerTests {
    let sandbox: Sandbox
    let store = FakeStore()

    init() throws { sandbox = try Sandbox() }

    func scan(_ config: Config? = nil, git: FakeGit = FakeGit(), apply: Bool = true) -> ScanReport {
        FolderScanner(config: config ?? sandbox.config(), store: store, git: git).scan(apply: apply)
    }

    @Test func excludesNodeModulesNextToPackageJSON() throws {
        try sandbox.file("projects/web/package.json", "{}")
        let modules = try sandbox.folder("projects/web/node_modules/react")
            .deletingLastPathComponent()

        let report = scan()

        #expect(report.excluded.map(\.url.fsPath) == [modules.fsPath])
        #expect(store.marker(of: modules) == "node-modules")
        #expect(report.errors.isEmpty)
    }

    @Test func ignoresFolderWithoutSentinel() throws {
        try sandbox.folder("projects/loose/node_modules")
        try sandbox.folder("projects/delivery/build")
        try sandbox.folder("projects/delivery/dist")

        let report = scan()

        #expect(report.excluded.isEmpty)
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func dryRunChangesNothing() throws {
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.folder("projects/web/node_modules")

        let report = scan(apply: false)

        #expect(report.excluded.count == 1)
        #expect(!report.applied)
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func neverExcludesEnvFilesOrFoldersHoldingSecrets() throws {
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.file("projects/web/.env.local", "SECRET=1")
        try sandbox.folder("projects/web/node_modules")
        try sandbox.file("projects/app/build.gradle", "")
        try sandbox.file("projects/app/build/release.keystore", "")

        let report = scan()

        #expect(store.excludedPaths == [sandbox.url("projects/web/node_modules").fsPath])
        #expect(report.skipped.map(\.url.fsPath) == [sandbox.url("projects/app/build").fsPath])
        #expect(report.skipped.first?.reason == "contains release.keystore")
    }

    @Test func recognisesPrivateKeysByContent() throws {
        try sandbox.file("projects/app/build.gradle", "")
        try sandbox.file("projects/app/build/vps-root", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n")
        try sandbox.file("projects/app/build/notes.txt", "-----BEGIN something else-----")
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.file("projects/web/node_modules/key-docs.txt", "-----BEGIN CERTIFICATE-----")

        let report = scan()

        #expect(report.skipped.map(\.reason) == ["contains vps-root"])
        #expect(store.excludedPaths == [sandbox.url("projects/web/node_modules").fsPath])
    }

    @Test(.timeLimit(.minutes(1)))
    func namedPipesNeverBlockTheScan() throws {
        try sandbox.file("projects/app/build.gradle", "")
        try sandbox.folder("projects/app/build")
        try sandbox.folder("projects/web/.next")
        try sandbox.folder("projects/tool/cache")
        // A pipe where a key, a package.json and a CACHEDIR.TAG would be read.
        for path in ["projects/app/build/deploy-key", "projects/web/package.json", "projects/tool/cache/CACHEDIR.TAG"] {
            #expect(mkfifo(sandbox.url(path).fsPath, 0o644) == 0)
        }

        let report = scan()

        #expect(report.excluded.map(\.url.fsPath) == [sandbox.url("projects/app/build").fsPath])
        #expect(report.errors.isEmpty)
    }

    @Test func neverExcludesAWholeRepository() throws {
        // A downloaded repository with a committed CACHEDIR.TAG at its top level.
        try sandbox.folder("projects/library/.git")
        try sandbox.file("projects/library/src/main.c", "int main(void) { return 0; }")
        try sandbox.file("projects/library/CACHEDIR.TAG", RuleMatcher.cacheDirTagSignature)

        let report = scan()

        #expect(report.skipped.map(\.reason) == ["contains .git"])
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func checksTrackedFilesWhenTheRootIsInsideARepository() throws {
        try sandbox.folder(".git")
        try sandbox.file("projects/web/package.json", "{}")
        let modules = try sandbox.folder("projects/web/node_modules")

        let report = scan(git: FakeGit(tracked: [modules.fsPath]))

        #expect(report.skipped.first?.reason == "contains files tracked by git")
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func deepRuleFoldersNeverCrossSymbolicLinks() throws {
        try sandbox.folder("outside/c")
        try sandbox.file("projects/app/tool.cfg", "")
        try sandbox.folder("projects/app/a")
        try FileManager.default.createSymbolicLink(at: sandbox.url("projects/app/a/b"), withDestinationURL: sandbox.url("outside"))
        let deep = Rule(id: "deep", folder: "a/b/c", sentinels: ["tool.cfg"], ecosystem: "Test")

        let report = scan(sandbox.config(rules: [deep]))

        #expect(report.excluded.isEmpty)
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func neverExcludesFoldersContainingProtectedPaths() throws {
        try sandbox.file("projects/app/build.gradle", "")
        try sandbox.folder("projects/app/build/keys")
        var config = sandbox.config(guarded: ["home/.config"])
        try sandbox.folder("home/.config/gcloud")
        config.protectedPaths = [sandbox.url("projects/app/build/keys"), sandbox.url("home/.config/gcloud")]

        let report = scan(config)

        #expect(report.skipped.count == 2)
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func removesOwnExclusionWhenSecretAppearsInside() throws {
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.folder("projects/web/node_modules")
        _ = scan()
        try sandbox.file("projects/web/node_modules/.env", "SECRET=1")

        let report = scan()

        #expect(report.removed.first?.reason == "now contains .env")
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func doesNotDescendIntoMatchedFolders() throws {
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.file("projects/web/node_modules/lib/package.json", "{}")
        try sandbox.folder("projects/web/node_modules/lib/node_modules")

        let report = scan()

        #expect(report.excluded.count == 1)
        #expect(report.directoriesVisited == 2) // projects, projects/web
    }

    @Test func doesNotDescendIntoFoldersExcludedByOthers() throws {
        try sandbox.file("projects/old/web/package.json", "{}")
        try sandbox.folder("projects/old/web/node_modules")
        store.excludeByOthers(sandbox.url("projects/old"))

        let report = scan()

        #expect(report.excluded.isEmpty)
        #expect(store.marker(of: sandbox.url("projects/old")) == nil)
    }

    @Test func leavesExclusionsByOthersAlone() throws {
        try sandbox.file("projects/web/package.json", "{}")
        let modules = try sandbox.folder("projects/web/node_modules")
        store.excludeByOthers(modules)

        let report = scan()

        #expect(report.excludedByOthers.count == 1)
        #expect(store.marker(of: modules) == nil)
    }

    @Test func removesExclusionWhenSentinelDisappears() throws {
        let packageJSON = try sandbox.file("projects/web/package.json", "{}")
        try sandbox.folder("projects/web/node_modules")
        _ = scan()
        try FileManager.default.removeItem(at: packageJSON)

        let report = scan()

        #expect(report.removed.map(\.ruleID) == ["node-modules"])
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func removesExclusionWhenRuleIsDisabled() throws {
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.folder("projects/web/coverage")
        _ = scan()
        let rules = Rule.defaults.filter { $0.id != "js-coverage" }

        let report = scan(sandbox.config(rules: rules))

        #expect(report.removed.map(\.ruleID) == ["js-coverage"])
    }

    @Test func secondRunChangesNothing() throws {
        try sandbox.file("projects/web/package.json", "{}")
        try sandbox.folder("projects/web/node_modules")
        _ = scan()

        let report = scan()

        #expect(report.excluded.isEmpty && report.removed.isEmpty)
        #expect(report.kept.count == 1)
    }

    @Test func handlesPathsWithSpaces() throws {
        try sandbox.file("projects/sito con spazi/package.json", "{}")
        let modules = try sandbox.folder("projects/sito con spazi/node_modules")

        _ = scan()

        #expect(store.marker(of: modules) == "node-modules")
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        try sandbox.file("elsewhere/web/package.json", "{}")
        try sandbox.folder("elsewhere/web/node_modules")
        try sandbox.folder("projects")
        try FileManager.default.createSymbolicLink(at: sandbox.url("projects/link"), withDestinationURL: sandbox.url("elsewhere"))
        try sandbox.file("projects/web/package.json", "{}")
        try FileManager.default.createSymbolicLink(
            at: sandbox.url("projects/web/node_modules"), withDestinationURL: sandbox.url("elsewhere/web/node_modules")
        )

        let report = scan()

        #expect(report.excluded.isEmpty)
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func matchesPackageJSONDependency() throws {
        try sandbox.file("projects/next/package.json", #"{"dependencies": {"next": "16.0.0"}}"#)
        try sandbox.folder("projects/next/.next")
        try sandbox.file("projects/other/package.json", #"{"dependencies": {"react": "19.0.0"}}"#)
        try sandbox.folder("projects/other/.next")

        _ = scan()

        #expect(store.excludedPaths == [sandbox.url("projects/next/.next").fsPath])
    }

    @Test func matchesWildcardSentinel() throws {
        try sandbox.file("projects/next/next.config.ts", "")
        try sandbox.folder("projects/next/.next")

        _ = scan()

        #expect(store.marker(of: sandbox.url("projects/next/.next")) == "next")
    }

    @Test func excludesNestedRuleFolderOnly() throws {
        try sandbox.file("projects/site/.vercel/project.json", "{}")
        let output = try sandbox.folder("projects/site/.vercel/output")

        let first = scan()
        let second = scan()

        #expect(store.excludedPaths == [output.fsPath])
        #expect(first.excluded.count == 1)
        #expect(second.kept.count == 1 && second.removed.isEmpty)
    }

    @Test func excludesCacheDirTaggedFolders() throws {
        try sandbox.file("projects/tool/.pytest_cache/CACHEDIR.TAG", RuleMatcher.cacheDirTagSignature + "\n# comment")
        try sandbox.file("projects/tool/fake/CACHEDIR.TAG", "not a signature")

        _ = scan()

        #expect(store.excludedPaths == [sandbox.url("projects/tool/.pytest_cache").fsPath])
        #expect(store.marker(of: sandbox.url("projects/tool/.pytest_cache")) == Rule.cacheDirTagID)
    }

    @Test func skipsFoldersTrackedByGit() throws {
        try sandbox.folder("projects/app/.git")
        try sandbox.file("projects/app/build.gradle", "")
        let build = try sandbox.folder("projects/app/build")

        let report = scan(git: FakeGit(tracked: [build.fsPath]))

        #expect(report.skipped.first?.reason == "contains files tracked by git")
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func listAndResetTouchOnlyOwnExclusions() throws {
        try sandbox.file("projects/web/package.json", "{}")
        let modules = try sandbox.folder("projects/web/node_modules")
        let manual = try sandbox.folder("projects/web/videos")
        store.excludeByOthers(manual)
        _ = scan()
        let scanner = FolderScanner(config: sandbox.config(), store: store, git: FakeGit())

        #expect(scanner.findOwned().kept.map(\.url.fsPath) == [modules.fsPath])
        let report = scanner.reset(apply: true)

        #expect(report.removed.map(\.url.fsPath) == [modules.fsPath])
        #expect(store.excludedPaths == [manual.fsPath])
    }

    @Test func guardsGlobalPaths() throws {
        try sandbox.folder("projects")
        let derivedData = try sandbox.folder("library/DerivedData")
        let simulators = try sandbox.folder("library/CoreSimulator/Devices")
        store.excludeByOthers(sandbox.url("library/CoreSimulator"))
        let config = sandbox.config(guarded: ["library/DerivedData", "library/CoreSimulator/Devices", "library/missing"])

        let first = scan(config)
        let second = scan(config)

        #expect(first.excluded.map(\.url.fsPath) == [derivedData.fsPath])
        #expect(store.marker(of: derivedData) == Rule.guardedMarker)
        #expect(store.marker(of: simulators) == nil)
        #expect(second.excluded.isEmpty && second.kept.count == 1)
    }

    @Test func doesNotGuardFoldersHoldingSecrets() throws {
        try sandbox.folder("projects")
        try sandbox.file("home/.gradle/gradle.properties", "signingPassword=x")

        let report = scan(sandbox.config(guarded: ["home/.gradle"]))

        #expect(report.skipped.first?.reason == "contains gradle.properties")
        #expect(store.excludedPaths.isEmpty)
    }

    @Test func respectsProtectedPaths() throws {
        try sandbox.file("projects/release/source/build.gradle", "")
        let build = try sandbox.folder("projects/release/source/build")
        try sandbox.file("projects/web/package.json", "{}")
        let modules = try sandbox.folder("projects/web/node_modules")
        _ = scan()
        #expect(store.excludedPaths == [build.fsPath, modules.fsPath])
        var config = sandbox.config()
        config.protectedPaths = [sandbox.url("projects/release"), modules]

        let report = scan(config)
        let again = scan(config)

        #expect(Set(report.removed.map(\.reason)) == ["in protectedPaths"])
        #expect(store.excludedPaths.isEmpty)
        #expect(again.skipped.count == 2 && again.excluded.isEmpty)
    }

    @Test func reportsMissingRoot() {
        let report = scan()
        #expect(report.errors.count == 1)
    }

    @Test func suggestsLargeIgnoredFoldersOutsideRules() throws {
        try sandbox.folder("projects/app/.git")
        try sandbox.file("projects/app/package.json", "{}")
        try sandbox.file("projects/app/node_modules/big.bin", String(repeating: "x", count: 50_000))
        try sandbox.file("projects/app/models/weights.bin", String(repeating: "x", count: 50_000))
        let repository = sandbox.url("projects/app").fsPath
        let git = FakeGit(ignored: [repository: ["node_modules", "models"]])

        let suggestions = FolderScanner(config: sandbox.config(), store: store, git: git).suggestions(minimumSize: 10_000)

        #expect(suggestions.map(\.url.fsPath) == [sandbox.url("projects/app/models").fsPath])
    }
}
