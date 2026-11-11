//
//  ClearScrollbackViewTests.swift
//
//  The view's side of ESC [ 3 J (erase saved lines): trimming the history
//  moves the viewport, and a view that is not told keeps placing itself on
//  the old row. On iOS that row is the scroll offset the rows are drawn
//  from, so after `clear` with history every draw came out empty. The iOS
//  view is not built here; the macOS one hears the same notification and
//  passes it on to its host.
//

#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

struct ClearScrollbackViewTests {
    final class Host: TerminalViewDelegate {
        var positions: [Double] = []
        func scrolled(source: TerminalView, position: Double) { positions.append(position) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @MainActor
    @Test func clearWithHistoryTellsTheViewAndItsHostWhereTheViewportWent() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let host = Host()
        view.terminalDelegate = host
        for i in 0 ..< 200 {
            view.terminal.feed(text: "line \(i)\r\n")
        }
        #expect(view.canScroll, "history above the screen")
        #expect(view.terminal.getTopVisibleRow() > 0)

        host.positions = []
        view.terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")

        #expect(!view.canScroll, "the saved lines are gone")
        #expect(view.terminal.getTopVisibleRow() == 0)
        #expect(host.positions == [0], "the viewport moved to the top without a word: \(host.positions)")
    }

    /// A full reset (`ESC c`, what `reset` sends) drops the history with the
    /// rest of the buffer: the same move, the same word owed.
    @MainActor
    @Test func resetWithHistoryTellsTheViewAndItsHostWhereTheViewportWent() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let host = Host()
        view.terminalDelegate = host
        for i in 0 ..< 200 {
            view.terminal.feed(text: "line \(i)\r\n")
        }
        #expect(view.canScroll, "history above the screen")
        #expect(view.terminal.getTopVisibleRow() > 0)

        host.positions = []
        view.terminal.feed(text: "\u{1b}c")

        #expect(!view.canScroll, "a reset leaves no history")
        #expect(view.terminal.getTopVisibleRow() == 0)
        #expect(host.positions == [0], "the viewport moved to the top without a word: \(host.positions)")
    }

    // MARK: - A selection over an erased history, and over a reset

    /// A view with two hundred lines of output, of which the screen shows
    /// the last few, keeping its selection while output arrives (a host that
    /// lets the user select while a program writes turns mouse reporting off
    /// for that, as Moshpit does).
    @MainActor
    private func viewWithHistory() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.allowMouseReporting = false
        for i in 0 ..< 200 {
            view.feed(text: "line \(i)\r\n")
        }
        #expect(view.terminal.buffer.yBase > 100, "history above the screen")
        return view
    }

    /// Buffer row `row`'s first `length` cells as the selection.
    @MainActor
    private func select(_ view: TerminalView, row: Int, through lastRow: Int? = nil, length: Int = 8) {
        view.selection.setSelection(start: Position(col: 0, row: row),
                                    end: Position(col: length, row: lastRow ?? row))
    }

    /// A selection is kept as buffer rows, and erasing the saved lines moves
    /// every row that is left up by as many as were erased. A selection on
    /// the screen stayed on its old row numbers: the highlight and the copy
    /// landed on whatever came to sit there — here, rows that are not there.
    @MainActor
    @Test func clearingTheHistoryKeepsASelectionOnTheScreenOnItsText() throws {
        let view = viewWithHistory()
        let erased = view.terminal.buffer.yBase
        select(view, row: erased + 2)
        let selected = try #require(view.getSelection())
        #expect(selected.hasPrefix("line 1"), "\(selected)")

        view.feed(text: "\u{1b}[3J")

        #expect(view.selectionActive, "the text it selected is still on the screen")
        #expect(view.getSelection() == selected, "the selection no longer covers its text")
        #expect(view.selection.start.row == 2)
        #expect(view.selection.end.row == 2)
    }

    /// A selection in the history the sequence erased has no text left: it
    /// goes. It stayed, and copied the screen rows that now have its numbers.
    @MainActor
    @Test func clearingTheHistoryDropsASelectionInIt() {
        let view = viewWithHistory()
        select(view, row: 3)
        #expect(view.getSelection() == "line 3")

        view.feed(text: "\u{1b}[3J")

        #expect(!view.selectionActive, "a selection of erased text survived")
        #expect(view.getSelection() == nil)
    }

    /// Part of the text is gone and the rest moved: a selection reaching from
    /// the erased history into the screen goes too.
    @MainActor
    @Test func clearingTheHistoryDropsASelectionReachingIntoIt() {
        let view = viewWithHistory()
        let screenTop = view.terminal.buffer.yBase
        select(view, row: screenTop - 2, through: screenTop + 1)

        view.feed(text: "\u{1b}[3J")

        #expect(!view.selectionActive, "a selection of partly erased text survived")
        #expect(view.getSelection() == nil)
    }

    /// Once the history is full, every line of output pushes the oldest one
    /// out and moves every row left up by one. The selection kept its row
    /// numbers: with each new line it slid a line down the text, highlight
    /// and copy.
    @MainActor
    @Test func aSelectionStaysOnItsTextWhileLinesScrollIntoAFullHistory() throws {
        let view = viewWithHistory()
        view.terminal.changeScrollback(50)
        #expect(view.terminal.buffer.lines.isFull, "the history is full")
        select(view, row: view.terminal.buffer.yBase + 2)
        let selected = try #require(view.getSelection())
        #expect(selected.hasPrefix("line 1"), "\(selected)")

        for i in 0 ..< 5 {
            view.feed(text: "more \(i)\r\n")
        }

        #expect(view.selectionActive)
        #expect(view.getSelection() == selected, "the selection slid onto other text")
    }

    /// The text of a selection on the oldest line leaves with it.
    @MainActor
    @Test func aSelectionGoesWithItsTextOutOfAFullHistory() throws {
        let view = viewWithHistory()
        view.terminal.changeScrollback(50)
        #expect(view.terminal.buffer.lines.isFull, "the history is full")
        select(view, row: 0, length: 4)
        #expect(view.selectionActive)

        view.feed(text: "more\r\n")

        #expect(!view.selectionActive, "a selection outlived its text")
    }

    // MARK: - A selection over a switch of screens

    /// A program that switches to the alternate screen (less, vim, a
    /// full-screen agent) puts other text where the selection was: the
    /// selection kept its rows, and Copy took the other screen's text.
    /// xterm.js clears it on the switch; so do the views now, both ways.
    @MainActor
    @Test func switchingToTheAlternateScreenDropsTheSelection() {
        let view = viewWithHistory()
        select(view, row: view.terminal.buffer.yBase + 2)
        #expect(view.selectionActive)

        view.feed(text: "\u{1b}[?1049h\u{1b}[Hfull screen")

        #expect(!view.selectionActive, "the selection outlived the screen it was made on")
        #expect(view.getSelection() == nil)
    }

    @MainActor
    @Test func leavingTheAlternateScreenDropsTheSelection() throws {
        let view = viewWithHistory()
        view.feed(text: "\u{1b}[?1049h\u{1b}[Hfull screen")
        select(view, row: view.terminal.buffer.yBase, length: 11)
        #expect(try #require(view.getSelection()) == "full screen")

        view.feed(text: "\u{1b}[?1049l")

        #expect(!view.selectionActive, "the selection outlived the screen it was made on")
        #expect(view.getSelection() == nil)
    }

    /// Asking for the screen that already shows changes nothing.
    @MainActor
    @Test func askingForTheScreenThatShowsKeepsTheSelection() throws {
        let view = viewWithHistory()
        view.feed(text: "\u{1b}[?1049h\u{1b}[Hfull screen")
        select(view, row: view.terminal.buffer.yBase, length: 11)

        view.feed(text: "\u{1b}[?1049h")

        #expect(view.selectionActive)
        #expect(view.getSelection() == "full screen")
    }

    /// A full reset (`ESC c`) throws the buffer away, history and screen.
    /// The selection stayed, its rows pointing into the fresh buffer: a
    /// highlight over blank rows, and a copy of whatever the next output put
    /// there. The iOS view's own Reset item dropped it; a reset the remote
    /// sends did not.
    @MainActor
    @Test func aFullResetDropsTheSelection() {
        let view = viewWithHistory()
        select(view, row: view.terminal.buffer.yBase + 2)
        #expect(view.selectionActive)

        view.feed(text: "\u{1b}c")

        #expect(!view.selectionActive, "the selection survived the buffer it was made in")
        #expect(view.getSelection() == nil)
    }

    /// DECCOLM either way clears the screen and changes the columns, which
    /// rewraps the history: a selection goes, as it does when the view
    /// itself resizes (and as xterm's ClearScreen disowns it).
    @MainActor
    @Test(arguments: ["\u{1b}[?40h\u{1b}[?3h", "\u{1b}[?40h\u{1b}[?3l"])
    func columnModeDropsTheSelection(_ sequence: String) {
        let view = viewWithHistory()
        select(view, row: view.terminal.buffer.yBase + 2)
        #expect(view.selectionActive)

        view.feed(text: sequence)

        #expect(!view.selectionActive, "the selection survived a cleared screen at another width")
        #expect(view.getSelection() == nil)
        #expect(view.terminal.buffer.yBase > 0, "DECCOLM keeps the history")
    }
}
#endif
