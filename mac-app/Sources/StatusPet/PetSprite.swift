import AppKit

/// The Claude Code critter, as a pixel grid.
///
/// Drawn from a cell map rather than shipped as artwork: it stays crisp at any
/// size, costs nothing to install, and lets the legs and eyes animate
/// independently of the body.
enum PetSprite {
    static let columns = 16
    static let rows = 10

    /// Body and arms. Rows run top to bottom.
    static let torso: [String] = [
        "..############..",
        "..############..",
        "..############..",
        "..############..",
        "################",
        "################",
        "..############..",
        "..############.."
    ]

    /// Standing still — all four legs down.
    static let legsPlanted: [String] = [
        "...#.#....#.#...",
        "...#.#....#.#..."
    ]

    /// Mid-stride — the outer legs lift, which reads as a shuffle when
    /// alternated with `legsPlanted`.
    static let legsStepping: [String] = [
        "...#.#....#.#...",
        ".....#......#..."
    ]

    /// Eye cells as (column, row) pairs, so expression is independent of pose.
    static func eyes(for mood: PetMood) -> [(col: Int, row: Int)] {
        switch mood {
        case .asleep:
            // Closed: flat lids.
            return [(4, 3), (5, 3), (10, 3), (11, 3)]
        case .busy:
            // Squinting in concentration. A literal >  < scatters into loose
            // blocks at this cell size, so the squint is a shortened bar.
            return [(4, 2), (11, 2)]
        case .idle, .waiting:
            // Wide open.
            return [(4, 2), (4, 3), (11, 2), (11, 3)]
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
