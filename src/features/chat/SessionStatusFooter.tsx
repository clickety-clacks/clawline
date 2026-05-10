import type {
  SessionControlAction,
  SessionStatusCapabilities,
  SessionStatusCapability,
  SessionStatusPayload
} from "../../protocol/stream-api";

interface FooterOption {
  enabled?: boolean | null;
  isCurrent: boolean;
  title: string;
  value?: string | null;
}

interface FooterItem {
  action?: SessionControlAction;
  options: FooterOption[];
  text: string;
  unsupportedReason?: string | null;
}

export const SESSION_STATUS_FOOTER_HEIGHT = 60;

export function SessionStatusFooter({
  onSelect,
  opacity,
  sessionStatus
}: {
  onSelect?: (
    sessionKey: string,
    action: SessionControlAction,
    value?: string | null,
    enabled?: boolean | null
  ) => void;
  opacity: number;
  sessionStatus?: SessionStatusPayload | null;
}) {
  const items = footerItems(sessionStatus);
  if (!sessionStatus || items.length === 0) {
    return null;
  }

  return (
    <div
      aria-label={items.map((item) => item.text).join(" · ")}
      className="session-status-footer"
      data-testid="session-status-footer"
      style={{ opacity }}
    >
      {items.map((item) => (
        <label className="session-status-footer-control" key={item.text}>
          <span className="sr-only">{item.text}</span>
          <select
            aria-label={item.text}
            disabled={!item.action || item.options.length === 0}
            onChange={(event) => {
              if (!item.action) {
                return;
              }
              const option = item.options[Number.parseInt(event.currentTarget.value, 10)];
              if (!option) {
                return;
              }
              onSelect?.(sessionStatus.sessionKey, item.action, option.value, option.enabled);
            }}
            title={!item.action ? item.unsupportedReason ?? undefined : undefined}
            value={Math.max(0, item.options.findIndex((option) => option.isCurrent))}
          >
            {item.options.map((option, index) => (
              <option key={`${option.title}:${option.value ?? option.enabled ?? index}`} value={index}>
                {option.isCurrent ? "\u2713 " : ""}
                {option.title}
              </option>
            ))}
          </select>
        </label>
      ))}
    </div>
  );
}

export function footerItems(status?: SessionStatusPayload | null): FooterItem[] {
  if (!status) {
    return [];
  }

  const display = status.display ?? {};
  const capabilities = status.capabilities ?? {};
  const modelCapability = capability(
    capabilities.setModel,
    capabilities.canChangeModel === true
  );
  const thinkingValue = normalized(display.thinkingLevel);
  const reasoningValue = normalized(display.reasoningLevel);
  const levelControl = levelControlAction({
    capabilities,
    hasReasoningValue: reasoningValue != null,
    hasThinkingValue: thinkingValue != null
  });
  const fastControl = fastModeControlAction(capabilities);

  return [
    {
      action: modelCapability.isSupported ? "set_model" : undefined,
      options: modelOptions(status),
      text: normalized(display.model) ?? "Unknown model",
      unsupportedReason: modelCapability.reason ?? "model_catalog_control_not_available"
    },
    {
      action: levelControl.action,
      options: levelOptions(thinkingValue ?? reasoningValue, levelControl.action),
      text: `Thinking ${thinkingValue ?? reasoningValue ?? "Unknown"}`,
      unsupportedReason: levelControl.reason
    },
    {
      action: fastControl.action,
      options: fastModeOptions(display.fastMode, fastControl.action),
      text: fastModeText(display.fastMode),
      unsupportedReason: fastControl.reason
    }
  ];
}

function capability(
  capabilityValue: SessionStatusCapability | null | undefined,
  legacySupported: boolean
) {
  if (capabilityValue) {
    return {
      isSupported: capabilityValue.supported,
      reason: capabilityValue.reason
    };
  }
  return {
    isSupported: legacySupported,
    reason: null
  };
}

function modelOptions(status: SessionStatusPayload): FooterOption[] {
  const current = normalized(status.display?.model);
  if (status.modelCatalog?.available === true) {
    return (status.modelCatalog.models ?? []).map((model) => {
      const title = normalized(model.alias) ?? normalized(model.name) ?? normalized(model.ref) ?? model.ref;
      return {
        title,
        value: model.ref,
        isCurrent:
          current === normalized(model.id) ||
          current === normalized(model.ref) ||
          current === title
      };
    });
  }

  const fallbackModels = [
    current,
    ...(status.display?.fallbackModels ?? []).map((model) => normalized(model))
  ].filter((model): model is string => Boolean(model));
  return [...new Set(fallbackModels)].map((model) => ({
    title: model,
    value: model,
    isCurrent: model === current
  }));
}

function levelControlAction({
  capabilities,
  hasReasoningValue,
  hasThinkingValue
}: {
  capabilities: SessionStatusCapabilities;
  hasReasoningValue: boolean;
  hasThinkingValue: boolean;
}) {
  const thinkingCapability = capability(capabilities.setThinking, false);
  const reasoningCapability = capability(
    capabilities.setReasoning,
    capabilities.canChangeReasoning === true
  );
  if (hasThinkingValue && thinkingCapability.isSupported) {
    return { action: "set_thinking" as const, reason: null };
  }
  if (hasReasoningValue && reasoningCapability.isSupported) {
    return { action: "set_reasoning" as const, reason: null };
  }
  if (thinkingCapability.isSupported) {
    return { action: "set_thinking" as const, reason: null };
  }
  if (reasoningCapability.isSupported) {
    return { action: "set_reasoning" as const, reason: null };
  }
  return {
    action: undefined,
    reason: thinkingCapability.reason ?? reasoningCapability.reason
  };
}

function levelOptions(current: string | null, action?: SessionControlAction): FooterOption[] {
  const levels = action === "set_reasoning"
    ? ["off", "on", "stream"]
    : action === "set_thinking"
      ? ["off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max"]
      : [];
  return levels.map((level) => ({
    title: level,
    value: level,
    isCurrent: level === current
  }));
}

function fastModeControlAction(capabilities: SessionStatusCapabilities) {
  const fastCapability = capability(
    capabilities.setFastMode,
    capabilities.canChangeFastMode === true
  );
  const modeCapability = capability(capabilities.setMode, false);
  if (fastCapability.isSupported) {
    return { action: "set_fast_mode" as const, reason: null };
  }
  if (modeCapability.isSupported) {
    return { action: "set_mode" as const, reason: null };
  }
  return {
    action: undefined,
    reason: fastCapability.reason ?? modeCapability.reason
  };
}

function fastModeOptions(current: boolean | null | undefined, action?: SessionControlAction) {
  if (action === "set_mode") {
    return [
      { title: "On", value: "fast", isCurrent: current === true },
      { title: "Off", value: "normal", isCurrent: current === false }
    ];
  }
  if (action !== "set_fast_mode") {
    return current == null
      ? []
      : [
          { title: current ? "On" : "Off", enabled: current, isCurrent: true }
        ];
  }
  return [
    { title: "On", enabled: true, isCurrent: current === true },
    { title: "Off", enabled: false, isCurrent: current === false }
  ];
}

function fastModeText(fastMode: boolean | null | undefined) {
  if (fastMode == null) {
    return "Fast Unknown";
  }
  return fastMode ? "Fast on" : "Fast off";
}

function normalized(value?: string | null) {
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : null;
}
