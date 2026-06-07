import ExtensionSDK

public final class DefaultRendererRegistry: RendererRegistry {
    private var byLanguage: [String: CodeBlockRenderer] = [:]
    public init() {}
    public func register(_ renderer: CodeBlockRenderer) { byLanguage[renderer.language] = renderer }
    public func renderer(for language: String) -> CodeBlockRenderer? { byLanguage[language] }
}
