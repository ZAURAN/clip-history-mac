// Рисует иконку приложения 1024×1024: usage: swift make_icon.swift out.png
import AppKit

let out = CommandLine.arguments[1]
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.92, alpha: 1))!.draw(in: path, angle: -70)

let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "list.clipboard.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (CGFloat(S) - s.width) / 2, y: (CGFloat(S) - s.height) / 2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
