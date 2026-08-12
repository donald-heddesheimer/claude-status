import AppKit

/// Renders the README's state strip from the sprite map.
///
/// Same reasoning as `IconExporter`: documentation art that is drawn by hand
/// drifts from the thing it documents, and nobody notices until the picture is
/// describing a pet that no longer exists. Regenerate with
/// `claude-status --export-states docs/states.png`.
///
/// The background is left transparent so the strip reads on GitHub's light and
/// dark themes alike, and the labels are a mid grey for the same reason.
public enum StatesExporter {
    private static let scale: CGFloat = 3
    private static let cell: CGFloat = 4 * scale
    private static let labelHeight: CGFloat = 34
    /// Wide enough to clear the attention ring at its widest.
    private static let gutter: CGFloat = 52

    private struct Panel {
        let mood: PetMood
        let legs: PetSprite.Legs
        let caption: String
        /// Asleep is drawn faded, as it is on screen.
        let alpha: CGFloat
    }

    private static let panels: [Panel] = [
        Panel(mood: .asleep, legs: .planted, caption: "nothing running", alpha: 0.45),
        Panel(mood: .idle, legs: .planted, caption: "idle", alpha: 1),
        Panel(mood: .busy, legs: .stepping, caption: "working", alpha: 1),
        Panel(mood: .waiting, legs: .tapping, caption: "needs you", alpha: 1)
    ]

    public static func writeStrip(to path: String) -> Bool {
        let spriteWidth = cell * CGFloat(PetSprite.columns)
        let spriteHeight = cell * CGFloat(PetSprite.rows)
        // The waiting pet wears a pulse ring, so every panel reserves room for
        // one; otherwise that panel alone would sit at a different scale.
        let panelWidth = spriteWidth + gutter * 2
        let width = panelWidth * CGFloat(panels.count)
        let height = spriteHeight + gutter * 2 + labelHeight

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        for (index, panel) in panels.enumerated() {
            let origin = NSPoint(
                x: CGFloat(index) * panelWidth + gutter,
                y: labelHeight + gutter)
            draw(panel, at: origin, spriteWidth: spriteWidth, spriteHeight: spriteHeight)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("states: \(error.localizedDescription)\n".utf8))
            return false
        }
        return true
    }

    private static func draw(_ panel: Panel, at origin: NSPoint,
                             spriteWidth: CGFloat, spriteHeight: CGFloat) {
        func rect(col: Int, row: Int) -> NSRect {
            NSRect(x: origin.x + CGFloat(col) * cell,
                   y: origin.y + CGFloat(PetSprite.rows - 1 - row) * cell,
                   width: cell, height: cell)
        }

        // The attention ring, drawn first so the critter sits inside it.
        //
        // Geometry copied from PetWindow.drawAttentionPulse: a rounded rect
        // inset outward from the sprite frame, not an ellipse. On screen it
        // expands on a cycle; a still has to pick a moment, so this is roughly
        // mid-pulse, with every dimension scaled like the sprite.
        if panel.mood == .waiting {
            let spread: CGFloat = 12 * scale
            let frame = NSRect(x: origin.x, y: origin.y,
                               width: spriteWidth, height: spriteHeight)
            let ring = NSBezierPath(
                roundedRect: frame.insetBy(dx: -spread, dy: -spread),
                xRadius: 14 * scale, yRadius: 14 * scale)
            ring.lineWidth = 3 * scale
            PetView.clay.withAlphaComponent(0.42).setStroke()
            ring.stroke()
        }

        PetView.clay.withAlphaComponent(panel.alpha).setFill()
        let body = NSBezierPath()
        for pixel in PetSprite.cells(of: PetSprite.torso) {
            body.appendRect(rect(col: pixel.col, row: pixel.row))
        }
        for pixel in PetSprite.cells(of: panel.legs.map, rowOffset: PetSprite.torso.count) {
            body.appendRect(rect(col: pixel.col, row: pixel.row))
        }
        body.fill()

        NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: panel.alpha).setFill()
        for pixel in PetSprite.eyes(for: panel.mood) {
            rect(col: pixel.col, row: pixel.row).fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            // Mid grey: legible against both a white and a dark README.
            .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)
        ]
        let text = panel.caption as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: origin.x + (spriteWidth - size.width) / 2,
                              y: labelHeight / 2 - size.height / 2),
                  withAttributes: attributes)
    }
}
