import Foundation

/// What a scan found and did.
public struct ScanReport: Sendable {
    public struct Item: Sendable, Equatable {
        public var url: URL
        public var ruleID: String
        public var reason: String?
    }

    /// True if changes were written; false for a dry run.
    public var applied: Bool
    /// Newly excluded (or that would be, in a dry run).
    public var excluded: [Item] = []
    /// TMSkipper exclusions removed because their rule no longer applies.
    public var removed: [Item] = []
    /// Matched a rule but failed a safety check: left as they are.
    public var skipped: [Item] = []
    /// Already excluded by TMSkipper and still valid.
    public var kept: [Item] = []
    /// Matched a rule but were already excluded by someone else: left as they are.
    public var excludedByOthers: [Item] = []
    public var errors: [String] = []
    public var directoriesVisited = 0
    public var duration: TimeInterval = 0
}

/// Walks the roots, applies the rules and keeps the guarded paths excluded.
///
/// The walk never follows symbolic links and never descends into `.git`, into folders
/// that are already excluded, into rule matches, or into iCloud placeholders.
public struct FolderScanner {
    public let config: Config
    public let store: any ExclusionStore
    /// nil when git is not available: the tracked-files check is then skipped.
    public let git: (any GitClient)?

    public init(config: Config, store: any ExclusionStore = SystemExclusionStore(), git: (any GitClient)?) {
        self.config = config
        self.store = store
        self.git = git
    }

    /// Applies the rules (or only reports, when `apply` is false).
    public func scan(apply: Bool) -> ScanReport {
        let start = Date()
        var report = ScanReport(applied: apply)
        for root in config.roots {
            traverse(
                root: root, report: &report,
                onCandidate: { url, ruleID, repository, report in
                    handleCandidate(url, ruleID: ruleID, repository: repository, apply: apply, report: &report)
                },
                onExcluded: { url, report in
                    guard let marker = store.marker(of: url) else { return }
                    reconcile(url, marker: marker, apply: apply, report: &report)
                }
            )
        }
        guardPaths(apply: apply, report: &report)
        report.duration = Date().timeIntervalSince(start)
        return report
    }

    /// Every exclusion made by TMSkipper, found by its marker (returned in `kept`).
    public func findOwned() -> ScanReport {
        let start = Date()
        var report = ScanReport(applied: false)
        let collect: (URL, inout ScanReport) -> Void = { url, report in
            if let marker = store.marker(of: url), store.isExcluded(url) {
                report.kept.append(.init(url: url, ruleID: marker))
            }
        }
        for root in config.roots {
            traverse(
                root: root, report: &report,
                onCandidate: { url, _, _, report in collect(url, &report) },
                onExcluded: collect
            )
        }
        for url in config.guardedPaths where !report.kept.contains(where: { $0.url.fsPath == url.fsPath }) {
            collect(url, &report)
        }
        report.duration = Date().timeIntervalSince(start)
        return report
    }

    /// Removes every exclusion made by TMSkipper (returned in `removed`). Others are untouched.
    public func reset(apply: Bool) -> ScanReport {
        let owned = findOwned()
        var report = ScanReport(applied: apply)
        report.errors = owned.errors
        report.directoriesVisited = owned.directoriesVisited
        for item in owned.kept {
            if apply {
                do { try store.include(item.url) } catch {
                    report.errors.append("cannot remove the exclusion of \(item.url.fsPath): \(error.localizedDescription)")
                    continue
                }
            }
            report.removed.append(item)
        }
        report.duration = owned.duration
        return report
    }

    /// A large git-ignored folder that no rule covers: a hint for a new rule. Never excluded automatically.
    public struct Suggestion: Sendable {
        public var url: URL
        public var size: Int64
    }

    /// Git-ignored folders of at least `minimumSize` bytes that are not excluded and match no rule.
    public func suggestions(minimumSize: Int64) -> [Suggestion] {
        guard let git else { return [] }
        var repositories: [URL] = []
        var report = ScanReport(applied: false)
        for root in config.roots {
            traverse(
                root: root, report: &report,
                onCandidate: { _, _, _, _ in }, onExcluded: { _, _ in },
                onDirectory: { directory, names in
                    if names.contains(".git") { repositories.append(directory) }
                }
            )
        }
        var suggestions: [Suggestion] = []
        for repository in repositories {
            for relative in git.ignoredDirectories(in: repository) ?? [] {
                let url = repository.appending(path: relative)
                guard let info = FileSystem.info(url), info.isDirectory,
                      !store.isExcludedIncludingAncestors(url),
                      !matchesAnyRule(url)
                else { continue }
                let size = FileSystem.allocatedSize(of: url)
                if size >= minimumSize { suggestions.append(Suggestion(url: url, size: size)) }
            }
        }
        return suggestions.sorted { $0.size > $1.size }
    }

    private func matchesAnyRule(_ url: URL) -> Bool {
        stillMatches(url, ruleID: Rule.cacheDirTagID) || config.rules.contains { stillMatches(url, ruleID: $0.id) }
    }

    // MARK: - Walk

    /// The nearest folder above `url` that holds a `.git` entry, if any.
    static func enclosingRepository(of url: URL) -> URL? {
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.fsPath != "/" {
            if FileSystem.info(current.appending(path: ".git")) != nil { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private func traverse(
        root: URL,
        report: inout ScanReport,
        onCandidate: (URL, String, URL?, inout ScanReport) -> Void,
        onExcluded: (URL, inout ScanReport) -> Void,
        onDirectory: (URL, Set<String>) -> Void = { _, _ in }
    ) {
        guard let info = FileSystem.info(root), info.isDirectory else {
            report.errors.append("root \(root.fsPath) does not exist, is not a folder or is a symbolic link")
            return
        }
        // Nothing inside an excluded root is backed up anyway.
        if store.isExcludedIncludingAncestors(root) { return }

        var handled = Set<String>()
        // A root can lie inside a repository: the tracked-files check must still find it.
        var stack: [(directory: URL, repository: URL?)] = [(root, Self.enclosingRepository(of: root))]
        while let (directory, enclosingRepository) = stack.popLast() {
            report.directoriesVisited += 1
            let entries: [FileSystem.Entry]
            do {
                entries = try FileSystem.entries(of: directory)
            } catch {
                report.errors.append("cannot read \(directory.fsPath): \(error.localizedDescription)")
                continue
            }
            let names = Set(entries.map(\.name))
            onDirectory(directory, names)
            let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let repository = names.contains(".git") ? directory : enclosingRepository

            for rule in config.rules {
                let components = rule.folderComponents
                guard let first = byName[components[0]], first.isDirectory else { continue }
                let candidate = directory.appending(path: rule.folder)
                guard !handled.contains(candidate.fsPath) else { continue }
                // Every component must be a real folder: a symbolic link in the middle could lead outside the roots.
                if components.count > 1 {
                    var path = directory
                    guard components.allSatisfy({ component in
                        path = path.appending(path: component)
                        return FileSystem.info(path)?.isDirectory == true
                    }) else { continue }
                }
                guard RuleMatcher.sentinelsMatch(rule, in: directory, names: names) else { continue }
                handled.insert(candidate.fsPath)
                onCandidate(candidate, rule.id, repository, &report)
            }

            for entry in entries where entry.isDirectory && entry.name != ".git" {
                let path = entry.url.fsPath
                if handled.contains(path) { continue }
                if store.isExcluded(entry.url) {
                    onExcluded(entry.url, &report)
                    continue
                }
                guard let info = FileSystem.info(entry.url), info.isDirectory, !info.isDataless else { continue }
                if config.cacheDirTagEnabled && RuleMatcher.hasCacheDirTag(entry.url) {
                    handled.insert(path)
                    onCandidate(entry.url, Rule.cacheDirTagID, repository, &report)
                    continue
                }
                stack.append((entry.url, repository))
            }
        }
    }

    // MARK: - Decisions

    private func handleCandidate(_ candidate: URL, ruleID: String, repository: URL?, apply: Bool, report: inout ScanReport) {
        let item = ScanReport.Item(url: candidate, ruleID: ruleID)
        if store.isExcluded(candidate) {
            if let marker = store.marker(of: candidate) {
                revalidateOwned(candidate, marker: marker, apply: apply, report: &report)
            } else {
                report.excludedByOthers.append(item)
            }
            return
        }
        if config.isProtected(candidate) {
            report.skipped.append(.init(url: candidate, ruleID: ruleID, reason: "in protectedPaths"))
            return
        }
        if let reason = safetyIssue(candidate, repository: repository) {
            report.skipped.append(.init(url: candidate, ruleID: ruleID, reason: reason))
            return
        }
        if apply {
            do { try store.exclude(candidate, marker: ruleID) } catch {
                report.errors.append("cannot exclude \(candidate.fsPath): \(error.localizedDescription)")
                return
            }
        }
        report.excluded.append(item)
    }

    /// An excluded folder carrying TMSkipper's marker that no rule matched at its position.
    private func reconcile(_ url: URL, marker: String, apply: Bool, report: inout ScanReport) {
        // Guarded paths inside a root are handled by guardPaths.
        if marker == Rule.guardedMarker { return }
        if stillMatches(url, ruleID: marker) {
            revalidateOwned(url, marker: marker, apply: apply, report: &report)
        } else {
            remove(url, ruleID: marker, reason: "rule \(marker) no longer applies", apply: apply, report: &report)
        }
    }

    /// Keeps an existing TMSkipper exclusion, unless the folder became protected or holds a protected item.
    private func revalidateOwned(_ url: URL, marker: String, apply: Bool, report: inout ScanReport) {
        if config.isProtected(url) {
            remove(url, ruleID: marker, reason: "in protectedPaths", apply: apply, report: &report)
        } else if let info = FileSystem.info(url), info.isDirectory, !info.isDataless,
                  let item = RuleMatcher.protectedItem(in: url) {
            remove(url, ruleID: marker, reason: "now contains \(item)", apply: apply, report: &report)
        } else {
            report.kept.append(.init(url: url, ruleID: marker))
        }
    }

    private func remove(_ url: URL, ruleID: String, reason: String, apply: Bool, report: inout ScanReport) {
        if apply {
            do { try store.include(url) } catch {
                report.errors.append("cannot remove the exclusion of \(url.fsPath): \(error.localizedDescription)")
                return
            }
        }
        report.removed.append(.init(url: url, ruleID: ruleID, reason: reason))
    }

    private func stillMatches(_ url: URL, ruleID: String) -> Bool {
        if ruleID == Rule.cacheDirTagID {
            return config.cacheDirTagEnabled && RuleMatcher.hasCacheDirTag(url)
        }
        guard let rule = config.rules.first(where: { $0.id == ruleID }) else { return false }
        let components = rule.folderComponents
        let pathComponents = url.standardizedFileURL.pathComponents
        guard pathComponents.count > components.count,
              Array(pathComponents.suffix(components.count)) == components
        else { return false }
        var base = url
        for _ in components { base = base.deletingLastPathComponent() }
        // If the base cannot be read, keep the exclusion rather than guess.
        guard let entries = try? FileSystem.entries(of: base) else { return true }
        return RuleMatcher.sentinelsMatch(rule, in: base, names: Set(entries.map(\.name)))
    }

    private func safetyIssue(_ candidate: URL, repository: URL?) -> String? {
        guard let info = FileSystem.info(candidate), info.isDirectory else {
            return "not a folder (or a symbolic link)"
        }
        if info.isDataless { return "iCloud placeholder, not downloaded" }
        if let item = RuleMatcher.protectedItem(in: candidate) { return "contains \(item)" }
        if let repository, let git {
            switch git.hasTrackedFiles(in: candidate, repository: repository) {
            case true?: return "contains files tracked by git"
            case nil: return "git could not check for tracked files"
            case false?: break
            }
        }
        return nil
    }

    // MARK: - Guarded paths

    private func guardPaths(apply: Bool, report: inout ScanReport) {
        for url in config.guardedPaths {
            // Missing paths are fine: the tool for that cache may not be installed.
            guard let info = FileSystem.info(url), !info.isSymbolicLink else { continue }
            let item = ScanReport.Item(url: url, ruleID: Rule.guardedMarker)
            if store.isExcludedIncludingAncestors(url) {
                if store.isExcluded(url), store.marker(of: url) != nil {
                    revalidateOwned(url, marker: Rule.guardedMarker, apply: apply, report: &report)
                } else {
                    report.excludedByOthers.append(item)
                }
                continue
            }
            if config.isProtected(url) {
                report.skipped.append(.init(url: url, ruleID: item.ruleID, reason: "in protectedPaths"))
                continue
            }
            if info.isDataless {
                report.skipped.append(.init(url: url, ruleID: item.ruleID, reason: "iCloud placeholder, not downloaded"))
                continue
            }
            if info.isDirectory, let protected = RuleMatcher.protectedItem(in: url) {
                report.skipped.append(.init(url: url, ruleID: item.ruleID, reason: "contains \(protected)"))
                continue
            }
            if apply {
                do { try store.exclude(url, marker: Rule.guardedMarker) } catch {
                    report.errors.append("cannot exclude \(url.fsPath): \(error.localizedDescription)")
                    continue
                }
            }
            report.excluded.append(item)
        }
    }
}
