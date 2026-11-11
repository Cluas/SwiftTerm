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

    // MARK: - A selection over an erased history

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
}
#endif
