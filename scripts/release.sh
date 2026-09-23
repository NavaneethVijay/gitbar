#!/usr/bin/env bash
# Builds a signed gitbar release and publishes it as a GitHub release that the
# app's "Check for Updates…" (Sparkle) can find and install.
#
#   make release VERSION=0.2.0       build, sign, publish release v0.2.0
#   make release-dry VERSION=0.2.0   same, into build/release, publishes nothing
#
# Optional release notes: build/release/notes.md (shown in the update dialog).
#
# Signing is ad-hoc for now (no Developer ID): Sparkle verifies every update
# with the EdDSA key from `make update-keys`. With a Developer ID later, set
# SIGN_IDENTITY="Developer ID Application: …" and add notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
REPO="${GITBAR_REPO:-NavaneethVijay/gitbar}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DRY_RUN="${DRY_RUN:-}"

# The hardened runtime is only needed for notarization (Developer ID). With
# ad-hoc signing it breaks launch: its library validation rejects the
# embedded Sparkle.framework, since ad-hoc code has no Team ID to match.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    HARDENED=NO; RUNTIME_OPTS=()
else
    HARDENED=YES; RUNTIME_OPTS=(--options runtime --timestamp)
fi

DERIVED="build/DerivedData"
OUT="build/release"
TOOLS="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
APP="$DERIVED/Build/Products/Release/gitbar.app"
TAG="v$VERSION"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: make release VERSION=<x.y.z>"
HAS_KEY=1
grep -q 'SUPublicEDKey: ""' project.yml && HAS_KEY=
if [[ -z "$DRY_RUN" ]]; then
    [[ -n "$HAS_KEY" ]] || die "SUPublicEDKey is empty — run 'make update-keys' first."
    gh auth status >/dev/null 2>&1 || die "gh isn't logged in — run 'gh auth login'."
    gh repo view "$REPO" >/dev/null 2>&1 || die "can't see $REPO with the current gh account ($(gh api user -q .login 2>/dev/null))."
    ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || die "release $TAG already exists on $REPO."
fi

step "Building gitbar $VERSION (Release)"
# CFBundleVersion = the marketing version: Sparkle compares dotted versions
# directly, so there's no separate build counter to keep in sync.
xcodebuild -project gitbar.xcodeproj -scheme gitbar -configuration Release -derivedDataPath "$DERIVED" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME="$HARDENED" \
    clean build | grep -E "^\*\*|error:" || true
[[ -d "$APP" ]] || die "build failed — no $APP"

step "Signing ($SIGN_IDENTITY)"
# Sparkle's own helpers must be re-signed inside-out with the same identity,
# and the app last, keeping the entitlements Xcode applied (sandbox etc.).
ENTITLEMENTS="$(mktemp)"
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force ${RUNTIME_OPTS[@]+"${RUNTIME_OPTS[@]}"} --sign "$SIGN_IDENTITY" "$@"; }
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements "$ENTITLEMENTS" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP" || die "signature verification failed"

step "Packaging"
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 \( -name '*.zip' -o -name 'appcast.xml' -o -name '*.delta' \) -delete
ZIP="$OUT/gitbar-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
[[ -f "$OUT/notes.md" ]] && cp "$OUT/notes.md" "$OUT/gitbar-$VERSION.md"

if [[ -n "$HAS_KEY" ]]; then
    step "Generating appcast.xml"
    # Signs the zip with the EdDSA key from the Keychain. The feed only needs
    # the newest release: the app reads releases/latest/download/appcast.xml.
    "$TOOLS/generate_appcast" --embed-release-notes \
        --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
        --link "https://github.com/$REPO" \
        -o "$OUT/appcast.xml" "$OUT"
else
    echo "warning: no SUPublicEDKey yet — skipping appcast (run 'make update-keys')."
fi

if [[ -n "$DRY_RUN" ]]; then
    step "Dry run — nothing published. Artifacts:"
    ls -lh "$OUT"
    exit 0
fi

step "Publishing $TAG to $REPO"
NOTES_ARGS=(--generate-notes)
[[ -f "$OUT/notes.md" ]] && NOTES_ARGS=(--notes-file "$OUT/notes.md")
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --title "gitbar $VERSION" "${NOTES_ARGS[@]}"

# Keep the repo's version in step with what's published.
sed -i '' "s/^\(    MARKETING_VERSION: \).*/\1\"$VERSION\"/; s/^\(    CURRENT_PROJECT_VERSION: \).*/\1\"$VERSION\"/" project.yml

echo
echo "Released $TAG. Installed copies will see it on their next update check."
echo "Commit the version bump in project.yml."
