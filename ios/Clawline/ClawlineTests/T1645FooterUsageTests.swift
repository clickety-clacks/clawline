import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
struct T1645FooterUsageTests {
    @Test("T1645 decodes the sanitized optional usage contract")
    func decodesSanitizedOptionalUsageContract() throws {
        let status = try decodedStatus(usageJSON: freshUsageJSON)
        let usage = try #require(status.display.codexUsage)

        #expect(usage.freshness == .fresh)
        #expect(usage.fetchedAt == 1_784_000_000_000)
        #expect(usage.windows.map(\.label) == [.fiveHour, .week])
        #expect(usage.windows.map(\.remainingPercent) == [64, 28])
        #expect(usage.windows.map(\.resetAt) == [1_784_003_600_000, 1_784_604_800_000])
        #expect(usage.unavailableReason == nil)

        let legacyStatus = try decodedStatus(usageJSON: nil)
        #expect(legacyStatus.display.codexUsage == nil)
    }

    @Test("T1645 renders exact fresh, stale, loading, and unavailable suffixes")
    func rendersUsageStates() throws {
        let fresh = try decodedStatus(usageJSON: freshUsageJSON)
        #expect(SessionMetadataFooterCell.footerText(for: fresh) ==
            "gpt-5.6  ·  Thinking medium  ·  Fast on  ·  OAUTH  ·  5h 64%  ·  Week 28%")

        let stale = try decodedStatus(usageJSON: freshUsageJSON.replacingOccurrences(of: "\"fresh\"", with: "\"stale\""))
        #expect(SessionMetadataFooterCell.footerText(for: stale)?.hasSuffix("OAUTH  ·  5h 64%  ·  Week 28%  ·  Stale") == true)

        let loading = try decodedStatus(usageJSON: stateUsageJSON(freshness: "loading", reason: "null"))
        #expect(SessionMetadataFooterCell.footerText(for: loading)?.hasSuffix("OAUTH  ·  Usage loading") == true)

        let unavailable = try decodedStatus(
            usageJSON: stateUsageJSON(freshness: "unavailable", reason: "\"provider_unavailable\"")
        )
        #expect(SessionMetadataFooterCell.footerText(for: unavailable)?.hasSuffix("OAUTH  ·  Usage unavailable") == true)
    }

    @Test("T1645 omits usage for API-key, token, and absent usage contracts")
    func omitsUsageOutsideOAuthContract() throws {
        let apiKey = try decodedStatus(authMode: "api_key", usageJSON: freshUsageJSON)
        #expect(SessionMetadataFooterCell.footerText(for: apiKey) ==
            "gpt-5.6  ·  Thinking medium  ·  Fast on  ·  API KEY")

        let token = try decodedStatus(authMode: "token", usageJSON: freshUsageJSON)
        #expect(SessionMetadataFooterCell.footerText(for: token) ==
            "gpt-5.6  ·  Thinking medium  ·  Fast on")

        let oauthWithoutUsage = try decodedStatus(usageJSON: nil)
        #expect(SessionMetadataFooterCell.footerText(for: oauthWithoutUsage) ==
            "gpt-5.6  ·  Thinking medium  ·  Fast on  ·  OAUTH")
    }

    @Test("T1673 puts complete OAuth usage states on the Version row without collision at iPhone width")
    func usageStatesMoveToVersionRowWithoutWrappingOrTruncation() throws {
        let status = try decodedStatus(usageJSON: freshUsageJSON)
        let narrowHeight = SessionMetadataFooterCell.height(for: status, width: 320)
        let wideHeight = SessionMetadataFooterCell.height(for: status, width: 900)

        #expect(narrowHeight == wideHeight)

        let staleStatus = try decodedStatus(
            usageJSON: freshUsageJSON.replacingOccurrences(of: "\"fresh\"", with: "\"stale\"")
        )
        let loadingStatus = try decodedStatus(usageJSON: stateUsageJSON(freshness: "loading", reason: "null"))
        let unavailableStatus = try decodedStatus(
            usageJSON: stateUsageJSON(freshness: "unavailable", reason: "\"provider_unavailable\"")
        )
        let usageStates = [
            (status, ["5h 64%", "Week 28%"]),
            (staleStatus, ["5h 64%", "Week 28%", "Stale"]),
            (loadingStatus, ["Usage loading"]),
            (unavailableStatus, ["Usage unavailable"]),
        ]
        for (usageStatus, expectedTexts) in usageStates {
            let cell = configuredCell(status: usageStatus, width: 320)
            let labels = descendants(of: cell).compactMap { $0 as? UILabel }
            let usageLabels = labels.filter {
                expectedTexts.contains($0.text ?? "") || $0.text == "OAUTH"
            }
            let versionLabel = try #require(labels.first { $0.text == SessionMetadataFooterCell.versionBuildText() })
            let versionRow = try #require(versionLabel.superview)
            let versionFrame = versionRow.convert(versionRow.bounds, to: cell)
            let menuButton = try #require(
                descendants(of: cell).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Test menu" }
            )
            let menuFrame = menuButton.convert(menuButton.bounds, to: cell)

            #expect(usageLabels.count == expectedTexts.count + 1)
            #expect(usageLabels.allSatisfy { $0.numberOfLines == 1 })
            #expect(usageLabels.allSatisfy { $0.lineBreakMode == .byClipping })
            #expect(usageLabels.allSatisfy { label in
                let frame = label.convert(label.bounds, to: cell)
                let requiredWidth = ceil((label.text! as NSString).size(withAttributes: [.font: label.font]).width)
                let textRect = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: 1)
                return versionFrame.contains(frame) && frame.width >= requiredWidth
                    && ceil(textRect.width) >= requiredWidth
                    && frame.intersects(menuFrame) == false
            })
        }

        let longStatus = try decodedStatus(
            model: "openai/gpt-5.6-long-protected-model",
            thinkingLevel: "extra-long-thinking-value",
            fastMode: true,
            usageJSON: stateUsageJSON(freshness: "unavailable", reason: "\"provider_unavailable\"")
        )
        let exactWidthCell = configuredCell(status: longStatus, width: 420)
        let exactWidthLabels = descendants(of: exactWidthCell).compactMap { $0 as? UILabel }
        let versionLabel = try #require(exactWidthLabels.first { $0.text == SessionMetadataFooterCell.versionBuildText() })
        let versionRow = try #require(versionLabel.superview)
        let versionLabels = exactWidthLabels.filter { ["OAUTH", "Usage unavailable"].contains($0.text) }
        let versionFrames = ([versionLabel] + versionLabels).map { $0.convert($0.bounds, to: exactWidthCell) }
        let exactWidthMenu = try #require(
            descendants(of: exactWidthCell).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Test menu" }
        )
        let exactWidthMenuFrame = exactWidthMenu.convert(exactWidthMenu.bounds, to: exactWidthCell)
        #expect(versionLabels.count == 2)
        #expect(versionFrames.allSatisfy { versionRow.convert(versionRow.bounds, to: exactWidthCell).contains($0) })
        #expect(versionLabels.allSatisfy { label in
            let requiredWidth = ceil((label.text! as NSString).size(withAttributes: [.font: label.font]).width)
            return label.bounds.width >= requiredWidth
                && ceil(label.textRect(forBounds: label.bounds, limitedToNumberOfLines: 1).width) >= requiredWidth
                && label.convert(label.bounds, to: exactWidthCell).intersects(exactWidthMenuFrame) == false
        })
        for first in versionFrames.indices {
            for second in versionFrames.indices where first < second {
                #expect(versionFrames[first].intersection(versionFrames[second]).isNull)
            }
        }

        exactWidthCell.frame.size.width = 320
        exactWidthCell.setNeedsLayout()
        exactWidthCell.layoutIfNeeded()
        let resizedLabels = descendants(of: exactWidthCell).compactMap { $0 as? UILabel }
        #expect(resizedLabels.filter { ["OAUTH", "Usage unavailable"].contains($0.text) }.count == 2)

        let wideCell = configuredCell(status: status, width: 900)
        let hiddenRows = descendants(of: wideCell).compactMap { $0 as? UIStackView }.filter(\.isHidden)
        let hiddenRequiredHeightConstraints = hiddenRows.flatMap(\.constraints).filter {
            $0.firstAttribute == .height && $0.priority == .required
        }
        #expect(hiddenRows.count == 1)
        #expect(hiddenRequiredHeightConstraints.isEmpty)
    }

    @Test("T1645 footer height follows accessibility Dynamic Type")
    func footerHeightFollowsDynamicType() throws {
        let status = try decodedStatus(usageJSON: freshUsageJSON)
        let normalHeight = SessionMetadataFooterCell.height(for: status, width: 320)
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let accessibilityHeight = SessionMetadataFooterCell.height(
            for: status,
            width: 320,
            compatibleWith: accessibilityTraits
        )

        #expect(accessibilityHeight > normalHeight)
    }

    @Test("T1645 usage accessibility is ordered, static, localized, and has no duplicate cell stop")
    func usageAccessibility() throws {
        let status = try decodedStatus(usageJSON: freshUsageJSON)
        let cell = configuredCell(status: status, width: 320, isSpatial: true)
        let labels = descendants(of: cell).compactMap { $0 as? UILabel }
        let fiveHour = try #require(labels.first { $0.text == "5h 64%" })
        let weekly = try #require(labels.first { $0.text == "Week 28%" })

        #expect(cell.isAccessibilityElement == false)
        #expect(fiveHour.accessibilityTraits.contains(.staticText))
        #expect(weekly.accessibilityTraits.contains(.staticText))
        #expect(fiveHour.accessibilityLabel?.hasPrefix("5 hour Codex usage, 64 percent remaining, resets ") == true)
        #expect(weekly.accessibilityLabel?.hasPrefix("Weekly Codex usage, 28 percent remaining, resets ") == true)
        #expect(fiveHour.textColor.isEqual(UIColor.white))
        #expect(weekly.textColor.isEqual(UIColor.white))
        #expect(fiveHour.convert(fiveHour.bounds, to: cell).minX < weekly.convert(weekly.bounds, to: cell).minX)
    }

    @Test("T1645 reuses the cancellable session-status cadence")
    func usageFollowUpCadence() throws {
        let loadingStatus = try decodedStatus(usageJSON: stateUsageJSON(freshness: "loading", reason: "null"))
        let staleStatus = try decodedStatus(
            usageJSON: freshUsageJSON.replacingOccurrences(of: "\"fresh\"", with: "\"stale\"")
        )
        let unavailableStatus = try decodedStatus(
            usageJSON: stateUsageJSON(freshness: "unavailable", reason: "\"timeout\"")
        )
        let freshStatus = try decodedStatus(usageJSON: freshUsageJSON)
        let loading = try #require(loadingStatus.display.codexUsage)
        let stale = try #require(staleStatus.display.codexUsage)
        let unavailable = try #require(unavailableStatus.display.codexUsage)
        let fresh = try #require(freshStatus.display.codexUsage)

        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: loading, usageFollowUpCount: 1, runState: .idle) == .seconds(2))
        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: loading, usageFollowUpCount: 2, runState: .idle) == .seconds(5))
        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: stale, usageFollowUpCount: 1, runState: .idle) == .seconds(5))
        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: stale, usageFollowUpCount: 2, runState: .idle) == .seconds(30))
        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: unavailable, usageFollowUpCount: 1, runState: .idle) == .seconds(30))
        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: fresh, usageFollowUpCount: 0, runState: .idle) == nil)
        #expect(ChatViewModel.sessionStatusFollowUpDelay(usage: fresh, usageFollowUpCount: 0, runState: .running) == .seconds(5))
    }

    private var freshUsageJSON: String {
        """
        {
          "freshness": "fresh",
          "fetchedAt": 1784000000000,
          "windows": [
            {"label": "5h", "remainingPercent": 64, "resetAt": 1784003600000},
            {"label": "Week", "remainingPercent": 28, "resetAt": 1784604800000}
          ],
          "unavailableReason": null
        }
        """
    }

    private func stateUsageJSON(freshness: String, reason: String) -> String {
        """
        {
          "freshness": "\(freshness)",
          "fetchedAt": null,
          "windows": [],
          "unavailableReason": \(reason)
        }
        """
    }

    private func decodedStatus(
        authMode: String = "oauth",
        model: String = "gpt-5.6",
        thinkingLevel: String = "medium",
        fastMode: Bool = true,
        usageJSON: String?
    ) throws -> SessionStatus {
        let usageField = usageJSON.map { ", \"codexUsage\": \($0)" } ?? ""
        let json = """
        {
          "sessionKey": "agent:main:clawline:user:s_t1645",
          "display": {
            "model": "\(model)",
            "provider": "openai-codex",
            "authMode": "\(authMode)",
            "thinkingLevel": "\(thinkingLevel)",
            "fastMode": \(fastMode)
            \(usageField)
          },
          "run": {"state": "idle"},
          "capabilities": {
            "setModel": {"supported": true},
            "setThinking": {"supported": true},
            "setFastMode": {"supported": true}
          }
        }
        """
        return try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
    }

    private func configuredCell(status: SessionStatus, width: CGFloat, isSpatial: Bool = false) -> SessionMetadataFooterCell {
        let cell = SessionMetadataFooterCell(
            frame: CGRect(x: 0, y: 0, width: width, height: SessionMetadataFooterCell.height(for: status, width: width))
        )
        cell.configure(status: status, isDark: false, isSpatial: isSpatial, onSelect: { _, _, _, _ in })
        cell.layoutIfNeeded()
        return cell
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
