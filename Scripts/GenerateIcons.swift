#!/usr/bin/env swift
// Generates app icon and menu bar icon PNGs from pure Core Graphics geometry.
// Run: swift Scripts/GenerateIcons.swift (from repo root)
// Outputs PNG files into Sources/App/Assets.xcassets subdirectories.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Drawing

// swiftlint:disable identifier_name
func drawAppIcon(size: Int) -> CGImage? {
    let S = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Squircle background: rx = 229/1024 * S
    let r = 229.0 / 1024.0 * S
    let squircle = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
        cornerWidth: r, cornerHeight: r, transform: nil
    )
    ctx.setFillColor(CGColor(srgbRed: 0x0F / 255.0, green: 0x6E / 255.0, blue: 0x56 / 255.0, alpha: 1.0))
    ctx.addPath(squircle)
    ctx.fillPath()

    // Ring: r = 280/1024 * S, stroke = 44/1024 * S, white
    let ringR = 280.0 / 1024.0 * S
    let strokeW = 44.0 / 1024.0 * S
    ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.setLineWidth(strokeW)
    ctx.addEllipse(in: CGRect(
        x: S / 2 - ringR, y: S / 2 - ringR,
        width: ringR * 2, height: ringR * 2
    ))
    ctx.strokePath()

    // Dot: r = 68/1024 * S, fill white
    let dotR = 68.0 / 1024.0 * S
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.addEllipse(in: CGRect(
        x: S / 2 - dotR, y: S / 2 - dotR,
        width: dotR * 2, height: dotR * 2
    ))
    ctx.fillPath()

    return ctx.makeImage()
}

func drawMenuBarIcon(size: Int) -> CGImage? {
    let S = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Transparent background — leave CGContext zeroed (all alpha=0). ✓

    // Ring: r=7.5/22 * S, strokeWidth=1.4/22 * S, black
    let ringR = 7.5 / 22.0 * S
    let strokeW = max(1.0, 1.4 / 22.0 * S)
    ctx.setStrokeColor(CGColor(gray: 0.0, alpha: 1.0))
    ctx.setLineWidth(strokeW)
    ctx.addEllipse(in: CGRect(
        x: S / 2 - ringR, y: S / 2 - ringR,
        width: ringR * 2, height: ringR * 2
    ))
    ctx.strokePath()

    // Dot: r=2/22 * S, fill black
    let dotR = 2.0 / 22.0 * S
    ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
    ctx.addEllipse(in: CGRect(
        x: S / 2 - dotR, y: S / 2 - dotR,
        width: dotR * 2, height: dotR * 2
    ))
    ctx.fillPath()

    return ctx.makeImage()
}
// swiftlint:enable identifier_name

// MARK: - Save

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("ERROR: Could not create destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        print("ERROR: Failed to write \(path)")
        return
    }
    print("Wrote \(path)")
}

// MARK: - Main

let repoRoot = FileManager.default.currentDirectoryPath
let appIconDir = "\(repoRoot)/Sources/App/Assets.xcassets/AppIcon.appiconset"
let menuBarDir = "\(repoRoot)/Sources/App/Assets.xcassets/MenuBarIcon.imageset"

try? FileManager.default.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: menuBarDir, withIntermediateDirectories: true)

// App icon sizes
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let image = drawAppIcon(size: size) else {
        print("ERROR: drawAppIcon failed for size \(size)")
        continue
    }
    savePNG(image, to: "\(appIconDir)/app-icon-\(size).png")
}

// Menu bar icon sizes: @1x=22, @2x=44, @3x=66
for size in [22, 44, 66] {
    guard let image = drawMenuBarIcon(size: size) else {
        print("ERROR: drawMenuBarIcon failed for size \(size)")
        continue
    }
    savePNG(image, to: "\(menuBarDir)/menubar-\(size).png")
}

print("Done.")
