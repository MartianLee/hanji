import Foundation

public struct TemplateContext {
    public var now: Date
    public var title: String
    public var creationDate: Date
    public var timeZone: TimeZone
    public init(now: Date = Date(), title: String, creationDate: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now; self.title = title; self.creationDate = creationDate; self.timeZone = timeZone
    }
}

public struct RenderedTemplate: Equatable {
    public let text: String
    public let cursorOffset: Int?
    public init(text: String, cursorOffset: Int?) { self.text = text; self.cursorOffset = cursorOffset }
}

public enum TemplateEngine {
    public static func render(_ template: String, _ ctx: TemplateContext) -> RenderedTemplate {
        let s = Array(template)
        var out = ""
        var cursor: (order: Int, offset: Int)? = nil
        var i = 0
        while i < s.count {
            if s[i] == "<", i + 1 < s.count, s[i + 1] == "%" {
                let isExec = (i + 2 < s.count && s[i + 2] == "*")
                // j lands on the '%' of the closing '%>' if found, else s.count (unterminated).
                var j = i + 2
                while j < s.count && !(s[j] == "%" && j + 1 < s.count && s[j + 1] == ">") { j += 1 }
                let inner = String(s[(i + 2)..<j])
                let end = (j < s.count) ? j + 2 : s.count
                if !isExec, let call = parseCall(inner) {
                    if call.function == "file.cursor" {
                        let order = call.intArg(0) ?? 0
                        if cursor == nil || order < cursor!.order { cursor = (order, out.utf16.count) }
                    } else {
                        out += evaluate(call, ctx)
                    }
                }
                i = end
            } else {
                out.append(s[i]); i += 1
            }
        }
        return RenderedTemplate(text: out, cursorOffset: cursor?.offset)
    }

    // MARK: - Parsing

    private enum Arg { case string(String), int(Int)
        var asString: String? { if case .string(let v) = self { return v }; return nil }
        var asInt: Int? { if case .int(let v) = self { return v }; return nil }
    }
    private struct Call {
        let namespace: String   // e.g. "tp"
        let function: String    // e.g. "date.now", "file.title"
        let args: [Arg]
        func stringArg(_ i: Int) -> String? { i < args.count ? args[i].asString : nil }
        func intArg(_ i: Int) -> Int? { i < args.count ? args[i].asInt : nil }
    }

    private static func parseCall(_ raw: String) -> Call? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var head = trimmed
        var argsPart = ""
        if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
            head = String(trimmed[trimmed.startIndex..<open])
            argsPart = String(trimmed[trimmed.index(after: open)..<close])
        }
        let dotted = head.split(separator: ".", maxSplits: 1).map(String.init)
        guard dotted.count == 2 else { return nil }
        return Call(namespace: dotted[0], function: dotted[1], args: parseArgs(argsPart))
    }

    private static func parseArgs(_ s: String) -> [Arg] {
        var args: [Arg] = []
        var fields: [String] = []
        var cur = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch) }
            else if ch == "," && !inQuote { fields.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty || !fields.isEmpty { fields.append(cur) }
        for f in fields {
            let t = f.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
                args.append(.string(String(t.dropFirst().dropLast())))
            } else if let n = Int(t) {
                args.append(.int(n))
            }
        }
        return args
    }

    // MARK: - Evaluation

    private static func evaluate(_ call: Call, _ ctx: TemplateContext) -> String {
        func addDays(_ d: Date, _ n: Int) -> Date {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = ctx.timeZone
            return cal.date(byAdding: .day, value: n, to: d) ?? d
        }
        switch call.function {
        case "date.now":
            return MomentFormat.format(addDays(ctx.now, call.intArg(1) ?? 0),
                                       call.stringArg(0) ?? "YYYY-MM-DD", timeZone: ctx.timeZone)
        case "date.tomorrow":
            return MomentFormat.format(addDays(ctx.now, 1), call.stringArg(0) ?? "YYYY-MM-DD", timeZone: ctx.timeZone)
        case "date.yesterday":
            return MomentFormat.format(addDays(ctx.now, -1), call.stringArg(0) ?? "YYYY-MM-DD", timeZone: ctx.timeZone)
        case "file.title":
            return ctx.title
        case "file.creation_date":
            return MomentFormat.format(ctx.creationDate, call.stringArg(0) ?? "YYYY-MM-DD HH:mm", timeZone: ctx.timeZone)
        default:
            return ""
        }
    }
}
