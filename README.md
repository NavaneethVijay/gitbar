# gitbar

A native macOS menu bar app for your git repos. Pin the repos you care about, see at a glance which ones need you, and drill into pull requests — review, check CI, open new PRs — without leaving the menu bar.

GitHub (github.com and GitHub Enterprise Server) is supported today; the app is built so GitLab and Bitbucket are one module each.

## Features

- **Pinned repos** with a status ring: all clear, CI running, or review requested.
- **Pull requests and issues** per repo, paginated, with real CI status per PR.
- **PR detail**: description (rendered like GitHub), reviewers, checks, comments — and submit a review (Approve / Request changes / Comment).
- **Create pull requests**: pick source and target branch, title, and description — prefilled from the repo's PR template.
- **Multiple accounts**, cloud or self-hosted.
- **Background refresh** (configurable), cheap on your rate limit: unchanged data comes back as `304 Not Modified`.
- Light / Dark / System appearance, open at login, automatic updates.

## Install

Download `gitbar-x.y.z.dmg` from the [latest release](https://github.com/NavaneethVijay/gitbar/releases/latest), open it, and drag **gitbar** onto the **Applications** shortcut.

gitbar isn't notarized yet, so on first launch macOS says it *could not verify "gitbar" is free of malware* — macOS blocks it before the app itself can run. To allow it, either:

- run `xattr -dr com.apple.quarantine /Applications/gitbar.app` in Terminal (simplest); or
- open it once and choose **Done**, go to **System Settings → Privacy & Security**, click **Open Anyway** next to *"gitbar" was blocked…*, then **open gitbar again right away** and click **Open** in the dialog that follows.

gitbar has no window or Dock icon — once it's running, look for its `</>` icon in the menu bar.

(On macOS 15 and later, right-click → Open no longer bypasses this.) You only need to do this once — after that, updates install themselves: **Settings → General → Check for Updates…**, or automatically in the background.

Then open **Settings → Accounts → GitHub → Add Account**, choose Cloud or Self-hosted, and paste a [personal access token](https://github.com/settings/tokens) with read access to your repos (plus write access to pull requests if you want to review or open PRs). Pick the repos to show under the account.

Requires macOS 15 or later.

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run      # generate the project, build Debug, launch
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
