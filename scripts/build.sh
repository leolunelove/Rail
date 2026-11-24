#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
RAIL_SCRATCH="${RAIL_BUILD_DIR:-.build}"
mkdir -p "$RAIL_SCRATCH"
RAIL_SCRATCH="$(cd "$RAIL_SCRATCH" && pwd)"
export CLANG_MODULE_CACHE_PATH="$(dirname "$RAIL_SCRATCH")/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --scratch-path "$RAIL_SCRATCH" --cache-path "$RAIL_SCRATCH/cache" --config-path "$RAIL_SCRATCH/config" --security-path "$RAIL_SCRATCH/security" --disable-sandbox
RAIL_APP="dist/Rail.app"
mkdir -p "$RAIL_APP/Contents/MacOS" "$RAIL_APP/Contents/Resources"
cp "$RAIL_SCRATCH/release/Rail" "$RAIL_APP/Contents/MacOS/Rail"
cp Info.plist "$RAIL_APP/Contents/Info.plist"
cp AppIcon.icns "$RAIL_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier studio.local.rail "$RAIL_APP"
echo "Built $RAIL_APP"
