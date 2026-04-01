import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClawdBarLib
import ClawdBarCore

// Generate animated GIF previews of each pet state for README
// Usage: swift run GenerateGifs [outputDir]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "assets"

let fm = FileManager.default
try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let frameCounts: [(PetState, Int)] = [
    (.idle, 8), (.thinking, 8), (.working, 6), (.juggling, 8),
    (.error, 8), (.notification, 4), (.happy, 6), (.sleeping, 6),
]

// FPS per state (matching MultiStatusBarController)
let fpsMap: [PetState: Int] = [
    .idle: 4, .thinking: 6, .working: 10, .juggling: 6,
    .error: 8, .notification: 6, .happy: 6, .sleeping: 4,
]

let scale = 8  // 22x22 → 176x176

for (state, count) in frameCounts {
    let fps = fpsMap[state] ?? 6
    let delay = 1.0 / Double(fps)
    let path = "\(outputDir)/\(state.rawValue).gif"
    let url = URL(fileURLWithPath: path)

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, count, nil
    ) else {
        print("Failed to create GIF destination for \(state)")
        continue
    }

    // GIF file properties: loop forever
    let gifProperties: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFLoopCount as String: 0
        ]
    ]
    CGImageDestinationSetProperties(dest, gifProperties as CFDictionary)

    for frame in 0..<count {
        let nsImage = PixelRenderer.render(state: state, frame: frame, totalFrames: count)

        // Scale up with nearest-neighbor for crisp pixels
        let srcSize = nsImage.size
        let dstW = Int(srcSize.width) * scale
        let dstH = Int(srcSize.height) * scale

        let scaled = NSImage(size: NSSize(width: dstW, height: dstH))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        nsImage.draw(
            in: NSRect(x: 0, y: 0, width: dstW, height: dstH),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        scaled.unlockFocus()

        // Convert to CGImage
        guard let cgImage = scaled.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to get CGImage for \(state) frame \(frame)")
            continue
        }

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, frameProperties as CFDictionary)
    }

    if CGImageDestinationFinalize(dest) {
        print("✓ \(path)")
    } else {
        print("✗ Failed to write \(path)")
    }
}

print("Done! Generated \(frameCounts.count) GIFs in \(outputDir)/")
