# Security policy

TMSkipper changes what Time Machine backs up. A bug that excludes the wrong folder can silently remove data from your backups, so these reports are treated as security issues.

## What to report

- Anything that makes TMSkipper exclude data that cannot be regenerated: source code, configuration, secrets, private keys, credential stores, deliverables.
- A way around `protectedPaths` or the always-protected credential stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, …).
- The scan following symbolic links, leaving the configured roots, or downloading iCloud placeholders.
- `reset` or `list` touching exclusions that TMSkipper did not create.
- Anything that leads to running code, writing files outside TMSkipper's own folders, or needing elevated privileges.

A rule that misses a regenerable folder is not a security issue: open a normal issue for it.

## How to report

Use GitHub's private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Please do not open a public issue for these problems.

Include the macOS version, the TMSkipper version (`tmskipper version`), the steps to reproduce and, if possible, a `tmskipper scan --dry-run` output with personal paths removed.

## What to expect

This is a personal project maintained in spare time. Reports are acknowledged as soon as possible, usually within a week, and fixes for confirmed problems are released before the issue is disclosed.

## Supported versions

Only the latest release receives fixes.

## If you think a backup is affected

1. Stop the agent: `tmskipper uninstall`.
2. Remove TMSkipper's exclusions: `tmskipper reset`.
3. Run a new Time Machine backup.

Exclusions made by hand or by other apps are not affected by these steps.
