//
//  StreamPageDotsView.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct StreamPageDotsView: View {
    @Environment(\.colorScheme) private var colorScheme

    let sessionKeys: [String]
    let activeSessionKey: String
    let dotStatesBySession: [String: StreamDotState]
    let maxWidth: CGFloat?
    let onTap: () -> Void
    let onScrubPreview: (String) -> Void
    let onScrubCommit: (String) -> Void
    let onScrubCancel: () -> Void
    let onScrubCandidateHaptic: (ScrubCandidateHapticStyle) -> Void

    @State private var scrubStartLocationX: CGFloat?
    @State private var scrubStartVirtualIndex: CGFloat?
    @State private var scrubVirtualIndex: CGFloat?
    @State private var scrubCandidateIndex: Int?
    @State private var scrubIsCancelled = false
    @State private var scrubTapSuppressionExpiresAt = Date.distantPast

    private static let collapsedMaxVisibleDots = 11
    private static let dotDiameter: CGFloat = 7
    private static let overflowDotDiameter: CGFloat = 4
    private static let dotSpacing: CGFloat = 7
    private static let horizontalPadding: CGFloat = 12
    private static let minimumHitTargetHeight: CGFloat = 44
    private static let scrubTapSuppressionDuration: TimeInterval = 0.45
    private static let scrubWaveLiftPerScalePoint: CGFloat = 20
    static let controlHeight: CGFloat = 23
    static func unreadEdgeBloomBlurRadius(colorScheme: ColorScheme) -> CGFloat {
        colorScheme == .dark ? 4.5 : 4.0
    }
    static func unreadEdgeBloomOpacity(colorScheme: ColorScheme) -> Double {
        0.40
    }

    private var activeIndex: Int {
        sessionKeys.firstIndex(of: activeSessionKey) ?? 0
    }

    private var isScrubbing: Bool {
        !scrubIsCancelled && (scrubStartVirtualIndex != nil || scrubVirtualIndex != nil)
    }

    private var hasActiveScrubGesture: Bool {
        scrubStartVirtualIndex != nil || scrubVirtualIndex != nil || scrubCandidateIndex != nil
    }

    private var baseVisibleDotCount: Int {
        Self.fittingVisibleDotCount(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
    }

    private var maxVisibleDots: Int {
        guard isScrubbing else { return baseVisibleDotCount }
        return Self.fittingVisibleDotCount(totalSessionCount: sessionKeys.count, maxWidth: scrubMetrics.scrubFieldWidth)
    }

    private var baseControlWidth: CGFloat {
        Self.renderedControlWidth(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
    }

    private var scrubMetrics: ScrubLayoutMetrics {
        Self.scrubLayoutMetrics(
            totalSessionCount: sessionKeys.count,
            visibleDotCount: baseVisibleDotCount,
            controlWidth: baseControlWidth,
            maxWidth: maxWidth,
            isScrubbing: isScrubbing
        )
    }

    private var expandedWidthBudget: CGFloat? {
        guard shouldExpandToMaxWidth else { return nil }
        return maxWidth
    }

    private var shouldExpandToMaxWidth: Bool {
        guard maxWidth != nil else { return false }
        return sessionKeys.count > Self.collapsedMaxVisibleDots
    }

    private var visibleDotIndices: [Int] {
        let centerIndex = Int((scrubVirtualIndex ?? CGFloat(activeIndex)).rounded())
        guard sessionKeys.count > maxVisibleDots else {
            return Array(sessionKeys.indices)
        }
        let halfWindow = maxVisibleDots / 2
        let maxStart = sessionKeys.count - maxVisibleDots
        let start = min(max(0, centerIndex - halfWindow), maxStart)
        return Array(start..<(start + maxVisibleDots))
    }

    private var showsLeadingOverflow: Bool {
        (visibleDotIndices.first ?? 0) > 0
    }

    private var showsTrailingOverflow: Bool {
        (visibleDotIndices.last ?? -1) < sessionKeys.count - 1
    }

    private var hasHiddenUnreadLeading: Bool {
        guard let firstVisibleIndex = visibleDotIndices.first, firstVisibleIndex > 0 else {
            return false
        }
        return sessionKeys[..<firstVisibleIndex].contains { dotStatesBySession[$0] == .unread }
    }

    private var hasHiddenUnreadTrailing: Bool {
        guard let lastVisibleIndex = visibleDotIndices.last, lastVisibleIndex < sessionKeys.count - 1 else {
            return false
        }
        return sessionKeys[(lastVisibleIndex + 1)...].contains { dotStatesBySession[$0] == .unread }
    }

    private var warningBloomColor: Color {
        ChatFlowTheme.unreadIndicator(colorScheme)
    }

    static func fittingVisibleDotCount(totalSessionCount: Int, maxWidth: CGFloat?) -> Int {
        let collapsedCount = min(totalSessionCount, collapsedMaxVisibleDots)
        guard totalSessionCount > collapsedMaxVisibleDots, let maxWidth else {
            return collapsedCount
        }

        var bestCount = collapsedCount
        for candidateCount in collapsedCount...totalSessionCount {
            let requiredWidth = requiredControlWidth(
                visibleDotCount: candidateCount,
                includesOverflowIndicators: candidateCount < totalSessionCount
            )
            if requiredWidth <= maxWidth {
                bestCount = candidateCount
            } else {
                break
            }
        }
        return bestCount
    }

    static func requiredControlWidth(
        visibleDotCount: Int,
        includesOverflowIndicators: Bool
    ) -> CGFloat {
        let overflowCount = includesOverflowIndicators ? 2 : 0
        let elementCount = visibleDotCount + overflowCount
        let totalDotWidth = (CGFloat(visibleDotCount) * dotDiameter)
            + (CGFloat(overflowCount) * overflowDotDiameter)
        let totalSpacing = CGFloat(max(0, elementCount - 1)) * dotSpacing
        return totalDotWidth + totalSpacing + (horizontalPadding * 2)
    }

    static func targetControlWidth(totalSessionCount: Int, maxWidth: CGFloat?) -> CGFloat? {
        guard totalSessionCount > collapsedMaxVisibleDots, let maxWidth else { return nil }
        let collapsedWidth = requiredControlWidth(
            visibleDotCount: collapsedMaxVisibleDots,
            includesOverflowIndicators: true
        )
        let visibleDotCount = fittingVisibleDotCount(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
        guard visibleDotCount > collapsedMaxVisibleDots else { return nil }
        guard maxWidth > collapsedWidth else { return nil }
        let requiredWidth = requiredControlWidth(
            visibleDotCount: visibleDotCount,
            includesOverflowIndicators: visibleDotCount < totalSessionCount
        )
        return min(maxWidth, requiredWidth)
    }

    static func renderedControlWidth(totalSessionCount: Int, maxWidth: CGFloat?) -> CGFloat {
        let visibleDotCount = fittingVisibleDotCount(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
        let includesOverflowIndicators = visibleDotCount < totalSessionCount
        return targetControlWidth(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
            ?? requiredControlWidth(
                visibleDotCount: visibleDotCount,
                includesOverflowIndicators: includesOverflowIndicators
            )
    }

    struct ScrubLayoutMetrics: Equatable {
        let scrubFieldWidth: CGFloat
        let magnificationRadius: CGFloat
        let magnificationSigma: CGFloat
        let maximumScale: CGFloat
    }

    enum ScrubCandidateHapticStyle: Equatable {
        case light
        case strong
    }

    static func scrubLayoutMetrics(
        totalSessionCount: Int,
        visibleDotCount: Int,
        controlWidth: CGFloat,
        maxWidth: CGFloat?,
        isScrubbing: Bool
    ) -> ScrubLayoutMetrics {
        guard totalSessionCount > 0 else {
            return ScrubLayoutMetrics(
                scrubFieldWidth: controlWidth,
                magnificationRadius: 6.5,
                magnificationSigma: 2.3,
                maximumScale: 2.85
            )
        }

        let visibleRatio = min(1, CGFloat(max(1, visibleDotCount)) / CGFloat(totalSessionCount))
        let hiddenPressure = 1 - visibleRatio
        let widthBudget = max(controlWidth, maxWidth ?? controlWidth)
        let fullContentWidth = requiredControlWidth(
            visibleDotCount: totalSessionCount,
            includesOverflowIndicators: false
        )
        let edgeExpansion = isScrubbing
            ? min(112, max(32, widthBudget * (0.12 + (0.28 * hiddenPressure))))
            : 0
        let scrubFieldWidth = min(fullContentWidth, controlWidth + (edgeExpansion * 2))
        let widthGainRatio = max(0, (scrubFieldWidth - controlWidth) / max(controlWidth, 1))

        // Dock equation: hidden pressure opens a wider temporary field, then field gain broadens
        // the influence radius and raises the peak. Radius controls the tail reach; sigma controls
        // the high central spike so it can broaden without translating the whole row.
        let baseMagnificationRadius = min(5.25, max(3.25, 3.35 + (1.35 * hiddenPressure) + (0.35 * widthGainRatio)))
        let magnificationRadius = baseMagnificationRadius * 2
        let magnificationSigma = max(2.3, magnificationRadius * 0.36)
        let maximumScale = min(3.35, max(2.85, 2.88 + (0.34 * hiddenPressure) + (0.20 * widthGainRatio)))

        return ScrubLayoutMetrics(
            scrubFieldWidth: scrubFieldWidth,
            magnificationRadius: magnificationRadius,
            magnificationSigma: magnificationSigma,
            maximumScale: maximumScale
        )
    }

    var body: some View {
        controlBody
        .contentShape(Rectangle())
        .overlay {
            gestureLayer
        }
        .onDisappear {
            cancelScrubIfNeeded()
        }
        .onChange(of: activeSessionKey) { _, _ in
            resetScrubState()
        }
        .onChange(of: sessionKeys) { _, _ in
            resetScrubState()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open stream manager"), onTap)
        .accessibilityLabel("Manage streams")
        .accessibilityValue("Stream \(activeIndex + 1) of \(sessionKeys.count)")
        .accessibilityHint("Tap to open stream manager. Long press and drag to preview streams.")
    }

    private func handleTap() {
        guard Date() >= scrubTapSuppressionExpiresAt else { return }
        onTap()
    }

    @ViewBuilder
    private var gestureLayer: some View {
#if canImport(UIKit)
        StreamPageDotsGestureBridge(
            onTap: handleTap,
            onScrubBegan: beginScrub(at:),
            onScrubChanged: updateScrub(at:),
            onScrubEnded: endScrub(at:),
            onScrubCancelled: cancelScrub
        )
        .frame(width: scrubMetrics.scrubFieldWidth, height: Self.minimumHitTargetHeight)
#else
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: handleTap)
            .gesture(scrubGesture)
            .frame(width: scrubMetrics.scrubFieldWidth, height: Self.minimumHitTargetHeight)
#endif
    }

    private var controlBody: some View {
        let controlWidth = baseControlWidth
        let scrubFieldWidth = scrubMetrics.scrubFieldWidth
        return ZStack(alignment: .bottom) {
            dockChrome(controlWidth: controlWidth)
                .frame(maxHeight: .infinity, alignment: .bottom)

            dotRow
                .frame(width: scrubFieldWidth, height: Self.controlHeight, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: scrubFieldWidth, height: Self.minimumHitTargetHeight, alignment: .bottom)
    }

    private func dockChrome(controlWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: controlWidth, height: Self.controlHeight)
            .background {
                unreadEdgeBloomOverlay
                    .mask(Capsule())
                    .blur(radius: Self.unreadEdgeBloomBlurRadius(colorScheme: colorScheme))
                    .allowsHitTesting(false)
            }
#if !os(visionOS)
            .glassEffect(.regular.interactive(), in: Capsule())
#else
            .background(.regularMaterial, in: Capsule())
#endif
#if os(visionOS)
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            }
#endif
    }

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginScrub(at: activeDotCenterX)
                case .second(true, let dragValue):
                    if let dragValue {
                        beginScrub(at: dragValue.startLocation.x)
                        updateScrub(at: dragValue.location)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .first(true):
                    commitScrub()
                case .second(true, let dragValue):
                    if let dragValue {
                        updateScrub(at: dragValue.location)
                    }
                    commitScrub()
                default:
                    cancelScrub()
                }
            }
    }

    private func beginScrub(at locationX: CGFloat) {
        guard !sessionKeys.isEmpty else { return }
        guard scrubStartVirtualIndex == nil else { return }
        scrubTapSuppressionExpiresAt = Date().addingTimeInterval(Self.scrubTapSuppressionDuration)
        let controlWidth = baseControlWidth
        let dockLocationX = dockLocationX(fromScrubFieldLocationX: locationX)
        let virtualIndex = Self.scrubStartVirtualIndex(
            startLocationX: dockLocationX,
            fieldWidth: controlWidth,
            totalSessionCount: sessionKeys.count,
            visibleDotIndices: visibleDotIndices,
            fallbackIndex: activeIndex
        )
        withAnimation(.spring(response: 0.18, dampingFraction: 0.86)) {
            scrubStartLocationX = dockLocationX
            scrubStartVirtualIndex = virtualIndex
            scrubIsCancelled = false
        }
        updateScrubVirtualIndex(virtualIndex)
    }

    private func updateScrub(at location: CGPoint) {
        guard !sessionKeys.isEmpty else { return }
        if scrubStartVirtualIndex == nil {
            beginScrub(at: location.x)
        }
        guard let startVirtualIndex = scrubStartVirtualIndex, let startLocationX = scrubStartLocationX else { return }
        if Self.shouldCancelScrub(locationY: location.y) {
            enterScrubCancelledState()
            return
        }

        let dockLocationX = dockLocationX(fromScrubFieldLocationX: location.x)
        if scrubIsCancelled {
            scrubIsCancelled = false
        }

        let virtualIndex = Self.scrubVirtualIndex(
            sessionCount: sessionKeys.count,
            startVirtualIndex: startVirtualIndex,
            startLocationX: startLocationX,
            currentLocationX: dockLocationX
        )
        updateScrubVirtualIndex(virtualIndex)
    }

    private func endScrub(at location: CGPoint) {
        updateScrub(at: location)
        guard !scrubIsCancelled else {
            resetScrubState()
            return
        }
        commitScrub()
    }

    private func updateScrubVirtualIndex(_ virtualIndex: CGFloat) {
        guard sessionKeys.indices.contains(Self.scrubCandidateIndex(sessionCount: sessionKeys.count, virtualIndex: virtualIndex)) else { return }
        scrubVirtualIndex = virtualIndex
        let candidateIndex = Self.scrubCandidateIndex(sessionCount: sessionKeys.count, virtualIndex: virtualIndex)
        let previousIndex = scrubCandidateIndex
        guard previousIndex != candidateIndex else { return }
        scrubCandidateIndex = candidateIndex
        onScrubPreview(sessionKeys[candidateIndex])
        if Self.shouldEmitScrubCandidateHaptic(previousIndex: previousIndex, candidateIndex: candidateIndex) {
            let sessionKey = sessionKeys[candidateIndex]
            onScrubCandidateHaptic(
                Self.scrubCandidateHapticStyle(
                    isActive: candidateIndex == activeIndex,
                    dotState: dotStatesBySession[sessionKey] ?? .inactive
                )
            )
        }
    }

    private func commitScrub() {
        guard let index = scrubCandidateIndex, sessionKeys.indices.contains(index) else {
            cancelScrub()
            return
        }
        let sessionKey = sessionKeys[index]
        resetScrubState()
        onScrubCommit(sessionKey)
    }

    private func cancelScrub() {
        resetScrubState()
        onScrubCancel()
    }

    private func enterScrubCancelledState() {
        guard !scrubIsCancelled || scrubCandidateIndex != nil || scrubVirtualIndex != nil else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            scrubIsCancelled = true
            scrubVirtualIndex = nil
            scrubCandidateIndex = nil
        }
        onScrubCancel()
    }

    private func dockLocationX(fromScrubFieldLocationX locationX: CGFloat) -> CGFloat {
        Self.dockLocationX(
            fromScrubFieldLocationX: locationX,
            scrubFieldWidth: scrubMetrics.scrubFieldWidth,
            baseControlWidth: baseControlWidth
        )
    }

    private func cancelScrubIfNeeded() {
        guard hasActiveScrubGesture else { return }
        cancelScrub()
    }

    private func resetScrubState() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            scrubStartLocationX = nil
            scrubStartVirtualIndex = nil
            scrubVirtualIndex = nil
            scrubCandidateIndex = nil
            scrubIsCancelled = false
        }
    }

    private var activeDotCenterX: CGFloat {
        Self.dotCenterX(
            for: activeIndex,
            totalSessionCount: sessionKeys.count,
            visibleDotIndices: visibleDotIndices,
            fieldWidth: baseControlWidth
        ) ?? (baseControlWidth / 2)
    }

    private var dotRow: some View {
        let fieldWidth = scrubMetrics.scrubFieldWidth
        return ZStack {
            dotRowDots
            selectionRingOverlay(fieldWidth: fieldWidth)
        }
        .frame(width: fieldWidth, height: Self.controlHeight)
    }

    private var dotRowDots: some View {
        let selectionRingIndex = Self.selectionRingIndex(
            activeIndex: activeIndex,
            scrubCandidateIndex: scrubCandidateIndex,
            sessionCount: sessionKeys.count
        )
        return HStack(spacing: 7) {
            if showsLeadingOverflow {
                Circle()
                    .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                    .frame(width: 4, height: 4)
            }
            ForEach(visibleDotIndices, id: \.self) { index in
                let sessionKey = sessionKeys[index]
                let isActive = index == activeIndex
                let isCandidate = index == scrubCandidateIndex
                let showsSelectionRing = index == selectionRingIndex
                let dotState = dotStatesBySession[sessionKey] ?? .inactive
                let scale = Self.scrubMagnificationScale(
                    dotIndex: index,
                    virtualIndex: scrubVirtualIndex,
                    metrics: scrubMetrics
                )
                let verticalOffset = Self.scrubMagnificationVerticalOffset(scale: scale)
                Circle()
                    .fill(
                        StreamDotColor.resolve(
                            isActive: isActive,
                            dotState: dotState,
                            colorScheme: colorScheme
                        )
                    )
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                    .scaleEffect(scale)
                    .offset(y: verticalOffset)
                    .zIndex(scale)
                    .shadow(
                        color: (isActive || isCandidate || showsSelectionRing) ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                        radius: (isActive || isCandidate || showsSelectionRing) ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
                    )
                    .shadow(
                        color: (isActive || isCandidate || showsSelectionRing) ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                        radius: (isActive || isCandidate || showsSelectionRing) ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
                    )
            }
            if showsTrailingOverflow {
                Circle()
                    .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                    .frame(width: 4, height: 4)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func selectionRingOverlay(fieldWidth: CGFloat) -> some View {
        let selectionRingIndex = Self.selectionRingIndex(
            activeIndex: activeIndex,
            scrubCandidateIndex: scrubCandidateIndex,
            sessionCount: sessionKeys.count
        )
        if let selectionRingIndex,
           let centerX = Self.dotCenterX(
               for: selectionRingIndex,
               totalSessionCount: sessionKeys.count,
               visibleDotIndices: visibleDotIndices,
               fieldWidth: fieldWidth
           ) {
            let scale = Self.scrubMagnificationScale(
                dotIndex: selectionRingIndex,
                virtualIndex: scrubVirtualIndex,
                metrics: scrubMetrics
            )
            let verticalOffset = Self.scrubMagnificationVerticalOffset(scale: scale)
            ZStack {
                Circle()
                    .stroke(StreamDotColor.activeGlow(colorScheme: colorScheme).opacity(0.85), lineWidth: 1.2)
                    .scaleEffect(1.16)
                Circle()
                    .stroke(Color.white.opacity(0.82), lineWidth: 0.55)
                    .scaleEffect(1.07)
            }
            .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            .scaleEffect(scale)
            .position(x: centerX, y: (Self.controlHeight / 2) + verticalOffset)
            .zIndex(scale + 1)
            .allowsHitTesting(false)
        }
    }

    private var unreadEdgeBloomOverlay: some View {
        ZStack {
            if hasHiddenUnreadLeading {
                edgeWarningBloom(edge: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasHiddenUnreadTrailing {
                edgeWarningBloom(edge: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func edgeWarningBloom(edge: HorizontalEdge) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(warningBloomColor.opacity(Self.unreadEdgeBloomOpacity(colorScheme: colorScheme)))
                .frame(width: 18, height: 16)
        }
        .frame(width: 20, height: 18)
        .offset(x: edge == .leading ? -4 : 4)
    }

    static func scrubStartCandidateIndex(
        startLocationX: CGFloat,
        fieldWidth: CGFloat,
        totalSessionCount: Int,
        visibleDotIndices: [Int],
        fallbackIndex: Int
    ) -> Int {
        scrubCandidateIndex(
            sessionCount: totalSessionCount,
            virtualIndex: scrubStartVirtualIndex(
                startLocationX: startLocationX,
                fieldWidth: fieldWidth,
                totalSessionCount: totalSessionCount,
                visibleDotIndices: visibleDotIndices,
                fallbackIndex: fallbackIndex
            )
        )
    }

    static func scrubStartVirtualIndex(
        startLocationX: CGFloat,
        fieldWidth: CGFloat,
        totalSessionCount: Int,
        visibleDotIndices: [Int],
        fallbackIndex: Int
    ) -> CGFloat {
        let centers = visibleDotCenters(
            totalSessionCount: totalSessionCount,
            visibleDotIndices: visibleDotIndices,
            fieldWidth: fieldWidth
        )
        guard let firstCenter = centers.first else {
            return CGFloat(fallbackIndex)
        }
        guard centers.count > 1 else { return CGFloat(firstCenter.index) }
        if startLocationX <= firstCenter.centerX {
            return CGFloat(firstCenter.index)
        }
        for (left, right) in zip(centers, centers.dropFirst()) {
            guard startLocationX <= right.centerX else { continue }
            let span = max(1, right.centerX - left.centerX)
            let progress = min(1, max(0, (startLocationX - left.centerX) / span))
            return CGFloat(left.index) + (CGFloat(right.index - left.index) * progress)
        }
        return CGFloat(centers[centers.count - 1].index)
    }

    static func scrubCandidateIndex(
        sessionCount: Int,
        startIndex: Int,
        translationWidth: CGFloat
    ) -> Int {
        guard sessionCount > 0 else { return 0 }
        let step = dotDiameter + dotSpacing
        let delta = Int((translationWidth / step).rounded())
        return min(max(0, startIndex + delta), sessionCount - 1)
    }

    static func scrubVirtualIndex(
        sessionCount: Int,
        startVirtualIndex: CGFloat,
        startLocationX: CGFloat,
        currentLocationX: CGFloat
    ) -> CGFloat {
        guard sessionCount > 0 else { return 0 }
        let step = dotDiameter + dotSpacing
        let delta = (currentLocationX - startLocationX) / step
        return min(max(0, startVirtualIndex + delta), CGFloat(sessionCount - 1))
    }

    static func scrubCandidateIndex(sessionCount: Int, virtualIndex: CGFloat) -> Int {
        guard sessionCount > 0 else { return 0 }
        return min(max(0, Int(virtualIndex.rounded())), sessionCount - 1)
    }

    static func dockLocationX(
        fromScrubFieldLocationX locationX: CGFloat,
        scrubFieldWidth: CGFloat,
        baseControlWidth: CGFloat
    ) -> CGFloat {
        let fieldExtra = max(0, scrubFieldWidth - baseControlWidth)
        return locationX - (fieldExtra / 2)
    }

    static func shouldCancelScrub(locationY: CGFloat) -> Bool {
        let indicatorTopY = minimumHitTargetHeight - controlHeight
        let indicatorBottomY = minimumHitTargetHeight
        if locationY < indicatorTopY {
            return (indicatorTopY - locationY) > minimumHitTargetHeight
        }
        if locationY > indicatorBottomY {
            return (locationY - indicatorBottomY) > minimumHitTargetHeight
        }
        return false
    }

    static func shouldEmitScrubCandidateHaptic(previousIndex: Int?, candidateIndex: Int) -> Bool {
        guard let previousIndex else { return false }
        return previousIndex != candidateIndex
    }

    static func selectionRingIndex(activeIndex: Int, scrubCandidateIndex: Int?, sessionCount: Int) -> Int? {
        guard sessionCount > 0 else { return nil }
        if let scrubCandidateIndex, (0..<sessionCount).contains(scrubCandidateIndex) {
            return scrubCandidateIndex
        }
        return min(max(0, activeIndex), sessionCount - 1)
    }

    static func dotCenterX(
        for index: Int,
        totalSessionCount: Int,
        visibleDotIndices: [Int],
        fieldWidth: CGFloat
    ) -> CGFloat? {
        visibleDotCenters(
            totalSessionCount: totalSessionCount,
            visibleDotIndices: visibleDotIndices,
            fieldWidth: fieldWidth
        )
        .first { $0.index == index }?
        .centerX
    }

    static func visibleDotCenters(
        totalSessionCount: Int,
        visibleDotIndices: [Int],
        fieldWidth: CGFloat
    ) -> [(index: Int, centerX: CGFloat)] {
        guard totalSessionCount > 0, !visibleDotIndices.isEmpty else { return [] }

        let includesLeadingOverflow = (visibleDotIndices.first ?? 0) > 0
        let includesTrailingOverflow = (visibleDotIndices.last ?? -1) < totalSessionCount - 1
        let overflowCount = (includesLeadingOverflow ? 1 : 0) + (includesTrailingOverflow ? 1 : 0)
        let elementCount = visibleDotIndices.count + overflowCount
        let contentWidth = (CGFloat(visibleDotIndices.count) * dotDiameter)
            + (CGFloat(overflowCount) * overflowDotDiameter)
            + (CGFloat(max(0, elementCount - 1)) * dotSpacing)
            + (horizontalPadding * 2)
        var cursor = ((fieldWidth - contentWidth) / 2) + horizontalPadding
        var centers: [(index: Int, centerX: CGFloat)] = []

        if includesLeadingOverflow {
            cursor += overflowDotDiameter + dotSpacing
        }
        for (offset, index) in visibleDotIndices.enumerated() {
            centers.append((index: index, centerX: cursor + (dotDiameter / 2)))
            cursor += dotDiameter
            let isLastVisibleDot = offset == visibleDotIndices.count - 1
            if !isLastVisibleDot || includesTrailingOverflow {
                cursor += dotSpacing
            }
        }

        return centers
    }

    static func scrubCandidateHapticStyle(isActive: Bool, dotState: StreamDotState) -> ScrubCandidateHapticStyle {
        StreamDotColor.kind(isActive: isActive, dotState: dotState) == .inactive ? .light : .strong
    }

    static func locationX(forIndex index: Int) -> CGFloat {
        horizontalPadding + (dotDiameter / 2) + (CGFloat(index) * (dotDiameter + dotSpacing))
    }

    static func scrubMagnificationScale(dotIndex: Int, candidateIndex: Int?) -> CGFloat {
        guard let candidateIndex else { return 1 }
        return scrubMagnificationScale(
            dotIndex: dotIndex,
            virtualIndex: CGFloat(candidateIndex),
            metrics: scrubLayoutMetrics(
                totalSessionCount: collapsedMaxVisibleDots,
                visibleDotCount: collapsedMaxVisibleDots,
                controlWidth: requiredControlWidth(
                    visibleDotCount: collapsedMaxVisibleDots,
                    includesOverflowIndicators: false
                ),
                maxWidth: nil,
                isScrubbing: true
            )
        )
    }

    static func scrubMagnificationScale(
        dotIndex: Int,
        virtualIndex: CGFloat?,
        metrics: ScrubLayoutMetrics
    ) -> CGFloat {
        guard let virtualIndex else { return 1 }
        let distance = abs(CGFloat(dotIndex) - virtualIndex)
        let falloff = scrubMagnificationFalloff(distance: distance, metrics: metrics)
        return 1 + ((metrics.maximumScale - 1) * falloff)
    }

    static func scrubMagnificationFalloff(distance: CGFloat, metrics: ScrubLayoutMetrics) -> CGFloat {
        guard distance < metrics.magnificationRadius else { return 0 }
        let narrowSigma = max(0.95, metrics.magnificationSigma * 0.60)
        let centralSpike = exp(-pow(distance / narrowSigma, 2.6))
        let edgeProgress = max(0, 1 - (distance / metrics.magnificationRadius))
        let broadTail = pow(edgeProgress, 1.25)
        return min(1, (0.72 * centralSpike) + (0.28 * broadTail))
    }

    static func scrubMagnificationVerticalOffset(scale: CGFloat) -> CGFloat {
        guard scale > 1 else { return 0 }
        return -(scale - 1) * scrubWaveLiftPerScalePoint
    }
}

#if canImport(UIKit)
private struct StreamPageDotsGestureBridge: UIViewRepresentable {
    let onTap: () -> Void
    let onScrubBegan: (CGFloat) -> Void
    let onScrubChanged: (CGPoint) -> Void
    let onScrubEnded: (CGPoint) -> Void
    let onScrubCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.28
        longPress.allowableMovement = 18
        tap.require(toFail: longPress)

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: StreamPageDotsGestureBridge

        init(parent: StreamPageDotsGestureBridge) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                parent.onScrubBegan(location.x)
            case .changed:
                parent.onScrubChanged(location)
            case .ended:
                parent.onScrubEnded(location)
            case .cancelled, .failed:
                parent.onScrubCancelled()
            default:
                break
            }
        }
    }
}
#endif
