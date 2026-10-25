# Changelog

## 0.2.0

Security fixes from a review before the first public release. Upgrade from 0.1.0, which is affected by all of them.

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

Fixes from a second review:

- Folders copied or moved out of the roots (`cp -R`, `ditto` and `mv` carry the exclusion) are found through Spotlight and their exclusion is removed; `list` and `reset` show and remove them too.
- Exclusions left in a root or guarded path removed from the config are removed at the next scan, and `list` and `reset` still see them (`locations.json` in the support folder).
- git no longer inherits `GIT_DIR`, `GIT_INDEX_FILE` or other `GIT_*` variables, and never reads folder names as pathspec magic.
- A repository git cannot answer for is asked once per scan, and all git checks of a scan share a 5-minute budget.
- The secret check ignores letter case, knows more key and password-database files (`*.pfx`, `*.ppk`, `*.kdbx`, `*.keychain-db`, `*.gpg`, …) and finds PGP, PuTTY and JSON-embedded private keys in the first 4 KB of a file.
- `status` replaces control characters in saved errors; bidirectional overrides are replaced in all output.
- `protectedPaths` also match candidates under a root reached through a symbolic link.

Fixes from a review of the accepted risks:

- Exclusions are written through a descriptor that never follows symbolic links. Before, a folder replaced by a link during a scan could leave an exclusion on the link's target that `list` and `reset` cannot see, and removing one could clear an exclusion made by someone else.
- Files committed into an already excluded folder are now noticed: the next scan removes its exclusion. git is asked once per repository, and only when its index changed since the last scan (`repositories.json` in the support folder).

Other changes:

- A dry run's summary now says "to exclude" and "to remove" instead of "excluded" and "removed".
- Documentation for publishing: example output and troubleshooting in the README, CONTRIBUTING.md, SECURITY.md, issue and pull request templates.

## 0.1.0

First release. Not supported: it has the security issues fixed in 0.2.0.

- Sentinel rules for Node.js and its frameworks, Apple, Gradle/Android, Rust, Python, Dart/Flutter, .NET, Elixir, Zig, Haskell and Terraform, plus any folder holding a valid `CACHEDIR.TAG`.
- Safety checks before every exclusion: secrets and private keys (by name and by content), files tracked by git, symbolic links, iCloud placeholders.
- Credential stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, …) always protected; `protectedPaths` for anything else.
- Guarded global caches (Xcode DerivedData, simulators, npm, Gradle, Cargo, …) re-excluded when recreated.
- Ownership marker, so `list` and `reset` only touch TMSkipper's own exclusions; stale exclusions removed when a rule stops matching.
- `suggest` lists large git-ignored folders that no rule covers, without excluding them.
- LaunchAgent: scan at login, every 6 hours (catching up on wake) and when a volume is mounted.
- Project folders detected automatically (`~/Developer`, `~/Projects`, `~/Code`, …) when the config file sets no roots.
