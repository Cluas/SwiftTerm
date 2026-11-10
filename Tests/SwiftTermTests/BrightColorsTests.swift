//
//  BrightColorsTests.swift
//
//  `useBrightColors` decides how a cell in ANSI colors 8-15 is drawn: in the
//  bright color, or in the base color with a bold face. The view resolves
//  each attribute once and caches it, so the setting has to drop that cache
//  and repaint when it changes, or a change at run time shows nowhere. The
//  iOS view shares the code and the fix; only the macOS one is built here.
//

#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

struct BrightColorsTests {
    @MainActor
    @Test func turningBrightColorsOffAtRunTimeRedrawsInBold() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let brightRed = Attribute(fg: .ansi256(code: 9), bg: .defaultColor, style: .none)
        let before = view.getAttributes(brightRed, withUrl: false)
        #expect(before?[.font] as? NSFont == view.fontSet.normal)

        view.terminal.clearUpdateRange()
        view.useBrightColors = false

        let after = view.getAttributes(brightRed, withUrl: false)
        #expect(after?[.font] as? NSFont == view.fontSet.bold,
                "the attribute cached with bright colors on is still served")
        #expect(after?[.foregroundColor] as? NSColor
                == view.mapColor(color: .ansi256(code: 1), isFg: true, isBold: false, useBrightColors: false))
        let range = view.terminal.getUpdateRange()
        #expect(range.map { $0.startY <= 0 && $0.endY >= view.terminal.rows - 1 } == true,
                "every row has to repaint in the new colors")
    }

    @MainActor
    @Test func settingTheSameValueRepaintsNothing() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.terminal.clearUpdateRange()
        view.useBrightColors = true
        #expect(view.terminal.getUpdateRange() == nil)
    }
}
#endif
