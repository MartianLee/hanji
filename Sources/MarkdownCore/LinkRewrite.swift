import Foundation

/// Links rewritten for notes that moved: every wikilink, embed and markdown
/// link that named a moved note gets its new place, in the form it was
/// written (a bare name stays a bare name unless that would now name another
/// note; a path stays a path; `#anchor`, `|alias` and `.md` are kept).
public enum LinkRewrite {
    private static let wiki = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]]+)\]\]"#)

    /// `moves`: old → new vault-relative paths. `before` / `after`: every
    /// note's path, in file order, before and after the move — what links
    /// resolved against then, and will now.
    public static func rewrite(_ text: String, moves: [String: String],
                               before: [String], after: [String]) -> (text: String, count: Int) {
        let ns = text as NSString
        let code = CodeBlockParser.allCodeRanges(in: text)
        func inCode(_ r: NSRange) -> Bool { code.contains { $0.overlaps(r.location..<NSMaxRange(r)) } }
        var edits: [(range: NSRange, text: String)] = []

        for m in wiki.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !inCode(m.range) {
            let inner = m.range(at: 1)
            let innerText = ns.substring(with: inner)
            let cut = innerText.firstIndex { $0 == "|" || $0 == "#" } ?? innerText.endIndex
            let raw = String(innerText[..<cut])
            let written = raw.trimmingCharacters(in: .whitespaces)
            guard let new = moved(written, moves, before),
                  let replacement = target(for: written, at: new, after: after) else { continue }
            let lead = (raw.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
            edits.append((NSRange(location: inner.location + lead, length: written.utf16.count), replacement))
        }
        for m in LinkParser.markdownLinks(ns) where !inCode(m.whole) {
            var dest = ns.substring(with: m.dest)
            guard !dest.contains("://"), !dest.hasPrefix("#"), !dest.hasPrefix("mailto:") else { continue }
            var anchor = ""
            if let hash = dest.firstIndex(of: "#") { anchor = String(dest[hash...]); dest = String(dest[..<hash]) }
            var path = dest.removingPercentEncoding ?? dest
            let dotSlash = path.hasPrefix("./")
            if dotSlash { path = String(path.dropFirst(2)) }
            guard path.lowercased().hasSuffix(".md"), let new = moved(path, moves, before),
                  let replacement = target(for: path, at: new, after: after) else { continue }
            let encoded = replacement.replacingOccurrences(of: " ", with: "%20")
            edits.append((m.dest, (dotSlash ? "./" : "") + encoded + anchor))
        }

        guard !edits.isEmpty else { return (text, 0) }
        let out = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: edit.range, with: edit.text)
        }
        return (out as String, edits.count)
    }

    /// Where the note `written` named before the move now lives, if it moved.
    private static func moved(_ written: String, _ moves: [String: String], _ before: [String]) -> String? {
        guard !written.isEmpty, let old = LinkTarget.resolve(written, in: before) else { return nil }
        return moves[old]
    }

    /// What to write for a link that said `written`, now naming `new` — or nil
    /// when `written` still names it as it is.
    private static func target(for written: String, at new: String, after: [String]) -> String? {
        let keepsExtension = written.lowercased().hasSuffix(".md")
        let path = String(new.dropLast(3))                     // `new` ends in .md
        var candidate = written.contains("/") ? path : (path as NSString).lastPathComponent
        if !written.contains("/"), LinkTarget.resolve(candidate, in: after) != new { candidate = path }
        guard LinkTarget.key(candidate) != LinkTarget.key(written) else { return nil }
        return keepsExtension ? candidate + ".md" : candidate
    }
}
