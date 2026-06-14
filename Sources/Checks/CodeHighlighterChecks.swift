import Foundation
import MarkdownCore

func codeHighlighterChecks() {
    func toks(_ code: String, _ lang: String) -> [(CodeHighlighter.TokenKind, String)] {
        let ns = code as NSString
        return CodeHighlighter.tokens(in: code, language: lang).map { t in
            (t.kind, ns.substring(with: NSRange(location: t.range.lowerBound,
                                                length: t.range.upperBound - t.range.lowerBound)))
        }
    }
    func has(_ ts: [(CodeHighlighter.TokenKind, String)], _ kind: CodeHighlighter.TokenKind, _ text: String) -> Bool {
        ts.contains { $0.0 == kind && $0.1 == text }
    }

    let sw = toks("func f() { let x = 1 } // note", "swift")
    expect(has(sw, .keyword, "func"), "swift func keyword")
    expect(has(sw, .keyword, "let"), "swift let keyword")
    expect(has(sw, .number, "1"), "swift number")
    expect(has(sw, .comment, "// note"), "swift line comment")

    let sw2 = toks("/* a\nb */ let s = \"hi\"", "swift")
    expect(has(sw2, .comment, "/* a\nb */"), "multi-line block comment")
    expect(has(sw2, .string, "\"hi\""), "swift string")

    let esc = toks("\"a\\\"b\"", "swift")
    expectEqual(esc.count, 1, "escaped quote does not split the string")
    expect(esc.first?.0 == .string, "escaped string token kind")

    let py = toks("# c\ndef g():\n    return None", "python")
    expect(has(py, .comment, "# c"), "python hash comment")
    expect(has(py, .keyword, "def"), "python def")
    expect(has(py, .keyword, "return"), "python return")
    expect(has(py, .keyword, "None"), "python None")

    let js = toks("const x = 'hi'; // c", "js")
    expect(has(js, .keyword, "const"), "js const (alias resolves)")
    expect(has(js, .string, "'hi'"), "js single-quote string")
    expect(has(js, .comment, "// c"), "js line comment")

    let json = toks("{\"a\": 12, \"b\": true}", "json")
    expect(has(json, .string, "\"a\""), "json key string")
    expect(has(json, .number, "12"), "json number")
    expect(has(json, .keyword, "true"), "json literal")

    let sh = toks("# c\necho hi", "bash")
    expect(has(sh, .comment, "# c"), "bash hash comment")
    expect(has(sh, .keyword, "echo"), "bash echo keyword")

    let fb = toks("x = 1 // c", "rust")
    expect(has(fb, .comment, "// c"), "fallback line comment")
    expect(has(fb, .number, "1"), "fallback number")
    let fbHash = toks("a # 2", "rust")
    expect(!fbHash.contains { $0.0 == .comment }, "fallback does not treat # as a comment")
}
