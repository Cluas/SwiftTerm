//
//  FullResetTests.swift
//
//  RIS (`ESC c`, what `reset` and `tput reset` send) puts the terminal back
//  in its initial state. xterm (charproc.c, ReallyReset) leaves the
//  alternate screen, clearing it first if it is showing (FromAlternate with
//  clearFirst), clears the screen and puts the cursor at home: CursorSet
//  (screen, 0, 0, ...), then CursorSave. SwiftTerm made a fresh normal
//  buffer and switched to it the way leaving the alternate screen does,
//  which hands the normal screen the alternate screen's cursor: after a
//  full-screen program the next prompt came out wherever that program left
//  its cursor.
//

import Testing

@testable import SwiftTerm

final class FullResetTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal() -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 6, scrollback: 50))
    }

    private func rowText(_ t: Terminal, _ row: Int) -> String {
        TerminalTestHarness.lineText(buffer: t.buffer, terminal: t, row: row) ?? "<no row \(row)>"
    }

    /// Mode 47 leaves the alternate screen without clearing it, so its cursor
    /// stays where the program left it (terminfo entries such as xterm-r6 use
    /// 47 for smcup/rmcup). A reset after that took the cursor from there.
    @Test func testResetAfterLeavingTheAlternateScreenPutsTheCursorAtHome() {
        let t = makeTerminal()
        t.feed(text: "$ less notes\r\n")
        t.feed(text: "\u{1b}[?47h\u{1b}[5;7Hpage 1\u{1b}[?47l")
        #expect(!t.isCurrentBufferAlternate)

        t.feed(text: "\u{1b}c")

        #expect(!t.isCurrentBufferAlternate)
        #expect(t.buffer.x == 0, "column \(t.buffer.x) after a reset")
        #expect(t.buffer.y == 0, "row \(t.buffer.y) after a reset")
        t.feed(text: "$ ")
        #expect(rowText(t, 0) == "$ ", "the next prompt is not at the top: \((0 ..< t.rows).map { rowText(t, $0) })")
    }

    /// `reset` typed after a full-screen program died without leaving the
    /// alternate screen: xterm clears that screen, goes back to the normal
    /// one and puts the cursor at home. The cursor stayed where the program
    /// left it, and the program's screen came back the next time anything
    /// switched to the alternate screen.
    @Test func testResetOnTheAlternateScreenStartsOverOnTheNormalScreen() {
        let t = makeTerminal()
        t.feed(text: "$ top\r\n")
        t.feed(text: "\u{1b}[?1049h\u{1b}[H\u{1b}[2Jload 0.42\u{1b}[5;7Hcpu 99%")
        #expect(t.isCurrentBufferAlternate)

        t.feed(text: "\u{1b}c")

        #expect(!t.isCurrentBufferAlternate, "a reset ends on the normal screen")
        #expect(t.buffer.x == 0, "column \(t.buffer.x) after a reset")
        #expect(t.buffer.y == 0, "row \(t.buffer.y) after a reset")

        t.feed(text: "\u{1b}[?1049h")
        #expect(t.isCurrentBufferAlternate)
        let left = (0 ..< t.rows).map { rowText(t, $0) }.filter { !$0.isEmpty }
        #expect(left.isEmpty, "the alternate screen kept what was on it before the reset: \(left)")
    }
}
