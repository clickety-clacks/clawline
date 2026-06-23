//
//  ExternalWebContentPolicy.swift
//  Clawline
//

import Foundation
import SafariServices
import UIKit
import WebKit

enum ExternalWebContentGeneratedLinkOpenRoute {
    case systemOpen
    case safariViewController
}

enum ExternalWebContentPolicy {
    static func shouldOpenInBrowserSurface(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), isLinkedInHost(host) else {
            return false
        }

        let path = url.path.lowercased()
        if path == "/login" || path.hasPrefix("/login/") {
            return true
        }
        if path == "/uas/login" || path.hasPrefix("/uas/login/") {
            return true
        }
        if path.hasPrefix("/checkpoint/") {
            return true
        }
        return false
    }

    @MainActor
    static func openBrowserSurface(for url: URL, from view: UIView?) {
        #if os(visionOS)
            UIApplication.shared.open(url)
        #else
            guard let presentingViewController = view?.clawlineParentViewController else {
                UIApplication.shared.open(url)
                return
            }
            presentingViewController.present(SFSafariViewController(url: url), animated: true)
        #endif
    }

    @MainActor
    static func openGeneratedLinkBrowserSurface(for url: URL, from view: UIView?) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            showGeneratedLinkFailure(from: view, message: "This generated link cannot be opened in Clawline.")
            return false
        }

        switch generatedLinkOpenRoute(isSpatial: isSpatialPlatform) {
        case .systemOpen:
            UIApplication.shared.open(url)
            return true
        case .safariViewController:
            guard let presentingViewController = view?.clawlineParentViewController else {
                showGeneratedLinkFailure(from: view, message: "Clawline could not present the generated link.")
                return false
            }
            presentingViewController.present(SFSafariViewController(url: url), animated: true)
            return true
        }
    }

    @MainActor
    private static func showGeneratedLinkFailure(from view: UIView?, message: String) {
        guard let presentingViewController = view?.clawlineParentViewController else {
            return
        }
        let alert = UIAlertController(
            title: "Generated Link Failed",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentingViewController.present(alert, animated: true)
    }

    private static func isLinkedInHost(_ host: String) -> Bool {
        host == "linkedin.com" || host.hasSuffix(".linkedin.com")
    }

    static func generatedLinkOpenRoute(isSpatial: Bool) -> ExternalWebContentGeneratedLinkOpenRoute {
        isSpatial ? .systemOpen : .safariViewController
    }

    private static var isSpatialPlatform: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }
}

enum GeneratedTextLinkActivationRouter {
    @MainActor
    static var openGeneratedLink: (URL, UIView?) -> Bool = { url, view in
        ExternalWebContentPolicy.openGeneratedLinkBrowserSurface(for: url, from: view)
    }

    @MainActor
    static var presentResolvedURLModal: (URL, UIView?) -> Bool = { url, view in
        guard let presenter = view?.clawlineParentViewController else { return false }
        let controller = TextLinkResolvedURLContentViewController(url: url, presentation: .modal)
        presenter.present(controller, animated: true)
        return true
    }

    @MainActor
    static var presentResolvedURLPopup: (URL, UIView?) -> Bool = { url, view in
        presentResolvedURLPopupAnchored(url, view, nil)
    }

    @MainActor
    static var presentResolvedURLPopupAnchored: (URL, UIView?, CGPoint?) -> Bool = { url, view, anchorPoint in
        presentResolvedURLPopupAtAnchor(url, from: view, anchorPoint: anchorPoint)
    }

    @MainActor
    static func presentResolvedURLPopupAtAnchor(_ url: URL, from view: UIView?, anchorPoint: CGPoint?) -> Bool {
        guard let presenter = view?.clawlineParentViewController else { return false }
        if let presented = presenter.presentedViewController as? TextLinkResolvedURLContentViewController {
            if presented.isPopup(for: url) {
                return true
            } else if presented.isPopupPresentation {
                let presenterAnchor = anchorPoint.map { view?.convert($0, to: presenter.view) ?? $0 }
                presented.updatePopup(url: url, anchorPoint: presenterAnchor)
                return true
            } else {
                return false
            }
        }
        let presenterAnchor = anchorPoint.map { view?.convert($0, to: presenter.view) ?? $0 }
        let controller = TextLinkResolvedURLContentViewController(
            url: url,
            presentation: .popup,
            anchorPoint: presenterAnchor
        )
        presenter.present(controller, animated: true)
        return true
    }

    @MainActor
    static func activateGeneratedLink(
        _ url: URL,
        displayMode: TextLinkResolvedURLDisplayMode,
        from view: UIView?
    ) -> Bool {
        activateGeneratedLinkTap(url, displayMode: displayMode, from: view)
    }

    @MainActor
    static func activateGeneratedLinkTap(
        _ url: URL,
        displayMode: TextLinkResolvedURLDisplayMode,
        from view: UIView?
    ) -> Bool {
        switch displayMode {
        case .direct:
            return openGeneratedLink(url, view)
        case .modal:
            return presentResolvedURLModal(url, view)
        case .popup:
            return false
        }
    }
}

extension UIView {
    var clawlineParentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

final class TextLinkResolvedURLContentViewController: UIViewController {
    enum Presentation {
        case modal
        case popup
    }

    private var url: URL
    private var presentation: Presentation
    private var anchorPoint: CGPoint?
    private let contentView = UIView()
    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSessionSharedResources.shared.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private let closeButton = UIButton(type: .system)
    private var popupHoverRecognizersInstalled = false

    var isPopupPresentation: Bool {
        presentation == .popup
    }

    func isPopup(for url: URL) -> Bool {
        presentation == .popup && self.url == url
    }

    func updatePopup(url: URL, anchorPoint: CGPoint?) {
        self.url = url
        self.presentation = .popup
        self.anchorPoint = anchorPoint
        guard isViewLoaded else { return }
        applyPresentationStyle()
        installPopupHoverRecognizers()
        webView.load(URLRequest(url: url))
        view.setNeedsLayout()
    }

    init(url: URL, presentation: Presentation, anchorPoint: CGPoint? = nil) {
        self.url = url
        self.presentation = presentation
        self.anchorPoint = anchorPoint
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.layer.cornerRadius = presentation == .modal ? 12 : 10
        contentView.layer.cornerCurve = .continuous
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = presentation == .modal ? 0.18 : 0.24
        contentView.layer.shadowRadius = presentation == .modal ? 22 : 16
        contentView.layer.shadowOffset = CGSize(width: 0, height: presentation == .modal ? 12 : 8)
        view.addSubview(contentView)

        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.layer.cornerRadius = presentation == .modal ? 12 : 10
        webView.layer.cornerCurve = .continuous
        webView.clipsToBounds = true
        webView.load(URLRequest(url: url))

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        closeButton.layer.cornerRadius = 18
        closeButton.layer.cornerCurve = .continuous
        closeButton.accessibilityLabel = "Close resolved URL"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        applyPresentationStyle()

        contentView.addSubview(webView)
        contentView.addSubview(closeButton)

        if presentation == .modal {
            let outsideTap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
            outsideTap.cancelsTouchesInView = false
            view.addGestureRecognizer(outsideTap)
        } else {
            installPopupHoverRecognizers()
        }
    }

    private func applyPresentationStyle() {
        view.backgroundColor = presentation == .modal ? UIColor.black.withAlphaComponent(0.36) : .clear
        contentView.backgroundColor = presentation == .modal ? .systemBackground : .clear
        closeButton.isHidden = presentation == .popup
    }

    private func installPopupHoverRecognizers() {
        guard !popupHoverRecognizersInstalled else { return }
        let rootHover = UIHoverGestureRecognizer(target: self, action: #selector(handlePopupHover(_:)))
        view.addGestureRecognizer(rootHover)
        let contentHover = UIHoverGestureRecognizer(target: self, action: #selector(handlePopupHover(_:)))
        contentView.addGestureRecognizer(contentHover)
        popupHoverRecognizersInstalled = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        let size: CGSize
        let origin: CGPoint
        switch presentation {
        case .modal:
            size = CGSize(width: safeFrame.width * 0.88, height: safeFrame.height * 0.82)
            origin = CGPoint(
                x: safeFrame.midX - size.width / 2,
                y: safeFrame.midY - size.height / 2
            )
        case .popup:
            let width = min(560, max(320, safeFrame.width * 0.62))
            let height = min(480, max(280, safeFrame.height * 0.55))
            size = CGSize(width: min(width, safeFrame.width - 36), height: min(height, safeFrame.height - 36))
            let rawAnchor = anchorPoint ?? CGPoint(x: safeFrame.midX, y: safeFrame.midY)
            let anchor = CGPoint(
                x: clamp(rawAnchor.x, min: safeFrame.minX + 18, max: safeFrame.maxX - 18),
                y: clamp(rawAnchor.y, min: safeFrame.minY + 18, max: safeFrame.maxY - 18)
            )
            origin = CGPoint(
                x: clamp(anchor.x - 24, min: safeFrame.minX + 18, max: safeFrame.maxX - size.width - 18),
                y: clamp(anchor.y - 24, min: safeFrame.minY + 18, max: safeFrame.maxY - size.height - 18)
            )
        }

        contentView.frame = CGRect(origin: origin, size: size)
        webView.frame = contentView.bounds
        closeButton.frame = CGRect(x: contentView.bounds.maxX - 48, y: 12, width: 36, height: 36)
    }

    @objc private func handleOutsideTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              !contentView.frame.contains(recognizer.location(in: view)) else {
            return
        }
        close()
    }

    @objc private func handlePopupHover(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: view)
        if recognizer.state == .changed,
           !contentView.frame.contains(location) {
            dismiss(animated: false)
            return
        }
        if (recognizer.state == .ended || recognizer.state == .cancelled),
           !contentView.frame.contains(location) {
            dismiss(animated: false)
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}
