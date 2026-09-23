// The create-PR form: source and target branch (from the remote — the app
// never pushes; you push your branch as usual), title and description.
import SwiftUI

struct CreatePullRequestView: View {
    let repo: RepoSnapshot
    let loadForm: () async throws -> CreatePullRequestFormData
    let onCreate: (_ title: String, _ head: String, _ base: String, _ body: String) async throws -> Void
    let onBack: () -> Void

    @State private var branches: [String] = []
    @State private var isLoadingBranches = true
    @State private var loadError: String?

    @State private var head: String?
    @State private var base: String?
    @State private var title = ""
    /// The title auto-filled from the head branch — replaced on a new pick
    /// only while the user hasn't typed their own.
    @State private var autoTitle = ""
    @State private var bodyText = ""
    @State private var templates: [PullRequestTemplate] = []
    @State private var selectedTemplate: PullRequestTemplate?

    @State private var isCreating = false
    @State private var createError: String?

    /// Keeps a long description from growing the popover past the screen.
    private static let formMaxHeight: CGFloat = 420

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validationMessage: String? {
        if let head, let base, head == base { return "Source and target must be different branches." }
        return nil
    }

    private var canCreate: Bool {
        head != nil && base != nil && !trimmedTitle.isEmpty && validationMessage == nil && !isCreating
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoadingBranches {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Loading branches…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else if let loadError {
                        VStack(spacing: 6) {
                            Text(loadError)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.danger)
                                .multilineTextAlignment(.center)
                            ReviewActionButton(title: "Retry", color: Palette.accent) {
                                Task { await load() }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        branchSection
                    }

                    field("Title") {
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(inputBackground)
                    }

                    field("Description", accessory: { templatePicker }) {
                        ZStack(alignment: .topLeading) {
                            inputBackground
                            if bodyText.isEmpty {
                                Text("Describe your changes — Markdown supported")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Palette.textPlaceholder)
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $bodyText)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.textPrimary)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                        }
                        .frame(height: 160)
                    }
                }
                .padding(14)
                .disabled(isCreating)
            }
            .frame(maxHeight: Self.formMaxHeight)

            footer
        }
        .frame(width: PRDetailMetrics.width)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text("New \(repo.provider.pullRequestNoun)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(repo.path)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: RepoDetailMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
        }
    }

    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("From (source)") {
                BranchPicker(branches: branches, selection: $head, placeholder: "Choose the branch you pushed")
            }
            HStack {
                Spacer()
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
            field("Into (target)") {
                BranchPicker(branches: branches, selection: $base, placeholder: "Choose the target branch")
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.attention)
            }
        }
        .onChange(of: head) { _, newHead in
            guard let newHead, title.isEmpty || title == autoTitle else { return }
            autoTitle = Self.title(fromBranch: newHead)
            title = autoTitle
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let createError {
                Text(createError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 0)
                ReviewActionButton(title: "Create \(repo.provider.pullRequestNoun)", color: Palette.success, isDisabled: !canCreate) {
                    create()
                }
            }
        }
        .padding(.horizontal, 14)
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

    private func field<Content: View, Accessory: View>(
        _ label: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
    }

    /// Only shown with more than one template; a single one is just prefilled.
    @ViewBuilder
    private var templatePicker: some View {
        if templates.count > 1 {
            Menu {
                ForEach(templates, id: \.self) { template in
                    Button(template.name) { apply(template) }
                }
                Divider()
                Button("No template") { apply(nil) }
            } label: {
                Text(selectedTemplate?.name ?? "No template")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.accent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusEffectDisabled()
        }
    }

    /// An explicit pick, so it replaces whatever is in the editor.
    private func apply(_ template: PullRequestTemplate?) {
        selectedTemplate = template
        bodyText = template?.body ?? ""
    }

    private func load() async {
        isLoadingBranches = true
        loadError = nil
        do {
            let result = try await loadForm()
            branches = result.branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if base == nil { base = result.defaultBranch }
            templates = result.templates
            // Prefill the provider's preferred (first) template, but never over
            // text already typed (e.g. on a Retry).
            if bodyText.isEmpty, let first = result.templates.first {
                apply(first)
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load branches."
        }
        isLoadingBranches = false
    }

    private func create() {
        guard canCreate, let head, let base else { return }
        createError = nil
        isCreating = true
        Task {
            do {
                try await onCreate(trimmedTitle, head, base, bodyText)
            } catch {
                createError = (error as? LocalizedError)?.errorDescription ?? "Couldn't create the \(repo.provider.pullRequestNoun)."
            }
            isCreating = false
        }
    }

    /// "feature/add-login_flow" → "Add login flow" — the same humanized
    /// branch name GitHub's own form defaults to for a multi-commit branch.
    static func title(fromBranch branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A searchable branch list — repos can have hundreds, too many for a menu.
private struct BranchPicker: View {
    let branches: [String]
    @Binding var selection: String?
    let placeholder: String

    @State private var isOpen = false
    @State private var isHovered = false
    @State private var query = ""

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
            Text(selection ?? placeholder)
                .font(.system(size: 12, design: selection == nil ? .default : .monospaced))
                .foregroundStyle(selection == nil ? Palette.textPlaceholder : Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.wash.opacity(isHovered ? 0.08 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.wash.opacity(0.1)))
        )
        .contentShape(Rectangle())
        .onTapGesture { isOpen = true }
        .hoverHighlight($isHovered)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                TextField("Filter branches", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit {
                        if let first = filtered.first { pick(first) }
                    }
            }
            .padding(10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text("No branches match.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.vertical, 16)
                    }
                    ForEach(filtered, id: \.self) { branch in
                        BranchRow(name: branch, isSelected: branch == selection) { pick(branch) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 280)
    }

    private func pick(_ branch: String) {
        selection = branch
        query = ""
        isOpen = false
    }
}

private struct BranchRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Palette.accent)
                .opacity(isSelected ? 1 : 0)
            Text(name)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.wash.opacity(isHovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .hoverHighlight($isHovered, animated: false)
    }
}
