// Reproducible original artwork for the macOS app and drag-to-install disk image.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent(".build-native/AppIcon.iconset", isDirectory: true)
let distribution = root.appendingPathComponent("Distribution/Artwork", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: distribution, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func image(width: Int, height: Int, scale: Int, draw: () -> Void) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
                                  pixelsHigh: height * scale, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    // NSGraphicsContext already maps bitmap.size points to the pixel dimensions.
    // Scaling again crops every Retina representation to its upper-left quarter.
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func drawIcon(_ size: CGFloat) {
    NSGraphicsContext.current!.cgContext.scaleBy(x: size / 1024, y: size / 1024)
    let face = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                            xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(24, 49, 110, 0.25)
    shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set(); color(36, 91, 232).setFill(); face.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(69, 131, 255), ending: color(23, 57, 181))!.draw(in: face, angle: -90)
    face.lineWidth = 3; color(255, 255, 255, 0.26).setStroke(); face.stroke()
    // The same four-bar voice mark used by the Local Dictation website.
    NSGraphicsContext.saveGraphicsState()
    let markShadow = NSShadow(); markShadow.shadowColor = color(5, 31, 108, 0.2)
    markShadow.shadowBlurRadius = 16; markShadow.shadowOffset = NSSize(width: 0, height: -8)
    markShadow.set(); NSColor.white.setFill()
    for (x, height) in [(CGFloat(336), CGFloat(128)), (452, 384), (568, 512), (684, 224)] {
        NSBezierPath(roundedRect: NSRect(x: x - 41, y: 512 - height / 2, width: 82, height: height),
                     xRadius: 41, yRadius: 41).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (text as NSString).draw(in: NSRect(x: 30, y: y, width: 660, height: size * 1.6),
                           withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                            .foregroundColor: ink, .paragraphStyle: style])
}

func drawBackground() {
    color(248, 249, 252).setFill(); NSRect(x: 0, y: 0, width: 720, height: 460).fill()
    centered("local dictation.", y: 395, size: 20, weight: .bold, ink: color(36, 91, 232))
    centered("Drag to Applications.", y: 354, size: 27, weight: .semibold, ink: color(29, 38, 56))
    let arrow = NSBezierPath(); arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 326, y: 236)); arrow.line(to: NSPoint(x: 394, y: 236))
    arrow.move(to: NSPoint(x: 382, y: 247)); arrow.line(to: NSPoint(x: 394, y: 236))
    arrow.line(to: NSPoint(x: 382, y: 225))
    color(36, 91, 232, 0.58).setStroke(); arrow.stroke()
    centered("Then open Local Dictation from Applications.", y: 91, size: 15, weight: .medium, ink: color(59, 70, 90))
    centered("Follow the permission prompts. Your Mac downloads the local models once.",
             y: 61, size: 12, weight: .regular, ink: color(102, 113, 132))
    centered("Apple Silicon · macOS 14+", y: 28, size: 11, weight: .regular, ink: color(132, 140, 153))
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = image(width: size, height: size, scale: scale) { drawIcon(CGFloat(size)) }
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try image(width: 1024, height: 1024, scale: 1) { drawIcon(1024) }
    .write(to: distribution.appendingPathComponent("app-icon-preview.png"))
for scale in [1, 2] {
    let suffix = scale == 2 ? "@2x" : ""
    try image(width: 720, height: 460, scale: scale, draw: drawBackground)
        .write(to: distribution.appendingPathComponent("dmg-background\(suffix).png"))
}
print("Rendered app icon sizes and Retina disk-image artwork")
