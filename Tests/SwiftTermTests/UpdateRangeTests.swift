//
//  UpdateRangeTests.swift
//
//  The iOS view repaints only the rows in the terminal's update range
//  (`getUpdateRange`), so the range is a promise: any visible row whose
//  cells change while it is collected must be inside it, or that row stays
//  stale on screen until something else repaints it. Seeded random output —
//  text of every width, colors, cursor moves, erases, scroll regions,
//  insert/delete, line render modes, the alternate screen, synchronized
//  updates — checked against that promise after every chunk.
//

import Foundation
import Testing

@testable import SwiftTerm

final class UpdateRangeTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// The viewport row the terminal last announced (`scrolled`): where a
    /// view that follows `yDisp` — iOS places its scroll offset there — puts
    /// itself. Each test gets its own instance.
    private var announcedYDisp: Int?
    func scrolled(source: Terminal, yDisp: Int) { announcedYDisp = yDisp }

    /// How many times the terminal said it replaced its buffers (a full
    /// reset): the view's cue to drop what it kept in rows of the old ones.
    private var resets = 0
    func terminalReset(source: Terminal) { resets += 1 }

    /// What a row draws from: every cell (character, width, link, colors and
    /// style), the line's render mode, its images.
    private struct RowSnapshot: Equatable {
        var cells: [Int64] = []
        var attributes: [Attribute] = []
        var renderMode = -1
        var images = 0
    }

    private func visibleRows(_ t: Terminal) -> [RowSnapshot] {
        let buffer = t.displayBuffer
        return (0 ..< t.rows).map { r in
            let index = buffer.yDisp + r
            guard index < buffer.lines.count else { return RowSnapshot() }
            let line = buffer.lines[index]
            var row = RowSnapshot()
            for col in 0 ..< t.cols {
                let cell = line[col]
                row.cells.append(Int64(cell.code) << 24 | Int64(cell.width) << 16 | Int64(cell.payload.code))
                row.attributes.append(cell.attribute)
            }
            switch line.renderMode {
            case .single: row.renderMode = 0
            case .doubleWidth: row.renderMode = 1
            case .doubledTop: row.renderMode = 2
            case .doubledDown: row.renderMode = 3
            }
            row.images = line.images?.count ?? 0
            return row
        }
    }

    /// Feeds `chunks` one at a time; returns the chunks after which a changed
    /// visible row was outside the update range, with the rows.
    private func violations(cols: Int, rows: Int, scrollback: Int, chunks: [String]) -> [String] {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        var found: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let buffer = t.displayBuffer
            let yDisp = buffer.yDisp
            let before = visibleRows(t)
            t.clearUpdateRange()
            announcedYDisp = nil
            t.feed(text: chunk)
            // A viewport that moved (output scrolled it, or ESC [ 3 J trimmed
            // the history above it) is repainted whole by the view — once the
            // view knows: it repaints when its offset moves to the new row,
            // and it moves only when told.
            if t.displayBuffer === buffer && t.displayBuffer.yDisp != yDisp {
                if announcedYDisp != t.displayBuffer.yDisp {
                    found.append("chunk \(i) \(chunk.debugDescription): the viewport moved from row \(yDisp) to \(t.displayBuffer.yDisp), the view was told \(announcedYDisp.map(String.init) ?? "nothing")")
                }
                continue
            }
            let after = visibleRows(t)
            let range = t.getUpdateRange()
            var outside: [Int] = []
            for r in 0 ..< rows where before[r] != after[r] {
                if let range, r >= range.startY, r <= range.endY {
                    continue
                }
                outside.append(r)
            }
            if !outside.isEmpty {
                found.append("chunk \(i) \(chunk.debugDescription): rows \(outside) changed, range \(range.map { "\($0.startY)...\($0.endY)" } ?? "none")")
            }
        }
        return found
    }

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func everyChangedRowIsInTheUpdateRange(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let cols = 30 + rng.below(30)
        let rows = 8 + rng.below(16)
        let chunks = (0 ..< 3000).map { _ in RandomOutput.chunk(&rng, rows: rows, cols: cols) }
        let found = violations(cols: cols, rows: rows, scrollback: 20, chunks: chunks)
        #expect(found.isEmpty, "\(found.count) chunks changed rows outside the update range; first: \(found.prefix(3))")
    }

    /// The shapes the iOS check on the device scripts by hand: a status line
    /// written with the cursor saved, a spinner, typing at a prompt, erasing
    /// and repeating characters in place.
    @Test func statusLineSpinnerAndTyping() {
        let chunks = [
            "user@host ~ $ ",
            "l", "s", " ", "-", "l",
            "\u{1b}7\u{1b}[1;1H\u{1b}[7m status \u{1b}[0m\u{1b}8",
            "\u{1b}[s\u{1b}[3;3H⠋ working\u{1b}[u",
            "\u{1b}[s\u{1b}[3;3H⠙ working\u{1b}[u",
            "\u{8} \u{8}",
            "\r\n",
            "中文🙂",
            "\u{1b}[2;5H\u{1b}[4@",
            "\u{1b}[2;5H\u{1b}[3P",
            "\u{1b}[5;10r\u{1b}[10;1H\n\n\u{1b}[r",
            "\u{1b}#8",
            "\u{1b}[2J",
            // Erase characters (ECH) and repeat (REP) with the cursor already
            // in place: nothing else in the chunk records the row.
            "\u{1b}[1;1Hsome text to erase",
            "\u{1b}[1;3H",
            "\u{1b}[4X",
            "\u{1b}[3;1HZ",
            "\u{1b}[5b",
            "\u{1b}[60b",
        ]
        let found = violations(cols: 40, rows: 12, scrollback: 10, chunks: chunks)
        #expect(found.isEmpty, "\(found)")
    }

    /// Where the viewport is when the saved lines go.
    enum Viewport: CustomStringConvertible {
        case liveBottom, inHistory, atTheTop
        var description: String {
            switch self {
            case .liveBottom: return "at the live bottom"
            case .inHistory: return "reading history"
            case .atTheTop: return "at the top of the history"
            }
        }
    }

    /// `clear` in a shell and `/clear` in Claude Code end with ESC [ 3 J:
    /// erase the saved lines. Every row the viewport shows moves to another
    /// index, so the view has to hear where the viewport went (its scroll
    /// offset and content size follow it) and repaint all of it — from the
    /// live bottom, from a row in the history (which now shows the screen),
    /// and from the very top, where the row number stays but the rows under
    /// it are new.
    @Test(arguments: [Viewport.liveBottom, .inHistory, .atTheTop])
    func erasingSavedLinesMovesTheViewportAndRepaintsIt(from viewport: Viewport) {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5, scrollback: 50))
        for i in 0 ..< 30 {
            t.feed(text: "line \(i)\r\n")
        }
        t.feed(text: "$ clear")
        #expect(t.displayBuffer.lines.count > t.rows, "history above the screen")
        switch viewport {
        case .liveBottom: break
        case .inHistory: t.setViewYDisp(7)
        case .atTheTop: t.setViewYDisp(0)
        }

        t.clearUpdateRange()
        announcedYDisp = nil
        t.feed(text: "\u{1b}[3J")

        #expect(t.displayBuffer.lines.count == t.rows, "the saved lines are gone")
        #expect(t.displayBuffer.yDisp == 0)
        #expect(announcedYDisp == 0, "the view was not told where the viewport went")
        let range = t.getUpdateRange()
        #expect(range.map { $0.startY <= 0 && $0.endY >= t.rows - 1 } == true,
                "the whole screen must repaint, range \(range.map { "\($0.startY)...\($0.endY)" } ?? "none")")
    }

    /// A full reset — RIS, `ESC c`, which `reset` and `tput reset` send —
    /// swaps in a fresh normal buffer: no history, the viewport on its first
    /// row. It is the same move as erasing the saved lines and needs the same
    /// word to the view, from wherever the viewport was: an iOS view still
    /// placed on the old row draws rows that are not there, a blank screen
    /// until something scrolls.
    @Test(arguments: [Viewport.liveBottom, .inHistory, .atTheTop])
    func fullResetMovesTheViewportAndRepaintsIt(from viewport: Viewport) {
        let t = terminalWithHistory(at: viewport)

        t.clearUpdateRange()
        announcedYDisp = nil
        t.feed(text: "\u{1b}c")

        #expect(t.displayBuffer.lines.count == t.rows, "a reset leaves no history")
        #expect(t.displayBuffer.yDisp == 0)
        #expect(announcedYDisp == 0, "the view was not told where the viewport went")
        #expect(resets == 1, "the view was not told the buffers were replaced")
        let range = t.getUpdateRange()
        #expect(range.map { $0.startY <= 0 && $0.endY >= t.rows - 1 } == true,
                "the whole screen must repaint, range \(range.map { "\($0.startY)...\($0.endY)" } ?? "none")")
    }

    /// DECCOLM (`CSI ? 3 h` / `CSI ? 3 l`, 132 and 80 columns) changes the
    /// columns, which rewraps the history and can move the viewport, and
    /// clears the screen: the whole screen repaints and the view hears where
    /// the viewport is. It keeps the history and replaces no buffer (it was
    /// a full reset; ColumnModeTests).
    @Test(arguments: ["\u{1b}[?3h", "\u{1b}[?3l"])
    func columnModeTellsTheViewWhereTheViewportIsAndRepaintsIt(sequence: String) {
        let t = terminalWithHistory(at: .inHistory)

        t.clearUpdateRange()
        announcedYDisp = nil
        t.feed(text: sequence)

        #expect(t.displayBuffer.lines.count > t.rows, "DECCOLM keeps the history")
        #expect(announcedYDisp == t.displayBuffer.yDisp, "the view was not told where the viewport is")
        #expect(resets == 0, "no buffer was replaced")
        let range = t.getUpdateRange()
        #expect(range.map { $0.startY <= 0 && $0.endY >= t.rows - 1 } == true,
                "the whole screen must repaint, range \(range.map { "\($0.startY)...\($0.endY)" } ?? "none")")
    }

    /// Thirty lines of output on a five-row screen, the viewport placed.
    private func terminalWithHistory(at viewport: Viewport) -> Terminal {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5, scrollback: 50))
        for i in 0 ..< 30 {
            t.feed(text: "line \(i)\r\n")
        }
        t.feed(text: "$ reset")
        #expect(t.displayBuffer.lines.count > t.rows, "history above the screen")
        switch viewport {
        case .liveBottom: break
        case .inHistory: t.setViewYDisp(7)
        case .atTheTop: t.setViewYDisp(0)
        }
        return t
    }
}

/// splitmix64.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

/// Terminal output of every kind a screen redraw has to keep up with.
private enum RandomOutput {
    private static let words = [
        "the", "agent", "wrote", "src/main.rs", "ok", "error[E0382]:", "→", "✓", "…",
        "中文", "终端", "智能体", "日本語", "한국어", "🙂", "🚀", "👍🏽", "┌──┐", "│", "█▓▒░",
        "e\u{301}", "naïve", "ที่", "{[()]}", "\t",
    ]

    static func chunk(_ rng: inout SplitMix64, rows: Int, cols: Int) -> String {
        var s = ""
        for _ in 0 ..< 1 + rng.below(8) {
            s += segment(&rng, rows: rows, cols: cols)
        }
        return s
    }

    private static func csi(_ s: String) -> String { "\u{1b}[\(s)" }

    private static func segment(_ rng: inout SplitMix64, rows: Int, cols: Int) -> String {
        switch rng.below(100) {
        case 0 ..< 36:
            return words[rng.below(words.count)] + " "
        case 36 ..< 44:
            switch rng.below(5) {
            case 0: return csi("\(30 + rng.below(8))m")
            case 1: return csi("\(40 + rng.below(8))m")
            case 2: return csi("38;5;\(rng.below(256))m")
            case 3: return csi("48;2;\(rng.below(256));\(rng.below(256));\(rng.below(256))m")
            default: return csi(["0", "1", "2", "3", "4", "7", "9", "4:3"][rng.below(8)] + "m")
            }
        case 44 ..< 52:
            return ["\r\n", "\n", "\r", "\u{8}", "\u{1b}D", "\u{1b}E", "\u{1b}M", "\u{b}", "\u{c}"][rng.below(9)]
        case 52 ..< 60:
            return csi("\(1 + rng.below(rows));\(1 + rng.below(cols))" + ["H", "f"][rng.below(2)])
        case 60 ..< 67:
            return csi("\(1 + rng.below(6))" + ["A", "B", "C", "D", "E", "F", "G", "d", "e", "a", "`", "I", "Z"][rng.below(13)])
        case 67 ..< 74:
            return csi(["K", "1K", "2K", "J", "1J", "\(1 + rng.below(9))X", "?K", "?2J"][rng.below(8)])
        case 74 ..< 81:
            return csi("\(1 + rng.below(4))" + ["@", "P", "L", "M", "S", "T", "b"][rng.below(7)])
        case 81 ..< 85:
            if rng.below(3) == 0 { return csi("r") }
            let top = 1 + rng.below(max(1, rows - 1))
            let bottom = min(rows, top + 1 + rng.below(max(1, rows - top)))
            return csi("\(top);\(bottom)r")
        case 85 ..< 88:
            return ["\u{1b}7", "\u{1b}8", csi("s"), csi("u")][rng.below(4)]
        case 88 ..< 91:
            return csi(["?1049h", "?1049l", "?47h", "?47l", "?1047h", "?1047l", "4h", "4l", "?7l", "?7h", "?6h", "?6l"][rng.below(12)])
        case 91 ..< 93:
            // No OSC 8 links: their payloads live in a process-wide table
            // (TinyAtom) that the parallel test cases would race on. A link
            // cell takes the same printing path as any other.
            return csi("\(1 + rng.below(rows))d") + words[rng.below(words.count)]
        case 93 ..< 95:
            return ["\u{1b}#3", "\u{1b}#4", "\u{1b}#5", "\u{1b}#6", "\u{1b}#8"][rng.below(5)]
        case 95 ..< 97:
            return csi("?2026h") + "sync \(rng.below(100))" + csi("?2026l")
        case 97:
            return csi(["2J", "3J", "?5h", "?5l"][rng.below(4)])
        default:
            return String(repeating: words[rng.below(words.count)], count: 1 + rng.below(20))
        }
    }
}
