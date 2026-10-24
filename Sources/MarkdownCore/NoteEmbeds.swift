import Foundation

/// An own-line `![[Note]]` that names a note (not an image or other file).
public struct NoteEmbed: Equatable {
    public let target: String      // without `#heading` or `|alias`
    public let heading: String?
    public let line: Range<Int>    // the whole line (UTF-16)
    public init(target: String, heading: String?, line: Range<Int>) {
        self.target = target; self.heading = heading; self.line = line
    }
}

public enum NoteEmbeds {
    /// Own-line `![[…]]` embeds whose target is a note: no extension, `.md`, or
    /// something after a dot that isn't a file extension (`Note v1.2`).
    public static func embeds(in text: String) -> [NoteEmbed] {
        let ns = text as NSString
        return ImageParser.images(in: text).compactMap { ref in
            let line = ns.substring(with: NSRange(location: ref.line.lowerBound, length: ref.line.count))
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("![[") else { return nil }
            var target = ref.path, heading: String?
            if let hash = target.firstIndex(of: "#") {
                heading = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
                target = String(target[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            let ext = (target as NSString).pathExtension.lowercased()
            let isFile = !ext.isEmpty && ext != "md" && ext.count <= 4 && ext.allSatisfy(\.isLetter)
            guard !target.isEmpty, !isFile else { return nil }
            return NoteEmbed(target: target, heading: heading?.isEmpty == true ? nil : heading, line: ref.line)
        }
    }

    /// The section a heading opens — its line through the line before the next
    /// heading of the same or a higher level — or nil when no heading has that
    /// title (ignoring case).
    public static func section(_ heading: String, in text: String) -> String? {
        let ns = text as NSString
        let headings = Outline.headings(in: text)
        guard let i = headings.firstIndex(where: { $0.title.caseInsensitiveCompare(heading) == .orderedSame }) else { return nil }
        let start = headings[i].offset
        let end = headings[(i + 1)...].first { $0.level <= headings[i].level }?.offset ?? ns.length
        return ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .newlines)
    }

    /// The `#heading` a link's source names: `[[Plan#Goals|x]]`, `[t](Plan.md#Goals)`.
    public static func heading(inLink source: String) -> String? {
        guard let hash = source.firstIndex(of: "#") else { return nil }
        let rest = source[source.index(after: hash)...]
        let end = rest.firstIndex { $0 == "|" || $0 == "]" || $0 == ")" } ?? rest.endIndex
        let heading = (rest[..<end].removingPercentEncoding ?? String(rest[..<end])).trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }
}

/// A note as an embed or a link preview shows it: its title and its text.
public struct NotePreview: Equatable {
    public let title: String
    public let text: String
    public init(title: String, text: String) { self.title = title; self.text = text }
}
