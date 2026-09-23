# gitbar

A native macOS menu bar app for git hosts — GitHub today, built so GitLab/Bitbucket are one module each: pin repos, glance at PR/issue status, drill into details — all from a standard menu bar icon and popover.

## Current architecture (read this before touching UI or data flow)

**Menu bar icon + popover, not a notch.** An earlier direction tried to build this as a custom edge-docked "notch" window inspired by the app codenotch (https://github.com/vinzdg/codenotch). That was abandoned entirely — the custom AppKit window, hit-testing, and hover-trigger geometry proved too fragile to get right, and it never matched the product's own approved mockup anyway. **codenotch is no longer a reference for anything in this project.** Its code was fully removed (`Sources/Notch/`, `SideNotchShape`, `NotchMotion`, `NotchGeometry`, etc. — all deleted). Do not reintroduce notch-style UI, vendor codenotch code, or use it as a design reference unless the user explicitly asks again from scratch.

The real UI is `NSStatusItem` + `NSPopover` — stock AppKit, not hand-built. This is deliberate: show/close, outside-click dismissal, and positioning all come from the system instead of custom code.

### Screens (all SwiftUI, all in `Sources/Features/`)
1. **`RepoListPanel`** — pinned/favorited repos, one row each (icon, name, status ring color, meta text). Entry screen.
2. **`RepoDetailView`** — one repo's open PRs/Issues, tabbed, paginated ("Load more"), scrollable within a fixed height.
3. **`PRDetailView`** — one PR's full detail: state, branches, description, reviewers, checks, comments. The conversation thread is still read-only (no replying into it), but the composer submits a real, formal review — Approve / Request changes / Comment (`ReviewDecision`, via `ProviderClient.submitReview`), not a plain comment post. "Request changes" hides when the provider's `capabilities` say it has no such verdict. Also scrollable within a fixed height, header and composer pinned.

Navigation is a simple 3-level stack owned by `MenuViewModel` (`Sources/Features/MenuContentView.swift`): `selectedRepoID: RepoRef?` / `selectedPullRequestID: Int?` (plus `isCreatingPullRequest` for the create form), both nil = list. Push/pop uses spring animations + `.move(edge:)` transitions, not opacity crossfades — that distinction mattered a lot to the product owner (see Lessons below).

### Provider architecture (read before touching data flow)
Provider-neutral core + one self-contained module per git host. **Modules decide *what* to request and *how* to map it; the core decides *when* to fetch, how to throttle/cache, and how things look.** Nothing outside `Sources/Providers/<Name>/` may reference a provider's wire types or string states — the only kind-switch that reaches module code is `ProviderRegistry`.

```
Sources/Core/
  Provider/ProviderKind.swift     github|gitlab|bitbucket: display name, cloud host + cloud/self-hosted
                                  product names, token placeholder + help URL, terms (PR/MR, #/!), normalizeHost
  Provider/ProviderClient.swift   THE contract a module implements (actor, one per account)
  Provider/ProviderRegistry.swift isAvailable(kind) + makeClient(kind, host, token) — the only switch on kind
  Provider/ProviderError.swift    neutral errors; messages name the provider
  Networking/HTTPTransport.swift  shared HTTP: no-URLCache session, ETag/If-None-Match → 304 replay cache,
                                  JSON decode, status → ProviderError; provider rules via HTTPPolicy
  Domain/Domain.swift             neutral data: RepoRef, PRRef, AccountProfile, RemoteRepo, PullRequest, Issue,
                                  CheckSummary, CheckRun, Reviewer/ReviewState, Comment, ReviewDecision,
                                  CreatePullRequestDraft/FormData, PullRequestTemplate, Page, RateLimitStatus,
                                  ProviderCapabilities
  Display/DisplayModels.swift     what views render (RepoSnapshot, RepoPullRequest, RepoIssue, PRCheck, …)
  Display/DisplayMapper.swift     Domain → Display: every label, color, "time ago", status-ring rule — shared
Sources/Providers/GitHub/         GitHubClient (REST + GraphQL, github.com or GHES), GitHubDTOs (wire types),
                                  GitHubMapping (DTO → Domain, review/rollup states, HTTP conventions)
```

- **Identity**: `RepoRef { accountID, path }` everywhere a repo is keyed (store dictionaries, navigation, `RepoSnapshot.id`); per-PR state keys on `PRRef { repo, number }`. `path` is the provider's own full path, only unique within an account — so the same path under two accounts/providers is two repos (the old "owner/repo" collision is gone).
- **Accounts**: `Sources/Accounts/{Account,AccountStore,KeychainStore}.swift`. `Account { id, provider, host, login, name, avatarURL }`; `isCloud` = host is the provider's cloud host. Settings' Add Account asks Cloud vs Self-hosted explicitly (self-hosted requires a server; `normalizeHost` strips scheme/slash); the account screen shows a Cloud/Self-hosted badge. `addAccount(provider:host:token:)` validates via the registry's client (`validate()`); same provider+host+login re-stores the token instead of duplicating. **Migration**: records saved before providers existed have no `provider`/`host` and decode as `.github`/`github.com` (custom `init(from:)`) — don't remove that. Tokens: Keychain only, keyed by `account.id` (unchanged). GitHub host → API: `github.com` → `api.github.com`; anything else → `https://{host}/api/v3` and `/api/graphql` (GHES).
- **Favorites**: `Sources/Repos/FavoriteRepoStore.swift` — `[accountID: Set<path>]` (UserDefaults `gitbar.favoriteRepos.byAccount`), i.e. already a set of `RepoRef`s. `clearFavorites(for:)` on disconnect.
- **Live data**: `Sources/Repos/LiveRepoStore.swift` — neutral orchestration over `any ProviderClient` (one cached client per account, so rate-limit/ETag state stays per token):
  - Repo-list tier (cheap): `refresh()` fans out over every account's favorites — `recentPullRequests`/`recentIssues` (5 each), plus `reviewers` + `checks` only for your own PRs — into `DisplayMapper.snapshot`. An account with no token, no module, or low rate limit just contributes nothing.
  - Repo-detail tier: `pullRequests`/`issues(page:)`, 20/page, "Load more" appends (deduped). CI labels per row come from one batched `checkSummaries` call per page.
  - "Only mine" (checkbox by the PR search, `gitbar.prList.onlyMine`): a separate server-side list, `pullRequests(repo:page:author:)` — GitHub's REST PR list can't filter by author, so it's a GraphQL `search` (`repo:… is:pr is:open author:…`) returning full PR fields; the client maps page numbers to GraphQL cursors. Stored in `minePullRequests`; `updatePullRequest` updates both lists; opening one `adoptPullRequest`s it into `detailPullRequests` for the PR screen.
  - PR detail: checks/comments/reviewers lazily and independently on first open. `RepoPullRequest.source` keeps the domain `PullRequest` so follow-up calls (checks need its head SHA, reviewers its requested list) go back to the module.
  - Writes: `submitReview(decision:)`, `createPullRequest` (+ `loadCreatePullRequestForm`: branches, default branch, templates ordered with the provider's own prefill first). Provider rejections surface verbatim via `ProviderError.validationFailed`.
  - Rate limits: `rateLimitGuard` skips a batch under 50 remaining (`client.rateLimitStatus()`); `withRateLimitBackoff` does one wait-and-retry on `ProviderError.rateLimited` (the provider's `Retry-After`, capped at 2 min, else 60s).
- **Refresh cadence** (app-wide, every account on every provider; no request is ever unbounded or duplicated):
  - `RefreshScheduler` (`Sources/Repos/RefreshScheduler.swift`, owned by `StatusItemController`) polls every `gitbar.refreshInterval` seconds (General → "Refresh every", default 300, `-1` = manual only), skips ticks in Low Power Mode, refreshes ~5s after wake. Each tick: repo list, plus the visible repo/PR screen if the popover is open.
  - `LiveRepoStore.refresh(force:)` joins an in-flight run and skips within 60s of the last one (`minimumRefreshInterval`); only Retry buttons and PR creation pass `force: true`. Popover open calls it unforced.
  - `beginRepoDetail` / `beginPRDetail`: first visit loads; revisiting after 60s re-fetches. Repo detail merges a fresh page one over already-loaded "Load more" pages (`mergeFirstPage`), keeping each PR's lazily-loaded checks/comments/reviewers.
  - `HTTPTransport` sends every GET's cached `ETag` as `If-None-Match` and replays the cached body on `304` — verified on GitHub that 304s don't consume rate limit. Its session has no `URLCache`, so Foundation can't serve `max-age=60` responses from cache and hide the 304s. POSTs (GitHub's GraphQL: PR templates, per-page `statusCheckRollup`) aren't cacheable and always count.
- **Wording**: views take it from `ProviderKind` via `RepoSnapshot.provider` / `LiveRepoStore.provider(for:)` — "Pull Requests"/"Merge Requests", "New PR"/"New MR", `#12`/`!12`, "Refresh every", "Rate limit low". No provider name is hard-coded in UI copy.

### Notifications & token access
- **Token access** (`TokenAccess` on `Account.access`, persisted): `ProviderClient.tokenAccess()` — GitHub reads `X-OAuth-Scopes` from `GET /user` (classic tokens); `github_pat_…` = fine-grained (no scopes header, **can't read notifications at all**). Rules: notifications need `notifications` **or** `repo` (verified: a `repo`-only token reads them); PR writes need `repo`/`public_repo`. Checked on add, on demand (Settings → account → Token access → Re-check), once at launch for accounts missing it, and again whenever a notifications call comes back `.forbidden`.
- **403 handling**: GitHub 403 is `.rateLimited` only with `Retry-After` or `X-RateLimit-Remaining: 0`; otherwise `ProviderError.forbidden` (a permission problem — no retry/backoff).
- **`NotificationStore`** (`Sources/Notifications/`, owned by `SettingsWindowController`, shared with the popover via `MenuViewModel`): unread threads from every account with `capabilities.supportsNotifications` and a token that allows it. Own poll loop (`startPolling`, 60s with tolerance, never faster than the provider's `X-Poll-Interval`; unchanged inboxes are ETag 304s — free), plus a throttled refresh on popover open. Optimistic mark-read / mark-all-read.
- **Alerts** (`NotificationAlerter`, `UNUserNotificationCenter` delegate — created at launch so clicks on older alerts still route): only for threads new or updated since last alerted (`gitbar.notifications.seen`: thread → updatedAt); an account's **first** fetch records a silent baseline (`gitbar.notifications.baselined`) instead of alerting on the backlog. Per-reason toggles (`NotificationSettings`, default: review requested, mentions, assignments). Clicking an alert opens the popover to that item.
- **Opening an item** (`MenuViewModel.open`): marks read; a PR in a pinned repo opens in the app's PR screen (`LiveRepoStore.loadPullRequest` loads page one first, then the PR); anything else opens `webURL` in the browser.
- **UI**: bell + count in the popover top bar → `InboxView` (fixed size like the repo screen, grouped by repo); unread dot cut into the menu bar template icon (`StatusItemController.makeIcon`, re-armed via `withObservationTracking`); per-repo unread badge on repo rows; Settings → Notifications page.

### Adding a provider (e.g. GitLab)
1. Create `Sources/Providers/GitLab/` with its wire types, a mapping file (DTO → `Domain`, its state strings, `HTTPPolicy` rules: error classification, rate-limit headers, pagination), and `GitLabClient: ProviderClient` built on `HTTPTransport`. Map host → API base there (self-managed instances).
2. Set its `capabilities` honestly (e.g. `supportsRequestChanges: false` if it has no such verdict; `supportsNotifications` if it has an inbox API — GitLab's To-Do list, Bitbucket has none) and implement `tokenAccess()` — the UI adapts.
3. `ProviderRegistry`: return `true` from `isAvailable` and construct the client in `makeClient`.
4. Check `ProviderKind`'s wording/URLs for it (token help URL, placeholder, cloud/self-hosted names, terms) — they're already filled in for GitLab/Bitbucket.
5. The Settings sidebar, Add Account (cloud/self-hosted), account screen, favorites, popover, refresh and caching all pick it up with no further changes. Verify with `xcodebuild` + a real account.

- **Rendering PR bodies/comments as the provider itself does**: `Sources/DesignSystem/MarkdownText.swift` (`RenderedBodyText`). Renders the provider's own server-rendered HTML when the module supplies it (`PullRequest.bodyHTML`/`Comment.bodyHTML` — GitHub's `body_html` via `Accept: application/vnd.github.full+json`, same response, no extra request), parsing it with AppKit's native HTML importer, then restyle fonts/colors to the app's dark theme — no third-party Markdown/HTML dependency. Plain flowed text renders through a custom `NSTextView` (`RichText`/`LinkCursorTextView`) rather than SwiftUI's `Text`, specifically so a link gets its own pointing-hand cursor. Converted bodies are memoized in `RenderCache` (the HTML importer spins up WebKit and `body` runs on every popover redraw — re-importing each time caused visible flicker), and `RichText.updateNSView` only resets text that actually changed. `<table>` is split out and rendered separately through a plain SwiftUI `Grid` (`TableGridView`) instead of `NSTextTable` — verified directly that `NSTextTable` either renders with no visible borders (no CSS) or silently drops entire rows (with CSS), a TextKit fragility not worth working around further.
- **Settings window**: `Sources/Settings/{SettingsWindowController,SettingsView}.swift` — real `NSWindow`, singleton, `NavigationSplitView` sidebar+detail (System Settings-style, not tabs). Sidebar: General, then one row per `ProviderKind` under "Accounts" — an available provider is a disclosure row with its accounts (each → `AccountDetailView`, repo/favorites picker via `AccountStore.repositories(for:)`) plus "Add Account"; an unavailable one is a "Soon" row. Generated from `ProviderKind.allCases`, so a new module appears automatically. Reached via the popover's gear icon → "Manage this app…". The window owns its size (`hosting.sizingOptions = []` — the default options blanked the whole window when switching detail screens) and bridges SwiftUI toolbars/titles into a unified titlebar (`sceneBridgingOptions`).
- **General settings**: `Sources/Settings/GeneralSettingsView.swift` — sidebar's first row. Appearance (`AppearanceMode`: System/Light/Dark → `NSApp.appearance`, stored in `UserDefaults` `gitbar.appearance`, applied at launch in `AppDelegate`; the popover has no forced appearance and follows it), Open at login (`SMAppService.mainApp`, status read live since the user can change it in System Settings), Updates, and the current version (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in project.yml).
- **App + menu bar icons**: `AppIcon.appiconset` is generated by `swift scripts/make-icons.swift` (drawn in code, all 10 PNG sizes — edit the script, not the PNGs). The menu bar icon is `MenuBarIcon.imageset`, a hand-written 18×18 template SVG. The mark is a bar with a panel dropping from it (the app's own popover shape) — deliberately *not* git imagery, which the user rejected as misleading, set on the status item with `isTemplate = true` and reused in the popover header.
- **Provider logos**: real GitHub/GitLab/Bitbucket marks as template SVGs in `Sources/Resources/Assets.xcassets` (`logo-<rawValue>`, Simple Icons, CC0 — noted in NOTICE.md), drawn via `ProviderLogoView(provider:)` in `SettingsView.swift`. SF Symbols has no brand logos; don't swap these back to generic symbols.
- **Updates**: Sparkle 2 (SwiftPM), wrapped by `Sources/Settings/AppUpdater.swift`, owned by `SettingsWindowController`. Feed: `SUFeedURL` = `https://github.com/NavaneethVijay/gitbar/releases/latest/download/appcast.xml` (each GitHub release carries the zip + `appcast.xml`). `SUPublicEDKey` is written by `make update-keys` (private key stays in the login Keychain). Sandboxed install path: `SUEnableInstallerLauncherService` + the `-spks`/`-spki` mach-lookup entitlements. `CFBundleVersion` == marketing version (`x.y.z`) — Sparkle compares it against the appcast, so never go back to an integer build counter (an integer sorts above `0.x.y`).
- **Installing from source is the supported path** (`make install` → `scripts/install.sh`): no Developer ID means downloaded builds are quarantined and blocked by Gatekeeper — on the author's machine "Open Anyway" even left `/Applications/gitbar.app` held at `_dyld_start` (identical binary ran fine from any other path) until a restart cleared it. Local builds are never quarantined. `install.sh` sets `SUEnableAutomaticChecks`/`SUAutomaticallyUpdate` to false in the installed Info.plist (an update Sparkle downloads would be quarantined too); updating is `git pull && make install`. Build + signing for both install and release live in `scripts/build-app.sh`.
- **Releasing** (kept for when there's a Developer ID; `scripts/release.sh`, via `make release VERSION=x.y.z` / `make release-dry`): Release build, universal (`-destination generic/platform=macOS`), ad-hoc signed (`SIGN_IDENTITY=-` default; no Developer ID yet), Sparkle's XPC helpers re-signed inside-out, zip, `generate_appcast` (sees only the zip), then a DMG (app + `/Applications` symlink, built after the appcast) for first installs, `gh release create --repo NavaneethVijay/gitbar` with DMG + zip + appcast, then bumps the versions in project.yml. **Ad-hoc ⇒ hardened runtime OFF** — with it on, library validation refuses to load the ad-hoc `Sparkle.framework` ("different Team IDs") and the app dies at launch; verified. Turn it back on only with a real Developer ID (and add notarization then). `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` keeps `get-task-allow` out of release builds.

### Known simplifications (deliberate, not bugs)
- No merge-conflict detection in the state computation (would need the single-PR-detail endpoint, an extra call per PR — skipped to bound request volume).
- Issues have no detail screen (PRs do). Issue rows are display-only.
- The conversation thread (issue-style comments) is still read-only — only a formal review (Approve/Request changes/Comment) can be posted, not a plain reply into that thread.
- No reviewer *request* picker — the Reviewers section is stats/status only (who's approved / requested changes / still pending). Requesting new reviewers would need a repo-collaborators fetch + picker UI, deliberately out of scope for this pass.
- Rate-limit backoff is "one wait-and-retry," not a full exponential scheduler — proportionate to a menu bar app's modest request volume.
- GitLab and Bitbucket have no module yet — the architecture is in place (see "Adding a provider"), but `ProviderRegistry.isAvailable` is false for both, so they show as "Soon".
- Tokens are PATs only — no OAuth flow for any provider.
- The repo-list status ring's "busy" signal still calls `checks` per own PR (REST, ETag-cacheable) rather than the batched `checkSummaries` (GitHub GraphQL, never cacheable) — deliberately, so background polls of quiet repos stay free.

### Rendering & performance rules (from a GPU/flicker pass — keep these)
- **Stable popover size.** The popover window follows its content (`sizingOptions = [.preferredContentSize]`), and window resizes are expensive and flicker-prone. So the repo / PR / create screens have fixed heights (`RepoDetailMetrics.height`, `PRDetailMetrics.height`) and scroll inside; the window only resizes when navigating. Don't go back to `maxHeight` caps.
- **No no-op writes.** `LiveRepoStore` is `@Observable` (per-property invalidation); its bookkeeping is `@ObservationIgnored`. Every UI-visible write goes through `assign(_:_:)`, which skips equal values — most background refreshes are 304s that change nothing. Display models must stay `Equatable` with content-derived ids (`PRCheck.id`, `PRComment.id` — never `UUID()`), or equality never holds.
- **Translucency is optional.** General → "Solid background" (`gitbar.solidBackground`), forced on by the system's Reduce Transparency; read via `SolidBackgroundReader` (popover surface + `floatingCapsule` toasts).
- **Lazy lists** (`LazyVStack`) for the repo PR/issue list and the PR screen's sections/comments.
- **Text:** `RenderedBodyText` shows the Markdown fallback on a cache miss and swaps in the HTML render ~300ms later (after the slide-in), caching whole bodies in `bodyCache`; `RichText` caches its measured height per width. `updateNSView` only resets changed text.
- **Cursor:** `.pointerStyle(.link)` via `hoverHighlight` — no `NSCursor.push/pop` (leaks when a hovered row disappears).
- **Timers:** the refresh sleep carries a tolerance so macOS can coalesce wakeups.

## Working conventions for this project

- **Every change gets verified with a real `xcodebuild`, not trusted from a report.** This came up constantly — subagent self-reports of "build succeeded" were independently re-verified every time before being passed on to the user. Keep doing this.
- `make run` kills the running instance, rebuilds, relaunches. Standard verification loop: edit → `make build` → `make run` → confirm PID alive.
- SourceKit "cannot find type in scope" diagnostics that appear mid-edit are almost always stale-index noise, not real errors — `xcodebuild` is the source of truth, not the live diagnostics.
- Fork (background agent) for heavy, multi-file, self-contained work (new subsystems: auth, data layer, bulk vendoring). Do sequential UI/polish fixes directly in the main thread — the user explicitly pushed back on forking for small iterative changes ("why do you need to fork... you are just idle").
- Match the approved mockup literally, down to exact meta text per row, not a paraphrased/regenerated version. Several rounds of rework happened because generated text ("N open PRs" everywhere) silently diverged from what the mockup actually specified per-row.
- Real interaction affordances matter: hover highlight must fill the actual clickable area (own the row's height inside the row view, not applied externally — externally-applied height left the highlight smaller than the click target), and a pointing-hand cursor belongs only on rows that actually do something on click (not decorative ones).
- Any list that can grow unboundedly (pagination, long comment threads) needs a capped, scrollable height — a popover sizes itself to its SwiftUI content, so unbounded content means an unbounded popover, up to filling the screen.
- Content transitions should feel physical (spring-driven move/scale), not a flat opacity crossfade — this was explicitly called out as feeling "mechanical" and fixed by using `.move(edge:)` + spring instead of `.opacity` alone.

## Build

```
make install                    # Release build from source → /Applications, opens it (the supported install path)
make run                        # xcodegen + Debug build (unsigned) + relaunch
make build                      # build only
make update-keys                # one-time: Sparkle EdDSA key → project.yml
make release-dry VERSION=x.y.z  # Release build/sign/appcast into build/release, publishes nothing
make release VERSION=x.y.z      # same + GitHub release
```

Everything builds into `build/DerivedData.noindex` (so Sparkle's CLI tools are at `build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin`). Debug builds are unsigned and therefore **not sandboxed** — sandbox behavior only shows up in `make release-dry` builds; test there before shipping anything that touches files, network or Keychain.

`NSSupportsAutomaticGraphicsSwitching: true` (project.yml info properties — the `INFOPLIST_KEY_` form doesn't work for it) keeps the app off the discrete GPU on dual-GPU Macs; forced switches glitched the whole screen on the author's 2019 16" MacBook Pro (Intel UHD 630 + AMD 5500M, macOS 26).

Bundle id `com.navaneeth.gitbar` (renamed from `com.navaneeth.gitsidebar` before the first release — no data migration, by decision). Author: NavaneethVijay (https://github.com/NavaneethVijay). macOS 15+ deployment target. One SwiftPM dependency: Sparkle (auto-updates), declared in project.yml.
