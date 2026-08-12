import AppKit

/// The panel that appears beside the pet on hover.
///
/// Click-through by design: the pet's hover tracking lives in `PetView`, and a
/// panel that swallowed mouse events would sit under the cursor, fire an exit,
/// hide itself, and flicker forever.
final class StatsPanel: NSPanel {
    private let view = StatsView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-measures for the new content and returns the size it wants.
    @discardableResult
    func update(with report: StatsReport) -> NSSize {
        let size = view.apply(report)
        setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        return size
    }
}

/// Draws the hover panel: a headline, one block per session, and a footer.
final class StatsView: NSView {
    private var report = StatsReport(headline: "", rows: [], footer: "")

    private let padding: CGFloat = 12
    private let maxWidth: CGFloat = 300
    private let minWidth: CGFloat = 190

    private static let headlineFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let rowFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let detailFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    private static let footerFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    private static let ink = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.97)
    private static let hairline = NSColor(calibratedWhite: 1, alpha: 0.13)
    private static let waitingTint = NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.40, alpha: 1)

    /// Chip size and the room it takes out of the text column. This panel is the
    /// legend for the colours on the pet's bubble, so the chip has to be the
    /// same colour as the bubble and sit where you can compare them.
    private static let chip: CGFloat = 8
    private static let chipGutter: CGFloat = 14

    /// Zero unless something is actually colour-coded, so a single session keeps
    /// the panel it always had.
    private var chipInset: CGFloat {
        report.rows.contains { $0.color != nil } ? Self.chipGutter : 0
    }

    /// Measures the report and stores it. Returns the size the panel needs.
    func apply(_ report: StatsReport) -> NSSize {
        self.report = report

        var widest: CGFloat = width(report.headline, Self.headlineFont)
        widest = max(widest, width(report.footer, Self.footerFont))
        for row in report.rows {
            widest = max(widest, width(primaryLine(row), Self.rowFont) + chipInset)
            widest = max(widest, width("\(row.detail) · \(row.age)", Self.detailFont) + chipInset)
        }

        let contentWidth = min(max(widest, minWidth), maxWidth)

        // headline + rule + rows + rule + footer
        var height = padding + lineHeight(Self.headlineFont) + 9
        for _ in report.rows {
            height += lineHeight(Self.rowFont) + 2 + lineHeight(Self.detailFont) + 9
        }
        if report.rows.isEmpty { height += 4 }
        height += lineHeight(Self.footerFont) + padding

        return NSSize(width: contentWidth + padding * 2, height: height)
    }

    private func primaryLine(_ row: SessionRow) -> String {
        row.project.isEmpty ? row.place : "\(row.place) — \(row.project)"
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        Self.ink.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let contentWidth = bounds.width - padding * 2
        // AppKit draws bottom-up; walking down from the top keeps the layout
        // readable in the same order it appears.
        var y = bounds.height - padding

        y -= lineHeight(Self.headlineFont)
        draw(report.headline, at: NSPoint(x: padding, y: y),
             font: Self.headlineFont, color: .white, maxWidth: contentWidth)

        y -= 6
        drawRule(atY: y, width: contentWidth)
        y -= 3

        let inset = chipInset

        for row in report.rows {
            y -= lineHeight(Self.rowFont)
            if let color = row.color {
                drawChip(color, alignedWith: y, font: Self.rowFont)
            }
            draw(primaryLine(row), at: NSPoint(x: padding + inset, y: y),
                 font: Self.rowFont,
                 color: row.isWaiting ? Self.waitingTint : .white,
                 maxWidth: contentWidth - inset)

            y -= 2 + lineHeight(Self.detailFont)
            draw("\(row.detail) · \(row.age)", at: NSPoint(x: padding + inset, y: y),
                 font: Self.detailFont,
                 color: NSColor(calibratedWhite: 1, alpha: 0.62),
                 maxWidth: contentWidth - inset)

            y -= 6
            drawRule(atY: y, width: contentWidth)
            y -= 3
        }

        if report.rows.isEmpty { y -= 4 }

        y -= lineHeight(Self.footerFont)
        draw(report.footer, at: NSPoint(x: padding, y: y),
             font: Self.footerFont,
             color: NSColor(calibratedWhite: 1, alpha: 0.45),
             maxWidth: contentWidth)
    }

    /// A dot in the session's colour, centred on the cap height of the line
    /// beside it rather than on the line box — optically centred beats
    /// arithmetically centred next to text.
    ///
    /// The same dot the right-click menu uses, ringed for the same reason: the
    /// first session's colour is near-black and this panel's background is too,
    /// so without the ring that row would look like it had no colour at all
    /// rather than like it had the darkest one.
    private func drawChip(_ color: NSColor, alignedWith y: CGFloat, font: NSFont) {
        let size = Self.chip
        let rect = NSRect(x: padding,
                          y: (y + font.capHeight / 2 - size / 2).rounded(),
                          width: size, height: size)
        let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        color.withAlphaComponent(1).setFill()
        dot.fill()
        NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }

    private func drawRule(atY y: CGFloat, width: CGFloat) {
        Self.hairline.setFill()
        NSRect(x: padding, y: y, width: width, height: 1).fill()
    }

    private func draw(_ text: String, at point: NSPoint, font: NSFont,
                      color: NSColor, maxWidth: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        var label = text
        while (label as NSString).size(withAttributes: attributes).width > maxWidth,
              label.count > 2 {
            label = String(label.dropLast())
        }
        if label != text { label += "…" }

        (label as NSString).draw(at: point, withAttributes: attributes)
    }
}
