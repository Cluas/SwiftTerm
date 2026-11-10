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
}
#endif
