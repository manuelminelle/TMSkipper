import Foundation

/// Evaluates rules and safety checks against the file system.
enum RuleMatcher {
    /// Signature that starts every valid CACHEDIR.TAG file (https://bford.info/cachedir/).
    static let cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// Names that must never end up excluded: if a candidate holds one at its top level, it is skipped.
    static let protectedPatterns = [
        ".env*", "*.p8", "*.p12", "*.pem", "*.key", "*.jks", "*.keystore",
        "*.mobileprovision", "*.cer", "id_rsa*", "id_ed25519*", "id_ecdsa*",
        "gradle.properties", ".npmrc", ".netrc", "credentials*", "secrets*",
    ]

    /// True if one of the rule's sentinels matches in `base`, whose entry names are `names`.
    static func sentinelsMatch(_ rule: Rule, in base: URL, names: Set<String>) -> Bool {
        rule.sentinels.contains { sentinelMatches($0, in: base, names: names) }
    }

    static func sentinelMatches(_ sentinel: String, in base: URL, names: Set<String>) -> Bool {
        if let hash = sentinel.firstIndex(of: "#") {
            let file = String(sentinel[..<hash])
            let dependency = String(sentinel[sentinel.index(after: hash)...])
            return packageJSON(base.appending(path: file), declares: dependency)
        }
        if sentinel.contains("*") || sentinel.contains("?") || sentinel.contains("[") {
            return names.contains { FileSystem.matches($0, pattern: sentinel) }
        }
        if sentinel.contains("/") {
            return FileSystem.info(base.appending(path: sentinel)) != nil
        }
        return names.contains(sentinel)
    }

    /// True if the package.json at `url` lists `dependency` in dependencies or devDependencies.
    static func packageJSON(_ url: URL, declares dependency: String) -> Bool {
        guard let info = FileSystem.info(url), !info.isDirectory, !info.isSymbolicLink,
              !info.isDataless, info.size < 1_000_000,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return ["dependencies", "devDependencies"].contains { key in
            (json[key] as? [String: Any])?[dependency] != nil
        }
    }

    /// True if `directory` holds a CACHEDIR.TAG file with the standard signature.
    static func hasCacheDirTag(_ directory: URL) -> Bool {
        let tag = directory.appending(path: "CACHEDIR.TAG")
        guard let info = FileSystem.info(tag), !info.isDirectory, !info.isSymbolicLink, !info.isDataless,
              let handle = try? FileHandle(forReadingFrom: tag)
        else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: cacheDirTagSignature.utf8.count)) ?? Data()
        return String(decoding: data, as: UTF8.self) == cacheDirTagSignature
    }

    /// Name of the first protected item at the top level of `directory`, if any.
    /// An unreadable directory counts as protected: nothing is excluded without looking at it first.
    static func protectedItem(in directory: URL) -> String? {
        guard let entries = try? FileSystem.entries(of: directory) else { return "(unreadable folder)" }
        if let byName = entries.first(where: { entry in
            protectedPatterns.contains { FileSystem.matches(entry.name, pattern: $0) }
        }) {
            return byName.name
        }
        // Keys are often saved under custom names: also look at what the files contain.
        return entries.first { !$0.isDirectory && !$0.isSymbolicLink && isPrivateKey($0.url) }?.name
    }

    /// True if the file starts like a PEM or OpenSSH private key ("-----BEGIN … PRIVATE KEY-----").
    /// A placeholder whose content is in iCloud counts as a key: it cannot be read without downloading it.
    static func isPrivateKey(_ url: URL) -> Bool {
        guard let info = FileSystem.info(url), !info.isDirectory, !info.isSymbolicLink else { return false }
        if info.isDataless { return true }
        guard info.size < 1_000_000, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = String(decoding: (try? handle.read(upToCount: 64)) ?? Data(), as: UTF8.self)
        return prefix.hasPrefix("-----BEGIN") && prefix.contains("PRIVATE KEY-----")
    }
}
