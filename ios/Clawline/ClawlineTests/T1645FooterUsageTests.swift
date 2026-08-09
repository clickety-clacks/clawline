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
        #expect(status.metadataContextGeneration == "generation-a")

        let missingUsageStatus = try decodedStatus(metadataContextGeneration: nil, usageJSON: nil)
        #expect(missingUsageStatus.display.codexUsage == nil)
        #expect(missingUsageStatus.metadataContextGeneration == nil)
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

    @Test("T1645 renders recognized singleton windows without inventing a counterpart")
    func rendersSingletonUsageWindows() throws {
        let weeklyStatus = try decodedStatus(
            usageJSON: singletonUsageJSON(label: "Week", remainingPercent: 81, resetAt: 1_784_604_800_000)
        )
        let weeklyUsage = try #require(weeklyStatus.display.codexUsage)
        #expect(weeklyUsage.windows.map(\.label) == [.week])
        #expect(weeklyUsage.windows.map(\.remainingPercent) == [81])
        #expect(SessionMetadataFooterCell.footerText(for: weeklyStatus) ==
            "gpt-5.6  ·  Thinking medium  ·  Fast on  ·  OAUTH  ·  Week 81%")

        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let cell = configuredCell(status: weeklyStatus, width: 320, contentSizeCategory: category)
            let labels = descendants(of: cell).compactMap { $0 as? UILabel }
            let buttons = descendants(of: cell).compactMap { $0 as? UIButton }
            let oauth = try #require(labels.first { $0.text == "OAUTH" })
            let weekly = try #require(labels.first { $0.text == "Week 81%" })
            let model = try #require(buttons.first { $0.accessibilityLabel == "gpt-5.6" })
            let usageRow = try #require(oauth.superview)

            #expect(weekly.superview === usageRow)
            #expect(model.superview !== usageRow)
            #expect(abs(usageRow.convert(usageRow.bounds, to: cell).midX - cell.bounds.midX) <= 0.5)
            #expect(labels.contains { $0.text?.hasPrefix("5h ") == true } == false)
            #expect(weekly.accessibilityLabel?.hasPrefix(
                "Weekly Codex usage, 81 percent remaining, resets "
            ) == true)
        }

        let fiveHourStatus = try decodedStatus(
            usageJSON: singletonUsageJSON(label: "5h", remainingPercent: 64, resetAt: 1_784_003_600_000)
        )
        let fiveHourUsage = try #require(fiveHourStatus.display.codexUsage)
        #expect(fiveHourUsage.windows.map(\.label) == [.fiveHour])
        #expect(SessionMetadataFooterCell.footerText(for: fiveHourStatus) ==
            "gpt-5.6  ·  Thinking medium  ·  Fast on  ·  OAUTH  ·  5h 64%")
    }

    @Test("T1645 omits usage outside OAuth and against an older provider")
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

    @Test("T1645 V7 keeps OAuth usage in its own centered row at every supported width and Dynamic Type size")
    func oauthUsageAlwaysOccupiesDistinctCenteredRow() throws {
        let freshStatus = try decodedStatus(usageJSON: freshUsageJSON)
        let staleStatus = try decodedStatus(
            usageJSON: freshUsageJSON.replacingOccurrences(of: "\"fresh\"", with: "\"stale\"")
        )
        let loadingStatus = try decodedStatus(usageJSON: stateUsageJSON(freshness: "loading", reason: "null"))
        let unavailableStatus = try decodedStatus(
            usageJSON: stateUsageJSON(freshness: "unavailable", reason: "\"provider_unavailable\"")
        )
        let usageStates = [
            (freshStatus, ["5h 64%", "Week 28%"]),
            (staleStatus, ["5h 64%", "Week 28%", "Stale"]),
            (loadingStatus, ["Usage loading"]),
            (unavailableStatus, ["Usage unavailable"]),
        ]
        for width in [CGFloat(320), 900] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                for (usageStatus, expectedTexts) in usageStates {
                    let cell = configuredCell(status: usageStatus, width: width, contentSizeCategory: category)
                    let labels = descendants(of: cell).compactMap { $0 as? UILabel }
                    let buttons = descendants(of: cell).compactMap { $0 as? UIButton }
                    let primaryViews = try ["gpt-5.6", "Thinking medium", "Fast on"].map { text in
                        try #require(buttons.first { $0.accessibilityLabel == text })
                    }
                    let usageLabels = try (["OAUTH"] + expectedTexts).map { text in
                        try #require(labels.first { $0.text == text })
                    }
                    let versionLabel = try #require(
                        labels.first { $0.text == SessionMetadataFooterCell.versionBuildText() }
                    )
                    let settingsButton = try #require(
                        buttons.first { $0.accessibilityLabel == "Settings" }
                    )
                    let primaryRow = try #require(primaryViews.first?.superview)
                    let usageRow = try #require(usageLabels.first?.superview)
                    let versionRow = try #require(versionLabel.superview)

                    #expect(primaryViews.allSatisfy { $0.superview === primaryRow })
                    #expect(usageLabels.allSatisfy { $0.superview === usageRow })
                    #expect(settingsButton.superview === versionRow)
                    #expect(primaryRow !== usageRow)
                    #expect(usageRow !== versionRow)

                    let primaryFrame = primaryRow.convert(primaryRow.bounds, to: cell)
                    let usageFrame = usageRow.convert(usageRow.bounds, to: cell)
                    let versionFrame = versionRow.convert(versionRow.bounds, to: cell)
                    #expect(primaryFrame.maxY <= usageFrame.minY)
                    #expect(usageFrame.maxY <= versionFrame.minY)
                    #expect(abs(usageFrame.midX - cell.bounds.midX) <= 0.5)
                    #expect(cell.bounds.insetBy(dx: SessionMetadataFooterCell.horizontalPadding, dy: 0)
                        .contains(usageFrame))
                    let usageValueLabels = expectedTexts.compactMap { text in
                        labels.first { $0.text == text }
                    }
                    #expect(usageValueLabels.count == expectedTexts.count)
                    #expect(usageValueLabels.allSatisfy { label in
                        label.numberOfLines == 0 && label.lineBreakMode == .byWordWrapping
                    })
                    #expect(usageLabels.allSatisfy { label in
                        let frame = label.convert(label.bounds, to: cell)
                        return usageFrame.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                    })
                    #expect(usageFrame.height >= SessionMetadataFooterCell.actionRegionHeight)
                }
            }
        }
    }

    @Test("T1645 V8 keeps Version and Settings adjacent in one centered content-hugging group")
    func versionAndSettingsRemainAdjacentAndCentered() throws {
        let status = try decodedStatus(usageJSON: freshUsageJSON)

        for width in [CGFloat(320), 900] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                let cell = configuredCell(status: status, width: width, contentSizeCategory: category)
                let versionLabel = try #require(
                    descendants(of: cell).compactMap { $0 as? UILabel }
                        .first { $0.text == SessionMetadataFooterCell.versionBuildText() }
                )
                let settingsButton = try #require(
                    descendants(of: cell).compactMap { $0 as? UIButton }
                        .first { $0.accessibilityLabel == "Settings" }
                )
                let versionRow = try #require(versionLabel.superview as? UIStackView)
                let versionFrame = versionLabel.convert(versionLabel.bounds, to: cell)
                let settingsFrame = settingsButton.convert(settingsButton.bounds, to: cell)
                let groupFrame = versionRow.convert(versionRow.bounds, to: cell)

                #expect(settingsButton.superview === versionRow)
                #expect(versionRow.arrangedSubviews.count == 2)
                #expect(abs(settingsFrame.minX - versionFrame.maxX - SessionMetadataFooterCell.footerRowSpacing) <= 0.5)
                #expect(abs(groupFrame.midX - cell.bounds.midX) <= 0.5)
                #expect(abs(groupFrame.minX - versionFrame.minX) <= 0.5)
                #expect(abs(groupFrame.maxX - settingsFrame.maxX) <= 0.5)
                #expect(groupFrame.width < cell.bounds.width - (SessionMetadataFooterCell.horizontalPadding * 2))
                #expect(groupFrame.height >= SessionMetadataFooterCell.actionRegionHeight)
            }
        }
    }

    @Test("T1645 retains scoped refresh states only for the exact metadata generation")
    func metadataAuthorityRetainsOnlyExactGeneration() throws {
        let cached = try #require(decodedStatus(usageJSON: freshUsageJSON).display.codexUsage)
        let loading = try #require(
            decodedStatus(usageJSON: stateUsageJSON(freshness: "loading", reason: "null"))
                .display.codexUsage
        )
        for reason in [
            SessionStatus.Display.CodexUsage.UnavailableReason.staleExpired,
            .resetElapsed,
        ] {
            let incoming = SessionStatus.Display.CodexUsage(
                freshness: .unavailable,
                fetchedAt: cached.fetchedAt,
                windows: [],
                unavailableReason: reason
            )
            let retained = try #require(ChatViewModel.resolvedCodexUsageForMetadataAuthority(
                incoming: incoming,
                incomingGeneration: "generation-a",
                cached: cached,
                cachedGeneration: "generation-a"
            ))
            #expect(retained.freshness == .stale)
            #expect(retained.windows == cached.windows)
            #expect(retained.unavailableReason == nil)
        }

        let retainedLoading = try #require(ChatViewModel.resolvedCodexUsageForMetadataAuthority(
            incoming: loading,
            incomingGeneration: "generation-a",
            cached: cached,
            cachedGeneration: "generation-a"
        ))
        #expect(retainedLoading.freshness == .stale)
        #expect(retainedLoading.windows == cached.windows)
    }

    @Test("T1645 rejects retained usage on changed, absent, or failed binding authority")
    func metadataAuthorityFailsClosed() throws {
        let cached = try #require(decodedStatus(usageJSON: freshUsageJSON).display.codexUsage)
        let bindingFailure = SessionStatus.Display.CodexUsage(
            freshness: .unavailable,
            fetchedAt: nil,
            windows: [],
            unavailableReason: .accountBindingUnavailable
        )
        let changed = try #require(ChatViewModel.resolvedCodexUsageForMetadataAuthority(
            incoming: bindingFailure,
            incomingGeneration: "generation-b",
            cached: cached,
            cachedGeneration: "generation-a"
        ))
        #expect(changed == bindingFailure)
        let sameGenerationFailure = try #require(ChatViewModel.resolvedCodexUsageForMetadataAuthority(
            incoming: bindingFailure,
            incomingGeneration: "generation-a",
            cached: cached,
            cachedGeneration: "generation-a"
        ))
        #expect(sameGenerationFailure == bindingFailure)
        #expect(ChatViewModel.resolvedCodexUsageForMetadataAuthority(
            incoming: nil,
            incomingGeneration: nil,
            cached: cached,
            cachedGeneration: "generation-a"
        ) == nil)
    }

    @Test("T1645 footer preserves Dynamic Type participation without shrinking its container")
    func footerPreservesDynamicTypeParticipation() throws {
        let status = try decodedStatus(usageJSON: freshUsageJSON)
        let normalCell = configuredCell(status: status, width: 320, contentSizeCategory: .large)
        let accessibilityCell = configuredCell(
            status: status,
            width: 320,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let normalUsage = try #require(
            descendants(of: normalCell).compactMap { $0 as? UILabel }.first { $0.text == "5h 64%" }
        )
        let accessibilityUsage = try #require(
            descendants(of: accessibilityCell).compactMap { $0 as? UILabel }.first { $0.text == "5h 64%" }
        )

        #expect(normalUsage.adjustsFontForContentSizeCategory)
        #expect(accessibilityUsage.adjustsFontForContentSizeCategory)
        #expect(accessibilityCell.bounds.height >= normalCell.bounds.height)
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

    private func singletonUsageJSON(label: String, remainingPercent: Int, resetAt: Int) -> String {
        """
        {
          "freshness": "fresh",
          "fetchedAt": 1784000000000,
          "windows": [
            {"label": "\(label)", "remainingPercent": \(remainingPercent), "resetAt": \(resetAt)}
          ],
          "unavailableReason": null
        }
        """
    }

    private func decodedStatus(
        metadataContextGeneration: String? = "generation-a",
        authMode: String = "oauth",
        model: String = "gpt-5.6",
        thinkingLevel: String = "medium",
        fastMode: Bool = true,
        harness: String? = nil,
        usageJSON: String?
    ) throws -> SessionStatus {
        let usageField = usageJSON.map { ", \"codexUsage\": \($0)" } ?? ""
        let harnessField = harness.map { ",\n        \"harness\": \"\($0)\"" } ?? ""
        let generationField = metadataContextGeneration.map {
            "\"metadataContextGeneration\": \"\($0)\","
        } ?? ""
        let json = """
        {
          "sessionKey": "agent:main:clawline:user:s_t1645",
          \(generationField)
          "display": {
            "model": "\(model)",
            "provider": "openai-codex",
            "authMode": "\(authMode)",
            "thinkingLevel": "\(thinkingLevel)",
            "fastMode": \(fastMode)\(harnessField)
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

    private func configuredCell(
        status: SessionStatus,
        width: CGFloat,
        isSpatial: Bool = false,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> SessionMetadataFooterCell {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let cell = SessionMetadataFooterCell(
            frame: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: SessionMetadataFooterCell.height(for: status, width: width, compatibleWith: traits)
            )
        )
        cell.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        cell.configure(status: status, isDark: false, isSpatial: isSpatial, onSelect: { _, _, _, _ in })
        cell.layoutIfNeeded()
        return cell
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
