#!/usr/bin/env swift
// Generates hanji's app icon: a violet→indigo squircle tile with a white
// markdown-style "M" + down-arrow mark. Renders a 1024px master, expands to an
// .iconset, and packs an .icns. Pure AppKit/CoreGraphics — no external assets.
import AppKit
import Foundation

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// --- Tile (rounded-rect "squircle") with a transparent margin like Apple templates.
let margin = S * 0.085
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let TS = rect.width
let radius = TS * 0.2237
let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
              color: NSColor(white: 0, alpha: 0.35).cgColor)
ctx.addPath(tile); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// Diagonal violet→indigo gradient fill.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(srgbRed: 0.52, green: 0.39, blue: 1.00, alpha: 1).cgColor,   // #845CFF
             NSColor(srgbRed: 0.28, green: 0.13, blue: 0.62, alpha: 1).cgColor]   // #47219E
            as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Glossy highlight sweeping the upper area.
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.minX, y: rect.midY), options: [])
ctx.restoreGState()

// Subtle inner stroke for crispness.
ctx.saveGState()
ctx.addPath(tile)
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
ctx.setLineWidth(S * 0.006)
ctx.strokePath()
ctx.restoreGState()

// --- The mark: a heavy white "M" with a down-arrow to its right.
let ink = NSColor.white
// "M" via a heavy rounded system font (fallback to heavy system font).
let fontSize = TS * 0.52
let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
let font: NSFont = {
    if let d = baseFont.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: fontSize) ?? baseFont }
    return baseFont
}()
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
let m = NSAttributedString(string: "M", attributes: attrs)
let mSize = m.size()
let groupCenterY = rect.midY
let mX = rect.minX + TS * 0.135
let mY = groupCenterY - mSize.height / 2
m.draw(at: CGPoint(x: mX, y: mY))

// Down-arrow to the right of the M.
let ax = rect.minX + TS * 0.715
let armH = TS * 0.46
let top = groupCenterY + armH / 2
let bottom = groupCenterY - armH / 2
let lw = TS * 0.085
let head = TS * 0.16
ctx.saveGState()
ctx.setStrokeColor(ink.cgColor)
ctx.setLineWidth(lw)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
// stem
ctx.move(to: CGPoint(x: ax, y: top))
ctx.addLine(to: CGPoint(x: ax, y: bottom))
// chevron head
ctx.move(to: CGPoint(x: ax - head, y: bottom + head))
ctx.addLine(to: CGPoint(x: ax, y: bottom))
ctx.addLine(to: CGPoint(x: ax + head, y: bottom + head))
ctx.strokePath()
ctx.restoreGState()

img.unlockFocus()

// --- Write master PNG.
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render\n".data(using: .utf8)!); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/hanji-icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
