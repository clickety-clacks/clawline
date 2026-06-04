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
