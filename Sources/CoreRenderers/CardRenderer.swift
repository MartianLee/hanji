import SwiftUI
import ExtensionSDK

/// A simple built-in renderer: shows a fenced ```card block as a bordered card.
/// Proves the renderer pipeline end-to-end; richer renderers (mermaid, Dataview,
/// images) register the same way.
public struct CardRenderer: CodeBlockRenderer {
    public let language = "card"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(
            Text(source)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.4)))
        )
    }
}
