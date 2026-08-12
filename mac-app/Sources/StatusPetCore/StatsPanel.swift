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

    /// Measures the report and stores it. Returns the size the panel needs.
    func apply(_ report: StatsReport) -> NSSize {
        self.report = report

        var widest: CGFloat = width(report.headline, Self.headlineFont)
        widest = max(widest, width(report.footer, Self.footerFont))
        for row in report.rows {
            widest = max(widest, width(primaryLine(row), Self.rowFont))
            widest = max(widest, width("\(row.detail) · \(row.age)", Self.detailFont))
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

        for row in report.rows {
            y -= lineHeight(Self.rowFont)
            draw(primaryLine(row), at: NSPoint(x: padding, y: y),
                 font: Self.rowFont,
                 color: row.isWaiting ? Self.waitingTint : .white,
                 maxWidth: contentWidth)

            y -= 2 + lineHeight(Self.detailFont)
            draw("\(row.detail) · \(row.age)", at: NSPoint(x: padding, y: y),
                 font: Self.detailFont,
                 color: NSColor(calibratedWhite: 1, alpha: 0.62),
                 maxWidth: contentWidth)

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
