import Testing
@testable import SwiftTerm

final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
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

    private func topLineText(from buffer: Buffer, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    @Test func testSynchronizedOutputBlocksDisplayUntilReset() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")

        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))
    }

    /// The lines a buffer has made, from copies or on a read.
    private func linesMade(_ buffer: Buffer) -> Int {
        buffer.lines.getArray().reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    private func text(_ buffer: Buffer, row: Int) -> String {
        buffer.translateBufferLineToString(lineIndex: row, trimRight: true)
    }

    /// The snapshot the view draws while an update is held back copied
    /// every line of the buffer, history and all, at every begin, and freed
    /// them all at the end: with Moshpit's 10 000 lines of history, several
    /// milliseconds of every frame of a program that redraws this way
    /// (Claude Code does, every frame). It copies the screen only, and the
    /// rows on display when the view is reading the history.
    @Test func testABeginCopiesTheScreenNotTheHistory() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 2_000)
        )
        for i in 0 ..< 1_000 {
            terminal.feed(text: "line \(i)\r\n")
        }

        terminal.feed(text: "\u{1b}[?2026h")
        let snapshot = terminal.displayBuffer

        #expect(snapshot !== terminal.buffer)
        #expect(linesMade(snapshot) == terminal.rows, "the begin copied \(linesMade(snapshot)) lines")
        #expect(snapshot.lines.count == terminal.buffer.lines.count, "numbered like the buffer")
        #expect(snapshot.yDisp == terminal.buffer.yDisp)

        // Reading the history.
        terminal.feed(text: "\u{1b}[?2026l")
        terminal.setViewYDisp(100)
        terminal.feed(text: "\u{1b}[?2026h")
        #expect(linesMade(terminal.displayBuffer) == 2 * terminal.rows,
                "the screen and the rows on display: \(linesMade(terminal.displayBuffer))")
        #expect(text(terminal.displayBuffer, row: 100) == "line 100")
        terminal.feed(text: "\u{1b}[?2026l")
    }

    /// While an update is held back the view can scroll into the history;
    /// those rows are read from the buffer when it asks, and are the text
    /// that was there when the update began — also when the update scrolled
    /// lines in and pushed the oldest out of a full history (those three are
    /// gone: they read blank until the update ends).
    @Test func testTheHistoryReadsTheSameWhileAnUpdateIsHeldBack() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 50)
        )
        for i in 0 ..< 100 {
            terminal.feed(text: "line \(i)\r\n")
        }
        #expect(terminal.buffer.lines.isFull)
        let before = (0 ..< terminal.buffer.lines.count).map { text(terminal.buffer, row: $0) }
        let screenTop = terminal.buffer.yBase

        terminal.feed(text: "\u{1b}[?2026h")
        terminal.feed(text: "new 1\r\nnew 2\r\nnew 3\r\n\u{1b}[HNEW TOP")

        let snapshot = terminal.displayBuffer
        #expect(text(snapshot, row: screenTop) == before[screenTop], "the held screen changed")
        terminal.setViewYDisp(10)
        for row in [3, 10, 11, 12, screenTop - 1] {
            #expect(text(snapshot, row: row) == before[row], "history row \(row)")
        }

        terminal.feed(text: "\u{1b}[?2026l")
        #expect(text(terminal.displayBuffer, row: terminal.buffer.yBase) == "NEW TOP")
    }
}
