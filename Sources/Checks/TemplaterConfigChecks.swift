import Foundation
import TemplateKit

func templaterConfigChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-tpl-\(UUID().uuidString)")
    let dir = vault.appendingPathComponent(".obsidian/plugins/templater-obsidian")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }

    expectEqual(TemplaterConfig.templatesFolder(vaultRoot: vault), "Templates", "default when no config")
    try? "{ \"templates_folder\": \"Meta/Templates\" }".write(
        to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    expectEqual(TemplaterConfig.templatesFolder(vaultRoot: vault), "Meta/Templates", "reads templates_folder")
}
