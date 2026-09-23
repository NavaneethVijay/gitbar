#!/usr/bin/env bash
# Builds a signed gitbar release and publishes it as a GitHub release: a DMG
# for first installs (drag to Applications), plus the zip + appcast.xml that
# the app's "Check for Updates…" (Sparkle) installs from.
#
#   make release VERSION=0.2.0       build, sign, publish release v0.2.0
#   make release-dry VERSION=0.2.0   same, into build/release, publishes nothing
#
# Optional release notes: build/release/notes.md (shown in the update dialog).
#
# Build + signing live in scripts/build-app.sh (ad-hoc for now; set
# SIGN_IDENTITY="Developer ID Application: …" once there is one, and add
# notarization). Sparkle verifies every update with the EdDSA key from
# `make update-keys`.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
REPO="${GITBAR_REPO:-NavaneethVijay/gitbar}"
DRY_RUN="${DRY_RUN:-}"

OUT="build/release"
TOOLS="build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"
TAG="v$VERSION"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: make release VERSION=<x.y.z>"
HAS_KEY=1
grep -q 'SUPublicEDKey: ""' project.yml && HAS_KEY=
if [[ -z "$DRY_RUN" ]]; then
    [[ -n "$HAS_KEY" ]] || die "SUPublicEDKey is empty — run 'make update-keys' first."
    gh auth status >/dev/null 2>&1 || die "gh isn't logged in — run 'gh auth login'."
    GH_USER="$(gh api user -q .login 2>/dev/null)"
    [[ "$(gh api "repos/$REPO" -q .permissions.push 2>/dev/null)" == "true" ]] ||
        die "gh account '$GH_USER' can't push to $REPO — run 'gh auth login' (or 'gh auth switch') as an account that can."
    ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || die "release $TAG already exists on $REPO."
fi

APP="$(scripts/build-app.sh "$VERSION" | tail -1)"

step "Packaging"
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 \( -name '*.zip' -o -name '*.dmg' -o -name 'appcast.xml' -o -name '*.delta' -o -name 'gitbar-*.md' \) -delete
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

# The DMG is for people installing by hand: the app next to an Applications
# shortcut. Built after the appcast so generate_appcast only sees the zip.
step "Building DMG"
DMG="$OUT/gitbar-$VERSION.dmg"
STAGING="$(mktemp -d)"
ditto "$APP" "$STAGING/gitbar.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "gitbar $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
hdiutil verify "$DMG" >/dev/null || die "DMG verification failed"


if [[ -n "$DRY_RUN" ]]; then
    step "Dry run — nothing published. Artifacts:"
    ls -lh "$OUT"
    exit 0
fi

step "Publishing $TAG to $REPO"
NOTES_ARGS=(--generate-notes)
[[ -f "$OUT/notes.md" ]] && NOTES_ARGS=(--notes-file "$OUT/notes.md")
gh release create "$TAG" "$DMG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --title "gitbar $VERSION" "${NOTES_ARGS[@]}"

# Keep the repo's version in step with what's published.
sed -i '' "s/^\(    MARKETING_VERSION: \).*/\1\"$VERSION\"/; s/^\(    CURRENT_PROJECT_VERSION: \).*/\1\"$VERSION\"/" project.yml

echo
echo "Released $TAG. Installed copies will see it on their next update check."
echo "Commit the version bump in project.yml."
