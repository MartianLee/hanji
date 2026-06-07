import SwiftUI
import Combine
import ExtensionSDK

public enum WordCounter {
    public static func words(in text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
    public static func characters(in text: String) -> Int {
        text.count
    }
}

public struct WordCountPlugin: Plugin {
    public static let id = "io.hanji.wordcount"
    public init() {}

    public func activate(host: PluginHost) {
        let textPublisher = host.editor.activeText
        host.ui.addSidebarView(id: "wordcount", title: "Word Count") {
            AnyView(WordCountView(textPublisher: textPublisher))
        }
    }
}

struct WordCountView: View {
    let textPublisher: AnyPublisher<String, Never>
    @State private var words = 0
    @State private var chars = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Words: \(words)")
            Text("Characters: \(chars)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(textPublisher) { text in
            words = WordCounter.words(in: text)
            chars = WordCounter.characters(in: text)
        }
    }
}
