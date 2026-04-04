import type { DeliveryState, PendingMessageRecord } from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import type { SessionProvisioningState } from "../streams/provisioning";

export type ChatSendConnectionState =
  | "idle"
  | "live"
  | "reconnecting"
  | "disconnected";

export type FailedMessageRetryAction = "none" | "reconnect" | "resend";

export interface ComposerSendState {
  canAttach: boolean;
  canSend: boolean;
  connectionState: ChatSendConnectionState;
  isSendButtonEnabled: boolean;
  placeholder: string;
  sendAriaLabel: string;
  sendAction: "none" | "reconnect" | "send";
}

export interface FailedMessageRetryState {
  action: FailedMessageRetryAction;
  canRetry: boolean;
  shouldShowRetry: boolean;
}

export function projectComposerSendState(input: {
  activeStreamDisplayName?: string;
  draft: string;
  isSubmitting: boolean;
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
  stagedAttachmentCount: number;
  transportPhase: TransportPhase;
}): ComposerSendState {
  const connectionState = projectChatSendConnectionState({
    provisioningState: input.provisioningState,
    sessionKey: input.sessionKey,
    transportPhase: input.transportPhase
  });
  const hasContent =
    input.draft.trim().length > 0 || input.stagedAttachmentCount > 0;
  const canSend =
    Boolean(input.sessionKey) &&
    input.transportPhase === "live" &&
    input.provisioningState === "ready" &&
    !input.isSubmitting &&
    hasContent;
  const sendAction = projectComposerSendAction({
    canSend,
    connectionState,
    isSubmitting: input.isSubmitting
  });

  return {
    canAttach: Boolean(input.sessionKey) && !input.isSubmitting,
    canSend,
    connectionState,
    isSendButtonEnabled: sendAction !== "none",
    placeholder: projectComposerPlaceholder({
      activeStreamDisplayName: input.activeStreamDisplayName,
      provisioningState: input.provisioningState,
      sessionKey: input.sessionKey,
      transportPhase: input.transportPhase
    }),
    sendAriaLabel: projectComposerSendAriaLabel({
      connectionState,
      isSubmitting: input.isSubmitting,
      sendAction
    }),
    sendAction
  };
}

export function projectFailedMessageRetryState(input: {
  delivery: DeliveryState;
  pendingMessage?: PendingMessageRecord;
  transportPhase: TransportPhase;
}): FailedMessageRetryState {
  if (input.delivery !== "failed" || !input.pendingMessage) {
    return {
      action: "none",
      canRetry: false,
      shouldShowRetry: false
    };
  }

  return {
    action: input.transportPhase === "live" ? "resend" : "reconnect",
    canRetry: true,
    shouldShowRetry: true
  };
}

function projectChatSendConnectionState(input: {
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
  transportPhase: TransportPhase;
}): ChatSendConnectionState {
  if (!input.sessionKey || input.provisioningState !== "ready") {
    return "idle";
  }

  if (input.transportPhase === "live") {
    return "live";
  }

  if (input.transportPhase === "failed") {
    return "disconnected";
  }

  return "reconnecting";
}

function projectComposerPlaceholder(input: {
  activeStreamDisplayName?: string;
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
  transportPhase: TransportPhase;
}) {
  if (!input.sessionKey) {
    return "Select a session";
  }

  if (input.transportPhase === "live" && input.provisioningState === "ready") {
    return input.activeStreamDisplayName
      ? `${input.activeStreamDisplayName} — ${input.sessionKey}`
      : input.sessionKey;
  }

  if (input.provisioningState === "unavailable") {
    return "This stream is unavailable for sending";
  }

  if (input.provisioningState === "waiting") {
    return "Waiting for provisioning";
  }

  return "Waiting for connection";
}

function projectComposerSendAriaLabel(input: {
  connectionState: ChatSendConnectionState;
  isSubmitting: boolean;
  sendAction: "none" | "reconnect" | "send";
}) {
  if (input.isSubmitting) {
    return "Uploading…";
  }

  if (input.sendAction === "reconnect") {
    return "Disconnected. Tap to reconnect.";
  }

  if (input.connectionState === "reconnecting") {
    return "Reconnecting";
  }

  if (input.connectionState === "disconnected") {
    return "Send unavailable while disconnected";
  }

  return "Send";
}

function projectComposerSendAction(input: {
  canSend: boolean;
  connectionState: ChatSendConnectionState;
  isSubmitting: boolean;
}): "none" | "reconnect" | "send" {
  if (input.isSubmitting) {
    return "none";
  }

  if (input.connectionState === "disconnected") {
    return "reconnect";
  }

  if (input.canSend) {
    return "send";
  }

  return "none";
}
