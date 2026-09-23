#!/usr/bin/env bash
# Creates the Sparkle EdDSA signing key if it doesn't exist yet (stored in the
# login Keychain — never printed or written to disk here), then writes the
# public key into project.yml's SUPublicEDKey so builds can verify updates.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS="build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_keys" ]] || { echo "Sparkle tools not found — run 'make update-keys'." >&2; exit 1; }

"$TOOLS/generate_keys" >/dev/null
PUBLIC_KEY="$("$TOOLS/generate_keys" -p)"
[[ -n "$PUBLIC_KEY" ]] || { echo "generate_keys returned no public key." >&2; exit 1; }

sed -i '' "s|^\(        SUPublicEDKey: \).*|\1\"$PUBLIC_KEY\"|" project.yml
grep -q "SUPublicEDKey: \"$PUBLIC_KEY\"" project.yml || { echo "Couldn't update project.yml." >&2; exit 1; }

echo "SUPublicEDKey set in project.yml: $PUBLIC_KEY"
echo
echo "Back up the private key — without it you can never ship another update:"
echo "  $TOOLS/generate_keys -x gitbar-sparkle-private-key   # then store it somewhere safe, not in git"
