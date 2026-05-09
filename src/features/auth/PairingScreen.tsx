import { Navigate } from "react-router-dom";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { AwaitingApprovalScreen } from "./AwaitingApprovalScreen";
import { usePairingActions } from "./usePairingActions";

export function PairingScreen() {
  const { state, store } = useAuthSessionStore();
  const pairing = usePairingActions();

  if (state.session?.token) {
    return <Navigate to="/chat" replace />;
  }

  if (pairing.stage === "awaiting-approval") {
    return (
      <AwaitingApprovalScreen
        errorMessage={pairing.errorMessage}
        onReset={pairing.resetPairing}
        onRetry={pairing.retryPendingPairing}
        reason={pairing.approvalReason}
      />
    );
  }

  return (
    <section className="pairing-shell">
      <div className="pairing-card">
        <p className="eyebrow">Phase 1 Browser Client</p>
        <h1>Pair this browser and move straight into chat.</h1>
        <p className="pairing-copy">
          The current web spec still leaves topology and auth storage open. This
          implementation uses the existing provider WebSocket contract so the Phase 1
          client can be exercised now.
        </p>

        <label className="field">
          <span>Name</span>
          <input
            autoComplete="name"
            onChange={(event) => {
              store.updateDraft({ claimedName: event.target.value });
            }}
            placeholder="Desk browser"
            type="text"
            value={state.draft.claimedName}
          />
        </label>

        <label className="field">
          <span>Provider address</span>
          <input
            autoCapitalize="off"
            autoCorrect="off"
            onChange={(event) => {
              store.updateDraft({ serverUrl: event.target.value });
            }}
            placeholder="ws://provider.local:18800"
            type="text"
            value={state.draft.serverUrl}
          />
        </label>

        {pairing.errorMessage ? (
          <p className="field-error" role="alert">
            {pairing.errorMessage}
          </p>
        ) : null}

        <div className="pairing-actions">
          <button
            className="button-primary"
            disabled={pairing.stage === "submitting"}
            onClick={() => {
              void pairing.submitPairing();
            }}
            type="button"
          >
            {pairing.stage === "submitting" ? "Pairing..." : "Pair browser"}
          </button>
        </div>

        <p className="pairing-hint">
          Normalized endpoint: {pairing.normalizedServerUrl ?? "Enter a provider URL"}
        </p>
      </div>
    </section>
  );
}
