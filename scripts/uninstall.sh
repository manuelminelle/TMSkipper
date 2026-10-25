#!/bin/bash
# Stops the LaunchAgent and removes the binary.
# With --reset it first removes every exclusion made by TMSkipper.
# The config file (~/.config/tmskipper) is kept.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BINARY="$PREFIX/bin/tmskipper"

if [[ ! -x "$BINARY" ]]; then
    echo "tmskipper not found in $PREFIX/bin" >&2
    exit 1
fi

"$BINARY" uninstall
if [[ "${1:-}" == "--reset" ]]; then
    "$BINARY" reset
fi
rm -f "$BINARY"
echo "Removed $BINARY"
