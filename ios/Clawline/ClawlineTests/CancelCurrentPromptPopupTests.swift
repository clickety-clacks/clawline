import Foundation
import Testing

struct CancelCurrentPromptPopupTests {
    @Test("T324 cancel popup uses a continuous body-tail material path")
    func cancelPopupUsesContinuousBodyTailMaterialPath() throws {
        let source = try Self.chatViewSource()
        let shapeSource = try Self.sourceSection(
            source,
            from: "private struct CancelCurrentPromptBubbleShape: Shape",
            to: "private struct PromptFocusShortcutModifier"
        )

        #expect(
            shapeSource.contains("var path = Path()"),
            "Cancel popup material should be drawn from one outline path."
        )
        #expect(
            !shapeSource.contains("Path(roundedRect: bodyRect"),
            "The rounded body must not be a separate path from the tail."
        )
        #expect(
            !shapeSource.contains("path.addPath(tail)"),
            "The tail must not be appended as a second subpath because that can render an internal seam."
        )
        #expect(
            !shapeSource.contains("bodyRect.minY + 1") && !shapeSource.contains("bodyRect.maxY - 1"),
            "The body-tail join should not rely on pixel overlap to hide the seam."
        )
        #expect(
            shapeSource.contains("path.addLine(to: tailTip)"),
            "The tail tip should be part of the same material outline as the popup body."
        )
    }

    private static func chatViewSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clawline/Views/Chat/ChatView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceSection(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            Issue.record("Unable to locate cancel prompt popup shape source.")
            return ""
        }
        return String(source[start..<end])
    }
}
