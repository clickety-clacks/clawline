//
//  StreamPopupFocusCoordinator.swift
//  Clawline
//
//  T1136 chat-picker keyboard/focus architecture refactor.
//
//  Single authority for the chat stream popup's focus transaction. Owns the
//  presentation identity, the active focus transaction, dismissal reason,
//  search-focus acknowledgement, the dismissal-guard used to suppress
//  tap-through reopen, and any delayed composer-restore work.
//
//  See reports/chat-picker-keyboard-focus-architecture-critique-20260703.html
//  (S1, E1-E6) for the architectural rationale. All delayed callbacks verify
//  presentation identity before mutating focus, so a stale task from
//  presentation N cannot mutate presentation N+1.
//

import Foundation

/// Platform-aware policy that decides the chat popup's initial focus target
/// when it opens. Replaces the iOS-software-keyboard-only rule that incorrectly
/// gated Catalyst/hardware-keyboard autofocus.
///
/// On iOS/iPadOS touch-only contexts (no software keyboard visible, no hardware
/// keyboard attached), the popup must not summon the software keyboard solely
/// for its filter, so the target is `.idle`. On Catalyst, iPad-with-hardware-
/// keyboard, or any time the software keyboard is already visible, the filter
/// autofocuses to `.searchField`.
enum StreamPopupFocusPolicy {
    enum OpenFocusTarget: Equatable {
        /// Autofocus the popup filter text field.
        case searchField
        /// Leave focus untouched; do not summon the software keyboard solely
        /// for the filter. Named `.idle` (not `.none`) so it never collides
        /// with `Optional.none` in equality assertions.
        case idle
    }

    /// Decides the popup's initial focus target from the two independent signals
    /// that matter: whether the software keyboard is already visible (iOS handoff
    /// rule) and whether a hardware keyboard is attached (Catalyst / iPad rule).
    static func focusTargetOnOpen(
        isSoftwareKeyboardVisible: Bool,
        isHardwareKeyboardAvailable: Bool
    ) -> OpenFocusTarget {
        if isSoftwareKeyboardVisible || isHardwareKeyboardAvailable {
            return .searchField
        }
        return .idle
    }

    /// Convenience overload that mirrors the legacy `shouldFocusSearchOnOpen`
    /// shape for call sites that have not yet migrated to `OpenFocusTarget`.
    /// Preserves the original iOS-scoped rule when no hardware keyboard is present.
    static func shouldFocusSearchOnOpen(
        isSoftwareKeyboardVisible: Bool,
        isHardwareKeyboardAvailable: Bool
    ) -> Bool {
        focusTargetOnOpen(
            isSoftwareKeyboardVisible: isSoftwareKeyboardVisible,
            isHardwareKeyboardAvailable: isHardwareKeyboardAvailable
        ) == .searchField
    }
}

/// Single owner of popup focus state, keyed by presentation identity.
///
/// The coordinator is intentionally a small `@Observable` collaborator: ChatView
/// constructs it via `@State`, drives transitions through it, and reads derived
/// signals (`isDismissalInProgress`, `shouldSuppressDotsToggleReopen`,
/// `isShortcutOwnershipActive`, `activeFocusTarget`) back into child views. The
/// coordinator does not own UIKit state, does not call `becomeFirstResponder`,
/// and does not read keyboard geometry; it only owns the transaction record.
@MainActor
@Observable
final class StreamPopupFocusCoordinator {
    /// Reasons a popup presentation may end. They do not all restore focus the same way.
    enum DismissalReason: Equatable {
        /// User selected a chat row (touch or hardware-keyboard shortcut).
        case rowSelection
        /// SwiftUI-initiated dismissal through the popover binding (outside tap, swipe, etc.).
        case outsideTap
        /// User tapped the visible-dots indicator to toggle the popup closed.
        case dotsToggleClose
        /// Escape / cancel keyboard command.
        case escapeOrCancel
        /// Popup transitioned directly into the track picker surface.
        case trackPickerHandoff
        /// ChatView toreardown or programmatic route clear (no composer restoration).
        case programmaticClear
        /// Close path that did not identify a more specific reason. Behaves like
        /// `.rowSelection`/`.outsideTap` for composer restoration.
        case unspecified
    }

    /// One open presentation's focus state.
    /// `searchFocusAcknowledged` and `dismissalReason` mutate as the
    /// presentation progresses; the other fields are set at open time.
    struct Transaction: Equatable {
        let presentationID: UInt
        let focusTarget: StreamPopupFocusPolicy.OpenFocusTarget
        /// True only if the popup-opening focus handoff actually displaced the
        /// prompt composer for this presentation (software keyboard was up and
        /// the composer held text focus). Captured at open time and may be
        /// cleared during the presentation if the software keyboard is dismissed.
        var displacedComposerFocus: Bool
        /// True once the child search text field reported it became first
        /// responder for this presentation. Search-focus requested is not the
        /// same as search-focus applied.
        var searchFocusAcknowledged: Bool
        /// Set when dismissal begins for this presentation. Terminal: once set,
        /// further `recordDismissal` calls are ignored for the same presentation.
        var dismissalReason: DismissalReason?
    }

    /// The currently-open presentation, or nil if no presentation is open.
    private(set) var activeTransaction: Transaction?

    /// The most-recently-dismissed presentation. Used by delayed composer-restore
    /// callbacks that fire after `activeTransaction` has been cleared.
    private(set) var lastDismissedTransaction: Transaction?

    /// Presentation ID guarded against immediate dots-toggle reopen. Set when a
    /// dismissal begins; consumed (or expired) by `consumeReopenSuppressionIfActive()`.
    private(set) var dismissGuardPresentationID: UInt?
    private var dismissGuardSetAt: Date?

    /// Last software-keyboard visibility signal reported for the active presentation.
    /// The coordinator does not read keyboard geometry; ChatView reports this.
    private var lastReportedKeyboardVisibleDuringPresentation: Bool = false

    private var composerRestoreTask: Task<Void, Never>?
    private var keyboardDismissalDebounceTask: Task<Void, Never>?

    /// Window after dismissal during which a leaked anchor tap should be
    /// suppressed rather than treated as a fresh reopen. Matches a typical
    /// popover dismissal animation plus slack.
    static let dismissalReopenGuardInterval: TimeInterval = 0.4

    /// Debounce for transient keyboard-height changes during popup presentation.
    /// Mirrors the legacy 180 ms observation window so behavior is preserved.
    static let keyboardDismissalDebounceInterval: Duration = .milliseconds(180)

    var presentationID: UInt {
        activeTransaction?.presentationID ?? lastDismissedTransaction?.presentationID ?? 0
    }

    var hasActivePresentation: Bool {
        activeTransaction != nil
    }

    /// True only when the active presentation has begun dismissing. Used by
    /// ChatView's `MessageInputBar.onRequestFocus` handler to avoid re-entering
    /// `closeStreamPopup` when the dismissal path requests composer focus.
    var isDismissalInProgress: Bool {
        guard let txn = activeTransaction else { return false }
        return txn.dismissalReason != nil
    }

    var activeFocusTarget: StreamPopupFocusPolicy.OpenFocusTarget? {
        activeTransaction?.focusTarget
    }

    /// True if a dots-toggle reopen should be suppressed right now. The guard
    /// auto-expires after `dismissalReopenGuardInterval` so legitimate later
    /// taps to reopen are not blocked.
    var shouldSuppressDotsToggleReopen: Bool {
        guard let dismissGuardSetAt, dismissGuardPresentationID != nil else {
            return false
        }
        return Date().timeIntervalSince(dismissGuardSetAt) < Self.dismissalReopenGuardInterval
    }

    /// True only when the shortcut key-command bridge is permitted to take
    /// first responder. The bridge must stand down during dismissal and during
    /// composer restoration so it cannot opportunistically grab first
    /// responder from the search field or the composer.
    var isShortcutOwnershipActive: Bool {
        guard let txn = activeTransaction else { return false }
        return txn.dismissalReason == nil
    }

    /// Begins a new presentation. Cancels any pending composer restore from a
    /// prior presentation and clears the dismissal guard. Returns the new
    /// transaction so callers can pass its presentation ID to child views.
    @discardableResult
    func beginPresentation(
        focusTarget: StreamPopupFocusPolicy.OpenFocusTarget,
        displacedComposerFocus: Bool
    ) -> Transaction {
        cancelPendingComposerRestore()
        keyboardDismissalDebounceTask?.cancel()
        keyboardDismissalDebounceTask = nil
        let nextID = nextPresentationID()
        let txn = Transaction(
            presentationID: nextID,
            focusTarget: focusTarget,
            displacedComposerFocus: displacedComposerFocus,
            searchFocusAcknowledged: false,
            dismissalReason: nil
        )
        activeTransaction = txn
        dismissGuardPresentationID = nil
        dismissGuardSetAt = nil
        lastReportedKeyboardVisibleDuringPresentation = false
        return txn
    }

    /// Marks the active presentation as dismissing for the given reason.
    /// Dismissal is terminal per presentation: a second call for the same
    /// presentation is a no-op. Sets the dismissal reopen guard so a leaked
    /// anchor tap cannot immediately toggle the popup back open.
    /// Returns the dismissed presentation ID, or nil if no active presentation
    /// (or if the active presentation was already dismissing).
    @discardableResult
    func recordDismissal(reason: DismissalReason) -> UInt? {
        guard var txn = activeTransaction else { return nil }
        guard txn.dismissalReason == nil else { return nil }
        txn.dismissalReason = reason
        activeTransaction = txn
        dismissGuardPresentationID = txn.presentationID
        dismissGuardSetAt = Date()
        lastDismissedTransaction = txn
        return txn.presentationID
    }

    /// Clears the active transaction after SwiftUI has fully torn down the
    /// popover. Presentation-ID guarded so a stale teardown cannot clear a
    /// newer presentation. Does not cancel the composer-restore task, which
    /// may legitimately fire after teardown.
    func clearActivePresentation(presentationID: UInt) {
        guard let txn = activeTransaction, txn.presentationID == presentationID else { return }
        activeTransaction = nil
        keyboardDismissalDebounceTask?.cancel()
        keyboardDismissalDebounceTask = nil
    }

    /// Cancels any pending composer-focus restore. Used when ChatView tears down
    /// (onDisappear) or when a new presentation supersedes the prior one.
    func cancelPendingComposerRestore() {
        composerRestoreTask?.cancel()
        composerRestoreTask = nil
    }

    /// Consumer-side dismissal guard for the dots-toggle reopen path. Returns
    /// true (and consumes the guard) if a reopen-suppression was active; the
    /// caller should ignore the tap. Returns false if no suppression was
    /// active; the caller may proceed with reopening. Stale guards are cleared.
    func consumeReopenSuppressionIfActive() -> Bool {
        if shouldSuppressDotsToggleReopen {
            dismissGuardPresentationID = nil
            dismissGuardSetAt = nil
            return true
        }
        if dismissGuardPresentationID != nil {
            dismissGuardPresentationID = nil
            dismissGuardSetAt = nil
        }
        return false
    }

    /// Child views report that the search text field became first responder for
    /// the given presentation. Ignored if the presentation ID does not match
    /// the active transaction.
    func acknowledgeSearchFocusApplied(presentationID: UInt) {
        guard var txn = activeTransaction, txn.presentationID == presentationID else { return }
        guard txn.searchFocusAcknowledged != true else { return }
        txn.searchFocusAcknowledged = true
        activeTransaction = txn
    }

    /// Child views report that the search text field resigned first responder
    /// for the given presentation.
    func acknowledgeSearchFocusResigned(presentationID: UInt) {
        guard var txn = activeTransaction, txn.presentationID == presentationID else { return }
        guard txn.searchFocusAcknowledged != false else { return }
        txn.searchFocusAcknowledged = false
        activeTransaction = txn
    }

    /// Software-keyboard visibility signal reported by ChatView (which owns the
    /// keyboard geometry) for the active presentation. When the keyboard is
    /// dismissed during popup display, the displaced-composer-focus flag is
    /// cleared after a debounce so later dismissal does not restore composer
    /// focus (which would re-summon the keyboard). This preserves the legacy
    /// 180 ms observation window without making keyboard state both an input
    /// and an effect of the transition.
    func reconcileKeyboardVisibilityDuringPresentation(isVisible: Bool) {
        lastReportedKeyboardVisibleDuringPresentation = isVisible
        keyboardDismissalDebounceTask?.cancel()
        keyboardDismissalDebounceTask = nil
        guard let txn = activeTransaction, txn.dismissalReason == nil else { return }
        guard !isVisible else { return }
        keyboardDismissalDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: StreamPopupFocusCoordinator.keyboardDismissalDebounceInterval)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard let self else { return }
            guard var current = self.activeTransaction,
                  current.dismissalReason == nil,
                  self.lastReportedKeyboardVisibleDuringPresentation == false else { return }
            current.displacedComposerFocus = false
            self.activeTransaction = current
        }
    }

    /// Schedules composer focus restoration after dismissal. The closure only
    /// fires if the dismissed presentation still matches `presentationID` and
    /// composer focus was displaced by that presentation. Cancellation is
    /// automatic when a new presentation begins or when ChatView tears down.
    func scheduleComposerFocusRestore(
        forDismissedPresentationID presentationID: UInt,
        delay: Duration,
        onRestore: @MainActor @escaping () -> Void
    ) {
        cancelPendingComposerRestore()
        composerRestoreTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard let self else { return }
            // A new presentation has superseded the dismissed one: abort.
            guard self.activeTransaction == nil else { return }
            guard let dismissed = self.lastDismissedTransaction,
                  dismissed.presentationID == presentationID,
                  dismissed.dismissalReason != nil,
                  Self.shouldRestoreComposer(for: dismissed) else { return }
            onRestore()
        }
    }

    /// Policy: which dismissal reasons restore composer focus when the open
    /// presentation displaced it.
    static func shouldRestoreComposer(for txn: Transaction) -> Bool {
        switch txn.dismissalReason {
        case .rowSelection, .outsideTap, .dotsToggleClose, .escapeOrCancel, .unspecified:
            return txn.displacedComposerFocus
        case .trackPickerHandoff, .programmaticClear, .none:
            return false
        }
    }

    private func nextPresentationID() -> UInt {
        let lastID = activeTransaction?.presentationID ?? lastDismissedTransaction?.presentationID ?? 0
        return lastID &+ 1
    }
}
