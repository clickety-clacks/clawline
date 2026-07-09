//
//  StreamPopupFocusCoordinatorTests.swift
//  ClawlineTests
//
//  T1136 chat-picker keyboard/focus architecture refactor.
//  Covers the real UI races the architecture critique (F1-F6) identified:
//  the per-presentation transaction, dismissal idempotency, the tap-through
//  reopen guard, the reentrant composer-focus close path, child focus
//  reporting, and platform-aware open policy. See
//  reports/chat-picker-keyboard-focus-architecture-critique-20260703.html.
//

import Testing
import Foundation
@testable import Clawline

@MainActor
struct StreamPopupFocusCoordinatorTests {
    @Test("R1136-ARCH-04: beginPresentation assigns a fresh presentation ID and clears stale state")
    func beginPresentationAssignsFreshPresentationID() {
        let coordinator = StreamPopupFocusCoordinator()

        let first = coordinator.beginPresentation(
            focusTarget: .searchField,
            displacedComposerFocus: true
        )
        #expect(coordinator.hasActivePresentation)
        #expect(coordinator.activeFocusTarget == .searchField)
        #expect(coordinator.presentationID == first.presentationID)
        #expect(first.searchFocusAcknowledged == false)
        #expect(first.dismissalReason == nil)

        let second = coordinator.beginPresentation(
            focusTarget: .idle,
            displacedComposerFocus: false
        )
        #expect(second.presentationID > first.presentationID)
        #expect(coordinator.presentationID == second.presentationID)
        #expect(coordinator.activeFocusTarget == .some(.idle))
    }

    @Test("R1136-ARCH-05: recordDismissal is terminal per presentation")
    func recordDismissalIsTerminalPerPresentation() async {
        let coordinator = StreamPopupFocusCoordinator()

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        let firstID = coordinator.recordDismissal(reason: .dotsToggleClose)
        #expect(firstID != nil)
        #expect(coordinator.isDismissalInProgress)

        // A second dismissal for the same presentation is a no-op.
        let secondID = coordinator.recordDismissal(reason: .outsideTap)
        #expect(secondID == nil)
        #expect(coordinator.lastDismissedTransaction?.dismissalReason == .dotsToggleClose)
    }

    @Test("R1136-ARCH-02: reentrant composer-focus close path is blocked by isDismissalInProgress")
    func reentrantClosePathIsBlocked() {
        let coordinator = StreamPopupFocusCoordinator()

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        // First dismissal starts (e.g., dots-toggle close).
        _ = coordinator.recordDismissal(reason: .dotsToggleClose)
        #expect(coordinator.isDismissalInProgress)

        // The composer-focus path now sees dismissal in progress and must
        // NOT re-enter close. recordDismissal returns nil, so the caller can
        // branch on that (or read isDismissalInProgress directly).
        let reentrant = coordinator.recordDismissal(reason: .unspecified)
        #expect(reentrant == nil)
    }

    @Test("R1136-ARCH-03: dismissal sets a reopen guard that absorbs one leaked anchor tap")
    func dismissalGuardAbsorbsOneLeakedAnchorTap() {
        let coordinator = StreamPopupFocusCoordinator()

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        #expect(coordinator.shouldSuppressDotsToggleReopen == false)
        #expect(coordinator.consumeReopenSuppressionIfActive() == false)

        _ = coordinator.recordDismissal(reason: .dotsToggleClose)
        #expect(coordinator.shouldSuppressDotsToggleReopen)

        // The leaked reopen tap is suppressed and the guard is consumed.
        #expect(coordinator.consumeReopenSuppressionIfActive())
        // A second tap is no longer suppressed — legitimate reopen works.
        #expect(coordinator.consumeReopenSuppressionIfActive() == false)
    }

    @Test("R1136-ARCH-03: dismissal reopen guard is cleared when a new presentation begins")
    func dismissalGuardClearedOnNewPresentation() {
        let coordinator = StreamPopupFocusCoordinator()

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        _ = coordinator.recordDismissal(reason: .outsideTap)
        #expect(coordinator.shouldSuppressDotsToggleReopen)

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        #expect(coordinator.shouldSuppressDotsToggleReopen == false)
    }

    @Test("R1136-ARCH-03: dismissal reopen guard auto-expires so legitimate later opens work")
    func dismissalGuardAutoExpires() async {
        let coordinator = StreamPopupFocusCoordinator()

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        _ = coordinator.recordDismissal(reason: .outsideTap)

        // Advance beyond the guard interval without performing a reopen tap.
        try? await Task.sleep(for: .milliseconds(Int(StreamPopupFocusCoordinator.dismissalReopenGuardInterval * 1000) + 50))

        // The guard is now stale; consumeReopenSuppressionIfActive returns false
        // and clears the stale state so subsequent opens proceed normally.
        #expect(coordinator.consumeReopenSuppressionIfActive() == false)
        #expect(coordinator.shouldSuppressDotsToggleReopen == false)
    }

    @Test("R1136-ARCH-05: clearActivePresentation is presentation-ID guarded")
    func clearActivePresentationIsGuarded() {
        let coordinator = StreamPopupFocusCoordinator()

        let txn = coordinator.beginPresentation(focusTarget: .idle, displacedComposerFocus: false)
        // Wrong presentation ID — no-op.
        coordinator.clearActivePresentation(presentationID: txn.presentationID &+ 99)
        #expect(coordinator.hasActivePresentation)

        // Correct presentation ID — clears.
        coordinator.clearActivePresentation(presentationID: txn.presentationID)
        #expect(coordinator.hasActivePresentation == false)
    }

    @Test("R1136-ARCH-06: child focus reports update the active transaction only for matching presentation")
    func childFocusReportsUpdateMatchingPresentationOnly() {
        let coordinator = StreamPopupFocusCoordinator()

        let first = coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        coordinator.acknowledgeSearchFocusApplied(presentationID: first.presentationID)
        #expect(coordinator.activeTransaction?.searchFocusAcknowledged == true)

        // A stale report for an older presentation ID is ignored.
        coordinator.acknowledgeSearchFocusResigned(presentationID: first.presentationID &- 1)
        #expect(coordinator.activeTransaction?.searchFocusAcknowledged == true)

        coordinator.acknowledgeSearchFocusResigned(presentationID: first.presentationID)
        #expect(coordinator.activeTransaction?.searchFocusAcknowledged == false)
    }

    @Test("R1136-ARCH-06: shortcut ownership is active only while a non-dismissing presentation is open")
    func shortcutOwnershipIsActiveOnlyWhileOpen() {
        let coordinator = StreamPopupFocusCoordinator()

        #expect(coordinator.isShortcutOwnershipActive == false)

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        #expect(coordinator.isShortcutOwnershipActive)

        _ = coordinator.recordDismissal(reason: .dotsToggleClose)
        // During dismissal the shortcut bridge must stand down (E6).
        #expect(coordinator.isShortcutOwnershipActive == false)
    }

    @Test("R1136-ARCH-02: composer restore only fires for reasons that should restore")
    func composerRestoreReasonPolicy() {
        func transaction(reason: StreamPopupFocusCoordinator.DismissalReason, displaced: Bool) -> StreamPopupFocusCoordinator.Transaction {
            StreamPopupFocusCoordinator.Transaction(
                presentationID: 1,
                focusTarget: .searchField,
                displacedComposerFocus: displaced,
                searchFocusAcknowledged: true,
                dismissalReason: reason
            )
        }

        // Restores composer when displaced, for these reasons:
        for reason in [StreamPopupFocusCoordinator.DismissalReason.rowSelection,
                       .outsideTap, .dotsToggleClose, .escapeOrCancel, .unspecified] {
            #expect(
                StreamPopupFocusCoordinator.shouldRestoreComposer(
                    for: transaction(reason: reason, displaced: true)
                ),
                "Expected restore for reason \(reason)"
            )
        }

        // Does NOT restore when composer focus was not displaced by the popup.
        #expect(
            StreamPopupFocusCoordinator.shouldRestoreComposer(
                for: transaction(reason: .rowSelection, displaced: false)
            ) == false
        )

        // Does NOT restore for these reasons regardless of displacement.
        for reason in [StreamPopupFocusCoordinator.DismissalReason.trackPickerHandoff,
                       .programmaticClear] {
            #expect(
                StreamPopupFocusCoordinator.shouldRestoreComposer(
                    for: transaction(reason: reason, displaced: true)
                ) == false,
                "Expected no restore for reason \(reason)"
            )
        }

        // No dismissal reason recorded yet — no restore.
        #expect(
            StreamPopupFocusCoordinator.shouldRestoreComposer(
                for: .init(
                    presentationID: 1,
                    focusTarget: .searchField,
                    displacedComposerFocus: true,
                    searchFocusAcknowledged: false,
                    dismissalReason: nil
                )
            ) == false
        )
    }

    @Test("R1136-ARCH-02: composer restore task cancels when a new presentation supersedes the dismissed one")
    func composerRestoreCancelsOnNewPresentation() async {
        let coordinator = StreamPopupFocusCoordinator()

        var restored = false

        let first = coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        _ = coordinator.recordDismissal(reason: .rowSelection)
        coordinator.scheduleComposerFocusRestore(
            forDismissedPresentationID: first.presentationID,
            delay: .milliseconds(60)
        ) {
            restored = true
        }

        // A new presentation supersedes the dismissed one before the restore fires.
        _ = coordinator.beginPresentation(focusTarget: .idle, displacedComposerFocus: false)
        try? await Task.sleep(for: .milliseconds(120))

        #expect(restored == false)
    }

    @Test("R1136-ARCH-02: composer restore task fires once for the dismissed presentation")
    func composerRestoreFiresForDismissedPresentation() async {
        let coordinator = StreamPopupFocusCoordinator()

        var restored = false

        let first = coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        _ = coordinator.recordDismissal(reason: .rowSelection)
        coordinator.scheduleComposerFocusRestore(
            forDismissedPresentationID: first.presentationID,
            delay: .milliseconds(40)
        ) {
            restored = true
        }
        // Simulate SwiftUI teardown of the popover.
        coordinator.clearActivePresentation(presentationID: first.presentationID)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(restored)
    }

    @Test("R1136-ARCH-02: composer restore does not fire when composer focus was not displaced")
    func composerRestoreSkipsWhenComposerFocusNotDisplaced() async {
        let coordinator = StreamPopupFocusCoordinator()

        var restored = false

        let first = coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: false)
        _ = coordinator.recordDismissal(reason: .rowSelection)
        coordinator.scheduleComposerFocusRestore(
            forDismissedPresentationID: first.presentationID,
            delay: .milliseconds(40)
        ) {
            restored = true
        }
        coordinator.clearActivePresentation(presentationID: first.presentationID)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(restored == false)
    }

    @Test("R1136-ARCH-04: software-keyboard dismissal during presentation clears the displaced-composer flag after debounce")
    func keyboardDismissalDuringPresentationClearsDisplacedFlag() async {
        let coordinator = StreamPopupFocusCoordinator()

        let txn = coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        // Software keyboard drops while popup is open.
        coordinator.reconcileKeyboardVisibilityDuringPresentation(isVisible: false)
        // Before the debounce window elapses, the flag is still set.
        #expect(coordinator.activeTransaction?.displacedComposerFocus == true)

        try? await Task.sleep(
            for: StreamPopupFocusCoordinator.keyboardDismissalDebounceInterval + .milliseconds(40)
        )
        _ = txn
        #expect(coordinator.activeTransaction?.displacedComposerFocus == false)
    }

    @Test("R1136-ARCH-04: software-keyboard transient hide-then-show during presentation keeps displaced flag")
    func keyboardTransientHideThenShowKeepsDisplacedFlag() async {
        let coordinator = StreamPopupFocusCoordinator()

        coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        // Brief hide then immediate show (transient keyboard adjustment).
        coordinator.reconcileKeyboardVisibilityDuringPresentation(isVisible: false)
        coordinator.reconcileKeyboardVisibilityDuringPresentation(isVisible: true)

        try? await Task.sleep(
            for: StreamPopupFocusCoordinator.keyboardDismissalDebounceInterval + .milliseconds(40)
        )
        // The show cancelled the debounce; the flag stays set.
        #expect(coordinator.activeTransaction?.displacedComposerFocus == true)
    }

    @Test("R1136-ARCH-02 / R1136-ARCH-03: integrated open → dots-close → leaked-anchor-tap race")
    func integratedDotsCloseLeakedAnchorTapRace() {
        let coordinator = StreamPopupFocusCoordinator()

        // 1. User opens popup with software keyboard up (composer had focus).
        _ = coordinator.beginPresentation(focusTarget: .searchField, displacedComposerFocus: true)
        #expect(coordinator.consumeReopenSuppressionIfActive() == false)

        // 2. User taps dots to close. Dismissal begins; guard is set.
        _ = coordinator.recordDismissal(reason: .dotsToggleClose)
        #expect(coordinator.isDismissalInProgress)
        #expect(coordinator.shouldSuppressDotsToggleReopen)

        // 3. The leaked anchor tap reaches the dots handler and is suppressed.
        #expect(coordinator.consumeReopenSuppressionIfActive())
        // The popup did NOT reopen from the leaked tap (caller would have
        // returned early before calling beginPresentation).
        #expect(coordinator.activeTransaction?.dismissalReason == .dotsToggleClose)

        // 4. Composer restore is permitted because the dots-close reason
        //    restores when displaced.
        let dismissed = coordinator.lastDismissedTransaction
        #expect(StreamPopupFocusCoordinator.shouldRestoreComposer(for: dismissed!))
    }

    @Test("R1136-ARCH-01 / R1136-ARCH-04: integrated Mac/Catalyst open with no software keyboard")
    func integratedMacCatalystOpenAutofocusesFilter() {
        let policy = StreamPopupFocusPolicy.focusTargetOnOpen(
            isSoftwareKeyboardVisible: false,
            isHardwareKeyboardAvailable: true
        )
        #expect(policy == .searchField)

        let coordinator = StreamPopupFocusCoordinator()
        let txn = coordinator.beginPresentation(focusTarget: policy, displacedComposerFocus: false)
        #expect(txn.focusTarget == .searchField)
        // No composer was displaced on Mac when opening without software keyboard.
        #expect(txn.displacedComposerFocus == false)
    }

    @Test("R1136-ARCH-08: route controller popup/track-picker surfaces still behave")
    func popupRouteControllerStillBehaves() {
        let routeController = StreamPopupRouteController()

        #expect(routeController.route == .closed)
        routeController.openPopup(focusSearch: true)
        #expect(routeController.isPopupPresented)
        #expect(routeController.popupSearchFocusRequestID != nil)
        routeController.consumeSearchFocusRequest()
        #expect(routeController.popupSearchFocusRequestID == nil)
        routeController.presentTrackPicker()
        #expect(routeController.route == .trackPicker)
        #expect(routeController.isPopupPresented == false)
        #expect(routeController.isTrackPickerPresented)
        routeController.dismissTrackPicker()
        #expect(routeController.route == .closed)
    }
}
