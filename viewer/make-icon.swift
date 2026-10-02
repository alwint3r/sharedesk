// Artwork source for sharedesk-viewer.icns. Run on macOS:
//   swift viewer/make-icon.swift /path/to/Sharedesk.iconset
//   iconutil -c icns /path/to/Sharedesk.iconset -o viewer/sharedesk-viewer.icns
// This is an asset-generation script, not part of the viewer executable.
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift viewer/make-icon.swift OUTPUT.iconset\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255,
                                           CGFloat((hex >> 8) & 255) / 255,
                                           CGFloat(hex & 255) / 255, alpha])!
}
func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fill(_ context: CGContext, _ path: CGPath, _ color: CGColor) {
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
}

func icon(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = rounded(CGRect(x: 64, y: 64, width: 896, height: 896), radius: 196)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x277EE8), color(0x1445A4)] as CFArray,
                                locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 360, y: 950), end: CGPoint(x: 700, y: 64),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, alpha: 0.16), color(0xFFFFFF, alpha: 0)] as CFArray,
                               locations: [0, 1])!
    context.drawRadialGradient(highlight, startCenter: CGPoint(x: 200, y: 850), startRadius: 20,
                               endCenter: CGPoint(x: 200, y: 850), endRadius: 740,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.20))
    context.setLineWidth(2)
    context.strokePath()

    // Two offset desktops linked by a short cable. No text, arrows or padlock.
    let rear = CGRect(x: 188, y: 494, width: 422, height: 264)
    let front = CGRect(x: 414, y: 288, width: 422, height: 264)
    let cable = CGMutablePath()
    cable.move(to: CGPoint(x: 348, y: 433))
    cable.addLine(to: CGPoint(x: 322, y: 433))
    cable.addCurve(to: CGPoint(x: 290, y: 401), control1: CGPoint(x: 300, y: 433), control2: CGPoint(x: 290, y: 421))
    cable.addLine(to: CGPoint(x: 290, y: 364))
    cable.addCurve(to: CGPoint(x: 322, y: 332), control1: CGPoint(x: 290, y: 342), control2: CGPoint(x: 300, y: 332))
    cable.addLine(to: CGPoint(x: 430, y: 332))
    context.addPath(cable)
    context.setStrokeColor(color(0xA8EDFF))
    context.setLineWidth(size <= 32 ? 38 : 28)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    for (index, rect) in [rear, front].enumerated() {
        let white = index == 0 ? color(0xEBF4FF) : color(0xFFFFFF)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x00152F, alpha: 0.27))
        fill(context, rounded(CGRect(x: rect.midX - 15, y: rect.minY - 54, width: 30, height: 60), radius: 9), white)
        fill(context, rounded(CGRect(x: rect.midX - 67, y: rect.minY - 66, width: 134, height: 26), radius: 13), white)
        fill(context, rounded(rect, radius: 36), white)
        context.restoreGState()
        // Thicker bezels keep the small Finder/Dock representations legible.
        let bezel: CGFloat = size <= 32 ? 38 : 28
        let pane = rect.insetBy(dx: bezel, dy: bezel)
        let panePath = rounded(pane, radius: 13)
        fill(context, panePath, color(index == 0 ? 0x398CF2 : 0x276CD7))
        if size >= 64 {
            context.saveGState()
            context.addPath(panePath)
            context.clip()
            let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, alpha: 0.14), color(0xFFFFFF, alpha: 0)] as CFArray,
                                   locations: [0, 1])!
            context.drawLinearGradient(gloss, start: CGPoint(x: pane.minX, y: pane.maxY), end: CGPoint(x: pane.maxX, y: pane.minY), options: [])
            context.restoreGState()
        }
    }
    return context.makeImage()!
}

// Standard macOS 1x/2x representations. Render directly at each pixel size;
// do not downsample the master and lose the small-size geometry adjustments.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(filename) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, icon(size: size * scale), nil)
        precondition(CGImageDestinationFinalize(destination), "Could not write \(filename)")
    }
}
