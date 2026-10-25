# Decisions

Design choices for TMSkipper, the alternatives considered and why they were rejected.
Measurements were taken on a MacBook Pro (Apple Silicon), macOS 27.2, Swift 6.4, on 2026-10-23.

## D1. Build a custom tool instead of using an existing one

| Tool | Why it was not enough |
|---|---|
| Asimov | Runs every 24 h by default and calls `tmutil addexclusion` for every folder. `tmutil` takes 1 s per visible folder and 11 s per hidden one (see D3), so a first run with 40 folders can take minutes. It cannot tell its own exclusions from manual ones, so there is no safe `reset`. |
| tmignore / tmignore-rs | Excludes everything listed in `.gitignore`, which includes `.env` files: secrets that exist only on this machine are exactly what a backup must keep. |
| asimeow | Not evaluated in depth. Same `tmutil`-based approach. |

Asimov's sentinel idea (exclude a folder only if the file that generates it sits next to it) is kept as the core rule.

## D2. Swift, as a command-line Swift Package with no dependencies

- The exclusion API (`URLResourceValues.isExcludedFromBackup`) is only available natively. From a shell script the choice would be `tmutil` (slow, D3) or writing Apple's private binary plist into the extended attribute by hand (fragile, undocumented).
- One self-contained binary, no interpreter that changes with OS updates (rules out Python and Node).
- Command-line parsing is hand-written: the command set is small and `swift-argument-parser` would be the only dependency.

## D3. Set exclusions with the Foundation API, never with `tmutil`

Measured:

| Method | Time per folder |
|---|---|
| `URLResourceValues.isExcludedFromBackup = true` | 1–2 ms, any folder |
| `tmutil addexclusion <path>`, visible folder | 1.0 s |
| `tmutil addexclusion <path>`, hidden folder (`.next`, `.gradle`, `.venv`, …) or outside the Spotlight index | 11.0 s, 0% CPU |
| `tmutil addexclusion <p1> <p2> <p3>`, hidden folders | 33 s (batching does not help) |
| `tmutil removeexclusion <path>` | same as `addexclusion` |

Both methods write the same extended attribute (`com.apple.metadata:com_apple_backup_excludeItem` = `com.apple.backupd`) and `tmutil isexcluded` reports both as `[Excluded]`.

Why `tmutil` is slow: a sample of the waiting process shows it blocked in `_MDPerfWaitFileIndexingMarkerProcessed`, waiting for Spotlight to index the change. Spotlight does not index hidden folders, so for them the wait always runs into a ~11 s timeout. The backup destination plays no part (measured with none configured). Many generated folders are hidden, so a `tmutil`-based tool pays the 11 s on most of them.

Two caveats found while testing, both handled in `SystemExclusionStore`:

- Reading back through `resourceValues(forKeys:)` right after a change can return a cached value. The exclusion state is read from the attribute itself.
- The Foundation setter is not reliable across threads: with 8 threads setting and clearing exclusions, 10 clears out of 1,600 had no effect; on a single thread 0 out of 700. TMSkipper is single-threaded, verifies the attribute after every write and clears it directly if needed. The tests that touch real attributes run serialized.
- The Foundation setter takes a path and follows a symbolic link at its end (verified), while the rest of TMSkipper never follows one. Every write therefore opens the item first (`O_NOFOLLOW`, which refuses a link), writes the marker and verifies the exclusion through that descriptor, and hands the setter the item's current path from `fcntl(F_GETPATH)`, taken right before the call (D12).

## D4. Item-bound ("sticky") exclusions, not fixed-path ones

`man tmutil` calls the default, attribute-based exclusion *sticky*: it travels with the item. `tmutil addexclusion -p` creates a *fixed-path* exclusion stored in Time Machine's preferences and requires root.

- Fixed-path exclusions need `sudo` (a hard requirement says no) and leave stale entries behind when projects move.
- Sticky exclusions disappear when the folder is deleted (`rm -rf node_modules && npm install`). This is why the tool must re-check regularly (D5).

## D5. Periodic scans triggered by launchd, not a resident FSEvents watcher

The first proposal was a resident watcher on FSEvents, to beat the hourly Time Machine backup. The real usage pattern changed the trade-off:

- the backup disk is connected by cable every 1–4 days, not hourly;
- the Mac spends a lot of time asleep with the lid closed.

What matters is that everything is excluded **when the disk is connected**. The LaunchAgent therefore runs a short scan and exits. Measured on `~/Developer` (3,239 folders visited): 1.5 s for a run with 18 new candidates, most of it spent in one `git ls-files` per new candidate (D7); later runs skip already-excluded folders and the git check.

| Trigger | launchd key | Purpose |
|---|---|---|
| Login | `RunAtLoad` | Catch up after a reboot. |
| Every 6 hours | `StartCalendarInterval` | `man launchd.plist`: calendar intervals missed while asleep are coalesced into one run on wake. `StartInterval` instead silently skips them, so it is not used. |
| A volume is mounted | `StartOnMount` | Connecting the backup disk triggers a scan before Time Machine starts copying. Fires for every mount (disk images, simulator runtimes): harmless, a scan is cheap. |

Rejected:
- FSEvents watcher: a resident process, stream handling, event IDs and debouncing, for no gain with backups every few days.
- `WatchPaths`: not recursive, and `man launchd.plist` itself calls it race-prone.

Known gap: a folder recreated between the last scan and the moment the disk is mounted is caught by the mount trigger; if Time Machine starts first, that folder lands in one backup and is excluded from the next one. To be confirmed by timing the gap between mount and backup start.

## D6. Rules: a sentinel next to the folder, data-driven, extensible

- A folder is excluded only if a sentinel proving it is generated sits in the same directory (`node_modules` + `package.json`, `build` + `build.gradle`, `target` + `Cargo.toml`, …).
- The rule table ships with defaults for many ecosystems, including ones not in use today, so new languages work out of the box.
- Folders tagged with a valid `CACHEDIR.TAG` (the Cache Directory Tagging Specification used by Cargo, pytest, mypy, ruff and others) are excluded by a generic built-in rule.
- Users change the defaults in `~/.config/tmskipper/config.json` (disable by id, add, override) without recompiling. JSON because Foundation decodes it natively.
- `dist` is never excluded on its own: it can be a deliverable. Only framework-specific output folders with a framework-specific sentinel are covered (Astro `dist` + `astro.config.*`, Next.js `out` + `next.config.*`).

## D7. Safety checks before every new exclusion

A candidate that matches a rule is still skipped when:

1. it contains secrets or credentials at its top level (`.env*`, `*.p8`, `*.p12`, `*.pfx`, `*.pem`, `*.key`, `*.ppk`, `*.jks`, `*.keystore`, `*.kdbx`, `*.keychain-db`, `gradle.properties`, …), matched in any letter case;
2. it contains files tracked by git: a committed `build/` or `dist/` is intentional and must be backed up;
3. it is a symbolic link, or an iCloud placeholder (dataless) that reading would download.

The tool never descends into `.git`, into symbolic links, or into folders that are already excluded.

Private keys are often saved under custom names (`vps-root`, `deploy`), so name patterns are not enough: any top-level file whose first 4 KB hold `-----BEGIN … PRIVATE KEY-----` or `-----BEGIN PGP PRIVATE KEY BLOCK-----` (also inside JSON, as in a Google Cloud service-account key, or after a byte-order mark), or that starts like a PuTTY key, also blocks the exclusion. `*.asc` is deliberately not a name pattern: Maven writes public `.asc` signatures into `target`.

Credential stores are always protected and cannot be unprotected from the config: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.config/gcloud`, `~/.password-store`, `~/.netrc`, `~/Library/Keychains`. A folder that contains one of them (for example `~/.config`) cannot be excluded either.

On top of the automatic checks, `protectedPaths` in the config lists folders that are never excluded, together with their contents, such as a release package kept next to its build tree. An existing TMSkipper exclusion inside a newly protected path, or one that now contains a secret, is removed at the next scan. So is one into which files were committed later, checked again with one git call per repository whenever the repository's index changed (D12).

### Why "ignored by git" is not a rule

`tmskipper suggest` lists large git-ignored folders that no rule covers, for the user to judge. Its first run on `~/Developer` found a folder of delivered videos, build artifacts kept on purpose, raw seed data and app screenshots: all git-ignored, none regenerable. This is the concrete reason tmignore's approach was rejected and why `suggest` never excludes anything by itself.

## D8. Ownership marker on the folder instead of a registry file

Every exclusion made by TMSkipper also gets a second extended attribute, `io.github.manuelminelle.tmskipper.rule`, holding the rule id.

- It moves and disappears with the folder, so it can never drift out of sync like a separate registry file.
- `list` and `reset` find TMSkipper's exclusions by scanning for the marker, and never touch exclusions made by hand or by other apps.
- When a rule stops matching (sentinel removed, rule disabled), the next scan removes the exclusion it had added.
- The marker also travels with copies: `cp -R`, `ditto` and `mv` carry both attributes along (verified), so a `dist` copied out as a delivery would stay excluded where no scan looks. Each scan asks Spotlight, which Time Machine itself queries for sticky exclusions, for excluded items in the home folder (about 0.25 s), and removes TMSkipper's exclusions found outside the roots and the guarded paths. Spotlight does not index hidden folders or folders inside them, so this catches most copies, not all. Roots are compared in every form (as written, real path, any letter case), so an exclusion inside a root is never taken for a copy.
- The roots and guarded paths of the last applied scan are saved in `~/Library/Application Support/TMSkipper/locations.json`. When the config stops listing one, the next scan walks it once more and removes the exclusions TMSkipper left there, and `list` and `reset` still see them; a location is forgotten only once that worked.

## D9. Guarded global paths

Some caches live outside the project roots (`~/Library/Developer/Xcode/DerivedData`, simulator data, `~/.npm`, Gradle caches, …). They are usually excluded once by hand, but a sticky exclusion is lost when the folder is deleted and recreated, which is common for `DerivedData`.

TMSkipper re-checks a short list of guarded paths at every scan and re-excludes them if needed. Whole configuration folders are not in the defaults when they can hold secrets: `~/.gradle/caches` and `~/.gradle/wrapper` are guarded, `~/.gradle` (which may contain `gradle.properties` with signing passwords) is not.

## D10. Logging and status

- Changes and errors go to the unified log (`os_log`, subsystem `io.github.manuelminelle.tmskipper`): no log file to rotate.
- The last scan's summary is written to `~/Library/Application Support/TMSkipper/last-scan.json` and shown by `tmskipper status`. `locations.json` next to it holds the roots and guarded paths of that scan (D8), `repositories.json` the state of the git index of each repository whose exclusions that scan found free of tracked files (D12).
- No notifications: a command-line binary has no app bundle, and the log plus `status` are enough.

## D11. English, open-source-ready, private until proven

Code, comments and documentation are in English so the project can be published. The repository stays private until the tool has run through a few weeks of real backups. No personal data in the repository: the original brief (`PROMPT.md`) is kept out of git, and the history was restarted from a single clean commit before release.

Settled before publishing, because they cannot change later without breaking existing installs:

- **Identifiers.** The ownership marker written on users' folders, the LaunchAgent label and the log subsystem use `io.github.manuelminelle.tmskipper`: a namespace tied to the GitHub account, the usual choice for open-source tools without a domain. Renaming the marker later would hide every existing exclusion from `list` and `reset`.
- **Default roots.** `~/Developer` is common on macOS but far from universal. Without `roots` in the config, the usual project folders that exist are scanned (`~/Developer`, `~/Projects`, `~/Code`, `~/src`, `~/dev`, `~/repos`, `~/workspace`, `~/GitHub`); symbolic links and roots nested inside another root are skipped.

## D12. Security review before release

Project folders are partly untrusted: they hold archives, downloads and other people's repositories, and the agent works on them unattended. A review (one pass by the author, one independent pass that did not see the first one's conclusions) found and fixed, each with a regression test that fails without the fix:

| Finding | Severity | Fix |
|---|---|---|
| A `.git/config` with `core.fsmonitor` made `git ls-files` run an arbitrary program (verified) | High | git runs with `-c core.fsmonitor=false -c core.untrackedCache=false -c core.hooksPath=/dev/null`, which override the repository's settings, and is killed after 60 s |
| A named pipe in a candidate folder blocked the scan forever and, through the lock, every later scan (verified) | Medium | Files are opened with `O_NONBLOCK \| O_NOFOLLOW` and read only if `fstat` says they are regular; the agent's scan ends after 15 minutes; skipped scans are logged |
| A repository whose top level held a committed `CACHEDIR.TAG` was excluded whole, sources and `.git` included (verified) | Medium | `.git` is a protected name: a folder holding it is never excluded |
| With a root inside a repository, the tracked-files check was skipped (verified) | Medium | The enclosing repository is looked up above each root |
| The agent did not inherit `XDG_CONFIG_HOME` or `TMSKIPPER_CONFIG`, so it could read a different config than the shell | Medium | The resolved config path is written into the agent's environment at install time |
| `protectedPaths` compared paths with exact case, while APFS ignores it (verified) | Low | Case-insensitive comparison, plus the target of a protected symbolic link |
| A nested rule folder could pass through a symbolic link in the middle of its path (verified) | Low | Every component must be a real folder |
| `~/.cache` was guarded by default but may hold tokens | Low | Removed from the defaults |

A second review, on the fixed code, found and fixed, again each with a regression test that fails without the fix:

| Finding | Severity | Fix |
|---|---|---|
| `cp -R`, `ditto` and `mv` copy the exclusion and the marker: a `dist` copied out as a delivery stayed excluded, invisible to `scan`, `list` and `reset` (verified) | Medium | Each scan asks Spotlight for excluded items in the home folder and removes TMSkipper's exclusions outside the roots and guarded paths; `list` and `reset` include them (D8) |
| `GIT_DIR`, `GIT_INDEX_FILE` or `GIT_CONFIG_*` inherited from a hook or an IDE terminal pointed git at another repository, whose empty answer read as "no tracked files" (verified) | Low | git runs without the caller's `GIT_*` variables |
| A root or guarded path removed from the config left its exclusions behind, unseen by `list` and `reset`, which the recovery steps in SECURITY.md rely on | Low | The locations of the last scan are saved and cleaned up once they leave the config (D8); a guarded marker inside a root that is no longer guarded is removed |
| The secret check matched names with exact case, missed `*.pfx`, `*.ppk`, `*.kdbx`, `*.keychain-db`, `*.gpg` and PGP private keys, and read only 64 bytes (verified) | Low | Names matched ignoring case, more patterns, 4 KB searched for PEM, OpenSSH, PGP and PuTTY keys |
| A named pipe as `.git/index` blocked git until its 60-second timeout for every candidate in that repository; enough of them ended the agent's scan at 15 minutes, every time (verified) | Low | A repository git cannot answer for is asked once per scan; all git checks of a scan share a 5-minute budget |
| A folder name such as `:(attr:x)build` was read as pathspec magic, so `ls-files` missed tracked files (verified) | Low | `--literal-pathspecs` |
| `status` printed saved scan errors, which hold untrusted file names, without replacing control characters; bidirectional overrides were never replaced | Low | Control and format characters (except the emoji joiner) become "?" everywhere |
| Under a root reached through a symbolic link, a protected path written with the real location did not match | Low | Candidates are compared by their real location too |

A review of the accepted risks listed below found and fixed two more, each with a regression test that fails without the fix:

| Finding | Severity | Fix |
|---|---|---|
| The Foundation setter follows a symbolic link at the end of the path (verified). A folder replaced by a link to another folder between the checks and the write left the marker on the link and the exclusion on its target, where `list` and `reset` cannot see it; removing an exclusion through the link cleared the target's own exclusion, made by someone else (both verified) | Low | Writes go through a descriptor opened with `O_NOFOLLOW`: a link is refused, the marker is written and the result verified on the opened item, and the setter gets the item's current path from `F_GETPATH`, so a folder renamed meanwhile is still the one written. Only something put in its place in the instant between `F_GETPATH` and the setter could still receive the write; the identity check afterwards reports it as an error naming the path |
| A folder already excluded was never checked again for git-tracked files, so files committed into it later had no working copy in the backups (their content is in `.git`, which is backed up, but uncommitted edits to them were not) | Low | Each scan checks the kept exclusions of a repository again, with one `git ls-files` for all of them, when the repository's index (found through `.git`, a folder or a `gitdir:` file) changed since the last scan found them clean. git rewrites the index on every commit and `add`, so an unchanged index needs no git call: on `~/Developer` the first scan checked every repository in 1.6 s in total, later ones ask git only where something was staged or committed. The index state is taken before git is asked, so a commit made during the scan is caught by the next one |

Accepted, documented risks:

- **Top-level secret check.** Only the top level of a candidate is checked for secret names and private keys. The tracked-files check does not make up for it: secrets are usually git-ignored, and a repository nested deeper inside a candidate (a git dependency in Elixir's `deps`, for example) is not seen by the outer one.
- **Copies Spotlight cannot see.** Copies of excluded folders inside hidden folders, or in places excluded from Spotlight or outside the home folder, are not found. The README tells how to copy without the exclusion.
- **Same-user attacker.** A process running as the user could still put a symbolic link in place of a folder in the instant between `F_GETPATH` and the Foundation setter, which only takes a path; the check afterwards reports it, but cannot undo a write that went elsewhere. Such a process could already change the user's backups directly, so this gives it nothing new. Writing the attribute through the descriptor (`fsetxattr`) would close the gap, but means writing Apple's binary plist by hand instead of using the documented API (D2).
- **Index rewritten without a change.** A repository whose index is not a regular file, or cannot be found, is checked again at every scan. One whose index keeps the same inode, size and modification time across a commit would not be: git always writes a new index through a rename, so this needs a tool that edits it in place.
- **Paths in the unified log** are logged as public so that `log show` is useful; they stay on the Mac unless the user shares a system diagnostic report.

## Verification status

| Hypothesis | Result |
|---|---|
| The API exclusion is recognised like `tmutil addexclusion` | Confirmed: same attribute, `tmutil isexcluded` → `[Excluded]`. |
| `tmutil` takes ~11 s per call | Partly: 1 s for visible folders, 11 s for hidden ones; caused by a Spotlight wait, not by the destination (D3). |
| Time Machine honours exclusions on folders Spotlight does not index | Confirmed. At backup start backupd logs "Querying Spotlight to find sticky exclusions", and Spotlight knew only 5 of the 15 exclusions (the visible ones). During the copy it also reads the attribute item by item ("Failed to read sticky exclusion extended attribute for …" on files deleted mid-backup). In the first real backup (2026-10-23) all 15 folders, the 10 hidden ones included, are absent. |
| Special permissions needed to set exclusions in `~/Developer` | None needed: `~/Developer` is not a privacy-protected folder. |
| The exclusion is lost when the folder is deleted and recreated | Confirmed by `SystemTests.exclusionIsLostWhenFolderIsRecreated`. |
| Paths with spaces | Covered by tests and by real project folders whose names contain spaces. |
| First scan of `~/Developer` takes a few seconds at most | Confirmed: 1.5 s (D5). |
| `WatchPaths` is not recursive | Not needed any more (D5); documented as race-prone. |
| Calendar intervals missed during sleep run on wake | Observed: with the Mac asleep at 06:00, the scheduled scan ran at 06:02 during a wake. |
| Excluded folders are absent from a real backup | Confirmed on the first backup: the 15 TMSkipper exclusions and the guarded caches are absent; the files next to them (`package.json`, config files, sources), `~/.ssh`, every `.env*` file and the protected release folder are present. |
| Delay between mounting the disk and the backup start | Observed on an automatic backup (cable plugged in after wake, 2026-10-24): mount-triggered scan at 07:33:46 (0.8 s), automatic backup requested at 07:33:50, exclusions read at 07:33:54. The scan finished about 4 s before the request and 8 s before the exclusions were read. A scan with many new folders (one git check each, low-priority I/O) took up to 4.8 s, still inside the window but with less margin. |
| Local APFS snapshots | backupd takes a local snapshot of the whole Data volume (`com.apple.TimeMachine.<date>.local`) and copies from it, applying the exclusions to the copy. Local snapshots therefore contain everything, briefly, as expected. |
