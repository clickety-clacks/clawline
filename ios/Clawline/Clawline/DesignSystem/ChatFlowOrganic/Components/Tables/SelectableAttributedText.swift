import SwiftUI
import UIKit

struct SelectableAttributedText: UIViewRepresentable {
    var attributedString: NSAttributedString
    var alignment: NSTextAlignment
    var colorScheme: ColorScheme
    var selectionResetToken: Int = 0
    var onSelectionChange: (Bool) -> Void
    var onLinkTap: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange, onLinkTap: onLinkTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = TraitResponsiveTextView()
        UnifiedMarkdownRenderer.configureTextView(
            textView,
            delegate: context.coordinator,
            enableDataDetectors: false
        )
        textView.textContainer.widthTracksTextView = true
        textView.adjustsFontForContentSizeCategory = true
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTextHover(_:)))
        textView.addGestureRecognizer(hover)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let fingerprint = ClawlineCatalystProfileInstrumentation.attributedTextFingerprint(attributedString)
        let interval = ClawlineCatalystProfileInstrumentation.beginInterval(
            "SelectableAttributedText.updateUIView",
            "count=\(context.coordinator.recordUpdate()) length=\(attributedString.length) fingerprint=\(fingerprint)"
        )
        defer {
            ClawlineCatalystProfileInstrumentation.endInterval(
                "SelectableAttributedText.updateUIView",
                interval,
                "assigned=\(context.coordinator.lastAttributedTextAssignment)"
            )
        }
        context.coordinator.isUpdatingFromSwiftUI = true
        defer { context.coordinator.isUpdatingFromSwiftUI = false }

        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        if uiView.overrideUserInterfaceStyle != style {
            uiView.overrideUserInterfaceStyle = style
        }
        let shouldAssignAttributedText = Self.needsAttributedTextUpdate(current: uiView.attributedText, next: attributedString)
        context.coordinator.lastAttributedTextAssignment = shouldAssignAttributedText
        ClawlineCatalystProfileInstrumentation.event(
            "SelectableAttributedText.attributedTextAssignment",
            "assigned=\(shouldAssignAttributedText) fingerprint=\(fingerprint)"
        )
        if shouldAssignAttributedText {
            uiView.attributedText = attributedString
        }
        uiView.textAlignment = alignment
        if context.coordinator.consumeSelectionResetToken(selectionResetToken) {
            context.coordinator.invalidateDeferredSelectionChanges()
            if uiView.selectedRange.length > 0 {
                uiView.selectedRange = NSRange(location: uiView.selectedRange.location, length: 0)
            }
            context.coordinator.emitSelectionChange(false)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let interval = ClawlineCatalystProfileInstrumentation.beginInterval(
            "SelectableAttributedText.sizeThatFits",
            "count=\(context.coordinator.recordSizeThatFits()) width=\(width)"
        )
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        ClawlineCatalystProfileInstrumentation.endInterval(
            "SelectableAttributedText.sizeThatFits",
            interval,
            "height=\(ceil(fitting.height))"
        )
        return CGSize(width: width, height: ceil(fitting.height))
    }

    private final class TraitResponsiveTextView: UITextView {
        private var traitObservation: (any NSObjectProtocol)?

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            registerColorTraitObservation()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerColorTraitObservation()
        }

        private func registerColorTraitObservation() {
            traitObservation = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: TraitResponsiveTextView, previousTraitCollection: UITraitCollection) in
                guard let self else { return }
                guard self.traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
                self.refreshAttributedTextForCurrentTraits()
            }
        }

        private func refreshAttributedTextForCurrentTraits() {
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

    static func needsAttributedTextUpdate(current: NSAttributedString?, next: NSAttributedString) -> Bool {
        guard let current else { return true }
        return !current.isEqual(to: next)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let onSelectionChange: (Bool) -> Void
        private let onLinkTap: (URL) -> Void
        var isUpdatingFromSwiftUI = false
        var lastAttributedTextAssignment = false
        private var lastHasSelection: Bool?
        private var lastSelectionResetToken: Int?
        private var deferredSelectionChangeGeneration = 0
        private var updateCount = 0
        private var sizeThatFitsCount = 0

        init(onSelectionChange: @escaping (Bool) -> Void, onLinkTap: @escaping (URL) -> Void) {
            self.onSelectionChange = onSelectionChange
            self.onLinkTap = onLinkTap
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let hasSelection = textView.selectedRange.length > 0
            if isUpdatingFromSwiftUI {
                guard !hasSelection else { return }
                let generation = deferredSelectionChangeGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == deferredSelectionChangeGeneration else { return }
                    emitSelectionChange(hasSelection)
                }
                return
            }
            emitSelectionChange(hasSelection)
        }

        func recordUpdate() -> Int {
            updateCount += 1
            return updateCount
        }

        func recordSizeThatFits() -> Int {
            sizeThatFitsCount += 1
            return sizeThatFitsCount
        }

        @available(iOS 17.0, macCatalyst 17.0, visionOS 1.0, *)
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            UnifiedMarkdownRenderer.primaryActionForTextItem(
                textItem,
                defaultAction: defaultAction,
                openURL: { url, characterRange in
                    if TextLinkURLTemplateRules.isGeneratedLink(in: textView.attributedText, characterRange: characterRange) {
                        _ = GeneratedTextLinkActivationRouter.activateGeneratedLinkTap(
                            url,
                            displayMode: TextLinkURLTemplateRules.displayMode(in: textView.attributedText, characterRange: characterRange),
                            from: textView
                        )
                        return
                    }
                    self.onLinkTap(url)
                }
            )
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard TextLinkURLTemplateRules.isGeneratedLink(in: textView.attributedText, characterRange: characterRange) else {
                return true
            }
            _ = GeneratedTextLinkActivationRouter.activateGeneratedLinkTap(
                URL,
                displayMode: TextLinkURLTemplateRules.displayMode(in: textView.attributedText, characterRange: characterRange),
                from: textView
            )
            return false
        }

        @objc func handleTextHover(_ recognizer: UIHoverGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed,
                  let textView = recognizer.view as? UITextView else {
                return
            }
            _ = MessageBubbleUIKitView.presentGeneratedTextLinkPopupForHover(in: textView, at: recognizer.location(in: textView))
        }

        func consumeSelectionResetToken(_ token: Int) -> Bool {
            defer { lastSelectionResetToken = token }
            guard let lastSelectionResetToken else { return token != 0 }
            return lastSelectionResetToken != token
        }

        func emitSelectionChange(_ hasSelection: Bool) {
            guard lastHasSelection != hasSelection else { return }
            lastHasSelection = hasSelection
            onSelectionChange(hasSelection)
        }

        func invalidateDeferredSelectionChanges() {
            deferredSelectionChangeGeneration += 1
        }
    }
}
