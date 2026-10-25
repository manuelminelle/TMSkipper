import Foundation
import TMSkipperCore

let usage = """
TMSkipper \(Identity.version): keeps regenerable development folders out of Time Machine backups.
It only sets or removes the backup exclusion: it never deletes files.

Usage: tmskipper <command> [options]

Commands:
  scan [--dry-run] [--no-sizes] [--quiet]
                       Exclude the folders matched by the rules and keep guarded paths excluded.
                       --dry-run shows what would change without touching anything.
  list [--no-sizes]    List the exclusions made by TMSkipper.
  reset [--dry-run]    Remove every exclusion made by TMSkipper (others are untouched).
  suggest [--min-size <MB>]
                       List large git-ignored folders that no rule covers (default: 100 MB).
  rules                Show the active rules and guarded paths.
  status               Show the agent, the configuration and the last scan.
  init                 Write a config file to edit (\(display(Config.defaultFileURL))).
  install [--every <hours>]
                       Install and start the LaunchAgent (default: every 6 hours).
  uninstall            Stop and remove the LaunchAgent. Exclusions stay; use reset first to remove them.
  version              Print the version.

"""

// MARK: - Helpers

/// Path with the home folder shortened to "~".
func display(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
    let path = url.fsPath
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("tmskipper: \(message)\n".utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    printError(message)
    exit(code)
}

/// Parses `--flag` and `--option value` arguments; exits on anything unknown.
struct Options {
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ arguments: ArraySlice<String>, flags allowedFlags: Set<String> = [], values allowedValues: Set<String> = []) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if allowedFlags.contains(argument) {
                flags.insert(argument)
            } else if allowedValues.contains(argument) {
                guard let value = iterator.next() else { fail("\(argument) needs a value", code: 2) }
                values[argument] = value
            } else {
                fail("unknown option \(argument)\n\n\(usage)", code: 2)
            }
        }
    }
}

func loadConfig() -> Config {
    do {
        return try Config.load()
    } catch {
        Log.scan.error("configuration error: \(String(describing: error), privacy: .public)")
        fail("configuration error: \(error)")
    }
}

func makeScanner(_ config: Config, quiet: Bool) -> FolderScanner {
    let git = Git.locate()
    if git == nil {
        Log.scan.notice("git not found: the tracked-files safety check is disabled")
        if !quiet { printError("warning: git not found, the tracked-files safety check is disabled") }
    }
    return FolderScanner(config: config, git: git)
}

func ruleLabel(_ ruleID: String) -> String {
    ruleID == Rule.guardedMarker ? "guarded path" : ruleID
}

func printItems(_ title: String, _ items: [ScanReport.Item], sizes: Bool) {
    guard !items.isEmpty else { return }
    print(title)
    var total: Int64 = 0
    for item in items.sorted(by: { $0.url.fsPath < $1.url.fsPath }) {
        var line = "  \(display(item.url))  [\(ruleLabel(item.ruleID))]"
        if sizes {
            let size = FileSystem.allocatedSize(of: item.url)
            total += size
            line += "  \(FileSystem.formatSize(size))"
        }
        if let reason = item.reason { line += "  (\(reason))" }
        print(line)
    }
    if sizes && items.count > 1 { print("  Total: \(FileSystem.formatSize(total))") }
    print("")
}

func summary(_ report: ScanReport) -> String {
    let seconds = String(format: "%.2f", report.duration)
    return "\(report.directoriesVisited) folders visited in \(seconds) s: "
        + "\(report.excluded.count) excluded, \(report.removed.count) removed, "
        + "\(report.skipped.count) skipped, \(report.kept.count) already excluded by TMSkipper, "
        + "\(report.excludedByOthers.count) already excluded by others, \(report.errors.count) errors"
}

// MARK: - Commands

func scan(_ options: Options) -> Int32 {
    let dryRun = options.flags.contains("--dry-run")
    let quiet = options.flags.contains("--quiet")
    let sizes = !options.flags.contains("--no-sizes") && !quiet
    let lock: ScanLock?
    do { lock = try ScanLock() } catch { fail("cannot create the lock file: \(error.localizedDescription)") }
    guard let lock else {
        if !quiet { print("Another scan is running.") }
        return 0
    }
    defer { withExtendedLifetime(lock) {} }

    let scanner = makeScanner(loadConfig(), quiet: quiet)
    let report = scanner.scan(apply: !dryRun)

    if !dryRun {
        for item in report.excluded {
            Log.scan.notice("excluded \(item.url.fsPath, privacy: .public) [\(item.ruleID, privacy: .public)]")
        }
        for item in report.removed {
            Log.scan.notice("removed exclusion \(item.url.fsPath, privacy: .public) [\(item.ruleID, privacy: .public)]: \(item.reason ?? "", privacy: .public)")
        }
        for item in report.skipped {
            Log.scan.notice("skipped \(item.url.fsPath, privacy: .public) [\(item.ruleID, privacy: .public)]: \(item.reason ?? "", privacy: .public)")
        }
        for error in report.errors { Log.scan.error("\(error, privacy: .public)") }
        Log.scan.notice("\(summary(report), privacy: .public)")
        do { try LastScan(report).save() } catch { printError("cannot save the scan summary: \(error.localizedDescription)") }
    }

    if quiet {
        report.errors.forEach(printError)
    } else {
        printItems(dryRun ? "Would exclude:" : "Excluded:", report.excluded, sizes: sizes)
        printItems(dryRun ? "Would remove the exclusion of:" : "Removed the exclusion of:", report.removed, sizes: false)
        printItems("Skipped (safety checks):", report.skipped, sizes: false)
        if !report.errors.isEmpty {
            print("Errors:")
            report.errors.forEach { print("  \($0)") }
            print("")
        }
        print((dryRun ? "Dry run, nothing changed. " : "") + summary(report))
    }
    return report.errors.isEmpty ? 0 : 1
}

func list(_ options: Options) -> Int32 {
    let report = makeScanner(loadConfig(), quiet: true).findOwned()
    if report.kept.isEmpty {
        print("No exclusions made by TMSkipper.")
    } else {
        printItems("Excluded by TMSkipper:", report.kept, sizes: !options.flags.contains("--no-sizes"))
    }
    report.errors.forEach(printError)
    return report.errors.isEmpty ? 0 : 1
}

func reset(_ options: Options) -> Int32 {
    let dryRun = options.flags.contains("--dry-run")
    let report = makeScanner(loadConfig(), quiet: true).reset(apply: !dryRun)
    if report.removed.isEmpty {
        print("No exclusions made by TMSkipper.")
    } else {
        printItems(dryRun ? "Would remove the exclusion of:" : "Removed the exclusion of:", report.removed, sizes: false)
        if !dryRun {
            Log.scan.notice("reset: removed \(report.removed.count) exclusions")
            if LaunchAgent.isLoaded {
                print("The LaunchAgent is still running and will exclude them again at the next scan.")
                print("Run `tmskipper uninstall` to stop it.")
            }
        }
    }
    report.errors.forEach(printError)
    return report.errors.isEmpty ? 0 : 1
}

func suggest(_ options: Options) -> Int32 {
    var megabytes: Int64 = 100
    if let value = options.values["--min-size"] {
        guard let parsed = Int64(value), parsed >= 0 else { fail("--min-size needs a number of megabytes", code: 2) }
        megabytes = parsed
    }
    let scanner = makeScanner(loadConfig(), quiet: false)
    guard scanner.git != nil else { fail("suggest needs git") }
    let suggestions = scanner.suggestions(minimumSize: megabytes * 1_000_000)
    guard !suggestions.isEmpty else {
        print("No git-ignored folder of \(megabytes) MB or more outside the rules.")
        return 0
    }
    print("Large git-ignored folders that no rule covers (not excluded):")
    for suggestion in suggestions {
        print("  \(FileSystem.formatSize(suggestion.size))  \(display(suggestion.url))")
    }
    print("\nIf one is regenerable, add a rule to \(display(Config.defaultFileURL)) (see README).")
    return 0
}

func rules() -> Int32 {
    let config = loadConfig()
    print("Roots:")
    config.roots.forEach { print("  \(display($0))") }
    if config.roots.isEmpty { print("  (none: set \"roots\" in \(display(Config.defaultFileURL)))") }
    print("\nRules (folder ← sentinels):")
    for rule in config.rules {
        print("  \(rule.id): \(rule.folder) ← \(rule.sentinels.joined(separator: ", "))  [\(rule.ecosystem)]")
    }
    if config.cacheDirTagEnabled {
        print("  \(Rule.cacheDirTagID): any folder holding a valid CACHEDIR.TAG")
    }
    print("\nGuarded paths:")
    for url in config.guardedPaths {
        let present = FileSystem.info(url) != nil
        print("  \(display(url))\(present ? "" : "  (not present)")")
    }
    if !config.protectedPaths.isEmpty {
        print("\nProtected paths (never excluded):")
        config.protectedPaths.forEach { print("  \(display($0))") }
    }
    return 0
}

func status() -> Int32 {
    print("TMSkipper \(Identity.version)\n")
    let installed = FileManager.default.fileExists(atPath: LaunchAgent.plistURL.fsPath)
    if installed {
        print("Agent:      \(LaunchAgent.isLoaded ? "running" : "installed but not loaded") (\(display(LaunchAgent.plistURL)))")
        if let executable = LaunchAgent.installedExecutable {
            let exists = FileManager.default.isExecutableFile(atPath: executable)
            print("Executable: \(display(URL(filePath: executable)))\(exists ? "" : "  (MISSING: reinstall)")")
        }
    } else {
        print("Agent:      not installed (run `tmskipper install`)")
    }

    let configURL = Config.defaultFileURL
    let hasConfig = FileManager.default.fileExists(atPath: configURL.fsPath)
    print("Config:     \(display(configURL))\(hasConfig ? "" : "  (not present: using defaults)")")
    do {
        let config = try Config.load()
        let roots = config.roots.map(display).joined(separator: ", ")
        print("Roots:      \(roots.isEmpty ? "none: set \"roots\" in the config file" : roots)")
    } catch {
        print("Config:     ERROR \(error)")
    }

    if let last = LastScan.load() {
        let date = last.date.formatted(date: .abbreviated, time: .shortened)
        let ago = last.date.formatted(.relative(presentation: .named))
        print("Last scan:  \(date) (\(ago)), \(String(format: "%.2f", last.duration)) s, \(last.directoriesVisited) folders")
        print("            \(last.excluded) excluded, \(last.removed) removed, \(last.skipped) skipped, \(last.kept) kept, \(last.errors.count) errors")
        last.errors.forEach { print("            error: \($0)") }
    } else {
        print("Last scan:  never")
    }
    print("\nLog:        /usr/bin/log show --last 1d --info --predicate 'subsystem == \"\(Identity.identifier)\"'")
    return 0
}

func initConfig() -> Int32 {
    let url = Config.defaultFileURL
    if FileManager.default.fileExists(atPath: url.fsPath) {
        print("\(display(url)) already exists.")
        return 0
    }
    let roots = Config.detectRoots()
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Config.template(roots: roots).write(to: url, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(display(url)): \(error.localizedDescription)")
    }
    print("Wrote \(display(url)).")
    if roots.isEmpty {
        print("No usual project folder found: add yours to \"roots\".")
    } else {
        print("Roots: \(roots.joined(separator: ", ")). Edit \"roots\" to change them.")
    }
    return 0
}

func install(_ options: Options) -> Int32 {
    var hours = 6
    if let value = options.values["--every"] {
        guard let parsed = Int(value) else { fail("--every needs a number of hours", code: 2) }
        hours = parsed
    }
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        fail("cannot find the path of this executable")
    }
    if executable.fsPath.contains("/.build/") {
        fail("this binary lives in a build folder that can be cleaned at any time.\nInstall with scripts/install.sh, which copies it to ~/.local/bin first.")
    }
    do {
        try LaunchAgent.install(executable: executable, everyHours: hours)
    } catch {
        fail("install failed: \(error)")
    }
    print("Installed \(display(LaunchAgent.plistURL)).")
    print("Scans run at login, every \(hours) h (on wake if the Mac was asleep) and when a disk is mounted.")
    print("A first scan is running now: see `tmskipper status`.")
    return 0
}

func uninstall() -> Int32 {
    do { try LaunchAgent.uninstall() } catch { fail("uninstall failed: \(error.localizedDescription)") }
    print("LaunchAgent removed. Existing exclusions stay: `tmskipper reset` removes them.")
    return 0
}

// MARK: - Entry point

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "help"
let rest = arguments.dropFirst()

let code: Int32
switch command {
case "scan": code = scan(Options(rest, flags: ["--dry-run", "--quiet", "--no-sizes"]))
case "list": code = list(Options(rest, flags: ["--no-sizes"]))
case "reset": code = reset(Options(rest, flags: ["--dry-run"]))
case "suggest": code = suggest(Options(rest, values: ["--min-size"]))
case "rules": _ = Options(rest); code = rules()
case "status": _ = Options(rest); code = status()
case "init": _ = Options(rest); code = initConfig()
case "install": code = install(Options(rest, values: ["--every"]))
case "uninstall": _ = Options(rest); code = uninstall()
case "version", "--version", "-v": print(Identity.version); code = 0
case "help", "--help", "-h": print(usage, terminator: ""); code = 0
default: fail("unknown command \(command)\n\n\(usage)", code: 2)
}
exit(code)
