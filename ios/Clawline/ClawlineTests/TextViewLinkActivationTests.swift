import Foundation
import Testing
import UIKit
@testable import Clawline

struct TextViewLinkActivationTests {
    @Test("Unified markdown text view configuration keeps links selectable")
    @MainActor
    func unifiedMarkdownTextViewConfigurationKeepsLinksSelectable() {
        let textView = UITextView()

        UnifiedMarkdownRenderer.configureTextView(textView, delegate: nil, enableDataDetectors: false)

        #expect(textView.isUserInteractionEnabled)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.delegate == nil)
        #expect(textView.dataDetectorTypes.isEmpty)
    }
}
