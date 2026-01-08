//
//  AuthManaging.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

@MainActor
protocol AuthManaging: AnyObject, Observable {
    var isAuthenticated: Bool { get }
    var currentUserId: String? { get }
    var token: String? { get }

    func storeCredentials(token: String, userId: String)
    func clearCredentials()
}
