import AppKit

/// Renders a picture of one pet speaking for two agents — the label under the
/// critter and the tinted bubble it gets once a second agent shows up.
///
/// Regenerate with `claude-status --export-agents docs/agents.png`.
public enum AgentsExporter {
    private static let scale = 2
    private static let petSize = NSSize(width: 270, height: 200)
    private static let petFooter: CGFloat = 42
    private static let gap: CGFloat = 14
    private static let backdrop = NSColor(calibratedRed: 0.33, green: 0.34, blue: 0.37, alpha: 1)

    private struct Pet {
        let caption: String
        let label: String?
        let slot: Int
    }

    private static let pets: [Pet] = [
        Pet(caption: "editing PetWindow.swift", label: nil, slot: 0),
        Pet(caption: "fixing bug.rs", label: "Codex", slot: 1)
    ]

    public static func writeStrip(to path: String) -> Bool {
        let width = petSize.width * CGFloat(pets.count)
        let height = petSize.height - petFooter

        guard let canvas = bitmap(NSSize(width: width, height: height)) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        backdrop.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        for (index, pet) in pets.enumerated() {
            let view = PetView(frame: NSRect(origin: .zero, size: petSize))
            view.mood = .busy
            view.caption = pet.caption
            view.agentLabel = pet.label
            view.bubbleTint = SessionPalette.color(slot: pet.slot)

            guard let rendered = render(petSize, { rep in
                view.drawHeadlessFrame(advancingBy: 0.25, into: rep)
            }) else { return false }

            draw(rendered, into: canvas,
                 at: NSPoint(x: CGFloat(index) * petSize.width, y: -petFooter))
        }

        guard let png = canvas.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("agents: \(error.localizedDescription)\n".utf8))
            return false
        }
        return true
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func render(_ size: NSSize, _ body: (NSBitmapImageRep) -> Void) -> NSImage? {
        guard let rep = bitmap(size) else { return nil }
        body(rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func draw(_ image: NSImage, into canvas: NSBitmapImageRep, at point: NSPoint) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        image.draw(at: point, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
