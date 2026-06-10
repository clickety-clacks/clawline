import { describe, expect, it } from "vitest";
import {
  createKeyboardOwnershipStore,
  keyboardIntentFromEvent,
  routeKeyboardCommand,
  type KeyboardSurfaceRecord
} from "./keyboardCommandRouter";

describe("keyboardCommandRouter", () => {
  it("routes popup lifecycle, notification globals, reply focus, composer focus, and action menus through one store", () => {
    const store = createKeyboardOwnershipStore([
      {
        records: [
          composer(true),
          {
            surfaceId: "mention-picker",
            surfaceKind: "mention-picker",
            parentSurfaceId: "composer",
            visible: true,
            active: true,
            focusedHint: true,
            commandFamilies: ["pickerNavigation", "pickerAccept"]
          },
          notificationBubble("n0"),
          notificationReply("n0", true),
          notificationBubble("n1", true),
          actionMenu("n1")
        ],
        notificationShortcutMap: {
          0: "notification-bubble:n0",
          1: "notification-bubble:n1"
        }
      }
    ]);

    expect(routeKeyboardCommand("pickerNavigateDown", store).ownerSurfaceId).toBe(
      "mention-picker"
    );
    expect(routeKeyboardCommand("menuActivate", store).ownerSurfaceId).toBe(
      "notification-action-menu:n1"
    );
    expect(routeKeyboardCommand("notificationAssignedReply", store, 1).ownerSurfaceId)
      .toBe("notification-bubble:n1");
    expect(routeKeyboardCommand("notificationScrollForward", store).ownerSurfaceId)
      .toBe("notification-bubble:n1");
    expect(routeKeyboardCommand("textSubmit", store).ownerSurfaceId).toBe(
      "mention-picker"
    );
    expect(routeKeyboardCommand("textModifiedNewline", store).ownerSurfaceId).toBe(
      "notification-reply:n0"
    );
  });

  it("revokes transient ownership when popup and reply records disappear", () => {
    const openStore = createKeyboardOwnershipStore([
      {
        records: [composer(true), notificationBubble("n0"), notificationReply("n0", true)],
        notificationShortcutMap: { 0: "notification-bubble:n0" }
      }
    ]);
    const closedStore = createKeyboardOwnershipStore([
      {
        records: [composer(true), notificationBubble("n0")],
        notificationShortcutMap: { 0: "notification-bubble:n0" }
      }
    ]);

    expect(routeKeyboardCommand("textSubmit", openStore).ownerSurfaceId).toBe(
      "notification-reply:n0"
    );
    expect(routeKeyboardCommand("textSubmit", closedStore).ownerSurfaceId).toBe(
      "composer"
    );
    expect(routeKeyboardCommand("notificationScrollForward", closedStore).ownerSurfaceId)
      .toBe("notification-bubble:n0");
  });

  it("routes notification scroll to the router-owned focused notification", () => {
    const store = createKeyboardOwnershipStore([
      {
        records: [
          composer(true),
          notificationBubble("n0"),
          notificationBubble("n1", true)
        ],
        notificationShortcutMap: {
          0: "notification-bubble:n0",
          1: "notification-bubble:n1"
        }
      }
    ]);

    expect(routeKeyboardCommand("notificationScrollForward", store).ownerSurfaceId)
      .toBe("notification-bubble:n1");
  });

  it("normalizes web physical shortcuts into the shared intent vocabulary", () => {
    expect(keyboardIntentFromEvent(keyEvent({ key: "j", metaKey: true }))).toEqual({
      intent: "notificationScrollForward"
    });
    expect(
      keyboardIntentFromEvent(keyEvent({ key: "3", metaKey: true, altKey: true }))
    ).toEqual({ intent: "notificationAssignedReply", index: 3 });
    expect(
      keyboardIntentFromEvent(keyEvent({ key: "#", metaKey: true, shiftKey: true }))
    ).toBeNull();
    expect(
      keyboardIntentFromEvent(keyEvent({ key: "3", metaKey: true, shiftKey: true }))
    ).toBeNull();
    expect(
      keyboardIntentFromEvent(
        keyEvent({ key: "#", metaKey: true, shiftKey: true, altKey: true })
      )
    ).toEqual({ intent: "notificationAssignedDismiss", index: 3 });
    expect(keyboardIntentFromEvent(keyEvent({ key: "Enter", ctrlKey: true }))).toEqual({
      intent: "textModifiedNewline"
    });
    expect(keyboardIntentFromEvent(keyEvent({ key: "\\", metaKey: true }))).toEqual({
      intent: "notificationToggleDock"
    });
    expect(keyboardIntentFromEvent(keyEvent({ key: ";", ctrlKey: true }))).toEqual({
      intent: "openStreamPopup"
    });
    expect(keyboardIntentFromEvent(keyEvent({ key: "0", ctrlKey: true }))).toBeNull();
    expect(keyboardIntentFromEvent(keyEvent({ key: "0", metaKey: true, ctrlKey: true }))).toBeNull();
    expect(keyboardIntentFromEvent(keyEvent({ key: ";", metaKey: true, ctrlKey: true }))).toBeNull();
  });

  it("requires picker accept capability and registered transcript fallback", () => {
    const emptyPickerStore = createKeyboardOwnershipStore([
      {
        records: [
          composer(true),
          {
            surfaceId: "mention-picker",
            surfaceKind: "mention-picker",
            parentSurfaceId: "composer",
            visible: true,
            active: true,
            focusedHint: true,
            commandFamilies: ["pickerNavigation"]
          }
        ]
      }
    ]);
    expect(routeKeyboardCommand("pickerNavigateDown", emptyPickerStore).ownerSurfaceId)
      .toBe("mention-picker");
    expect(routeKeyboardCommand("pickerAccept", emptyPickerStore).outcome)
      .toBe("fallthrough");
    expect(routeKeyboardCommand("focusPromptInput", {
      notificationShortcutMap: {},
      routeEpoch: 0,
      surfaceRegistry: {}
    }).outcome).toBe("fallthrough");
  });
});

function composer(focusedHint: boolean): KeyboardSurfaceRecord {
  return {
    surfaceId: "composer",
    surfaceKind: "composer",
    visible: true,
    active: true,
    focusedHint,
    commandFamilies: ["textEditing"]
  };
}

function notificationBubble(
  sourceChatId: string,
  focusedHint = false
): KeyboardSurfaceRecord {
  return {
    surfaceId: `notification-bubble:${sourceChatId}`,
    surfaceKind: "notification-bubble",
    visible: true,
    active: true,
    focusedHint,
    commandFamilies: ["notificationAssigned", "notificationStack", "notificationScroll"],
    domainRef: sourceChatId
  };
}

function notificationReply(
  sourceChatId: string,
  focusedHint: boolean
): KeyboardSurfaceRecord {
  return {
    surfaceId: `notification-reply:${sourceChatId}`,
    surfaceKind: "notification-reply",
    parentSurfaceId: `notification-bubble:${sourceChatId}`,
    visible: true,
    active: true,
    focusedHint,
    commandFamilies: ["textEditing"],
    domainRef: sourceChatId
  };
}

function actionMenu(sourceChatId: string): KeyboardSurfaceRecord {
  return {
    surfaceId: `notification-action-menu:${sourceChatId}`,
    surfaceKind: "notification-action-menu",
    parentSurfaceId: `notification-bubble:${sourceChatId}`,
    visible: true,
    active: true,
    focusedHint: true,
    commandFamilies: ["menuNavigation"],
    domainRef: sourceChatId
  };
}

function keyEvent(input: {
  key: string;
  altKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  shiftKey?: boolean;
}) {
  return {
    altKey: false,
    ctrlKey: false,
    metaKey: false,
    shiftKey: false,
    ...input
  };
}
