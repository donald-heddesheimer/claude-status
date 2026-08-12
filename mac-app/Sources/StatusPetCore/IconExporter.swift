import AppKit

/// Renders the app icon from the same pixel map the pet is drawn from.
///
/// The alternative is committing a binary `.icns` that drifts from the sprite
/// and that nobody can regenerate. This way `scripts/build-app.sh` produces the
/// icon at build time, and changing the critter changes the icon.
public enum IconExporter {
    /// The sizes `iconutil` expects in an `.iconset`.
    private static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024)
    ]

    /// Writes a complete `.iconset` directory. Returns false on any failure, so
    /// the build script can fail loudly rather than ship an iconless app.
    public static func writeIconSet(to directory: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("icon: \(error.localizedDescription)\n".utf8))
            return false
        }

        for variant in variants {
            guard let png = render(pixels: variant.pixels) else { return false }
            let path = (directory as NSString).appendingPathComponent("\(variant.name).png")
            guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                FileHandle.standardError.write(Data("icon: could not write \(path)\n".utf8))
                return false
            }
        }
        return true
    }

    private static func render(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let canvas = CGFloat(pixels)
        // Apple's icon grid leaves the outer margin empty; a full-bleed square
        // reads as oversized next to every other icon in the Dock.
        let inset = (canvas * 0.09).rounded()
        let plate = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
        let radius = plate.width * 0.2237

        let plateShape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
        // A flat fill looks dead at 512px; the gradient is subtle enough to
        // vanish at 16px, where it would only muddy the shape.
        let gradient = NSGradient(
            starting: PetView.clay.blended(withFraction: 0.18, of: .white) ?? PetView.clay,
            ending: PetView.clay.blended(withFraction: 0.22, of: .black) ?? PetView.clay)
        gradient?.draw(in: plateShape, angle: -90)

        drawCritter(in: plate, canvas: canvas)

        return rep.representation(using: .png, properties: [:])
    }

    /// Draws the critter from the sprite map, cell-aligned so it stays crisp.
    private static func drawCritter(in plate: NSRect, canvas: CGFloat) {
        // Legs are part of the silhouette, so the icon uses the resting pose
        // rather than any animation frame.
        let map = PetSprite.cells(of: PetSprite.torso)
            + PetSprite.cells(of: PetSprite.legsPlanted, rowOffset: PetSprite.torso.count)

        // Whole-pixel cells: a fractional cell size makes the sprite shimmer at
        // small sizes, which is exactly where an icon has to be legible.
        //
        // Below 64px a whole cell no longer fits — the grid is 32 across and
        // the plate is not — so take the fractional one rather than clamping to
        // 1px and drawing a critter wider than the plate it sits on. Crispness
        // is not on offer at that size either way; staying inside the icon is.
        let available = plate.width * 0.62
        let exact = available / CGFloat(PetSprite.columns)
        let cell = exact >= 1 ? exact.rounded(.down) : exact
        let spriteWidth = cell * CGFloat(PetSprite.columns)
        let spriteHeight = cell * CGFloat(PetSprite.rows)
        let origin = NSPoint(x: (plate.midX - spriteWidth / 2).rounded(),
                             y: (plate.midY - spriteHeight / 2).rounded())

        NSColor(calibratedWhite: 1, alpha: 0.96).setFill()
        for pixel in map {
            NSRect(x: origin.x + CGFloat(pixel.col) * cell,
                   y: origin.y + CGFloat(PetSprite.rows - 1 - pixel.row) * cell,
                   width: cell, height: cell).fill()
        }

        // Eyes in the plate colour, so they read as holes rather than as marks.
        PetView.clay.blended(withFraction: 0.35, of: .black)?.setFill()
        for pixel in PetSprite.eyes(for: .idle) {
            NSRect(x: origin.x + CGFloat(pixel.col) * cell,
                   y: origin.y + CGFloat(PetSprite.rows - 1 - pixel.row) * cell,
                   width: cell, height: cell).fill()
        }
    }
}
