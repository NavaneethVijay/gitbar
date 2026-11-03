import Foundation

/// A file's unified diff (`patch`) parsed into display lines, plus the rules
/// for which diffs are worth drawing at all. Provider-neutral: GitHub,
/// GitLab and Bitbucket all hand back the same unified format per file.
enum UnifiedDiff {
    struct Line: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// `@@ -12,7 +12,9 @@ func name()`
            case hunk
            case added
            case removed
            case context
            /// `\ No newline at end of file`
            case meta
        }

        /// Position in the patch — stable for a given patch.
        let id: Int
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }

    /// Lines drawn before "Show more"; each click reveals another batch.
    static let lineBatch = 300
    /// More changed lines than this and a file starts behind "Show diff".
    static let largeChangeThreshold = 500

    /// One pass over the patch. Tabs become spaces so columns line up in the
    /// monospaced rows; the leading `+`/`-`/space marker is dropped (the row
    /// draws its own).
    static func parse(_ patch: String) -> [Line] {
        var lines: [Line] = []
        var oldLine = 0
        var newLine = 0
        var index = 0
        patch.enumerateLines { raw, _ in
            defer { index += 1 }
            let text = raw.replacingOccurrences(of: "\t", with: "    ")
            guard let marker = text.first else {
                // A blank line inside a hunk is unchanged context.
                lines.append(Line(id: index, kind: .context, oldNumber: oldLine, newNumber: newLine, text: ""))
                oldLine += 1; newLine += 1
                return
            }
            switch marker {
            case "@":
                if let (oldStart, newStart) = hunkStarts(text) {
                    oldLine = oldStart; newLine = newStart
                }
                lines.append(Line(id: index, kind: .hunk, oldNumber: nil, newNumber: nil, text: text))
            case "+":
                lines.append(Line(id: index, kind: .added, oldNumber: nil, newNumber: newLine, text: String(text.dropFirst())))
                newLine += 1
            case "-":
                lines.append(Line(id: index, kind: .removed, oldNumber: oldLine, newNumber: nil, text: String(text.dropFirst())))
                oldLine += 1
            case "\\":
                lines.append(Line(id: index, kind: .meta, oldNumber: nil, newNumber: nil, text: text))
            default:
                lines.append(Line(id: index, kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(text.dropFirst())))
                oldLine += 1; newLine += 1
            }
        }
        return lines
    }

    /// `@@ -12,7 +14,9 @@` → (12, 14).
    private static func hunkStarts(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ part: Substring) -> Int? {
            part.dropFirst().split(separator: ",").first.flatMap { Int($0) }
        }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        return (old, new)
    }

    /// Lock files, minified bundles, snapshots and vendored code: rarely read
    /// in review, often huge — they start collapsed behind "Show diff".
    static func isLikelyGenerated(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let lockFiles: Set<String> = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "bun.lockb",
            "podfile.lock", "package.resolved", "cartfile.resolved", "cargo.lock", "gemfile.lock",
            "composer.lock", "poetry.lock", "pipfile.lock", "uv.lock", "go.sum", "mix.lock", "pubspec.lock",
            "flake.lock",
        ]
        if lockFiles.contains(name) { return true }
        let generatedSuffixes = [".min.js", ".min.css", ".js.map", ".css.map", ".snap", ".pbxproj", ".lock"]
        if generatedSuffixes.contains(where: name.hasSuffix) { return true }
        let lowered = "/" + path.lowercased()
        return ["/vendor/", "/node_modules/", "/dist/", "/__snapshots__/", "/generated/"].contains(where: lowered.contains)
    }
}
