//
//  MessageDetailAction.swift
//  Clawline
//
//  Cycle-3 Goal A, step 5. Click-to-detail bridge.
//
//  PROVENANCE / MERGE NOTE: Goal B (worktree clawline-cycle3-goalb-detail-viewer,
//  commit 94f47f75ab7, file Views/Detail/MessageDetailViewer.swift) owns the
//  canonical `openDetail` SwiftUI Environment action and the actual detail
//  viewer. That worktree is a separate, still-unmerged branch off the same
//  foundation this worktree builds on, so this file mirrors Goal B's exact
//  `MessageDetailAction` / `EnvironmentValues.openDetail` contract (struct
//  name, signature, default no-op) so Goal A's tap handlers compile and are
//  independently sim-verifiable today. At merge time, Goal B's declaration is
//  canonical -- this file should be DELETED, not kept alongside it.
//
//  Until that merge, the environment default is a no-op: Goal A never
//  presents its own detail view (explicit brief constraint -- "do not build
//  your own detail viewer"). MessageFlowCollectionView is UIKit, so the
//  hosting SwiftUI layer (ChatView) reads this environment action and passes
//  it down as a plain closure.
//

import SwiftUI

struct MessageDetailAction {
    private let handler: @MainActor (Message) -> Void

    init(handler: @escaping @MainActor (Message) -> Void) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction(for message: Message) {
        handler(message)
    }
}

private struct MessageDetailActionKey: EnvironmentKey {
    static let defaultValue = MessageDetailAction { _ in }
}

extension EnvironmentValues {
    var openDetail: MessageDetailAction {
        get { self[MessageDetailActionKey.self] }
        set { self[MessageDetailActionKey.self] = newValue }
    }
}
