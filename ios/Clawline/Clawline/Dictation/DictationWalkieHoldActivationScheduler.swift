//
//  DictationWalkieHoldActivationScheduler.swift
//  Clawline
//
//  Created by Codex on 6/11/26.
//

import CoreGraphics
import Foundation

@MainActor
final class DictationWalkieHoldActivationScheduler {
    private var task: Task<Void, Never>?

    var isScheduled: Bool {
        task != nil
    }

    func schedule(
        delay: TimeInterval,
        motion: DictationMotion,
        activationThreshold: CGFloat,
        holdDuration: TimeInterval,
        shouldArm: @escaping @MainActor () -> Bool,
        activate: @escaping @MainActor (_ up: CGFloat, _ rawDragY: CGFloat) -> Void
    ) {
        guard task == nil else { return }
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            task = nil
            guard shouldArm() else { return }
            guard motion.updateWalkieHoldArming(
                activationThreshold: activationThreshold,
                holdDuration: holdDuration
            ) else { return }
            activate(motion.pushDragUpDistance, motion.rawDragY)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
