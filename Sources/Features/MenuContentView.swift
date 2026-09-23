// The popover's content: a top bar plus one of the list / repo / PR / create
// screens, pushed and popped with spring-driven moves.
import AppKit
import SwiftUI

@MainActor
final class MenuViewModel: ObservableObject {
    @Published var selectedRepoID: RepoRef?
    @Published var selectedPullRequestID: Int?
    /// The create-PR form, pushed on top of the selected repo's detail.
    @Published var isCreatingPullRequest = false

    let repoStore: LiveRepoStore

    init(repoStore: LiveRepoStore) {
        self.repoStore = repoStore
    }

    var repos: [RepoSnapshot] { repoStore.snapshots }
}

struct MenuContentView: View {
    @ObservedObject var model: MenuViewModel
    @ObservedObject var repoStore: LiveRepoStore

    init(model: MenuViewModel) {
        self.model = model
        self.repoStore = model.repoStore
    }

    private var selectedRepo: RepoSnapshot? {
        model.repos.first { $0.id == model.selectedRepoID }
    }

    /// From the paginated detail list — where the clicked row came from.
    private var selectedPullRequest: RepoPullRequest? {
        guard let repoID = model.selectedRepoID, let prID = model.selectedPullRequestID else { return nil }
        return repoStore.detailPullRequests[repoID]?.first { $0.id == prID }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                if let pr = selectedPullRequest, let repoID = model.selectedRepoID {
                    PRDetailView(
                        pr: pr,
                        isLoadingChecks: repoStore.isLoadingChecks(repoID: repoID, prID: pr.id),
                        isLoadingComments: repoStore.isLoadingComments(repoID: repoID, prID: pr.id),
                        isLoadingReviewers: repoStore.isLoadingReviewers(repoID: repoID, prID: pr.id),
                        isSubmittingReview: repoStore.isSubmittingReview(repoID: repoID, prID: pr.id),
                        reviewSubmitError: repoStore.reviewSubmitError(repoID: repoID, prID: pr.id),
                        provider: repoStore.provider(for: repoID),
                        canRequestChanges: repoStore.capabilities(for: repoID).supportsRequestChanges,
                        onSubmitReview: { decision, body in
                            Task { await repoStore.submitReview(repoID: repoID, prID: pr.id, decision: decision, body: body) }
                        },
                        isRefreshingDetail: repoStore.isRefreshingPRDetail(repoID: repoID, prID: pr.id),
                        onRefresh: {
                            Task { await repoStore.refreshPRDetail(repoID: repoID, prID: pr.id) }
                        },
                        onBack: {
                            navigate {
                                model.selectedPullRequestID = nil
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .task(id: pr.id) {
                        repoStore.beginPRDetail(repoID: repoID, prID: pr.id)
                    }
                } else if let repo = selectedRepo, model.isCreatingPullRequest {
                    CreatePullRequestView(
                        repo: repo,
                        loadForm: { try await repoStore.loadCreatePullRequestForm(repoID: repo.id) },
                        onCreate: { title, head, base, body in
                            let created = try await repoStore.createPullRequest(
                                repoID: repo.id, title: title, head: head, base: base, body: body)
                            // Land on the new PR; back returns to the list, not the form.
                            navigate {
                                model.isCreatingPullRequest = false
                                model.selectedPullRequestID = created.id
                            }
                        },
                        onBack: {
                            navigate {
                                model.isCreatingPullRequest = false
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if let repo = selectedRepo {
                    RepoDetailView(
                        repo: repo,
                        pullRequests: repoStore.detailPullRequests[repo.id],
                        issues: repoStore.detailIssues[repo.id],
                        hasMorePullRequests: repoStore.hasMorePullRequests[repo.id] ?? false,
                        hasMoreIssues: repoStore.hasMoreIssues[repo.id] ?? false,
                        isLoadingMorePullRequests: repoStore.isLoadingMorePullRequests[repo.id] ?? false,
                        isLoadingMoreIssues: repoStore.isLoadingMoreIssues[repo.id] ?? false,
                        onLoadMorePullRequests: { Task { await repoStore.loadMorePullRequests(repoID: repo.id) } },
                        onLoadMoreIssues: { Task { await repoStore.loadMoreIssues(repoID: repo.id) } },
                        prSearchResult: repoStore.prSearchResults[repo.id],
                        isSearchingPR: repoStore.isSearchingPR[repo.id] ?? false,
                        prSearchError: repoStore.prSearchError[repo.id],
                        onSearchPR: { number in Task { await repoStore.searchPullRequest(repoID: repo.id, number: number) } },
                        onClearPRSearch: { repoStore.clearPullRequestSearch(repoID: repo.id) },
                        onBack: {
                            navigate {
                                model.selectedRepoID = nil
                            }
                        },
                        onSelectPR: { pr in
                            repoStore.openSearchResult(repoID: repo.id, prID: pr.id)
                            navigate {
                                model.selectedPullRequestID = pr.id
                            }
                        },
                        onCreatePR: {
                            navigate {
                                model.isCreatingPullRequest = true
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .task(id: repo.id) {
                        repoStore.beginRepoDetail(repoID: repo.id)
                    }
                } else {
                    listOrStatus
                        .frame(width: RepoPanelMetrics.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.bottom, 10)
        }
        // Translucent over the popover's own Liquid Glass so text stays
        // legible. No fixed width: each screen sets its own.
        .background(Palette.surface)
    }

    private func navigate(_ change: () -> Void) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82), change)
    }

    /// The repo list, or the state explaining why there's nothing to list.
    @ViewBuilder
    private var listOrStatus: some View {
        if !repoStore.hasConnectedAccount {
            StatusPrompt(
                icon: "person.crop.circle.badge.questionmark",
                title: "No account connected",
                message: "Connect an account to see your repos here.",
                actionTitle: "Open Settings",
                action: { SettingsWindowController.shared.show() }
            )
        } else if !repoStore.hasFavorites {
            StatusPrompt(
                icon: "star",
                title: "No favorite repos yet",
                message: "Pick a few repos to watch in Settings.",
                actionTitle: "Open Settings",
                action: { SettingsWindowController.shared.show() }
            )
        } else if repoStore.isLoading && repoStore.snapshots.isEmpty {
            VStack {
                ProgressView().controlSize(.small)
                Text("Loading your repos…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if let warning = repoStore.rateLimitWarning, repoStore.snapshots.isEmpty {
            StatusPrompt(
                icon: "hourglass",
                title: "Rate limit low",
                message: warning,
                actionTitle: "Try again",
                action: { Task { await repoStore.refresh(force: true) } }
            )
        } else if let error = repoStore.loadError, repoStore.snapshots.isEmpty {
            StatusPrompt(
                icon: "exclamationmark.triangle",
                title: "Couldn't load your repos",
                message: error,
                actionTitle: "Retry",
                action: { Task { await repoStore.refresh(force: true) } }
            )
        } else {
            VStack(spacing: 0) {
                // A late rate-limit warning flags the list rather than blanking it.
                if let warning = repoStore.rateLimitWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 10))
                        Text(warning).font(.system(size: 10.5)).lineLimit(1).truncationMode(.tail)
                    }
                    .foregroundStyle(Palette.attention)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                RepoListPanel(repos: model.repos, onSelect: { repo in
                    navigate {
                        model.selectedRepoID = repo.id
                    }
                })
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text("gitbar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            if repoStore.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Menu {
                Button("Manage this app…") { SettingsWindowController.shared.show() }
                Divider()
                Button("Quit gitbar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // AppKit makes this the initial first responder, which would draw
            // a focus ring nobody tabbed to.
            .focusEffectDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
        }
    }
}

private struct StatusPrompt: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Palette.textTertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMeta)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
