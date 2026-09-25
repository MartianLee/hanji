import Foundation

/// "Where is the next closing delimiter?" for a parser that asks again from
/// every opener. Without a memory each unclosed opener rescans the rest of the
/// text — a line of 20k `[[` with no `]]` is 20k scans of 40k units, seconds on
/// the main thread. A search starting anywhere between the last start and the
/// last answer has that same answer, so openers visited left to right cost one
/// pass in total.
struct ForwardScan {
    private let text: NSString
    private let hit: (NSString, Int) -> Bool
    private var start = 0
    private var answer = -1   // first hit at or after `start`; -1 = nothing asked yet

    init(_ text: NSString, where hit: @escaping (NSString, Int) -> Bool) {
        self.text = text
        self.hit = hit
    }

    /// The first index ≥ `from` where `hit` holds, or `text.length` if none.
    mutating func next(from: Int) -> Int {
        if start <= from && from <= answer { return answer }
        var j = from
        while j < text.length && !hit(text, j) { j += 1 }
        start = from
        answer = j
        return j
    }
}
