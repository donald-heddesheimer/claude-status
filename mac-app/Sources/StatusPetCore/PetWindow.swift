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
            animator.set(mood: mood)
            syncAnimation()
            needsDisplay = true
        }
    }

    var remoteBadge: String? {
        didSet { needsDisplay = true }
    }

    /// Body colour, so each agent's pet is recognisable at a glance.
    var tint: NSColor = PetView.clay {
        didSet { needsDisplay = true }
    }

    /// Agent name under the critter, set only when more than one pet is up.
    var agentLabel: String? {
        didSet { needsDisplay = true }
    }

    /// Optional override artwork. Drop a PNG at ~/.claude-status/pet.png to use
    /// your own pet instead of the drawn one.
    var petImage: NSImage? {
        didSet { needsDisplay = true }
    }

    var menuProvider: (() -> NSMenu)?

    /// Play the finished-a-turn flourish. Restarts it if one is already running.
    func celebrate() {
        animator.celebrate()
        syncAnimation()
        needsDisplay = true
    }

    /// Short text for the thought bubble. Nil hides the bubble entirely.
    var caption: String? {
        didSet { needsDisplay = true }
    }

    /// Fired on a click that wasn't a drag.
    var onClick: (() -> Void)?

    /// Fired when the cursor enters or leaves the pet itself.
    var onHover: ((Bool) -> Void)?

    private let animator = PetAnimator()
    private var pose = PetPose()
    private var timer: Timer?

    /// Half what it was, because the sprite grid is twice as fine. The critter
    /// occupies the same 128pt as before; only the unit it is measured in
    /// changed.
    private let cell: CGFloat = 4

    /// Gap between the critter and its thought bubble, clear of the pulse ring.
    private static let bubbleGap: CGFloat = 26

    /// Where the critter sits at rest, before any animation offset. Centred, so
    /// the window holds matching room above and below for the bubble and the
    /// text can grow out to either side.
    private var spriteFrame: NSRect {
        let width = CGFloat(PetSprite.columns) * cell
        let height = CGFloat(PetSprite.rows) * cell
        return NSRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: ((bounds.height - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    /// The critter's rectangle in window coordinates. The hover panel hugs this
    /// rather than the window, most of which is transparent padding.
    var critterFrame: NSRect { spriteFrame }

    // MARK: - Animation

    /// The pet is never completely still — it breathes and blinks even with
    /// nothing running, because a frozen sprite reads as a hung app. Calm states
    /// pay for that at 12fps rather than 30.
    private func syncAnimation() {
        timer?.invalidate()

        let interval = animator.frameInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pose = self.animator.advance(by: interval)
            self.needsDisplay = true
        }
        // Let it tick while a menu or a drag is spinning its own run loop.
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    /// Advances the animation one frame and draws it into `rep`, with no window
    /// and no run loop.
    ///
    /// This is how `--export-animation` builds the README's GIF: the real
    /// animator driving the real drawing code, rather than a mock-up that would
    /// start lying the first time either changed. The scheduled timer never
    /// fires here because nothing is running the main run loop, so the clock
    /// advances only by the amount asked for — which is also what makes the
    /// output reproducible.
    func drawHeadlessFrame(advancingBy delta: CFTimeInterval, into rep: NSBitmapImageRep) {
        pose = animator.advance(by: delta)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Palette

    /// Claude clay, sampled from the mascot.
    static let clay = NSColor(calibratedRed: 0.843, green: 0.471, blue: 0.353, alpha: 1)
    private static let eyeInk = NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)

    private var bodyColor: NSColor {
        switch mood {
        case .asleep:
            return NSColor(calibratedWhite: 0.44, alpha: 1)
        case .idle, .busy:
            return tint
        case .waiting:
            // Hotter and more saturated than the resting colour, whatever that
            // is for this agent — urgency has to read without knowing the pet.
            guard let hot = tint.usingColorSpace(.deviceRGB) else { return tint }
            return NSColor(deviceHue: hot.hueComponent,
                           saturation: min(1, hot.saturationComponent * 1.35),
                           brightness: min(1, hot.brightnessComponent * 1.05),
                           alpha: 1)
        }
    }

    // MARK: - Drawing

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        syncAnimation()
    }

    required init?(coder: NSCoder) {
        fatalError("PetView is created in code only")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let base = spriteFrame
        let body = NSRect(
            x: base.minX + pose.offset.width,
            y: base.minY + pose.offset.height,
            width: base.width,
            height: base.height
        )

        if let sleep = pose.sleep {
            drawSleep(sleep, over: base)
        }
        if let pulse = pose.pulse {
            // Around the squashed silhouette, not the nominal frame: at the
            // tightest part of the pulse a stretched pet would otherwise poke
            // out through the top of its own ring.
            drawAttentionPulse(around: squashed(body, by: pose.squash), progress: pulse)
        }

        // Squash and stretch applies to the critter alone. The ring, the badge
        // and the bubble are not made of the same rubber.
        withSquash(pose.squash, footedAt: body) {
            if let image = petImage {
                image.draw(in: body, from: .zero, operation: .sourceOver, fraction: pose.alpha)
            } else {
                drawCritter(origin: body.origin, alpha: pose.alpha,
                            legs: pose.legs, eyesClosed: pose.eyesClosed,
                            delighted: pose.celebration != nil)
            }
        }

        // After the critter, not before: sparks thrown from the top of its head
        // that the head then draws over are just an expensive way to draw
        // nothing. They ride the bobbing body rather than the resting frame,
        // since they are meant to look thrown by it.
        if let celebration = pose.celebration {
            drawCelebration(celebration, from: body)
        }

        if let badge = remoteBadge {
            drawRemoteBadge(badge, origin: body.origin, spriteWidth: base.width)
        }

        if let agentLabel {
            drawAgentLabel(agentLabel, under: base)
        }

        // Anchored to where the pet *rests*, not where the animation has it this
        // frame. A bubble that bobs with the walk cycle — and vibrates along
        // with the waiting jitter — reads as broken, and text redrawn on
        // fractional offsets shimmers on top of it.
        if let caption {
            drawThoughtBubble(caption, over: base)
        }
    }

    /// A thought bubble naming what the pet is actually doing — the tool in
    /// flight, or why it stopped.
    ///
    /// Overhead by default, which is where a thought belongs; it drops below the
    /// pet only when there isn't screen room above, so a pet parked under the
    /// menu bar doesn't think off the top of the display.
    private func drawThoughtBubble(_ text: String, over sprite: NSRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let padX: CGFloat = 7
        let padY: CGFloat = 3

        // Everything is measured against the part of the window that's actually
        // on screen. Drag the pet half off the edge and the window keeps its
        // full width, so clamping to `bounds` would happily put the caption
        // where no display can show it.
        let limits = visibleBounds

        // Keep long phrases from pushing the bubble past that edge.
        var label = text
        let maxTextWidth = max(60, limits.width - padX * 2 - 12)
        while (label as NSString).size(withAttributes: attributes).width > maxTextWidth,
              label.count > 4 {
            label = String(label.dropLast())
        }
        if label != text { label += "…" }

        let textSize = (label as NSString).size(withAttributes: attributes)
        // Whole pixels: the text sits at a fixed offset inside the bubble, so a
        // fractional origin blurs every glyph and softens the rounded corners.
        let height = (textSize.height + padY * 2).rounded()
        let width = (textSize.width + padX * 2).rounded()
        let above = roomAbove(for: height)

        // Centred on the pet, then nudged back inside the visible area — a short
        // caption sits over its head, a long one spreads out to both sides.
        var x = (sprite.midX - width / 2).rounded()
        let lowerX = limits.minX + 6
        let upperX = limits.maxX - width - 6
        x = upperX >= lowerX ? min(max(x, lowerX), upperX) : lowerX

        let bubble = NSRect(
            x: x,
            y: (above ? sprite.maxY + Self.bubbleGap
                      : sprite.minY - Self.bubbleGap - height).rounded(),
            width: width,
            height: height
        )

        let ink = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.94)
        ink.setFill()

        // Two puffs trailing back toward the pet, so it reads as a thought
        // rather than speech.
        let puffs: [(y: CGFloat, size: CGFloat)] = above
            ? [(sprite.maxY + 2, 4), (sprite.maxY + 10, 8)]
            : [(sprite.minY - 6, 4), (sprite.minY - 18, 8)]
        for puff in puffs {
            NSBezierPath(ovalIn: NSRect(
                x: (sprite.midX - puff.size / 2).rounded(), y: puff.y,
                width: puff.size, height: puff.size)).fill()
        }

        NSBezierPath(roundedRect: bubble, xRadius: 7, yRadius: 7).fill()

        (label as NSString).draw(
            at: NSPoint(x: bubble.minX + padX, y: bubble.minY + padY),
            withAttributes: attributes
        )
    }

    /// Whether an overhead bubble of this height still lands on screen. The
    /// window itself always has the room; the display is what runs out.
    private func roomAbove(for height: CGFloat) -> Bool {
        guard window?.screen != nil else { return true }
        return spriteFrame.maxY + Self.bubbleGap + height <= visibleBounds.maxY
    }

    /// The slice of this view that a display can actually show, in view
    /// coordinates. Equal to `bounds` in the normal case, and smaller once the
    /// pet is dragged past a screen edge.
    private var visibleBounds: NSRect {
        guard let window, let screen = window.screen else { return bounds }
        let visible = screen.visibleFrame
        let local = NSRect(
            x: visible.minX - window.frame.minX,
            y: visible.minY - window.frame.minY,
            width: visible.width,
            height: visible.height
        )
        let clipped = bounds.intersection(local)
        // A pet dragged almost entirely off screen leaves nothing to lay out
        // against; fall back to the window rather than to a degenerate rect.
        return clipped.width < 40 || clipped.height < 40 ? bounds : clipped
    }

    /// The rect a squashed critter actually occupies. Feet stay put; width and
    /// height trade off so the silhouette keeps its area.
    private func squashed(_ frame: NSRect, by squash: CGFloat) -> NSRect {
        let width = frame.width * squash
        let height = frame.height / squash
        return NSRect(x: frame.midX - width / 2, y: frame.minY,
                      width: width, height: height)
    }

    /// Scales the critter about its feet, so a squash plants it into the ground
    /// and a stretch pulls it upward — the anchor is what sells the weight.
    private func withSquash(_ squash: CGFloat, footedAt frame: NSRect, _ draw: () -> Void) {
        guard abs(squash - 1) > 0.001 else { return draw() }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: frame.midX, yBy: frame.minY)
        transform.scaleX(by: squash, yBy: 1 / squash)
        transform.translateX(by: -frame.midX, yBy: -frame.minY)
        transform.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCritter(origin: NSPoint, alpha: CGFloat,
                             legs: PetSprite.Legs, eyesClosed: Bool,
                             delighted: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        bodyColor.withAlphaComponent(alpha).setFill()

        let body = PetSprite.cells(of: PetSprite.torso)
            + PetSprite.cells(of: legs.map, rowOffset: PetSprite.torso.count)

        // One path for the whole body so the drop shadow wraps the silhouette
        // instead of every individual pixel.
        let path = NSBezierPath()
        for pixel in body {
            path.appendRect(rect(col: pixel.col, row: pixel.row, origin: origin))
        }
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        Self.eyeInk.withAlphaComponent(alpha).setFill()
        // Delight outranks the blink. A celebration interrupted by a blink reads
        // as the pet losing its train of thought.
        let expression: [(col: Int, row: Int)]
        if delighted {
            expression = PetSprite.happyEyes
        } else {
            expression = eyesClosed ? PetSprite.closedEyes : PetSprite.eyes(for: mood)
        }
        for pixel in expression {
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

    /// Which agent this pet speaks for. Anchored to the resting frame like the
    /// bubble, so it doesn't ride the walk cycle.
    private func drawAgentLabel(_ text: String, under sprite: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            .kern: 0.6
        ]
        let label = text.uppercased() as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: (sprite.midX - size.width / 2).rounded(),
                        y: (sprite.minY - 16).rounded()),
            withAttributes: attributes
        )
    }

    /// Three glyphs drifting up and off, so a sleeping pet still has a pulse.
    /// Staggered thirds of one loop, which costs one timer instead of three.
    private func drawSleep(_ progress: CGFloat, over sprite: NSRect) {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)

        for index in 0..<3 {
            let local = (progress + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            // Fade in over the first fifth, then out across the rest.
            let fade = local < 0.2 ? local / 0.2 : (1 - local) / 0.8
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: font.pointSize * (0.75 + local * 0.5),
                                         weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(fade * 0.55)
            ]
            let glyph = "z" as NSString
            glyph.draw(
                at: NSPoint(
                    x: (sprite.maxX - 12 + local * 14).rounded(),
                    y: (sprite.maxY - 4 + local * 26).rounded()
                ),
                withAttributes: attributes
            )
        }
    }

    /// Sparks thrown off a finished turn.
    ///
    /// Drawn rather than set in text, unlike the sleep `z`: an emoji would
    /// inherit whatever the system font feels like today, and a coloured glyph
    /// would ignore the pet's tint. These are four small diamonds that arc out
    /// and fade, in the body colour, so a retinted pet keeps its own confetti.
    private func drawCelebration(_ progress: CGFloat, from sprite: NSRect) {
        // Fade in fast, out slowly, and stop before the hops do so the last
        // half-second is just the pet settling.
        let life = min(1, progress / 0.75)
        guard life < 1 else { return }
        let fade = life < 0.15 ? life / 0.15 : (1 - life) / 0.85

        // Two per side, at different angles and speeds, so it doesn't read as a
        // mechanical burst. All angles point upward and outward, so a spark is
        // clear of the body from its first frame.
        let sparks: [(angle: CGFloat, speed: CGFloat, size: CGFloat)] = [
            (angle: 0.55, speed: 40, size: 5),
            (angle: 1.15, speed: 30, size: 3.5),
            (angle: 1.99, speed: 37, size: 4.5),
            (angle: 2.59, speed: 28, size: 3)
        ]

        // The crown of the head, so nothing has to travel through the critter.
        let centre = NSPoint(x: sprite.midX, y: sprite.maxY - 2)

        for spark in sparks {
            let travel = spark.speed * life
            let point = NSPoint(x: centre.x + cos(spark.angle) * travel,
                                y: centre.y + sin(spark.angle) * travel)
            let half = spark.size * (1 - life * 0.4)

            // A diamond: four points around the centre. Cheaper than a star and
            // legible at five pixels, which a star is not.
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: point.x, y: point.y + half))
            diamond.line(to: NSPoint(x: point.x + half, y: point.y))
            diamond.line(to: NSPoint(x: point.x, y: point.y - half))
            diamond.line(to: NSPoint(x: point.x - half, y: point.y))
            diamond.close()

            bodyColor.withAlphaComponent(fade * 0.9).setFill()
            diamond.fill()
        }
    }

    /// Expanding ring so a blocked session catches your eye from across the room.
    private func drawAttentionPulse(around frame: NSRect, progress cycle: CGFloat) {
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

    /// Hover is tracked over the critter, not the whole window. Most of the
    /// panel is transparent padding for the bubble and the pulse, and a stats
    /// card that appeared from empty space would feel broken.
    private var petRect: NSRect {
        spriteFrame.insetBy(dx: -8, dy: -8)
    }

    /// Only the critter is live. The rest of the window is transparent space
    /// held open for the bubble, and a click there should reach whatever is
    /// behind the pet rather than being swallowed by an invisible target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return petRect.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // .activeAlways: the pet is an accessory app and is never the key
        // window, so anything less never fires.
        addTrackingArea(NSTrackingArea(
            rect: petRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

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
