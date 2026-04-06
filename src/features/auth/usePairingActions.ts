import { useEffect, useEffectEvent, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  parsePairResultPayload,
  serializePairRequest
} from "../../protocol/chat-wire";
import {
  getOrCreateDeviceId,
  useAuthSessionStore
} from "../../runtime/auth/authSessionStore";
import { normalizePairingWebSocketUrl } from "./pairingUrl";

type PairingStage = "idle" | "submitting" | "awaiting-approval" | "error";
const PAIRING_RETRY_INTERVAL_MS = 3_000;

export function usePairingActions() {
  const navigate = useNavigate();
  const { state, store } = useAuthSessionStore();
  const [stage, setStage] = useState<PairingStage>("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [approvalReason, setApprovalReason] = useState<string | undefined>();
  const [pendingRetryVersion, setPendingRetryVersion] = useState(0);
  const pairingAttemptInFlightRef = useRef(false);

  const normalizedServerUrl = useMemo(
    () => normalizePairingWebSocketUrl(state.draft.serverUrl),
    [state.draft.serverUrl]
  );

  const runPairingAttempt = useEffectEvent(
    async ({ keepAwaitingState }: { keepAwaitingState: boolean }) => {
      if (pairingAttemptInFlightRef.current) {
        return;
      }

      if (!normalizedServerUrl) {
        setStage("error");
        setErrorMessage("Enter a valid provider address.");
        setPendingRetryVersion(0);
        return;
      }

      const claimedName = state.draft.claimedName.trim();
      if (claimedName.length === 0) {
        setStage("error");
        setErrorMessage("Enter a name for this browser.");
        setPendingRetryVersion(0);
        return;
      }

      pairingAttemptInFlightRef.current = true;

      if (!keepAwaitingState) {
        setStage("submitting");
      }
      setErrorMessage(null);
      setApprovalReason(undefined);

      try {
        const deviceId = getOrCreateDeviceId(state.session?.deviceId);
        const result = await requestPairing({
          claimedName: claimedName.slice(0, 64),
          deviceId,
          serverUrl: normalizedServerUrl
        });

        if (result.status === "success") {
          setPendingRetryVersion(0);
          store.storePairingSession({
            claimedName,
            deviceId,
            serverUrl: normalizedServerUrl,
            token: result.token,
            userId: result.userId
          });
          setStage("idle");
          navigate("/chat", { replace: true });
          return;
        }

        if (result.status === "awaiting-approval") {
          setStage("awaiting-approval");
          setApprovalReason(result.reason);
          setPendingRetryVersion((version) => version + 1);
          return;
        }

        if (keepAwaitingState) {
          setStage("awaiting-approval");
          setErrorMessage(result.reason ?? "Could not reach the provider.");
          setPendingRetryVersion((version) => version + 1);
          return;
        }

        setStage("error");
        setErrorMessage(result.reason ?? "Pairing failed.");
        setPendingRetryVersion(0);
      } finally {
        pairingAttemptInFlightRef.current = false;
      }
    }
  );

  function submitPairing() {
    void runPairingAttempt({ keepAwaitingState: false });
  }

  function retryPendingPairing() {
    void runPairingAttempt({ keepAwaitingState: true });
  }

  useEffect(() => {
    if (stage !== "awaiting-approval" || pendingRetryVersion === 0) {
      return undefined;
    }

    const retryTimer = window.setTimeout(() => {
      retryPendingPairing();
    }, PAIRING_RETRY_INTERVAL_MS);

    return () => {
      window.clearTimeout(retryTimer);
    };
  }, [pendingRetryVersion, stage]);

  function resetPairing() {
    setPendingRetryVersion(0);
    setStage("idle");
    setErrorMessage(null);
    setApprovalReason(undefined);
  }

  return {
    approvalReason,
    errorMessage,
    normalizedServerUrl,
    resetPairing,
    retryPendingPairing,
    stage,
    submitPairing
  };
}

async function requestPairing({
  claimedName,
  deviceId,
  serverUrl
}: {
  claimedName: string;
  deviceId: string;
  serverUrl: string;
}) {
  const socket = new WebSocket(serverUrl);

  return new Promise<
    | { status: "success"; token: string; userId: string }
    | { status: "awaiting-approval"; reason?: string }
    | { status: "error"; reason?: string }
  >((resolve) => {
    const cleanup = () => {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
    };

    socket.onopen = () => {
      socket.send(
        serializePairRequest({
          type: "pair_request",
          protocolVersion: 1,
          deviceId,
          claimedName,
          deviceInfo: {
            platform: "Web",
            model: navigator.platform || "Browser"
          }
        })
      );
    };

    socket.onmessage = (event) => {
      const payloadType = JSON.parse(event.data).type as string | undefined;

      if (payloadType === "error") {
        const payload = JSON.parse(event.data) as {
          message?: string;
          code?: string;
        };
        cleanup();
        resolve({
          status: "error",
          reason: payload.message ?? payload.code ?? "Pairing failed."
        });
        return;
      }

      const payload = parsePairResultPayload(event.data);

      if (payload.success && payload.token && payload.userId) {
        cleanup();
        resolve({
          status: "success",
          token: payload.token,
          userId: payload.userId
        });
        return;
      }

      if (
        payload.reason === "pair_pending" ||
        payload.reason === "device_not_approved"
      ) {
        cleanup();
        resolve({
          status: "awaiting-approval",
          reason: payload.reason
        });
        return;
      }

      cleanup();
      resolve({
        status: "error",
        reason: payload.reason
      });
    };

    socket.onerror = () => {
      cleanup();
      resolve({
        status: "error",
        reason: "Could not reach the provider."
      });
    };

    socket.onclose = () => {
      resolve({
        status: "error",
        reason: "Provider closed the pairing socket."
      });
    };
  });
}
