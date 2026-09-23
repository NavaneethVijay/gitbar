#!/usr/bin/env bash
# Builds and signs a Release gitbar.app — shared by `make install` (local,
# from source) and `make release` (published). Prints the app's path last.
#
#   scripts/build-app.sh [version]    default: MARKETING_VERSION in project.yml
#
# Signing is ad-hoc unless SIGN_IDENTITY is set (a Developer ID later).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/^    MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED="build/DerivedData.noindex"
APP="$DERIVED/Build/Products/Release/gitbar.app"

die() { echo "error: $*" >&2; exit 1; }

# The hardened runtime is only needed for notarization (Developer ID). With
# ad-hoc signing it breaks launch: its library validation rejects the
# embedded Sparkle.framework, since ad-hoc code has no Team ID to match.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    HARDENED=NO; RUNTIME_OPTS=()
else
    HARDENED=YES; RUNTIME_OPTS=(--options runtime --timestamp)
fi

echo "==> Building gitbar $VERSION (Release)" >&2
# CFBundleVersion = the marketing version: Sparkle compares dotted versions
# directly, so there's no separate build counter to keep in sync.
xcodebuild -project gitbar.xcodeproj -scheme gitbar -configuration Release -derivedDataPath "$DERIVED" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME="$HARDENED" \
    clean build | grep -E "^\*\*|error:" >&2 || true
[[ -d "$APP" ]] || die "build failed — no $APP"

# Optional Info.plist tweaks before signing, e.g. `make install` turning off
# Sparkle's automatic checks: "Key=bool" pairs in INFO_OVERRIDES.
for pair in ${INFO_OVERRIDES:-}; do
    key="${pair%%=*}" value="${pair#*=}"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$APP/Contents/Info.plist" 2>/dev/null ||
        /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$APP/Contents/Info.plist"
done

echo "==> Signing ($SIGN_IDENTITY)" >&2
# Sparkle's own helpers must be re-signed inside-out with the same identity,
# and the app last, keeping the entitlements Xcode applied (sandbox etc.).
ENTITLEMENTS="$(mktemp)"
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force ${RUNTIME_OPTS[@]+"${RUNTIME_OPTS[@]}"} --sign "$SIGN_IDENTITY" "$@" 2>/dev/null; }
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements "$ENTITLEMENTS" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP" || die "signature verification failed"

# Keep this build-folder copy out of "Open With" — only the installed app
# should be the gitbar macOS knows about.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true

echo "$APP"
