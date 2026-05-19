//
//  ExternalWebContentPolicy.swift
//  Clawline
//

import Foundation
import SafariServices
import UIKit

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

    private static func isLinkedInHost(_ host: String) -> Bool {
        host == "linkedin.com" || host.hasSuffix(".linkedin.com")
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
