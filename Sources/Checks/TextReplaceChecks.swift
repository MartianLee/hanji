import Foundation
import MarkdownCore

func textReplaceChecks() {
    // Non-overlapping scan: "aaaa" holds two "aa", not three.
    expectEqual(TextReplace.count(of: "aa", in: "aaaa"), 2, "matches do not overlap")

    // An empty needle must terminate and match nothing (the scan loop would
    // otherwise never advance).
    expectEqual(TextReplace.count(of: "", in: "abc"), 0, "empty needle matches nothing")
    expect(TextReplace.apply("", with: "x", in: "abc") == nil, "empty needle is a no-op")

    // Case sensitivity is opt-in per call.
    expectEqual(TextReplace.count(of: "Note", in: "note Note NOTE"), 1, "case-sensitive by default")
    expectEqual(TextReplace.count(of: "Note", in: "note Note NOTE", caseSensitive: false), 3,
                "case-insensitive finds every casing")

    // Replacement is applied to every occurrence.
    expectEqual(TextReplace.apply("a", with: "b", in: "aXa"), "bXb", "replaces all occurrences")

    // A replacement that contains the needle must not be rescanned, or "a"→"aa"
    // would grow forever.
    expectEqual(TextReplace.apply("a", with: "aa", in: "aa"), "aaaa", "replacement is not rescanned")

    // Nothing to do reports nil, so callers can skip the write entirely.
    expect(TextReplace.apply("zz", with: "y", in: "abc") == nil, "no match → nil")

    // Case-insensitive replace keeps the replacement's own casing.
    expectEqual(TextReplace.apply("note", with: "memo", in: "Note note", caseSensitive: false),
                "memo memo", "case-insensitive replace rewrites every casing")

    // Multi-byte text: offsets are UTF-16, which is what NSString/TextKit use.
    expectEqual(TextReplace.count(of: "노트", in: "내 노트와 노트"), 2, "counts Korean matches")
    expectEqual(TextReplace.apply("노트", with: "메모", in: "내 노트와 노트"), "내 메모와 메모",
                "replaces Korean matches")

    let ranges = TextReplace.ranges(of: "노트", in: "내 노트와 노트")
    expectEqual(ranges.count, 2, "two ranges")
    let ns = "내 노트와 노트" as NSString
    if let first = ranges.first {
        expectEqual(ns.substring(with: NSRange(location: first.lowerBound,
                                               length: first.upperBound - first.lowerBound)),
                    "노트", "ranges are UTF-16 offsets usable with NSString")
    }

    // Newlines are ordinary characters — a needle may span lines.
    expectEqual(TextReplace.apply("a\nb", with: "c", in: "x\na\nb\ny"), "x\nc\ny",
                "needle may span a line break")
}
