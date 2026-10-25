import Darwin
import Foundation

/// The per-user LaunchAgent that runs `tmskipper scan --quiet`.
///
/// Triggers: at login (`RunAtLoad`), every N hours (`StartCalendarInterval`, which launchd
/// runs on wake when the Mac was asleep at the scheduled time) and whenever a volume is
/// mounted (`StartOnMount`), so connecting the backup disk triggers a scan.
public enum LaunchAgent {
    public static var label: String { Identity.identifier }

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var errorLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TMSkipper/error.log")
    }

    private static var domain: String { "gui/\(getuid())" }

    /// `config` is written into the agent's environment: launchd does not pass on shell variables
    /// such as `XDG_CONFIG_HOME`, so without it the agent could read a different file.
    public static func propertyList(executable: URL, everyHours: Int, config: URL) -> [String: Any] {
        let hours = Array(stride(from: 0, to: 24, by: everyHours))
        return [
            "Label": label,
            "ProgramArguments": [executable.fsPath, "scan", "--quiet"],
            "RunAtLoad": true,
            "StartCalendarInterval": hours.map { ["Hour": $0, "Minute": 0] },
            "StartOnMount": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardErrorPath": errorLogURL.fsPath,
            "EnvironmentVariables": ["TMSKIPPER_CONFIG": config.fsPath],
        ]
    }

    /// Writes the property list and (re)loads the agent.
    public static func install(executable: URL, everyHours: Int, config: URL) throws {
        guard (1...24).contains(everyHours) else { throw ConfigError("--every must be between 1 and 24 hours") }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: errorLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList(executable: executable, everyHours: everyHours, config: config), format: .xml, options: 0
        )
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        try data.write(to: plistURL, options: .atomic)
        let result = launchctl(["bootstrap", domain, plistURL.fsPath])
        guard result.status == 0 else {
            throw ConfigError("launchctl bootstrap failed: \(result.output)")
        }
    }

    /// Unloads the agent and deletes its property list. Exclusions and config stay.
    public static func uninstall() throws {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.fsPath) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public static var isLoaded: Bool {
        launchctl(["print", "\(domain)/\(label)"]).status == 0
    }

    /// Config file path written in the installed property list, if any.
    public static var installedConfig: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let environment = plist["EnvironmentVariables"] as? [String: String]
        else { return nil }
        return environment["TMSKIPPER_CONFIG"]
    }

    /// Executable path written in the installed property list, if any.
    public static var installedExecutable: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
