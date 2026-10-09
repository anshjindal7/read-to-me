// Draws the app icon (an open book with headphones on an orange tile) into an .iconset folder.
// Usage: swift scripts/make_icon.swift <output.iconset>

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded tile with a warm gradient, inset like standard macOS icons.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1),
               ending: NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.16, alpha: 1))!
        .draw(in: path, angle: -90)

    // White symbols on top.
    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    func drawSymbol(_ name: String, centerY: CGFloat, scale: CGFloat) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let w = symbol.size.width * scale, h = symbol.size.height * scale
        symbol.draw(in: NSRect(x: size / 2 - w / 2, y: centerY - h / 2, width: w, height: h))
    }
    drawSymbol("headphones", centerY: size * 0.61, scale: 0.78)
    drawSymbol("book.fill", centerY: size * 0.3, scale: 0.5)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try drawIcon(pixels: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
