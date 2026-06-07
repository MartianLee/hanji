import Foundation
import Combine
import VaultKit

public final class AppState: ObservableObject {
    @Published public var vaultRoot: URL?
    @Published public var files: [MarkdownFile] = []
    @Published public var selectedFile: MarkdownFile?
    @Published public var activeText: String = ""
    @Published public var index: MetadataIndex = MetadataIndex()
    public let rendererRegistry = DefaultRendererRegistry()

    private var vault: Vault?

    public init() {}

    public func openVault(at root: URL) {
        let v = Vault(root: root)
        vault = v
        vaultRoot = root
        files = (try? v.markdownFiles()) ?? []
        index = (try? MetadataIndex.build(from: v)) ?? MetadataIndex()
        selectedFile = nil
        activeText = ""
    }

    public func open(_ file: MarkdownFile) {
        selectedFile = file
        activeText = (try? vault?.read(file)) ?? ""
    }

    public func save() {
        guard let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
    }
}
