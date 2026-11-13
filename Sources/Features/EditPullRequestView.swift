// Editing an existing PR: title, description and target branch — what the
// web's "Edit" offers. A screen of its own in the popover (same fixed size as
// the PR screen) and a sheet over the main window.
import SwiftUI

struct EditPullRequestView: View {
    let pr: RepoPullRequest
    let provider: ProviderKind
    var isWindowed = false
    let loadBranches: () async throws -> [String]
    /// Throws the provider's message — shown in the form, the text kept.
    let onSave: (_ title: String, _ body: String, _ targetBranch: String) async throws -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var bodyText = ""
    @State private var base: String?
    @State private var branches: [String] = []
    @State private var isLoadingBranches = true
    @State private var branchError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didLoad = false
    @FocusState private var isDescriptionFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasChanges: Bool {
        trimmedTitle != pr.source.title || bodyText != pr.source.body || (base ?? pr.baseBranch) != pr.baseBranch
    }

    private var validationMessage: String? {
        if trimmedTitle.isEmpty { return "The title can't be empty." }
        if let base, base == pr.headBranch { return "The target can't be the source branch." }
        return nil
    }

    private var canSave: Bool { hasChanges && validationMessage == nil && !isSaving }

    private var fontSize: CGFloat { isWindowed ? 13 : 12 }
    private var labelSize: CGFloat { isWindowed ? 11 : 10.5 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                fields
                    .padding(isWindowed ? 20 : 14)
                    .disabled(isSaving)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .modifier(EditFrame(isWindowed: isWindowed))
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            title = pr.source.title
            bodyText = pr.source.body
            base = pr.baseBranch
        }
        .task { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            if !isWindowed {
                BackButton(action: onCancel)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit \(provider.pullRequestNoun)")
                    .font(.system(size: isWindowed ? 15 : 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(provider.formatNumber(pr.id))
                    .font(.system(size: isWindowed ? 11 : 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, isWindowed ? 20 : 12)
        .frame(height: isWindowed ? 56 : RepoDetailMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(inputBackground)
            }

            field("Into (target)") {
                VStack(alignment: .leading, spacing: 5) {
                    // Until the list loads, the current target is the only choice.
                    BranchPicker(branches: branches.isEmpty ? [pr.baseBranch] : branches,
                                 selection: $base, placeholder: "Choose the target branch")
                    HStack(spacing: 4) {
                        if isLoadingBranches {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Loading branches…")
                        } else if let branchError {
                            Text(branchError).foregroundStyle(Palette.danger)
                        } else {
                            Text("From \(pr.headBranch) — the source branch can't be changed.")
                        }
                    }
                    .font(.system(size: labelSize))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }

            field("Description") {
                ZStack(alignment: .topLeading) {
                    if isWindowed {
                        ComposerWell(isFocused: isDescriptionFocused)
                    } else {
                        inputBackground
                    }
                    if bodyText.isEmpty {
                        Text("Describe your changes — Markdown supported")
                            .font(.system(size: fontSize))
                            .foregroundStyle(Palette.textPlaceholder)
                            .padding(.leading, 8 + 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $bodyText)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Palette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(OverlayScrollers())
                        .padding(8)
                        .focused($isDescriptionFocused)
                }
                .frame(height: isWindowed ? 260 : 220)
            }

            if let validationMessage, hasChanges {
                Text(validationMessage)
                    .font(.system(size: labelSize))
                    .foregroundStyle(Palette.attention)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let saveError {
                Text(saveError)
                    .font(.system(size: labelSize))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().controlSize(.small).scaleEffect(isWindowed ? 1 : 0.7)
                }
                Spacer(minLength: 0)
                if isWindowed {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                } else {
                    ReviewActionButton(title: "Save", color: Palette.success, isDisabled: !canSave, action: save)
                }
            }
            .controlSize(isWindowed ? .large : .regular)
        }
        .padding(.horizontal, isWindowed ? 20 : 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Palette.wash.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.wash.opacity(0.1)))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoadingBranches = true
        branchError = nil
        do {
            let names = try await loadBranches()
            branches = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            branchError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load branches."
        }
        isLoadingBranches = false
    }

    private func save() {
        guard canSave else { return }
        saveError = nil
        isSaving = true
        Task {
            do {
                try await onSave(trimmedTitle, bodyText, base ?? pr.baseBranch)
            } catch {
                saveError = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't save the \(provider.pullRequestNoun)."
            }
            isSaving = false
        }
    }
}

/// Popover: the PR screen's fixed size, so the popover doesn't resize.
/// Sheet: a comfortable fixed size over the main window.
private struct EditFrame: ViewModifier {
    let isWindowed: Bool
    func body(content: Content) -> some View {
        if isWindowed {
            content.frame(width: 600, height: 560)
        } else {
            content.frame(width: PRDetailMetrics.width, height: PRDetailMetrics.height, alignment: .top)
        }
    }
}
