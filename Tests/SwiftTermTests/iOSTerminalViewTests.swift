//
//  iOSTerminalViewTests.swift
//
//  The UIKit view. `swift test` on macOS does not build it; these run where
//  it does, on Mac Catalyst:
//
//    xcodebuild test -scheme SwiftTerm-Package \
//      -destination 'platform=macOS,variant=Mac Catalyst' \
//      -only-testing:SwiftTermTests/iOSTerminalViewTests
//

#if os(iOS)
import Foundation
import Testing
import UIKit

@testable import SwiftTerm

@MainActor
struct iOSTerminalViewTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                     font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    /// Lets the main queue run what is queued on it: a repaint the view
    /// queued holds the view until it has run (`queuePendingDisplay`).
    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Lifetime

    /// The display link held the view: a display link keeps its target, and
    /// the run loop keeps the link until it is invalidated, which only
    /// `updateUiClosed()` did. So every view ever made lived on with its
    /// terminal and its whole history (about 19 MB at 10 000 lines) after
    /// its host let it go: every closed pane.
    @Test func aViewItsHostLetsGoIsFreed() async {
        weak var view: TerminalView?
        weak var terminal: Terminal?
        do {
            let made = makeView()
            for i in 0 ..< 100 {
                made.feed(text: "line \(i)\r\n")
            }
            view = made
            terminal = made.getTerminal()
        }
        await drainMainQueue()

        #expect(view == nil, "the view outlived its last reference")
        #expect(terminal == nil, "the terminal outlived its view")
    }

    /// The same once the text system has asked for the view's tokenizer,
    /// which it does when the view takes the keyboard: the tokenizer must
    /// not hold the view either.
    @Test func aViewThatHadTheKeyboardIsFreed() async {
        weak var view: TerminalView?
        do {
            let made = makeView()
            _ = made.tokenizer
            made.feed(text: "hello\r\n")
            view = made
        }
        await drainMainQueue()

        #expect(view == nil, "the view outlived its last reference")
    }

    // MARK: - Text input traits

    /// The terminal's text input said nothing of what it is (a nil content
    /// type, "unknown"), and AutoFill guessed: on a Mac it tried to show a
    /// list of one-time codes at the terminal's caret. It names a type of
    /// its own now, none of the ones AutoFill fills.
    @Test func theTextInputIsNothingAutoFillFills() throws {
        let view = makeView()
        let type = try #require(view.textContentType, "no content type: AutoFill guesses")
        var filled: [UITextContentType] = [
            .username, .password, .newPassword, .oneTimeCode, .emailAddress, .telephoneNumber,
            .name, .givenName, .familyName, .fullStreetAddress, .postalCode, .URL, .creditCardNumber,
        ]
        if #available(iOS 17.0, *) {
            filled += [.creditCardSecurityCode, .birthdate]
        }
        #expect(!filled.contains(type), "\(type.rawValue)")
        #expect(!type.rawValue.isEmpty)
    }
}
#endif
