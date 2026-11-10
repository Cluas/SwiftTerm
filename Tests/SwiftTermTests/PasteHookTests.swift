//
//  PasteHookTests.swift
//
//  A paste can be taken over by the host (`pasteRequested(source:text:)`).
//  The view's own answer to "bracketed or not" is the local emulator's
//  `bracketedPasteMode`, which a host rendering a multiplexer's view of a pane
//  never sees the program turn on — a multi-line paste then ran line by
//  line. The iOS view takes the same hook (and sends its own paste in one
//  write); only the macOS one is built here.
//

#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

struct PasteHookTests {
    /// Records what reaches the remote; says nothing about pastes, so it gets
    /// the default.
    final class Remote: TerminalViewDelegate {
        var writes: [[UInt8]] = []
        var text: String { String(decoding: writes.joined(), as: UTF8.self) }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { writes.append(Array(data)) }
        func scrolled(source: TerminalView, position: Double) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// A host that delivers pastes itself. Its own conformance, not a
    /// subclass of `Remote`: a subclass method does not replace the
    /// protocol's default that the superclass conformance already chose.
    final class PastingHost: TerminalViewDelegate {
        var writes: [[UInt8]] = []
        var pasted: [String] = []
        func pasteRequested(source: TerminalView, text: String) -> Bool {
            pasted.append(text)
            return true
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { writes.append(Array(data)) }
        func scrolled(source: TerminalView, position: Double) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @MainActor
    @Test func aHostCanTakeThePasteOver() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let host = PastingHost()
        view.terminalDelegate = host

        view.paste(text: "first line\nsecond line")

        #expect(host.pasted == ["first line\nsecond line"])
        #expect(host.writes.isEmpty, "the view sent the paste as well: \(host.writes)")
    }

    @MainActor
    @Test func withoutTheHostThePasteFollowsTheTerminalsMode() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let remote = Remote()
        view.terminalDelegate = remote

        view.paste(text: "a\nb")
        #expect(remote.text == "a\nb")

        remote.writes = []
        view.terminal.feed(text: "\u{1b}[?2004h")
        view.paste(text: "a\nb")
        #expect(remote.text == "\u{1b}[200~a\nb\u{1b}[201~")
    }
}
#endif
