# gitbar

A native macOS menu bar app for your git repos. Pin the repos you care about, see at a glance which ones need you, and drill into pull requests — review, check CI, open new PRs — without leaving the menu bar.

GitHub (github.com and GitHub Enterprise Server) is supported today; the app is built so GitLab and Bitbucket are one module each.

## Features

- **Pinned repos** with a status ring: all clear, CI running, or review requested.
- **Pull requests and issues** per repo, paginated, with real CI status per PR.
- **PR detail**: description (rendered like GitHub), reviewers, checks, comments — and submit a review (Approve / Request changes / Comment).
- **Create pull requests**: pick source and target branch, title, and description — prefilled from the repo's PR template.
- **Notifications**: an inbox of review requests, mentions, assignments and more, an unread dot on the menu bar icon, per-repo unread counts, and macOS alerts for new ones (you choose which reasons). Needs a classic token with the `notifications` or `repo` scope.
- **Token check**: when you add an account, gitbar tells you what the token can do (read repos, review/open PRs, notifications) and how to fix what's missing.
- **Multiple accounts**, cloud or self-hosted.
- **Background refresh** (configurable), cheap on your rate limit: unchanged data comes back as `304 Not Modified`.
- Light / Dark / System appearance, open at login, automatic updates.

## Install

Build it from source — one command, and since nothing is downloaded, macOS has no reason to block it.

Requires macOS 15+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/NavaneethVijay/gitbar.git
cd gitbar
make install        # builds, installs to /Applications/gitbar.app, and opens it
```

gitbar lives in the menu bar — it has no window or Dock icon. Open **Settings → Accounts → GitHub → Add Account**, choose Cloud or Self-hosted, and paste a [personal access token](https://github.com/settings/tokens) with read access to your repos (plus write access to pull requests if you want to review or open PRs). Then pick the repos to show.

To update: `git pull && make install`. To remove: `make uninstall`. Install elsewhere with `make install INSTALL_DIR=~/Applications` (no admin rights needed).

<details>
<summary>Prebuilt downloads (DMG)</summary>

Releases also ship a DMG, but gitbar isn't notarized yet (that needs an Apple Developer ID), so macOS blocks the downloaded app with *"Apple could not verify gitbar is free of malware"*. If you use it anyway, drag it to Applications and run `xattr -dr com.apple.quarantine /Applications/gitbar.app` **before** first opening it. Building from source avoids all of this.

</details>

## Development

```sh
make run      # Debug build (unsigned) and launch
make build    # build only
make clean    # remove build output and the generated project
```

## Releasing

Each GitHub release carries a DMG (for installing), plus a zip and a Sparkle `appcast.xml` (for updates); installed copies check `releases/latest/download/appcast.xml`.

One-time setup:

```sh
make update-keys   # creates the Sparkle signing key (kept in your login Keychain)
                   # and writes its public key into project.yml
```

Back up the private key it points you to — without it you can't ship updates to existing installs. Commit the updated `project.yml`.

Each release:

```sh
make release-dry VERSION=0.2.0   # optional: build + sign + appcast into build/release, publish nothing
make release VERSION=0.2.0       # build, sign, publish GitHub release v0.2.0
```

Optional release notes go in `build/release/notes.md` (shown in the update dialog). `gh` must be logged in to an account that can publish to `NavaneethVijay/gitbar` (override with `GITBAR_REPO=owner/name`). Commit the version bump the script leaves in `project.yml`.

Builds are ad-hoc signed for now; with a Developer ID, run with `SIGN_IDENTITY="Developer ID Application: …"` (notarization still to be added).

## Author

[NavaneethVijay](https://github.com/NavaneethVijay)

## License

MIT — see [LICENSE](LICENSE). Third-party notices in [NOTICE.md](NOTICE.md).
