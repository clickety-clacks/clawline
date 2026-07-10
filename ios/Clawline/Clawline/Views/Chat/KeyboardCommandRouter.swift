//
//  KeyboardCommandRouter.swift
//  Clawline
//
//  Created by Codex on 5/19/26.
//

import SwiftUI
import UIKit

enum KeyboardCommandIntent: Equatable {
    case focusPromptInput
    case openStreamPopup
    case navigatePreviousStream
    case navigateNextStream
    case toggleShowOnlyUserMessages
    case notificationAssignedOpen(Int)
    case notificationAssignedReply(Int)
    case notificationAssignedDismiss(Int)
    case notificationDismissAll
    case notificationToggleDock
    case notificationScrollForward
    case notificationScrollBackward
    case transcriptBubbleScrollForward
    case transcriptBubbleScrollBackward
    case transcriptChatScrollForward
    case transcriptChatScrollBackward
    case menuNavigateUp
    case menuNavigateDown
    case menuActivate
    case menuCancel
    case pickerNavigateUp
    case pickerNavigateDown
    case pickerAccept
    case textSubmit
    case textModifiedNewline
    case textCancel
    case textEditing
}

enum KeyboardSurfaceKind: String, Equatable {
    case composer
    case chatSelector
    case mentionPicker
    case notificationBubble
    case notificationReply
    case notificationActionMenu
    case transcript
}

enum KeyboardSurfaceId: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    case composer
    case chatSelectorRow(String)
    case mentionPicker
    case notificationBubble(String)
    case notificationReply(String)
    case notificationActionMenu(String)
    case transcript
    case custom(String)

    init(stringLiteral value: String) {
        self = .custom(value)
    }

    var description: String {
        switch self {
        case .composer:
            return "composer"
        case .chatSelectorRow(let sessionKey):
            return "chat-selector-row:\(sessionKey)"
        case .mentionPicker:
            return "mention-picker"
        case .notificationBubble(let domainRef):
            return "notification-bubble:\(domainRef)"
        case .notificationReply(let domainRef):
            return "notification-reply:\(domainRef)"
        case .notificationActionMenu(let domainRef):
            return "notification-action-menu:\(domainRef)"
        case .transcript:
            return "transcript"
        case .custom(let value):
            return value
        }
    }
}

enum KeyboardCommandFamily: Hashable {
    case appNavigation
    case chatSelectorAssigned
    case notificationAssigned
    case notificationStack
    case notificationScroll
    case menuNavigation
    case pickerNavigation
    case pickerAccept
    case textEditing
    case transcriptFallback
}

struct KeyboardSurfaceRecord: Equatable {
    let surfaceId: KeyboardSurfaceId
    let surfaceKind: KeyboardSurfaceKind
    let parentSurfaceId: KeyboardSurfaceId?
    let lifecycleToken: String
    var visible: Bool
    var active: Bool
    var focusedHint: Bool
    let commandFamilies: Set<KeyboardCommandFamily>
    let domainRef: String?

    var participatesInRouting: Bool {
        visible && active
    }
}

struct KeyboardOwnershipStore: Equatable {
    var sceneId: String
    private(set) var surfaceRegistry: [KeyboardSurfaceId: KeyboardSurfaceRecord] = [:]
    private(set) var chatSelectorShortcutMap: [Int: KeyboardSurfaceId] = [:]
    private(set) var notificationShortcutMap: [Int: KeyboardSurfaceId] = [:]
    private(set) var routeEpoch: Int = 0

    init(sceneId: String = "active-chat-scene") {
        self.sceneId = sceneId
    }

    mutating func register(_ record: KeyboardSurfaceRecord) {
        surfaceRegistry[record.surfaceId] = record
        routeEpoch += 1
        reconcile()
    }

    mutating func update(
        surfaceId: KeyboardSurfaceId,
        lifecycleToken: String,
        visible: Bool? = nil,
        active: Bool? = nil,
        focusedHint: Bool? = nil
    ) {
        guard var record = surfaceRegistry[surfaceId],
              record.lifecycleToken == lifecycleToken else {
            return
        }
        if let visible {
            record.visible = visible
        }
        if let active {
            record.active = active
        }
        if let focusedHint {
            record.focusedHint = focusedHint
        }
        surfaceRegistry[surfaceId] = record
        routeEpoch += 1
        reconcile()
    }

    mutating func unregister(surfaceId: KeyboardSurfaceId, lifecycleToken: String) {
        guard surfaceRegistry[surfaceId]?.lifecycleToken == lifecycleToken else { return }
        surfaceRegistry.removeValue(forKey: surfaceId)
        routeEpoch += 1
        reconcile()
    }

    mutating func setNotificationShortcutMap(_ map: [Int: KeyboardSurfaceId]) {
        notificationShortcutMap = map.filter { _, surfaceId in
            surfaceRegistry[surfaceId]?.participatesInRouting == true
        }
        routeEpoch += 1
        reconcile()
    }

    mutating func setChatSelectorShortcutMap(_ map: [Int: KeyboardSurfaceId]) {
        chatSelectorShortcutMap = map.filter { _, surfaceId in
            surfaceRegistry[surfaceId]?.participatesInRouting == true
        }
        routeEpoch += 1
        reconcile()
    }

    mutating func synchronize(
        records: [KeyboardSurfaceRecord],
        notificationShortcutMap nextNotificationShortcutMap: [Int: KeyboardSurfaceId],
        chatSelectorShortcutMap nextChatSelectorShortcutMap: [Int: KeyboardSurfaceId] = [:]
    ) {
        let nextRegistry = Dictionary(uniqueKeysWithValues: records.map { ($0.surfaceId, $0) })
        guard nextRegistry != surfaceRegistry
                || nextNotificationShortcutMap != notificationShortcutMap
                || nextChatSelectorShortcutMap != chatSelectorShortcutMap else {
            return
        }
        surfaceRegistry = nextRegistry
        chatSelectorShortcutMap = nextChatSelectorShortcutMap.filter { _, surfaceId in
            nextRegistry[surfaceId]?.participatesInRouting == true
        }
        notificationShortcutMap = nextNotificationShortcutMap.filter { _, surfaceId in
            nextRegistry[surfaceId]?.participatesInRouting == true
        }
        routeEpoch += 1
        reconcile()
    }

    mutating func reconcile() {
        var removedAny = false
        repeat {
            removedAny = false
            for record in surfaceRegistry.values {
                guard let parentSurfaceId = record.parentSurfaceId else { continue }
                if surfaceRegistry[parentSurfaceId]?.participatesInRouting != true {
                    surfaceRegistry.removeValue(forKey: record.surfaceId)
                    removedAny = true
                }
            }
        } while removedAny

        notificationShortcutMap = notificationShortcutMap.filter { _, surfaceId in
            surfaceRegistry[surfaceId]?.participatesInRouting == true
        }
        chatSelectorShortcutMap = chatSelectorShortcutMap.filter { _, surfaceId in
            surfaceRegistry[surfaceId]?.participatesInRouting == true
        }
    }

    func activeVisibleSurfaces() -> [KeyboardSurfaceRecord] {
        surfaceRegistry.values.filter(\.participatesInRouting)
    }

    func firstActiveSurface(
        kind: KeyboardSurfaceKind,
        focusedOnly: Bool = false,
        supporting family: KeyboardCommandFamily? = nil
    ) -> KeyboardSurfaceRecord? {
        activeVisibleSurfaces().first { record in
            record.surfaceKind == kind
                && (!focusedOnly || record.focusedHint)
                && family.map { record.commandFamilies.contains($0) } ?? true
        }
    }

    func activeNotificationSurface(supporting family: KeyboardCommandFamily) -> KeyboardSurfaceRecord? {
        let focused = activeVisibleSurfaces().first {
            $0.surfaceKind == .notificationBubble
                && $0.focusedHint
                && $0.commandFamilies.contains(family)
        }
        if let focused {
            return focused
        }
        let mapped = notificationShortcutMap
            .sorted { $0.key < $1.key }
            .compactMap { surfaceRegistry[$0.value] }
            .first { $0.participatesInRouting && $0.commandFamilies.contains(family) }
        return mapped ?? firstActiveSurface(kind: .notificationBubble, supporting: family)
    }

    mutating func reconcileFocusedTextSurface(_ focusedSurfaceId: KeyboardSurfaceId) {
        for record in activeVisibleSurfaces() where record.commandFamilies.contains(.textEditing) {
            update(
                surfaceId: record.surfaceId,
                lifecycleToken: record.lifecycleToken,
                focusedHint: record.surfaceId == focusedSurfaceId
            )
        }
    }
}

struct KeyboardRouteDecision: Equatable {
    enum Outcome: Equatable {
        case handled(KeyboardSurfaceId)
        case handledMany([KeyboardSurfaceId])
        case fallthroughToDefault
        case ignored
    }

    let intent: KeyboardCommandIntent
    let outcome: Outcome
    let priorityRule: String
    let participatingSurfaces: [KeyboardSurfaceId]
    let routeEpoch: Int
    let bridgeConsumedEvent: Bool
}

extension KeyboardRouteDecision.Outcome {
    var handledSurfaceIds: [KeyboardSurfaceId] {
        switch self {
        case .handled(let surfaceId):
            return [surfaceId]
        case .handledMany(let surfaceIds):
            return surfaceIds
        case .fallthroughToDefault, .ignored:
            return []
        }
    }

    func containsHandledSurface(_ surfaceId: KeyboardSurfaceId) -> Bool {
        handledSurfaceIds.contains(surfaceId)
    }

    var containsNotificationBubble: Bool {
        handledSurfaceIds.contains { surfaceId in
            if case .notificationBubble = surfaceId {
                return true
            }
            return false
        }
    }
}

enum KeyboardCommandRouter {
    static func route(
        intent: KeyboardCommandIntent,
        store: KeyboardOwnershipStore,
        bridgeConsumedEvent: Bool = true
    ) -> KeyboardRouteDecision {
        var reconciledStore = store
        reconciledStore.reconcile()
        let participants = reconciledStore.activeVisibleSurfaces().map(\.surfaceId).sorted { $0.description < $1.description }

        func decision(
            _ outcome: KeyboardRouteDecision.Outcome,
            _ priorityRule: String
        ) -> KeyboardRouteDecision {
            KeyboardRouteDecision(
                intent: intent,
                outcome: outcome,
                priorityRule: priorityRule,
                participatingSurfaces: participants,
                routeEpoch: reconciledStore.routeEpoch,
                bridgeConsumedEvent: bridgeConsumedEvent
            )
        }

        switch intent {
        case .menuNavigateUp, .menuNavigateDown, .menuActivate, .menuCancel:
            if let menu = reconciledStore.firstActiveSurface(kind: .notificationActionMenu, supporting: .menuNavigation) {
                return decision(.handled(menu.surfaceId), "PR-01")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .pickerNavigateUp, .pickerNavigateDown:
            if let picker = reconciledStore.firstActiveSurface(kind: .mentionPicker, supporting: .pickerNavigation) {
                return decision(.handled(picker.surfaceId), "PR-02")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .pickerAccept:
            if let picker = reconciledStore.firstActiveSurface(kind: .mentionPicker, supporting: .pickerAccept) {
                return decision(.handled(picker.surfaceId), "PR-02")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .notificationAssignedOpen(let index),
             .notificationAssignedReply(let index),
             .notificationAssignedDismiss(let index):
            if case .notificationAssignedOpen = intent,
               let selectorSurfaceId = reconciledStore.chatSelectorShortcutMap[index],
               let selectorRecord = reconciledStore.surfaceRegistry[selectorSurfaceId],
               selectorRecord.participatesInRouting,
               selectorRecord.commandFamilies.contains(.chatSelectorAssigned) {
                return decision(.handled(selectorSurfaceId), "PR-00")
            }
            if let surfaceId = reconciledStore.notificationShortcutMap[index],
               let record = reconciledStore.surfaceRegistry[surfaceId],
               record.participatesInRouting,
               record.commandFamilies.contains(.notificationAssigned) {
                return decision(.handled(surfaceId), "PR-03")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .notificationDismissAll, .notificationToggleDock:
            if let notification = reconciledStore.activeNotificationSurface(supporting: .notificationStack) {
                return decision(.handled(notification.surfaceId), "PR-04")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .notificationScrollForward, .notificationScrollBackward:
            if let notification = reconciledStore.activeNotificationSurface(supporting: .notificationScroll) {
                return decision(.handled(notification.surfaceId), "PR-04")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .transcriptBubbleScrollForward,
             .transcriptBubbleScrollBackward:
            let transcript = reconciledStore.firstActiveSurface(kind: .transcript, supporting: .transcriptFallback)
            let notification = reconciledStore.activeNotificationSurface(supporting: .notificationScroll)
            let owners = [transcript?.surfaceId, notification?.surfaceId].compactMap { $0 }
            if owners.count > 1 {
                return decision(.handledMany(owners), "PR-04")
            }
            if let notification {
                return decision(.handled(notification.surfaceId), "PR-04")
            }
            if let transcript {
                return decision(.handled(transcript.surfaceId), "PR-07")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .transcriptChatScrollForward,
             .transcriptChatScrollBackward:
            if let transcript = reconciledStore.firstActiveSurface(kind: .transcript, supporting: .transcriptFallback) {
                return decision(.handled(transcript.surfaceId), "PR-07")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .textSubmit, .textModifiedNewline, .textCancel, .textEditing:
            if intent == .textSubmit,
               let picker = reconciledStore.firstActiveSurface(kind: .mentionPicker, supporting: .pickerAccept) {
                return decision(.handled(picker.surfaceId), "PR-02")
            }
            if let reply = reconciledStore.firstActiveSurface(kind: .notificationReply, focusedOnly: true, supporting: .textEditing) {
                return decision(.handled(reply.surfaceId), "PR-05")
            }
            if let composer = reconciledStore.firstActiveSurface(kind: .composer, focusedOnly: true, supporting: .textEditing) {
                return decision(.handled(composer.surfaceId), "PR-06")
            }
            return decision(.fallthroughToDefault, "PR-07")

        case .focusPromptInput, .openStreamPopup, .navigatePreviousStream, .navigateNextStream, .toggleShowOnlyUserMessages:
            if let transcript = reconciledStore.firstActiveSurface(kind: .transcript, supporting: .appNavigation) {
                return decision(.handled(transcript.surfaceId), "PR-07")
            }
            return decision(.fallthroughToDefault, "PR-07")
        }
    }
}

enum TextEditingShortcutAction: Equatable {
    case moveToBeginning
    case moveToEnd
    case deletePreviousWord
    case deleteToBeginning
    case deleteToEnd
    case clear
}

enum TextEditingShortcutContract {
    struct Spec: Equatable {
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let action: TextEditingShortcutAction
    }

    static let specs: [Spec] = [
        Spec(input: "a", modifierFlags: [.control], action: .moveToBeginning),
        Spec(input: "e", modifierFlags: [.control], action: .moveToEnd),
        Spec(input: "w", modifierFlags: [.control], action: .deletePreviousWord),
        Spec(input: "u", modifierFlags: [.control], action: .deleteToBeginning),
        Spec(input: "k", modifierFlags: [.control], action: .deleteToEnd),
        Spec(input: "c", modifierFlags: [.control], action: .clear)
    ]

    static func action(for command: UIKeyCommand) -> TextEditingShortcutAction? {
        specs.first {
            command.input == $0.input && command.modifierFlags == $0.modifierFlags
        }?.action
    }

    static func keyCommands(action: Selector) -> [UIKeyCommand] {
        specs.map { spec in
            let command = UIKeyCommand(
                input: spec.input,
                modifierFlags: spec.modifierFlags,
                action: action
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @MainActor
    static func perform(
        _ action: TextEditingShortcutAction,
        in textView: UITextView,
        replace: (UITextRange, String) -> Void
    ) {
        switch action {
        case .moveToBeginning:
            textView.selectedTextRange = textView.textRange(
                from: textView.beginningOfDocument,
                to: textView.beginningOfDocument
            )
        case .moveToEnd:
            textView.selectedTextRange = textView.textRange(
                from: textView.endOfDocument,
                to: textView.endOfDocument
            )
        case .deletePreviousWord:
            if let selectedRange = textView.selectedTextRange, !selectedRange.isEmpty {
                replace(selectedRange, "")
                return
            }

            guard let cursor = textView.selectedTextRange?.start,
                  let textBeforeCursorRange = textView.textRange(
                    from: textView.beginningOfDocument,
                    to: cursor
                  ),
                  let textBeforeCursor = textView.text(in: textBeforeCursorRange),
                  !textBeforeCursor.isEmpty else { return }

            var deleteStartIndex = textBeforeCursor.endIndex
            while deleteStartIndex > textBeforeCursor.startIndex {
                let previousIndex = textBeforeCursor.index(before: deleteStartIndex)
                if !textBeforeCursor[previousIndex].isWhitespace { break }
                deleteStartIndex = previousIndex
            }
            while deleteStartIndex > textBeforeCursor.startIndex {
                let previousIndex = textBeforeCursor.index(before: deleteStartIndex)
                if textBeforeCursor[previousIndex].isWhitespace { break }
                deleteStartIndex = previousIndex
            }

            let charactersToDelete = textBeforeCursor.distance(
                from: deleteStartIndex,
                to: textBeforeCursor.endIndex
            )
            guard charactersToDelete > 0,
                  let deleteStart = textView.position(from: cursor, offset: -charactersToDelete),
                  let deleteRange = textView.textRange(from: deleteStart, to: cursor) else { return }
            replace(deleteRange, "")
        case .deleteToBeginning:
            guard let cursor = textView.selectedTextRange?.start,
                  let range = textView.textRange(from: textView.beginningOfDocument, to: cursor),
                  !range.isEmpty else { return }
            replace(range, "")
        case .deleteToEnd:
            guard let cursor = textView.selectedTextRange?.start,
                  let range = textView.textRange(from: cursor, to: textView.endOfDocument),
                  !range.isEmpty else { return }
            replace(range, "")
        case .clear:
            guard let range = textView.textRange(
                from: textView.beginningOfDocument,
                to: textView.endOfDocument
            ) else { return }
            replace(range, "")
        }
    }
}

enum KeyboardCommandBridge {
    struct KeyCommandSpec: Equatable {
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let intent: KeyboardCommandIntent
    }

    struct SwiftUIShortcutSpec: Equatable {
        let input: Character
        let modifiers: EventModifiers
        let intent: KeyboardCommandIntent
    }

    static let noTextInputSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "/", modifierFlags: [], intent: .openStreamPopup),
        KeyCommandSpec(input: ";", modifierFlags: [], intent: .openStreamPopup),
        KeyCommandSpec(input: " ", modifierFlags: [], intent: .focusPromptInput),
        KeyCommandSpec(input: "\r", modifierFlags: [], intent: .focusPromptInput)
    ]

    static let navigationSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "l", modifierFlags: [.command], intent: .focusPromptInput),
        KeyCommandSpec(input: ";", modifierFlags: [.command], intent: .openStreamPopup),
        KeyCommandSpec(input: ";", modifierFlags: [.control], intent: .openStreamPopup),
        KeyCommandSpec(input: "h", modifierFlags: [.command, .shift], intent: .navigatePreviousStream),
        KeyCommandSpec(input: "l", modifierFlags: [.command, .shift], intent: .navigateNextStream),
        KeyCommandSpec(input: "`", modifierFlags: [.command], intent: .toggleShowOnlyUserMessages)
    ]

    static let transcriptScrollSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "j", modifierFlags: [.command], intent: .transcriptBubbleScrollForward),
        KeyCommandSpec(input: "k", modifierFlags: [.command], intent: .transcriptBubbleScrollBackward),
        KeyCommandSpec(input: "j", modifierFlags: [.command, .shift], intent: .transcriptChatScrollForward),
        KeyCommandSpec(input: "k", modifierFlags: [.command, .shift], intent: .transcriptChatScrollBackward)
    ]

    static let notificationScrollSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "j", modifierFlags: [.command], intent: .notificationScrollForward),
        KeyCommandSpec(input: "k", modifierFlags: [.command], intent: .notificationScrollBackward),
        KeyCommandSpec(input: "-", modifierFlags: [.command, .shift, .alternate], intent: .notificationDismissAll),
        KeyCommandSpec(input: "_", modifierFlags: [.command, .shift, .alternate], intent: .notificationDismissAll),
        KeyCommandSpec(input: "\\", modifierFlags: [.command], intent: .notificationToggleDock)
    ]

    static let menuSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: UIKeyCommand.inputUpArrow, modifierFlags: [], intent: .menuNavigateUp),
        KeyCommandSpec(input: UIKeyCommand.inputUpArrow, modifierFlags: [.numericPad], intent: .menuNavigateUp),
        KeyCommandSpec(input: UIKeyCommand.inputDownArrow, modifierFlags: [], intent: .menuNavigateDown),
        KeyCommandSpec(input: UIKeyCommand.inputDownArrow, modifierFlags: [.numericPad], intent: .menuNavigateDown),
        KeyCommandSpec(input: "\r", modifierFlags: [], intent: .menuActivate),
        KeyCommandSpec(input: "\n", modifierFlags: [], intent: .menuActivate),
        KeyCommandSpec(input: UIKeyCommand.inputEscape, modifierFlags: [], intent: .menuCancel)
    ]

    static let pickerSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "\t", modifierFlags: [], intent: .pickerAccept),
        KeyCommandSpec(input: UIKeyCommand.inputUpArrow, modifierFlags: [], intent: .pickerNavigateUp),
        KeyCommandSpec(input: UIKeyCommand.inputDownArrow, modifierFlags: [], intent: .pickerNavigateDown)
    ]

    static let textInputSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "\r", modifierFlags: [], intent: .textSubmit),
        KeyCommandSpec(input: "\n", modifierFlags: [], intent: .textSubmit),
        KeyCommandSpec(input: "\r", modifierFlags: [.shift], intent: .textModifiedNewline),
        KeyCommandSpec(input: "\n", modifierFlags: [.shift], intent: .textModifiedNewline),
        KeyCommandSpec(input: "\r", modifierFlags: [.control], intent: .textModifiedNewline),
        KeyCommandSpec(input: "\n", modifierFlags: [.control], intent: .textModifiedNewline),
        KeyCommandSpec(input: UIKeyCommand.inputEscape, modifierFlags: [], intent: .textCancel)
    ]

    static func appSpecs(
        notificationVisibleCount: Int,
        selectorShortcutSlots: Set<Int> = []
    ) -> [KeyCommandSpec] {
        navigationSpecs
            + transcriptScrollSpecs
            + numberSpecs(
                notificationVisibleCount: notificationVisibleCount,
                selectorShortcutSlots: selectorShortcutSlots
            )
    }

    static func notificationNumberSpecs(visibleCount: Int) -> [KeyCommandSpec] {
        guard visibleCount > 0 else { return [] }
        return (0..<min(visibleCount, 10)).flatMap { index in
            [
                KeyCommandSpec(input: "\(index)", modifierFlags: [.command], intent: .notificationAssignedOpen(index)),
                KeyCommandSpec(input: "\(index)", modifierFlags: [.command, .alternate], intent: .notificationAssignedReply(index)),
                KeyCommandSpec(input: "\(index)", modifierFlags: [.command, .shift, .alternate], intent: .notificationAssignedDismiss(index))
            ]
        }
    }

    static func numberSpecs(
        notificationVisibleCount: Int,
        selectorShortcutSlots: Set<Int>
    ) -> [KeyCommandSpec] {
        var specs = notificationNumberSpecs(visibleCount: notificationVisibleCount)
        let existingPlainSlots = Set(0..<min(notificationVisibleCount, 10))
        let selectorOnlySlots = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].filter { slot in
            selectorShortcutSlots.contains(slot) && !existingPlainSlots.contains(slot)
        }
        specs.append(contentsOf: selectorOnlySlots.map { slot in
            KeyCommandSpec(input: "\(slot)", modifierFlags: [.command], intent: .notificationAssignedOpen(slot))
        })
        return specs
    }

    static func prioritizedTextInputSpecs(notificationVisibleCount: Int) -> [KeyCommandSpec] {
        let textInputGlobalNavigationSpecs = navigationSpecs.filter {
            ($0.intent == .openStreamPopup && $0.input == ";")
                || $0.intent == .toggleShowOnlyUserMessages
        }
        guard notificationVisibleCount > 0 else {
            return textInputGlobalNavigationSpecs + transcriptScrollSpecs
        }
        return textInputGlobalNavigationSpecs + transcriptScrollSpecs + notificationNumberSpecs(visibleCount: notificationVisibleCount)
    }

    static func hiddenNotificationSwiftUIFallbackSpecs(visibleNotificationCount: Int) -> [SwiftUIShortcutSpec] {
        guard visibleNotificationCount > 0 else { return [] }
        return notificationScrollSpecs
            .filter { $0.intent == .notificationScrollForward || $0.intent == .notificationScrollBackward }
            .compactMap { spec in
            guard let character = spec.input.first else { return nil }
            return SwiftUIShortcutSpec(
                input: character,
                modifiers: eventModifiers(from: spec.modifierFlags),
                intent: spec.intent
            )
        }
    }

    private static func eventModifiers(from modifierFlags: UIKeyModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if modifierFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if modifierFlags.contains(.alternate) {
            modifiers.insert(.option)
        }
        if modifierFlags.contains(.control) {
            modifiers.insert(.control)
        }
        return modifiers
    }

    static func intent(input: String?, modifierFlags: UIKeyModifierFlags) -> KeyboardCommandIntent? {
        guard let input else { return nil }
        let normalizedInput = input.lowercased()
        if let direct = (navigationSpecs + transcriptScrollSpecs + notificationScrollSpecs + noTextInputSpecs + menuSpecs + pickerSpecs + textInputSpecs)
            .first(where: { $0.input.lowercased() == normalizedInput && $0.modifierFlags == modifierFlags }) {
            return direct.intent
        }

        guard normalizedInput.count == 1 else { return nil }
        let filteredModifiers = modifierFlags.intersection([.command, .shift, .alternate, .control])
        if let index = Int(normalizedInput) {
            switch filteredModifiers {
            case [.command]:
                return .notificationAssignedOpen(index)
            case [.command, .alternate]:
                return .notificationAssignedReply(index)
            case [.command, .shift, .alternate]:
                return .notificationAssignedDismiss(index)
            default:
                return nil
            }
        }

        if let shiftedIndex = shiftedNumberIndex(normalizedInput) {
            switch filteredModifiers {
            case [.command, .alternate]:
                return .notificationAssignedReply(shiftedIndex)
            case [.command, .shift, .alternate]:
                return .notificationAssignedDismiss(shiftedIndex)
            default:
                return nil
            }
        }

        return nil
    }

    private static func shiftedNumberIndex(_ input: String) -> Int? {
        switch input {
        case ")": return 0
        case "!": return 1
        case "@": return 2
        case "#": return 3
        case "$": return 4
        case "%": return 5
        case "^": return 6
        case "&": return 7
        case "*": return 8
        case "(": return 9
        default: return nil
        }
    }
}

enum KeyboardOwnershipSceneFactory {
    static func chatSceneRecords(
        visibleNotificationSourceChatIds: [String],
        mentionPickerVisible: Bool,
        mentionPickerHasCompletion: Bool,
        composerFocused: Bool,
        notificationFocusedSourceChatId: String?,
        notificationReplySourceChatIds: [String],
        notificationReplyFocusedSourceChatId: String?,
        actionMenuSourceChatId: String?
    ) -> (records: [KeyboardSurfaceRecord], notificationShortcutMap: [Int: KeyboardSurfaceId]) {
        var records: [KeyboardSurfaceRecord] = [
            KeyboardSurfaceRecord(
                surfaceId: .transcript,
                surfaceKind: .transcript,
                parentSurfaceId: nil,
                lifecycleToken: "transcript",
                visible: true,
                active: true,
                focusedHint: false,
                commandFamilies: [.appNavigation, .transcriptFallback],
                domainRef: nil
            ),
            KeyboardSurfaceRecord(
                surfaceId: .composer,
                surfaceKind: .composer,
                parentSurfaceId: nil,
                lifecycleToken: "composer",
                visible: true,
                active: true,
                focusedHint: composerFocused,
                commandFamilies: [.textEditing],
                domainRef: nil
            )
        ]
        if mentionPickerVisible {
            records.append(
                KeyboardSurfaceRecord(
                    surfaceId: .mentionPicker,
                    surfaceKind: .mentionPicker,
                    parentSurfaceId: .composer,
                    lifecycleToken: "mention-picker",
                    visible: true,
                    active: true,
                    focusedHint: composerFocused,
                    commandFamilies: mentionPickerHasCompletion
                        ? [.pickerNavigation, .pickerAccept]
                        : [.pickerNavigation],
                    domainRef: nil
                )
            )
        }
        for sourceChatId in visibleNotificationSourceChatIds {
            let bubbleId = KeyboardSurfaceId.notificationBubble(sourceChatId)
            records.append(
                KeyboardSurfaceRecord(
                    surfaceId: bubbleId,
                    surfaceKind: .notificationBubble,
                    parentSurfaceId: nil,
                    lifecycleToken: "notification-bubble:\(sourceChatId)",
                    visible: true,
                    active: true,
                    focusedHint: notificationFocusedSourceChatId == sourceChatId,
                    commandFamilies: [.notificationAssigned, .notificationStack, .notificationScroll],
                    domainRef: sourceChatId
                )
            )
            if notificationReplySourceChatIds.contains(sourceChatId) {
                records.append(
                    KeyboardSurfaceRecord(
                        surfaceId: .notificationReply(sourceChatId),
                        surfaceKind: .notificationReply,
                        parentSurfaceId: bubbleId,
                        lifecycleToken: "notification-reply:\(sourceChatId)",
                        visible: true,
                        active: true,
                        focusedHint: notificationReplyFocusedSourceChatId == sourceChatId,
                        commandFamilies: [.textEditing],
                        domainRef: sourceChatId
                    )
                )
            }
            if actionMenuSourceChatId == sourceChatId {
                records.append(
                    KeyboardSurfaceRecord(
                        surfaceId: .notificationActionMenu(sourceChatId),
                        surfaceKind: .notificationActionMenu,
                        parentSurfaceId: bubbleId,
                        lifecycleToken: "notification-action-menu:\(sourceChatId)",
                        visible: true,
                        active: true,
                        focusedHint: true,
                        commandFamilies: [.menuNavigation],
                        domainRef: sourceChatId
                    )
                )
            }
        }
        let shortcutMap = Dictionary(
            uniqueKeysWithValues: visibleNotificationSourceChatIds
                .prefix(10)
                .enumerated()
                .map { index, sourceChatId in
                    (index, KeyboardSurfaceId.notificationBubble(sourceChatId))
                }
        )
        return (records, shortcutMap)
    }

    static func chatScene(
        visibleNotificationSourceChatIds: [String],
        visibleChatSelectorSessionKeys: [String] = [],
        mentionPickerVisible: Bool,
        mentionPickerHasCompletion: Bool = false,
        composerFocused: Bool,
        notificationFocusedSourceChatId: String? = nil,
        notificationReplySourceChatIds: [String] = [],
        notificationReplyFocusedSourceChatId: String?,
        actionMenuSourceChatId: String?
    ) -> KeyboardOwnershipStore {
        let scene = chatSceneRecords(
            visibleNotificationSourceChatIds: visibleNotificationSourceChatIds,
            mentionPickerVisible: mentionPickerVisible,
            mentionPickerHasCompletion: mentionPickerHasCompletion,
            composerFocused: composerFocused,
            notificationFocusedSourceChatId: notificationFocusedSourceChatId,
            notificationReplySourceChatIds: notificationReplySourceChatIds,
            notificationReplyFocusedSourceChatId: notificationReplyFocusedSourceChatId,
            actionMenuSourceChatId: actionMenuSourceChatId
        )
        var store = KeyboardOwnershipStore()
        let chatSelectorRecords = StreamSelectorShortcutMap.records(selectableSessionKeys: visibleChatSelectorSessionKeys)
        store.synchronize(
            records: scene.records + chatSelectorRecords,
            notificationShortcutMap: scene.notificationShortcutMap,
            chatSelectorShortcutMap: StreamSelectorShortcutMap.shortcutMap(
                selectableSessionKeys: visibleChatSelectorSessionKeys
            )
        )
        return store
    }
}
