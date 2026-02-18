import Foundation
import Testing

struct MessageFlowCacheSeamIntegrityTests {
    @Test("T085: direct cache mutations stay inside cache seam block")
    func directCacheMutationsAreScopedToSeam() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let seamStart = lines.firstIndex(where: { $0.contains("// MARK: - Cache Mutation Seam") }),
              let seamEnd = lines.firstIndex(where: { $0.contains("override func viewDidLayoutSubviews()") }) else {
            Issue.record("Unable to locate cache seam boundaries in MessageFlowCollectionView.swift")
            return
        }

        // Mutation-only patterns from the spec's acceptance criterion #7 + dirty-size invalidation writes.
        let patterns: [String] = [
            "sizeCache\\[.*\\]\\s*=",
            "sizeCache\\.remove",
            "lastMeasuredSizes\\[.*\\]\\s*=",
            "lastMeasuredSizes\\.remove",
            "bubbleSizingV2MeasurementCache\\.setValue",
            "bubbleSizingV2MeasurementCache\\.remove",
            "bubbleSizingV2KeysByMessageId\\[.*\\]",
            "bubbleSizingV2KeysByMessageId\\.remove",
            "bubbleSizingV2LinkPreviewHeightCache\\.set",
            "bubbleSizingV2LinkPreviewStateVersionByMessageId\\[.*\\]",
            "bubbleSizingV2LinkPreviewStateVersionByMessageId\\.remove",
            "dirtySizeIds\\.insert",
            "dirtySizeIds\\.remove"
        ]
        let regexes = try patterns.map { pattern in
            try NSRegularExpression(pattern: pattern)
        }

        for (idx, line) in lines.enumerated() {
            let lineNumber = idx + 1
            let isInsideSeam = idx >= seamStart && idx < seamEnd
            let range = NSRange(location: 0, length: (line as NSString).length)
            for (pattern, regex) in zip(patterns, regexes) {
                if regex.firstMatch(in: line, range: range) != nil {
                    #expect(isInsideSeam, "Direct cache mutation pattern '\(pattern)' escaped seam at line \(lineNumber)")
                }
            }
        }
    }
}
