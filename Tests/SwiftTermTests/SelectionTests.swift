//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/20.
//

import Foundation
import Testing

@testable import SwiftTerm

final class SelectionTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        print ("here")
    }
    
    @Test func testDoesNotCrashWhenSelectingWordOrExpressionOutsideColumnRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")
        
        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position(col: -1, row: 0), in: terminal.buffer)
        selection.selectWordOrExpression(at: Position(col: 11, row: 0), in: terminal.buffer)
    }
    
    @Test func testDoesNotCrashWhenSelectingWordOrExpressionOutsideRowRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")

        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position (col: 0, row: -1), in: terminal.buffer)

    }

    @Test func testSelectWordOrExpressionSelectsWord() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)

        #expect(selection.getSelectedText() == "hello")
    }

    @Test func testSelectWordOrExpressionSelectsBalancedParens() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "(abc) def")

        selection.selectWordOrExpression(at: Position(col: 0, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "(abc)")

        selection.selectWordOrExpression(at: Position(col: 4, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "(abc)")
    }

    /// The shape tmux captured from a real Claude Code transcript: a long
    /// hyperlink printed as two physical rows, each re-opening the same
    /// OSC 8 link after the continuation indent.
    private func feedWrappedLink(_ terminal: Terminal, url: String, rows: [String], indent: String = "  ") {
        let open = "\u{1b}]8;id=7;\(url)\u{1b}\\"
        let close = "\u{1b}]8;;\u{1b}\\"
        var text = ""
        for (index, row) in rows.enumerated() {
            if index > 0 { text += "\r\n" + indent }
            text += open + row + close
        }
        terminal.feed(text: text)
    }

    @Test func testWordSelectionOnWrappedHyperlinkTakesAllOfItAndCopiesTheAddress() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        let selection = SelectionService(terminal: terminal)
        let url = "https://x.y/abcdefghijkl"
        feedWrappedLink(terminal, url: url, rows: ["https://x.y/abcdefgh", "ijkl"])

        selection.selectWordOrExpression(at: Position(col: 5, row: 0), in: terminal.buffer)
        #expect(selection.start == Position(col: 0, row: 0))
        #expect(selection.end == Position(col: 6, row: 1), "the continuation row's indent is not part of the link")
        #expect(selection.getSelectedText() == url, "copying the link yields the address, not the rows")

        selection.selectWordOrExpression(at: Position(col: 3, row: 1), in: terminal.buffer)
        #expect(selection.start == Position(col: 0, row: 0), "from the continuation row the same link is selected")
        #expect(selection.getSelectedText() == url)
    }

    @Test func testWrappedHyperlinkLabelKeepsItsRowBreak() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        let selection = SelectionService(terminal: terminal)
        feedWrappedLink(terminal, url: "https://x.y/doc", rows: ["Open the", "doc"])

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)
        #expect(selection.end.row == 1, "a label is one link across both rows")
        let text = selection.getSelectedText()
        #expect(text.hasPrefix("Open the"))
        #expect(text.contains("\n"), "a prose label's row break stands for a space and stays")
        #expect(text.hasSuffix("doc"))
    }

    /// tmux's `capture-pane -e` re-emits a hyperlink with an id of its own,
    /// while the live stream carries the program's (here: none) — after a
    /// repaint the two rows of one link differ in everything but the URL.
    @Test func testRowsLinkedWithDifferentIdsAreStillOneLink() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        let selection = SelectionService(terminal: terminal)
        let url = "https://x.y/abcdefghijkl"
        let close = "\u{1b}]8;;\u{1b}\\"
        terminal.feed(text: "\u{1b}]8;;\(url)\u{1b}\\https://x.y/abcdefgh" + close
                      + "\r\n  \u{1b}]8;id=128g0ok;\(url)\u{1b}\\ijkl" + close)

        selection.selectWordOrExpression(at: Position(col: 3, row: 1), in: terminal.buffer)
        #expect(selection.start == Position(col: 0, row: 0))
        #expect(selection.getSelectedText() == url)
    }

    /// A drag that starts on the indent before an indented link and ends on
    /// the blanks after it still copies the address.
    @Test func testDragOverAnIndentedWrappedLinkCopiesTheAddress() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        let selection = SelectionService(terminal: terminal)
        let url = "https://x.y/abcdefghijkl"
        terminal.feed(text: "  ")
        feedWrappedLink(terminal, url: url, rows: ["https://x.y/abcdef", "ghijkl"])

        selection.setSoftStart(row: 0, col: 0)
        selection.shiftExtend(row: 1, col: 12)
        #expect(selection.getSelectedText() == url)
    }

    @Test func testSelectionReachingPastTheLinkCopiesRowsAsTheyAre() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        let selection = SelectionService(terminal: terminal)
        feedWrappedLink(terminal, url: "https://x.y/abcdefghijkl", rows: ["https://x.y/abcdefgh", "ijkl"])
        terminal.feed(text: " tail")

        selection.setSoftStart(row: 0, col: 0)
        selection.shiftExtend(row: 1, col: 11)
        let text = selection.getSelectedText()
        #expect(text.contains("\n"), "prose after the link keeps the selection's real rows")
        #expect(text.hasSuffix("ijkl tail"))
    }

#if os(macOS)
    // Test only on macOS due to differences in how frames are handled on mac and iOS
    @Test func testMouseHitCorrectWhenScrolled() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 10, height: 10)))

        for _ in 0..<100 {
            view.terminal.feed (text: "12345")
        }

        // Scroll all the way down, check the bottom-left corner
        view.scrollTo(row: 100)
        #expect(view.calculateMouseHit(at: CGPoint(x: 0, y: 0)).grid.row == 100)

        // Scroll all the way back up, check the top-left corner
        view.scrollTo(row: 1)
        #expect(view.calculateMouseHit(at: CGPoint(x: 0, y: 10)).grid.row == 1)
    }
#endif

    // MARK: - Selection Tests Ported from Ghostty

    /// Test that selection start and end are properly ordered
    /// From Ghostty: "Selection: order, standard"
    @Test func testSelectionOrdering() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDE\nFGHIJ\nKLMNO")

        // Set selection from higher position to lower position
        selection.setSelection(
            start: Position(col: 5, row: 2),
            end: Position(col: 2, row: 0)
        )

        // Selection service should keep start before end internally
        // or the getSelectedText should work regardless of order
        let text = selection.getSelectedText()
        #expect(text.contains("ABCDE") || text.contains("CDE"))
    }

    /// Test selecting entire line
    /// From Ghostty: row selection
    @Test func testSelectRow() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        selection.select(row: 1)

        #expect(selection.active)
        #expect(selection.start.row == 1)
        #expect(selection.end.row == 1)
        #expect(selection.start.col == 0)
        #expect(selection.end.col == terminal.cols, "the end is exclusive")
    }

    /// A triple-click selects the row, and the copy is the row: its last
    /// cell went missing (the end is exclusive and was set to the last
    /// column, the cause Select All had).
    @Test func testSelectRowCopiesAFullRowWhole() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "first\r\n0123456789")

        selection.select(row: 1)

        #expect(selection.getSelectedText() == "0123456789")
    }

    /// Shift-click after a triple-click extends by whole rows: forwards, the
    /// last row it reaches comes whole too.
    @Test func testShiftExtendingARowSelectionTakesTheLastRowWhole() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "first\r\nabcdefghij\r\n0123456789")

        selection.select(row: 0)
        selection.shiftExtend(row: 2, col: 3)

        #expect(selection.getSelectedText() == "first\nabcdefghij\n0123456789")
    }

    /// Test select all
    /// From Ghostty: selection of entire buffer
    @Test func testSelectAll() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        selection.selectAll()

        #expect(selection.active)
        #expect(selection.start.col == 0)
        #expect(selection.start.row == 0)
    }

    /// The lines the normal buffer has made, in use or not.
    private func linesMade(_ terminal: Terminal) -> Int {
        terminal.normalBuffer.lines.getArray().reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    /// A terminal with a 10 000-line history (Moshpit's) holding a hundred
    /// lines of output and a prompt.
    private func terminalWithShortHistory() -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24, scrollback: 10_000))
        for i in 0 ..< 100 {
            terminal.feed(text: "line \(i)\r\n")
        }
        terminal.feed(text: "$ ")
        return terminal
    }

    /// Select All ends on the last line with anything on it. It ended on the
    /// last line the scrollback could hold, 10 023 here, where 101 lines
    /// exist: past them every row is a slot for a line nobody wrote.
    @Test func testSelectAllEndsOnTheLastLineWithContent() {
        let terminal = terminalWithShortHistory()
        let selection = SelectionService(terminal: terminal)

        selection.selectAll()

        #expect(selection.active)
        #expect(selection.start == Position(col: 0, row: 0))
        #expect(selection.end.row == 100, "the prompt's line is the last with content, not \(selection.end.row)")
    }

    /// Copying a Select All visits the selection's rows, and the hyperlink
    /// stitching (patch 22) every one of its cells: on rows past the output
    /// that made a line per slot, 10 024 lines of 80 cells, about 20 MB that
    /// stayed in the buffer, plus a position per cell for the stitching.
    @Test func testCopyingSelectAllMakesNoLinesPastTheOutput() {
        let terminal = terminalWithShortHistory()
        let selection = SelectionService(terminal: terminal)
        let before = linesMade(terminal)

        selection.selectAll()
        let text = selection.getSelectedText()

        #expect(linesMade(terminal) == before, "\(linesMade(terminal) - before) lines made by a copy")
        let expected = (0 ..< 100).map { "line \($0)" }.joined(separator: "\n") + "\n$ "
        #expect(text == expected)
    }

    /// The selection's end is exclusive. Select All ended at the last
    /// column, so a last line that fills the row lost its last character:
    /// the bottom row of a full-screen program's screen, for one.
    @Test func testSelectAllCopiesTheLastCellOfTheLastLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 3))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "top\r\n\r\n0123456789")

        selection.selectAll()

        #expect(selection.getSelectedText() == "top\n\n0123456789")
    }

    /// Test drag extend moves end position
    /// From Ghostty: selection adjustment
    @Test func testDragExtendMovesEnd() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDEFGHIJ")

        // Start selection at position 2
        selection.startSelection(row: 0, col: 2)

        // Drag to position 7
        selection.dragExtend(row: 0, col: 7)

        #expect(selection.end.col == 7)
        #expect(selection.end.row == 0)
    }

    /// Test drag extend across multiple lines
    /// From Ghostty: multi-line selection
    @Test func testDragExtendMultiLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        // Start selection on line 0
        selection.startSelection(row: 0, col: 2)

        // Drag to line 2
        selection.dragExtend(row: 2, col: 3)

        #expect(selection.isMultiLine)
        #expect(selection.end.row == 2)
    }

    /// Test shift extend can swap start and end
    /// From Ghostty: "Selection: adjust left/right"
    @Test func testShiftExtendSwapsWhenNeeded() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDEFGHIJ")

        // Start selection at position 5
        selection.startSelection(row: 0, col: 5)
        selection.dragExtend(row: 0, col: 7)

        // Now shift extend to position 2 (before start)
        selection.shiftExtend(row: 0, col: 2)

        // Selection should now include position 2
        let text = selection.getSelectedText()
        #expect(text.contains("C") || selection.start.col <= 2)
    }

    /// Test selection with empty line
    @Test func testSelectionWithEmptyContent() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)

        // Don't feed any text - buffer should be empty/spaces
        selection.startSelection(row: 0, col: 0)
        selection.dragExtend(row: 0, col: 5)

        // Should not crash, text may be empty or spaces
        let text = selection.getSelectedText()
        #expect(text.count >= 0)
    }

    /// Test selection active state
    /// From Ghostty: selection state management
    @Test func testSelectionActiveState() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test content")

        #expect(!selection.active)

        selection.startSelection(row: 0, col: 0)
        #expect(selection.active)

        selection.active = false
        #expect(!selection.active)
    }

    /// Test hasSelectionRange
    @Test func testHasSelectionRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test content")

        // Initially no range
        #expect(!selection.hasSelectionRange)

        // Start selection - still no range (start == end)
        selection.startSelection(row: 0, col: 5)
        #expect(!selection.hasSelectionRange)

        // Extend - now has range
        selection.dragExtend(row: 0, col: 8)
        #expect(selection.hasSelectionRange)
    }

    /// Test selection text extraction with newlines
    /// From Ghostty: formatter tests for selection
    @Test func testSelectionTextWithNewlines() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "AAA\r\nBBB\r\nCCC")

        // Use selectAll to get everything
        selection.selectAll()

        let text = selection.getSelectedText()
        // Should contain content from multiple lines
        #expect(text.contains("AAA"))
        #expect(text.contains("BBB"))
        #expect(text.contains("CCC"))
    }

    /// Test word selection at word boundaries
    /// From Ghostty: word boundary selection
    @Test func testWordSelectionAtBoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        // Select word at start of "world"
        selection.selectWordOrExpression(at: Position(col: 6, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "world")

        // Select word at end of "world"
        selection.selectWordOrExpression(at: Position(col: 10, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "world")
    }

    /// Test balanced expression selection with nested brackets
    @Test func testBalancedExpressionNested() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "foo(bar[baz])end")

        // Click on opening paren - should select balanced expression
        selection.selectWordOrExpression(at: Position(col: 3, row: 0), in: terminal.buffer)
        let text = selection.getSelectedText()

        // Should include the full balanced expression
        #expect(text == "(bar[baz])")
    }

    /// Test balanced expression with braces
    @Test func testBalancedExpressionBraces() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "x{a{b}c}y")

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)
        let text = selection.getSelectedText()

        #expect(text == "{a{b}c}")
    }

    /// Test selection mode persists during extension
    @Test func testSelectionModePersistence() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        // Start character selection
        selection.startSelection(row: 0, col: 5)
        #expect(selection.selectionMode == .character)

        // Select row
        selection.select(row: 0)
        #expect(selection.selectionMode == .row)
    }

    /// Test soft start doesn't activate selection visually
    @Test func testSoftStartBehavior() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test")

        // Soft start should set position but selection should still be active
        // (in SwiftTerm, setSoftStart calls setActiveAndNotify)
        selection.setSoftStart(row: 0, col: 3)

        // The position should be set
        #expect(selection.start.col == 3)
        #expect(selection.end.col == 3)
    }

    // MARK: - Lines dropped from the top of the buffer (ESC [ 3 J)

    /// What the terminal last told its delegate it dropped. Each test gets its
    /// own instance.
    private var droppedLines: [Int] = []
    func linesDropped(source: Terminal, count: Int) { droppedLines.append(count) }

    /// Erasing the saved lines tells the delegate how many lines went: the
    /// rows above the screen. With none saved, and on the alternate screen
    /// (which saves none), nothing moved and nothing is said.
    @Test func testErasingSavedLinesReportsTheLinesDropped() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5, scrollback: 100))
        terminal.feed(text: "\u{1b}[3J")
        #expect(droppedLines == [])

        for i in 0 ..< 20 {
            terminal.feed(text: "line \(i)\r\n")
        }
        let saved = terminal.buffer.yBase
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[3J\u{1b}[?1049l")
        #expect(droppedLines == [], "the alternate screen has no saved lines")

        terminal.feed(text: "\u{1b}[3J")
        #expect(droppedLines == [saved])
    }

    /// A selection on the lines that are left moves up with its text, and so
    /// does the pivot a handle drag extends from.
    @Test func testLinesDroppedMovesTheSelectionWithItsText() throws {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5, scrollback: 100))
        let selection = SelectionService(terminal: terminal)
        for i in 0 ..< 20 {
            terminal.feed(text: "line \(i)\r\n")
        }
        selection.setSelection(start: Position(col: 2, row: 17), end: Position(col: 4, row: 18))
        selection.pivot = Position(col: 2, row: 17)
        let text = selection.getSelectedText()

        terminal.feed(text: "\u{1b}[3J")
        let dropped = try #require(droppedLines.first)
        selection.linesDropped(count: dropped)

        #expect(selection.active)
        #expect(selection.start == Position(col: 2, row: 17 - dropped))
        #expect(selection.end == Position(col: 4, row: 18 - dropped))
        #expect(selection.pivot == Position(col: 2, row: 17 - dropped))
        #expect(selection.getSelectedText() == text)
    }

    /// A selection with any of its rows among the dropped lines goes, as a
    /// whole: its text is not all there any more.
    @Test(arguments: [(start: 3, end: 4), (start: 14, end: 16), (start: 15, end: 15)])
    func testLinesDroppedDropsASelectionThatReachedIntoThem(rows: (start: Int, end: Int)) {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5, scrollback: 100))
        let selection = SelectionService(terminal: terminal)
        for i in 0 ..< 20 {
            terminal.feed(text: "line \(i)\r\n")
        }
        selection.setSelection(start: Position(col: 0, row: rows.start), end: Position(col: 4, row: rows.end))

        selection.linesDropped(count: 16)

        #expect(!selection.active, "rows \(rows.start)...\(rows.end) reached into the 16 lines dropped")
    }

    // MARK: - Switching screens

    /// How many times the terminal said the screen changed.
    private var screenSwitches = 0
    func bufferActivated(source: Terminal) { screenSwitches += 1 }

    /// The delegate hears of a switch between the normal and the alternate
    /// screen, the cue to drop what it kept in rows of the other one — and
    /// only of a switch: a program that asks for the screen already showing
    /// changes nothing, and a selection there should stay.
    @Test func testOnlyARealScreenSwitchIsReported() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(screenSwitches == 1)
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?47h")
        #expect(screenSwitches == 1, "asking for the alternate screen while it shows is not a switch")
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(screenSwitches == 2)
        terminal.feed(text: "\u{1b}[?1049l\u{1b}[?1047l")
        #expect(screenSwitches == 2, "asking for the normal screen while it shows is not a switch")
        terminal.feed(text: "\u{1b}[?47h\u{1b}[?47l")
        #expect(screenSwitches == 4)
    }

    // MARK: - Lines dropped from a full history

    /// Until the history is full a new line takes a new row and no row
    /// number changes. Once it is full, every line that scrolls in pushes the
    /// oldest one out and every line left sits a row earlier: the delegate
    /// hears of one line dropped per line. The alternate screen keeps no
    /// history, so it is always full.
    @Test func testAFullHistoryReportsALineDroppedForEachNewLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 30, scrollback: 10))
        // 29 line feeds reach the bottom row, ten more fill the history.
        for i in 0 ..< 39 {
            terminal.feed(text: "line \(i)\r\n")
        }
        #expect(terminal.buffer.lines.isFull)
        #expect(droppedLines == [], "nothing was dropped before the history was full")

        terminal.feed(text: "line 39\r\nline 40\r\nline 41\r\n")
        #expect(droppedLines == [1, 1, 1])

        droppedLines = []
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[30;1H\r\n\r\n")
        #expect(droppedLines == [1, 1], "the alternate screen dropped its top row")
    }

    /// A selection on the screen while output scrolls on, with the history
    /// full: it kept its row numbers while the rows moved up under it, so
    /// with every new line it slid a line further down the text, highlight
    /// and copy, and went to another line's text entirely.
    @Test func testASelectionStaysOnItsTextAsLinesScrollIntoAFullHistory() throws {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5, scrollback: 10))
        let selection = SelectionService(terminal: terminal)
        for i in 0 ..< 20 {
            terminal.feed(text: "line \(i)\r\n")
        }
        #expect(terminal.buffer.lines.isFull)
        let row = terminal.buffer.yBase + 2
        selection.setSelection(start: Position(col: 0, row: row), end: Position(col: 7, row: row))
        let selected = selection.getSelectedText()
        #expect(selected == "line 18")

        droppedLines = []
        terminal.feed(text: "line 20\r\nline 21\r\n")
        // What the views do with what they hear.
        for count in droppedLines {
            selection.linesDropped(count: count)
        }

        #expect(selection.active)
        #expect(selection.getSelectedText() == selected, "the selection slid onto other text")
    }
}
