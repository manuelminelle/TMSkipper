import Foundation

/// Evaluates rules and safety checks against the file system.
enum RuleMatcher {
    /// Signature that starts every valid CACHEDIR.TAG file (https://bford.info/cachedir/).
    static let cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// Names that must never end up excluded: if a candidate holds one at its top level, it is skipped.
    /// Matched ignoring case (`Credentials.json`, `KEY.PEM`). `.git` keeps a whole repository (for
    /// example one with a committed CACHEDIR.TAG) in the backup. `*.asc` is not listed: Maven signs
    /// its artifacts into `target` with public `.asc` signatures, and armoured private keys are
    /// recognised by content.
    static let protectedPatterns = [
        ".git", ".env*", "*.p8", "*.p12", "*.pfx", "*.pem", "*.key", "*.ppk", "*.jks", "*.keystore",
        "*.mobileprovision", "*.cer", "id_rsa*", "id_dsa*", "id_ed25519*", "id_ecdsa*",
        "*.gpg", "*.kdbx", "*.keychain", "*.keychain-db",
        "gradle.properties", ".npmrc", ".netrc", "credentials*", "secrets*",
    ]

    /// Bytes read from the start of each top-level file when looking for a private key.
    static let keySearchBytes = 4096

    /// PEM, OpenSSH and PGP armour of a private key ("-----BEGIN … PRIVATE KEY-----",
    /// "-----BEGIN PGP PRIVATE KEY BLOCK-----"), wherever it appears in the bytes read.
    nonisolated(unsafe) static let privateKeyArmor = #/-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----/#

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
        guard let info = FileSystem.info(url), info.size < 1_000_000,
              let data = FileSystem.readPrefix(of: url, maxBytes: 1_000_000),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return ["dependencies", "devDependencies"].contains { key in
            (json[key] as? [String: Any])?[dependency] != nil
        }
    }

    /// True if `directory` holds a CACHEDIR.TAG file with the standard signature.
    static func hasCacheDirTag(_ directory: URL) -> Bool {
        let tag = directory.appending(path: "CACHEDIR.TAG")
        guard let data = FileSystem.readPrefix(of: tag, maxBytes: cacheDirTagSignature.utf8.count) else { return false }
        return String(decoding: data, as: UTF8.self) == cacheDirTagSignature
    }

    /// Name of the first protected item at the top level of `directory`, if any.
    /// An unreadable directory counts as protected: nothing is excluded without looking at it first.
    static func protectedItem(in directory: URL) -> String? {
        guard let entries = try? FileSystem.entries(of: directory) else { return "(unreadable folder)" }
        if let byName = entries.first(where: { entry in
            protectedPatterns.contains { FileSystem.matches(entry.name, pattern: $0, ignoringCase: true) }
        }) {
            return byName.name
        }
        // Keys are often saved under custom names: also look at what the files contain.
        return entries.first { !$0.isDirectory && !$0.isSymbolicLink && isPrivateKey($0.url) }?.name
    }

    /// True if the file holds a private key in its first bytes: PEM, OpenSSH or PGP armour, also inside
    /// JSON (a Google Cloud service-account key) or after a byte-order mark, or a PuTTY key.
    /// A placeholder whose content is in iCloud counts as a key: it cannot be read without downloading it.
    /// Named pipes, sockets and devices are never opened.
    static func isPrivateKey(_ url: URL) -> Bool {
        guard let info = FileSystem.info(url), info.isRegularFile else { return false }
        if info.isDataless { return true }
        guard let data = FileSystem.readPrefix(of: url, maxBytes: keySearchBytes) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("PuTTY-User-Key-File-") || text.contains(privateKeyArmor)
    }
}
