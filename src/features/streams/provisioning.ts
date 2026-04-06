import type { TransportPhase } from "../../runtime/transport/transportMachine";

export type SessionProvisioningState =
  | "none"
  | "ready"
  | "waiting"
  | "unavailable";

export function getSessionProvisioningState(input: {
  hasStream: boolean;
  provisionedSessionKeys: string[];
  sessionKey?: string;
  transportPhase: TransportPhase;
}): SessionProvisioningState {
  if (!input.sessionKey || !input.hasStream) {
    return "none";
  }

  if (input.provisionedSessionKeys.includes(input.sessionKey)) {
    return "ready";
  }

  return input.transportPhase === "live" ? "unavailable" : "waiting";
}
