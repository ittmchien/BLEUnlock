#!/usr/bin/env bash
# Build BLEUnlock locally, ad-hoc sign it, install it and relaunch it.
#
# Usage: scripts/build.sh [install-dir]      (default: ~/Downloads)
#        CONFIG=Release scripts/build.sh
#
# Ad-hoc signatures change on every build, so macOS asks again for
# Accessibility / Bluetooth permission after each install.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly CONFIG="${CONFIG:-Debug}"
readonly INSTALL_DIR="${1:-$HOME/Downloads}"
readonly DERIVED_DATA="build/DerivedData"
readonly BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIG/BLEUnlock.app"
readonly INSTALLED_APP="$INSTALL_DIR/BLEUnlock.app"
readonly LOGIC_CHECK_BIN="build/devicelogic-check"
readonly BUILD_LOG="build/xcodebuild.log"
# Review fix: bounded wait for the old instance to quit (QUIT_WAIT_TRIES x QUIT_WAIT_INTERVAL = 10s)
readonly QUIT_WAIT_TRIES=50
readonly QUIT_WAIT_INTERVAL=0.2
readonly CURRENT_USER="$(id -un)"

echo "==> Logic self-check"
mkdir -p build
swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o "$LOGIC_CHECK_BIN"
"$LOGIC_CHECK_BIN"

echo "==> Building ($CONFIG)"
# Full xcodebuild output goes to a log; only compiler errors are printed on failure
if ! xcodebuild \
    -project BLEUnlock.xcodeproj \
    -scheme BLEUnlock \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$BUILD_LOG" 2>&1; then
    grep -E "error:" "$BUILD_LOG" | sort -u || true
    echo "Build failed. Full log: $BUILD_LOG" >&2
    exit 1
fi

echo "==> Quitting running BLEUnlock"
# Review fix: only this user's instance; fail instead of hanging if it won't quit
pkill -x -u "$CURRENT_USER" BLEUnlock || true
for ((try = 0; try < QUIT_WAIT_TRIES; try++)); do
    pgrep -x -u "$CURRENT_USER" BLEUnlock >/dev/null || break
    sleep "$QUIT_WAIT_INTERVAL"
done
if pgrep -x -u "$CURRENT_USER" BLEUnlock >/dev/null; then
    echo "BLEUnlock did not quit; quit it manually and rerun." >&2
    exit 1
fi

echo "==> Installing to $INSTALLED_APP"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
codesign --force --deep --sign - "$INSTALLED_APP"

echo "==> Launching"
open "$INSTALLED_APP"
echo "Done. If lock/unlock doesn't work, re-enable BLEUnlock in System Settings > Privacy & Security > Accessibility."
