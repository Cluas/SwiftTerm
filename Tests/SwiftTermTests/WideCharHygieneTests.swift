//
//  WideCharHygieneTests.swift
//
//  The write-side wide-char hygiene (overwriting half a fullwidth char must
//  clear the other half) and, critically, WHAT the cleared half is filled
//  with. Filling with the default-attribute Null punches a default-background
//  hole into whatever colored region the application was painting — and a
//  diff-rendering peer (mosh's framebuffer, Claude Code's renderer) that
//  believes the cell unchanged never repaints it, so the hole is permanent
//  and accumulates while scrolling ("滚动的时候样式乱了", 2026-08-19).
//  The clipped halves must instead be blanks carrying the OVERWRITING
//  write's attribute: that is the paint the application believes is there.
//

import Foundation
import Testing

@testable import SwiftTerm

final class WideCharHygieneTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func cell(_ t: Terminal, _ col: Int, _ row: Int) -> CharData {
        t.buffer.lines[t.buffer.yBase + row][col]
    }

    /// Blue-background bar containing a CJK char; a narrow char written over
    /// the LEAD (same blue paint, as a diff renderer would) must leave the
    /// orphaned continuation as a BLUE blank, not a default-background hole.
    @Test func overwritingLeadFillsStubWithWritersAttribute() {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        t.feed(text: "\u{1b}[44mAB中CD\u{1b}[0m")      // 中 occupies cols 2-3
        #expect(cell(t, 2, 0).width == 2)

        t.feed(text: "\u{1b}[1;3H\u{1b}[44mX")          // X over the lead at col 2
        #expect(cell(t, 2, 0).getCharacter() == "X")
        let stub = cell(t, 3, 0)
        #expect(stub.width == 1, "the orphaned continuation must be cleared")
        #expect(stub.attribute.bg == t.buffer.lines[t.buffer.yBase][2].attribute.bg,
                "the cleared half carries the overwriting write's paint (blue), not the default background")
    }

    /// Same for the other half: writing over the CONTINUATION clips the lead,
    /// which must also keep the writer's paint.
    @Test func overwritingStubFillsLeadWithWritersAttribute() {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        t.feed(text: "\u{1b}[44mAB中CD\u{1b}[0m")
        t.feed(text: "\u{1b}[1;4H\u{1b}[44mX")          // X over the continuation at col 3
        let lead = cell(t, 2, 0)
        #expect(lead.width == 1, "the clipped lead must be cleared")
        #expect(lead.attribute.bg == cell(t, 3, 0).attribute.bg,
                "the clipped lead carries the overwriting write's paint, not the default background")
    }

    /// A reverse-video write over a wide char must NOT leave an inverted
    /// blank — SwiftTerm models SGR 7 with the .defaultInvertedColor
    /// sentinel, and a cleared half carrying it renders as the bright block
    /// this hygiene exists to kill (caught by the mosh framebuffer replay).
    @Test func inverseWriterLeavesPlainBlank() {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        t.feed(text: "AB中CD")
        t.feed(text: "\u{1b}[1;3H\u{1b}[7mX\u{1b}[0m")   // inverse X over the lead
        let stub = cell(t, 3, 0)
        #expect(stub.width == 1)
        #expect(stub.attribute.bg == Attribute.Color.defaultColor,
                "the cleared half must not inherit the inverse sentinel")
    }

    /// The ASCII fast path takes the same care: a run written over a lead's
    /// continuation clips the lead with the run's attribute.
    @Test func asciiRunClipsWithRunAttribute() {
        let t = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        t.feed(text: "\u{1b}[44mAB中CD\u{1b}[0m")
        t.feed(text: "\u{1b}[1;4H\u{1b}[44mxyz")        // ASCII run from the continuation
        let lead = cell(t, 2, 0)
        #expect(lead.width == 1)
        #expect(lead.attribute.bg == cell(t, 3, 0).attribute.bg,
                "insertAsciiRun's clip must carry the run's paint too")
    }
}
