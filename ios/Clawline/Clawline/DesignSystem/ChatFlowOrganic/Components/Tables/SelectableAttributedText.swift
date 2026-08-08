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
        textView.onTextMetricsTraitChange = context.coordinator.invalidateMeasurementMemo
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
        context.coordinator.update(
            view: uiView,
            attributedString: attributedString,
            alignment: alignment,
            userInterfaceStyle: colorScheme == .dark ? .dark : .light,
            selectionResetToken: selectionResetToken
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return context.coordinator.measuredSize(width: width, using: uiView)
    }

    final class TraitResponsiveTextView: UITextView {
        var onTextMetricsTraitChange: (() -> Void)?

        private var colorTraitObservation: (any NSObjectProtocol)?
        private var textMetricsTraitObservation: (any NSObjectProtocol)?

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            registerTraitObservations()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerTraitObservations()
        }

        private func registerTraitObservations() {
            colorTraitObservation = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: TraitResponsiveTextView, previousTraitCollection: UITraitCollection) in
                guard let self else { return }
                guard self.traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
                self.refreshAttributedTextForCurrentTraits()
            }
            textMetricsTraitObservation = registerForTraitChanges([
                UITraitPreferredContentSizeCategory.self,
                UITraitLegibilityWeight.self,
            ]) { [weak self] (_: TraitResponsiveTextView, _: UITraitCollection) in
                self?.onTextMetricsTraitChange?()
            }
        }

        func refreshAttributedTextForCurrentTraits() {
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
        private static let measurementMemoCapacity = 8

        private let onSelectionChange: (Bool) -> Void
        private let onLinkTap: (URL) -> Void
        private var measurementMemo: [CGFloat: CGFloat] = [:]
        private(set) var lastSubmittedAttributedString: NSAttributedString?
        private var lastAppliedAlignment: NSTextAlignment?
        private(set) var measurementMissCount = 0
        var measurementMemoEntryCount: Int { measurementMemo.count }
        var isUpdatingFromSwiftUI = false
        private var lastHasSelection: Bool?
        private var lastSelectionResetToken: Int?
        private var deferredSelectionChangeGeneration = 0

        init(onSelectionChange: @escaping (Bool) -> Void, onLinkTap: @escaping (URL) -> Void) {
            self.onSelectionChange = onSelectionChange
            self.onLinkTap = onLinkTap
        }

        func measuredSize(width: CGFloat, using textView: UITextView) -> CGSize {
            if let height = measurementMemo[width] {
                return CGSize(width: width, height: height)
            }

            let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = ceil(fitting.height)
            if measurementMemo.count == Self.measurementMemoCapacity {
                invalidateMeasurementMemo()
            }
            measurementMemo[width] = height
            measurementMissCount += 1
            return CGSize(width: width, height: height)
        }

        func invalidateMeasurementMemo() {
            measurementMemo.removeAll()
        }

        func update(
            view uiView: UITextView,
            attributedString: NSAttributedString,
            alignment: NSTextAlignment,
            userInterfaceStyle: UIUserInterfaceStyle,
            selectionResetToken: Int
        ) {
            isUpdatingFromSwiftUI = true
            defer { isUpdatingFromSwiftUI = false }

            if uiView.overrideUserInterfaceStyle != userInterfaceStyle {
                uiView.overrideUserInterfaceStyle = userInterfaceStyle
            }
            if SelectableAttributedText.needsAttributedTextUpdate(
                current: lastSubmittedAttributedString,
                next: attributedString
            ) {
                uiView.attributedText = attributedString
                lastSubmittedAttributedString = NSAttributedString(attributedString: attributedString)
                invalidateMeasurementMemo()
            }
            if lastAppliedAlignment != alignment {
                uiView.textAlignment = alignment
                lastAppliedAlignment = alignment
                invalidateMeasurementMemo()
            }
            if consumeSelectionResetToken(selectionResetToken) {
                invalidateDeferredSelectionChanges()
                if uiView.selectedRange.length > 0 {
                    uiView.selectedRange = NSRange(location: uiView.selectedRange.location, length: 0)
                }
                emitSelectionChange(false)
            }
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
