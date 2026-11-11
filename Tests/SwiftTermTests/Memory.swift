//
//  Memory.swift - Ensures that an allocated terminal is deallocated, this is
// to make sure we do not regress when we use helper classes that might introduce
// a strong cycle.
//  
//
//  Created by Miguel de Icaza on 4/17/21.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class SwiftTermMemory {
    static var deinited = false
    static var terminalDeinited = false
    class SimpleTerminal: HeadlessTerminal {
        
        init (queue: DispatchQueue) {
            super.init (queue: queue, onEnd: { x in })
        }
        deinit {
            SwiftTermMemory.deinited = true
        }
    }
    
    class EmptyTerminalDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {
        }
    }
    class SubTerminal: Terminal {
        init (delegate: TerminalDelegate) {
            super.init(delegate: delegate)
        }
        
        deinit {
            SwiftTermMemory.terminalDeinited = true
        }
    }
    
    // This tests that the `Terminal` instance is not leaking
    @Test func testTerminal() {
        SwiftTermMemory.terminalDeinited = false
        func run () {
            let _ = SubTerminal (delegate: EmptyTerminalDelegate ())
        }
        run ()
        #expect(SwiftTermMemory.terminalDeinited == true)

    }
    
    func allocate (){
        let queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
        let h = SimpleTerminal(queue: queue)
        //h.terminal.close ()
        let _ = h.terminal
    }
    
    // This test ensures that we are not keeping any strong references
    // in the code that would prevent terminal containers from being released
    @Test func testMemory() {
        SwiftTermMemory.deinited = false
        allocate ()
        #expect(SwiftTermMemory.deinited == true)
    }

    /// A full reset — `ESC c` (what `reset` sends), the iOS view's Reset
    /// menu item — makes a fresh normal buffer. Its scroll callback held the
    /// terminal strongly (the one the initializer installs holds it weakly),
    /// and the terminal holds the buffer: after a single reset the terminal,
    /// its buffers and its history were never freed. No reset at all (`""`)
    /// is the control; DECCOLM, either way, used to be a full reset too.
    @Test(arguments: ["", "\u{1b}c", "\u{1b}[?3h", "\u{1b}[?3l"])
    func testTerminalIsFreedAfterAFullReset(_ reset: String) {
        let delegate = EmptyTerminalDelegate()
        weak var released: Terminal?
        do {
            let terminal = Terminal(delegate: delegate,
                                    options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
            released = terminal
            terminal.feed(text: "before\r\n")
            terminal.feed(text: reset)
            // The buffer the reset made still scrolls through the terminal.
            for i in 0 ..< 30 {
                terminal.feed(text: "after \(i)\r\n")
            }
            #expect(terminal.buffer.yBase > 0, "the output after the reset did not scroll")
        }
        #expect(released == nil, "the terminal outlived its last reference")
    }
}
#endif
