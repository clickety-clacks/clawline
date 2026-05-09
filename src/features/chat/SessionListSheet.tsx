import { useMemo, useState } from "react";
import { Plus, Search } from "lucide-react";
import type {
  StreamDotState,
  StreamRecord
} from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { getSessionProvisioningState } from "../streams/provisioning";

export function parseStreamName(sessionKey: string) {
  const tail = sessionKey.split(":").filter(Boolean).at(-1) ?? sessionKey;
  const normalized = tail.replaceAll("_", " ").trim();

  if (normalized.length === 0) {
    return sessionKey;
  }

  return normalized
    .split(/\s+/)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

export function resolveStreamDisplayName(stream: Pick<StreamRecord, "displayName" | "sessionKey">) {
  const displayName = stream.displayName?.trim();
  return displayName && displayName.length > 0
    ? displayName
    : parseStreamName(stream.sessionKey);
}

export function SessionListSheet({
  activeSessionKey,
  isOpen,
  onClose,
  onOpenStreamManager,
  onSelectSession,
  provisionedSessionKeys,
  streamDotStateBySessionKey,
  unreadBySessionKey,
  streams,
  transportPhase
}: {
  activeSessionKey?: string;
  isOpen: boolean;
  onClose: () => void;
  onOpenStreamManager: () => void;
  onSelectSession: (sessionKey: string) => void;
  provisionedSessionKeys: string[];
  streamDotStateBySessionKey: Record<string, StreamDotState>;
  unreadBySessionKey: Record<string, number>;
  streams: StreamRecord[];
  transportPhase: TransportPhase;
}) {
  const [filterQuery, setFilterQuery] = useState("");
  const filteredStreams = useMemo(() => {
    const normalizedQuery = filterQuery.trim().toLowerCase();
    if (normalizedQuery.length === 0) {
      return streams;
    }

    return streams.filter((stream) =>
      resolveStreamDisplayName(stream).toLowerCase().includes(normalizedQuery)
    );
  }, [filterQuery, streams]);

  if (!isOpen) {
    return null;
  }

  return (
    <div className="session-popover-backdrop" onClick={onClose}>
      <aside
        aria-label="Sessions"
        className="session-popover"
        data-testid="session-popover"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="session-popover-list" data-testid="session-popover-list">
          {filteredStreams.length === 0 ? (
            <p className="stream-empty">
              {streams.length === 0
                ? "Waiting for provisioned sessions..."
                : "No chats match the filter."}
            </p>
          ) : (
            filteredStreams.map((stream) => {
              const displayName = resolveStreamDisplayName(stream);
              const isActive = stream.sessionKey === activeSessionKey;
              const dotState =
                streamDotStateBySessionKey[stream.sessionKey] ?? "inactive";
              const unreadCount = Math.max(0, unreadBySessionKey[stream.sessionKey] ?? 0);
              const provisioningState = getSessionProvisioningState({
                hasStream: true,
                provisionedSessionKeys,
                sessionKey: stream.sessionKey,
                transportPhase
              });

              return (
                <button
                  aria-current={isActive ? "page" : undefined}
                  className={isActive ? "session-sheet-card active" : "session-sheet-card"}
                  key={stream.sessionKey}
                  onClick={() => {
                    onSelectSession(stream.sessionKey);
                    onClose();
                  }}
                  onPointerDown={(event) => {
                    // Keep the composer focused so selecting a chat doesn't dismiss
                    // the software keyboard before the route switch completes.
                    event.preventDefault();
                  }}
                  type="button"
                >
                  <span className="session-sheet-card-row">
                    <span className="session-sheet-card-leading">
                      <span
                        aria-hidden="true"
                        className={
                          isActive
                            ? "session-sheet-card-indicator session-sheet-card-indicator--active"
                            : unreadCount > 0 || dotState === "unread"
                              ? "session-sheet-card-indicator session-sheet-card-indicator--unread"
                              : dotState === "userTail"
                                ? "session-sheet-card-indicator session-sheet-card-indicator--user-tail"
                                : "session-sheet-card-indicator"
                        }
                      />
                      <span className="session-sheet-card-title">{displayName}</span>
                      {unreadCount > 0 ? (
                        <span aria-label={`${unreadCount} unread messages`} className="session-sheet-card-unread-count">
                          {unreadCount}
                        </span>
                      ) : null}
                    </span>
                  </span>
                </button>
              );
            })
          )}
        </div>
        <div className="session-popover-footer">
          <label className="session-popover-filter">
            <span aria-hidden="true" className="session-popover-filter-icon">
              <Search size={16} strokeWidth={2.15} />
            </span>
            <input
              aria-label="Filter chats"
              onChange={(event) => setFilterQuery(event.target.value)}
              placeholder="Filter…"
              type="text"
              value={filterQuery}
            />
          </label>
          <button
            aria-label="Add stream"
            className="button-icon session-popover-action-button"
            onClick={() => {
              onClose();
              onOpenStreamManager();
            }}
            title="Add stream"
            type="button"
          >
            <Plus size={18} strokeWidth={2} />
          </button>
        </div>
      </aside>
    </div>
  );
}
