//
//  LinkLookupTests.swift
//
//
//  Created by Codex on 1/31/26.
//

import Foundation
import Testing

@testable import SwiftTerm

final class LinkLookupTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    private func write(_ text: String, terminal: Terminal, row: Int, col: Int = 0) {
        guard row >= 0 && row < terminal.displayBuffer.lines.count else {
            return
        }
        let line = terminal.displayBuffer.lines[row]
        var x = col
        for ch in text {
            guard x < terminal.cols else { break }
            line[x] = terminal.makeCharData(attribute: CharData.defaultAttr, char: ch)
            x += 1
        }
    }

    @Test func testExplicitLinkLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "abc")

        let payload = "id;https://example.com"
        let atom = TinyAtom.lookup(value: payload)!
        let line = terminal.displayBuffer.lines[0]
        var cd = line[1]
        cd.setPayload(atom: atom)
        line[1] = cd

        let link = terminal.link(at: .buffer(Position(col: 1, row: 0)), mode: .explicitOnly)
        #expect(link == "https://example.com")
    }

    @Test func testImplicitUrlLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 1))
        terminal.feed(text: "https://example.com tail")

        let link = terminal.link(at: .buffer(Position(col: 5, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "https://example.com")
    }

    @Test func testImplicitFilePathLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "/tmp/example.txt")

        let link = terminal.link(at: .buffer(Position(col: 2, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "/tmp/example.txt")
    }

    @Test func testImplicitUrlLookupAcrossWrappedLines() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
        terminal.feed(text: url)

        let topRowLink = terminal.link(at: .buffer(Position(col: 2, row: 0)), mode: .explicitAndImplicit)
        #expect(topRowLink == url)

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 1, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == url)
    }

    @Test func testImplicitMatchReportsPerRowRangesAcrossWrap() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
        terminal.feed(text: url)

        guard let match = terminal.linkMatch(at: .buffer(Position(col: 1, row: 1)), mode: .explicitAndImplicit) else {
            Issue.record("Expected implicit link match on wrapped row")
            return
        }
        #expect(match.text == url)
        #expect(match.rowRanges.count >= 2)
        #expect(match.rowRanges.contains { $0.row == 0 })
        #expect(match.rowRanges.contains { $0.row == 1 })
        #expect(match.rowRanges.first(where: { $0.row == 1 })?.range.contains(1) == true)
    }

    @Test func testImplicitUrlLookupAcrossWrappedContinuationWithIndentation() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        write("https://example.", terminal: terminal, row: 0)
        write("    com/path", terminal: terminal, row: 1)
        terminal.displayBuffer.lines[1].isWrapped = true

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 6, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == "https://example.com/path")
    }

    @Test func testImplicitUrlLookupAcrossEditorSoftWrapWithoutWrappedFlag() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 92, rows: 4))
        let firstSegment = "https://example.com/this/is/a/long/url/segment/that/reaches/the/visual/wrap/"
        write(firstSegment, terminal: terminal, row: 0)
        write("    and/keeps/going", terminal: terminal, row: 1)

        let firstRowLink = terminal.link(at: .buffer(Position(col: 20, row: 0)), mode: .explicitAndImplicit)
        #expect(firstRowLink == firstSegment + "and/keeps/going")

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 8, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == firstSegment + "and/keeps/going")
    }

    @Test func testImplicitUrlLookupDoesNotJoinUnrelatedRows() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 92, rows: 3))
        write("https://example.com", terminal: terminal, row: 0)
        write("nextline", terminal: terminal, row: 1)

        let urlRowLink = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(urlRowLink == "https://example.com")

        let nextRowLink = terminal.link(at: .buffer(Position(col: 2, row: 1)), mode: .explicitAndImplicit)
        #expect(nextRowLink == nil)
    }

    @Test func testImplicitBareDomainDoesNotMatch() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "example.com")

        let link = terminal.link(at: .buffer(Position(col: 3, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testWhitespaceReturnsNil() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "a b")

        let link = terminal.link(at: .buffer(Position(col: 1, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testScreenCoordinates() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 32, rows: 2))
        terminal.feed(text: "https://www.example.com")

        let link = terminal.link(at: .screen(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "https://www.example.com")
    }

    // MARK: - viewportLineText / tagPlainTextLink
    //
    // These support a host app (Moshi) linkifying plain http(s) URLs with its
    // OWN detector, deliberately bypassing SwiftTerm's built-in implicit-link
    // regex — testImplicitFilePathLookup above proves that regex matches bare
    // file paths too (a false positive Moshi specifically wants to avoid).

    @Test func testViewportLineTextReturnsPlainTrimmedText() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 3))
        terminal.feed(text: "hello world")

        #expect(terminal.viewportLineText(row: 0) == "hello world")
        #expect(terminal.viewportLineText(row: 1) == "")
    }

    @Test func testViewportLineTextOutOfBoundsReturnsEmpty() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 2))
        terminal.feed(text: "hi")

        #expect(terminal.viewportLineText(row: -1) == "")
        #expect(terminal.viewportLineText(row: 99) == "")
    }

    @Test func testTagPlainTextLinkMakesTextTappableAndExplicit() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 1))
        terminal.feed(text: "see http://example.com/x for details")

        // "http://example.com/x" starts at column 4, 20 characters long.
        terminal.tagPlainTextLink(row: 0, startCol: 4, endCol: 23, url: "http://example.com/x")

        // Explicit-only lookup (what `.always` highlight mode / tap-to-open
        // uses) now finds it — proving this is indistinguishable from a real
        // OSC-8 hyperlink to the rest of SwiftTerm, not just a heuristic match.
        let explicit = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitOnly)
        #expect(explicit == "http://example.com/x")

        // Untouched text on either side is not part of the link.
        #expect(terminal.link(at: .buffer(Position(col: 0, row: 0)), mode: .explicitOnly) == nil)
        #expect(terminal.link(at: .buffer(Position(col: 25, row: 0)), mode: .explicitOnly) == nil)
    }

    @Test func testTagPlainTextLinkClampsOutOfRangeColumns() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "0123456789")

        // endCol well past the last column must clamp, not crash / corrupt.
        terminal.tagPlainTextLink(row: 0, startCol: 5, endCol: 999, url: "http://x")
        #expect(terminal.link(at: .buffer(Position(col: 9, row: 0)), mode: .explicitOnly) == "http://x")
        #expect(terminal.link(at: .buffer(Position(col: 4, row: 0)), mode: .explicitOnly) == nil)
    }

    @Test func testTagPlainTextLinkIgnoresInvertedRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "0123456789")

        // startCol > endCol: a no-op, not a crash.
        terminal.tagPlainTextLink(row: 0, startCol: 5, endCol: 2, url: "http://x")
        #expect(terminal.link(at: .buffer(Position(col: 3, row: 0)), mode: .explicitOnly) == nil)
    }
}
