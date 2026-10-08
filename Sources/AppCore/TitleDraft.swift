import Foundation

/// The inline title's text while it's being edited, tied to the note it was
/// typed for. The title can stop being editable (reading mode) or start showing
/// another note (a tab switch) before the edit is committed; a rename taken from
/// the draft always names the note the text was typed for, so it can't rename
/// the note shown next.
public struct TitleDraft: Equatable {
    /// A rename the draft asks for: the note, and its new name.
    public struct Rename: Equatable {
        public let url: URL
        public let name: String
        public init(url: URL, name: String) { self.url = url; self.name = name }
    }

    /// The note the text belongs to.
    public private(set) var url: URL
    public var text: String

    public init(url: URL) {
        self.url = url
        self.text = Self.name(of: url)
    }

    /// The rename the text asks for — nil when it's blank or the note's name.
    public var rename: Rename? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != Self.name(of: url) else { return nil }
        return Rename(url: url, name: name)
    }

    /// Start showing `url`. Returns the rename still pending for the note shown
    /// until now, for the caller to commit.
    public mutating func show(_ url: URL) -> Rename? {
        let pending = rename
        self.url = url
        text = Self.name(of: url)
        return pending
    }

    /// Back to the note's name (an edit that renames nothing).
    public mutating func revert() { text = Self.name(of: url) }

    private static func name(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}
