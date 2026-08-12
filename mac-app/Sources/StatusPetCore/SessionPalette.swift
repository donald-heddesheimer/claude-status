import AppKit

/// Colours that tell one session's thought bubble from another's.
///
/// The pet has one bubble and several sessions can be talking, so on a busy
/// afternoon the caption flips between them with nothing to say which is which.
/// A colour per session fixes that, provided it holds still — see
/// `SessionStore.slots` for why the colour is keyed to arrival rather than to
/// anything that moves.
enum SessionPalette {
    /// The bubble ink the pet has always used: near-black with a blue cast.
    ///
    /// It is deliberately slot zero, so the first session — the only session,
    /// most of the time — looks exactly as it did before there was a palette.
    /// Colour is for telling sessions apart, and one session needs no telling.
    static let ink = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.94)

    /// Six fills, all dark enough to carry the bubble's white text at better
    /// than 7:1 contrast, and spread far enough around the wheel to survive the
    /// common colour-vision deficiencies — blue, teal, plum, rust and olive
    /// differ in lightness as well as hue, so none of them relies on hue alone.
    ///
    /// Six is where legibility runs out, not an arbitrary cap: past that the
    /// colours would be too close to name at a glance. A seventh session wraps
    /// around and shares a colour, and the hover panel is the authority when it
    /// does.
    static let colors: [NSColor] = [
        ink,
        NSColor(calibratedRed: 0.20, green: 0.26, blue: 0.55, alpha: 0.94),  // indigo
        NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.36, alpha: 0.94),  // teal
        NSColor(calibratedRed: 0.44, green: 0.17, blue: 0.42, alpha: 0.94),  // plum
        NSColor(calibratedRed: 0.51, green: 0.28, blue: 0.10, alpha: 0.94),  // rust
        NSColor(calibratedRed: 0.28, green: 0.36, blue: 0.16, alpha: 0.94)   // olive
    ]

    static func color(slot: Int) -> NSColor {
        colors[((slot % colors.count) + colors.count) % colors.count]
    }

    /// A dot for the right-click menu and the hover panel.
    ///
    /// Ringed rather than plain, because slot zero is nearly black and the menu
    /// is drawn on a light background in one system theme and a dark one in the
    /// other. A mid-grey ring is visible against both, so the first session's
    /// swatch reads as a colour rather than as a hole.
    static func swatch(_ color: NSColor, diameter: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            color.withAlphaComponent(1).setFill()
            circle.fill()
            NSColor(calibratedWhite: 0.5, alpha: 0.85).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }
}

/// One session, as offered to the right-click menu and the Settings picker.
struct SessionChoice {
    let id: String
    let label: String
    /// The session's colour, or nil when there is nothing to tell apart — one
    /// session, or colour coding switched off.
    let color: NSColor?
    let isFollowed: Bool
}
