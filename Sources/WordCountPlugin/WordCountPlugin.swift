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
        host.ui.addStatusItem(id: "wordcount") {
            AnyView(WordCountStatusView(textPublisher: textPublisher))
        }
    }
}

/// Compact one-line word/character count for the editor status bar.
struct WordCountStatusView: View {
    let textPublisher: AnyPublisher<String, Never>
    @State private var words = 0
    @State private var chars = 0

    var body: some View {
        Text("\(words) words · \(chars) chars")
            .font(.caption)
            .foregroundStyle(.secondary)
            // At most four counts a second: counting walks the whole note, and
            // doing it on every keystroke cost 12-19ms a key in a 4,000-line
            // note (60-90ms at 20,000). The latest text always gets counted.
            .onReceive(textPublisher.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)) { text in
                words = WordCounter.words(in: text)
                chars = WordCounter.characters(in: text)
            }
    }
}
