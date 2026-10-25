import Foundation

/// Effective configuration: defaults merged with the user's config file.
public struct Config: Sendable {
    /// Directories scanned with the rules. Only folders inside them are ever matched.
    public var roots: [URL]
    /// Active rules, in evaluation order.
    public var rules: [Rule]
    /// Whether folders with a valid CACHEDIR.TAG are excluded.
    public var cacheDirTagEnabled: Bool
    /// Global paths kept excluded even if they are deleted and recreated.
    public var guardedPaths: [URL]
    /// Folders never excluded, together with everything inside them.
    public var protectedPaths: [URL]

    public init(roots: [URL], rules: [Rule], cacheDirTagEnabled: Bool, guardedPaths: [URL], protectedPaths: [URL] = []) {
        self.roots = roots
        self.rules = rules
        self.cacheDirTagEnabled = cacheDirTagEnabled
        self.guardedPaths = guardedPaths
        self.protectedPaths = protectedPaths
    }

    /// True if excluding `url` would exclude a protected path: `url` is one, lies inside one or contains one.
    /// Case-insensitive, as APFS is by default; on a case-sensitive volume this only protects more.
    public func isProtected(_ url: URL) -> Bool {
        let path = url.fsPath.lowercased()
        return protectedPaths.contains { protected in
            let protectedPath = protected.fsPath.lowercased()
            return path == protectedPath || path.hasPrefix(protectedPath + "/") || protectedPath.hasPrefix(path + "/")
        }
    }

    /// Usual project folders. Without `roots` in the config file, the ones that exist are scanned.
    public static let rootCandidates = ["~/Developer", "~/Projects", "~/Code", "~/src", "~/dev", "~/repos", "~/workspace", "~/GitHub"]

    /// Root candidates that exist under `home` as real folders (symbolic links are ignored).
    public static func detectRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        rootCandidates.filter { candidate in
            let info = FileSystem.info(home.appending(path: String(candidate.dropFirst(2))))
            return info?.isDirectory == true
        }
    }

    /// Credential stores that are always protected, whatever the config file says.
    public static let alwaysProtectedPaths = [
        "~/.ssh",
        "~/.gnupg",
        "~/.aws",
        "~/.azure",
        "~/.kube",
        "~/.docker",
        "~/.config/gcloud",
        "~/.password-store",
        "~/.netrc",
        "~/Library/Keychains",
    ]

    /// Caches outside the project roots. Whole folders that may hold secrets (such as ~/.gradle,
    /// which can contain gradle.properties with signing passwords) are deliberately not listed.
    public static let defaultGuardedPaths = [
        "~/Library/Developer/Xcode/DerivedData",
        "~/Library/Developer/Xcode/iOS DeviceSupport",
        "~/Library/Developer/Xcode/watchOS DeviceSupport",
        "~/Library/Developer/Xcode/tvOS DeviceSupport",
        "~/Library/Developer/Xcode/visionOS DeviceSupport",
        "~/Library/Developer/CoreSimulator/Caches",
        "~/Library/Developer/CoreSimulator/Devices",
        "~/.npm",
        "~/Library/pnpm/store",
        "~/.bun/install/cache",
        "~/.gradle/caches",
        "~/.gradle/wrapper",
        "~/.cargo/registry",
        "~/.rustup/toolchains",
    ]

    /// `$TMSKIPPER_CONFIG`, else `$XDG_CONFIG_HOME/tmskipper/config.json`, else `~/.config/tmskipper/config.json`.
    public static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TMSKIPPER_CONFIG"], !path.isEmpty {
            return URL(filePath: expandTilde(path))
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "tmskipper/config.json")
    }

    /// Loads the config file at `url`, or the defaults if it does not exist.
    public static func load(from url: URL = defaultFileURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.fsPath) else {
            return try resolve(ConfigFile())
        }
        let data = try Data(contentsOf: url)
        let file: ConfigFile
        do {
            file = try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            throw ConfigError("\(url.fsPath) is not valid: \(error)")
        }
        return try resolve(file)
    }

    /// Merges a parsed config file with the defaults and validates the result.
    static func resolve(_ file: ConfigFile, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Config {
        let disabled = Set(file.rules?.disable ?? [])
        let added = file.rules?.add ?? []
        let knownIDs = Set(Rule.defaults.map(\.id) + added.map(\.id) + [Rule.cacheDirTagID])
        if let unknown = disabled.subtracting(knownIDs).sorted().first {
            throw ConfigError("rules.disable: unknown rule id \"\(unknown)\"")
        }
        for rule in added {
            if let error = rule.validationError() { throw ConfigError("rules.add: \(error)") }
        }
        if let duplicate = Dictionary(grouping: added, by: \.id).first(where: { $0.value.count > 1 })?.key {
            throw ConfigError("rules.add: duplicate rule id \"\(duplicate)\"")
        }

        // An added rule with a default rule's id replaces it in place.
        let addedByID = Dictionary(uniqueKeysWithValues: added.map { ($0.id, $0) })
        var rules = Rule.defaults.map { addedByID[$0.id] ?? $0 }
        let defaultIDs = Set(Rule.defaults.map(\.id))
        rules += added.filter { !defaultIDs.contains($0.id) }
        rules.removeAll { disabled.contains($0.id) }

        let listedRoots = try (file.roots ?? detectRoots(home: home)).map { path -> URL in
            let expanded = path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2))).fsPath : expandTilde(path)
            guard expanded.hasPrefix("/"), expanded != "/" else {
                throw ConfigError("roots: \"\(path)\" must be an absolute path other than /")
            }
            return URL(filePath: expanded)
        }
        // A root inside another root would be scanned twice.
        var roots: [URL] = []
        for root in listedRoots where !listedRoots.contains(where: { root.fsPath.hasPrefix($0.fsPath + "/") })
            && !roots.contains(where: { $0.fsPath == root.fsPath }) {
            roots.append(root)
        }

        let disabledGuards = Set((file.guardedPaths?.disable ?? []).map(expandTilde))
        var guarded = defaultGuardedPaths.map(expandTilde).filter { !disabledGuards.contains($0) }
        for path in (file.guardedPaths?.add ?? []).map(expandTilde) where !guarded.contains(path) {
            let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
            guard path.hasPrefix("/"), path != "/", path != home else {
                throw ConfigError("guardedPaths.add: \"\(path)\" must be an absolute path other than / and the home folder")
            }
            guarded.append(path)
        }

        let listedProtected = try alwaysProtectedPaths.map { URL(filePath: expandTilde($0)) }
            + (file.protectedPaths ?? []).map { path -> URL in
                let expanded = expandTilde(path)
                guard expanded.hasPrefix("/") else {
                    throw ConfigError("protectedPaths: \"\(path)\" must be an absolute path")
                }
                return URL(filePath: expanded)
            }
        // Protect the real location too when a protected path is a symbolic link.
        var protected: [URL] = []
        for url in listedProtected + listedProtected.map({ $0.resolvingSymlinksInPath() })
        where !protected.contains(where: { $0.fsPath == url.fsPath }) {
            protected.append(url)
        }

        return Config(
            roots: roots,
            rules: rules,
            cacheDirTagEnabled: !disabled.contains(Rule.cacheDirTagID),
            guardedPaths: guarded.map { URL(filePath: $0) },
            protectedPaths: protected
        )
    }

    /// The config file written by `tmskipper init`: every section present, nothing changed.
    public static func template(roots: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let list = roots.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        return """
        {
          "roots": [\(list.joined(separator: ", "))],
          "rules": {
            "disable": [],
            "add": []
          },
          "guardedPaths": {
            "disable": [],
            "add": []
          },
          "protectedPaths": []
        }

        """
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// The JSON config file. Every key is optional.
struct ConfigFile: Codable {
    struct Rules: Codable {
        var disable: [String]?
        var add: [Rule]?
    }

    struct Paths: Codable {
        var disable: [String]?
        var add: [String]?
    }

    var roots: [String]?
    var rules: Rules?
    var guardedPaths: Paths?
    var protectedPaths: [String]?
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
