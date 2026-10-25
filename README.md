# TMSkipper

Keeps regenerable development folders (`node_modules`, `.next`, Gradle `build`, `.venv`, Rust `target`, …) out of Time Machine backups, automatically and safely.

TMSkipper **never deletes anything**. It only sets, or removes, the same backup exclusion that `tmutil addexclusion` sets, and only on folders it can prove are generated.

## Why

Generated folders take gigabytes and tens of thousands of files, change all the time and can be rebuilt with one command. Backing them up wastes disk space and slows every backup.

Existing tools fall short in one of two ways:

- **[Asimov](https://github.com/AsimovMac/asimov)** calls `tmutil addexclusion`, which takes 1 to 11 seconds per folder (11 for hidden ones such as `.next`), and runs once a day.
- **[tmignore](https://github.com/samuelmeuli/tmignore)** excludes everything in `.gitignore`. That includes `.env` files, which hold secrets that exist only on your machine, and other ignored folders that cannot be rebuilt: deliveries, raw data, screenshots.

TMSkipper sets the exclusion through the Foundation API in about a millisecond. It excludes a folder only when a *sentinel* file proves it is generated. See [DECISIONS.md](DECISIONS.md) for the measurements and trade-offs.

## How it works

- **Sentinel rules.** `node_modules` is excluded only if a `package.json` sits next to it, `build` only next to `build.gradle`, `target` only next to `Cargo.toml` or `pom.xml`, and so on. Folders tagged with a standard [`CACHEDIR.TAG`](https://bford.info/cachedir/) (Cargo, pytest, mypy, ruff, …) are excluded too.
- **Safety checks.** A matching folder is still skipped if it contains secrets (`.env*`, keys, certificates, keystores, `gradle.properties`, any file starting with `-----BEGIN … PRIVATE KEY-----`), contains files tracked by git, is a symbolic link or is an iCloud placeholder. Credential stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/Library/Keychains`, …) are never excluded, nor is any folder containing them.
- **Guarded paths.** Global caches (`~/Library/Developer/Xcode/DerivedData`, simulator data, `~/.npm`, Gradle and Cargo caches, …) are re-excluded whenever they are deleted and recreated.
- **Ownership marker.** Every exclusion made by TMSkipper carries an extra attribute, so `list` and `reset` never touch exclusions you made by hand. When a rule stops matching, the exclusion it added is removed.
- **Triggers.** A LaunchAgent runs a short scan at login, every 6 hours (catching up on wake if the Mac was asleep) and whenever a disk is mounted, so connecting the backup disk starts a scan first. No resident process, no polling, no network, no `sudo`.

## Install

Requires macOS 13 or later and a Swift 6 toolchain (Xcode or the Command Line Tools).

```bash
git clone https://github.com/manuelminelle/TMSkipper.git
cd TMSkipper
scripts/install.sh            # builds, copies to ~/.local/bin, starts the agent
```

Make sure `~/.local/bin` is on your `PATH`. Use `PREFIX=/some/dir scripts/install.sh` to install elsewhere, and `scripts/install.sh --every 12` for a different interval.

Before installing, preview what would change:

```bash
swift run -c release tmskipper scan --dry-run
```

## Commands

| Command | What it does |
|---|---|
| `tmskipper scan --dry-run` | Shows what would be excluded, with sizes. Changes nothing. |
| `tmskipper scan` | Applies the rules. This is what the agent runs. |
| `tmskipper list` | Lists the exclusions made by TMSkipper, with sizes. |
| `tmskipper reset [--dry-run]` | Removes every exclusion made by TMSkipper. Others are untouched. |
| `tmskipper suggest [--min-size MB]` | Lists large git-ignored folders that no rule covers. Never excludes them: ignored is not the same as regenerable. |
| `tmskipper rules` | Shows roots, active rules, guarded and protected paths. |
| `tmskipper status` | Shows the agent, the config file and the last scan. |
| `tmskipper init` | Writes a config file to edit. |
| `tmskipper install` / `uninstall` | Starts or removes the LaunchAgent. |

Check any folder with `tmutil isexcluded <path>`. The log is in the unified log:

```bash
/usr/bin/log show --last 1d --info --predicate 'subsystem == "io.github.manuelminelle.tmskipper"'
```

## Configuration

Everything works without a config file. To change the defaults, run `tmskipper init` and edit `~/.config/tmskipper/config.json`:

```json
{
  "roots": ["~/Developer", "~/Projects"],
  "rules": {
    "disable": ["js-coverage"],
    "add": [
      { "id": "godot", "folder": ".godot", "sentinels": ["project.godot"], "ecosystem": "Godot" }
    ]
  },
  "guardedPaths": {
    "disable": ["~/.cache"],
    "add": ["~/.colima"]
  },
  "protectedPaths": ["~/Developer/client/release-package"]
}
```

- **`roots`**: folders scanned with the rules. Without it, TMSkipper scans the usual project folders that exist: `~/Developer`, `~/Projects`, `~/Code`, `~/src`, `~/dev`, `~/repos`, `~/workspace`, `~/GitHub`.
- **`rules.disable`**: rule ids to turn off (see `tmskipper rules`); `cachedir-tag` turns off the CACHEDIR.TAG rule.
- **`rules.add`**: new rules. An added rule with the id of a default rule replaces it.
- **`guardedPaths`**: global paths to keep excluded.
- **`protectedPaths`**: folders never excluded, with everything inside them.

Sentinel syntax, relative to the folder's parent:

| Sentinel | Matches when |
|---|---|
| `package.json` | the file or folder exists |
| `next.config.*` | an entry matches the wildcard |
| `.vercel/project.json` | the nested path exists |
| `package.json#next` | `package.json` declares `next` in `dependencies` or `devDependencies` |

## Default rules

| Ecosystem | Folders (sentinel) |
|---|---|
| Node.js and frameworks | `node_modules` (`package.json`), `.next` (`next.config.*` or `next` dependency), `out` (`next.config.*`), `.nuxt` and `.output` (`nuxt.config.*`), `.astro` and `dist` (`astro.config.*`), `.svelte-kit`, `.angular`, `.turbo`, `.parcel-cache`, `.expo`, `coverage` |
| Deploy tools | `.wrangler` (`wrangler.*`), `.vercel/output`, `supabase/.temp`, `supabase/.branches` |
| Apple | `.build` (`Package.swift`), `DerivedData` (`*.xcodeproj`, `*.xcworkspace`), `Pods` (`Podfile`), `Carthage/Build` |
| Android / JVM | `build`, `.gradle`, `.gradle-user`, `.kotlin`, `.cxx` (Gradle files), `target` (`pom.xml`) |
| Rust | `target` (`Cargo.toml`) |
| Python | `.venv`, `venv` (`pyproject.toml`, `requirements.txt`, …), `__pycache__` (`*.py`), `.tox` |
| Dart / Flutter | `.dart_tool`, `build` (`pubspec.yaml`) |
| .NET | `bin`, `obj` (`*.csproj`, `*.fsproj`, `*.vbproj`) |
| Others | Elixir `_build`, `deps`; Zig `.zig-cache`, `zig-out`; Haskell `.stack-work`, `dist-newstyle`; Terraform `.terraform` |
| Any | folders holding a valid `CACHEDIR.TAG` |

A plain `dist` or `build` folder without a framework-specific sentinel is never excluded: it may be a deliverable.

## Uninstall

```bash
scripts/uninstall.sh --reset   # stops the agent, removes TMSkipper's exclusions and the binary
```

Without `--reset` the exclusions stay in place. The config file in `~/.config/tmskipper` is kept.

## Development

```bash
swift build
swift test
```

## License

MIT. See [LICENSE](LICENSE).

TMSkipper is not affiliated with or endorsed by Apple. Time Machine is a trademark of Apple Inc.
