#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs(
        "Usage: build-icns.swift <source.png> <output.icns>\n",
        stderr
    )
    exit(EXIT_FAILURE)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("Cannot read source icon: \(sourceURL.path)\n", stderr)
    exit(EXIT_FAILURE)
}

let chunks: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

func renderPNG(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        NSGraphicsContext.restoreGraphicsState()
        throw CocoaError(.fileWriteUnknown)
    }
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(
        using: .png,
        properties: [:]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

do {
    var body = Data()
    for chunk in chunks {
        let png = try renderPNG(pixels: chunk.pixels)
        body.append(Data(chunk.type.utf8))
        appendUInt32(UInt32(png.count + 8), to: &body)
        body.append(png)
    }

    var icon = Data("icns".utf8)
    appendUInt32(UInt32(body.count + 8), to: &icon)
    icon.append(body)
    try icon.write(to: outputURL, options: .atomic)
} catch {
    fputs("Cannot build ICNS: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
