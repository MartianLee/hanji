import Foundation

/// Which note a link names — the one rule link clicks, rename rewrites and
/// mention links share.
public enum LinkTarget {
    /// The note `target` names among `paths` (vault-relative, with `.md`, in
    /// file order): by path or by file name, without `.md`, ignoring case; the
    /// first match wins. A `#heading` is ignored.
    public static func resolve(_ target: String, in paths: [String]) -> String? {
        let wanted = key(target)
        guard !wanted.isEmpty else { return nil }
        return paths.first { path in
            let k = key(path)
            return k == wanted || (k as NSString).lastPathComponent == wanted
        }
    }

    /// `raw` as `resolve` compares it: trimmed, without `#…` or `.md`, lowercased.
    public static func key(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }
        return t.lowercased()
    }
}
