//
//  DictationMotion.swift
//  Clawline
//
//  Created by Codex on 2/24/26.
//

import Foundation
import Observation
import CoreGraphics

@Observable
@MainActor
final class DictationMotion {
    enum SettledSurface: Equatable {
        case closed
        case openPaused
        case openListening
    }

    struct SettledCommit: Equatable {
        let target: SettledSurface
        let reason: String
    }

    enum GesturePhase: Equatable {
        case idle
        case dragging
        case settling
    }

    enum GestureOrigin: Equatable {
        case closed
        case open
    }

    enum GestureEndIntent: Equatable {
        case none
        case send
        case dismissSurface
        case startSticky
        case endWalkieKeepOpen
        case endWalkieAndDismiss
        case settleOpen
        case settleClosed
    }

    struct GestureEndContext {
        let pullToSendEligible: Bool
        let isSwipeActivationEnabled: Bool
        let verticallyDominant: Bool
    }

    private enum Thresholds {
        static let reveal: CGFloat = 100
        static let pullToSendStart: CGFloat = 40
        static let pullToSendTrigger: CGFloat = 62
    }

    let session: DictationSession

    private(set) var gesturePhase: GesturePhase = .idle
    private(set) var rawDragY: CGFloat = 0
    private(set) var surfaceRevealProgress: CGFloat = 0
    private(set) var originWasOpen: Bool = false
    private(set) var holdThresholdReachedTime: Date?
    private(set) var walkieStartedThisGesture = false
    private(set) var deferredSettleTarget: SurfaceTarget?
    private(set) var settleDurationMultiplier: Double = 1.0
    private(set) var pendingCommit: SettledCommit?

    init(session: DictationSession) {
        self.session = session
    }

    var upDistance: CGFloat { max(0, -rawDragY) }

    // Temporary compatibility alias while MessageInputBar is still migrating.
    var surfaceInteractiveProgress: CGFloat {
        surfaceRevealProgress
    }

    var pullToSendProgress: CGFloat {
        max(
            0,
            min(1, (upDistance - Thresholds.pullToSendStart) / max(1, (Thresholds.pullToSendTrigger - Thresholds.pullToSendStart)))
        )
    }

    var isPullToSendArmed: Bool { pullToSendProgress >= 1.0 }

    var isTextInteractionLocked: Bool { gesturePhase == .dragging }

    var isSurfaceVisible: Bool {
        session.surfaceTarget == .open || (gesturePhase != .idle && surfaceRevealProgress > 0)
    }

    var settledSurface: SettledSurface {
        if session.surfaceTarget == .closed { return .closed }
        return session.isListening ? .openListening : .openPaused
    }

    var shouldFreezeLayout: Bool { gesturePhase != .idle }

    var settleTarget: SurfaceTarget { session.surfaceTarget }

    var composerLiftY: CGFloat {
        max(0, upDistance)
    }

    var pushGestureStartedWithSurfaceOpen: Bool {
        originWasOpen
    }

    var pushDragUpDistance: CGFloat {
        upDistance
    }

    func shouldBeginPan(selectionLength: Int) -> Bool {
        if isSurfaceVisible { return true }
        if session.surfaceTarget == .closed && selectionLength == 0 { return true }
        return false
    }

    func gestureBegan(originWasOpen: Bool) {
        guard gesturePhase == .idle else { return }
        gesturePhase = .dragging
        self.originWasOpen = originWasOpen
        rawDragY = 0
        walkieStartedThisGesture = false
        holdThresholdReachedTime = nil
        if originWasOpen {
            surfaceRevealProgress = 1
        } else {
            surfaceRevealProgress = 0
        }
    }

    func gestureChanged(translationY: CGFloat, velocityY _: CGFloat) {
        guard gesturePhase == .dragging else { return }
        rawDragY = translationY
        let up = upDistance
        let down = max(0, rawDragY)

        if originWasOpen {
            if up > 0 {
                surfaceRevealProgress = 1
            } else {
                surfaceRevealProgress = max(0, min(1, 1 - (down / 120)))
            }
        } else {
            surfaceRevealProgress = max(0, min(1, up / max(1, Thresholds.reveal)))
        }
    }

    func gestureEnded(
        translationY: CGFloat,
        predictedY: CGFloat,
        velocityY: CGFloat,
        context: GestureEndContext
    ) -> GestureEndIntent {
        guard gesturePhase == .dragging else { return .none }

        rawDragY = translationY
        let up = max(0, -translationY)
        let down = max(0, translationY)
        let projectedUp = max(0, -predictedY)
        let projectedDown = max(0, predictedY)
        let fastUp = predictedY < -120 || velocityY < -900
        let fastDown = predictedY > 120 || velocityY > 900
        let pullToSendArmed = isPullToSendArmed

        teardownGesture()

        if pullToSendArmed && context.pullToSendEligible {
            pendingCommit = .init(target: originWasOpen ? .openPaused : .closed, reason: "pull_to_send")
            surfaceRevealProgress = originWasOpen ? 1 : 0
            return .send
        }

        if isSurfaceVisible {
            if session.isWalkieTalkieActive {
                if originWasOpen {
                    pendingCommit = .init(target: .openPaused, reason: "walkie_release_keep_open")
                    surfaceRevealProgress = 1
                    return .endWalkieKeepOpen
                }
                pendingCommit = .init(target: .closed, reason: "walkie_release_dismiss")
                surfaceRevealProgress = 0
                return .endWalkieAndDismiss
            }

            if context.verticallyDominant && (down >= 32 || fastDown || projectedDown >= 96 || surfaceRevealProgress < 0.45) {
                pendingCommit = .init(target: .closed, reason: "dismiss_surface")
                surfaceRevealProgress = 0
                return .dismissSurface
            }
            pendingCommit = .init(target: .openPaused, reason: "settle_open_existing")
            surfaceRevealProgress = 1
            return .settleOpen
        }

        guard context.isSwipeActivationEnabled else {
            pendingCommit = .init(target: .closed, reason: "activation_disabled")
            surfaceRevealProgress = 0
            return .settleClosed
        }
        guard context.verticallyDominant else {
            pendingCommit = .init(target: .closed, reason: "not_vertical_dominant")
            surfaceRevealProgress = 0
            return .settleClosed
        }
        guard up >= 32 || fastUp || projectedUp >= 96 || surfaceRevealProgress >= 0.45 else {
            pendingCommit = .init(target: .closed, reason: "threshold_not_met")
            surfaceRevealProgress = 0
            return .settleClosed
        }
        if walkieStartedThisGesture {
            pendingCommit = .init(target: .openPaused, reason: "walkie_release_to_open")
            surfaceRevealProgress = 1
            return .endWalkieKeepOpen
        }
        pendingCommit = .init(target: .openListening, reason: "start_sticky")
        surfaceRevealProgress = 1
        return .startSticky
    }

    func gestureCancelled() {
        guard gesturePhase != .idle else { return }
        teardownGesture()
        settle(to: settleTarget)
        pendingCommit = .init(target: settledSurface, reason: "gesture_cancelled")
    }

    func settle(to target: SurfaceTarget) {
        if gesturePhase == .dragging {
            deferredSettleTarget = target
            return
        }
        if target == .open {
            surfaceRevealProgress = 1
        } else {
            surfaceRevealProgress = 0
        }
    }

    func commitSettledState() {
        gesturePhase = .idle
        rawDragY = 0
        deferredSettleTarget = nil
        pendingCommit = nil
        holdThresholdReachedTime = nil
        walkieStartedThisGesture = false
    }

    func clearGestureState() {
        gesturePhase = .idle
        rawDragY = 0
        holdThresholdReachedTime = nil
        walkieStartedThisGesture = false
        deferredSettleTarget = nil
        originWasOpen = false
        pendingCommit = nil
        surfaceRevealProgress = session.surfaceTarget == .open ? 1 : 0
    }

    @discardableResult
    func updateWalkieHoldArming(up: CGFloat, activationThreshold: CGFloat, holdDuration: TimeInterval) -> Bool {
        guard gesturePhase == .dragging else { return false }
        if up >= activationThreshold {
            if holdThresholdReachedTime == nil {
                holdThresholdReachedTime = Date()
                return false
            }
            if let reachedAt = holdThresholdReachedTime,
               !walkieStartedThisGesture,
               Date().timeIntervalSince(reachedAt) >= holdDuration {
                walkieStartedThisGesture = true
                return true
            }
        } else {
            holdThresholdReachedTime = nil
        }
        return false
    }

    private func teardownGesture() {
        gesturePhase = .settling
        rawDragY = 0
        holdThresholdReachedTime = nil
        walkieStartedThisGesture = false
        if let deferredSettleTarget {
            settle(to: deferredSettleTarget)
            self.deferredSettleTarget = nil
        }
    }

    func commitSettledState(_ target: SettledSurface) {
        if target == .closed {
            settle(to: .closed)
        } else {
            settle(to: .open)
        }
        commitSettledState()
    }
}
