import AppKit

/// The Claude Code critter, as a pixel grid.
///
/// Drawn from a cell map rather than shipped as artwork: it stays crisp at any
/// size, costs nothing to install, and lets the legs and eyes animate
/// independently of the body.
///
/// The grid is twice as fine as anything drawn on it — every feature here is an
/// even number of cells across, so none of them needs the resolution. It buys
/// one thing: a body width that centres on a half-step. At 16 columns only even
/// widths centre, which put the nearest alternatives to a 12-wide body at 10
/// (too lean) and 14 (wider still). 11 sits where it should, and costs nothing
/// but a denominator.
enum PetSprite {
    static let columns = 32
    static let rows = 20

    /// Body and arms, rows top to bottom. The body is 22 cells (11 at the old
    /// scale); the arm bar runs the full width, which is what makes the arms
    /// read as sticking out rather than as a bulge in the silhouette.
    static let torso: [String] = [
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        "################################",
        "################################",
        "################################",
        "################################",
        ".....######################.....",
        ".....######################.....",
        ".....######################.....",
        ".....######################....."
    ]

    /// Standing still — all four legs down.
    static let legsPlanted: [String] = [
        ".......##..##......##..##.......",
        ".......##..##......##..##.......",
        ".......##..##......##..##.......",
        ".......##..##......##..##......."
    ]

    /// Mid-stride — the outer legs lift, which reads as a shuffle when
    /// alternated with `legsPlanted`.
    static let legsStepping: [String] = [
        ".......##..##......##..##.......",
        ".......##..##......##..##.......",
        "...........##......##...........",
        "...........##......##..........."
    ]

    /// One foot up. Alternated slowly with `legsPlanted` it reads as an
    /// impatient tap rather than as walking.
    static let legsTapping: [String] = [
        ".......##..##......##..##.......",
        ".......##..##......##..##.......",
        ".......##..##......##...........",
        ".......##..##......##..........."
    ]

    /// Which leg map a pose wants.
    enum Legs {
        case planted, stepping, tapping

        var map: [String] {
            switch self {
            case .planted:  return legsPlanted
            case .stepping: return legsStepping
            case .tapping:  return legsTapping
            }
        }
    }

    /// A rectangular run of cells. Listing eyes one tuple at a time was fine
    /// when an eye was one cell; at this resolution it is four, and the list
    /// stopped saying anything the ranges don't.
    private static func block(cols: ClosedRange<Int>,
                              rows: ClosedRange<Int>) -> [(col: Int, row: Int)] {
        rows.flatMap { row in cols.map { (col: $0, row: row) } }
    }

    /// Lids down. The sleep expression, and every blink in the waking ones.
    /// Wider than the open eye and only half as tall: a closed eye is a lash
    /// line, not a shrunken pupil.
    static let closedEyes: [(col: Int, row: Int)] =
        block(cols: 9...12, rows: 6...7) + block(cols: 19...22, rows: 6...7)

    /// Delighted — an upturned arc per eye, the classic `^ ^`.
    ///
    /// Wider than the open eye and drawn as a curve rather than a block, because
    /// at this size a "happy" expression has to come from shape: there is no
    /// room for a mouth, and a merely smaller eye reads as a squint, which is
    /// already what concentration looks like.
    static let happyEyes: [(col: Int, row: Int)] = [
        (8, 6), (9, 5), (10, 5), (11, 6),
        (20, 6), (21, 5), (22, 5), (23, 6)
    ]

    /// Eye cells as (column, row) pairs, so expression is independent of pose.
    static func eyes(for mood: PetMood) -> [(col: Int, row: Int)] {
        switch mood {
        case .asleep:
            return closedEyes
        case .busy:
            // Squinting in concentration. A literal >  < scatters into loose
            // blocks at this cell size, so the squint is a shortened bar.
            return block(cols: 9...10, rows: 4...5) + block(cols: 21...22, rows: 4...5)
        case .idle, .waiting:
            // Wide open.
            return block(cols: 9...10, rows: 4...7) + block(cols: 21...22, rows: 4...7)
        }
    }

    /// Filled cells of a row map, as (column, row) pairs offset by `rowOffset`.
    static func cells(of map: [String], rowOffset: Int = 0) -> [(col: Int, row: Int)] {
        var result: [(col: Int, row: Int)] = []
        for (rowIndex, line) in map.enumerated() {
            for (colIndex, character) in line.enumerated() where character == "#" {
                result.append((col: colIndex, row: rowIndex + rowOffset))
            }
        }
        return result
    }
}
