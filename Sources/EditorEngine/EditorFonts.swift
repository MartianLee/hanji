import AppKit

/// The editor's fonts (Settings ▸ Appearance ▸ Text font / Code font). A choice
/// is stored as a string: "" for the system's own (San Francisco, SF Mono),
/// `systemSerif` for its serif design (New York), or an installed family name.
/// A family that isn't installed (any more) falls back to the system's.
public enum EditorFonts {
    public static let systemSerif = "system-serif"

    /// Families to offer for text: everything installed, minus the system's
    /// hidden `.`-prefixed ones.
    public static var textFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }

    /// Families to offer for code: the monospaced ones.
    public static var codeFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFontDescriptor(name: $0, size: 0).object(forKey: .family) as? String })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Whether `choice` names a font this Mac has ("" and `systemSerif` always do).
    public static func isAvailable(_ choice: String) -> Bool {
        choice.isEmpty || choice == systemSerif || family(choice, size: 12) != nil
    }

    /// Regular text in `choice`.
    public static func text(_ choice: String, size: CGFloat) -> NSFont {
        cached("t", choice, size) {
            if choice == systemSerif { return serif(size: size, bold: false) }
            return family(choice, size: size) ?? .systemFont(ofSize: size)
        }
    }

    /// Bold text in `choice` (headings).
    public static func boldText(_ choice: String, size: CGFloat) -> NSFont {
        cached("b", choice, size) {
            if choice == systemSerif { return serif(size: size, bold: true) }
            guard let regular = family(choice, size: size) else { return .boldSystemFont(ofSize: size) }
            return NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        }
    }

    /// Code in `choice`.
    public static func code(_ choice: String, size: CGFloat) -> NSFont {
        cached("c", choice, size) {
            family(choice, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private static func family(_ name: String, size: CGFloat) -> NSFont? {
        guard !name.isEmpty, name != systemSerif else { return nil }
        return NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
    }

    private static func serif(size: CGFloat, bold: Bool) -> NSFont {
        let system: NSFont = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    }

    /// Styling asks for these once per run of text, so remember them rather than
    /// look the family up each time.
    private static var fonts: [String: NSFont] = [:]
    private static func cached(_ kind: String, _ choice: String, _ size: CGFloat, _ make: () -> NSFont) -> NSFont {
        let key = "\(kind)|\(choice)|\(size)"
        if let font = fonts[key] { return font }
        let font = make()
        fonts[key] = font
        return font
    }
}
