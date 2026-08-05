import Foundation

/// Reads the shipping app SOURCE, for the handful of invariants that ARE the absence (or the
/// confinement) of code and so cannot be observed by running anything: no networking API anywhere,
/// every `LanguageModelSession` built in one file, no template generator for finding prose.
///
/// These exist because prose and code drift apart silently — `README.md` spent weeks describing a
/// pipeline that had been deleted, and nothing failed. A claim worth stating in the docs is usually
/// worth pinning here too.
enum SourceScan {
    /// The app target's source tree, derived from this file's compile-time location.
    static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VerdantTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Verdant")
    }

    /// Every Swift file in the app target. Throws rather than returning an empty sweep — a scan that
    /// silently found nothing would certify an app it never read.
    static func swiftSources() throws -> [(path: String, text: String)] {
        struct TreeMissing: Error { let path: String }
        let root = appRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw TreeMissing(path: root.path)
        }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        guard files.count > 50 else { throw TreeMissing(path: root.path) }
        return try files.map {
            try (path: $0.lastPathComponent, text: String(contentsOf: $0, encoding: .utf8))
        }
    }

    /// Code only. Comments are stripped because the codebase deliberately NAMES the things it avoids
    /// in order to explain why — a scan that flagged those would punish the documentation that makes
    /// the decision reviewable.
    static func code(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The argument text of the call that opens at `open`, to its BALANCED closing paren.
    ///
    /// Written after a naive `prefix(while: { $0 != ")" })` gave a false positive: it stopped at the
    /// inner paren of `jobID: UUID()` and reported a call as missing an argument that was two lines
    /// further down. A scan that answers a slightly different question than the one asked is exactly
    /// the defect class these invariants exist to catch, so it should not be one.
    static func callBody(in text: Substring, from open: Substring.Index) -> Substring {
        var depth = 1
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return text[open..<index] }
            default: break
            }
            index = text.index(after: index)
        }
        return text[open...]
    }

    /// Every CALL of `name` in `text`, as the argument text between its balanced parens.
    ///
    /// Declarations are skipped. Matching `func name(` as though it were a call was the cause of two
    /// separate false positives in these invariants — a scan reporting that a function "does not
    /// pass" an argument its own signature was declaring. Three of the call-site scans written here
    /// answered a slightly different question than the one asked, which is the defect class they
    /// exist to catch, so the shared helper now rules out the commonest cause.
    ///
    /// Domain filtering is still the caller's job: if a wrapper shares a name with the API it wraps,
    /// only the caller knows which is which (`requestAuthorization` is filtered by `read:`).
    static func callSites(of name: String, in text: String) -> [String] {
        var found: [String] = []
        var searched = text[...]
        while let hit = searched.range(of: "\(name)(") {
            let isDeclaration = searched[..<hit.lowerBound].hasSuffix("func ")
            let body = callBody(in: searched, from: hit.upperBound)
            searched = searched[hit.upperBound...]
            guard !isDeclaration else { continue }
            found.append(String(body))
        }
        return found
    }

    /// A reference that could actually execute: a call, a member access, or an import — not a
    /// backticked mention in prose.
    static func uses(_ token: String, in text: String) -> Bool {
        // A type ANNOTATION is the fourth form and was missing: `let session: URLSession = .shared`
        // contains none of the other three — no paren, no dot after the name, no import — so the
        // networking ban would have read straight past it. Unlikely to be written, but the whole
        // value of that ban is that it holds for code nobody reviewed.
        text.contains("\(token)(") || text.contains("\(token).")
            || text.contains("import \(token)") || text.contains(": \(token)")
    }
}
