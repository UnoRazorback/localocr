#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Rendition {
    let filename: String
    let pixels: Int
}

private let renditions = [
    Rendition(filename: "AppIcon-16.png", pixels: 16),
    Rendition(filename: "AppIcon-16@2x.png", pixels: 32),
    Rendition(filename: "AppIcon-32.png", pixels: 32),
    Rendition(filename: "AppIcon-32@2x.png", pixels: 64),
    Rendition(filename: "AppIcon-128.png", pixels: 128),
    Rendition(filename: "AppIcon-128@2x.png", pixels: 256),
    Rendition(filename: "AppIcon-256.png", pixels: 256),
    Rendition(filename: "AppIcon-256@2x.png", pixels: 512),
    Rendition(filename: "AppIcon-512.png", pixels: 512),
    Rendition(filename: "AppIcon-512@2x.png", pixels: 1024),
]

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let ground = CGColor(
    colorSpace: colorSpace,
    components: [0xF4 / 255, 0xF2 / 255, 0xEC / 255, 1]
)!
private let olive = CGColor(
    colorSpace: colorSpace,
    components: [0x4A / 255, 0x57 / 255, 0x29 / 255, 1]
)!
private let foldStroke = CGColor(
    colorSpace: colorSpace,
    components: [0x17 / 255, 0x16 / 255, 0x0F / 255, 0.52]
)!
private let scanRule = CGColor(
    colorSpace: colorSpace,
    components: [0xF4 / 255, 0xF2 / 255, 0xEC / 255, 0.92]
)!

private func makeContext(side: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "LocalOCRAppIcon", code: 1)
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

private func drawIcon(side: Int) throws -> CGImage {
    let context = try makeContext(side: side)
    let length = CGFloat(side)

    context.clear(CGRect(x: 0, y: 0, width: length, height: length))

    let tileInset = max(1, length * 0.045)
    let tile = CGRect(
        x: tileInset,
        y: tileInset,
        width: length - 2 * tileInset,
        height: length - 2 * tileInset
    )
    let tileRadius = length * 0.215
    context.addPath(
        CGPath(
            roundedRect: tile,
            cornerWidth: tileRadius,
            cornerHeight: tileRadius,
            transform: nil
        )
    )
    context.setFillColor(ground)
    context.fillPath()

    context.addPath(
        CGPath(
            roundedRect: tile.insetBy(dx: length * 0.006, dy: length * 0.006),
            cornerWidth: tileRadius,
            cornerHeight: tileRadius,
            transform: nil
        )
    )
    context.setStrokeColor(olive.copy(alpha: 0.18)!)
    context.setLineWidth(max(0.5, length * 0.008))
    context.strokePath()

    let pageLeft = length * 0.265
    let pageRight = length * 0.735
    let pageBottom = length * 0.19
    let pageTop = length * 0.81
    let fold = length * 0.145

    let page = CGMutablePath()
    page.move(to: CGPoint(x: pageLeft, y: pageBottom))
    page.addLine(to: CGPoint(x: pageLeft, y: pageTop))
    page.addLine(to: CGPoint(x: pageRight - fold, y: pageTop))
    page.addLine(to: CGPoint(x: pageRight, y: pageTop - fold))
    page.addLine(to: CGPoint(x: pageRight, y: pageBottom))
    page.closeSubpath()
    context.addPath(page)
    context.setFillColor(olive)
    context.fillPath()

    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: pageRight - fold, y: pageTop))
    foldPath.addLine(to: CGPoint(x: pageRight - fold, y: pageTop - fold))
    foldPath.addLine(to: CGPoint(x: pageRight, y: pageTop - fold))
    context.addPath(foldPath)
    context.setStrokeColor(foldStroke)
    context.setLineWidth(max(1, length * 0.018))
    context.setLineJoin(.round)
    context.strokePath()

    context.setStrokeColor(scanRule)
    context.setLineCap(side == 16 ? .butt : .round)
    context.setLineWidth(max(1, length * 0.025))

    // At Finder's smallest native size, two pixel-aligned rules stay legible.
    // Larger renditions retain the full three-rule document mark.
    let ruleLeft = side == 16 ? CGFloat(6) : length * 0.365
    let ruleWidths = side == 16
        ? [CGFloat(4), CGFloat(3)]
        : [length * 0.275, length * 0.275, length * 0.17]
    let ruleYs = side == 16
        ? [CGFloat(8.5), CGFloat(6.5)]
        : [length * 0.50, length * 0.415, length * 0.33]
    for (width, y) in zip(ruleWidths, ruleYs) {
        context.move(to: CGPoint(x: ruleLeft, y: y))
        context.addLine(to: CGPoint(x: ruleLeft + width, y: y))
        context.strokePath()
    }

    guard let image = context.makeImage() else {
        throw NSError(domain: "LocalOCRAppIcon", code: 2)
    }
    return image
}

private func writePNG(_ image: CGImage, to destinationURL: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "LocalOCRAppIcon", code: 3)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "LocalOCRAppIcon", code: 4)
    }
}

private let outputDirectory: URL = {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--output" {
        return URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    }
    let scriptURL = URL(fileURLWithPath: #filePath)
    return scriptURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
}()

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)
for rendition in renditions {
    let image = try drawIcon(side: rendition.pixels)
    try writePNG(image, to: outputDirectory.appendingPathComponent(rendition.filename))
}
