import Foundation
import UIKit

enum BubbleSizingV2 {
    // Read once at app launch (static let) to avoid mid-session behavior changes.
    static let isEnabled: Bool = {
        let processInfo = ProcessInfo.processInfo
        let envValue = processInfo.environment["CLAWLINE_BUBBLE_SIZING_V2"]
        if envValue == "1" { return true }
        if envValue == "0" { return false }
        if processInfo.arguments.contains("--bubble-sizing-v2") { return true }
        return false
    }()

    struct Environment: Hashable {
        let containerWidth: CGFloat
        let containerHeight: CGFloat
        let singleLinkContainerHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat
        let truncationBottomInset: CGFloat
        let isVisionOS: Bool
        let metricsFingerprint: Int
    }

    struct Plan: Hashable {
        let messageId: String
        let presentationFingerprint: Int
        let sizeClass: MessageSizeClass
        let isSingleLinkPreview: Bool
        let isWide: Bool
        let maxWidth: CGFloat
        let minWidth: CGFloat
        let heightPolicy: BubbleHeightPolicy
        let allowsOuterScroll: Bool
        let linkPreviewURL: URL?
    }

    enum HeightCapMode: Hashable {
        case designSystem
        case screenAware
    }

    struct Measurement: Hashable {
        let measuredCellSize: CGSize
        let measuredBubbleWidth: CGFloat
        let contentHeight: CGFloat
        let chromeHeight: CGFloat
        let outerScrollEnabled: Bool
        let outerScrollViewportHeight: CGFloat
        let isFinal: Bool
    }

    struct LayoutState: Hashable {
        let plan: Plan
        let measurement: Measurement
        let linkPreviewCacheKey: String?
        let linkPreviewEstimatedHeight: CGFloat?
        let linkPreviewMinHeight: CGFloat
        let linkPreviewMaxHeight: CGFloat
    }

    struct CacheKey: Hashable {
        let messageId: String
        let presentationFingerprint: Int
        let layoutFingerprint: Int
        let env: Environment
        let linkPreviewStateVersion: Int
    }

    struct BubbleHeightPolicy: Hashable {
        let isSingleLinkPreview: Bool
        let heightCapMode: HeightCapMode
        let heightCap: CGFloat
        let v1TruncationHeightOverride: CGFloat?
        let linkPreviewViewportMaxHeight: CGFloat
        let cacheFingerprint: Int

        static func resolve(
            metrics: ChatFlowTheme.Metrics,
            env: Environment,
            isSingleLinkPreview: Bool,
            prefersScreenAwareHeightCap: Bool,
            allowsOuterScroll: Bool
        ) -> BubbleHeightPolicy {
            let screenAwareCap = availableHeightCap(
                containerHeight: env.containerHeight,
                topInset: env.topInset,
                bottomInset: max(env.bottomInset, env.truncationBottomInset),
                flowPadding: metrics.containerPadding
            )
            let singleLinkCap: CGFloat = {
                if env.isVisionOS {
                    // Spatial requirement: single-link bubbles cap at 75% of current window height.
                    return max(120, floor(env.singleLinkContainerHeight * 0.75))
                }
                return availableHeightCap(
                    containerHeight: env.singleLinkContainerHeight,
                    topInset: env.topInset,
                    bottomInset: env.bottomInset,
                    flowPadding: metrics.containerPadding
                )
            }()
            let heightCapMode: HeightCapMode = (isSingleLinkPreview || prefersScreenAwareHeightCap) ? .screenAware : .designSystem
            let heightCap: CGFloat = {
                if isSingleLinkPreview {
                    return singleLinkCap
                }
                guard allowsOuterScroll else { return 2000 }
                switch heightCapMode {
                case .screenAware:
                    return screenAwareCap
                case .designSystem:
                    return metrics.truncationHeight
                }
            }()
            let v1TruncationHeightOverride: CGFloat? = {
                if isSingleLinkPreview { return singleLinkCap }
                if prefersScreenAwareHeightCap { return screenAwareCap }
                return nil
            }()
            let linkPreviewViewportMaxHeight = max(44, heightCap - max(0, metrics.bubblePaddingVertical * 2))
            var hasher = Hasher()
            hasher.combine(isSingleLinkPreview)
            hasher.combine(heightCapMode)
            hasher.combine(heightCap)
            hasher.combine(v1TruncationHeightOverride)
            hasher.combine(linkPreviewViewportMaxHeight)
            let cacheFingerprint = hasher.finalize()
            return BubbleHeightPolicy(
                isSingleLinkPreview: isSingleLinkPreview,
                heightCapMode: heightCapMode,
                heightCap: heightCap,
                v1TruncationHeightOverride: v1TruncationHeightOverride,
                linkPreviewViewportMaxHeight: linkPreviewViewportMaxHeight,
                cacheFingerprint: cacheFingerprint
            )
        }

        func measurementCacheKey(
            messageId: String,
            presentationFingerprint: Int,
            layoutFingerprintSeed: Int,
            env: Environment,
            linkPreviewStateVersion: Int
        ) -> CacheKey {
            var hasher = Hasher()
            hasher.combine(layoutFingerprintSeed)
            hasher.combine(cacheFingerprint)
            return CacheKey(
                messageId: messageId,
                presentationFingerprint: presentationFingerprint,
                layoutFingerprint: hasher.finalize(),
                env: env,
                linkPreviewStateVersion: linkPreviewStateVersion
            )
        }
    }

    // Simple in-memory LRU cache (controller-owned). Correctness must not depend on retention.
    final class LRUCache<Key: Hashable, Value> {
        private struct Entry {
            var value: Value
            var stamp: Int
        }

        private var store: [Key: Entry] = [:]
        private var counter: Int = 0
        private let maxEntries: Int

        init(maxEntries: Int) {
            self.maxEntries = max(1, maxEntries)
        }

        func removeAll() {
            store.removeAll()
            counter = 0
        }

        func removeValue(forKey key: Key) {
            store.removeValue(forKey: key)
        }

        func value(forKey key: Key) -> Value? {
            guard var entry = store[key] else { return nil }
            counter += 1
            entry.stamp = counter
            store[key] = entry
            return entry.value
        }

        func setValue(_ value: Value, forKey key: Key) {
            counter += 1
            store[key] = Entry(value: value, stamp: counter)
            evictIfNeeded()
        }

        private func evictIfNeeded() {
            guard store.count > maxEntries else { return }
            // Evict least-recently-used by stamp.
            // This is O(n) but maxEntries is small (hundreds), and only runs on insert past limit.
            if let (lruKey, _) = store.min(by: { $0.value.stamp < $1.value.stamp }) {
                store.removeValue(forKey: lruKey)
            }
        }
    }

    // URL + width + metrics aware link preview height cache.
    final class LinkPreviewHeightCache {
        private let cache = NSCache<NSString, NSNumber>()

        init(countLimit: Int = 256) {
            cache.countLimit = max(1, countLimit)
        }

        func get(cacheKey: String) -> CGFloat? {
            guard let value = cache.object(forKey: cacheKey as NSString) else { return nil }
            return CGFloat(truncating: value)
        }

        func set(height: CGFloat, cacheKey: String) {
            guard height.isFinite, height > 0 else { return }
            cache.setObject(NSNumber(value: Double(height)), forKey: cacheKey as NSString)
        }
    }

    static func metricsFingerprint(metrics: ChatFlowTheme.Metrics, traitCollection: UITraitCollection) -> Int {
        var hasher = Hasher()
        hasher.combine(metrics.isCompact)
        hasher.combine(metrics.flowGap)
        hasher.combine(metrics.containerPadding)
        hasher.combine(metrics.bubblePaddingVertical)
        hasher.combine(metrics.bubblePaddingHorizontal)
        hasher.combine(metrics.shortFontSize)
        hasher.combine(metrics.mediumFontSize)
        hasher.combine(metrics.bodyFontSize)
        hasher.combine(metrics.senderFontSize)
        hasher.combine(metrics.truncationHeight)
        hasher.combine(traitCollection.preferredContentSizeCategory.rawValue)
        return hasher.finalize()
    }

    static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        max(minValue, min(maxValue, value))
    }

    static func availableHeightCap(
        containerHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        flowPadding: CGFloat
    ) -> CGFloat {
        let available = containerHeight - topInset - bottomInset - (flowPadding * 2)
        return max(120, floor(available))
    }
}
