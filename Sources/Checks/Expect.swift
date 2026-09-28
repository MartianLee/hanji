import Foundation

// Minimal zero-dependency test harness (XCTest is unavailable with Command Line
// Tools only). Run with `swift run Checks [GroupName]`. Exits non-zero on failure.

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
    let filter = CommandLine.arguments.dropFirst().first
    let selected = filter.map { f in groups.filter { $0.name == f } } ?? groups
    if let f = filter, selected.isEmpty {
        print("No check group named '\(f)'. Available: \(groups.map(\.name).joined(separator: ", "))")
        exit(2)
    }
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
