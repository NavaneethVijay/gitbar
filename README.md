# gitbar

A native macOS menu bar app for your git repos. Pin the repos you care about, see at a glance which ones need you, and drill into pull requests — review, check CI, open new PRs — without leaving the menu bar.

GitHub (github.com and GitHub Enterprise Server) is supported today; the app is built so GitLab and Bitbucket are one module each.

## Features

- **Pinned repos** with a status ring: all clear, CI running, or review requested.
- **Pull requests and issues** per repo, paginated, with real CI status per PR — and an **Only mine** filter.
- **PR detail**: description (rendered like GitHub), reviewers, checks, comments — and submit a review (Approve / Request changes / Comment).
- **Create pull requests**: pick source and target branch, title, and description — prefilled from the repo's PR template.
- **Notifications**: an inbox of review requests, mentions, assignments and more, an unread dot on the menu bar icon, per-repo unread counts, and macOS alerts for new ones (you choose which reasons). Needs a classic token with the `notifications` or `repo` scope.
- **Token check**: when you add an account, gitbar tells you what the token can do (read repos, review/open PRs, notifications) and how to fix what's missing.
- **Multiple accounts**, cloud or self-hosted.
- **Background refresh** (configurable), cheap on your rate limit: unchanged data comes back as `304 Not Modified`.
- Light / Dark / System appearance, an optional solid (non-translucent) background, and open at login.

## Install

gitbar is installed by building it from source. There are no prebuilt downloads yet — see [Roadmap](#roadmap) for why.

**Requirements:** macOS 15 or later, [Xcode](https://apps.apple.com/app/xcode/id497799835), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/NavaneethVijay/gitbar.git
cd gitbar
make install        # builds, installs to /Applications/gitbar.app, and opens it
```

Because the app is built on your own Mac rather than downloaded, macOS opens it without any security prompt.

gitbar lives in the menu bar — it has no window or Dock icon. To get started:

1. Click its menu bar icon → gear → **Manage this app…**
2. **Accounts → GitHub → Add Account**, choose **Cloud** (github.com) or **Self-hosted** (GitHub Enterprise Server).
3. Paste a [personal access token](https://github.com/settings/tokens). A **classic** token with the `repo` scope covers everything, including notifications; gitbar shows what your token can and can't do right after you add it.
4. Pick the repos to show.

| | |
|---|---|
| Update | `git pull && make install` |
| Remove | `make uninstall` |
| Install without admin rights | `make install INSTALL_DIR=~/Applications` |

## Development

```sh
make run      # Debug build (unsigned) and launch
make build    # build only
make clean    # remove build output and the generated project
```

## Roadmap

- **Signed downloads and automatic updates.** A prebuilt app that just opens needs to be signed with an Apple Developer ID and notarized by Apple — without that, macOS blocks any downloaded copy (*"Apple could not verify gitbar is free of malware"*). Until then, building from source is the supported way to install and update. The groundwork is already in place: in-app updates (Sparkle), a release script that builds a DMG and update feed (`make release`), and signing hooks — they switch on once there's a Developer ID and notarization.
- **More providers.** GitLab and Bitbucket, each as a self-contained module on the existing provider architecture.

## Author

[NavaneethVijay](https://github.com/NavaneethVijay)

## License

MIT — see [LICENSE](LICENSE). Third-party notices in [NOTICE.md](NOTICE.md).
