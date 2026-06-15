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
    public var isDirty: Bool { text != savedText }
    public init(file: MarkdownFile, text: String) {
        self.id = UUID()
        self.file = file
        self.text = text
        self.savedText = text
        self.externalConflict = nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
