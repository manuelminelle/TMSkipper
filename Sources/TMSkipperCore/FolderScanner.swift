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
    /// Former roots and guarded paths where an exclusion could not be removed: kept for the next scan.
    var unfinishedLocations = ScanLocations()
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
    /// Finds TMSkipper's exclusions on folders copied or moved out of the roots; nil skips that search.
    public let index: (any ExclusionIndex)?
    /// Roots and guarded paths of an earlier scan that the config no longer lists.
    public let formerRoots: [URL]
    public let formerGuardedPaths: [URL]
    /// Total time the git checks of one scan may take. Past it, the remaining candidates inside
    /// repositories are skipped, so the agent's scan ends before its 15-minute limit.
    public var gitTimeBudget: TimeInterval = 5 * 60

    /// `previous` is what the last applied scan covered (see `locations(after:)`).
    public init(
        config: Config, store: any ExclusionStore = SystemExclusionStore(), git: (any GitClient)?,
        index: (any ExclusionIndex)? = nil, previous: ScanLocations? = nil
    ) {
        self.config = config
        self.store = store
        self.git = git
        self.index = index
        let roots = config.roots.map(\.fsPath)
        formerRoots = (previous?.roots ?? [])
            .filter { former in !roots.contains { FileSystem.path(former, isInside: $0) } }
            .map { URL(filePath: $0) }
        let guarded = Set(config.guardedPaths.map(\.fsPath))
        formerGuardedPaths = (previous?.guardedPaths ?? []).filter { !guarded.contains($0) }.map { URL(filePath: $0) }
    }

    /// What to save after an applied scan: the current roots and guarded paths, plus the former ones
    /// where an exclusion could not be removed, so the next scan tries again.
    public func locations(after report: ScanReport) -> ScanLocations {
        var locations = ScanLocations(config)
        locations.roots += report.unfinishedLocations.roots.filter { !locations.roots.contains($0) }
        locations.guardedPaths += report.unfinishedLocations.guardedPaths.filter { !locations.guardedPaths.contains($0) }
        return locations
    }

    /// Applies the rules (or only reports, when `apply` is false).
    public func scan(apply: Bool) -> ScanReport {
        let start = Date()
        var report = ScanReport(applied: apply)
        let checks = GitChecks()
        for root in config.roots {
            traverse(
                root: root, report: &report,
                onCandidate: { url, ruleID, repository, report in
                    handleCandidate(url, ruleID: ruleID, repository: repository, checks: checks, apply: apply, report: &report)
                },
                onExcluded: { url, report in
                    guard let marker = store.marker(of: url) else { return }
                    reconcile(url, marker: marker, apply: apply, report: &report)
                }
            )
        }
        guardPaths(apply: apply, report: &report)
        removeOrphans(apply: apply, report: &report)
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
        for orphan in orphans(report: &report) where !report.kept.contains(where: { $0.url.fsPath == orphan.item.url.fsPath }) {
            report.kept.append(.init(url: orphan.item.url, ruleID: orphan.item.ruleID))
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

    /// `skipping` lists folders not to enter: current roots inside a former root.
    private func traverse(
        root: URL,
        report: inout ScanReport,
        skipping: [URL] = [],
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

        var handled = Set<String>(skipping.map(\.fsPath))
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

    private func handleCandidate(
        _ candidate: URL, ruleID: String, repository: URL?, checks: GitChecks, apply: Bool, report: inout ScanReport
    ) {
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
        if let reason = safetyIssue(candidate, repository: repository, checks: checks) {
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
        if marker == Rule.guardedMarker {
            // Guarded paths inside a root are handled by guardPaths.
            if config.guardedPaths.contains(where: { $0.fsPath == url.fsPath }) { return }
            remove(url, ruleID: marker, reason: "no longer a guarded path", apply: apply, report: &report)
            return
        }
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

    /// False if the exclusion could not be removed.
    @discardableResult
    private func remove(_ url: URL, ruleID: String, reason: String, apply: Bool, report: inout ScanReport) -> Bool {
        if apply {
            do { try store.include(url) } catch {
                report.errors.append("cannot remove the exclusion of \(url.fsPath): \(error.localizedDescription)")
                return false
            }
        }
        report.removed.append(.init(url: url, ruleID: ruleID, reason: reason))
        return true
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

    private func safetyIssue(_ candidate: URL, repository: URL?, checks: GitChecks) -> String? {
        guard let info = FileSystem.info(candidate), info.isDirectory else {
            return "not a folder (or a symbolic link)"
        }
        if info.isDataless { return "iCloud placeholder, not downloaded" }
        if let item = RuleMatcher.protectedItem(in: candidate) { return "contains \(item)" }
        if let repository, let git {
            if checks.failedRepositories.contains(repository.fsPath) { return "git could not check for tracked files" }
            if checks.elapsed >= gitTimeBudget { return "time limit for git checks reached in this scan" }
            let start = Date()
            let tracked = git.hasTrackedFiles(in: candidate, repository: repository)
            checks.elapsed += Date().timeIntervalSince(start)
            switch tracked {
            case true?: return "contains files tracked by git"
            case nil:
                checks.failedRepositories.insert(repository.fsPath)
                return "git could not check for tracked files"
            case false?: break
            }
        }
        return nil
    }

    // MARK: - Orphans

    /// An owned exclusion that the walk of the roots cannot reach, with the former root or guarded
    /// path it was found in, if any.
    private struct Orphan {
        var item: ScanReport.Item
        var formerRoot: String?
        var formerGuardedPath: String?
    }

    /// Removes the orphans: no rule checks them any more, and a copy or move out of the roots
    /// (a `dist` delivered elsewhere) must be backed up.
    private func removeOrphans(apply: Bool, report: inout ScanReport) {
        let current = Set((report.excluded + report.kept).map(\.url.fsPath))
        for orphan in orphans(report: &report) where !current.contains(orphan.item.url.fsPath) {
            let item = orphan.item
            guard !remove(item.url, ruleID: item.ruleID, reason: item.reason ?? "", apply: apply, report: &report) else { continue }
            if let root = orphan.formerRoot, !report.unfinishedLocations.roots.contains(root) {
                report.unfinishedLocations.roots.append(root)
            }
            if let path = orphan.formerGuardedPath { report.unfinishedLocations.guardedPaths.append(path) }
        }
    }

    /// TMSkipper's exclusions in a former root or guarded path, and those that Spotlight finds
    /// outside the roots and the guarded paths.
    private func orphans(report: inout ScanReport) -> [Orphan] {
        var orphans: [Orphan] = []
        var seen = Set<String>()
        func add(_ url: URL, reason: String, formerRoot: String? = nil, formerGuardedPath: String? = nil) {
            guard store.isExcluded(url), let marker = store.marker(of: url) else { return }
            // The same folder can come from a former root and from Spotlight under two names.
            let key = FileSystem.realPath(url) ?? url.fsPath
            guard !seen.contains(key), !isKnownLocation(url) else { return }
            seen.insert(key)
            orphans.append(Orphan(
                item: .init(url: url, ruleID: marker, reason: reason), formerRoot: formerRoot, formerGuardedPath: formerGuardedPath
            ))
        }

        for root in formerRoots where FileSystem.info(root)?.isDirectory == true {
            let errors = report.errors.count
            let reason = "its root was removed from the config"
            traverse(
                root: root, report: &report, skipping: config.roots,
                onCandidate: { url, _, _, _ in add(url, reason: reason, formerRoot: root.fsPath) },
                onExcluded: { url, _ in add(url, reason: reason, formerRoot: root.fsPath) }
            )
            // Part of it could not be read: look again next time.
            if report.errors.count > errors { report.unfinishedLocations.roots.append(root.fsPath) }
        }
        for url in formerGuardedPaths where store.marker(of: url) == Rule.guardedMarker {
            add(url, reason: "no longer a guarded path", formerGuardedPath: url.fsPath)
        }
        for url in index?.excludedItems() ?? [] {
            guard let info = FileSystem.info(url), !info.isSymbolicLink else { continue }
            add(url, reason: "outside the roots: copied or moved there")
        }
        return orphans
    }

    /// True if `url` is inside a root or is a guarded path, comparing every way of naming them:
    /// Spotlight reports real paths in their real case, while a root may be written in another
    /// case or reached through a symbolic link. Such an exclusion is never treated as an orphan.
    func isKnownLocation(_ url: URL) -> Bool {
        let paths = Self.names(of: url)
        let roots = config.roots.flatMap(Self.names)
        if paths.contains(where: { path in roots.contains { FileSystem.path(path, isInside: $0) } }) { return true }
        let guarded = Set(config.guardedPaths.flatMap(Self.names).map { $0.lowercased() })
        return paths.contains { guarded.contains($0.lowercased()) }
    }

    /// The path as written, with symbolic links resolved by Foundation (which drops `/private`) and by `realpath`.
    private static func names(of url: URL) -> [String] {
        [url.fsPath, url.resolvingSymlinksInPath().fsPath] + (FileSystem.realPath(url).map { [$0] } ?? [])
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

/// Per-scan state of the tracked-files check. A repository git could not answer for is not asked
/// again: a hostile one (for example with a named pipe as its index, which blocks git until it is
/// killed) would otherwise cost the full git timeout for every candidate it holds (verified).
private final class GitChecks {
    var failedRepositories = Set<String>()
    var elapsed: TimeInterval = 0
}
