import UIKit
import SwiftTerm
import Testing
import CoreText
@testable import Clawline

@MainActor
struct TerminalBubbleUIKitViewTests {
    @Test("T001: terminal sanitizer preserves control chords outside bracketed paste")
    func terminalInputSanitizerPreservesControlBytesOutsideBracketedPaste() {
        var sanitizer = TerminalInputSanitizer()
        let input: [UInt8] = [0x03, 0x13, 0x1A]

        let sanitized = sanitizer.sanitize(input[...])

        #expect(sanitized?.elementsEqual(input) == true)
    }

    @Test("T001: terminal sanitizer strips disallowed control bytes only inside bracketed paste")
    func terminalInputSanitizerStripsDisallowedPasteBytesInsideBracketedPaste() {
        var sanitizer = TerminalInputSanitizer()
        let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        let pastePayload: [UInt8] = [0x61, 0x13, 0x62, 0x03, 0x63]

        #expect(sanitizer.sanitize(pasteStart[...])?.elementsEqual(pasteStart) == true)
        #expect(sanitizer.sanitize(pastePayload[...])?.elementsEqual([0x61, 0x62, 0x63]) == true)
        #expect(sanitizer.sanitize(pasteEnd[...])?.elementsEqual(pasteEnd) == true)
    }

    @Test("T001: terminal bubble registers bundled Nerd Font faces")
    func terminalBubbleRegistersBundledNerdFontFaces() {
        TerminalBubbleUIKitView.registerBundledFonts()

        #expect(UIFont(name: "BlexMonoNFM", size: 14) != nil)
        #expect(UIFont(name: "BlexMonoNFM-Bold", size: 14) != nil)
        #expect(UIFont(name: "BlexMonoNFM-Italic", size: 14) != nil)
        #expect(UIFont(name: "BlexMonoNFM-BoldItalic", size: 14) != nil)
    }

    @Test("T001: bundled terminal faces expose Nerd Font glyphs through CoreText")
    func terminalBubbleBundledFontsExposeNerdGlyphs() {
        TerminalBubbleUIKitView.registerBundledFonts()

        let fontNames = [
            "BlexMonoNFM",
            "BlexMonoNFM-Bold",
            "BlexMonoNFM-Italic",
            "BlexMonoNFM-BoldItalic"
        ]
        let sampleScalars: [UnicodeScalar] = [
            "\u{E0B0}",
            "\u{E0B6}",
            "\u{F0E7}"
        ]

        for fontName in fontNames {
            guard let font = UIFont(name: fontName, size: 14) else {
                Issue.record("Missing expected font \(fontName)")
                continue
            }

            let ctFont = font as CTFont
            for scalar in sampleScalars {
                var utf16 = [UniChar(scalar.utf16.first ?? 0)]
                var glyph = CGGlyph()
                let hasGlyph = CTFontGetGlyphsForCharacters(ctFont, &utf16, &glyph, 1)
                #expect(hasGlyph)
                #expect(glyph != 0)
            }

            let attributed = NSAttributedString(
                string: String(sampleScalars.map(Character.init)),
                attributes: [.font: font]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            #expect(!runs.isEmpty)

            for run in runs {
                let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let runFont = runAttributes[.font] as? UIFont
                #expect(runFont?.fontName == font.fontName)

                let glyphCount = CTRunGetGlyphCount(run)
                let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: glyphCount) { bufferPointer, count in
                    CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                    count = glyphCount
                }
                #expect(!runGlyphs.isEmpty)
                #expect(runGlyphs.allSatisfy { $0 != 0 })
            }
        }
    }

    @Test("T001: terminal bubble reserves one row less than SwiftTerm reports")
    func terminalBubbleVisibleRowsClampReportedRowsByOne() {
        #expect(TerminalBubbleUIKitView.visibleRows(forReportedRows: 24) == 23)
        #expect(TerminalBubbleUIKitView.visibleRows(forReportedRows: 2) == 1)
        #expect(TerminalBubbleUIKitView.visibleRows(forReportedRows: 1) == 1)
    }

    @Test("T001: terminal bubble renders without close or expand buttons and fills its bubble height")
    func terminalBubbleHasNoChromeButtonsAndTerminalMatchesBounds() {
        let view = TerminalBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.configure(
            descriptor: sampleDescriptor(),
            style: .bubble(height: 240),
            context: .init(messageId: "message-test", slotIndex: 0, source: .bubble)
        )
        view.layoutIfNeeded()

        let buttonTitles = allSubviews(in: view).compactMap { ($0 as? UIButton)?.currentTitle }
        #expect(!buttonTitles.contains("Expand"))
        #expect(!buttonTitles.contains("Close"))

        let terminalView = allSubviews(in: view).compactMap { $0 as? FocusableTerminalView }.first
        #expect(terminalView != nil)
        if let terminalView {
            #expect(terminalView.frame.integral == view.bounds.integral)
            #expect(terminalView.backgroundColor?.cgColor.alpha == 1)
            #expect(terminalView.backgroundColor != .clear)
            let foreground = terminalView.nativeForegroundColor
            let background = terminalView.nativeBackgroundColor
            #expect(relativeLuminance(foreground) > relativeLuminance(background))
            #expect(terminalView.font.fontName == "BlexMonoNFM")
        }
        #expect(view.backgroundColor?.cgColor.alpha == 1)
        #expect(view.backgroundColor != .clear)
    }

    private func sampleDescriptor() -> TerminalSessionDescriptor {
        TerminalSessionDescriptor(
            version: 1,
            terminalSessionId: "ts_test",
            title: "Terminal Bubble Test",
            provider: .init(baseUrl: "https://example.com", wsPath: "/ws/terminal"),
            capabilities: .init(
                interactive: true,
                supportsBinaryFrames: true,
                supportsResize: true,
                supportsDetach: true
            ),
            auth: .init(mode: .chatToken, terminalAccessToken: nil),
            expiresAtMs: nil
        )
    }

    private func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { self.allSubviews(in: $0) }
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }
}
