#!/usr/bin/env bash
# Builds gitbar from this checkout and installs it — no download, so macOS
# never quarantines it and there's no Gatekeeper prompt.
#
#   make install                         → ~/Applications/gitbar.app, then opens it
#   make install INSTALL_DIR=/Applications
#
# Updating = `git pull && make install`. Sparkle's automatic update checks
# are turned off in these builds: an update downloaded from GitHub would be
# quarantined and blocked, which is exactly what installing from source avoids.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
TARGET="$INSTALL_DIR/gitbar.app"

APP="$(INFO_OVERRIDES="SUEnableAutomaticChecks=false SUAutomaticallyUpdate=false" scripts/build-app.sh | tail -1)"

echo "==> Installing to $TARGET"
pkill -x gitbar 2>/dev/null && sleep 1 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"

open "$TARGET"
echo "Installed and launched gitbar — look for the </> icon in the menu bar."
