//
//  ScrollbackAllocationTests.swift
//
//  A scrollback size is a ceiling, not an allocation: the buffer makes a
//  line when output (or a read) first needs one. A resize used to make a
//  blank line for every slot up to the ceiling — the column loops and the
//  post-condition check walked `lines.maxLength`, and reading an empty slot
//  makes its line. With the 50 000 lines a host asks for, that was about
//  96 MB at 80 columns and tens of milliseconds on the first resize (the
//  keyboard coming up is one), before a line of history existed.
//

import Foundation
import Testing

@testable import SwiftTerm

final class ScrollbackAllocationTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// The lines the normal buffer has made, in use or not.
    private func allocated(_ t: Terminal) -> Int {
        t.normalBuffer.lines.getArray().reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    /// The normal buffer's text without the blank rows at its end.
    private func text(_ t: Terminal) -> [String] {
        var lines = String(decoding: t.getBufferAsData(kind: .normal), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    enum Resize: CustomStringConvertible {
        case rowsOnly, wider, narrower
        var description: String {
            switch self {
            case .rowsOnly: return "fewer rows (a keyboard coming up)"
            case .wider: return "more columns"
            case .narrower: return "fewer columns"
            }
        }
    }

    /// A hundred lines of output into a 50 000-line history, then one resize.
    @Test(arguments: [Resize.rowsOnly, .wider, .narrower])
    func aResizeMakesNoLinesForHistoryNobodyWrote(_ resize: Resize) {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 40))
        t.changeScrollback(50_000)
        for i in 0 ..< 100 {
            t.feed(text: "line \(i)\r\n")
        }
        let before = text(t)

        switch resize {
        case .rowsOnly: t.resize(cols: 80, rows: 30)
        case .wider: t.resize(cols: 120, rows: 40)
        case .narrower: t.resize(cols: 60, rows: 40)
        }

        #expect(allocated(t) < 1_000,
                "\(allocated(t)) lines made for \(t.normalBuffer.lines.count) in use")
        #expect(text(t) == before, "the resize changed the text")
        let buffer = t.normalBuffer
        let narrow = (0 ..< buffer.lines.count).filter { buffer.lines[$0].count < t.cols }
        #expect(narrow.isEmpty, "lines narrower than the \(t.cols) columns: \(narrow.prefix(5))")
    }

    /// A terminal built with a large history resizes once while it sets
    /// itself up.
    @Test func aTerminalBuiltWithALargeHistoryMakesOnlyItsScreen() {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 40, scrollback: 50_000))
        #expect(allocated(t) < 1_000, "\(allocated(t)) lines made for a screen of \(t.rows)")
    }

    /// Lines made after a resize — new output, and the history filling up
    /// past what was there — have the width the buffer has then.
    @Test func linesMadeAfterAResizeHaveTheNewWidth() {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 10))
        t.changeScrollback(5_000)
        for i in 0 ..< 50 {
            t.feed(text: "before \(i)\r\n")
        }
        t.resize(cols: 100, rows: 10)
        for i in 0 ..< 300 {
            t.feed(text: "after \(i) " + String(repeating: "x", count: 85) + "\r\n")
        }

        let buffer = t.normalBuffer
        let narrow = (0 ..< buffer.lines.count).filter { buffer.lines[$0].count < 100 }
        #expect(narrow.isEmpty, "lines narrower than 100 columns: \(narrow.prefix(5))")
        let last = text(t).last
        #expect(last == "after 299 " + String(repeating: "x", count: 85), "\(last ?? "nothing")")
    }
}
