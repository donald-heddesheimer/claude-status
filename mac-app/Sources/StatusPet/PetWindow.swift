import AppKit

/// Borderless, transparent, always-on-top panel that never steals focus.
final class PetPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Follow the user across Spaces and sit above full-screen apps, which
        // is the whole point of a pet you can glance at.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Never take keyboard focus away from whatever the user is doing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the critter and animates it per session state.
final class PetView: NSView {
    var mood: PetMood = .asleep {
        didSet {
            guard mood != oldValue else { return }
            syncAnimation()
            needsDisplay = true
        }
    }

    var remoteBadge: String? {
        didSet { needsDisplay = true }
    }

    /// Optional override artwork. Drop a PNG at ~/.claude-status/pet.png to use
    /// your own pet instead of the drawn one.
    var petImage: NSImage? {
        didSet { needsDisplay = true }
    }

    var menuProvider: (() -> NSMenu)?

    /// Short text for the thought bubble. Nil hides the bubble entirely.
    var caption: String? {
        didSet { needsDisplay = true }
    }

    /// Fired on a click that wasn't a drag.
    var onClick: (() -> Void)?

    private var phase: CGFloat = 0
    private var timer: Timer?

    private let cell: CGFloat = 8

    // MARK: - Animation

    /// Only animate when something is happening. Idle and asleep cost no CPU.
    private func syncAnimation() {
        timer?.invalidate()
        timer = nil
        phase = 0

        guard mood == .busy || mood == .waiting else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 1.0 / 30.0
            self.needsDisplay = true
        }
    }

    deinit { timer?.invalidate() }

    // MARK: - Palette

    /// Claude clay, sampled from the mascot.
    private static let clay = NSColor(calibratedRed: 0.843, green: 0.471, blue: 0.353, alpha: 1)
    private static let eyeInk = NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)

    private var bodyColor: NSColor {
        switch mood {
        case .asleep:  return NSColor(calibratedWhite: 0.44, alpha: 1)
        case .idle:    return Self.clay
        case .busy:    return Self.clay
        case .waiting: return NSColor(calibratedRed: 0.93, green: 0.40, blue: 0.26, alpha: 1)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let spriteWidth = CGFloat(PetSprite.columns) * cell
        let spriteHeight = CGFloat(PetSprite.rows) * cell

        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var alpha: CGFloat = 1
        var stepping = false

        switch mood {
        case .asleep:
            alpha = 0.45
        case .idle:
            break
        case .busy:
            // Shuffle the legs and bob, so it reads as busy at a glance.
            offsetY = abs(sin(phase * 5.0)) * 5
            stepping = sin(phase * 10.0) > 0
        case .waiting:
            // Hold position but jitter, so it reads as "blocked", not "working".
            // Stays fully opaque — a translucent pet reads as a rendering bug
            // rather than as urgency.
            offsetX = sin(phase * 22) * 1.5
        }

        // Anchored low in the window so the thought bubble has room above.
        let origin = NSPoint(
            x: (bounds.width - spriteWidth) / 2 + offsetX,
            y: 26 + offsetY
        )

        if mood == .waiting {
            drawAttentionPulse(around: NSRect(
                x: origin.x, y: origin.y, width: spriteWidth, height: spriteHeight
            ))
        }

        if let image = petImage {
            image.draw(
                in: NSRect(x: origin.x, y: origin.y, width: spriteWidth, height: spriteHeight),
                from: .zero, operation: .sourceOver, fraction: alpha
            )
        } else {
            drawCritter(origin: origin, alpha: alpha, stepping: stepping)
        }

        if let badge = remoteBadge {
            drawRemoteBadge(badge, origin: origin, spriteWidth: spriteWidth)
        }

        if let caption {
            drawThoughtBubble(caption, above: NSRect(
                x: origin.x, y: origin.y, width: spriteWidth, height: spriteHeight
            ))
        }
    }

    /// A thought bubble above the pet naming what it's actually doing —
    /// the tool in flight, or why it stopped.
    private func drawThoughtBubble(_ text: String, above sprite: NSRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        // Keep long tool names from pushing the bubble past the window edge.
        var label = text
        let maxTextWidth = bounds.width - 22
        while (label as NSString).size(withAttributes: attributes).width > maxTextWidth,
              label.count > 4 {
            label = String(label.dropLast())
        }
        if label != text { label += "…" }

        let textSize = (label as NSString).size(withAttributes: attributes)
        let padX: CGFloat = 7
        let padY: CGFloat = 3

        let bubble = NSRect(
            x: (bounds.width - (textSize.width + padX * 2)) / 2,
            y: sprite.maxY + 15,
            width: textSize.width + padX * 2,
            height: textSize.height + padY * 2
        )

        let ink = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.94)
        ink.setFill()

        // Two trailing puffs, so it reads as a thought rather than speech.
        NSBezierPath(ovalIn: NSRect(x: sprite.midX - 1, y: sprite.maxY + 3, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: sprite.midX + 2, y: sprite.maxY + 8, width: 6, height: 6)).fill()

        NSBezierPath(roundedRect: bubble, xRadius: 7, yRadius: 7).fill()

        (label as NSString).draw(
            at: NSPoint(x: bubble.minX + padX, y: bubble.minY + padY),
            withAttributes: attributes
        )
    }

    private func drawCritter(origin: NSPoint, alpha: CGFloat, stepping: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        bodyColor.withAlphaComponent(alpha).setFill()

        let legs = stepping ? PetSprite.legsStepping : PetSprite.legsPlanted
        let body = PetSprite.cells(of: PetSprite.torso)
            + PetSprite.cells(of: legs, rowOffset: PetSprite.torso.count)

        // One path for the whole body so the drop shadow wraps the silhouette
        // instead of every individual pixel.
        let path = NSBezierPath()
        for pixel in body {
            path.appendRect(rect(col: pixel.col, row: pixel.row, origin: origin))
        }
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        Self.eyeInk.withAlphaComponent(alpha).setFill()
        for pixel in PetSprite.eyes(for: mood) {
            rect(col: pixel.col, row: pixel.row, origin: origin).fill()
        }
    }

    /// Grid cell to view rect. The map runs top-down; AppKit runs bottom-up.
    private func rect(col: Int, row: Int, origin: NSPoint) -> NSRect {
        NSRect(
            x: origin.x + CGFloat(col) * cell,
            y: origin.y + CGFloat(PetSprite.rows - 1 - row) * cell,
            width: cell,
            height: cell
        )
    }

    /// Expanding ring so a blocked session catches your eye from across the room.
    private func drawAttentionPulse(around frame: NSRect) {
        let cycle = phase.truncatingRemainder(dividingBy: 1.5) / 1.5
        let spread = 4 + cycle * 18
        let alpha = (1 - cycle) * 0.75

        let ring = NSBezierPath(
            roundedRect: frame.insetBy(dx: -spread, dy: -spread),
            xRadius: 14, yRadius: 14
        )
        ring.lineWidth = 3.0
        bodyColor.withAlphaComponent(alpha).setStroke()
        ring.stroke()
    }

    /// Small badge marking that a session is running on a remote host.
    private func drawRemoteBadge(_ letter: String, origin: NSPoint, spriteWidth: CGFloat) {
        let diameter: CGFloat = 22
        let rect = NSRect(
            x: origin.x + spriteWidth - diameter + 4,
            y: origin.y - 6,
            width: diameter,
            height: diameter
        )

        NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 0.96).setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.white.withAlphaComponent(0.80).setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()

        let text = letter as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        // performDrag runs its own event loop and returns on mouse-up, so
        // comparing the origin across it tells us whether this was a drag or
        // just a click — without needing our own tracking state.
        let before = window?.frame.origin ?? .zero
        window?.performDrag(with: event)
        let after = window?.frame.origin ?? .zero

        let travelled = hypot(after.x - before.x, after.y - before.y)
        if travelled < 3 {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
