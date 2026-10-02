import Foundation
import VaultKit

/// One open note's working state. Every tab showing the note — in either pane —
/// holds the same buffer, so a note can't have two diverging versions: what's
/// typed in one pane is what the other shows. The active tab's buffer is
/// mirrored by AppState's `activeText`/`savedText`/`externalConflict`/
/// `missingOnDisk` working fields, which write straight through to it.
public final class NoteBuffer {
    public var file: MarkdownFile
    public var text: String
    /// Disk baseline; the note is dirty when `text` differs.
    public var savedText: String
    /// The on-disk version waiting on the "changed on disk" banner.
    public var externalConflict: String?
    /// The file vanished while the note had unsaved edits; saving is paused until
    /// the user saves it again or closes it (or the file comes back).
    public var missingOnDisk = false
    public var isDirty: Bool { !(text as NSString).isEqual(to: savedText) }   // see AppState.isDirty

    init(file: MarkdownFile, text: String) {
        self.file = file
        self.text = text
        self.savedText = text
    }
}

/// A tab: its own identity and pin, showing a note's shared buffer. The note
/// properties read and write that buffer.
public struct OpenTab: Identifiable, Equatable {
    public let id: UUID
    public internal(set) var buffer: NoteBuffer
    /// Pinned tabs can't be closed until unpinned, and the vault reopens them.
    public var isPinned = false
    /// Reading mode: the note shown fully rendered, not editable (checkbox
    /// toggles aside). Per tab — another tab on the same note keeps its own.
    public var isReading = false
    /// The notes this tab showed before its current one (most recent last), and
    /// the ones back navigation stepped away from, for forward.
    public internal(set) var back: [NavigationEntry] = []
    public internal(set) var forward: [NavigationEntry] = []

    public var file: MarkdownFile {
        get { buffer.file } nonmutating set { buffer.file = newValue }
    }
    public var text: String {
        get { buffer.text } nonmutating set { buffer.text = newValue }
    }
    public var savedText: String {
        get { buffer.savedText } nonmutating set { buffer.savedText = newValue }
    }
    public var externalConflict: String? {
        get { buffer.externalConflict } nonmutating set { buffer.externalConflict = newValue }
    }
    public var missingOnDisk: Bool {
        get { buffer.missingOnDisk } nonmutating set { buffer.missingOnDisk = newValue }
    }
    public var isDirty: Bool { buffer.isDirty }

    public init(file: MarkdownFile, text: String) {
        self.id = UUID()
        self.buffer = NoteBuffer(file: file, text: text)
    }

    /// Another tab on the same note (a second pane): same buffer, its own
    /// identity (the pin stays with the original tab).
    init(sharing other: OpenTab) {
        self.id = UUID()
        self.buffer = other.buffer
    }

    public static func == (a: OpenTab, b: OpenTab) -> Bool {
        a.id == b.id && a.buffer === b.buffer && a.isPinned == b.isPinned && a.isReading == b.isReading
    }
}

/// A step in a tab's history: a note and where its caret was.
public struct NavigationEntry: Equatable {
    public var url: URL
    public var caret: Int
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
