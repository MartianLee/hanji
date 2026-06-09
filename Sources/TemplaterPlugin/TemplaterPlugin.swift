import Foundation
import ExtensionSDK
import TemplateKit

public struct TemplaterPlugin: Plugin {
    public static let id = "io.hanji.templater"
    public init() {}

    public func activate(host: PluginHost) {
        host.commands.register(Command(id: "templater.newFromTemplate", title: "New note from template…") { [weak ws = host.workspace] in
            guard let ws, let root = ws.vaultRoot else { return }
            let folder = TemplaterConfig.templatesFolder(vaultRoot: root)
            guard let templateRel = ws.pickNote(title: "Choose a template", startingFolder: folder) else { return }
            let templateText = ws.readNote(relativePath: templateRel) ?? ""
            guard let newRel = ws.promptNewNotePath(suggestedName: "Untitled.md") else { return }
            let base = ((newRel as NSString).lastPathComponent as NSString).deletingPathExtension
            let rendered = TemplateEngine.render(templateText,
                TemplateContext(now: Date(), title: base, creationDate: Date()))
            ws.createNote(relativePath: newRel, text: rendered.text, cursorOffset: rendered.cursorOffset)
            ws.openNote(relativePath: newRel)
        })
    }
}
