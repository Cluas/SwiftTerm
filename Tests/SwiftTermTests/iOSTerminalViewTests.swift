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
#if targetEnvironment(macCatalyst)
import UIKit.UIGestureRecognizerSubclass
#endif

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

    // MARK: - The pointer

    /// Over the terminal the pointer is over text, and becomes the I-beam:
    /// the view's pointer interaction answers with a region, the whole view,
    /// and a style for it. It answered with no region, so the pointer stayed
    /// the system's default on an iPad's trackpad and on a Mac, and no
    /// interaction a host added further up was asked. (UIKit makes no region
    /// request a test can make: this asks the method the delegate's answer
    /// comes from. A Mac showing the I-beam cursor is checked by hand.)
    @available(iOS 13.4, *)
    @Test func thePointerOverTheTextHasARegionAndABeam() throws {
        let view = makeView()
        let interaction = try #require(view.interactions.compactMap { $0 as? UIPointerInteraction }.first)
        let whole = UIPointerRegion(rect: view.bounds)

        let region = view.pointerRegion(at: CGPoint(x: 20, y: 20), modifiers: [], defaultRegion: whole)

        #expect(region === whole, "no region: the system's default pointer over the text")
        let style = try #require(view.pointerInteraction(interaction, styleFor: whole))
        #expect(String(describing: style).contains("type = shape"), "\(style)")
    }

    #if targetEnvironment(macCatalyst)
    // MARK: - The pointer selects (Mac Catalyst)

    /// A drag a test can steer: where the pointer is, and how far the drag
    /// has got.
    final class SteeredPan: UIPanGestureRecognizer {
        var point = CGPoint.zero
        var steeredState: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { steeredState }
            set { steeredState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    /// The middle of the cell at `col`, `row` (screen rows).
    private func point(_ view: TerminalView, col: Int, row: Int) -> CGPoint {
        CGPoint(x: (CGFloat(col) + 0.5) * view.cellDimension.width,
                y: (CGFloat(row) + 0.5) * view.cellDimension.height + view.contentOffset.y)
    }

    /// On a Mac a click-drag selects, from where the button went down; it
    /// selected nothing (the scroll view's pan took the drag and dragged the
    /// history), and selection handles meant for a finger were offered.
    @Test func thePointersDragSelects() throws {
        let view = makeView()
        view.feed(text: "first line\r\nhello world")
        let drag = try #require(view.gestureRecognizers?.first { $0 is TerminalView.PointerDragRecognizer },
                                "nothing turns the pointer's drag into a selection")
        #expect(view.panGestureRecognizer.allowedTouchTypes.isEmpty,
                "the scroll view's pan still takes the pointer's drag")
        _ = drag

        let steer = SteeredPan(target: nil, action: nil)
        steer.point = point(view, col: 0, row: 1)
        steer.state = .began
        view.pointerSelectionDrag(steer)
        steer.point = point(view, col: 5, row: 1)
        steer.state = .changed
        view.pointerSelectionDrag(steer)

        #expect(view.getSelection() == "hello")
    }

    /// No handles: the pointer drags the selection.
    @Test func aSelectionOnAMacHasNoHandlesToDrag() {
        let view = makeView()
        view.enableSelectionPanGesture()
        #expect(view.panSelectionGesture == nil)
    }
    #endif

    // MARK: - Tab

    /// What the view sends its host.
    final class Host: NSObject, TerminalViewDelegate {
        var sent: [[UInt8]] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// The terminal takes Tab itself; as a stop of UIKit's keyboard focus,
    /// Tab also moved the focus on, and the keyboard with it (a Mac, G4).
    @Test func theTerminalIsNoStopOfTheKeyboardFocus() {
        #expect(!makeView().canBecomeFocused)
    }

    #if targetEnvironment(macCatalyst)
    /// On a Mac with the app active, Tab and Shift-Tab come as AppKit's
    /// commands, not presses; answered, they are the keys' bytes, and the
    /// commands go nowhere else (AppKit's own Tab moved the focus).
    @Test func tabAndShiftTabAsMacCommandsReachTheRemote() {
        let view = makeView()
        let host = Host()
        view.terminalDelegate = host
        #expect(view.canPerformAction(NSSelectorFromString("insertTab:"), withSender: nil))
        #expect(view.canPerformAction(NSSelectorFromString("insertBacktab:"), withSender: nil))

        view.insertTab(nil)
        view.insertBacktab(nil)

        #expect(host.sent == [[9], [0x1b, 0x5b, 0x5a]])
    }

    /// With the app active the keyboard focus took Shift-Tab: the view's key
    /// commands for Tab and Shift-Tab come before the system's own use of
    /// them.
    @Test func theMacsOwnKeysComeToTheViewFirst() throws {
        let commands = makeView().keyCommands ?? []
        func command(_ input: String, _ flags: UIKeyModifierFlags) -> UIKeyCommand? {
            commands.first { $0.input == input && $0.modifierFlags == flags }
        }
        for (input, flags) in [("\t", UIKeyModifierFlags()), ("\t", .shift)] {
            let found = try #require(command(input, flags), "no key command for \(input.debugDescription) \(flags.rawValue)")
            #expect(found.wantsPriorityOverSystemBehavior)
        }
    }

    /// With the kitty keyboard protocol on, as a press would be encoded.
    @Test func tabAsAMacCommandSpeaksTheKittyProtocolWhenItIsOn() {
        let view = makeView()
        let host = Host()
        view.terminalDelegate = host
        view.feed(text: "\u{1b}[>1u")
        host.sent = []

        view.insertBacktab(nil)

        #expect(host.sent == [Array("\u{1b}[9;2u".utf8)])
    }
    #endif

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
