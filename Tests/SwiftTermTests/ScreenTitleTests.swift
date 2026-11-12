//
//  ScreenTitleTests.swift
//
//  screen's title sequence, ESC k <title> ST. A shell inside screen or tmux
//  names its window this way (oh-my-zsh does for every prompt and every
//  command), and the multiplexer eats it — but a tmux control-mode client
//  is handed a pane's bytes raw, so the sequence reaches this emulator.
//  It must be consumed, as tmux and screen do, not printed.
//
import Foundation
import Testing

@testable import SwiftTerm

final class ScreenTitleTests {
    private static func feed(_ text: String, cols: Int = 80, rows: Int = 24, chunk: Int = .max) -> Terminal {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows)
        let bytes = Array(text.utf8)
        var start = 0
        while start < bytes.count {
            let end = min(start + chunk, bytes.count)
            terminal.feed(byteArray: Array(bytes[start..<end]))
            start = end
        }
        return terminal
    }

    /// The visible rows without trailing blanks (written spaces included).
    private static func screen(_ terminal: Terminal) -> [String] {
        TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal).map {
            String($0.reversed().drop(while: { $0 == " " }).reversed())
        }
    }

    /// zsh's PROMPT_SP: a reverse-video `%`, a line's worth of spaces, and a
    /// carriage return.
    private static let promptSP = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
        + String(repeating: " ", count: 79) + "\u{D} \u{D}"

    /// The robbyrussell prompt in `~/demo`.
    private static let prompt = "\u{D}\u{1B}[0m\u{1B}[27m\u{1B}[24m\u{1B}[J\u{1B}[01;32m➜  \u{1B}[36mdemo\u{1B}[00m \u{1B}[K"
        + "\u{1B}[?1h\u{1B}=\u{1B}[?2004h"

    /// What a tmux 3.6a control-mode client received for one pane running
    /// zsh with oh-my-zsh (TERM=tmux-256color, so `title` uses ESC k): the
    /// `%output` payloads of `echo hello`, `ls` in an empty directory and
    /// `printf %s done`, octal escapes decoded. Each command line is named
    /// for its command before it runs and for the directory at the prompt.
    private static let ohMyZsh =
        "e\u{8}echo hello\u{1B}[?1l\u{1B}>\u{1B}[?2004l\u{D}\u{D}\u{A}" +
        "\u{1B}kecho\u{1B}\\hello\u{D}\u{A}" +
        promptSP + "\u{1B}k~/demo\u{1B}\\" + prompt +
        "l\u{8}ls\u{1B}[?1l\u{1B}>\u{1B}[?2004l\u{D}\u{D}\u{A}" +
        "\u{1B}kls\u{1B}\\" +
        promptSP + "\u{1B}k~/demo\u{1B}\\" + prompt +
        "p\u{8}printf %s done\u{1B}[?1l\u{1B}>\u{1B}[?2004l\u{D}\u{D}\u{A}" +
        "\u{1B}kprintf\u{1B}\\done" +
        promptSP + "\u{1B}k~/demo\u{1B}\\" + prompt

    private static let ohMyZshScreen = [
        "echo hello",
        "hello",
        "➜  demo ls",
        "➜  demo printf %s done",
        "done%",
        "➜  demo",
    ]

    @Test func ohMyZshTitlesAreNotPrinted() {
        let terminal = Self.feed(Self.ohMyZsh)
        #expect(Array(Self.screen(terminal).prefix(Self.ohMyZshScreen.count)) == Self.ohMyZshScreen)
        let rest = Self.screen(terminal).dropFirst(Self.ohMyZshScreen.count)
        #expect(rest.allSatisfy { $0.isEmpty })
        // The prompt's cursor: after "➜  demo ".
        TerminalTestHarness.assertCursor(terminal.buffer, col: 8, row: 5)
    }

    @Test func ohMyZshTitlesAreNotPrintedWhereverTheFeedsCut() {
        for chunk in [1, 2, 3, 5, 7, 64] {
            let terminal = Self.feed(Self.ohMyZsh, chunk: chunk)
            #expect(Array(Self.screen(terminal).prefix(Self.ohMyZshScreen.count)) == Self.ohMyZshScreen,
                    "feeds of \(chunk) bytes")
        }
    }

    @Test func aTitleIsConsumedWhateverItHolds() {
        // UTF-8 (➜ is e2 9e 9c: its last byte is C1 ST when read as 8-bit
        // controls, and must not end the title), CJK, a C0 control, DEL.
        let terminal = Self.feed("a\u{1B}k➜ 项目/文档 \u{1}x\u{7F}y\u{1B}\\b")
        #expect(Self.screen(terminal)[0] == "ab")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 0)
    }

    @Test func belEndsATitleAsInTmux() {
        let terminal = Self.feed("a\u{1B}kvim\u{7}b")
        #expect(Self.screen(terminal)[0] == "ab")
    }

    @Test func anEscapeEndsATitleAndStartsItsOwnSequence() {
        // tmux takes the title at the ESC whatever follows it; the ESC then
        // starts the next sequence, here a cursor move and an SGR.
        let terminal = Self.feed("a\u{1B}kvim\u{1B}[3;5Hb\u{1B}[1mc")
        #expect(Self.screen(terminal)[0] == "a")
        #expect(Self.screen(terminal)[2] == "    bc")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 6, row: 2)
    }

    @Test func cancelAbortsATitle() {
        let terminal = Self.feed("a\u{1B}kvim\u{18}b\u{1B}kx\u{1A}c")
        #expect(Self.screen(terminal)[0] == "abc")
    }

    @Test func anEmptyTitleIsConsumed() {
        let terminal = Self.feed("a\u{1B}k\u{1B}\\b")
        #expect(Self.screen(terminal)[0] == "ab")
    }

    @Test func otherEscapesAroundItStillWork() {
        // ESC j and ESC l (unused finals next to k) stay single-character
        // escapes, and SOS/PM strings are still consumed.
        let terminal = Self.feed("a\u{1B}jb\u{1B}lc\u{1B}Xsos\u{1B}\\d\u{1B}^pm\u{1B}\\e")
        #expect(Self.screen(terminal)[0] == "abcde")
    }
}
