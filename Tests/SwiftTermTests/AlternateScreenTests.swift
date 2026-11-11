//
//  AlternateScreenTests.swift
//
//  The alternate screen keeps no history: xterm makes it "exactly as large
//  as the display" with "no additional saved lines" (ctlseqs, The
//  Alternate Screen Buffer). A program on it that scrolls (less, a log
//  viewer, a full-screen agent printing past its last row) pushes its top
//  row out, and the view has nothing to scroll back into.
//

import Testing

@testable import SwiftTerm

final class AlternateScreenTests {
    private let esc = "\u{1b}"

    /// Sixty lines printed on the alternate screen, which then holds the
    /// screen's rows and nothing above them.
    private func scrollTheAlternateScreen(_ terminal: Terminal, rows: Int) {
        terminal.feed(text: "\(esc)[?1049h")
        for i in 0 ..< 60 {
            terminal.feed(text: "row \(i)\r\n")
        }
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.buffer.yBase == 0, "the alternate screen kept \(terminal.buffer.yBase) lines of history")
        #expect(terminal.buffer.lines.count == rows)
        TerminalTestHarness.assertLineText(terminal.buffer, row: rows - 2, equals: "row 59")
    }

    /// The terminal made its alternate screen 25 rows tall, the default
    /// size, before its own size applied, and making it shorter left it the
    /// room it had: on a screen of fewer rows, the first program on it kept
    /// up to the difference as history.
    @Test(arguments: [3, 10, 24, 25, 40])
    func theAlternateScreenKeepsNoHistory(rows: Int) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: rows, scrollback: 100)
        scrollTheAlternateScreen(terminal, rows: rows)
    }

    /// The same when the screen gets shorter while the normal screen shows,
    /// as it does each time a phone's keyboard comes up: the empty alternate
    /// screen kept the height it had.
    @Test func theAlternateScreenKeepsNoHistoryAfterTheScreenGotShorter() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 40, scrollback: 100)
        terminal.feed(text: "\(esc)[?1049h\(esc)[?1049l")
        terminal.resize(cols: 20, rows: 12)
        scrollTheAlternateScreen(terminal, rows: 12)
    }
}
