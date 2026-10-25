# Changelog

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
