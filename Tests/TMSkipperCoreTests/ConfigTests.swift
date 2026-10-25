import Foundation
import Testing
@testable import TMSkipperCore

@Suite struct ConfigTests {
    func decode(_ json: String) throws -> ConfigFile {
        try JSONDecoder().decode(ConfigFile.self, from: Data(json.utf8))
    }

    @Test func defaultsWithoutFile() throws {
        let home = try Sandbox()
        try home.folder("Developer")
        try home.folder("Projects")
        try home.folder("elsewhere")
        try FileManager.default.createSymbolicLink(at: home.url("src"), withDestinationURL: home.url("elsewhere"))

        let config = try Config.resolve(ConfigFile(), home: home.root)

        #expect(config.rules == Rule.defaults)
        #expect(config.cacheDirTagEnabled)
        #expect(config.roots.map(\.fsPath) == [home.url("Developer").fsPath, home.url("Projects").fsPath])
    }

    @Test func noRootsWhenNoUsualFolderExists() throws {
        let home = try Sandbox()
        #expect(try Config.resolve(ConfigFile(), home: home.root).roots.isEmpty)
    }

    @Test func dropsNestedAndDuplicateRoots() throws {
        let config = try Config.resolve(decode(#"{"roots": ["/code", "/code/web", "/other", "/code"]}"#))
        #expect(config.roots.map(\.fsPath) == ["/code", "/other"])
    }

    @Test func templateIsValid() throws {
        let config = try Config.resolve(decode(Config.template(roots: ["~/Developer", "~/My Projects"])))
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(config.rules == Rule.defaults)
        #expect(config.roots.map(\.fsPath) == [home.appending(path: "Developer").fsPath, home.appending(path: "My Projects").fsPath])
        #expect(try Config.resolve(decode(Config.template(roots: []))).roots.isEmpty)
    }

    @Test func defaultRulesAreValid() {
        #expect(Rule.defaults.compactMap { $0.validationError() }.isEmpty)
        #expect(Set(Rule.defaults.map(\.id)).count == Rule.defaults.count)
    }

    @Test func disablesAddsAndOverridesRules() throws {
        let config = try Config.resolve(decode("""
        {
          "rules": {
            "disable": ["js-coverage", "cachedir-tag"],
            "add": [
              {"id": "node-modules", "folder": "node_modules", "sentinels": ["package.json", "bun.lock"], "ecosystem": "Node.js"},
              {"id": "godot", "folder": ".godot", "sentinels": ["project.godot"], "ecosystem": "Godot"}
            ]
          },
          "guardedPaths": {"disable": ["~/.npm"], "add": ["~/.colima"]}
        }
        """))

        #expect(!config.rules.contains { $0.id == "js-coverage" })
        #expect(!config.cacheDirTagEnabled)
        #expect(config.rules.first { $0.id == "node-modules" }?.sentinels == ["package.json", "bun.lock"])
        #expect(config.rules.last?.id == "godot")
        let guarded = config.guardedPaths.map(display)
        #expect(!guarded.contains("~/.npm"))
        #expect(guarded.contains("~/.colima"))
    }

    @Test(arguments: [
        #"{"rules": {"add": [{"id": "x", "folder": ".git", "sentinels": ["a"], "ecosystem": ""}]}}"#,
        #"{"rules": {"add": [{"id": "x", "folder": "../up", "sentinels": ["a"], "ecosystem": ""}]}}"#,
        #"{"rules": {"add": [{"id": "x", "folder": "/abs", "sentinels": ["a"], "ecosystem": ""}]}}"#,
        #"{"rules": {"add": [{"id": "x", "folder": "out", "sentinels": [], "ecosystem": ""}]}}"#,
        #"{"rules": {"add": [{"id": "guarded", "folder": "out", "sentinels": ["a"], "ecosystem": ""}]}}"#,
        #"{"rules": {"disable": ["no-such-rule"]}}"#,
        #"{"roots": ["/"]}"#,
        #"{"roots": ["relative/path"]}"#,
        #"{"guardedPaths": {"add": ["~"]}}"#,
        #"{"protectedPaths": ["relative/path"]}"#,
    ])
    func rejectsInvalidConfig(_ json: String) throws {
        let file = try decode(json)
        #expect(throws: ConfigError.self) { try Config.resolve(file) }
    }

    @Test func alwaysProtectsCredentialStores() throws {
        let config = try Config.resolve(decode(#"{"protectedPaths": []}"#))
        let home = FileManager.default.homeDirectoryForCurrentUser

        #expect(config.isProtected(home.appending(path: ".ssh")))
        #expect(config.isProtected(home.appending(path: ".ssh/vps-key")))
        #expect(config.isProtected(home.appending(path: ".config")))     // contains ~/.config/gcloud
        #expect(!config.isProtected(home.appending(path: ".config/tmskipper")))
        #expect(!config.isProtected(home.appending(path: "Developer/web/node_modules")))
    }

    @Test func protectedPathsIgnoreCaseAndSymbolicLinks() throws {
        let sandbox = try Sandbox()
        let real = try sandbox.folder("Release Kit")
        try FileManager.default.createSymbolicLink(at: sandbox.url("alias"), withDestinationURL: real)
        let config = try Config.resolve(decode(#"{"protectedPaths": ["\#(sandbox.url("alias").fsPath)", "/Volumes/Data/Client"]}"#))

        #expect(config.isProtected(real.appending(path: "build")))
        #expect(config.isProtected(URL(filePath: "/volumes/data/client/build")))
        #expect(!config.isProtected(URL(filePath: "/Volumes/Data/Other")))
    }

    @Test func launchAgentSchedule() {
        let plist = LaunchAgent.propertyList(
            executable: URL(filePath: "/usr/local/bin/tmskipper"), everyHours: 6, config: URL(filePath: "/custom/config.json")
        )
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["TMSKIPPER_CONFIG": "/custom/config.json"])
        let intervals = plist["StartCalendarInterval"] as? [[String: Int]]
        #expect(intervals?.map { $0["Hour"] } == [0, 6, 12, 18])
        #expect(plist["StartOnMount"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/tmskipper", "scan", "--quiet"])
    }

    private func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
        return "~" + url.fsPath.dropFirst(home.count)
    }
}
