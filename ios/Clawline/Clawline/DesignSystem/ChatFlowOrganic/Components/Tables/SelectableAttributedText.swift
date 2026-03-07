import SwiftUI
import UIKit

struct SelectableAttributedText: UIViewRepresentable {
    var attributedString: NSAttributedString
    var alignment: NSTextAlignment
    var colorScheme: ColorScheme
    var onSelectionChange: (Bool) -> Void
    var onLinkTap: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange, onLinkTap: onLinkTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = TraitResponsiveTextView()
        UnifiedMarkdownRenderer.configureTextView(textView, delegate: context.coordinator)
        textView.textContainer.widthTracksTextView = true
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.isUpdatingFromSwiftUI = true
        defer { context.coordinator.isUpdatingFromSwiftUI = false }

        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        if uiView.overrideUserInterfaceStyle != style {
            uiView.overrideUserInterfaceStyle = style
        }
        uiView.attributedText = attributedString
        uiView.textAlignment = alignment
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitting.height))
    }

    private final class TraitResponsiveTextView: UITextView {
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            guard let previousTraitCollection else { return }
            guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }

            // TextKit can cache resolved run colors; reassigning forces it to resolve dynamic UIColor
            // attributes with the new trait collection.
            let selection = selectedRange
            let current = attributedText
            attributedText = current
            if selection.location + selection.length <= (attributedText?.length ?? 0) {
                selectedRange = selection
            }
            setNeedsDisplay()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let onSelectionChange: (Bool) -> Void
        private let onLinkTap: (URL) -> Void
        var isUpdatingFromSwiftUI = false
        private var lastHasSelection: Bool?

        init(onSelectionChange: @escaping (Bool) -> Void, onLinkTap: @escaping (URL) -> Void) {
            self.onSelectionChange = onSelectionChange
            self.onLinkTap = onLinkTap
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let hasSelection = textView.selectedRange.length > 0
            if isUpdatingFromSwiftUI {
                DispatchQueue.main.async { [weak self] in
                    self?.emitSelectionChange(hasSelection)
                }
                return
            }
            emitSelectionChange(hasSelection)
        }

        @available(iOS 17.0, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                onLinkTap(url)
                return nil
            }
            return defaultAction
        }

        private func emitSelectionChange(_ hasSelection: Bool) {
            guard lastHasSelection != hasSelection else { return }
            lastHasSelection = hasSelection
            onSelectionChange(hasSelection)
        }
    }
}
