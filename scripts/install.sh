#!/usr/bin/env bash
# Builds gitbar from this checkout and installs it — no download, so macOS
# never quarantines it and there's no Gatekeeper prompt.
#
#   make install                              → /Applications/gitbar.app, then opens it
#   make install INSTALL_DIR=~/Applications   (no admin rights needed)
#
# Updating = `git pull && make install`. Sparkle's automatic update checks
# are turned off in these builds: an update downloaded from GitHub would be
# quarantined and blocked, which is exactly what installing from source avoids.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TARGET="$INSTALL_DIR/gitbar.app"

APP="$(INFO_OVERRIDES="SUEnableAutomaticChecks=false SUAutomaticallyUpdate=false" scripts/build-app.sh | tail -1)"

echo "==> Installing to $TARGET"
pkill -x gitbar 2>/dev/null && sleep 1 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET"
ditto "$APP" "$TARGET" || { echo "error: can't write to $INSTALL_DIR — try: make install INSTALL_DIR=~/Applications" >&2; exit 1; }

# Only one gitbar on the system: drop a copy left in the other Applications folder.
for other in /Applications/gitbar.app "$HOME/Applications/gitbar.app"; do
    if [[ "$other" != "$TARGET" && -d "$other" ]]; then
        rm -rf "$other"
        echo "Removed old copy at $other"
    fi
done

open "$TARGET"
echo "Installed and launched gitbar — look for its icon in the menu bar."
