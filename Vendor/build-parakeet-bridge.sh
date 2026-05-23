#!/bin/bash
# Build parakeet-bridge staticlib for Xcode integration.
# Run from repo root: Vendor/build-parakeet-bridge.sh
# Output: Vendor/parakeet-bridge/target/release/libparakeet_bridge.a
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CARGO="${HOME}/.cargo/bin/cargo"
if [ ! -x "$CARGO" ]; then
    echo "error: cargo not found at $CARGO" >&2
    exit 1
fi
"$CARGO" build --release --manifest-path "$SCRIPT_DIR/parakeet-bridge/Cargo.toml"
echo "Built: $SCRIPT_DIR/parakeet-bridge/target/release/libparakeet_bridge.a"
