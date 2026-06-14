import Foundation

/// Lightweight, grammar-configured syntax tokenizer for fenced code blocks.
/// One scanner indexes the text as UTF-16 (so token ranges drop straight onto
/// NSTextStorage); per-language `LanguageGrammar` supplies keywords, comment
/// markers, and string delimiters. Unknown languages get a C-like fallback.
public enum CodeHighlighter {
    public enum TokenKind: Equatable { case keyword, type, string, comment, number }

    public struct Token: Equatable {
        public let range: Range<Int>   // UTF-16
        public let kind: TokenKind
        public init(range: Range<Int>, kind: TokenKind) { self.range = range; self.kind = kind }
    }

    public struct LanguageGrammar {
        public let keywords: Set<String>
        public let types: Set<String>
        public let lineComments: [String]
        public let blockComment: (open: String, close: String)?
        public let stringDelims: [Character]
        public init(keywords: Set<String>, types: Set<String> = [], lineComments: [String],
                    blockComment: (open: String, close: String)? = nil, stringDelims: [Character]) {
            self.keywords = keywords; self.types = types
            self.lineComments = lineComments; self.blockComment = blockComment
            self.stringDelims = stringDelims
        }
    }

    public static func tokens(in code: String, language: String) -> [Token] {
        let g = grammar(for: language)
        let ns = code as NSString
        let n = ns.length
        let delimUnits = Set(g.stringDelims.compactMap { $0.unicodeScalars.first.map { UInt16($0.value) } })
        var out: [Token] = []
        var i = 0

        func matches(_ s: String, at k: Int) -> Bool {
            let m = s as NSString
            guard k + m.length <= n else { return false }
            for j in 0..<m.length where ns.character(at: k + j) != m.character(at: j) { return false }
            return true
        }
        func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }
        func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 }
        func isIdentChar(_ u: UInt16) -> Bool { isIdentStart(u) || isDigit(u) }

        while i < n {
            if let lc = g.lineComments.first(where: { matches($0, at: i) }) {
                _ = lc
                var j = i
                while j < n && ns.character(at: j) != 10 { j += 1 }
                out.append(Token(range: i..<j, kind: .comment)); i = j; continue
            }
            if let bc = g.blockComment, matches(bc.open, at: i) {
                var j = i + (bc.open as NSString).length
                while j < n && !matches(bc.close, at: j) { j += 1 }
                if j < n { j += (bc.close as NSString).length }
                out.append(Token(range: i..<min(j, n), kind: .comment)); i = min(j, n); continue
            }
            let u = ns.character(at: i)
            if delimUnits.contains(u) {
                var j = i + 1
                while j < n {
                    let c = ns.character(at: j)
                    if c == 92 { j += 2; continue }
                    if c == u { j += 1; break }
                    j += 1
                }
                out.append(Token(range: i..<min(j, n), kind: .string)); i = min(j, n); continue
            }
            if isDigit(u) {
                var j = i + 1
                while j < n {
                    let c = ns.character(at: j)
                    if isDigit(c) || c == 46 || c == 95 || c == 120 || c == 88
                        || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) { j += 1 } else { break }
                }
                out.append(Token(range: i..<j, kind: .number)); i = j; continue
            }
            if isIdentStart(u) {
                var j = i + 1
                while j < n && isIdentChar(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if g.keywords.contains(word) { out.append(Token(range: i..<j, kind: .keyword)) }
                else if g.types.contains(word) { out.append(Token(range: i..<j, kind: .type)) }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    private static func grammar(for language: String) -> LanguageGrammar {
        switch language.lowercased() {
        case "swift": return swift
        case "js", "javascript", "ts", "typescript", "jsx", "tsx": return javascript
        case "py", "python": return python
        case "json": return json
        case "sh", "bash", "shell", "zsh": return bash
        default: return fallback
        }
    }

    private static let swift = LanguageGrammar(
        keywords: ["func","let","var","if","else","for","while","return","struct","class","enum",
                   "protocol","extension","import","guard","switch","case","default","break","continue",
                   "in","self","nil","true","false","public","private","internal","fileprivate","open",
                   "static","init","deinit","override","throws","throw","try","catch","do","defer",
                   "as","is","where","async","await","weak","unowned","lazy","mutating","some","any","typealias"],
        types: ["Int","String","Bool","Double","Float","Array","Dictionary","Set","Optional","Character","Data","URL","Date","Void"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\""])

    private static let javascript = LanguageGrammar(
        keywords: ["const","let","var","function","return","if","else","for","while","do","class","extends",
                   "new","this","super","import","export","from","default","async","await","try","catch","finally",
                   "throw","typeof","instanceof","in","of","switch","case","break","continue","null","undefined",
                   "true","false","interface","type","enum","public","private","protected","readonly","static","void"],
        types: ["string","number","boolean","any","unknown","never","object","Array","Promise"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'", "`"])

    private static let python = LanguageGrammar(
        keywords: ["def","class","return","if","elif","else","for","while","import","from","as","with",
                   "try","except","finally","raise","pass","break","continue","in","is","not","and","or",
                   "None","True","False","lambda","yield","global","nonlocal","async","await","assert","del"],
        lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])

    private static let json = LanguageGrammar(
        keywords: ["true","false","null"], lineComments: [], blockComment: nil, stringDelims: ["\""])

    private static let bash = LanguageGrammar(
        keywords: ["if","then","else","elif","fi","for","while","until","do","done","case","esac",
                   "function","in","return","echo","export","local","read","source","exit","set","unset","alias"],
        lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])

    /// C-like default for unknown languages. `#` is deliberately NOT a comment
    /// marker (ambiguous across languages) to avoid mis-coloring.
    private static let fallback = LanguageGrammar(
        keywords: ["if","else","for","while","return","function","class","def","const","let","var",
                   "import","export","true","false","null","new","switch","case","break","continue"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'"])
}
