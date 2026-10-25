# Changelog

## Unreleased

Security fixes from a review before the first public release:

- A repository with a hostile `.git/config` (`core.fsmonitor`) could make git run a program when TMSkipper queried it. git now runs with hooks, file-system monitors and the untracked cache disabled, and with a 60-second limit.
- A named pipe inside a project could block a scan forever and stop the agent. Files are now read only if they are regular files, without ever blocking; an unattended scan also ends after 15 minutes.
- A folder holding a `.git` entry is never excluded, so a repository with a committed `CACHEDIR.TAG` stays in the backup.
- Folders under a root that lies inside a repository now get the tracked-files check too.
- The LaunchAgent now reads the same config file as the shell that installed it (`TMSKIPPER_CONFIG` in its environment); `status` warns when they differ.
- `protectedPaths` matching ignores letter case and also protects the target of a symbolic link.
- Rules with nested folders never cross a symbolic link in the middle of the path.
- `~/.cache` is no longer guarded by default: tools such as Hugging Face keep tokens there.
- The ownership marker is written before the exclusion, so an interrupted write can never leave an exclusion that `list` and `reset` cannot see.
- Control characters in file names are replaced before printing.
- CI runs with read-only permissions and a pinned checkout action.

Other changes:

- A dry run's summary now says "to exclude" and "to remove" instead of "excluded" and "removed".
- Documentation for publishing: example output and troubleshooting in the README, CONTRIBUTING.md, SECURITY.md, issue and pull request templates.

## 0.1.0

First release.

- Sentinel rules for Node.js and its frameworks, Apple, Gradle/Android, Rust, Python, Dart/Flutter, .NET, Elixir, Zig, Haskell and Terraform, plus any folder holding a valid `CACHEDIR.TAG`.
- Safety checks before every exclusion: secrets and private keys (by name and by content), files tracked by git, symbolic links, iCloud placeholders.
- Credential stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, …) always protected; `protectedPaths` for anything else.
- Guarded global caches (Xcode DerivedData, simulators, npm, Gradle, Cargo, …) re-excluded when recreated.
- Ownership marker, so `list` and `reset` only touch TMSkipper's own exclusions; stale exclusions removed when a rule stops matching.
- `suggest` lists large git-ignored folders that no rule covers, without excluding them.
- LaunchAgent: scan at login, every 6 hours (catching up on wake) and when a volume is mounted.
- Project folders detected automatically (`~/Developer`, `~/Projects`, `~/Code`, …) when the config file sets no roots.
