#!/usr/bin/env swift
//
// Draws Triage.icns. Run: Scripts/make-icon.swift [output.icns]
//
// BRIEF
// -----
// A descending stack: rows of mail narrowing to nothing, brightest at the top and
// dissolving toward the bottom. That is the app's job made visual -- a pile triaged
// down, with the thing worth keeping still solid at the top. Centred rather than
// left-aligned, so it reads as a funnel rather than a list, which is the closest
// existing visual language to "filter this down".
//
// Deliberately NOT a waveform and NOT indigo: Cadence sits next to this in the Dock
// and uses vertical indigo bars. Horizontal teal bars share no silhouette with it, so
// the two are still telling apart at 16pt where colour is most of what you get.
//
// Both width AND opacity fall down the stack. Cadence learned that opacity alone is
// too subtle to read as intent -- it just looks like the artwork faded -- so the two
// devices reinforce each other here.
//
// Why code and not an image file: the icon exists at seven sizes and the artwork is
// SIMPLIFIED at small ones -- five bars at 128pt and up, four at 32-64, three at 16.
// A single PNG downscaled to 16pt turns five sub-pixel bars into grey mush.
//
// Full bleed, no rounded corners of its own, on purpose: macOS 26 masks app icons to
// its own squircle, and an icon carrying transparent corners gets inset into a grey
// plate instead ("icon jail"). Art stays well inside the corner radius so the mask
// cannot clip it.

import AppKit
import Foundation

// MARK: - Design

enum Design {
    /// Diagonal background, light top-left to dark bottom-right. Teal reads as
    /// "cleaned up" without the alarm of green-as-success, and is far enough from
    /// Cadence's indigo to be distinguishable as a Dock smudge.
    static let backgroundTop = NSColor(srgbRed: 0.129, green: 0.702, blue: 0.639, alpha: 1)
    static let backgroundBottom = NSColor(srgbRed: 0.035, green: 0.216, blue: 0.243, alpha: 1)

    /// Bar widths as a fraction of the canvas, widest first.
    ///
    /// Kept far apart deliberately, which is Cadence's hard-won lesson: adjacent
    /// fractions round to the same pixel count at 16pt and the descent collapses into
    /// a block. At 16pt the three-bar set lands on 12 / 8 / 5 px, which stays legible.
    static func widths(barCount: Int) -> [CGFloat] {
        switch barCount {
        case 3: return [0.72, 0.50, 0.30]
        case 4: return [0.72, 0.56, 0.40, 0.26]
        default: return [0.72, 0.60, 0.48, 0.36, 0.24]
        }
    }

    /// Opacity down the stack: solid at the top, dissolving at the bottom.
    static func alphas(barCount: Int) -> [CGFloat] {
        switch barCount {
        case 3: return [1.00, 0.78, 0.52]
        case 4: return [1.00, 0.84, 0.66, 0.48]
        default: return [1.00, 0.86, 0.72, 0.58, 0.44]
        }
    }

    /// Bar thickness and gap as a fraction of the canvas. Fewer bars are drawn thicker
    /// so the mark keeps its visual weight as it simplifies.
    static func geometry(barCount: Int) -> (thickness: CGFloat, gap: CGFloat) {
        switch barCount {
        case 3: return (0.130, 0.120)
        case 4: return (0.105, 0.085)
        default: return (0.088, 0.062)
        }
    }

    /// Below this size the artwork is snapped to whole pixels. At 16pt the gaps come
    /// out under a pixel wide, and a sub-pixel gap does not render as a gap -- it
    /// renders as two bars bleeding into one smear.
    static let pixelSnapCeiling = 64

    /// How many bars survive at a given pixel size.
    static func barCount(forPixelSize pixels: Int) -> Int {
        if pixels < 32 { return 3 }
        if pixels < 128 { return 4 }
        return 5
    }
}

// MARK: - Render

func renderIcon(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate a \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)

    // Background: full bleed, so the system mask has opaque corners to cut.
    NSGradient(starting: Design.backgroundTop, ending: Design.backgroundBottom)?
        .draw(in: canvas, angle: -55)

    // A faint sheen along the top edge. Invisible at 16pt, which is fine -- it is not
    // carrying meaning, it just stops the field reading as flat vinyl at 512pt.
    if pixels >= 128 {
        NSGradient(
            starting: NSColor(white: 1, alpha: 0.12),
            ending: NSColor(white: 1, alpha: 0)
        )?.draw(in: NSRect(x: 0, y: side * 0.55, width: side, height: side * 0.45), angle: -90)
    }

    let count = Design.barCount(forPixelSize: pixels)
    let widths = Design.widths(barCount: count)
    let alphas = Design.alphas(barCount: count)
    let (thicknessFraction, gapFraction) = Design.geometry(barCount: count)

    let snap = pixels <= Design.pixelSnapCeiling
    /// At small sizes every edge lands on a pixel boundary; at large sizes exact
    /// proportions matter more than crisp edges and antialiasing does fine work.
    func quantise(_ value: CGFloat, floor minimum: CGFloat = 1) -> CGFloat {
        snap ? max(minimum, value.rounded()) : value
    }

    let thickness = quantise(side * thicknessFraction)
    let gap = quantise(side * gapFraction, floor: 1)
    let totalHeight = thickness * CGFloat(count) + gap * CGFloat(count - 1)
    // Drawn top-down, so start at the top of the centred block. AppKit's origin is
    // bottom-left, hence subtracting from the top edge.
    var y = quantise((side + totalHeight) / 2 - thickness, floor: 0)

    for (index, widthFraction) in widths.enumerated() {
        let width = quantise(side * widthFraction)
        let rect = NSRect(
            x: quantise((side - width) / 2, floor: 0),
            y: y,
            width: width,
            height: thickness
        )
        NSColor(white: 1, alpha: alphas[index]).setFill()

        // Fully rounded caps. Below about 24px the radius is under a pixel and the bar
        // becomes a plain rectangle, which is the right outcome -- a half-antialiased
        // cap is mush at that size.
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2)
            .fill()

        y -= thickness + gap
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode the \(pixels)px bitmap as PNG")
    }
    return png
}

/// Nearest-neighbour magnification of a small render, for judging small sizes.
///
/// Small-size failures are invisible at 100% and obvious magnified -- that is exactly
/// how Cadence's first two drafts got shipped as a grey smear at 16px.
func magnified(pixels: Int, to target: Int) -> Data {
    let source = NSBitmapImageRep(data: renderIcon(pixels: pixels))!

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: target, pixelsHigh: target,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate the magnified bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    source.draw(in: NSRect(x: 0, y: 0, width: target, height: target))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Iconset

/// (file name, pixel size). Both entries of a size pair are rendered at that size
/// rather than sharing one file, because @2x of 16 is 32 and 32 draws four bars.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1
    ? arguments[1]
    : fm.currentDirectoryPath + "/build/Triage.icns")

let directory = output.deletingLastPathComponent()
try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
let iconset = directory.appendingPathComponent("Triage.iconset")

try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, pixels) in variants {
    try renderIcon(pixels: pixels).write(to: iconset.appendingPathComponent(name))
}

// Previews for looking at the thing without mounting an .icns.
try renderIcon(pixels: 1024).write(to: directory.appendingPathComponent("icon-preview.png"))
try magnified(pixels: 16, to: 256)
    .write(to: directory.appendingPathComponent("icon-preview-16-magnified.png"))
try magnified(pixels: 32, to: 256)
    .write(to: directory.appendingPathComponent("icon-preview-32-magnified.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? fm.removeItem(at: iconset)
print("wrote \(output.path)")
print("previews: icon-preview.png, icon-preview-16-magnified.png, icon-preview-32-magnified.png")
