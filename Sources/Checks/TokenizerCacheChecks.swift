import Foundation
import MarkdownCore

/// The paragraph cache must give exactly what the plain tokenizer gives — on
/// fresh text and after edits that reuse cached lines — and make a re-tokenize
/// of a long note after a one-character edit cheap.
func tokenizerCacheChecks() {
    var seed: UInt64 = 0xCAC4E
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    let lines = ["---", "title: x", "# Head #h", "Some **bold** and `c` #tag [[L]]", "- item", "- [ ] task", "1. one",
                 "> quote", "> [!note] call", "```swift", "let x = 1 #no", "```", "~~~", "    ```", "", "plain text",
                 "`open", "#123 #2026년", "tab\t#t", "a#b", "---", "> - [x] done", "![alt](x.png)", "* star"]
    let cache = TokenizerCache()
    var text = (0..<60).map { _ in lines[next(lines.count)] }.joined(separator: "\n")
    for round in 0..<300 {
        let expected = InlineTokenizer.spans(in: text)
        let got = cache.spans(in: text)
        if got != expected {
            expect(false, "round \(round): cached spans match the tokenizer (\(got.count) vs \(expected.count))")
            return
        }
        // Edit: replace, insert or delete a line, or type into one.
        var ls = text.components(separatedBy: "\n")
        let i = next(ls.count)
        switch next(4) {
        case 0: ls[i] = lines[next(lines.count)]
        case 1: ls.insert(lines[next(lines.count)], at: i)
        case 2: if ls.count > 1 { ls.remove(at: i) }
        default: ls[i] += ["x", " ", "`", "*", "#", "]"][next(6)]
        }
        text = ls.joined(separator: "\n")
    }
    expect(true, "300 rounds of edits: cached spans always match")

    // Code block regions come out of the same pass.
    let doc = "a\n```js\nx\n```\nb\n~~~\nopen"
    _ = cache.spans(in: doc)
    expectEqual(cache.codeBlockRegions, CodeBlockParser.regions(in: doc), "closed code blocks match the parser")
    expectEqual(cache.codeRanges, CodeBlockParser.codeRanges(in: doc), "code ranges (with the open fence) match")

    // Cost: a one-character edit in a 20,000-line note.
    var big: [String] = []
    for i in 0..<5000 { big += ["## Section \(i)", "Paragraph \(i) with **bold**, `code` and [[link]] #tag.", "- item", ""] }
    var long = big.joined(separator: "\n")
    // First load (an empty cache) may not cost noticeably more than tokenizing
    // plainly. Release builds measure ~1.05× (20,000 lines: 37.0 vs 35.2ms); debug
    // builds, where the checks run, ~1.3× from dictionary/hashing overhead.
    func best(_ f: () -> Void) -> TimeInterval {
        (0..<3).map { _ in let t = Date(); f(); return Date().timeIntervalSince(t) }.min()!
    }
    let plainLoad = best { _ = InlineTokenizer.spans(in: long); _ = CodeBlockParser.codeRanges(in: long) }
    let coldLoad = best { _ = TokenizerCache().spans(in: long) }
    let warm = TokenizerCache()
    _ = warm.spans(in: long)
    expect(coldLoad < plainLoad * 1.5,
           "a cold cache (first load) costs about what plain tokenizing does (\(Int(coldLoad * 1000))ms vs \(Int(plainLoad * 1000))ms)")
    long.insert("x", at: long.index(long.startIndex, offsetBy: long.count / 2))
    let t0 = Date()
    _ = warm.spans(in: long)
    let cached = Date().timeIntervalSince(t0)
    let t1 = Date()
    _ = InlineTokenizer.spans(in: long)
    let plain = Date().timeIntervalSince(t1)
    expect(cached < plain / 2, "re-tokenizing after one edit is well under the full cost (\(Int(cached * 1000))ms vs \(Int(plain * 1000))ms)")
}
