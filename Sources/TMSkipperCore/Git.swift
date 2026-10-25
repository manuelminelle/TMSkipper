import Foundation

/// The git queries TMSkipper needs. A protocol so tests can replace it.
public protocol GitClient {
    /// True if `folder` contains files tracked in the repository at `repository`; nil if git could not tell.
    func hasTrackedFiles(in folder: URL, repository: URL) -> Bool?
    /// Ignored directories of the repository, as paths relative to its root.
    func ignoredDirectories(in repository: URL) -> [String]?
}

/// Runs the git executable. Read-only commands only, with optional locks disabled.
public struct Git: GitClient {
    public let executable: URL

    /// Finds a git executable without triggering the "install the command line tools" dialog:
    /// `/usr/bin/git` is only a shim when no developer directory is selected.
    public static func locate() -> Git? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return Git(executable: URL(filePath: path))
        }
        guard let output = run(URL(filePath: "/usr/bin/xcode-select"), ["-p"]), output.status == 0 else {
            return nil
        }
        return Git(executable: URL(filePath: "/usr/bin/git"))
    }

    public func hasTrackedFiles(in folder: URL, repository: URL) -> Bool? {
        let root = repository.fsPath
        let path = folder.fsPath
        guard path.hasPrefix(root + "/") else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        guard let output = Self.run(executable, ["-C", root, "ls-files", "-z", "--", relative]),
              output.status == 0
        else { return nil }
        return !output.data.isEmpty
    }

    public func ignoredDirectories(in repository: URL) -> [String]? {
        let arguments = ["-C", repository.fsPath, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"]
        guard let output = Self.run(executable, arguments), output.status == 0 else { return nil }
        return output.data.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
    }

    /// Settings that override the repository's own configuration. A folder under the roots can be a
    /// downloaded `.git` with a hostile config: `core.fsmonitor` names a program that git runs on
    /// `ls-files` (verified), and TMSkipper runs git unattended. Command-line settings take precedence.
    /// Seconds after which a git call is killed and its answer treated as unknown.
    static let timeout: TimeInterval = 60

    static let hardening = [
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.hooksPath=/dev/null",
    ]

    private static func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, data: Data)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = executable.lastPathComponent == "git" ? hardening + arguments : arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A git that never returns (huge repository, broken file system) must not stall the agent.
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data)
    }
}
