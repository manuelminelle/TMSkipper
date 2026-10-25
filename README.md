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
- **Safety checks.** A matching folder is still skipped if its top level holds secrets (`.env*`, keys, certificates, keystores, password databases, `gradle.properties`, matched in any letter case, and any file whose first 4 KB hold a PEM, OpenSSH, PGP or PuTTY private key, also inside JSON such as a Google Cloud service-account key) or a `.git` entry, if it contains files tracked by git (checked again, once per repository, whenever something is staged or committed), or if it is a symbolic link or an iCloud placeholder. The secret check looks at the folder's top level only, and the git check does not cover what lies deeper: secrets are usually git-ignored, and a repository nested inside the folder is not seen by the outer one. Keep secrets out of generated folders, or list such folders in `protectedPaths`. Credential stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/Library/Keychains`, …) are never excluded, nor is any folder containing them.
- **Guarded paths.** Global caches (`~/Library/Developer/Xcode/DerivedData`, simulator data, `~/.npm`, Gradle and Cargo caches, …) are re-excluded whenever they are deleted and recreated.
- **Ownership marker.** Every exclusion made by TMSkipper carries an extra attribute, so `list` and `reset` never touch exclusions you made by hand. When a rule stops matching, the exclusion it added is removed. So are its exclusions in a root or guarded path removed from the config, and on folders copied or moved out of the roots (`cp -R`, `ditto` and `mv` carry the exclusion along) when Spotlight can see them.
- **Untrusted folders.** Project folders may come from archives or downloads, so the scan never follows symbolic links, never opens named pipes or devices, reads at most the first bytes of a few files, and runs git with the repository's own hooks and monitors disabled, the caller's `GIT_*` variables cleared, folder names never read as pathspec magic and a time limit. A repository git cannot answer for is asked once per scan, and all git checks of a scan share a 5-minute budget. Exclusions are written through a handle that never follows symbolic links, even if a folder is replaced by one during the scan.
- **Triggers.** A LaunchAgent runs a short scan at login, every 6 hours (catching up on wake if the Mac was asleep) and whenever a disk is mounted, so connecting the backup disk starts a scan first. No resident process, no polling, no network, no `sudo`.

## Example

A dry run on a folder of sample projects:

```text
$ tmskipper scan --dry-run
Would exclude:
  ~/Projects/android-app/.gradle  [gradle-cache]  8.2 MB
  ~/Projects/android-app/app/build  [gradle-build]  46.1 MB
  ~/Projects/ios-kit/.build  [swiftpm-build]  61.4 MB
  ~/Projects/py-tool/.pytest_cache  [cachedir-tag]  4 KB
  ~/Projects/py-tool/.venv  [python-venv]  30.7 MB
  ~/Projects/web-app/.next  [next]  92.2 MB
  ~/Projects/web-app/node_modules  [node-modules]  204.8 MB
  Total: 443.4 MB

Skipped (safety checks):
  ~/Projects/docs-site/dist  [astro-dist]  (contains files tracked by git)
  ~/Projects/release-kit/build  [gradle-build]  (contains upload.keystore)

Dry run, nothing changed. 8 folders visited in 0.09 s: 7 to exclude, 0 to remove, 2 skipped, 0 already excluded by TMSkipper, 0 already excluded by others, 0 errors
```

`web-app/.env.local` is not in the list: files and folders without a matching rule are never touched. The committed `dist` and the `build` folder holding a keystore are skipped by the safety checks.

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

## Troubleshooting

**A folder was not excluded.** Run `tmskipper scan --dry-run` and look for it:

- under *Skipped*, with the reason: it contains files tracked by git, a secret or a private key, or it is in `protectedPaths`;
- not listed at all: check that it is inside one of the roots (`tmskipper rules`) and that the rule's sentinel sits next to it. Folders inside an already excluded folder are not scanned, because Time Machine skips them anyway.

If the folder is regenerable but no rule covers it, add one (see [Configuration](#configuration)). `tmskipper suggest` lists large git-ignored folders that may need a rule.

**A folder I want backed up was excluded.** Add it to `protectedPaths`, or disable the rule in `rules.disable`. The next scan removes the exclusion TMSkipper had added.

**Undo everything.** Stop the agent first, otherwise it excludes the folders again at the next scan:

```bash
tmskipper uninstall
tmskipper reset
```

or `scripts/uninstall.sh --reset`, which also removes the binary. Exclusions you made by hand or with other tools are never touched.

**I copied a generated folder elsewhere.** `cp -R`, `ditto` and `mv` copy the exclusion along with the folder, so a `dist` copied out as a delivery would not be backed up. The next scan finds TMSkipper's exclusions outside the roots through Spotlight and removes them, but Spotlight does not see hidden folders or folders inside them. To copy without the exclusion, use `cp -RX` or `ditto --noextattr`, and check with `tmutil isexcluded <path>`.

**Check that a folder is excluded.** `tmutil isexcluded <path>` reads the attribute. To see a real backup, open Time Machine from the menu bar and press <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>.</kbd> to show hidden folders. Commands such as `tmutil listbackups` need Full Disk Access for the terminal app; TMSkipper itself never does.

**`log show` fails with "too many arguments".** zsh can shadow Apple's `log` with a built-in command. Use the full path: `/usr/bin/log show …`.

**`tmskipper status` says the agent is not loaded, or the executable is missing.** Run `scripts/install.sh` again. Startup errors are written to `~/Library/Logs/TMSkipper/error.log`, and `launchctl print gui/$(id -u)/io.github.manuelminelle.tmskipper` shows launchd's view of the agent.

**"warning: git not found".** The tracked-files safety check needs git: install the Command Line Tools (`xcode-select --install`) or git from Homebrew. Without git the other checks still apply.

**Scans run often while I work.** The agent also starts when any volume is mounted, including disk images and simulator runtimes. A scan takes about a second at low priority, so this is harmless.

**Hidden folders and Spotlight.** At the start of a backup Time Machine asks Spotlight for excluded items, and Spotlight does not index hidden folders such as `.next`. Time Machine also reads the exclusion on each item while copying, and hidden folders excluded by TMSkipper were verified absent from real backups.

**Local snapshots still contain excluded folders.** Time Machine's local snapshots copy the whole volume; exclusions apply to the copy on the backup disk. Local snapshots are deleted automatically after about 24 hours or when space is needed.

## Uninstall

```bash
scripts/uninstall.sh --reset   # stops the agent, removes TMSkipper's exclusions and the binary
```

Without `--reset` the exclusions stay in place. The config file in `~/.config/tmskipper` is kept.

## Contributing

Bug reports and new rules are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem privately, see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

TMSkipper is not affiliated with or endorsed by Apple. Time Machine is a trademark of Apple Inc.
