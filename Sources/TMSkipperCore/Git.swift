import Foundation

/// The git queries TMSkipper needs. A protocol so tests can replace it.
public protocol GitClient {
    /// True if `folder` contains files tracked in the repository at `repository`; nil if git could not tell.
    func hasTrackedFiles(in folder: URL, repository: URL) -> Bool?
    /// Paths of the `folders` that contain files tracked in the repository at `repository`, in one
    /// query; nil if git could not tell.
    func trackedFolders(among folders: [URL], repository: URL) -> Set<String>?
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

    public func trackedFolders(among folders: [URL], repository: URL) -> Set<String>? {
        let root = repository.fsPath
        let relatives = folders.compactMap { folder -> (relative: String, path: String)? in
            let path = folder.fsPath
            guard path.hasPrefix(root + "/") else { return nil }
            return (String(path.dropFirst(root.count + 1)), path)
        }
        var tracked = Set<String>()
        // A few hundred paths per call stay far below the argument size limit.
        for start in stride(from: 0, to: relatives.count, by: 200) {
            let chunk = relatives[start..<min(start + 200, relatives.count)]
            guard let output = Self.run(executable, ["-C", root, "ls-files", "-z", "--"] + chunk.map(\.relative)),
                  output.status == 0
            else { return nil }
            for file in output.data.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
                for folder in chunk where file.hasPrefix(folder.relative + "/") { tracked.insert(folder.path) }
            }
        }
        return tracked
    }

    public func ignoredDirectories(in repository: URL) -> [String]? {
        let arguments = ["-C", repository.fsPath, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"]
        guard let output = Self.run(executable, arguments), output.status == 0 else { return nil }
        return output.data.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
    }

    /// Seconds after which a git call is killed and its answer treated as unknown.
    static let timeout: TimeInterval = 60

    /// Settings that override the repository's own configuration. A folder under the roots can be a
    /// downloaded `.git` with a hostile config: `core.fsmonitor` names a program that git runs on
    /// `ls-files` (verified), and TMSkipper runs git unattended. Command-line settings take precedence.
    /// `--literal-pathspecs` keeps a folder name such as `:(attr:x)build` from being read as pathspec
    /// magic, which made `ls-files` miss tracked files (verified).
    static let hardening = [
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.hooksPath=/dev/null",
    ]

    /// The caller's environment without git's own variables. `GIT_DIR`, `GIT_WORK_TREE`,
    /// `GIT_INDEX_FILE` or `GIT_CONFIG_*`, set by a hook or an IDE terminal, point git at another
    /// repository or configuration, and its empty answer then reads as "no tracked files" (verified).
    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        return environment
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, data: Data)? {
        Subprocess.run(
            executable,
            executable.lastPathComponent == "git" ? hardening + arguments : arguments,
            environment: environment(from: ProcessInfo.processInfo.environment),
            timeout: timeout
        )
    }
}

/// What `lstat` says about a repository's index file. git rewrites the index (through a rename) on
/// every commit, `add` or checkout, so an unchanged state means that nothing was staged or committed
/// since it was taken.
public struct GitIndexState: Codable, Sendable, Hashable {
    public var inode: UInt64
    public var size: Int64
    public var modified: Int64

    /// State of an index that does not exist: nothing was ever staged.
    static let absent = GitIndexState(inode: 0, size: -1, modified: 0)

    init(inode: UInt64, size: Int64, modified: Int64) {
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    /// The state of the index of the repository at `repository`, or nil if it cannot be found:
    /// TMSkipper then always asks git. `.git` is a folder, or a file naming one ("gitdir: …") for
    /// worktrees and submodules. Only `lstat` is used, never `open`, on anything inside `.git`.
    public init?(repository: URL) {
        let dotGit = repository.appending(path: ".git")
        guard let info = FileSystem.info(dotGit) else { return nil }
        let gitDirectory: URL
        if info.isDirectory {
            gitDirectory = dotGit
        } else if info.isRegularFile, let data = FileSystem.readPrefix(of: dotGit, maxBytes: 4096) {
            let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first ?? ""
            guard line.hasPrefix("gitdir:") else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            gitDirectory = path.hasPrefix("/") ? URL(filePath: path) : repository.appending(path: path)
        } else {
            return nil
        }
        var st = stat()
        let result = gitDirectory.appending(path: "index").withUnsafeFileSystemRepresentation { lstat($0!, &st) }
        if result != 0 {
            guard errno == ENOENT, FileSystem.info(gitDirectory)?.isDirectory == true else { return nil }
            self = .absent
            return
        }
        // A symbolic link or anything else would not change when the index does.
        guard st.st_mode & S_IFMT == S_IFREG else { return nil }
        self.init(
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            modified: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        )
    }
}
