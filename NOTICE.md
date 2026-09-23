# Third-party notices

gitbar itself is MIT licensed — see [LICENSE](LICENSE). It includes or is
derived from the following third-party work. Full license texts are in
[`THIRD_PARTY_LICENSES/`](THIRD_PARTY_LICENSES), and copies of this file and
those licenses are bundled inside every built `gitbar.app`
(`Contents/Resources`).

## Sparkle

[Sparkle](https://sparkle-project.org) 2.10.0, the update framework, is
embedded in the app (`Sparkle.framework`), linked via Swift Package Manager.
MIT licensed; its license also covers the external components Sparkle bundles
(bsdiff — BSD 2-Clause, sais-lite — MIT, ed25519 — zlib, and
`SUSignatureVerifier` — BSD).

License: [`THIRD_PARTY_LICENSES/Sparkle-LICENSE.txt`](THIRD_PARTY_LICENSES/Sparkle-LICENSE.txt)

## codenotch

`Sources/Features/SpinningArc.swift` — the spinning ring shown on a repo row
while its CI is running — is adapted from
[codenotch](https://github.com/vinzdg/codenotch) by Vinz (MIT licensed). No
other codenotch code remains in gitbar.

License: [`THIRD_PARTY_LICENSES/codenotch-LICENSE.txt`](THIRD_PARTY_LICENSES/codenotch-LICENSE.txt)

## Provider logos

The GitHub, GitLab and Bitbucket marks in `Sources/Resources/Assets.xcassets`
come from [Simple Icons](https://simpleicons.org), released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) (no attribution
required; credited here anyway). The logos themselves are trademarks of their
respective owners and are used only to identify those services. gitbar is not
affiliated with or endorsed by GitHub, GitLab or Atlassian.
