//
//  HistoryTests.swift
//  SwiftTerm
//
//  Created for testing the dynamic history size change API
//

import Testing
@testable import SwiftTerm

final class HistoryTests {
    
    class TestDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }
    
    @Test func testChangeHistorySize() {
        let delegate = TestDelegate()
        let options = TerminalOptions(scrollback: 100)
        let terminal = Terminal(delegate: delegate, options: options)
        
        // Test initial scrollback
        #expect(terminal.buffer.scrollback == 100)
        #expect(terminal.buffer.hasScrollback)
        
        // Test increasing history size
        terminal.changeHistorySize(500)
        #expect(terminal.buffer.scrollback == 500)
        #expect(terminal.buffer.hasScrollback)
        #expect(terminal.options.scrollback == 500)
        
        // Test decreasing history size
        terminal.changeHistorySize(50)
        #expect(terminal.buffer.scrollback == 50)
        #expect(terminal.buffer.hasScrollback)
        #expect(terminal.options.scrollback == 50)
        
        // Test disabling scrollback
        terminal.changeHistorySize(nil)
        #expect(terminal.buffer.scrollback == nil)
        #expect(!terminal.buffer.hasScrollback)
        #expect(terminal.options.scrollback == 0)
        
        // Test re-enabling scrollback
        terminal.changeHistorySize(1000)
        #expect(terminal.buffer.scrollback == 1000)
        #expect(terminal.buffer.hasScrollback)
        #expect(terminal.options.scrollback == 1000)
    }

    @Test func testChangeScrollbackApi() {
        let delegate = TestDelegate()
        let options = TerminalOptions(scrollback: 20)
        let terminal = Terminal(delegate: delegate, options: options)

        terminal.changeScrollback(80)
        #expect(terminal.buffer.scrollback == 80)
        #expect(terminal.options.scrollback == 80)

        terminal.changeScrollback(nil)
        #expect(terminal.buffer.scrollback == nil)
        #expect(!terminal.buffer.hasScrollback)
        #expect(terminal.options.scrollback == 0)
    }
    
    @Test func testHistorySizeBufferLength() {
        let delegate = TestDelegate()
        let options = TerminalOptions(cols: 80, rows: 25, scrollback: 100)
        let terminal = Terminal(delegate: delegate, options: options)
        
        let initialMaxLength = terminal.buffer.lines.maxLength
        #expect(initialMaxLength == 125) // 25 rows + 100 scrollback
        
        // Increase history size
        terminal.changeHistorySize(200)
        #expect(terminal.buffer.lines.maxLength == 225) // 25 rows + 200 scrollback
        
        // Decrease history size
        terminal.changeHistorySize(50)
        #expect(terminal.buffer.lines.maxLength == 75) // 25 rows + 50 scrollback
        
        // Disable scrollback
        terminal.changeHistorySize(nil)
        #expect(terminal.buffer.lines.maxLength == 25) // 25 rows only
    }

    // MARK: - A history made shorter than it holds

    /// Hears what the terminal drops and where it says the viewport went.
    final class DropDelegate: TerminalDelegate {
        var dropped: [Int] = []
        var scrolledTo: [Int] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func linesDropped(source: Terminal, count: Int) { dropped.append(count) }
        func scrolled(source: Terminal, yDisp: Int) { scrolledTo.append(yDisp) }
    }

    /// Forty lines of output on a five-row screen: 41 lines, 36 of them
    /// history, room for 55.
    private func terminalWithHistory(_ delegate: TerminalDelegate) -> Terminal {
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 5, scrollback: 50))
        for i in 0 ..< 40 {
            terminal.feed(text: "line \(i)\r\n")
        }
        #expect(terminal.buffer.yBase == 36)
        return terminal
    }

    /// Ten lines of history kept: the oldest 26 lines go, and every line
    /// left sits 26 rows earlier, as after ED 3 or a line pushed out of a
    /// full history. The delegate heard nothing: a selection kept its rows
    /// and covered other text, and a view kept placing itself where the
    /// viewport had been.
    @Test func testAShorterHistoryTellsTheDelegateWhatWentAndWhereTheViewportIs() throws {
        let delegate = DropDelegate()
        let terminal = terminalWithHistory(delegate)
        let selection = SelectionService(terminal: terminal)
        selection.setSelection(start: Position(col: 0, row: 34), end: Position(col: 7, row: 34))
        #expect(selection.getSelectedText() == "line 34")
        delegate.scrolledTo = []

        terminal.changeScrollback(10)

        #expect(delegate.dropped == [26])
        for count in delegate.dropped {
            selection.linesDropped(count: count)
        }
        #expect(selection.active)
        #expect(selection.getSelectedText() == "line 34", "the selection slid onto other text")
        #expect(terminal.buffer.yDisp == 10)
        #expect(delegate.scrolledTo == [10], "the view was not told where the viewport went")
    }

    /// The saved cursor (DECSC) is a place on the screen, which a shorter
    /// history leaves where it is: it moved up by as many rows as went.
    @Test func testAShorterHistoryLeavesTheSavedCursorWhereItWas() {
        let terminal = terminalWithHistory(DropDelegate())
        terminal.feed(text: "\u{1b}[3;4H\u{1b}7\u{1b}[H")

        terminal.changeScrollback(10)
        terminal.feed(text: "\u{1b}8")

        #expect(terminal.buffer.x == 3 && terminal.buffer.y == 2,
                "the saved cursor came back at \(terminal.buffer.x), \(terminal.buffer.y)")
    }

    /// A line keeps its scroll-invariant number while lines before it go,
    /// as it does when a full history pushes one out.
    @Test func testAShorterHistoryKeepsTheScrollInvariantNumbers() throws {
        let terminal = terminalWithHistory(DropDelegate())
        let line = try #require(terminal.getScrollInvariantLine(row: 36))
        #expect(line.translateToString(trimRight: true) == "line 36")

        terminal.changeScrollback(10)

        let after = try #require(terminal.getScrollInvariantLine(row: 36), "line 36 has no number any more")
        #expect(after.translateToString(trimRight: true) == "line 36")
        #expect(terminal.getScrollInvariantLine(row: 25) == nil, "line 25 went")
    }

    /// With nothing dropped nothing is said: a longer history, or a shorter
    /// one that still holds every line.
    @Test func testAHistoryThatDropsNothingSaysNothing() {
        let delegate = DropDelegate()
        let terminal = terminalWithHistory(delegate)
        delegate.scrolledTo = []
        terminal.changeScrollback(100)
        terminal.changeScrollback(40)
        #expect(delegate.dropped == [])
        #expect(delegate.scrolledTo == [])
    }
}
