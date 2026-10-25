# Contributing

Thanks for helping. TMSkipper is a small personal project maintained in spare time, so issues and pull requests may take a while to be answered.

TMSkipper decides what is **not** backed up. Every change is judged first by one question: could it ever exclude something that cannot be rebuilt?

## Build and test

Requires macOS 13 or later and a Swift 6 toolchain (Xcode or the Command Line Tools).

```bash
swift build
swift test
```

To try a change on your own projects without touching anything:

```bash
swift run tmskipper scan --dry-run
```

Use `TMSKIPPER_CONFIG=/path/to/config.json` to point a run at a test configuration instead of your own.

## Layout

| Path | Contents |
|---|---|
| `Sources/TMSkipperCore/Rule.swift` | The rule type and the default rules |
| `Sources/TMSkipperCore/RuleMatcher.swift` | Sentinel matching and the safety checks (secrets, private keys, CACHEDIR.TAG) |
| `Sources/TMSkipperCore/FolderScanner.swift` | The walk, the decisions, guarded paths, `list`, `reset`, `suggest` |
| `Sources/TMSkipperCore/ExclusionStore.swift` | Reading and writing the exclusion and the ownership marker |
| `Sources/TMSkipperCore/ExclusionIndex.swift` | The Spotlight query that finds exclusions copied out of the roots |
| `Sources/TMSkipperCore/Git.swift` | The hardened git calls (tracked and ignored files) and the index state |
| `Sources/TMSkipperCore/FileSystem.swift` | `lstat`, non-blocking reads, directory listing, path comparison |
| `Sources/TMSkipperCore/Support.swift` | Identity, logging, subprocesses, the scan lock and the state files |
| `Sources/TMSkipperCore/Config.swift` | Config file, defaults, protected and guarded paths |
| `Sources/TMSkipperCore/LaunchAgent.swift` | The LaunchAgent property list and `launchctl` calls |
| `Sources/tmskipper/main.swift` | The command-line interface |
| `DECISIONS.md` | Why things are the way they are, with measurements |

Read [DECISIONS.md](DECISIONS.md) before changing how exclusions are written, how the walk works or when the agent runs.

## Proposing a new rule

Open an issue with the *New rule* template, or a pull request. A rule is accepted when:

1. **The folder is regenerable with one command** of the tool that creates it (`npm ci`, `cargo build`, `flutter pub get`, …), from files that stay in the backup.
2. **The sentinel is specific.** It must be a file that the tool needs and that sits next to the folder: `Cargo.toml` for `target`, not a generic name. If the folder name is common (`build`, `dist`, `out`, `bin`, `target`), the sentinel must belong to one ecosystem only.
3. **The folder never holds user data**: no configuration you edit, no credentials, no deliverables.

For a pull request:

- add the rule to `Rule.defaults` in `Rule.swift`, with a unique `id` and the ecosystem name;
- add a test in `Tests/TMSkipperCoreTests/FolderScannerTests.swift` covering both the match and a folder with the same name but without the sentinel;
- update the *Default rules* table in `README.md` and the *Unreleased* section of `CHANGELOG.md`.

Folders that are only *often* regenerable, such as `dist`, `build` or `vendor` without a framework-specific sentinel, are left to each user's config file.

## Code

- Swift 6 language mode, strict concurrency, no third-party dependencies.
- Keep the scan single-threaded: Foundation's exclusion setter is not reliable across threads (see DECISIONS.md, D3).
- Write exclusions only through `ExclusionStore`: Foundation's setter follows symbolic links, and the store makes sure every write lands on the folder that was checked (D3, D12).
- Never follow symbolic links or open files that could block: use `FileSystem.info` and `FileSystem.readPrefix`.
- Match the surrounding style: small types, comments that explain *why*.
- Tests that touch real file attributes live in `SystemTests` and run serialized.

## Pull requests

- One topic per pull request.
- `swift build` with no warnings and `swift test` passing (CI runs both).
- Describe how you tested it, ideally with a `tmskipper scan --dry-run` output. Remove personal paths from anything you paste.
