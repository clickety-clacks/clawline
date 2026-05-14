//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import Foundation
import Observation
import OSLog
import Combine

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessageInputBar")

private struct MessageInputBarTextEditorFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct MessageInputBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct DictationWaveformMetrics {
    let baseAmplitude: CGFloat
    let dynamicFrequencyScale: CGFloat
    let dynamicPhaseSpeedScale: CGFloat
    let baseLineWidth: CGFloat

    init(audioLevel: Float, isPaused: Bool, t: CGFloat) {
        let rms = max(0, audioLevel)
        let minDb: Float = -55
        let maxDb: Float = -10
        let db = rms > 0 ? 20 * log10(rms) : minDb
        let rawAudio = max(0, min(1, (db - minDb) / (maxDb - minDb)))
        let pauseMultiplier: CGFloat = isPaused ? 0.70 : 1.0
        let idleDrift = 0.070 + 0.022 * sin(t * 1.9)
        let pausedAudioScale: CGFloat = isPaused ? 0.80 : 1.0
        // Invariant 11: asymptotic amplitude curve (fast rise, bounded approach).
        let boundedAmplitudeDrive = tanh(CGFloat(rawAudio) * 2.4)
        let targetAmplitude = 0.060 + (0.455 - 0.060) * boundedAmplitudeDrive * pausedAudioScale
        baseAmplitude = (idleDrift + targetAmplitude) * pauseMultiplier

        // Invariant 12: period curve differs from amplitude and keeps increasing.
        let periodDrive = log1p(CGFloat(rawAudio) * 1.8)
        let frequencyAudioScale: CGFloat = isPaused ? 0.64 : 0.95
        let phaseAudioScale: CGFloat = isPaused ? 0.52 : 0.65
        dynamicFrequencyScale = 1.0 + frequencyAudioScale * periodDrive
        dynamicPhaseSpeedScale = 1.0 + phaseAudioScale * periodDrive
        baseLineWidth = isPaused ? 1.1 : 2.0
    }
}

private struct DictationWaveformLine: View {
    let reduceMotion: Bool
    let isPaused: Bool
    let audioLevel: Float
    let colorScheme: ColorScheme

    private struct WaveConfig: Identifiable {
        let id: Int
        let frequency: CGFloat
        let phaseOffset: CGFloat
        let speed: CGFloat
        let amplitudeScale: CGFloat
    }

    private static let waveConfigs: [WaveConfig] = [
        WaveConfig(id: 0, frequency: 1.30, phaseOffset: 0.0, speed: 2.0, amplitudeScale: 1.00),
        WaveConfig(id: 1, frequency: 1.85, phaseOffset: 1.1, speed: 2.7, amplitudeScale: 0.95),
        WaveConfig(id: 2, frequency: 2.45, phaseOffset: 2.0, speed: 3.4, amplitudeScale: 0.86),
        WaveConfig(id: 3, frequency: 3.10, phaseOffset: 2.8, speed: 4.0, amplitudeScale: 0.74)
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.12 : (1 / 60))) { context in
            GeometryReader { proxy in
                waveformFrame(
                    width: max(1, proxy.size.width),
                    height: max(1, proxy.size.height),
                    t: CGFloat(context.date.timeIntervalSinceReferenceDate)
                )
            }
        }
    }

    @ViewBuilder
    private func waveformFrame(width: CGFloat, height: CGFloat, t: CGFloat) -> some View {
        let metrics = DictationWaveformMetrics(audioLevel: audioLevel, isPaused: isPaused, t: t)
        if reduceMotion {
            reducedMotionWave(width: width, t: t)
        } else {
            animatedWave(width: width, height: height, midY: height * 0.5, t: t, metrics: metrics)
        }
    }

    private func reducedMotionWave(width: CGFloat, t: CGFloat) -> some View {
        let pulse = 0.825 + (0.175 * sin(t * 2 * .pi))
        let alpha = max(0.65, min(1.0, pulse))

        return ZStack {
            Capsule()
                .fill(ChatFlowTheme.adminAccent(colorScheme).opacity(alpha))
                .frame(height: isPaused ? 4 : 6)
            Capsule()
                .fill(ChatFlowTheme.sage(colorScheme).opacity(alpha * 0.7))
                .frame(width: width * 0.72, height: isPaused ? 3 : 4)
            Capsule()
                .fill(ChatFlowTheme.softCoral(colorScheme).opacity(alpha * 0.52))
                .frame(width: width * 0.48, height: isPaused ? 2 : 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func animatedWave(
        width: CGFloat,
        height: CGFloat,
        midY: CGFloat,
        t: CGFloat,
        metrics: DictationWaveformMetrics
    ) -> some View {
        ZStack {
            ForEach(Self.waveConfigs) { config in
                DictationWavePath(
                    width: width,
                    height: height,
                    midY: midY,
                    phase: (t * config.speed * metrics.dynamicPhaseSpeedScale) + config.phaseOffset,
                    frequency: config.frequency * metrics.dynamicFrequencyScale,
                    amplitude: min(0.48, max(0.050, metrics.baseAmplitude * config.amplitudeScale)),
                    color: waveColor(config.id),
                    opacity: isPaused ? (0.18 - CGFloat(config.id) * 0.02) : (0.62 - CGFloat(config.id) * 0.10),
                    lineWidth: metrics.baseLineWidth + CGFloat(3 - config.id) * 0.26
                )
            }
        }
    }

    private func waveColor(_ index: Int) -> Color {
        switch index {
        case 0:
            return ChatFlowTheme.adminAccent(colorScheme)
        case 1:
            return ChatFlowTheme.sage(colorScheme)
        case 2:
            return ChatFlowTheme.softCoral(colorScheme)
        default:
            return ChatFlowTheme.terracotta(colorScheme)
        }
    }
}

private struct DictationWavePath: View {
    let width: CGFloat
    let height: CGFloat
    let midY: CGFloat
    let phase: CGFloat
    let frequency: CGFloat
    let amplitude: CGFloat
    let color: Color
    let opacity: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        path.stroke(
            color.opacity(opacity),
            style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private var path: Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: midY))
            let step: CGFloat = 2
            var x: CGFloat = 0
            while x <= width {
                let progress = x / width
                let taper = pow(sin(progress * .pi), 0.95)
                let y = midY + sin((progress * .pi * 2 * frequency) + phase) * height * amplitude * taper
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
        }
    }
}

struct DictationPanEvent {
    let startLocation: CGPoint
    let translation: CGPoint
    let predictedEndTranslation: CGPoint
    let velocity: CGPoint
}

enum DictationPanIntentDecision: Equatable {
    case undecided
    case dictation
    case textEditing
}

struct DictationPanIntentContext {
    let startedInEditableRegion: Bool
    let isSurfaceOpen: Bool
    let elapsed: TimeInterval
    let translation: CGPoint
    let velocity: CGPoint
}

struct DictationInteractionProjection {
    let surfaceTarget: SurfaceTarget
    let isSurfaceOpen: Bool
    let isDictationActive: Bool
    let isStickyDictationActive: Bool
    let isWalkieTalkieActive: Bool
    let isListening: Bool
    let micVisible: Bool
    let swipeActivationEnabled: Bool
    let reduceMotionEnabled: Bool
    let showsComposeKeyPromptModal: Bool
    let errorMessage: String?
    let audioLevel: Float
    let inlineKeyText: String
    let inlineKeyStatus: SonioxKeyVerificationStatus
    let inlineKeyActionTitle: String

    init(session: DictationSession) {
        surfaceTarget = session.surfaceTarget
        isSurfaceOpen = session.isSurfaceOpen
        isDictationActive = session.isDictationActive
        isStickyDictationActive = session.isStickyDictationActive
        isWalkieTalkieActive = session.isWalkieTalkieActive
        isListening = session.isListening
        micVisible = session.micVisible
        swipeActivationEnabled = session.swipeActivationEnabled
        reduceMotionEnabled = session.reduceMotionEnabled
        showsComposeKeyPromptModal = session.showsComposeKeyPromptModal
        errorMessage = session.errorMessage
        audioLevel = session.audioLevel
        inlineKeyText = session.inlineKeyText
        inlineKeyStatus = session.inlineKeyStatus
        inlineKeyActionTitle = session.inlineKeyActionTitle
    }
}

@MainActor
enum DictationGestureCommitIntent {
    case startSticky
    case startWalkieTalkie
    case dismissSurface
    case endWalkieTalkie
    case resumeWalkieTalkieFromPaused
}

enum DictationStopIntentSource {
    case escapeKey
    case voiceOverAction
}

enum DictationDiscardIntentSource {
    case escapeLongPress
    case voiceOverAction
}

enum DictationInteractionIntent {
    case activationSelectionCaptured(NSRange)
    case composeSelectionChanged(NSRange)
    case composeUserEdited(range: NSRange, replacementUTF16Length: Int)
    case composeTextViewChanged(PastableTextView?)
    case gesturePrewarmRequested
    case gestureCancelled(trigger: String)
    case gestureCommitRequested(DictationGestureCommitIntent)
    case stopRequested(DictationStopIntentSource)
    case discardRequested(DictationDiscardIntentSource)
    case waveformToggleRequested
    case inlineKeyTextChanged(String)
}

@MainActor
struct DictationInteractionEmitter {
    let emit: (DictationInteractionIntent) -> Void
    let performComposeKeyPrimaryAction: (@escaping (URL) -> Void) async -> Void
}

func shouldBeginDictationPanGesture(
    startedInEditableRegion: Bool,
    isSurfaceVisible: Bool,
    swipeActivationEnabled: Bool,
    hasSelection: Bool,
    startedInSelectionGestureRegion: Bool
) -> Bool {
    if startedInEditableRegion || startedInSelectionGestureRegion {
        return false
    }
    if hasSelection {
        return false
    }
    if isSurfaceVisible || swipeActivationEnabled {
        return true
    }
    return false
}

func classifyDictationPanIntent(_ context: DictationPanIntentContext) -> DictationPanIntentDecision {
    let up = max(0, -context.translation.y)
    let down = max(0, context.translation.y)
    let verticalDominant = max(up, down) >= 1.25 * abs(context.translation.x)
    let velocityDominantUp = abs(context.velocity.y) >= 1.15 * abs(context.velocity.x)
    let fastUpVelocity = context.velocity.y <= -220 && velocityDominantUp
    let velocityDominantDown = abs(context.velocity.y) >= 1.15 * abs(context.velocity.x)
    let clearDownDismissDrag = context.isSurfaceOpen &&
        verticalDominant &&
        down >= 24 &&
        (context.elapsed < 0.22 || (context.velocity.y >= 280 && velocityDominantDown))

    if context.startedInEditableRegion {
        if clearDownDismissDrag {
            return .dictation
        }
        if fastUpVelocity || (up >= 22 && context.elapsed < 0.18 && verticalDominant) {
            return .dictation
        }
        // Prefer text editing quickly when a touch starts in the editor and does not
        // clearly indicate dictation intent. This preserves tap-to-focus behavior.
        if context.elapsed >= 0.06 || down >= 8 || abs(context.translation.x) >= 20 || up >= 8 {
            return .textEditing
        }
        return .undecided
    }

    if verticalDominant && (up >= 6 || (context.isSurfaceOpen && down >= 6)) {
        return .dictation
    }

    return .undecided
}

struct DictationPanGestureInstaller: UIViewControllerRepresentable {
    var shouldBegin: (CGPoint, CGPoint) -> Bool
    var startsInEditableRegion: (CGPoint) -> Bool
    var activeRegion: () -> CGRect
    var isSurfaceOpen: () -> Bool
    var scenePhase: ScenePhase
    var onChanged: (DictationPanEvent) -> Void
    var onEnded: (DictationPanEvent, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
            startsInEditableRegion: startsInEditableRegion,
            activeRegion: activeRegion,
            isSurfaceOpen: isSurfaceOpen,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    func makeUIViewController(context: Context) -> InstallerViewController {
        let controller = InstallerViewController()
        controller.coordinator = context.coordinator
        context.coordinator.attachIfNeeded(from: controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: InstallerViewController, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.startsInEditableRegion = startsInEditableRegion
        context.coordinator.activeRegion = activeRegion
        context.coordinator.isSurfaceOpen = isSurfaceOpen
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.handleScenePhaseChanged(scenePhase)
        context.coordinator.attachIfNeeded(from: uiViewController)
    }

#if DEBUG
    static func debugCoordinatorForTests(
        onEnded: @escaping (DictationPanEvent, Bool) -> Void = { _, _ in }
    ) -> Coordinator {
        Coordinator(
            shouldBegin: { _, _ in false },
            startsInEditableRegion: { _ in false },
            activeRegion: { .zero },
            isSurfaceOpen: { false },
            onChanged: { _ in },
            onEnded: onEnded
        )
    }
#endif

    final class InstallerViewController: UIViewController {
        weak var coordinator: Coordinator?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator?.updateActiveRegion(from: self)
            coordinator?.attachIfNeeded(from: self)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            coordinator?.updateActiveRegion(from: self)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            coordinator?.prepareForInstallerDisappear()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private enum IntentLock {
            case undecided
            case dictation
            case textEditing
        }

        var shouldBegin: (CGPoint, CGPoint) -> Bool
        var startsInEditableRegion: (CGPoint) -> Bool
        var activeRegion: () -> CGRect
        var isSurfaceOpen: () -> Bool
        var onChanged: (DictationPanEvent) -> Void
        var onEnded: (DictationPanEvent, Bool) -> Void

        private weak var attachedView: UIView?
        private weak var installerViewController: InstallerViewController?
        private let pan = UIPanGestureRecognizer()
        private var intentLock: IntentLock = .undecided
        private var gestureStartDate: Date = .distantPast
        private var startedInEditableRegion = false
        private var activeRegionInWindow: CGRect = .zero
        private var activeTextView: UITextView?
        private var activeTextViewWasScrollEnabled = false
        private var activeTextViewWasSelectable = false
        private var activeTextViewGestureRecognizerStates: [(UIGestureRecognizer, Bool)] = []
        private var lastScenePhase: ScenePhase?

        init(
            shouldBegin: @escaping (CGPoint, CGPoint) -> Bool,
            startsInEditableRegion: @escaping (CGPoint) -> Bool,
            activeRegion: @escaping () -> CGRect,
            isSurfaceOpen: @escaping () -> Bool,
            onChanged: @escaping (DictationPanEvent) -> Void,
            onEnded: @escaping (DictationPanEvent, Bool) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.startsInEditableRegion = startsInEditableRegion
            self.activeRegion = activeRegion
            self.isSurfaceOpen = isSurfaceOpen
            self.onChanged = onChanged
            self.onEnded = onEnded
            super.init()
            pan.addTarget(self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
        }

        deinit {
            prepareForInstallerDisappear()
        }

        func attachIfNeeded(from installerViewController: InstallerViewController) {
            self.installerViewController = installerViewController
            updateActiveRegion(from: installerViewController)

            let host = resolveInteractiveHost(from: installerViewController)
            guard let host else { return }

            guard attachedView !== host else { return }
            resetGestureState()
            attachedView?.removeGestureRecognizer(pan)
            host.addGestureRecognizer(pan)
            attachedView = host
            logger.info("DICTATION_UI pan_attach host=\(String(describing: type(of: host)), privacy: .public)")
        }

        func prepareForInstallerDisappear() {
            resetGestureState()
            attachedView?.removeGestureRecognizer(pan)
            attachedView = nil
        }

        func handleScenePhaseChanged(_ scenePhase: ScenePhase) {
            guard scenePhase != lastScenePhase else { return }
            lastScenePhase = scenePhase
            if scenePhase == .background {
                resetGestureState()
            }
        }

        func updateActiveRegion(from installerViewController: InstallerViewController) {
            let explicitActiveRegion = activeRegion()
            if explicitActiveRegion != .zero {
                activeRegionInWindow = explicitActiveRegion
                return
            }
            guard let window = installerViewController.view.window else {
                activeRegionInWindow = .zero
                return
            }
            activeRegionInWindow = installerViewController.view.convert(installerViewController.view.bounds, to: window)
        }

        private func resolveInteractiveHost(from installerViewController: InstallerViewController) -> UIView? {
            if let parentView = installerViewController.parent?.view {
                return parentView
            }
            if let rootView = installerViewController.view.window?.rootViewController?.view {
                return rootView
            }
            return installerViewController.view.window
        }

        @objc
        private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let host = attachedView, let window = host.window else { return }
            let event = DictationPanEvent(
                startLocation: gesture.location(in: window),
                translation: gesture.translation(in: window),
                predictedEndTranslation: {
                    let t = gesture.translation(in: window)
                    let v = gesture.velocity(in: window)
                    return CGPoint(x: t.x + (v.x * 0.12), y: t.y + (v.y * 0.12))
                }(),
                velocity: gesture.velocity(in: window)
            )

            switch gesture.state {
            case .began:
                gestureStartDate = Date()
                startedInEditableRegion = startsInEditableRegion(event.startLocation)
                activeTextView = nearestTextView(at: event.startLocation, in: window)
                activeTextViewWasScrollEnabled = activeTextView?.isScrollEnabled ?? false
                activeTextViewWasSelectable = activeTextView?.isSelectable ?? false
                intentLock = .undecided
                promoteIntentIfNeeded(event)
                if intentLock == .dictation {
                    onChanged(event)
                }
            case .changed:
                promoteIntentIfNeeded(event)
                if intentLock == .dictation {
                    onChanged(event)
                }
            case .ended:
                if intentLock == .dictation {
                    // Unlock the text view before callbacks that may immediately
                    // collapse the surface and tear down this installer host.
                    resetGestureState()
                    onEnded(event, false)
                } else {
                    resetGestureState()
                }
            case .cancelled, .failed:
                if intentLock == .dictation {
                    // Cleanup must not depend on callback completion.
                    resetGestureState()
                    onEnded(event, true)
                } else {
                    resetGestureState()
                }
            default:
                break
            }
        }

        private func resetGestureState() {
            if let activeTextView {
                for (gestureRecognizer, wasEnabled) in activeTextViewGestureRecognizerStates {
                    gestureRecognizer.isEnabled = wasEnabled
                }
                activeTextView.isScrollEnabled = activeTextViewWasScrollEnabled
                activeTextView.isSelectable = activeTextViewWasSelectable
            }
            activeTextViewGestureRecognizerStates.removeAll(keepingCapacity: false)
            activeTextView = nil
            activeTextViewWasScrollEnabled = false
            activeTextViewWasSelectable = false
            intentLock = .undecided
            startedInEditableRegion = false
            gestureStartDate = .distantPast
        }

#if DEBUG
        func debugPrimeTextViewLock(_ textView: UITextView) {
            activeTextView = textView
            activeTextViewWasScrollEnabled = textView.isScrollEnabled
            activeTextViewWasSelectable = textView.isSelectable
            lockTextScrollForDictationIfNeeded()
        }
#endif

        private func promoteIntentIfNeeded(_ event: DictationPanEvent) {
            guard intentLock == .undecided else { return }

            let decision = classifyDictationPanIntent(
                .init(
                    startedInEditableRegion: startedInEditableRegion,
                    isSurfaceOpen: isSurfaceOpen(),
                    elapsed: Date().timeIntervalSince(gestureStartDate),
                    translation: event.translation,
                    velocity: event.velocity
                )
            )
            switch decision {
            case .dictation:
                intentLock = .dictation
                lockTextScrollForDictationIfNeeded()
            case .textEditing:
                intentLock = .textEditing
                pan.isEnabled = false
                pan.isEnabled = true
            case .undecided:
                break
            }
        }

        private func lockTextScrollForDictationIfNeeded() {
            guard let activeTextView else { return }
            if activeTextView.isScrollEnabled {
                activeTextView.isScrollEnabled = false
            }
            if activeTextView.isFirstResponder {
                if activeTextViewGestureRecognizerStates.isEmpty {
                    let gestureRecognizers = activeTextView.gestureRecognizers ?? []
                    activeTextViewGestureRecognizerStates = gestureRecognizers.map { ($0, $0.isEnabled) }
                    for gestureRecognizer in gestureRecognizers where gestureRecognizer.isEnabled {
                        gestureRecognizer.isEnabled = false
                    }
                }
            } else if activeTextView.isSelectable {
                activeTextView.isSelectable = false
            }
        }

        private func nearestTextView(at location: CGPoint, in window: UIWindow) -> UITextView? {
            var current = window.hitTest(location, with: nil)
            while let view = current {
                if let textView = view as? UITextView {
                    return textView
                }
                current = view.superview
            }
            return nil
        }

        private func nearestCollectionView(from view: UIView) -> UICollectionView? {
            var current: UIView? = view
            while let candidate = current {
                if let collectionView = candidate as? UICollectionView {
                    return collectionView
                }
                current = candidate.superview
            }
            return nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pan,
                  let host = attachedView,
                  let window = host.window
            else {
                return false
            }
            let location = pan.location(in: window)
            if let touchedView = window.hitTest(location, with: nil),
               nearestCollectionView(from: touchedView) != nil {
                return false
            }
            guard activeRegionInWindow.contains(location) else { return false }
            let velocity = pan.velocity(in: window)
            let allowed = shouldBegin(location, velocity)
            logger.info("DICTATION_UI pan_should_begin allowed=\(allowed, privacy: .public) location=\(location.debugDescription, privacy: .public) velocity=\(velocity.debugDescription, privacy: .public)")
            return allowed
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === pan {
                if otherGestureRecognizer.view is UITextView {
                    return true
                }
                if let activeTextView, let view = otherGestureRecognizer.view {
                    return view.isDescendant(of: activeTextView)
                }
            }
            return false
        }
    }
}

// The input bar is hosted in a pinned UIKit container, so parent value changes do not always
// rebuild its content closure. Keep the send button state in a stable observable store.
@Observable
@MainActor
final class SendButtonConnectionStateStore {
    var value: SendButtonConnectionState

    init(value: SendButtonConnectionState = .disconnected) {
        self.value = value
    }
}

// MARK: - ⚠️⚠️⚠️ CRITICAL: READ ChatView.swift HEADER BEFORE MODIFYING ⚠️⚠️⚠️
//
// This view is used inside .safeAreaInset in ChatView. That context has special behavior:
//
// 1. THIS VIEW GETS RECREATED when geometry changes (e.g., keyboard appears)
// 2. Any @State defined HERE will be RESET when that happens
// 3. onChange handlers HERE may NEVER FIRE because the view recreates before they trigger
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHAT THIS MEANS FOR YOU
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// ❌ DO NOT add @State here for keyboard/focus tracking - it will reset
// ❌ DO NOT expect onChange to fire reliably - view may recreate first
// ❌ DO NOT apply positioning offsets here - they won't update on parent state change
//
// ✅ DO use callbacks (like onFocusChange) to report state to parent
// ✅ DO let parent (ChatView) own state that needs to survive geometry changes
// ✅ DO let parent apply offset/positioning modifiers
//
// The @FocusState here was replaced by RichTextEditor focus callbacks that update parent state.
// The parent's @State survives; ours does not.
//
// See ChatView.swift header comment for the full explanation and rescue tag: `working-keyboard-behaviors`.
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct MessageInputBar: View {
    enum SendButtonBubbleVisualState: Equatable {
        case ghost
        case active
        case reconnecting
        case error
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    let dictation: DictationInteractionProjection
    let dictationEmitter: DictationInteractionEmitter
    var placeholderText: String = "Message"
    var fontScaleChangeSequence: Int = 0
    var resetToken: Int
    let canSend: Bool
    let isSending: Bool
    let isStagingAttachments: Bool
    let connectionStateStore: SendButtonConnectionStateStore
    let focusTrigger: Int
    let dismissTrigger: Int
    let isTextFieldFocused: Bool
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    @Binding var isAttachmentMenuPresented: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onReconnect: () -> Void
    let onAdd: () -> Void
    let attachmentMenuContent: () -> AnyView
    let onFocusChange: (Bool) -> Void
    let onRequestFocus: () -> Void
    var onRequestDirectFocus: (() -> Void)?
    var onPasteImages: (([UIImage]) -> Void)?

    @State private var editorHeight: CGFloat = 44
    @Bindable var motion: DictationMotion
    @State private var waveformDidStartWalkie = false
    @State private var micTransientVisible = false
    @State private var micTransientOpacity: Double = 0
    @State private var micTransientOffset: CGFloat = 0
    @State private var micFadeTask: Task<Void, Never>?
    @State private var micTapActivationTask: Task<Void, Never>?
    @State private var gestureSettleTask: Task<Void, Never>?
    @State private var textEditorGlobalFrame: CGRect = .zero
    @State private var inputBarGlobalFrame: CGRect = .zero
    @State private var cachedMaxBarWidth: CGFloat?
    @State private var shouldRestoreFocusAfterGestureDictationStart = false
    let isCompact: Bool
    private let verticalDominanceRatio: CGFloat = 1.4

    private var metrics: MessageInputBarMetrics {
        MessageInputBarMetrics(
            horizontalSizeClass: isCompact ? .compact : .regular,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: deviceCornerRadius,
            isFieldFocused: isKeyboardVisible
        )
    }

    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    private var inputHeight: CGFloat {
        if content.length == 0 {
            return metrics.inputBarHeight
        }
        return max(editorHeight, metrics.inputBarHeight)
    }

    private var isSingleLine: Bool {
        editorHeight <= metrics.inputBarHeight + 0.5
    }

    private var inputShape: AnyShape {
        if isSingleLine {
            return AnyShape(Capsule())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var inputCornerRadius: CGFloat {
        isSingleLine ? inputHeight / 2 : 22
    }

    private var reduceMotionForDictation: Bool {
        accessibilityReduceMotion || dictation.reduceMotionEnabled
    }

    private var isKeyboardDictationUITestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-keyboard-dictation")
    }

    private var shouldRenderMic: Bool {
        (!dictation.isSurfaceOpen || isKeyboardDictationUITestMode)
            && (!isTextFieldFocused || isKeyboardDictationUITestMode)
            && content.length == 0
            && (dictation.micVisible || micTransientVisible)
    }

    private var isDictationDragActive: Bool {
        motion.gesturePhase == .dragging
    }

    private var micTrailingPadding: CGFloat {
        shouldRenderMic ? 52 : 20
    }

    private var connectionAlertHint: String? {
        switch connectionState {
        case .reconnecting:
            return "Waiting for connection to return."
        case .disconnected:
            return "Connection lost. Try again soon."
        case .connected:
            return nil
        }
    }

    private var isReconnecting: Bool {
        connectionState == .reconnecting
    }

    private var isDisconnected: Bool {
        connectionState == .disconnected
    }

    private var hasSubmittableDraft: Bool {
        !content.isEffectivelyEmpty
    }

    private var sendButtonWidth: CGFloat {
        metrics.inputBarHeight
    }

    private var walkieHoldActivationThreshold: CGFloat { 124 }
    private var walkieHoldDurationSeconds: TimeInterval { 0.55 }
    private var canSendNow: Bool {
        !isSending && canSend && connectionState == .connected
    }

    static func shouldDispatchEditorSubmitIntent(
        isSending: Bool,
        hasSubmittableDraft: Bool
    ) -> Bool {
        !isSending && hasSubmittableDraft
    }

    static func shouldRequestFocusOnEditorTap(isKeyboardVisible: Bool) -> Bool {
        !isKeyboardVisible
    }

    static func reconnectBubbleScale(phase: CGFloat) -> CGFloat {
        let clampedPhase = min(1, max(0, phase))
        return 0.75 + (0.25 * clampedPhase)
    }

    static func sendButtonBubbleVisualState(
        isSending: Bool,
        canSend: Bool,
        isStagingAttachments: Bool,
        connectionState: SendButtonConnectionState
    ) -> SendButtonBubbleVisualState {
        switch connectionState {
        case .connected:
            return (isSending || canSend || sendButtonShowsPreparingSpinner(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )) ? .active : .ghost
        case .reconnecting:
            return .reconnecting
        case .disconnected:
            return .error
        }
    }

    static func sendButtonShowsPreparingSpinner(
        isSending: Bool,
        canSend: Bool,
        isStagingAttachments: Bool,
        connectionState: SendButtonConnectionState
    ) -> Bool {
        connectionState == .connected && isStagingAttachments && !isSending && !canSend
    }

    static func sendButtonShowsPrimaryIcon(
        isSending: Bool,
        canSend: Bool,
        isStagingAttachments: Bool,
        connectionState: SendButtonConnectionState
    ) -> Bool {
        !isSending && !sendButtonShowsPreparingSpinner(
            isSending: isSending,
            canSend: canSend,
            isStagingAttachments: isStagingAttachments,
            connectionState: connectionState
        )
    }

    static func sendButtonPrimarySymbolName(connectionState: SendButtonConnectionState) -> String {
        connectionState == .disconnected ? "arrow.clockwise" : "paperplane.fill"
    }

    static func sendButtonBubbleScale(
        state: SendButtonBubbleVisualState,
        reconnectPhase: Double = 0
    ) -> Double {
        switch state {
        case .ghost:
            return 0
        case .active, .error:
            return 1
        case .reconnecting:
            return Double(reconnectBubbleScale(phase: CGFloat(reconnectPhase)))
        }
    }

    private var pullToSendEligible: Bool {
        canSendNow
    }

    private var settleDurationMs: Int {
        Int((300.0 * max(0.1, motion.settleDurationMultiplier)).rounded())
    }

    private var settleSpring: Animation {
        .interactiveSpring(
            response: 0.56 * max(0.1, motion.settleDurationMultiplier),
            dampingFraction: 0.82,
            blendDuration: 0.12
        )
    }

    private var pullToSendLift: CGFloat {
        let revealContribution = motion.pushGestureStartedWithSurfaceOpen ? 0 : min(motion.pushDragUpDistance, 100)
        return max(0, motion.pushDragUpDistance - revealContribution)
    }

    private var isPausedSurfaceState: Bool {
        dictation.isSurfaceOpen && !dictation.isListening && dictation.errorMessage == nil
    }

    private var containerPadding: CGFloat {
        ChatFlowTheme.Metrics(isCompact: isCompact).inputBarPaddingHorizontal
    }

    static func chromeWidth(
        isCompact: Bool,
        bottomSafeAreaInset: CGFloat,
        isFieldFocused: Bool
    ) -> CGFloat {
        let themeMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let metrics = MessageInputBarMetrics(
            horizontalSizeClass: isCompact ? .compact : .regular,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: 0,
            isFieldFocused: isFieldFocused
        )
        return (themeMetrics.inputBarPaddingHorizontal * 2)
            + metrics.inputBarHeight
            + metrics.inputBarHeight
            + (MessageInputBarMetrics.elementSpacing * 2)
    }

    static func maxBarWidth(
        isCompact: Bool,
        bottomSafeAreaInset: CGFloat,
        isFieldFocused: Bool
    ) -> CGFloat? {
        guard !isCompact else { return nil }
        let bodyFont = UIFont.clawline(.bodyText)
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFont: bodyFont)
        return textWidth + chromeWidth(
            isCompact: isCompact,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isFieldFocused: isFieldFocused
        )
    }

    static func renderedInputFieldWidthCap(
        containerWidth: CGFloat,
        isCompact: Bool,
        bottomSafeAreaInset: CGFloat,
        isFieldFocused: Bool
    ) -> CGFloat {
        let resolvedBarWidth = min(
            containerWidth,
            maxBarWidth(
                isCompact: isCompact,
                bottomSafeAreaInset: bottomSafeAreaInset,
                isFieldFocused: isFieldFocused
            ) ?? containerWidth
        )
        return max(
            0,
            resolvedBarWidth - chromeWidth(
                isCompact: isCompact,
                bottomSafeAreaInset: bottomSafeAreaInset,
                isFieldFocused: isFieldFocused
            )
        )
    }

    private func refreshMaxBarWidth() {
        cachedMaxBarWidth = Self.maxBarWidth(
            isCompact: isCompact,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isFieldFocused: isKeyboardVisible
        )
    }

    // #61: On visionOS, keep the input bar in dark mode regardless of the global theme toggle.
    // The rest of the UI still respects `settings.appearanceMode`.
    private var isLightModeForInputBar: Bool {
#if os(visionOS)
        return false
#else
        return colorScheme == .light
#endif
    }

    private var connectionState: SendButtonConnectionState {
        connectionStateStore.value
    }

    private var inputBarColorScheme: ColorScheme {
        isLightModeForInputBar ? .light : .dark
    }

    private var addButtonForeground: Color {
#if os(visionOS)
        return isLightModeForInputBar ? .black : .white
#else
        return .primary
#endif
    }

    private var appearanceIconColor: Color { addButtonForeground }

    private var appearanceIconName: String {
        settings.appearanceMode == .dark ? "moon.stars" : "sun.max"
    }

    private var isLightMode: Bool {
        settings.appearanceMode == .light
    }

    private var visionOSBorderColor: Color {
        isLightModeForInputBar
            ? ChatFlowTheme.ink(.light).opacity(0.95)
            : Color.white.opacity(0.5)
    }

    private var inputBorderColor: Color {
#if os(visionOS)
        return visionOSBorderColor
#else
        return ChatFlowTheme.ink(colorScheme).opacity(0.16)
#endif
    }

    private var placeholderColor: Color {
#if os(visionOS)
        return isLightModeForInputBar
            ? ChatFlowTheme.ink(.light).opacity(0.6)
            : ChatFlowTheme.ink(.dark).opacity(0.6)
#else
        return .secondary
#endif
    }

    private var inputTintColor: Color {
#if os(visionOS)
        return isLightModeForInputBar ? ChatFlowTheme.ink(.light) : ChatFlowTheme.ink(.dark)
#else
        return .primary
#endif
    }

    private var editorTintUIColor: UIColor {
#if os(visionOS)
        return UIColor(inputTintColor)
#else
        return UIColor(ChatFlowTheme.sage(colorScheme))
#endif
    }

    static func disabledSendButtonBackingColor(
        colorScheme: ColorScheme,
        drawsDisabledBacking: Bool = true
    ) -> Color? {
        guard drawsDisabledBacking else { return nil }
        return colorScheme == .light
            ? Color(red: 0.925, green: 0.922, blue: 0.890)
            : nil
    }

    static let sendButtonColoredBackingBlurRadius: CGFloat = 7

    private func handleEditorSubmitIntent() {
        guard Self.shouldDispatchEditorSubmitIntent(
            isSending: isSending,
            hasSubmittableDraft: hasSubmittableDraft
        ) else { return }
        onSend()
    }

#if DEBUG
    private var dictationDebugVersionText: String? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else { return nil }
        if let version, !version.isEmpty {
            return "DBG v\(version) b\(build)"
        }
        return "DBG b\(build)"
    }
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow

            dictationSurface
                .frame(height: motion.isSurfaceVisible ? 100 : 0, alignment: .top)
                .opacity(motion.surfaceInteractiveProgress)
                .clipped()
                .padding(.top, motion.isSurfaceVisible ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: motion.isSurfaceVisible)
        }
        .padding(.horizontal, containerPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: cachedMaxBarWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MessageInputBarFramePreferenceKey.self,
                    value: geometry.frame(in: .global)
                )
            }
        )
        .overlay(alignment: .bottom) {
            if motion.pullToSendProgress > 0.001 {
                pullToSendIndicator
                    .frame(height: 40)
                    .scaleEffect(0.85 + 0.15 * motion.pullToSendProgress, anchor: .center)
                    .opacity(min(1, 0.2 + 1.2 * motion.pullToSendProgress))
                    .offset(y: MessageInputBarMetrics.elementSpacing)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .overlay(
            DictationPanGestureInstaller(
                shouldBegin: shouldBeginDictationPan(startLocation:velocity:),
                startsInEditableRegion: startsInEditableRegion(startLocation:),
                activeRegion: { inputBarGlobalFrame },
                isSurfaceOpen: { motion.isSurfaceVisible },
                scenePhase: scenePhase,
                onChanged: { event in
                    handlePushChanged(
                        startLocation: event.startLocation,
                        translation: event.translation,
                        velocity: event.velocity
                    )
                },
                onEnded: { event, wasCancelled in
                    handlePushEnded(
                        startLocation: event.startLocation,
                        translation: event.translation,
                        predictedEndTranslation: event.predictedEndTranslation,
                        velocity: event.velocity,
                        wasCancelled: wasCancelled
                    )
                }
            )
            .allowsHitTesting(false)
        )
        .onPreferenceChange(MessageInputBarTextEditorFramePreferenceKey.self) { frame in
            textEditorGlobalFrame = frame
        }
        .onPreferenceChange(MessageInputBarFramePreferenceKey.self) { frame in
            inputBarGlobalFrame = frame
        }
        .simultaneousGesture(TapGesture().onEnded {
            logger.info("Input bar tap gesture")
        })
#if DEBUG
        .overlay(alignment: .topTrailing) {
            if dictation.isDictationActive,
               let dictationDebugVersionText {
                Text(dictationDebugVersionText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.trailing, containerPadding)
                    .offset(y: -18)
                    .accessibilityIdentifier("dictation-debug-version")
            }
        }
#endif
        .onChange(of: content.length) { _, newValue in
            guard newValue == 0 else { return }
            editorHeight = metrics.inputBarHeight
        }
        .onDisappear {
            micFadeTask?.cancel()
            gestureSettleTask?.cancel()
            motion.clearGestureState()
        }
        .onAppear {
            resetMotionToCurrentProjection()
            refreshMaxBarWidth()
        }
        .onChange(of: isCompact) { _, _ in
            refreshMaxBarWidth()
        }
        .onChange(of: settings.fontScale) { _, _ in
            refreshMaxBarWidth()
        }
        .onChange(of: dictation.surfaceTarget) { _, target in
            resetMotionToCurrentProjection()
            if dictation.isSurfaceOpen {
                micFadeTask?.cancel()
                micTransientVisible = false
                micTransientOpacity = 0
                micTransientOffset = 0
            }
        }
        .onChange(of: dictation.isDictationActive) { _, _ in
            resetMotionToCurrentProjection()
        }
        .onChange(of: dictation.errorMessage) { _, _ in
            resetMotionToCurrentProjection()
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: MessageInputBarMetrics.elementSpacing) {
#if os(visionOS)
            // Appearance toggle button
            Button(action: {
                settings.toggleAppearanceMode()
            }) {
                Image(systemName: appearanceIconName)
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(appearanceIconColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(visionOSBorderColor, lineWidth: 1)
            }
#else
            .glassEffect(.regular.interactive(), in: Circle())
            .background {
                if isLightMode {
                    Circle()
                        .fill(Color.primary.opacity(0.15))
                }
            }
#endif
            .accessibilityLabel("Toggle appearance")
#endif

            // Add button - send-style for reliable hit testing (left side)
            Button(action: {
                onAdd()
            }) {
                Image(systemName: "plus")
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(addButtonForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .stroke(visionOSBorderColor, lineWidth: 1)
            )
#else
            .glassEffect(.regular.interactive(), in: Circle())
#endif
            .accessibilityLabel("Add attachment")
            .disabled(isSending)
            .popover(
                isPresented: $isAttachmentMenuPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                attachmentMenuContent()
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(.clear)
            }

            // Text field - glass capsule/rounded rect
            ZStack(alignment: .leading) {
                RichTextEditor(
                    attributedText: $content,
                    calculatedHeight: $editorHeight,
                    selectionRange: $selectionRange,
                    pendingInsertions: $pendingInsertions,
                    fontScaleChangeSequence: fontScaleChangeSequence,
                    resetToken: resetToken,
                    focusTrigger: focusTrigger,
                    dismissTrigger: dismissTrigger,
                    isEditable: true,
                    isKeyboardVisible: isKeyboardVisible,
                    isDictationActive: dictation.isDictationActive,
                    tintColor: editorTintUIColor,
                    textColor: {
#if os(visionOS)
                        // #61: Input bar is forced dark on visionOS; ensure typed text is visible.
                        return .white
#else
                        return .label
#endif
                    }(),
                    onFocusChange: onFocusChange,
                    onSubmit: handleEditorSubmitIntent,
                    onEscape: {
                        dictationEmitter.emit(.stopRequested(.escapeKey))
                    },
                    onEscapeLongPress: {
                        dictationEmitter.emit(.discardRequested(.escapeLongPress))
                    },
                    onPasteImages: onPasteImages,
                    onUserEdit: { range, replacementUTF16Length in
                        dictationEmitter.emit(
                            .composeUserEdited(
                                range: range,
                                replacementUTF16Length: replacementUTF16Length
                            )
                        )
                    },
                    onTextViewReady: { textView in
                        dictationEmitter.emit(.composeTextViewChanged(textView))
                    },
                    trailingPadding: micTrailingPadding
                )
                .opacity(isSending ? 0.5 : 1)
                .onChange(of: selectionRange) { _, newValue in
                    dictationEmitter.emit(.composeSelectionChanged(newValue))
                }

                if content.length == 0 {
                    Text(placeholderText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(placeholderColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 20)
                        .padding(.trailing, micTrailingPadding)
                }

                if shouldRenderMic {
                    micButton
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .opacity((dictation.micVisible || isKeyboardDictationUITestMode) ? 1 : micTransientOpacity)
                        .offset(x: (dictation.micVisible || isKeyboardDictationUITestMode) ? 0 : micTransientOffset)
                        .allowsHitTesting(dictation.micVisible || isKeyboardDictationUITestMode)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .animation(.easeOut(duration: isTextFieldFocused ? 0.7 : 0.35), value: dictation.micVisible)
                }
            }
            .tint(inputTintColor)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
#if os(visionOS)
            .background(.regularMaterial, in: inputShape)
#else
            .glassEffect(.regular, in: inputShape)
#endif
            .overlay {
                inputShape
                    .stroke(inputBorderColor, lineWidth: 1)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MessageInputBarTextEditorFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            )
            .overlay {
                if isKeyboardDictationUITestMode {
                    Button {
                        if let onRequestDirectFocus {
                            onRequestDirectFocus()
                        } else {
                            onFocusChange(true)
                            onRequestFocus()
                        }
                    } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compose-focus-target")
                    .accessibilityLabel("Compose message")
                }
            }
            .accessibilityAction(named: Text("Start Sticky Dictation")) {
                guard dictation.micVisible || dictation.swipeActivationEnabled else { return }
                dictationEmitter.emit(.activationSelectionCaptured(selectionRange))
                dictationEmitter.emit(.gestureCommitRequested(.startSticky))
            }
            .accessibilityAction(named: Text("Start Walkie-Talkie Dictation")) {
                guard dictation.micVisible || dictation.swipeActivationEnabled else { return }
                dictationEmitter.emit(.activationSelectionCaptured(selectionRange))
                dictationEmitter.emit(.gestureCommitRequested(.startWalkieTalkie))
                beginMicFadeOut(fromSwipe: !dictation.micVisible)
            }
            .accessibilityAction(named: Text("Stop Dictation")) {
                dictationEmitter.emit(.stopRequested(.voiceOverAction))
            }
            .accessibilityAction(named: Text("Cancel and Discard Dictation")) {
                dictationEmitter.emit(.discardRequested(.voiceOverAction))
            }

            MessageSendControl(
                isSending: isSending,
                isStagingAttachments: isStagingAttachments,
                canSend: canSendNow,
                connectionState: connectionState,
                sendButtonSize: sendButtonWidth,
                inputBarColorScheme: inputBarColorScheme,
                uiColorScheme: colorScheme,
                visionOSBorderColor: visionOSBorderColor,
                connectionAlertHint: connectionAlertHint,
                onSend: onSend,
                onCancel: onCancel,
                onReconnect: onReconnect
            )
        }
    }

    private struct MessageSendControl: View {
        let isSending: Bool
        let isStagingAttachments: Bool
        let canSend: Bool
        let connectionState: SendButtonConnectionState
        let sendButtonSize: CGFloat
        let inputBarColorScheme: ColorScheme
        let uiColorScheme: ColorScheme
        let visionOSBorderColor: Color
        let connectionAlertHint: String?
        let onSend: () -> Void
        let onCancel: () -> Void
        let onReconnect: () -> Void

        private var isReconnecting: Bool { connectionState == .reconnecting }
        private var isDisconnected: Bool { connectionState == .disconnected }
        private var sendActionEnabled: Bool { isSending || canSend || isDisconnected }
        private var sendIconColor: Color { .white }
        private let reconnectPulseDuration: TimeInterval = 0.8
        private var drawsDisabledSendButtonBacking: Bool {
#if os(visionOS)
            false
#else
            true
#endif
        }
        private var isPreparingSpinnerVisible: Bool {
            MessageInputBar.sendButtonShowsPreparingSpinner(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )
        }
        private var showsPrimaryIcon: Bool {
            MessageInputBar.sendButtonShowsPrimaryIcon(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )
        }

        private var bubbleVisualState: MessageInputBar.SendButtonBubbleVisualState {
            MessageInputBar.sendButtonBubbleVisualState(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )
        }

        private var bubbleColor: Color {
            let activeColor: Color = {
#if os(visionOS)
                ChatFlowTheme.sage(inputBarColorScheme)
#else
                ChatFlowTheme.sage(uiColorScheme)
#endif
            }()
            switch bubbleVisualState {
            case .ghost:
                return activeColor
            case .active:
                return activeColor
            case .reconnecting:
                return ChatFlowTheme.connectionReconnecting(inputBarColorScheme)
            case .error:
                return ChatFlowTheme.connectionDisconnected(inputBarColorScheme)
            }
        }

        private func reconnectPulsePhase(at date: Date) -> Double {
            let phase = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: reconnectPulseDuration) / reconnectPulseDuration
            return 0.5 - 0.5 * cos(phase * 2 * .pi)
        }

        private func bubbleScale(at date: Date) -> Double {
            MessageInputBar.sendButtonBubbleScale(
                state: bubbleVisualState,
                reconnectPhase: reconnectPulsePhase(at: date)
            )
        }

        var body: some View {
            Button(action: {
                if isSending {
                    onCancel()
                    return
                }
                switch connectionState {
                case .connected:
                    onSend()
                case .disconnected:
                    onReconnect()
                case .reconnecting:
                    break
                }
            }) {
                ZStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(sendIconColor)
                        .scaleEffect(0.9)
                        .opacity(isPreparingSpinnerVisible ? 1 : 0)
                        .scaleEffect(isPreparingSpinnerVisible ? 1 : 0.7)

                    Image(systemName: "stop.fill")
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(sendIconColor)
                        .opacity(isSending && !isReconnecting && !isPreparingSpinnerVisible ? 1 : 0)
                        .scaleEffect(isSending && !isReconnecting && !isPreparingSpinnerVisible ? 1 : 0.7)

                    Image(systemName: MessageInputBar.sendButtonPrimarySymbolName(connectionState: connectionState))
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(sendIconColor)
                        .opacity(showsPrimaryIcon ? 1 : 0)
                        .scaleEffect(showsPrimaryIcon ? 1 : 0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .frame(width: sendButtonSize, height: sendButtonSize)
            .background {
                if bubbleVisualState == .ghost,
                   let backingColor = MessageInputBar.disabledSendButtonBackingColor(
                    colorScheme: uiColorScheme,
                    drawsDisabledBacking: drawsDisabledSendButtonBacking
                   ) {
                    Circle()
                        .fill(backingColor)
                        .frame(width: sendButtonSize, height: sendButtonSize)
                        .blur(radius: MessageInputBar.sendButtonColoredBackingBlurRadius)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isReconnecting)) { context in
                    Circle()
                        .fill(bubbleColor)
                        .frame(width: sendButtonSize, height: sendButtonSize)
                        .scaleEffect(bubbleScale(at: context.date))
                        .blur(radius: MessageInputBar.sendButtonColoredBackingBlurRadius)
                }
            }
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(visionOSBorderColor, lineWidth: 1))
#else
            .glassEffect(.regular.interactive(), in: Circle())
#endif
            .buttonStyle(.plain)
#if os(visionOS)
            .tint(sendIconColor)
            .foregroundStyle(sendIconColor)
#endif
            .allowsHitTesting(sendActionEnabled && !isReconnecting)
            .accessibilityLabel(
                isReconnecting ? "Reconnecting" :
                    (isPreparingSpinnerVisible ? "Staging attachments" :
                        (isDisconnected ? "Disconnected. Tap to reconnect." : "Send message"))
            )
            .accessibilityHint(connectionAlertHint ?? "")
            .accessibilityIdentifier("send_button")
            .id("send-button")
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: isSending)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: canSend)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: connectionState)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: bubbleVisualState)
        }
    }

    private var micButton: some View {
        Button {
            guard !isSending else { return }
            if dictation.isStickyDictationActive {
                dictationEmitter.emit(.gestureCommitRequested(.dismissSurface))
            } else {
                startStickyFromMicTap()
            }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(inputTintColor.opacity(0.9))
                .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isStickyDictationActive ? "Stop dictation" : "Start dictation")
        .accessibilityIdentifier("dictation-mic-button")
        .disabled(isSending)
    }

    private func startStickyFromMicTap() {
        micTapActivationTask?.cancel()
        dictationEmitter.emit(.activationSelectionCaptured(selectionRange))
        let shouldPreserveKeyboardFocus = isTextFieldFocused || isKeyboardVisible
        dictationEmitter.emit(.gesturePrewarmRequested)
        withAnimation(settleSpring) {
            motion.beginProgrammaticReveal()
        }
        beginMicFadeOut(fromSwipe: false)
        micTapActivationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(settleDurationMs))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            dictationEmitter.emit(.gestureCommitRequested(.startSticky))
            motion.commitSettledState(.openListening)
            if shouldPreserveKeyboardFocus {
                requestComposeFocus()
            }
        }
    }

    private func requestComposeFocus() {
        if let onRequestDirectFocus {
            onRequestDirectFocus()
        } else {
            onFocusChange(true)
            onRequestFocus()
        }
    }

    private func handlePushChanged(startLocation: CGPoint, translation: CGPoint, velocity: CGPoint) {
        let dx = translation.x
        let dy = translation.y
        let up = max(0, -dy)
        let down = max(0, dy)
        let verticalDominant = max(up, down) >= verticalDominanceRatio * abs(dx)

        if motion.gesturePhase == .settling {
            gestureSettleTask?.cancel()
            motion.clearGestureState()
        }

        if motion.gesturePhase == .idle {
            gestureSettleTask?.cancel()
            motion.gestureBegan(
                originWasOpen: motion.isSurfaceVisible,
                swipeActivationEnabled: dictation.swipeActivationEnabled
            )
            shouldRestoreFocusAfterGestureDictationStart = isTextFieldFocused || isKeyboardVisible
            dictationEmitter.emit(.activationSelectionCaptured(selectionRange))
            dictationEmitter.emit(.gesturePrewarmRequested)
        }

        if !motion.isSurfaceVisible && !motion.swipeActivationEnabledAtGestureStart {
            dictationEmitter.emit(.gestureCancelled(trigger: "push_changed_activation_disabled"))
            withAnimation(settleSpring) {
                motion.gestureCancelled()
            }
            scheduleInsetUnfreezeAfterSettle()
            return
        }

        if !motion.isSurfaceVisible && up < verticalDominanceRatio * abs(dx) {
            if abs(dx) > up {
                dictationEmitter.emit(.gestureCancelled(trigger: "push_changed_horizontal_dominant"))
            }
            withAnimation(settleSpring) {
                motion.gestureCancelled()
            }
            scheduleInsetUnfreezeAfterSettle()
            return
        }

        motion.gestureChanged(
            translationY: dy,
            velocityY: velocity.y
        )

        if !motion.isSurfaceVisible,
           verticalDominant,
           motion.updateWalkieHoldArming(
            up: up,
            activationThreshold: walkieHoldActivationThreshold,
            holdDuration: walkieHoldDurationSeconds
           ) {
            logDictation("DICTATION_UI gesture_classification=walkie_hold_activated up=\(up) dx=\(dx) dy=\(dy)")
            dictationEmitter.emit(.gestureCommitRequested(.startWalkieTalkie))
            beginMicFadeOut(fromSwipe: false)
        }
    }

    private func handlePushEnded(
        startLocation: CGPoint,
        translation: CGPoint,
        predictedEndTranslation: CGPoint,
        velocity: CGPoint,
        wasCancelled: Bool
    ) {
        logDictation("DICTATION_UI handlePushEnded")
        guard motion.gesturePhase == .dragging else {
            return
        }
        if wasCancelled {
            shouldRestoreFocusAfterGestureDictationStart = false
            withAnimation(settleSpring) {
                motion.gestureCancelled()
            }
            scheduleInsetUnfreezeAfterSettle()
            return
        }

        let dx = translation.x
        let dy = translation.y
        let up = max(0, -dy)
        let down = max(0, dy)
        let verticalDominant = max(up, down) >= verticalDominanceRatio * abs(dx)

        let intent: DictationMotion.GestureEndIntent = withAnimation(settleSpring) {
            motion.gestureEnded(
                translationY: dy,
                predictedY: predictedEndTranslation.y,
                velocityY: velocity.y,
                context: .init(
                    pullToSendEligible: canSendNow,
                    verticallyDominant: verticalDominant
                )
            )
        }

        switch intent {
        case .send:
            shouldRestoreFocusAfterGestureDictationStart = false
            logDictation("DICTATION_UI gesture_end action=pull_to_send up=\(up) down=\(down) verticalDominant=\(verticalDominant) startedSurfaceOpen=\(motion.pushGestureStartedWithSurfaceOpen) walkieActive=\(dictation.isWalkieTalkieActive)")
            onSend()
        case .dismissSurface:
            shouldRestoreFocusAfterGestureDictationStart = false
            dictationEmitter.emit(.gestureCommitRequested(.dismissSurface))
        case .startSticky:
            logDictation("DICTATION_UI gesture_end classification=sticky_start up=\(up) down=\(down)")
            dictationEmitter.emit(.gestureCommitRequested(.startSticky))
            beginMicFadeOut(fromSwipe: false)
            if shouldRestoreFocusAfterGestureDictationStart {
                requestComposeFocus()
            }
            shouldRestoreFocusAfterGestureDictationStart = false
        case .endWalkieKeepOpen:
            shouldRestoreFocusAfterGestureDictationStart = false
            logDictation("DICTATION_UI gesture_end classification=walkie_release_keep_open up=\(up) down=\(down)")
            dictationEmitter.emit(.gestureCommitRequested(.endWalkieTalkie))
        case .endWalkieAndDismiss:
            shouldRestoreFocusAfterGestureDictationStart = false
            logDictation("DICTATION_UI gesture_end classification=walkie_release_dismiss up=\(up) down=\(down)")
            dictationEmitter.emit(.gestureCommitRequested(.dismissSurface))
        case .settleClosed:
            shouldRestoreFocusAfterGestureDictationStart = false
            break
        case .settleOpen:
            shouldRestoreFocusAfterGestureDictationStart = false
            break
        case .none:
            shouldRestoreFocusAfterGestureDictationStart = false
            break
        }
        scheduleInsetUnfreezeAfterSettle()
    }

    private func shouldBeginDictationPan(startLocation: CGPoint, velocity: CGPoint) -> Bool {
        _ = velocity
        let shouldBegin = shouldBeginDictationPanGesture(
            startedInEditableRegion: startsInEditableRegion(startLocation: startLocation),
            isSurfaceVisible: motion.isSurfaceVisible,
            swipeActivationEnabled: dictation.swipeActivationEnabled,
            hasSelection: selectionRange.length > 0,
            startedInSelectionGestureRegion: startsInSelectionGestureRegion(startLocation: startLocation)
        )
        if shouldBegin {
            shouldRestoreFocusAfterGestureDictationStart = isTextFieldFocused || isKeyboardVisible
        }
        return shouldBegin
    }

    private func startsInEditableRegion(startLocation: CGPoint) -> Bool {
        textEditorGlobalFrame != .zero && textEditorGlobalFrame.contains(startLocation)
    }

    private func startsInSelectionGestureRegion(startLocation: CGPoint) -> Bool {
        guard selectionRange.length > 0, textEditorGlobalFrame != .zero else { return false }
        return textEditorGlobalFrame.insetBy(dx: -24, dy: -24).contains(startLocation)
    }

    @ViewBuilder
    private var dictationSurface: some View {
        if dictation.showsComposeKeyPromptModal {
            dictationKeyEntryContent
        } else {
            dictationWaveformContent
        }
    }

    private var dictationWaveformContent: some View {
        let statusText: String
        let statusColor: Color
        if let message = dictation.errorMessage {
            statusText = message
            statusColor = .red
        } else if isPausedSurfaceState {
            statusText = "Paused"
            statusColor = .secondary
        } else {
            statusText = "Listening..."
            statusColor = .secondary
        }

        return VStack(alignment: .center, spacing: 8) {
            waveformLine
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    dictationEmitter.emit(.waveformToggleRequested)
                }
                .onLongPressGesture(
                    minimumDuration: 0.35,
                    maximumDistance: 24,
                    pressing: { isPressing in
                        guard !isPressing, waveformDidStartWalkie else { return }
                        waveformDidStartWalkie = false
                        dictationEmitter.emit(.gestureCommitRequested(.endWalkieTalkie))
                    },
                    perform: {
                        guard isPausedSurfaceState else { return }
                        waveformDidStartWalkie = true
                        dictationEmitter.emit(.gestureCommitRequested(.resumeWalkieTalkieFromPaused))
                    }
                )

            Text(statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .onAppear {
                    if let message = dictation.errorMessage {
                        logDictation("DICTATION_ERROR ui_display ts=\(Date().timeIntervalSince1970) message=\(message)")
                    }
                }
                .onChange(of: dictation.errorMessage) { _, newValue in
                    if let message = newValue {
                        logDictation("DICTATION_ERROR ui_display ts=\(Date().timeIntervalSince1970) message=\(message)")
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 100, alignment: .top)
#if os(visionOS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#else
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#endif
    }

    private var dictationKeyTextBinding: Binding<String> {
        Binding(
            get: { dictation.inlineKeyText },
            set: { dictationEmitter.emit(.inlineKeyTextChanged($0)) }
        )
    }

    private var dictationKeyEntryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SonioxKeyConfigurationRow(
                keyText: dictationKeyTextBinding,
                status: dictation.inlineKeyStatus,
                actionTitle: dictation.inlineKeyActionTitle,
                onAction: {
                    Task { @MainActor in
                        await dictationEmitter.performComposeKeyPrimaryAction { url in
                            openURL(url)
                        }
                    }
                },
                placeholder: "Soniox API Key",
                style: .surface,
                colorSchemeOverride: .dark
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 100, alignment: .top)
#if os(visionOS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#else
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#endif
    }

    private var pullToSendIndicator: some View {
        let subtitle: String = {
            if !pullToSendEligible {
                return "Nothing to send"
            }
            return motion.isPullToSendArmed ? "Release to send" : "Pull up to send"
        }()

        return HStack(spacing: 8) {
            Image(systemName: motion.isPullToSendArmed ? "paperplane.fill" : "arrow.up.circle")
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle({
            if !pullToSendEligible { return AnyShapeStyle(.secondary) }
            if motion.isPullToSendArmed { return AnyShapeStyle(ChatFlowTheme.adminAccent(colorScheme)) }
            return AnyShapeStyle(inputTintColor.opacity(0.9))
        }())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var waveformLine: some View {
        DictationWaveformLine(
            reduceMotion: reduceMotionForDictation,
            isPaused: isPausedSurfaceState,
            audioLevel: dictation.audioLevel,
            colorScheme: colorScheme
        )
    }

    private func beginMicFadeOut(fromSwipe: Bool) {
        let animationPlan = DictationMicAffordanceAnimationPlan.make(fromSwipe: fromSwipe)

        micFadeTask?.cancel()
        micTransientVisible = true
        micTransientOpacity = 1
        micTransientOffset = animationPlan.initialOffset

        if let slideDurationMs = animationPlan.slideDurationMs {
            Task { @MainActor in
                // Ensure first frame renders at the right-edge offset before sliding inward.
                await Task.yield()
                withAnimation(.easeOut(duration: Double(slideDurationMs) / 1_000)) {
                    micTransientOffset = 0
                }
            }
        } else {
            micTransientOffset = 0
        }

        micFadeTask = Task { @MainActor in
            if animationPlan.fadeDelayMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(animationPlan.fadeDelayMs))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }

            withAnimation(.easeOut(duration: Double(animationPlan.fadeDurationMs) / 1_000)) {
                micTransientOpacity = 0
            }

            let cleanupDelayMs = animationPlan.fadeDurationMs + animationPlan.cleanupTailMs
            do {
                try await Task.sleep(for: .milliseconds(cleanupDelayMs))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            micTransientVisible = false
            micTransientOpacity = 0
            micTransientOffset = 0
        }
    }

    private func scheduleInsetUnfreezeAfterSettle() {
        gestureSettleTask?.cancel()
        let commitTarget = motion.pendingCommit?.target ?? motion.settledSurface
        gestureSettleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(settleDurationMs))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            motion.commitSettledState(commitTarget)
        }
    }

    private func resetMotionToCurrentProjection() {
        guard motion.gesturePhase != .dragging else { return }
        gestureSettleTask?.cancel()
        shouldRestoreFocusAfterGestureDictationStart = false
        motion.clearGestureState()
        motion.settle(to: dictation.surfaceTarget)
    }

    private func logDictation(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

struct DictationMicAffordanceAnimationPlan {
    let initialOffset: CGFloat
    let slideDurationMs: Int?
    let fadeDelayMs: Int
    let fadeDurationMs: Int
    let cleanupTailMs: Int

    static func make(fromSwipe: Bool) -> Self {
        if fromSwipe {
            // Spec: swipe-left retrieval should visibly re-enter from the right over 350ms.
            return Self(
                initialOffset: 28,
                slideDurationMs: 350,
                fadeDelayMs: 350,
                fadeDurationMs: 850,
                cleanupTailMs: 80
            )
        }

        return Self(
            initialOffset: 0,
            slideDurationMs: nil,
            fadeDelayMs: 0,
            fadeDurationMs: 1_200,
            cleanupTailMs: 80
        )
    }
}

#Preview("Message Input") {
    @Previewable @State var content = NSAttributedString(string: "Hello")
    @Previewable @State var selection = NSRange(location: 5, length: 0)
    @Previewable @State var connectionStateStore = SendButtonConnectionStateStore(value: .connected)
    let draftHost = PreviewDictationDraftHost()
    let dictation = DictationCoordinator(
        bridge: DictationTranscriptApplicator(host: draftHost),
        keyStore: SonioxKeyStore()
    )
    let motion = DictationMotion(session: dictation)
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                content: $content,
                selectionRange: $selection,
                pendingInsertions: .constant([]),
                dictation: DictationInteractionProjection(session: dictation),
                dictationEmitter: DictationInteractionEmitter(
                    emit: { intent in
                        switch intent {
                        case .activationSelectionCaptured(let selectionRange):
                            dictation.captureComposeSelectionRangeForActivation(selectionRange)
                        case .composeSelectionChanged:
                            break
                        case .composeUserEdited(let range, let replacementUTF16Length):
                            dictation.noteComposeUserEditDuringDictation(
                                editedRangeUTF16: range,
                                replacementUTF16Length: replacementUTF16Length
                            )
                        case .composeTextViewChanged(let textView):
                            dictation.setComposeTextView(textView)
                        case .gesturePrewarmRequested:
                            dictation.beginGesturePrewarm()
                        case .gestureCancelled(let trigger):
                            dictation.cancelGesturePrewarmIfNeeded(trigger: trigger)
                        case .gestureCommitRequested(let commitIntent):
                            switch commitIntent {
                            case .startSticky:
                                dictation.startStickyDictation()
                            case .startWalkieTalkie:
                                dictation.startWalkieTalkieDictation()
                            case .dismissSurface:
                                dictation.dismissSurfaceFromUserGesture()
                            case .endWalkieTalkie:
                                dictation.endWalkieTalkieIfNeeded()
                            case .resumeWalkieTalkieFromPaused:
                                dictation.startWalkieTalkieFromPausedSurface()
                            }
                        case .stopRequested(let source):
                            switch source {
                            case .escapeKey:
                                dictation.stopFromEscapeKey()
                            case .voiceOverAction:
                                dictation.stopFromVoiceOverAction()
                            }
                        case .discardRequested(let source):
                            switch source {
                            case .escapeLongPress:
                                dictation.discardFromEscapeLongPress()
                            case .voiceOverAction:
                                dictation.discardFromVoiceOverAction()
                            }
                        case .waveformToggleRequested:
                            dictation.toggleWaveformTapAction()
                        case .inlineKeyTextChanged(let value):
                            dictation.updateInlineKeyText(value)
                        }
                    },
                    performComposeKeyPrimaryAction: { openURL in
                        await dictation.handleComposeKeyPrimaryAction(openKeyURL: openURL)
                    }
                ),
                placeholderText: "Message",
                resetToken: 0,
                canSend: true,
                isSending: false,
                isStagingAttachments: false,
                connectionStateStore: connectionStateStore,
                focusTrigger: 0,
                dismissTrigger: 0,
                isTextFieldFocused: false,
                bottomSafeAreaInset: 34,
                isKeyboardVisible: false,
                isAttachmentMenuPresented: .constant(false),
                onSend: {},
                onCancel: {},
                onReconnect: {},
                onAdd: {},
                attachmentMenuContent: { AnyView(EmptyView()) },
                onFocusChange: { _ in },
                onRequestFocus: {},
                onPasteImages: nil,
                motion: motion,
                isCompact: true
            )
        }
}

@MainActor
private final class PreviewDictationDraftHost: DictationComposeDraftHosting {
    var activeSessionKey: String = "preview"

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        .empty
    }

    func applyComposeDraftDelta(
        baseSnapshot: ComposeDraftSnapshot,
        previousTranscriptUTF16Length: Int,
        replacementText: NSAttributedString,
        to sessionKey: String,
        moveCursorToEnd: Bool
    ) {}

    func applyComposeDraftSnapshot(_ snapshot: ComposeDraftSnapshot,
                                   to sessionKey: String,
                                   moveCursorToEnd: Bool,
                                   announceEditorReset: Bool) {}
}
