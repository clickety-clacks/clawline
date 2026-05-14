export function AwaitingApprovalScreen({
  errorMessage,
  onRetry,
  onReset,
  reason
}: {
  errorMessage?: string | null;
  onRetry: () => void;
  onReset: () => void;
  reason?: string;
}) {
  return (
    <section className="pairing-shell">
      <div className="pairing-card">
        <p className="eyebrow">Awaiting Approval</p>
        <h1>Clawline is waiting on an approved device.</h1>
        <p className="pairing-copy">
          {reason === "device_not_approved"
            ? "This browser is not approved yet. Retry after an admin approves it."
            : "The provider accepted the request but has not approved this browser yet."}
        </p>
        <p className="pairing-copy">
          {errorMessage
            ? "The pairing socket is no longer waiting. Retry to resubmit after checking approval."
            : "Clawline is keeping this pairing request open while you wait."}
        </p>
        {errorMessage ? (
          <p className="field-error" role="alert">
            {errorMessage}
          </p>
        ) : null}
        <div className="pairing-actions">
          {errorMessage ? (
            <button className="button-primary" onClick={onRetry} type="button">
              Retry pairing
            </button>
          ) : null}
          <button className="button-secondary" onClick={onReset} type="button">
            Edit details
          </button>
        </div>
      </div>
    </section>
  );
}
