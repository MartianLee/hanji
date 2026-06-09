import Foundation

public enum TemplaterConfig {
    /// The Templater plugin's templates folder (vault-relative), default "Templates".
    public static func templatesFolder(vaultRoot: URL) -> String {
        let url = vaultRoot.appendingPathComponent(".obsidian/plugins/templater-obsidian/data.json")
        if let data = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let folder = obj["templates_folder"] as? String, !folder.isEmpty {
            return folder
        }
        return "Templates"
    }
}
