#!/bin/bash
# Builds TMSkipper, copies it to $PREFIX/bin (default ~/.local/bin) and starts the LaunchAgent.
# Extra arguments are passed to `tmskipper install` (e.g. --every 6).
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
cd "$(dirname "$0")/.."

swift build -c release
mkdir -p "$PREFIX/bin"
install -m 755 .build/release/tmskipper "$PREFIX/bin/tmskipper"
echo "Copied tmskipper to $PREFIX/bin/tmskipper"

"$PREFIX/bin/tmskipper" install "$@"
