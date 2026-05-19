import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useState,
  type ReactNode
} from "react";

export type KeyboardCommandIntent =
  | "focusPromptInput"
  | "openStreamPopup"
  | "notificationAssignedOpen"
  | "notificationAssignedReply"
  | "notificationAssignedDismiss"
  | "notificationDismissAll"
  | "notificationToggleDock"
  | "notificationScrollForward"
  | "notificationScrollBackward"
  | "menuNavigateUp"
  | "menuNavigateDown"
  | "menuActivate"
  | "menuCancel"
  | "pickerNavigateUp"
  | "pickerNavigateDown"
  | "pickerAccept"
  | "textSubmit"
  | "textModifiedNewline"
  | "textCancel";

export type KeyboardSurfaceKind =
  | "composer"
  | "mention-picker"
  | "notification-bubble"
  | "notification-reply"
  | "notification-action-menu"
  | "transcript";

export type KeyboardCommandFamily =
  | "appNavigation"
  | "notificationAssigned"
  | "notificationStack"
  | "notificationScroll"
  | "menuNavigation"
  | "pickerNavigation"
  | "pickerAccept"
  | "textEditing"
  | "transcriptFallback";

export interface KeyboardSurfaceRecord {
  surfaceId: string;
  surfaceKind: KeyboardSurfaceKind;
  parentSurfaceId?: string;
  visible: boolean;
  active: boolean;
  focusedHint: boolean;
  commandFamilies: KeyboardCommandFamily[];
  domainRef?: string;
}

export interface KeyboardOwnershipStore {
  surfaceRegistry: Record<string, KeyboardSurfaceRecord>;
  notificationShortcutMap: Record<number, string>;
  routeEpoch: number;
}

export interface KeyboardRouteDecision {
  intent: KeyboardCommandIntent;
  ownerSurfaceId: string | null;
  priorityRule: string;
  outcome: "handled" | "fallthrough" | "ignored";
  participatingSurfaces: string[];
  routeEpoch: number;
}

interface KeyboardOwnershipContribution {
  records: KeyboardSurfaceRecord[];
  notificationShortcutMap?: Record<number, string>;
}

interface KeyboardOwnershipContextValue {
  store: KeyboardOwnershipStore;
  setContribution: (ownerId: string, contribution: KeyboardOwnershipContribution) => void;
  clearContribution: (ownerId: string) => void;
}

const KeyboardOwnershipContext = createContext<KeyboardOwnershipContextValue | null>(
  null
);

export function KeyboardOwnershipProvider({ children }: { children: ReactNode }) {
  const [contributions, setContributions] = useState<
    Record<string, KeyboardOwnershipContribution>
  >({});

  const store = useMemo(() => {
    return createKeyboardOwnershipStore(Object.values(contributions));
  }, [contributions]);

  const setContribution = useCallback(
    (ownerId: string, contribution: KeyboardOwnershipContribution) => {
      setContributions((current) => ({
        ...current,
        [ownerId]: contribution
      }));
    },
    []
  );
  const clearContribution = useCallback((ownerId: string) => {
    setContributions((current) => {
      if (!(ownerId in current)) {
        return current;
      }
      const next = { ...current };
      delete next[ownerId];
      return next;
    });
  }, []);

  const value = useMemo<KeyboardOwnershipContextValue>(
    () => ({
      store,
      setContribution,
      clearContribution
    }),
    [clearContribution, setContribution, store]
  );

  return (
    <KeyboardOwnershipContext.Provider value={value}>
      {children}
    </KeyboardOwnershipContext.Provider>
  );
}

export function useKeyboardOwnershipStore() {
  const context = useContext(KeyboardOwnershipContext);
  if (!context) {
    throw new Error("useKeyboardOwnershipStore must be used inside KeyboardOwnershipProvider");
  }
  return context.store;
}

export function useKeyboardOwnershipContribution(
  ownerId: string,
  contribution: KeyboardOwnershipContribution
) {
  const context = useContext(KeyboardOwnershipContext);
  if (!context) {
    throw new Error(
      "useKeyboardOwnershipContribution must be used inside KeyboardOwnershipProvider"
    );
  }
  const contributionKey = JSON.stringify(contribution);

  useLayoutEffect(() => {
    context.setContribution(ownerId, contribution);
    return () => context.clearContribution(ownerId);
  }, [context.clearContribution, context.setContribution, contributionKey, ownerId]);
}

export function createKeyboardOwnershipStore(
  contributions: KeyboardOwnershipContribution[]
): KeyboardOwnershipStore {
  const surfaceRegistry: Record<string, KeyboardSurfaceRecord> = {
    transcript: {
      surfaceId: "transcript",
      surfaceKind: "transcript",
      visible: true,
      active: true,
      focusedHint: false,
      commandFamilies: ["appNavigation", "transcriptFallback"]
    }
  };
  let notificationShortcutMap: Record<number, string> = {};

  for (const contribution of contributions) {
    for (const record of contribution.records) {
      surfaceRegistry[record.surfaceId] = record;
    }
    if (contribution.notificationShortcutMap) {
      notificationShortcutMap = {
        ...notificationShortcutMap,
        ...contribution.notificationShortcutMap
      };
    }
  }

  const reconciledStore = reconcileKeyboardOwnershipStore({
    surfaceRegistry,
    notificationShortcutMap,
    routeEpoch: 0
  });
  return {
    ...reconciledStore,
    routeEpoch: Object.keys(reconciledStore.surfaceRegistry).length
  };
}

export function routeKeyboardCommand(
  intent: KeyboardCommandIntent,
  store: KeyboardOwnershipStore,
  index?: number
): KeyboardRouteDecision {
  const reconciledStore = reconcileKeyboardOwnershipStore(store);
  const participatingSurfaces = activeVisibleSurfaces(reconciledStore)
    .map((record) => record.surfaceId)
    .sort();
  const decision = (
    outcome: KeyboardRouteDecision["outcome"],
    ownerSurfaceId: string | null,
    priorityRule: string
  ): KeyboardRouteDecision => ({
    intent,
    ownerSurfaceId,
    outcome,
    participatingSurfaces,
    priorityRule,
    routeEpoch: reconciledStore.routeEpoch
  });

  if (isMenuIntent(intent)) {
    return firstActiveSurface(reconciledStore, "notification-action-menu", "menuNavigation")
      ? decision(
          "handled",
          firstActiveSurface(reconciledStore, "notification-action-menu", "menuNavigation")
            ?.surfaceId ?? null,
          "PR-01"
        )
      : decision("fallthrough", null, "PR-07");
  }

  if (intent === "pickerNavigateUp" || intent === "pickerNavigateDown") {
    const picker = firstActiveSurface(reconciledStore, "mention-picker", "pickerNavigation");
    return picker
      ? decision("handled", picker.surfaceId, "PR-02")
      : decision("fallthrough", null, "PR-07");
  }

  if (intent === "pickerAccept") {
    const picker = firstActiveSurface(reconciledStore, "mention-picker", "pickerAccept");
    return picker
      ? decision("handled", picker.surfaceId, "PR-02")
      : decision("fallthrough", null, "PR-07");
  }

  if (isNotificationAssignedIntent(intent)) {
    const surfaceId = index === undefined ? undefined : reconciledStore.notificationShortcutMap[index];
    const record = surfaceId ? reconciledStore.surfaceRegistry[surfaceId] : undefined;
    return record?.commandFamilies.includes("notificationAssigned")
      ? decision("handled", record.surfaceId, "PR-03")
      : decision("fallthrough", null, "PR-07");
  }

  if (intent === "notificationDismissAll" || intent === "notificationToggleDock") {
    const notification = activeNotificationSurface(reconciledStore, "notificationStack");
    return notification
      ? decision("handled", notification.surfaceId, "PR-04")
      : decision("fallthrough", null, "PR-07");
  }

  if (intent === "notificationScrollForward" || intent === "notificationScrollBackward") {
    const notification = activeNotificationSurface(reconciledStore, "notificationScroll");
    return notification
      ? decision("handled", notification.surfaceId, "PR-04")
      : decision("fallthrough", null, "PR-07");
  }

  if (intent === "textSubmit" || intent === "textModifiedNewline" || intent === "textCancel") {
    if (intent === "textSubmit") {
      const picker = firstActiveSurface(reconciledStore, "mention-picker", "pickerAccept");
      if (picker) {
        return decision("handled", picker.surfaceId, "PR-02");
      }
    }
    const reply = firstActiveSurface(
      reconciledStore,
      "notification-reply",
      "textEditing",
      true
    );
    if (reply) {
      return decision("handled", reply.surfaceId, "PR-05");
    }
    const composer = firstActiveSurface(reconciledStore, "composer", "textEditing", true);
    if (composer) {
      return decision("handled", composer.surfaceId, "PR-06");
    }
    return decision("fallthrough", null, "PR-07");
  }

  const transcript = firstActiveSurface(reconciledStore, "transcript", "appNavigation");
  return transcript
    ? decision("handled", transcript.surfaceId, "PR-07")
    : decision("fallthrough", null, "PR-07");
}

export function keyboardIntentFromEvent(event: Pick<KeyboardEvent, "key" | "altKey" | "ctrlKey" | "metaKey" | "shiftKey">):
  | { intent: KeyboardCommandIntent; index?: number }
  | null {
  const key = event.key.toLowerCase();
  const command = event.metaKey && !event.ctrlKey;

  if (command && !event.shiftKey && !event.altKey && key === ";") {
    return { intent: "openStreamPopup" };
  }
  if (command && !event.shiftKey && !event.altKey && key === "l") {
    return { intent: "focusPromptInput" };
  }
  if (command && !event.altKey && key === "j") {
    return { intent: "notificationScrollForward" };
  }
  if (command && !event.altKey && key === "k") {
    return { intent: "notificationScrollBackward" };
  }
  if (command && !event.shiftKey && !event.altKey && key === "\\") {
    return { intent: "notificationToggleDock" };
  }
  if (command && !event.shiftKey && !event.altKey && key === "-") {
    return { intent: "notificationDismissAll" };
  }

  const index = hotkeyIndexFromKey(key);
  if (command && index !== null) {
    if (event.shiftKey && event.altKey) {
      return { intent: "notificationAssignedDismiss", index };
    }
    if (event.shiftKey) {
      return { intent: "notificationAssignedReply", index };
    }
    if (!event.altKey) {
      return { intent: "notificationAssignedOpen", index };
    }
  }

  if (!event.metaKey && !event.altKey && (event.shiftKey || event.ctrlKey) && key === "enter") {
    return { intent: "textModifiedNewline" };
  }

  if (!command && !event.altKey && !event.shiftKey) {
    if (key === "arrowup") {
      return { intent: "pickerNavigateUp" };
    }
    if (key === "arrowdown") {
      return { intent: "pickerNavigateDown" };
    }
    if (key === "tab") {
      return { intent: "pickerAccept" };
    }
    if (key === "enter") {
      return { intent: "textSubmit" };
    }
    if (key === "escape") {
      return { intent: "textCancel" };
    }
  }

  return null;
}

function reconcileKeyboardOwnershipStore(
  store: KeyboardOwnershipStore
): KeyboardOwnershipStore {
  const surfaceRegistry = { ...store.surfaceRegistry };
  let removedAny = true;
  while (removedAny) {
    removedAny = false;
    for (const record of Object.values(surfaceRegistry)) {
      if (
        record.parentSurfaceId &&
        !participatesInRouting(surfaceRegistry[record.parentSurfaceId])
      ) {
        delete surfaceRegistry[record.surfaceId];
        removedAny = true;
      }
    }
  }
  const notificationShortcutMap = Object.fromEntries(
    Object.entries(store.notificationShortcutMap).filter(([, surfaceId]) =>
      participatesInRouting(surfaceRegistry[surfaceId])
    )
  );
  return { ...store, surfaceRegistry, notificationShortcutMap };
}

function activeVisibleSurfaces(store: KeyboardOwnershipStore) {
  return Object.values(store.surfaceRegistry).filter(participatesInRouting);
}

function firstActiveSurface(
  store: KeyboardOwnershipStore,
  surfaceKind: KeyboardSurfaceKind,
  commandFamily: KeyboardCommandFamily,
  focusedOnly = false
) {
  return activeVisibleSurfaces(store).find(
    (record) =>
      record.surfaceKind === surfaceKind &&
      record.commandFamilies.includes(commandFamily) &&
      (!focusedOnly || record.focusedHint)
  );
}

function activeNotificationSurface(
  store: KeyboardOwnershipStore,
  commandFamily: KeyboardCommandFamily
) {
  const focused = activeVisibleSurfaces(store).find(
    (record) =>
      record.surfaceKind === "notification-bubble" &&
      record.focusedHint &&
      record.commandFamilies.includes(commandFamily)
  );
  if (focused) {
    return focused;
  }
  for (const index of Object.keys(store.notificationShortcutMap)
    .map(Number)
    .sort((left, right) => left - right)) {
    const record = store.surfaceRegistry[store.notificationShortcutMap[index]];
    if (participatesInRouting(record) && record.commandFamilies.includes(commandFamily)) {
      return record;
    }
  }
  return firstActiveSurface(store, "notification-bubble", commandFamily);
}

function participatesInRouting(record?: KeyboardSurfaceRecord) {
  return Boolean(record?.visible && record.active);
}

function isMenuIntent(intent: KeyboardCommandIntent) {
  return (
    intent === "menuNavigateUp" ||
    intent === "menuNavigateDown" ||
    intent === "menuActivate" ||
    intent === "menuCancel"
  );
}

function isNotificationAssignedIntent(intent: KeyboardCommandIntent) {
  return (
    intent === "notificationAssignedOpen" ||
    intent === "notificationAssignedReply" ||
    intent === "notificationAssignedDismiss"
  );
}

function hotkeyIndexFromKey(key: string) {
  if (/^\d$/.test(key)) {
    return Number(key);
  }
  return ")!@#$%^&*(".indexOf(key);
}
