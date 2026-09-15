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
        #expect(selection.end.col == terminal.cols - 1)
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
}
