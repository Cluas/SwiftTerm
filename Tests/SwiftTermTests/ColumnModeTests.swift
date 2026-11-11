//
//  ColumnModeTests.swift
//
//  DECCOLM (CSI ? 3 h, 132 columns; CSI ? 3 l, 80). xterm (charproc.c:
//  srm_DECCOLM and set_column_mode) changes the columns, clears the screen
//  and makes its lines single width, resets the margins and puts the cursor
//  home, and leaves everything else alone. It was a full reset here: the
//  history went, every mode went back to its default, and a program on the
//  alternate screen was put back on the normal one. xterm does it only with
//  mode 40 on (CSI ? 40 h; the c132 resource, false by default), and so
//  does the terminal now.
//

import Testing

@testable import SwiftTerm

final class ColumnModeTests: TerminalDelegate {
    private var responses: [String] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        responses.append(String(decoding: data, as: UTF8.self))
    }

    private var resets = 0
    func terminalReset(source: Terminal) { resets += 1 }

    private var sizeChanges = 0
    func sizeChanged(source: Terminal) { sizeChanges += 1 }

    private let esc = "\u{1b}"

    /// Twenty lines of output and a prompt on a five-row screen, by a
    /// program that allowed DECCOLM (mode 40).
    private func terminalWithHistory(allowingColumnMode: Bool = true) -> Terminal {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 100, rows: 5, scrollback: 50))
        if allowingColumnMode {
            t.feed(text: "\(esc)[?40h")
        }
        for i in 0 ..< 20 {
            t.feed(text: "line \(i)\r\n")
        }
        t.feed(text: "$ prompt")
        return t
    }

    private func text(_ t: Terminal, line: Int) -> String {
        t.buffer.translateBufferLineToString(lineIndex: line, trimRight: true)
    }

    @Test(arguments: [("\u{1b}[?3h", 132), ("\u{1b}[?3l", 80)])
    func columnModeChangesTheColumnsClearsTheScreenAndKeepsTheHistory(sequence: String, columns: Int) {
        let t = terminalWithHistory()
        let saved = t.buffer.yBase
        #expect(saved > 0, "history above the screen")

        t.feed(text: sequence)

        #expect(t.cols == columns)
        #expect(sizeChanges == 1)
        #expect(resets == 0, "DECCOLM is not a full reset")
        #expect(t.buffer.yBase == saved, "the history went")
        for line in 0 ..< saved {
            #expect(text(t, line: line) == "line \(line)")
        }
        for row in 0 ..< t.rows {
            #expect(text(t, line: t.buffer.yBase + row) == "", "screen row \(row) was not cleared")
        }
        #expect(t.buffer.x == 0 && t.buffer.y == 0, "the cursor is not home")
    }

    /// The modes a program set stay set: the keys it reads (application
    /// cursor keys), how a paste reaches it, the mouse it asked for, how
    /// text is written.
    @Test(arguments: ["\u{1b}[?3h", "\u{1b}[?3l"])
    func columnModeKeepsTheModes(sequence: String) {
        let t = terminalWithHistory()
        t.feed(text: "\(esc)[?1h\(esc)[?2004h\(esc)[?1000h\(esc)[?1006h\(esc)[?7l\(esc)[4h")

        t.feed(text: sequence)

        #expect(t.applicationCursor, "application cursor keys were reset")
        #expect(t.bracketedPasteMode, "bracketed paste was reset")
        #expect(t.mouseMode == .vt200, "mouse reporting was reset")
        #expect(!t.wraparound, "autowrap was reset")
        #expect(t.insertMode, "insert mode was reset")
    }

    /// A program on the alternate screen stays there; the normal screen and
    /// its history are where it left them.
    @Test(arguments: ["\u{1b}[?3h", "\u{1b}[?3l"])
    func columnModeStaysOnTheAlternateScreen(sequence: String) {
        let t = terminalWithHistory()
        let saved = t.buffer.yBase
        t.feed(text: "\(esc)[?1049h\(esc)[Hfull screen")

        t.feed(text: sequence)

        #expect(t.isCurrentBufferAlternate, "DECCOLM left the alternate screen")
        #expect(text(t, line: 0) == "", "the alternate screen was not cleared")
        t.feed(text: "\(esc)[?1049l")
        #expect(!t.isCurrentBufferAlternate)
        #expect(t.buffer.yBase == saved)
        #expect(text(t, line: 0) == "line 0")
        #expect(text(t, line: t.buffer.yBase + t.buffer.y) == "$ prompt")
    }

    /// The scrolling region and the left and right margins are reset, the
    /// cursor goes to the top left corner, the lines are single width.
    @Test(arguments: ["\u{1b}[?3h", "\u{1b}[?3l"])
    func columnModeResetsTheMarginsAndTheLineSizes(sequence: String) {
        let t = terminalWithHistory()
        t.feed(text: "\(esc)[2;4r\(esc)[?69h\(esc)[3;10s\(esc)[3;5H\(esc)#6wide")
        #expect(t.buffer.scrollTop == 1)

        t.feed(text: sequence)

        #expect(t.buffer.scrollTop == 0)
        #expect(t.buffer.scrollBottom == t.rows - 1)
        #expect(t.buffer.marginLeft == 0)
        #expect(t.buffer.marginRight == t.cols - 1)
        #expect(t.buffer.x == 0 && t.buffer.y == 0)
        for row in 0 ..< t.rows {
            #expect(t.buffer.lines[t.buffer.yBase + row].renderMode == .single)
        }
    }

    /// With mode 40 off (`CSI ? 40 l`) DECCOLM does nothing at all.
    @Test func columnModeIsIgnoredWhenNotAllowed() {
        let t = terminalWithHistory()
        let cols = t.cols
        t.feed(text: "\(esc)[?40l\(esc)[?3h")
        #expect(t.cols == cols)
        #expect(text(t, line: t.buffer.yBase + t.buffer.y) == "$ prompt")
        #expect(sizeChanges == 0)
    }

    /// Mode 40 is off until a program turns it on, as in xterm, and again
    /// after a full reset: a remote could make the window 132 or 80 columns
    /// wide, and clear the screen, with DECCOLM alone. DECRQM says so.
    @Test(arguments: ["", "\u{1b}[?40h\u{1b}c"])
    func columnModeIsNotAllowedUntilAProgramAllowsIt(before: String) {
        let t = terminalWithHistory(allowingColumnMode: false)
        t.feed(text: before)
        t.feed(text: "\r\(esc)[K$ prompt")
        let cols = t.cols

        for sequence in ["\(esc)[?3h", "\(esc)[?3l"] {
            t.feed(text: sequence)
            #expect(t.cols == cols, "\(sequence.debugDescription) made the window \(t.cols) columns wide")
            #expect(text(t, line: t.buffer.yBase + t.buffer.y) == "$ prompt", "the screen was cleared")
        }
        #expect(sizeChanges == 0)

        responses = []
        t.feed(text: "\(esc)[?40$p")
        #expect(responses == ["\(esc)[?40;2$y"])
        t.feed(text: "\(esc)[?40h\(esc)[?40$p")
        #expect(responses.last == "\(esc)[?40;1$y")
        t.feed(text: "\(esc)[?3h")
        #expect(t.cols == 132)
    }
}
