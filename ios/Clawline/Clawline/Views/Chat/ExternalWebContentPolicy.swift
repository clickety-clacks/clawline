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
        presentResolvedURLPopupAtAnchor(url, from: view, anchorPoint: nil)
    }

    @MainActor
    static func presentResolvedURLPopupAtAnchor(_ url: URL, from view: UIView?, anchorPoint: CGPoint?) -> Bool {
        guard let presenter = view?.clawlineParentViewController else { return false }
        if presenter.presentedViewController is TextLinkResolvedURLContentViewController {
            return true
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

    private let url: URL
    private let presentation: Presentation
    private let anchorPoint: CGPoint?
    private let panelView = UIView()
    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSessionSharedResources.shared.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private let closeButton = UIButton(type: .system)

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

        view.backgroundColor = UIColor.black.withAlphaComponent(presentation == .modal ? 0.36 : 0.08)

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.backgroundColor = .systemBackground
        panelView.layer.cornerRadius = 12
        panelView.layer.cornerCurve = .continuous
        panelView.layer.shadowColor = UIColor.black.cgColor
        panelView.layer.shadowOpacity = 0.18
        panelView.layer.shadowRadius = 22
        panelView.layer.shadowOffset = CGSize(width: 0, height: 12)
        view.addSubview(panelView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        closeButton.layer.cornerRadius = 18
        closeButton.layer.cornerCurve = .continuous
        closeButton.accessibilityLabel = "Close resolved URL"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.isHidden = presentation == .popup

        panelView.addSubview(webView)
        panelView.addSubview(closeButton)

        if presentation == .modal {
            let outsideTap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
            outsideTap.cancelsTouchesInView = false
            view.addGestureRecognizer(outsideTap)
        } else {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePopupHover(_:)))
            panelView.addGestureRecognizer(hover)
        }

        var constraints: [NSLayoutConstraint] = [
            panelView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            panelView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            panelView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            panelView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            panelView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            panelView.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: presentation == .modal ? 0.88 : 0.58),
            panelView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: presentation == .modal ? 0.82 : 0.52),

            webView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: panelView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ]
        if presentation == .popup, let anchorPoint {
            let anchoredTop = panelView.topAnchor.constraint(equalTo: view.topAnchor, constant: max(18, anchorPoint.y - 24))
            anchoredTop.priority = .defaultHigh
            constraints.append(anchoredTop)
        } else {
            constraints.append(panelView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func handleOutsideTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              !panelView.frame.contains(recognizer.location(in: view)) else {
            return
        }
        close()
    }

    @objc private func handlePopupHover(_ recognizer: UIHoverGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled {
            dismiss(animated: false)
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
