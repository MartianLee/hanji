import Foundation
import VaultKit

/// A saved snapshot of one open tab. The ACTIVE tab's live state lives in
/// AppState's `selectedFile`/`activeText`/`savedText`/`externalConflict`
/// working fields; this snapshot is written back on switch/close.
public struct OpenTab: Identifiable, Equatable {
    public let id: UUID
    public var file: MarkdownFile
    public var text: String
    public var savedText: String
    public var externalConflict: String?
    /// The file vanished while this tab had unsaved edits; saving is paused until
    /// the user saves it again or closes it (or the file comes back).
    public var missingOnDisk = false
    /// Pinned tabs can't be closed until unpinned, and the vault reopens them.
    public var isPinned = false
    public var isDirty: Bool { text != savedText }
    public init(file: MarkdownFile, text: String) {
        self.id = UUID()
        self.file = file
        self.text = text
        self.savedText = text
        self.externalConflict = nil
    }

    /// The same note's state under a new tab identity — for showing it in a
    /// second pane (a pin stays with the original tab).
    init(copying other: OpenTab) {
        self.id = UUID()
        self.file = other.file
        self.text = other.text
        self.savedText = other.savedText
        self.externalConflict = other.externalConflict
        self.missingOnDisk = other.missingOnDisk
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
