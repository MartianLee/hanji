#!/usr/bin/env swift
// Generates Hanji's app icon: a sheet of hanji (Korean mulberry paper, fibres
// and all) with 한 brushed in ink and a red 한지 seal. Pure AppKit/CoreText,
// no external assets; the fibres come from a fixed-seed RNG, so every run gives
// the same icon.
//
//   swift Scripts/generate-icon.swift            # writes Scripts/AppIcon.icns
//   swift Scripts/generate-icon.swift out.png    # just the 1024px master
import AppKit
import Foundation

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

var seed: UInt64 = 0x48414E4A49   // "HANJI"
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}

let paperLight = NSColor(srgbRed: 0.975, green: 0.955, blue: 0.905, alpha: 1)
let paperDark  = NSColor(srgbRed: 0.925, green: 0.890, blue: 0.815, alpha: 1)
let ink        = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.19, alpha: 1)
let sealRed    = NSColor(srgbRed: 0.78, green: 0.16, blue: 0.13, alpha: 0.92)

// --- Tile: Apple's squircle-ish rounded rect with the standard transparent margin.
let margin = S * 0.085
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let TS = rect.width
let tile = CGPath(roundedRect: rect, cornerWidth: TS * 0.2237, cornerHeight: TS * 0.2237, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
              color: NSColor(white: 0, alpha: 0.30).cgColor)
ctx.addPath(tile); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// --- Paper: a warm diagonal wash, then short curved mulberry fibres.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let wash = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [paperLight.cgColor, paperDark.cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(wash, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
for _ in 0..<420 {
    let x = rect.minX + rnd() * rect.width, y = rect.minY + rnd() * rect.height
    let len = S * (0.02 + rnd() * 0.07), angle = rnd() * .pi * 2, bend = (rnd() - 0.5) * len * 0.6
    let fibre = CGMutablePath()
    fibre.move(to: CGPoint(x: x, y: y))
    fibre.addQuadCurve(to: CGPoint(x: x + cos(angle) * len, y: y + sin(angle) * len),
                       control: CGPoint(x: x + cos(angle) * len / 2 - sin(angle) * bend,
                                        y: y + sin(angle) * len / 2 + cos(angle) * bend))
    ctx.addPath(fibre)
    ctx.setStrokeColor(NSColor(srgbRed: 0.55, green: 0.47, blue: 0.33, alpha: 0.05 + rnd() * 0.09).cgColor)
    ctx.setLineWidth(S * (0.0012 + rnd() * 0.002)); ctx.setLineCap(.round); ctx.strokePath()
}
ctx.restoreGState()

/// Draw `text` with its ink (not its line box) centred on `center`.
func draw(_ text: String, font: NSFont, color: NSColor, center: CGPoint) {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    ctx.textPosition = .zero   // image bounds are measured from the current text position
    let ink = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
    CTLineDraw(line, ctx)
}

let myungjo = { (size: CGFloat) in NSFont(name: "AppleMyungjo", size: size) ?? .systemFont(ofSize: size, weight: .bold) }

// --- 한 in ink, a little left of centre to balance the seal.
draw("한", font: myungjo(TS * 0.62), color: ink, center: CGPoint(x: rect.midX - TS * 0.04, y: rect.midY + TS * 0.02))

// --- Red seal (낙관) with 한 over 지, bottom right.
let sealSize = TS * 0.19
let sealCenter = CGPoint(x: rect.maxX - TS * 0.19, y: rect.minY + TS * 0.19)
ctx.addPath(CGPath(roundedRect: CGRect(x: sealCenter.x - sealSize / 2, y: sealCenter.y - sealSize / 2,
                                      width: sealSize, height: sealSize),
                   cornerWidth: sealSize * 0.12, cornerHeight: sealSize * 0.12, transform: nil))
ctx.setFillColor(sealRed.cgColor); ctx.fillPath()
for (i, ch) in ["한", "지"].enumerated() {
    draw(ch, font: myungjo(sealSize * 0.40), color: paperLight,
         center: CGPoint(x: sealCenter.x, y: sealCenter.y + (0.5 - CGFloat(i)) * sealSize * 0.40))
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!

// --- Output: a PNG if asked for one, else the full .icns next to this script.
let args = CommandLine.arguments.dropFirst()
if let out = args.first, out.hasSuffix(".png") {
    try! png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
    exit(0)
}
let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let icns = args.first.map { URL(fileURLWithPath: $0) } ?? scripts.appendingPathComponent("AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Hanji-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("master.png")
try! png.write(to: master)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path]
        sips.standardOutput = FileHandle.nullDevice
        try! sips.run(); sips.waitUntilExit()
    }
}
try! FileManager.default.removeItem(at: master)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run(); iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
print("wrote \(icns.path)")
