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
const PAIRING_PENDING_TIMEOUT_MS = 5 * 60_000;

export function usePairingActions() {
  const navigate = useNavigate();
  const { state, store } = useAuthSessionStore();
  const [stage, setStage] = useState<PairingStage>("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [approvalReason, setApprovalReason] = useState<string | undefined>();
  const activePairingAbortRef = useRef<AbortController | null>(null);
  const pairingAttemptIdRef = useRef(0);
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
        return;
      }

      const claimedName = state.draft.claimedName.trim();
      if (claimedName.length === 0) {
        setStage("error");
        setErrorMessage("Enter a name for this browser.");
        return;
      }

      activePairingAbortRef.current?.abort();
      const abortController = new AbortController();
      activePairingAbortRef.current = abortController;
      const attemptId = pairingAttemptIdRef.current + 1;
      pairingAttemptIdRef.current = attemptId;
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
          onPending(reason) {
            if (pairingAttemptIdRef.current !== attemptId) {
              return;
            }

            setStage("awaiting-approval");
            setApprovalReason(reason);
            setErrorMessage(null);
          },
          serverUrl: normalizedServerUrl,
          signal: abortController.signal
        });

        if (pairingAttemptIdRef.current !== attemptId || result.status === "aborted") {
          return;
        }

        if (result.status === "success") {
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
          return;
        }

        if (keepAwaitingState || result.pendingObserved) {
          setStage("awaiting-approval");
          setErrorMessage(result.reason ?? "Pairing connection stalled. Retry to resubmit the request.");
          return;
        }

        setStage("error");
        setErrorMessage(result.reason ?? "Pairing failed.");
      } finally {
        if (pairingAttemptIdRef.current === attemptId) {
          activePairingAbortRef.current = null;
          pairingAttemptInFlightRef.current = false;
        }
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
    return () => {
      activePairingAbortRef.current?.abort();
    };
  }, []);

  function resetPairing() {
    activePairingAbortRef.current?.abort();
    activePairingAbortRef.current = null;
    pairingAttemptInFlightRef.current = false;
    pairingAttemptIdRef.current += 1;
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
  onPending,
  signal,
  serverUrl
}: {
  claimedName: string;
  deviceId: string;
  onPending: (reason?: string) => void;
  signal: AbortSignal;
  serverUrl: string;
}) {
  const socket = new WebSocket(serverUrl);

  return new Promise<
    | { status: "success"; token: string; userId: string }
    | { status: "awaiting-approval"; reason?: string }
    | { status: "error"; reason?: string; pendingObserved?: boolean }
    | { status: "aborted" }
  >((resolve) => {
    let pendingObserved = false;
    let settled = false;
    let pendingTimeoutId: number | null = window.setTimeout(() => {
      settle({
        status: "error",
        pendingObserved,
        reason: "Pairing timed out. Retry after checking approval."
      });
    }, PAIRING_PENDING_TIMEOUT_MS);

    const cleanup = () => {
      if (pendingTimeoutId !== null) {
        window.clearTimeout(pendingTimeoutId);
        pendingTimeoutId = null;
      }
      signal.removeEventListener("abort", handleAbort);
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
    };

    const settle = (
      result:
        | { status: "success"; token: string; userId: string }
        | { status: "awaiting-approval"; reason?: string }
        | { status: "error"; reason?: string; pendingObserved?: boolean }
        | { status: "aborted" }
    ) => {
      if (settled) {
        return;
      }

      settled = true;
      cleanup();
      resolve(result);
    };

    const handleAbort = () => {
      settle({ status: "aborted" });
    };

    signal.addEventListener("abort", handleAbort);

    socket.onopen = () => {
      if (signal.aborted) {
        settle({ status: "aborted" });
        return;
      }

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
        settle({
          status: "error",
          reason: payload.message ?? payload.code ?? "Pairing failed."
        });
        return;
      }

      const payload = parsePairResultPayload(event.data);

      if (payload.success && payload.token && payload.userId) {
        settle({
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
        pendingObserved = true;
        onPending(payload.reason);
        return;
      }

      settle({
        status: "error",
        reason: payload.reason
      });
    };

    socket.onerror = () => {
      settle({
        status: "error",
        pendingObserved,
        reason: "Could not reach the provider."
      });
    };

    socket.onclose = () => {
      settle({
        status: "error",
        pendingObserved,
        reason: "Provider closed the pairing socket."
      });
    };

    if (signal.aborted) {
      settle({ status: "aborted" });
    }
  });
}
