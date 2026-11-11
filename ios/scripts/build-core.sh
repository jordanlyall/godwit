#!/usr/bin/env bash
# Builds ios/Godwit.xcframework from ./mobile (device + arm64 simulator, stripped).
# gomobile refuses to overwrite, so remove ios/Godwit.xcframework first when rebuilding.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
[ -d web/node_modules ] || (cd web && bun install --frozen-lockfile)
if [ -e ios/Godwit.xcframework ]; then echo "ios/Godwit.xcframework exists; remove it first" >&2; exit 1; fi
gomobile bind -target ios,iossimulator -iosversion 17.0 -ldflags="-s -w" -o ios/Godwit.xcframework ./mobile
echo "built ios/Godwit.xcframework"
