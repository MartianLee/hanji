import Foundation

// Minimal zero-dependency test harness (XCTest is unavailable with Command Line
// Tools only). Run with `swift run Checks [GroupName …]`, or `--changed [--slow]
// [--base REF]` for just the groups a change reaches (see ChangedChecks).
// Exits non-zero on failure.

enum Check {
    static var passed = 0
    static var failures: [String] = []
    /// How much longer a timed check may take here than on a developer's Mac.
    /// Hosted CI runners are shared VMs, several times slower and noisier (a
    /// paste the M-series Macs the limits were set on do in 250ms took 1.0–1.5s
    /// on GitHub's macos-15), so there the absolute limits are 3× looser. The
    /// machine-independent guards (counters, growth ratios) aren't scaled.
    static let timeSlack: Double = ProcessInfo.processInfo.environment["CI"] != nil ? 3 : 1
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #file, line: UInt = #line) {
    if condition() { Check.passed += 1 }
    else { Check.failures.append("\(file):\(line) — \(message)") }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T,
                               _ expected: @autoclosure () -> T,
                               _ message: String = "",
                               file: StaticString = #file, line: UInt = #line) {
    let a = actual(); let e = expected()
    if a == e { Check.passed += 1 }
    else { Check.failures.append("\(file):\(line) — \(message) (got \(a), expected \(e))") }
}

func runChecks(_ groups: [(name: String, run: () -> Void)]) -> Never {
    var args = Array(CommandLine.arguments.dropFirst())
    let includeSlow = args.contains("--slow")
    args.removeAll { $0 == "--slow" }
    var names: [String]
    if args.contains("--changed") {
        var base = "HEAD"
        if let b = args.firstIndex(of: "--base"), b + 1 < args.count { base = args[b + 1] }
        let selection = ChangedChecks.select(base: base, includeSlow: includeSlow)
        for note in selection.notes { print("ℹ️  \(note)") }
        if !selection.skippedSlow.isEmpty {
            print("⏭  Skipped slow (add --slow): \(selection.skippedSlow.joined(separator: ", "))")
        }
        guard !selection.groups.isEmpty else { print("✅ No check group is affected by the change"); exit(0) }
        print("▶︎ \(selection.groups.count) affected group(s)")
        names = selection.groups
    } else {
        names = args.filter { !$0.hasPrefix("--") }
    }
    let byName = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    if let unknown = names.first(where: { byName[$0] == nil }) {
        print("No check group named '\(unknown)'. Available: \(groups.map(\.name).joined(separator: ", "))")
        exit(2)
    }
    let selected = names.isEmpty ? groups : names.compactMap { byName[$0] }
    for g in selected { g.run() }
    if Check.failures.isEmpty {
        print("✅ All checks passed (\(Check.passed) assertions, \(selected.count) group(s))")
        exit(0)
    } else {
        print("❌ \(Check.failures.count) failure(s) [\(Check.passed) passed]:")
        for f in Check.failures { print("  - \(f)") }
        exit(1)
    }
}
