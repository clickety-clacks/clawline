import Foundation
import Testing
import UIKit
@testable import Clawline

struct TextViewLinkActivationTests {
    @Test("Rendered links keep URL attributes for UITextView activation")
    @MainActor
    func renderedLinksKeepURLAttributesForTextViewActivation() {
        let url = URL(string: "https://example.com/release-triggered-link")!
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "Open \(url.absoluteString)",
            baseFont: .systemFont(ofSize: 15),
            inkColor: .label,
            lineSpacing: 0
        )

        let link = rendered?.attribute(.link, at: "Open ".count, effectiveRange: nil) as? URL
        #expect(link == url)
    }

    @Test("Text views are configured for delegate-driven link activation")
    @MainActor
    func textViewsAreConfiguredForDelegateDrivenLinkActivation() {
        let delegate = TextViewDelegateProbe()
        let textView = UITextView()
        let linkTextAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.systemBlue
        ]

        UnifiedMarkdownRenderer.configureTextView(
            textView,
            delegate: delegate,
            linkTextAttributes: linkTextAttributes
        )

        #expect(textView.delegate === delegate)
        #expect(textView.isUserInteractionEnabled)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(!textView.isScrollEnabled)
        #expect(textView.dataDetectorTypes.isEmpty)
        #expect(textView.linkTextAttributes[.foregroundColor] as? UIColor == .systemBlue)
    }
}

private final class TextViewDelegateProbe: NSObject, UITextViewDelegate {}
