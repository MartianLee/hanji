import AppKit
import CoreGraphics
import ApplicationServices

// GUI caret probe for Hanji (run it through scripts/caret-probe.sh). Usage: probe <Hanji.app> <vault> <scenario>
// Launches the app on the vault (it opens the first note), drives it with key
// events posted straight to its PID (never to whatever else is frontmost), and
// after each step samples the window 10 times over 2.5s, counting frames that
// show a caret: a thin vertical run of caret-blue pixels in the editor area.
// Prints one line per step: "<step> caret <hits>/10". Kills the app by PID.

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: guiprobe <app> <vault> <scenario>"); exit(2) }
let appPath = args[1], vault = args[2], scenario = args[3]
let debugDir = ProcessInfo.processInfo.environment["PROBE_FRAMES"]

let app = Process()
app.executableURL = URL(fileURLWithPath: appPath + "/Contents/MacOS/hanji")
var env = ProcessInfo.processInfo.environment
env["HANJI_OPEN_VAULT"] = vault
app.environment = env
try app.run()
let pid = app.processIdentifier
defer { app.terminate(); app.waitUntilExit() }
func pause(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
pause(4)

func windowID() -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .max { (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) < (($1[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) }?[kCGWindowNumber as String] as? CGWindowID
}
guard let wid = windowID() else { print("no window"); exit(1) }

let src = CGEventSource(stateID: .privateState)
func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], times: Int = 1, gap: Double = 0.06) {
    focus()
    for _ in 0..<times {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
            e.flags = flags
            e.postToPid(pid)
        }
        pause(gap)
    }
}
func type(_ s: String) {
    for ch in s.utf16 {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            var c = ch
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            e.postToPid(pid)
        }
        pause(0.06)
    }
}
let up: CGKeyCode = 126, down: CGKeyCode = 125, ret: CGKeyCode = 36

var frameNo = 0
func frontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
func focus() {
    if frontmost() { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    pause(0.4)
}
/// (frames showing a caret, frames where Hanji was frontmost)
func caretHits() -> (Int, Int) {
    var hits = 0, valid = 0
    for _ in 0..<10 {
        focus()
        guard frontmost() else { pause(0.25); continue }
        valid += 1
        let path = NSTemporaryDirectory() + "guiprobe-\(pid).png"
        let cap = Process()
        cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        cap.arguments = ["-x", "-o", "-l\(wid)", path]
        try? cap.run(); cap.waitUntilExit()
        frameNo += 1
        if let d = debugDir { try? FileManager.default.copyItem(atPath: path, toPath: "\(d)/\(scenario)-\(frameNo).png") }
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        // Redraw into a known RGBA8 buffer: screencapture's PNGs vary in layout.
        let w = src.width, h = src.height, bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        func blue(_ x: Int, _ y: Int) -> Bool {
            let o = y * bpr + x * 4   // a bitmap context holds its rows top-down
            let (r, g, b) = (Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]))
            return b > 110 && b - r > 35 && b - g > 20
        }
        // Editor area: right of the sidebar, below the tab bar.
        var found = false
        let x0 = Int(Double(w) * 0.25), y0 = Int(Double(h) * 0.12)
        outer: for x in x0..<(w - 4) {
            var run = 0
            for y in y0..<(h - 4) {
                if blue(x, y) { run += 1; if run >= 24 && !blue(x + 4, y) && !blue(x - 4, y) { found = true; break outer } }
                else { run = 0 }
            }
        }
        if found { hits += 1 }
        pause(0.25)
    }
    return (hits, valid)
}
func report(_ step: String) { let (h, v) = caretHits(); print("\(step) caret \(h)/\(v)"); fflush(stdout) }

report("open")
switch scenario {
case "plain":
    key(down, times: 25); pause(0.3); report("arrowed-down-25")
    key(up, times: 10); pause(0.3); report("arrowed-up-10")
    type("abc"); pause(0.3); report("typed")
    key(ret); pause(0.3); report("return")
    key(up, times: 12); pause(0.3); report("arrowed-up-12")
case "mixed":
    key(down, times: 40); pause(0.3); report("arrowed-down-40")
    type("xyz"); pause(0.3); report("typed-above-widgets")
    key(ret); pause(0.3); report("return-above-code")
    key(up, times: 20); pause(0.3); report("arrowed-up-20")
    key(down, times: 30); pause(0.3); report("arrowed-down-30")
case "ends":
    key(down, [.maskCommand]); pause(0.6); report("end-of-note")
    key(up, times: 30); pause(0.4); report("arrowed-up-30-from-end")
    key(up, [.maskCommand]); pause(0.6); report("top-of-note")
default: break
}
