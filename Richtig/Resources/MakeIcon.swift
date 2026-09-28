// Zeichnet das App-Symbol und legt es als PNG-Satz ab.
// Aufruf: swift MakeIcon.swift <Zielordner>
import AppKit

let arguments = CommandLine.arguments
let destination = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : ".")

func drawIcon(size: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.225

    let background = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.72, blue: 0.72, alpha: 1)
    ])
    gradient?.draw(in: background, angle: -60)

    // Waveform: two speakers, mirrored – one listening, one answering.
    let barCount = 7
    let spacing = body.width / CGFloat(barCount + 3)
    let heights: [CGFloat] = [0.24, 0.46, 0.70, 0.94, 0.62, 0.38, 0.20]
    NSColor.white.withAlphaComponent(0.95).setFill()

    for index in 0..<barCount {
        let height = body.height * 0.42 * heights[index]
        let x = body.minX + spacing * CGFloat(index + 2) - spacing * 0.28
        let barRect = NSRect(
            x: x,
            y: body.midY - height / 2,
            width: spacing * 0.55,
            height: height
        )
        NSBezierPath(
            roundedRect: barRect,
            xRadius: barRect.width / 2,
            yRadius: barRect.width / 2
        ).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for entry in sizes {
    guard let rep = drawIcon(size: entry.pixels),
          let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: destination.appendingPathComponent("\(entry.name).png"))
}
print("Icons geschrieben nach \(destination.path)")
