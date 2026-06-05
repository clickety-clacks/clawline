//
//  ExternalWebContentPolicy.swift
//  Clawline
//

import Foundation
import SafariServices
import UIKit

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
        let alert = UIAlertController(title: "Resolved URL", message: url.absoluteString, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        presenter.present(alert, animated: true)
        return true
    }

    @MainActor
    static var presentResolvedURLPopup: (URL, UIView?) -> Bool = { url, view in
        guard let presenter = view?.clawlineParentViewController else { return false }
        let controller = TextLinkResolvedURLPopupViewController(url: url)
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        presenter.present(controller, animated: true)
        return true
    }

    @MainActor
    static func activateGeneratedLink(
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
            return presentResolvedURLPopup(url, view)
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

final class TextLinkResolvedURLPopupViewController: UIViewController {
    private let url: URL
    private let panelView = UIView()
    private let urlLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.black.withAlphaComponent(0.28)

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.backgroundColor = .secondarySystemBackground
        panelView.layer.cornerRadius = 20
        panelView.layer.cornerCurve = .continuous
        panelView.layer.shadowColor = UIColor.black.cgColor
        panelView.layer.shadowOpacity = 0.18
        panelView.layer.shadowRadius = 22
        panelView.layer.shadowOffset = CGSize(width: 0, height: 12)
        view.addSubview(panelView)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Resolved URL"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.text = url.absoluteString
        urlLabel.font = .preferredFont(forTextStyle: .body)
        urlLabel.adjustsFontForContentSizeCategory = true
        urlLabel.numberOfLines = 0
        urlLabel.lineBreakMode = .byCharWrapping
        urlLabel.textColor = .label

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.accessibilityLabel = "Close resolved URL popup"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        panelView.addSubview(titleLabel)
        panelView.addSubview(urlLabel)
        panelView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            panelView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            panelView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            panelView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            titleLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            urlLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -20),
            urlLabel.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -20),
        ])
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
