import AppKit

/// Renders the README's picture of several sessions at once.
///
/// Same rule as the icon, the state strip and the GIF: the picture is drawn by
/// the code it documents, so it cannot quietly start describing a pet that no
/// longer exists. Here that includes the palette itself — the bubbles and the
/// panel's chips both come from `SessionPalette`, so a colour changed there
/// changes the documentation on the next run and nowhere else.
///
/// Regenerate with `claude-status --export-sessions docs/sessions.png`.
public enum SessionsExporter {
    private static let scale = 2
    /// Narrower than the real window and taller: the bubble needs the headroom,
    /// and the width the window reserves is room for a caption to grow sideways
    /// into, which at three across is just three columns of empty grey.
    private static let petSize = NSSize(width: 270, height: 200)
    private static let gap: CGFloat = 14

    /// The pet is drawn centred in a window that reserves as much room below it
    /// as above, and only the top half is ever used — the bubble goes there.
    /// Trimmed off the bottom rather than by moving the critter, which would
    /// mean drawing it somewhere it is never actually drawn.
    private static let petFooter: CGFloat = 42

    /// Mid grey rather than the GIF's near-black.
    ///
    /// The first session's bubble *is* near-black — that is the whole point of
    /// slot zero — so a dark backdrop would hide the one bubble the reader most
    /// needs to see. Mid grey separates every colour in the palette and reads on
    /// a light and a dark README alike.
    private static let backdrop = NSColor(calibratedRed: 0.33, green: 0.34, blue: 0.37, alpha: 1)

    private struct Pet {
        let mood: PetMood
        let caption: String
        let slot: Int
        let badge: String?
    }

    private static let pets: [Pet] = [
        Pet(mood: .busy, caption: "editing PetWindow.swift", slot: 0, badge: nil),
        Pet(mood: .busy, caption: "reading README.md", slot: 1, badge: nil),
        Pet(mood: .waiting, caption: "allow Bash?", slot: 2, badge: "D")
    ]

    /// The panel as it appears beside the pet, with a chip per session. Written
    /// out rather than taken from a live `SessionStore` so the picture is the
    /// same every time it is generated — ages and event counts would not be.
    private static var report: StatsReport {
        StatsReport(
            headline: "3 sessions · 1 needs you",
            rows: [
                SessionRow(place: "devbox (ssh)", project: "drone-es-rd",
                           detail: "waiting · allow Bash?", age: "4m", isWaiting: true,
                           color: SessionPalette.color(slot: 2)),
                SessionRow(place: "local", project: "claude-status",
                           detail: "working · editing PetWindow.swift", age: "12s",
                           isWaiting: false, color: SessionPalette.color(slot: 0)),
                SessionRow(place: "local", project: "docs-site",
                           detail: "working · reading README.md", age: "1m",
                           isWaiting: false, color: SessionPalette.color(slot: 1))
            ],
            footer: "up 3h 20m · 412 events")
    }

    public static func writeStrip(to path: String) -> Bool {
        let stats = StatsView(frame: .zero)
        let statsSize = stats.apply(report)
        stats.frame = NSRect(origin: .zero, size: statsSize)

        let width = petSize.width * CGFloat(pets.count)
        let height = petSize.height - petFooter + statsSize.height + gap * 2

        guard let canvas = bitmap(NSSize(width: width, height: height)) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        backdrop.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        for (index, pet) in pets.enumerated() {
            let view = PetView(frame: NSRect(origin: .zero, size: petSize))
            view.mood = pet.mood
            view.caption = pet.caption
            view.remoteBadge = pet.badge
            view.bubbleTint = SessionPalette.color(slot: pet.slot)

            guard let rendered = render(petSize, { rep in
                // A quarter second in: past the entrance spring, so the pose is
                // the one the pet actually rests in.
                view.drawHeadlessFrame(advancingBy: 0.25, into: rep)
            }) else { return false }

            draw(rendered, into: canvas,
                 at: NSPoint(x: CGFloat(index) * petSize.width,
                             y: statsSize.height + gap * 2 - petFooter))
        }

        guard let panel = render(statsSize, { rep in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            stats.draw(stats.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }) else { return false }

        draw(panel, into: canvas, at: NSPoint(x: ((width - statsSize.width) / 2).rounded(), y: gap))

        guard let png = canvas.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("sessions: \(error.localizedDescription)\n".utf8))
            return false
        }
        return true
    }

    // MARK: - Offscreen plumbing

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        // Points, not pixels: everything drawn into it then lands at `scale`
        // without a single call site having to know about it.
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
