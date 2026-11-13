import Foundation

// GitLab REST v4 / GraphQL wire types — private to the GitLab module. Mapped
// to `Domain` types in GitLabMapping.swift; nothing outside Providers/GitLab
// sees these. GitLab uses snake_case throughout, so the client decodes these
// with the shared decoder and explicit CodingKeys.

struct GitLabUser: Decodable {
    let username: String
    let name: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case username, name
        case avatarURL = "avatar_url"
    }
}

struct GitLabUserRef: Decodable {
    let username: String
}

struct GitLabProject: Decodable {
    let pathWithNamespace: String
    /// "private" / "internal" / "public".
    let visibility: String?

    enum CodingKeys: String, CodingKey {
        case pathWithNamespace = "path_with_namespace"
        case visibility
    }
}

struct GitLabProjectInfo: Decodable {
    let defaultBranch: String?
    /// The project's default MR description (a Premium setting) — what
    /// GitLab's own form prefills when no `Default` template exists.
    let mergeRequestsTemplate: String?
    let description: String?
    let starCount: Int?
    let webURL: URL?

    enum CodingKeys: String, CodingKey {
        case description
        case webURL = "web_url"
        case defaultBranch = "default_branch"
        case mergeRequestsTemplate = "merge_requests_template"
        case starCount = "star_count"
    }
}

/// A label as GitLab sends it: a bare name by default, or an object with
/// its color when the list asked for `with_labels_details=true`.
struct GitLabLabel: Decodable {
    let name: String
    /// "#d73a4a".
    let color: String?

    private enum CodingKeys: String, CodingKey { case name, color }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            color = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            color = try container.decodeIfPresent(String.self, forKey: .color)
        }
    }
}

struct GitLabRelease: Decodable {
    let tagName: String
    let releasedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case releasedAt = "released_at"
    }
}

struct GitLabBranch: Decodable {
    let name: String
}

struct GitLabMergeRequest: Decodable {
    /// Per-project number (`!12`) — GitLab's own `id` is instance-wide.
    let iid: Int
    let title: String
    let author: GitLabUserRef?
    /// "opened" / "closed" / "merged" / "locked".
    let state: String?
    let draft: Bool?
    /// Pre-14.0 name for `draft`, still sent by older instances.
    let workInProgress: Bool?
    let reviewers: [GitLabUserRef]?
    let sourceBranch: String
    let targetBranch: String
    let sha: String?
    let description: String?
    let createdAt: Date
    let webURL: URL?
    let labels: [GitLabLabel]?
    /// Single-MR responses only — the commits a diff position is pinned to.
    let diffRefs: GitLabDiffRefs?

    enum CodingKeys: String, CodingKey {
        case iid, title, author, state, draft, reviewers, sha, description, labels
        case diffRefs = "diff_refs"
        case workInProgress = "work_in_progress"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case createdAt = "created_at"
        case webURL = "web_url"
    }
}

struct GitLabIssue: Decodable {
    let iid: Int
    let title: String
    let author: GitLabUserRef?
    let createdAt: Date
    let labels: [GitLabLabel]?
    let assignees: [GitLabUserRef]?
    let userNotesCount: Int?
    let webURL: URL?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case iid, title, author, labels, assignees, description
        case createdAt = "created_at"
        case userNotesCount = "user_notes_count"
        case webURL = "web_url"
    }
}

struct GitLabPipeline: Decodable {
    let id: Int
    /// The project the pipeline ran in — the *source fork* for an MR from a
    /// fork, not the MR's own project.
    let projectID: Int?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case projectID = "project_id"
    }
}

struct GitLabJob: Decodable {
    let name: String
    let stage: String?
    /// created, pending, running, failed, success, canceled, canceling,
    /// skipped, manual, scheduled, preparing, waiting_for_resource…
    let status: String
    let allowFailure: Bool?
    let webURL: URL?

    enum CodingKeys: String, CodingKey {
        case name, stage, status
        case allowFailure = "allow_failure"
        case webURL = "web_url"
    }
}

struct GitLabNote: Decodable {
    let id: Int
    let body: String
    let author: GitLabUserRef?
    let createdAt: Date
    /// Generated activity ("added 1 commit", "approved this merge request").
    let system: Bool?
    /// nil for a top-level comment, "DiscussionNote" for a thread reply,
    /// "DiffNote" for an inline code comment.
    let type: String?
    /// Where a `DiffNote` sits in the diff.
    var position: GitLabPosition? = nil
    var resolved: Bool? = nil
    var resolvable: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, body, author, system, type, position, resolved, resolvable
        case createdAt = "created_at"
    }
}

struct GitLabDiffRefs: Decodable {
    let baseSHA: String
    let startSHA: String
    let headSHA: String

    enum CodingKeys: String, CodingKey {
        case baseSHA = "base_sha"
        case startSHA = "start_sha"
        case headSHA = "head_sha"
    }
}

/// A diff note's position; also the shape a new one is posted with.
struct GitLabPosition: Codable {
    var positionType: String? = "text"
    var baseSHA: String? = nil
    var startSHA: String? = nil
    var headSHA: String? = nil
    let oldPath: String?
    let newPath: String?
    let oldLine: Int?
    let newLine: Int?

    enum CodingKeys: String, CodingKey {
        case positionType = "position_type"
        case baseSHA = "base_sha"
        case startSHA = "start_sha"
        case headSHA = "head_sha"
        case oldPath = "old_path"
        case newPath = "new_path"
        case oldLine = "old_line"
        case newLine = "new_line"
    }
}

/// A note in your unsubmitted review (`/draft_notes`) — a new diff thread,
/// or a reply to an existing discussion when `discussionID` is set.
struct GitLabDraftNote: Decodable {
    let id: Int
    let note: String?
    let discussionID: String?
    let position: GitLabPosition?

    enum CodingKeys: String, CodingKey {
        case id, note, position
        case discussionID = "discussion_id"
    }
}

/// One thread (`/discussions`): a top-level note and its replies.
struct GitLabDiscussion: Decodable {
    let id: String
    let notes: [GitLabNote]
}

struct GitLabApprovals: Decodable {
    struct Approver: Decodable { let user: GitLabUserRef }
    let approvedBy: [Approver]?

    enum CodingKeys: String, CodingKey {
        case approvedBy = "approved_by"
    }
}

/// One entry of `GET /merge_requests/:iid/reviewers` (GitLab 16+), which
/// carries each requested reviewer's review state.
struct GitLabReviewerState: Decodable {
    let user: GitLabUserRef
    /// "unreviewed" / "review_started" / "reviewed" / "requested_changes" /
    /// "approved" / "unapproved".
    let state: String?
}

struct GitLabDiff: Decodable {
    let oldPath: String?
    let newPath: String
    let newFile: Bool?
    let renamedFile: Bool?
    let deletedFile: Bool?
    /// Unified-diff hunks without the `---`/`+++` header; empty for binary
    /// or collapsed files.
    let diff: String?
    let tooLarge: Bool?
    let collapsed: Bool?

    enum CodingKeys: String, CodingKey {
        case diff, collapsed
        case oldPath = "old_path"
        case newPath = "new_path"
        case newFile = "new_file"
        case renamedFile = "renamed_file"
        case deletedFile = "deleted_file"
        case tooLarge = "too_large"
    }
}

/// The deprecated `GET /merge_requests/:iid/changes` — only used on
/// instances older than 15.7, which lack `/diffs`.
struct GitLabChanges: Decodable {
    let changes: [GitLabDiff]
}

struct GitLabTemplateSummary: Decodable {
    let key: String?
    let name: String
}

struct GitLabTemplate: Decodable {
    let name: String
    let content: String?
}

struct GitLabTokenInfo: Decodable {
    let name: String?
    let scopes: [String]
}

struct GitLabTodo: Decodable {
    struct Project: Decodable {
        let pathWithNamespace: String
        enum CodingKeys: String, CodingKey { case pathWithNamespace = "path_with_namespace" }
    }
    struct Target: Decodable {
        let iid: Int?
        let title: String?
    }

    let id: Int
    let project: Project?
    /// assigned, mentioned, build_failed, marked, approval_required,
    /// unmergeable, directly_addressed, review_requested, review_submitted…
    let actionName: String
    /// "MergeRequest", "Issue", "Commit", "Epic", …
    let targetType: String
    let target: Target?
    let targetURL: URL?
    let body: String?
    let state: String?
    let createdAt: Date
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, project, target, body, state
        case actionName = "action_name"
        case targetType = "target_type"
        case targetURL = "target_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// GitLab's error body: `message` is a string, a list, or a field → messages
/// map depending on the endpoint; `error` on some auth failures.
struct GitLabErrorBody: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        if let message = try? container.decode(String.self, forKey: AnyKey("message")) {
            text = message
        } else if let list = try? container.decode([String].self, forKey: AnyKey("message")) {
            text = list.joined(separator: "\n")
        } else if let fields = try? container.decode([String: [String]].self, forKey: AnyKey("message")) {
            text = fields.sorted { $0.key < $1.key }.flatMap { key, messages in
                messages.map { key == "base" ? $0 : "\(key.replacingOccurrences(of: "_", with: " ").capitalized) \($0)" }
            }.joined(separator: "\n")
        } else if let error = (try? container.decode(String.self, forKey: AnyKey("error_description")))
                    ?? (try? container.decode(String.self, forKey: AnyKey("error"))) {
            text = error
        } else {
            text = nil
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
