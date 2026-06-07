import SwiftUI
import ExtensionSDK
import AppCore

private struct FakeRenderer: CodeBlockRenderer {
    let language = "card"
    func makeView(source: String) -> AnyView { AnyView(Text(source)) }
}

func rendererRegistryChecks() {
    let reg = DefaultRendererRegistry()
    reg.register(FakeRenderer())
    expect(reg.renderer(for: "card") != nil, "renderer found by language")
    expect(reg.renderer(for: "nope") == nil, "unknown language returns nil")
}
