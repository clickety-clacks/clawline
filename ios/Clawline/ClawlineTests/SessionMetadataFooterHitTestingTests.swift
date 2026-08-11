import Testing
import UIKit
@testable import Clawline

@MainActor
struct SessionMetadataFooterHitTestingTests {
    @Test("Footer action regions are stable non-overlapping tap targets")
    func footerActionRegionsAreStableNonOverlappingTapTargets() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)
        let frames = buttons.map { $0.convert($0.bounds, to: cell) }

        for frame in frames {
            #expect(frame.width >= 44)
            #expect(frame.height <= 24)
            #expect(cell.bounds.contains(frame))
        }

        for firstIndex in frames.indices {
            for secondIndex in frames.indices where firstIndex < secondIndex {
                let firstFrame = frames[firstIndex]
                let secondFrame = frames[secondIndex]
                #expect(firstFrame.intersection(secondFrame).isNull)
            }
        }

        for index in frames.indices.dropFirst() {
            let gap = frames[index].minX - frames[index - 1].maxX
            #expect(gap <= 2.5)
            #expect(gap >= 0)
        }

        let occupiedWidth = frames.last!.maxX - frames.first!.minX
        #expect(occupiedWidth < cell.bounds.width * 0.7)
    }

    @Test("Footer actions sit in compact reveal row")
    func footerActionsSitInCompactRevealRow() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)
        let frames = buttons.map { $0.convert($0.bounds, to: cell) }
        let searchField = try footerSearchField(in: cell)
        let searchFrame = searchField.convert(searchField.bounds, to: cell)

        #expect(SessionMetadataFooterCell.topPadding == 12)
        #expect(SessionMetadataFooterCell.height(for: makeStatus()) == 142)
        #expect(SessionMetadataFooterCell.fadeRevealRange == 138)
        #expect(frames.allSatisfy {
            let centeredY = searchFrame.maxY
                + SessionMetadataFooterCell.footerRowSpacing
                + (SessionMetadataFooterCell.actionRegionHeight - $0.height) / 2
            return abs($0.minY - centeredY) <= 0.5
        })
        #expect(frames.allSatisfy { $0.height <= 24 })
    }

    @Test("Footer search row is first with equal row spacing and centered text")
    func footerSearchRowIsFirstWithEqualRowSpacingAndCenteredText() throws {
        let cell = makeConfiguredCell()
        let searchField = try footerSearchField(in: cell)
        let searchFrame = searchField.convert(searchField.bounds, to: cell)
        let buttons = try footerButtons(in: cell)
        let actionRow = try #require(
            allSubviews(in: cell).compactMap { $0 as? UIStackView }
                .first { stack in stack.axis == .horizontal && buttons.allSatisfy { $0.superview === stack } }
        )
        let actionRowFrame = actionRow.convert(actionRow.bounds, to: cell)
        let versionLabel = try #require(
            allSubviews(in: cell).compactMap { $0 as? UILabel }
                .first { $0.text == SessionMetadataFooterCell.versionBuildText() }
        )
        let versionRow = try #require(versionLabel.superview)
        let versionFrame = versionRow.convert(versionRow.bounds, to: cell)
        let searchToActions = actionRowFrame.minY - searchFrame.maxY
        let actionsToVersion = versionFrame.minY - actionRowFrame.maxY

        #expect(searchFrame.minY == SessionMetadataFooterCell.topPadding)
        #expect(searchFrame.minY < actionRowFrame.minY)
        #expect(actionRowFrame.minY < versionFrame.minY)
        #expect(abs(searchToActions - actionsToVersion) <= 0.5)
        #expect(abs(searchToActions - SessionMetadataFooterCell.footerRowSpacing) <= 0.5)
        #expect(searchField.textAlignment == .center)
    }

    @Test("Thinking action hit target does not include off-glyph segment above compact label")
    func thinkingActionHitTargetDoesNotIncludeOffGlyphSegmentAboveCompactLabel() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let thinkingButton = try #require(buttons.first { $0.accessibilityLabel == "Thinking high" })
        let thinkingFrame = thinkingButton.convert(thinkingButton.bounds, to: cell)
        let thinkingLabel = try #require(thinkingButton.titleLabel)
        let thinkingLabelFrame = thinkingLabel.convert(thinkingLabel.bounds, to: cell)
        let thinkingRegion = try #require(
            FooterActionHitTesting.actionRegions(for: buttons, in: cell)
                .first { $0.view === thinkingButton }?.rect
        )
        let offGlyphPoint = CGPoint(x: thinkingLabelFrame.midX, y: thinkingFrame.minY - 1)

        #expect(thinkingRegion.width >= 44)
        #expect(thinkingFrame.contains(offGlyphPoint) == false)
        #expect(thinkingLabelFrame.contains(offGlyphPoint) == false)
        #expect(thinkingRegion.contains(offGlyphPoint) == false)
        #expect(cell.hitTest(offGlyphPoint, with: nil) !== thinkingButton)
    }

    @Test("Every sampled point inside each visible footer button resolves to that button")
    func everySampledPointInsideEachVisibleFooterButtonResolvesToThatButton() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)

        for button in buttons {
            let frame = button.convert(button.bounds, to: cell)
            let samplePoints = [
                CGPoint(x: frame.midX, y: frame.midY),
                CGPoint(x: frame.minX + 1, y: frame.midY),
                CGPoint(x: frame.maxX - 1, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.minY + 1),
                CGPoint(x: frame.midX, y: frame.maxY - 1),
                CGPoint(x: frame.minX + 1, y: frame.minY + 1),
                CGPoint(x: frame.maxX - 1, y: frame.minY + 1),
                CGPoint(x: frame.minX + 1, y: frame.maxY - 1),
                CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
            ]

            for point in samplePoints {
                #expect(button.point(inside: cell.convert(point, to: button), with: nil))
                #expect(cell.hitTest(point, with: nil) === button)
            }
        }
    }

#if targetEnvironment(macCatalyst)
    @Test("R1662-05 Catalyst resting footer search remains visible and hit-testable")
    func r1662_05_catalystRestingFooterSearchRemainsVisibleAndHitTestable() throws {
        let restingBottom: CGFloat = 440
        let trueBottom: CGFloat = 500
        let cell = makeConfiguredCell()
        cell.alpha = MessageFlowCollectionViewController.initialFooterCellAlpha(
            contentOffsetY: restingBottom,
            chatBubbleBottomOffsetY: restingBottom,
            revealDistance: trueBottom - restingBottom
        )
        let searchField = try footerSearchField(in: cell)
        let searchCenter = searchField.convert(
            CGPoint(x: searchField.bounds.midX, y: searchField.bounds.midY),
            to: cell
        )

        #expect(MessageFlowCollectionViewController.hidesFooterAtRestingBottom == false)
        #expect(cell.alpha == 1)
        #expect(searchField.alpha > 0.01)
        #expect(searchField.isUserInteractionEnabled)
        let hitView = try #require(cell.hitTest(searchCenter, with: nil))
        #expect(hitView === searchField || hitView.isDescendant(of: searchField))
    }
#endif

    @Test("Direct label glyph taps resolve to the enabled footer button")
    func directLabelGlyphTapsResolveToTheEnabledFooterButton() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)

        for button in buttons {
            let titleLabel = try #require(button.titleLabel)
            let labelFrameInButton = titleLabel.convert(titleLabel.bounds, to: button)
            let labelCenterInButton = CGPoint(x: labelFrameInButton.midX, y: labelFrameInButton.midY)
            let labelCenterInCell = button.convert(labelCenterInButton, to: cell)

            #expect(titleLabel.bounds.width > 0)
            #expect(titleLabel.bounds.height > 0)
            #expect(titleLabel.point(inside: titleLabel.convert(labelCenterInCell, from: cell), with: nil))
            #expect(button.hitTest(labelCenterInButton, with: nil) === button)
            #expect(cell.hitTest(labelCenterInCell, with: nil) === button)
        }
    }

    @Test("Footer action regions keep compact borderless styling")
    func footerActionRegionsKeepCompactBorderlessStyling() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let thinkingButton = try #require(buttons.first { $0.accessibilityLabel == "Thinking high" })
        let configuration = try #require(thinkingButton.configuration)

        #expect(configuration.contentInsets.top == 2)
        #expect(configuration.contentInsets.bottom == 2)
        #expect(configuration.contentInsets.leading == 4)
        #expect(configuration.contentInsets.trailing == 4)
        #expect(configuration.background.strokeWidth == 0)
        #expect(configuration.background.backgroundColor?.cgColor.alpha == 0)
    }

    @Test("Footer text keeps readable opacity without changing reveal mechanics")
    func footerTextKeepsReadableOpacity() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let modelButton = try #require(buttons.first { $0.accessibilityLabel == "gpt-5.5" })
        let configuration = try #require(modelButton.configuration)
        let foreground = try #require(configuration.baseForegroundColor)

        #expect(foreground.cgColor.alpha == SessionMetadataFooterCell.textAlpha(isDark: false))
        #expect(SessionMetadataFooterCell.fadeRevealRange == 138)
    }

    @Test("T1184 Spatial footer text stays white across theme states")
    func spatialFooterTextStaysWhiteAcrossThemeStates() throws {
        #expect(SessionMetadataFooterCell.textColor(isDark: false, isSpatial: true).isEqual(UIColor.white))
        #expect(SessionMetadataFooterCell.textColor(isDark: true, isSpatial: true).isEqual(UIColor.white))
        #expect(SessionMetadataFooterCell.textColor(isDark: false, isSpatial: false).isEqual(UIColor.white) == false)

        for isDark in [false, true] {
            let cell = makeConfiguredCell(authMode: "oauth", isDark: isDark, isSpatial: true)
            let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
            let labels = allSubviews(in: cell).compactMap { $0 as? UILabel }
                .filter { label in
                    sequence(first: label.superview, next: { $0?.superview })
                        .allSatisfy { !($0 is UITextField) }
                }

            for button in buttons {
                let foreground = try #require(button.configuration?.baseForegroundColor)
                #expect(foreground.isEqual(UIColor.white))
                #expect(button.tintColor.isEqual(UIColor.white))
            }

            for label in labels {
                #expect(label.textColor.isEqual(UIColor.white))
            }
        }
    }

    @Test("Footer shows version build line and test menu")
    func footerShowsVersionBuildLineAndTestMenu() throws {
        let cell = makeConfiguredCell()
        let versionLabel = try #require(
            allSubviews(in: cell).compactMap { $0 as? UILabel }
                .first { $0.accessibilityLabel?.hasPrefix("Version ") == true }
        )
        let testMenuButton = try #require(
            allSubviews(in: cell).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Settings" }
        )
        let actions = try #require(testMenuButton.menu?.children.compactMap { $0 as? UIAction })

        #expect(versionLabel.text == SessionMetadataFooterCell.versionBuildText())
        #expect(actions.map(\.title) == ["Settings", "Logout"])
        #expect(actions.last?.attributes.contains(.destructive) == true)
        #expect(testMenuButton.showsMenuAsPrimaryAction)
        #expect(testMenuButton.configuration?.image == UIImage(systemName: "gearshape"))
        #expect(testMenuButton.configuration?.preferredSymbolConfigurationForImage == UIImage.SymbolConfiguration(
            pointSize: SessionMetadataFooterCell.testMenuIconPointSize,
            weight: .regular
        ))
        #expect(testMenuButton.bounds.width == 44)
        let testMenuCenter = testMenuButton.convert(
            CGPoint(x: testMenuButton.bounds.midX, y: testMenuButton.bounds.midY),
            to: cell
        )
        #expect(cell.hitTest(testMenuCenter, with: nil) === testMenuButton)
        let expandedHitPoint = testMenuButton.convert(
            CGPoint(x: testMenuButton.bounds.midX, y: testMenuButton.bounds.minY - 8),
            to: cell
        )
        #expect(cell.hitTest(expandedHitPoint, with: nil) === testMenuButton)
    }

    @Test("Footer renders sanitized auth mode as right-most text")
    func footerRendersSanitizedAuthModeRightMost() {
        let apiKeyStatus = makeStatus(authMode: "api_key")
        #expect(SessionMetadataFooterCell.footerText(for: apiKeyStatus) == "gpt-5.5  ·  Thinking high  ·  Fast on  ·  API KEY")

        let unknownStatus = makeStatus(authMode: "unknown")
        #expect(SessionMetadataFooterCell.footerText(for: unknownStatus) == "gpt-5.5  ·  Thinking high  ·  Fast on")
    }

    @Test("Footer auth mode uses semantic theme colors")
    func footerAuthModeUsesSemanticThemeColors() throws {
        let oauthCell = makeConfiguredCell(authMode: "oauth", isDark: false)
        let oauthLabel = try #require(
            allSubviews(in: oauthCell).compactMap { $0 as? UILabel }
                .first { $0.accessibilityLabel == "OAUTH" }
        )
        #expect(oauthLabel.textColor.isEqual(ChatFlowUIKitTheme.palette(isDark: false).sage))
        #expect(oauthLabel.accessibilityTraits.contains(.staticText))
        #expect(oauthLabel.isUserInteractionEnabled == false)
        let oauthCenter = oauthLabel.convert(CGPoint(x: oauthLabel.bounds.midX, y: oauthLabel.bounds.midY), to: oauthCell)
        #expect(oauthCell.hitTest(oauthCenter, with: nil) !== oauthLabel)

        let apiKeyCell = makeConfiguredCell(authMode: "api_key", isDark: false)
        let apiKeyLabel = try #require(
            allSubviews(in: apiKeyCell).compactMap { $0 as? UILabel }
                .first { $0.accessibilityLabel == "API KEY" }
        )
        #expect(apiKeyLabel.textColor.isEqual(ChatFlowUIKitTheme.connectionReconnecting(isDark: false)))
        #expect(apiKeyLabel.accessibilityTraits.contains(.staticText))
        #expect(apiKeyLabel.isUserInteractionEnabled == false)
        let apiKeyCenter = apiKeyLabel.convert(CGPoint(x: apiKeyLabel.bounds.midX, y: apiKeyLabel.bounds.midY), to: apiKeyCell)
        #expect(apiKeyCell.hitTest(apiKeyCenter, with: nil) !== apiKeyLabel)
    }

    @Test("Footer auth mode renders visible semantic pixels in simulator")
    func footerAuthModeRendersVisibleSemanticPixels() throws {
        let oauthRender = try renderedFooterImage(authMode: "oauth", accessibilityLabel: "OAUTH")
        writeEvidenceImage(oauthRender.image, name: "t318-oauth-footer-render.png")
        let oauthPixels = try sampledTextPixels(in: oauthRender.image, frame: oauthRender.labelFrame)
        #expect(oauthPixels.count >= 12)
        #expect(oauthPixels.averageGreen > oauthPixels.averageRed + 2)
        #expect(oauthPixels.averageGreen > oauthPixels.averageBlue + 3)

        let apiKeyRender = try renderedFooterImage(authMode: "api_key", accessibilityLabel: "API KEY")
        writeEvidenceImage(apiKeyRender.image, name: "t318-api-key-footer-render.png")
        let apiKeyPixels = try sampledTextPixels(in: apiKeyRender.image, frame: apiKeyRender.labelFrame)
        #expect(apiKeyPixels.count >= 12)
        #expect(apiKeyPixels.averageRed > apiKeyPixels.averageBlue + 20)
        #expect(apiKeyPixels.averageGreen > apiKeyPixels.averageBlue + 20)
    }

    @Test("Footer model label prefers matching catalog display name")
    func footerModelLabelPrefersMatchingCatalogDisplayName() throws {
        let status = try decodedStatus(
            displayModel: "qwen3.6-35b-a3b",
            catalogName: "Qwen 3.6 35B-A3B Q4_K_M (gibson)"
        )

        #expect(SessionMetadataFooterCell.footerText(for: status) == "Qwen 3.6 35B-A3B Q4_K_M (gibson)  ·  Thinking high  ·  Fast off")
    }

    @Test("Footer model menu deduplicates catalog refs with one selected item")
    func footerModelMenuDeduplicatesCatalogRefsWithOneSelectedItem() throws {
        let status = try decodedStatus(
            displayModel: "gpt-5.5",
            catalogModelsJSON: """
              {
                "id": "gpt-5.5",
                "provider": "openai",
                "ref": "openai/gpt-5.5",
                "name": "GPT-5.5",
                "alias": "gpt-5.5"
              },
              {
                "id": "gpt-5.4",
                "provider": "openai",
                "ref": "openai/gpt-5.4",
                "name": "GPT-5.4",
                "alias": "gpt-5.4"
              },
              {
                "id": "gpt-5.5-duplicate",
                "provider": "openai",
                "ref": "openai/gpt-5.5",
                "name": "GPT-5.5 Experimental",
                "alias": "gpt-5.5"
              }
            """
        )
        let cell = SessionMetadataFooterCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: SessionMetadataFooterCell.height(for: status))
        )
        cell.configure(status: status, isDark: false, isSpatial: false, onSelect: { _, _, _, _ in })
        cell.layoutIfNeeded()
        let modelButton = try #require(
            allSubviews(in: cell).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "GPT-5.5" }
        )
        let actions = try #require(modelButton.menu?.children.compactMap { $0 as? UIAction })

        #expect(actions.map(\.title) == ["GPT-5.5", "GPT-5.4"])
        #expect(actions.filter { $0.image != nil }.map(\.title) == ["GPT-5.5"])
    }

    @Test("Footer appends when rendered items and footer-capable status are present")
    func footerAppendsWhenRenderedItemsAndFooterCapableStatusArePresent() {
        #expect(SessionMetadataFooterCell.shouldAppendFooter(after: ["message-1"], status: makeStatus()))
        #expect(SessionMetadataFooterCell.shouldAppendFooter(after: [], status: makeStatus()) == false)
        #expect(SessionMetadataFooterCell.shouldAppendFooter(after: ["message-1"], status: nil))
    }

    @Test("Footer chrome persists while session metadata is loading")
    func footerChromePersistsWhileSessionMetadataIsLoading() throws {
        let cell = makeConfiguredCell(status: nil)

        _ = try footerSearchField(in: cell)
        _ = try versionLabel(in: cell)
        _ = try testMenuButton(in: cell)

        let disabledButtons = footerActionButtons(in: cell)
        #expect(SessionMetadataFooterCell.height(for: nil) == 142)
        #expect(SessionMetadataFooterCell.footerText(for: nil) == "Model loading  ·  Thinking loading  ·  Fast loading")
        #expect(disabledButtons.map(\.accessibilityLabel) == ["Model loading", "Thinking loading", "Fast loading"])
        #expect(disabledButtons.allSatisfy { !$0.isEnabled })
    }

    @Test("Footer chrome persists while model metadata is unavailable")
    func footerChromePersistsWhileModelMetadataIsUnavailable() throws {
        let status = makeStatus(
            model: nil,
            thinkingLevel: nil,
            fastMode: nil,
            setModel: .init(supported: false, reason: "model_catalog_unavailable"),
            setThinking: .init(supported: false, reason: "model_metadata_unavailable"),
            setFastMode: .init(supported: false, reason: "model_metadata_unavailable")
        )
        let cell = makeConfiguredCell(status: status)

        _ = try footerSearchField(in: cell)
        _ = try versionLabel(in: cell)
        _ = try testMenuButton(in: cell)

        let disabledButtons = footerActionButtons(in: cell)
        #expect(SessionMetadataFooterCell.footerText(for: status) == "Model unavailable  ·  Thinking unavailable  ·  Fast unavailable")
        #expect(disabledButtons.map(\.accessibilityLabel) == ["Model unavailable", "Thinking unavailable", "Fast unavailable"])
        #expect(disabledButtons.allSatisfy { !$0.isEnabled })
    }

    @Test("Harness footer uses setHarness capability reason and does not build a menu when unsupported")
    func harnessFooterSurfacesSetHarnessUnsupportedReason() async throws {
        var unavailableReason: String?
        let status = makeStatus(
            harness: "codex",
            setHarness: .init(
                supported: false,
                reason: "credential_unavailable",
                options: [.init(title: "claude", value: "claude", enabled: true)]
            )
        )
        let cell = makeConfiguredCell(
            status: status,
            isTightbeam: true,
            harnessOptions: ["claude"],
            onUnavailableSelect: { reason in unavailableReason = reason }
        )

        let harnessButton = try #require(
            footerActionButtons(in: cell).first { $0.accessibilityLabel == "Harness codex" }
        )
        #expect(harnessButton.isEnabled)
        #expect(harnessButton.menu == nil)
        #expect(harnessButton.accessibilityHint == "credential_unavailable")

        harnessButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(20))

        #expect(unavailableReason == "credential_unavailable")
    }

    @Test("Footer controls preserve fallback model, thinking, and Fast options when live catalogs are absent")
    func footerControlsPreserveFallbackOptionsWhenLiveCatalogsAreAbsent() throws {
        let status = makeStatus()
        let cell = makeConfiguredCell(status: status)
        let buttons = footerActionButtons(in: cell)

        #expect(buttons.map(\.accessibilityLabel) == ["gpt-5.5", "Thinking high", "Fast on"])
        #expect(buttons.allSatisfy { $0.menu != nil })
        #expect(buttons.allSatisfy { $0.isEnabled })
        #expect(buttons[0].menu?.children.compactMap { ($0 as? UIAction)?.title } == [
            "gpt-5.5", "claude-sonnet-4.6"
        ])
        #expect(buttons[1].menu?.children.compactMap { ($0 as? UIAction)?.title }.contains("adaptive") == true)
        #expect(buttons[2].menu?.children.compactMap { ($0 as? UIAction)?.title } == ["On", "Off"])
    }

    @Test("Harness footer requires server value before building an action")
    func harnessFooterRequiresServerValueBeforeBuildingAction() throws {
        let status = makeStatus(
            harness: "codex",
            setHarness: .init(
                supported: true,
                reason: nil,
                options: [.init(title: "Claude Display", value: nil, enabled: true)]
            )
        )
        let cell = makeConfiguredCell(
            status: status,
            isTightbeam: true,
            harnessOptions: []
        )

        let harnessButton = try #require(
            footerActionButtons(in: cell).first { $0.accessibilityLabel == "Harness codex" }
        )
        #expect(harnessButton.isEnabled == false)
        #expect(harnessButton.menu == nil)
        #expect(harnessButton.accessibilityHint == "harness_options_unavailable")
    }

    @Test("Footer controls disable cached options while session status is stale")
    func footerControlsDisableCachedOptionsWhileSessionStatusIsStale() throws {
        let status = makeStatus(
            harness: "codex",
            setHarness: .init(
                supported: true,
                reason: nil,
                options: [
                    .init(title: "codex", value: "codex", enabled: true),
                    .init(title: "claude", value: "claude", enabled: true),
                ]
            )
        )
        let cell = makeConfiguredCell(
            status: status,
            statusAvailability: .stale,
            isTightbeam: true,
            harnessOptions: ["codex", "claude"]
        )
        let buttons = footerActionButtons(in: cell)

        #expect(Set(buttons.compactMap(\.accessibilityLabel)) == ["gpt-5.5", "Thinking high", "Fast on", "Harness codex"])
        #expect(buttons.allSatisfy { $0.menu == nil })
        #expect(buttons.allSatisfy { !$0.isEnabled })
        #expect(buttons.allSatisfy { $0.accessibilityHint == "session_status_stale" })
    }

    @Test("Footer controls distinguish unavailable status from stale status")
    func footerControlsSurfaceUnavailableStatusReason() throws {
        let status = makeStatus(
            harness: "codex",
            setHarness: .init(
                supported: true,
                reason: nil,
                options: [
                    .init(title: "codex", value: "codex", enabled: true),
                    .init(title: "claude", value: "claude", enabled: true),
                ]
            )
        )
        let cell = makeConfiguredCell(
            status: status,
            statusAvailability: .unavailable,
            isTightbeam: true,
            harnessOptions: ["codex", "claude"]
        )
        let buttons = footerActionButtons(in: cell)

        #expect(buttons.allSatisfy { $0.menu == nil })
        #expect(buttons.allSatisfy { !$0.isEnabled })
        #expect(buttons.allSatisfy { $0.accessibilityHint == "session_status_unavailable" })
    }

    @Test("Popup selectors mark current item with checkmark image instead of text")
    func popupSelectorsMarkCurrentItemWithCheckmarkImageInsteadOfText() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)
        let expectedCurrentTitlesByButton = [
            "gpt-5.5": "gpt-5.5",
            "Thinking high": "high",
            "Fast on": "On"
        ]

        for button in buttons {
            let actions = try #require(button.menu?.children.compactMap { $0 as? UIAction })
            #expect(actions.allSatisfy { !$0.title.localizedCaseInsensitiveContains("(current)") })

            let currentTitle = try #require(expectedCurrentTitlesByButton[button.accessibilityLabel ?? ""])
            let currentAction = try #require(actions.first { $0.title == currentTitle })
            #expect(currentAction.image != nil)
            #expect(currentAction.discoverabilityTitle == "\(currentTitle), Current")

            for action in actions where action.title != currentTitle {
                #expect(action.image == nil)
                #expect(action.discoverabilityTitle == action.title)
            }
        }
    }
}

private func makeConfiguredCell(authMode: String? = nil, isDark: Bool = false, isSpatial: Bool = false) -> SessionMetadataFooterCell {
    makeConfiguredCell(status: makeStatus(authMode: authMode), isDark: isDark, isSpatial: isSpatial)
}

private func makeConfiguredCell(
    status: SessionStatus?,
    statusAvailability: SessionStatusAvailability? = nil,
    isDark: Bool = false,
    isSpatial: Bool = false,
    isTightbeam: Bool = false,
    harnessOptions: [String] = [],
    onUnavailableSelect: (@MainActor (String) -> Void)? = nil
) -> SessionMetadataFooterCell {
    let cell = SessionMetadataFooterCell(
        frame: CGRect(
            x: 0,
            y: 0,
            width: 320,
            height: SessionMetadataFooterCell.height(
                for: status,
                isTightbeam: isTightbeam,
                harnessOptions: harnessOptions
            )
        )
    )
    cell.configure(
        status: status,
        statusAvailability: statusAvailability,
        isDark: isDark,
        isSpatial: isSpatial,
        isTightbeam: isTightbeam,
        harnessOptions: harnessOptions,
        onSelect: { _, _, _, _ in },
        onUnavailableSelect: onUnavailableSelect
    )
    cell.setNeedsLayout()
    cell.layoutIfNeeded()
    return cell
}

private func makeStatus(
    authMode: String? = nil,
    model: String? = "gpt-5.5",
    thinkingLevel: String? = "high",
    fastMode: Bool? = true,
    harness: String? = nil,
    setModel: SessionStatus.Capability? = .init(supported: true, reason: nil),
    setThinking: SessionStatus.Capability? = .init(supported: true, reason: nil),
    setFastMode: SessionStatus.Capability? = .init(supported: true, reason: nil),
    setHarness: SessionStatus.Capability? = nil,
    modelCatalog explicitModelCatalog: SessionStatus.ModelCatalog? = nil
) -> SessionStatus {
    return SessionStatus(
        sessionKey: "agent:main:clawline:user:s_test",
        display: .init(
            model: model,
            fallbackModels: ["gpt-5.5", "claude-sonnet-4.6"],
            provider: "openai",
            harness: harness,
            authMode: authMode,
            reasoningLevel: nil,
            thinkingLevel: thinkingLevel,
            fastMode: fastMode,
            mode: nil,
            verbosity: nil
        ),
        run: .init(
            state: .idle,
            runId: nil,
            messageId: nil,
            startedAt: nil,
            queueDepth: nil
        ),
        context: nil,
        approval: nil,
        capabilities: .init(
            cancelCurrentRun: nil,
            setModel: setModel,
            setThinking: setThinking,
            setReasoning: nil,
            setFastMode: setFastMode,
            setMode: nil,
            setVerbosity: nil,
            setHarness: setHarness,
            canCancelCurrentRun: nil,
            canChangeModel: nil,
            canChangeReasoning: nil,
            canChangeFastMode: nil,
            canChangeVerbosity: nil,
            readOnlyStatus: nil
        ),
        modelCatalog: explicitModelCatalog
    )
}

@MainActor
private func decodedStatus(displayModel: String, catalogName: String) throws -> SessionStatus {
    try decodedStatus(
        displayModel: displayModel,
        catalogModelsJSON: """
          {
            "id": "\(displayModel)",
            "provider": "gibson",
            "ref": "gibson/\(displayModel)",
            "name": "\(catalogName)",
            "alias": "qwen"
          }
        """
    )
}

@MainActor
private func decodedStatus(displayModel: String, catalogModelsJSON: String) throws -> SessionStatus {
    let json = """
    {
      "sessionKey": "agent:heimdal:main",
      "display": {
        "model": "\(displayModel)",
        "provider": "gibson",
        "thinkingLevel": "high",
        "fastMode": false
      },
      "run": {
        "state": "idle"
      },
      "capabilities": {
        "setModel": {
          "supported": true
        },
        "setThinking": {
          "supported": true
        },
        "setFastMode": {
          "supported": true
        }
      },
      "modelCatalog": {
        "available": true,
        "models": [
          \(catalogModelsJSON)
        ]
      }
    }
    """
    return try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
}

private func allSubviews(in view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
}

@MainActor
private func footerSearchField(in cell: SessionMetadataFooterCell) throws -> UITextField {
    try #require(
        allSubviews(in: cell).compactMap { $0 as? UITextField }
            .first { $0.accessibilityLabel == "Search current stream" }
    )
}

@MainActor
private func versionLabel(in cell: SessionMetadataFooterCell) throws -> UILabel {
    try #require(
        allSubviews(in: cell).compactMap { $0 as? UILabel }
            .first { $0.text == SessionMetadataFooterCell.versionBuildText() }
    )
}

@MainActor
private func testMenuButton(in cell: SessionMetadataFooterCell) throws -> UIButton {
    try #require(
        allSubviews(in: cell).compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Settings" }
    )
}

@MainActor
private func renderedFooterImage(authMode: String, accessibilityLabel: String) throws -> (image: UIImage, labelFrame: CGRect) {
    let cell = makeConfiguredCell(authMode: authMode)
    let label = try #require(
        allSubviews(in: cell).compactMap { $0 as? UILabel }
            .first { $0.accessibilityLabel == accessibilityLabel }
    )
    let container = UIView(frame: CGRect(x: 0, y: 0, width: cell.bounds.width, height: cell.bounds.height))
    container.backgroundColor = .white
    cell.frame = container.bounds
    container.addSubview(cell)
    container.setNeedsLayout()
    container.layoutIfNeeded()

    let renderer = UIGraphicsImageRenderer(bounds: container.bounds)
    let image = renderer.image { _ in
        container.drawHierarchy(in: container.bounds, afterScreenUpdates: true)
    }
    return (image, label.convert(label.bounds, to: container))
}

private func writeEvidenceImage(_ image: UIImage, name: String) {
    let environment = ProcessInfo.processInfo.environment
    let directory = environment["T318_FOOTER_EVIDENCE_DIR"]
        ?? environment["TEST_RUNNER_T318_FOOTER_EVIDENCE_DIR"]
    guard let directory,
          let data = image.pngData() else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

private func sampledTextPixels(in image: UIImage, frame: CGRect) throws -> (count: Int, averageRed: Double, averageGreen: Double, averageBlue: Double) {
    let cgImage = try #require(image.cgImage)
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let scale = image.scale
    let sampleFrame = frame.insetBy(dx: 2, dy: 2)
    let minX = max(0, Int(floor(sampleFrame.minX * scale)))
    let maxX = min(width - 1, Int(ceil(sampleFrame.maxX * scale)))
    let minY = max(0, Int(floor(sampleFrame.minY * scale)))
    let maxY = min(height - 1, Int(ceil(sampleFrame.maxY * scale)))

    var count = 0
    var red = 0
    var green = 0
    var blue = 0
    for y in minY ... maxY {
        for x in minX ... maxX {
            let offset = ((y * width) + x) * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            guard r < 248 || g < 248 || b < 248 else { continue }
            count += 1
            red += r
            green += g
            blue += b
        }
    }
    return (
        count,
        count == 0 ? 0 : Double(red) / Double(count),
        count == 0 ? 0 : Double(green) / Double(count),
        count == 0 ? 0 : Double(blue) / Double(count)
    )
}

@MainActor
private func footerButtons(in cell: SessionMetadataFooterCell) throws -> [UIButton] {
    let buttons = footerActionButtons(in: cell)
        .filter { $0.isEnabled }
    #expect(buttons.map(\.accessibilityLabel) == ["gpt-5.5", "Thinking high", "Fast on"])
    return try #require(buttons.count == 3 ? buttons : nil)
}

@MainActor
private func footerActionButtons(in cell: SessionMetadataFooterCell) -> [UIButton] {
    allSubviews(in: cell)
        .compactMap { $0 as? UIButton }
        .filter { $0.accessibilityLabel != "Settings" }
        .sorted {
            $0.convert($0.bounds, to: cell).minX < $1.convert($1.bounds, to: cell).minX
        }
}
