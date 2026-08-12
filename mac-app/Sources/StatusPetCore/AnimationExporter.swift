import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Renders the README's animation by running the real pet offscreen.
///
/// Same principle as the icon and the state strip: no hand-made artwork, so the
/// documentation cannot drift from the app. Here it matters more than usual —
/// the whole point of the GIF is to show the motion, and motion is exactly what
/// a hand-made mock-up would get subtly wrong.
///
/// Regenerate with `claude-status --export-animation docs/pet.gif`.
public enum AnimationExporter {
    /// 14fps is a compromise. The pet runs at 30 when busy, but every frame is a
    /// full image in a GIF, and a README that takes a moment to load costs more
    /// than the dropped frames do. The motion still reads.
    private static let fps = 14.0
    private static let scale = 2

    /// A backdrop, because the pet's window is transparent and its shadow and
    /// bubble are soft-edged — GIF only has 1-bit transparency, which would
    /// fringe every one of those edges. Dark neutral reads on both GitHub
    /// themes.
    private static let backdrop = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)

    private struct Beat {
        let mood: PetMood
        let caption: String?
        let badge: String?
        let seconds: Double
    }

    /// A plausible minute of work, compressed. Ends where it started so the loop
    /// does not jump.
    private static let storyboard: [Beat] = [
        Beat(mood: .idle, caption: nil, badge: nil, seconds: 1.1),
        Beat(mood: .busy, caption: "reading README.md", badge: nil, seconds: 1.8),
        Beat(mood: .busy, caption: "editing PetWindow.swift", badge: nil, seconds: 1.8),
        Beat(mood: .waiting, caption: "allow Bash?", badge: "D", seconds: 2.6),
        Beat(mood: .busy, caption: "Run the test suite", badge: "D", seconds: 1.8),
        Beat(mood: .idle, caption: nil, badge: nil, seconds: 1.4)
    ]

    public static func writeGIF(to path: String) -> Bool {
        let size = NSSize(width: 320, height: 180)
        let view = PetView(frame: NSRect(origin: .zero, size: size))

        let pixelsWide = Int(size.width) * scale
        let pixelsHigh = Int(size.height) * scale

        let url = URL(fileURLWithPath: path)
        let frameCount = storyboard.reduce(0) { $0 + Int(($1.seconds * fps).rounded()) }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            FileHandle.standardError.write(Data("animation: could not create \(path)\n".utf8))
            return false
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let delta = 1.0 / fps
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delta,
                kCGImagePropertyGIFUnclampedDelayTime: delta
            ]
        ] as CFDictionary

        for beat in storyboard {
            view.mood = beat.mood
            view.caption = beat.caption
            view.remoteBadge = beat.badge

            for _ in 0..<Int((beat.seconds * fps).rounded()) {
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
                rep.size = size

                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                backdrop.setFill()
                NSRect(origin: .zero, size: size).fill()
                NSGraphicsContext.restoreGraphicsState()

                view.drawHeadlessFrame(advancingBy: delta, into: rep)

                guard let image = rep.cgImage else { return false }
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            FileHandle.standardError.write(Data("animation: could not finalise \(path)\n".utf8))
            return false
        }
        return true
    }
}
