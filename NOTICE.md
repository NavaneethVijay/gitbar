# Third-party notices

gitbar dropped its earlier notch-based UI (the custom edge-docked
window, its geometry, and its fold/hover animation system) in favor of a
standard `NSStatusItem` + `NSPopover` menu bar UI. Most of the code
previously adapted from [codenotch](https://github.com/vinzdg/codenotch) by
Vinz (MIT licensed) was removed along with it.

One file remains adapted from it: `Sources/Features/SpinningArc.swift`, a
Core Animation spinning-arc view extracted from codenotch's
`ProviderRing.swift`, used here for a pull request's "checks running"
indicator.

The full license text is included at
`THIRD_PARTY_LICENSES/codenotch-LICENSE.txt`.

## Provider logos

The GitHub, GitLab and Bitbucket marks in
`Sources/Resources/Assets.xcassets` come from
[Simple Icons](https://simpleicons.org) (CC0 1.0). The logos themselves
are trademarks of their respective owners and are used only to identify
those services.
