import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent
} from "react";
import { Plus, Search, Trash2 } from "lucide-react";
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
  filterQuery,
  isOpen,
  onClose,
  onCreateSession,
  onDeleteSession,
  onFilterQueryChange,
  onRenameSession,
  onSelectSession,
  provisionedSessionKeys,
  streamDotStateBySessionKey,
  unreadBySessionKey,
  streams,
  transportPhase
}: {
  activeSessionKey?: string;
  filterQuery: string;
  isOpen: boolean;
  onClose: () => void;
  onCreateSession: () => Promise<StreamRecord | null>;
  onDeleteSession: (sessionKey: string) => Promise<void>;
  onFilterQueryChange: (query: string) => void;
  onRenameSession: (sessionKey: string, displayName: string) => Promise<void>;
  onSelectSession: (sessionKey: string) => void;
  provisionedSessionKeys: string[];
  streamDotStateBySessionKey: Record<string, StreamDotState>;
  unreadBySessionKey: Record<string, number>;
  streams: StreamRecord[];
  transportPhase: TransportPhase;
}) {
  const measureRef = useRef<HTMLSpanElement | null>(null);
  const editInputRef = useRef<HTMLInputElement | null>(null);
  const [editingSessionKey, setEditingSessionKey] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [revealedSessionKey, setRevealedSessionKey] = useState<string | null>(null);
  const [draggingSessionKey, setDraggingSessionKey] = useState<string | null>(null);
  const [dragOffset, setDragOffset] = useState(0);
  const [pendingActionKey, setPendingActionKey] = useState<string | null>(null);
  const [measuredContentWidth, setMeasuredContentWidth] = useState(0);
  const dragStartRef = useRef<{
    sessionKey: string;
    startX: number;
    startY: number;
    lockedAxis: "horizontal" | "vertical" | null;
  } | null>(null);
  const filteredStreams = useMemo(() => {
    const normalizedQuery = filterQuery.trim().toLowerCase();
    if (normalizedQuery.length === 0) {
      return streams;
    }

    return streams.filter((stream) =>
      resolveStreamDisplayName(stream).toLowerCase().includes(normalizedQuery)
    );
  }, [filterQuery, streams]);
  const visibleStreams = useMemo(() => {
    if (
      !editingSessionKey ||
      filteredStreams.some((stream) => stream.sessionKey === editingSessionKey)
    ) {
      return filteredStreams;
    }

    const editingStream = streams.find(
      (stream) => stream.sessionKey === editingSessionKey
    );
    return editingStream ? [...filteredStreams, editingStream] : filteredStreams;
  }, [editingSessionKey, filteredStreams, streams]);
  const displayNameBySessionKey = useMemo(
    () =>
      Object.fromEntries(
        streams.map((stream) => [stream.sessionKey, resolveStreamDisplayName(stream)])
      ),
    [streams]
  );

  useEffect(() => {
    if (!isOpen) {
      return;
    }

    const measure = () => {
      const measureElement = measureRef.current;
      if (!measureElement) {
        return;
      }
      let widest = 0;
      for (const stream of visibleStreams) {
        measureElement.textContent = resolveStreamDisplayName(stream);
        widest = Math.max(widest, measureElement.scrollWidth);
      }
      setMeasuredContentWidth(Math.ceil(widest));
    };

    measure();
    document.fonts?.ready.then(measure).catch(() => {});
  }, [visibleStreams, isOpen]);

  useEffect(() => {
    if (!editingSessionKey) {
      return;
    }
    editInputRef.current?.focus({ preventScroll: true });
    editInputRef.current?.select();
  }, [editingSessionKey]);

  useEffect(() => {
    if (!isOpen) {
      setEditingSessionKey(null);
      setRevealedSessionKey(null);
      setDraggingSessionKey(null);
      setDragOffset(0);
    }
  }, [isOpen]);

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
        style={
          {
            "--session-popover-content-width": `${measuredContentWidth}px`
          } as CSSProperties
        }
      >
        <span aria-hidden="true" className="session-popover-measure" ref={measureRef} />
        <div className="session-popover-list" data-testid="session-popover-list">
          {visibleStreams.length === 0 ? (
            <p className="stream-empty">
              {streams.length === 0
                ? "Waiting for provisioned sessions..."
                : "No chats match the filter."}
            </p>
          ) : (
            visibleStreams.map((stream) => {
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

              const isEditing = editingSessionKey === stream.sessionKey;
              const isRevealed = revealedSessionKey === stream.sessionKey;
              const rowOffset =
                draggingSessionKey === stream.sessionKey
                  ? dragOffset
                  : isRevealed
                    ? -144
                    : 0;

              return (
                <div
                  className={
                    isRevealed
                      ? "session-sheet-row session-sheet-row--revealed"
                      : "session-sheet-row"
                  }
                  key={stream.sessionKey}
                >
                  <div className="session-sheet-row-actions" aria-hidden={!isRevealed}>
                    <button
                      className="session-sheet-row-action session-sheet-row-action--rename"
                      disabled={!isRevealed || pendingActionKey !== null}
                      onClick={() => beginRename(stream.sessionKey, displayName)}
                      tabIndex={isRevealed ? 0 : -1}
                      type="button"
                    >
                      Rename
                    </button>
                    <button
                      aria-label={`Delete ${displayName}`}
                      className="session-sheet-row-action session-sheet-row-action--delete"
                      disabled={!isRevealed || pendingActionKey !== null}
                      onClick={() => void deleteSession(stream.sessionKey)}
                      tabIndex={isRevealed ? 0 : -1}
                      type="button"
                    >
                      <Trash2 size={17} strokeWidth={2} />
                    </button>
                  </div>
                  <div
                    aria-current={isActive ? "page" : undefined}
                    aria-disabled={pendingActionKey === `delete:${stream.sessionKey}` ? true : undefined}
                    className={isActive ? "session-sheet-card active" : "session-sheet-card"}
                    onClick={() => {
                      if (isEditing || pendingActionKey === `delete:${stream.sessionKey}`) {
                        return;
                      }
                      onSelectSession(stream.sessionKey);
                      onClose();
                    }}
                    onKeyDown={(event) => {
                      if (event.key !== "Enter" && event.key !== " ") {
                        return;
                      }
                      if (isEditing || pendingActionKey === `delete:${stream.sessionKey}`) {
                        return;
                      }
                      event.preventDefault();
                      onSelectSession(stream.sessionKey);
                      onClose();
                    }}
                    onPointerCancel={endRowDrag}
                    onPointerDown={(event) => startRowDrag(event, stream.sessionKey)}
                    onPointerMove={moveRowDrag}
                    onPointerUp={endRowDrag}
                    role="button"
                    style={{ transform: `translateX(${rowOffset}px)` }}
                    tabIndex={0}
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
                        {isEditing ? (
                          <input
                            aria-label={`Rename ${displayName}`}
                            className="session-sheet-card-edit"
                            onBlur={() => void commitRename(stream.sessionKey)}
                            onChange={(event) => setRenameValue(event.target.value)}
                            onClick={(event) => event.stopPropagation()}
                            onKeyDown={(event) => {
                              if (event.key === "Enter") {
                                event.preventDefault();
                                void commitRename(stream.sessionKey);
                              }
                              if (event.key === "Escape") {
                                event.preventDefault();
                                cancelRename();
                              }
                            }}
                            ref={editInputRef}
                            value={renameValue}
                          />
                        ) : (
                          <span className="session-sheet-card-title">{displayName}</span>
                        )}
                        {unreadCount > 0 ? (
                          <span aria-label={`${unreadCount} unread messages`} className="session-sheet-card-unread-count">
                            {unreadCount}
                          </span>
                        ) : null}
                      </span>
                    </span>
                  </div>
                </div>
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
              onChange={(event) => onFilterQueryChange(event.target.value)}
              placeholder="Filter…"
              type="text"
              value={filterQuery}
            />
          </label>
          <button
            aria-label="Add chat"
            className="button-icon session-popover-action-button"
            disabled={pendingActionKey !== null}
            onClick={() => void createSession()}
            title="Add chat"
            type="button"
          >
            <Plus size={18} strokeWidth={2} />
          </button>
        </div>
      </aside>
    </div>
  );

  function beginRename(sessionKey: string, displayName: string) {
    setRevealedSessionKey(null);
    setEditingSessionKey(sessionKey);
    setRenameValue(displayName);
  }

  function cancelRename() {
    setEditingSessionKey(null);
    setRenameValue("");
  }

  async function commitRename(sessionKey: string) {
    if (editingSessionKey !== sessionKey || pendingActionKey !== null) {
      return;
    }
    const trimmedName = renameValue.trim();
    const currentName = displayNameBySessionKey[sessionKey] ?? "";
    if (trimmedName.length === 0 || trimmedName === currentName) {
      cancelRename();
      return;
    }

    setPendingActionKey(`rename:${sessionKey}`);
    try {
      await onRenameSession(sessionKey, trimmedName);
      cancelRename();
    } finally {
      setPendingActionKey(null);
    }
  }

  async function createSession() {
    if (pendingActionKey !== null) {
      return;
    }
    setPendingActionKey("create");
    try {
      const stream = await onCreateSession();
      if (!stream) {
        return;
      }
      beginRename(stream.sessionKey, resolveStreamDisplayName(stream));
    } finally {
      setPendingActionKey(null);
    }
  }

  async function deleteSession(sessionKey: string) {
    if (pendingActionKey !== null) {
      return;
    }
    setPendingActionKey(`delete:${sessionKey}`);
    try {
      await onDeleteSession(sessionKey);
      if (sessionKey === activeSessionKey) {
        const nextSessionKey = streams.find((stream) => stream.sessionKey !== sessionKey)?.sessionKey;
        if (nextSessionKey) {
          onSelectSession(nextSessionKey);
        }
      }
      setRevealedSessionKey(null);
    } finally {
      setPendingActionKey(null);
    }
  }

  function startRowDrag(event: PointerEvent<HTMLDivElement>, sessionKey: string) {
    if (editingSessionKey === sessionKey) {
      return;
    }
    dragStartRef.current = {
      sessionKey,
      startX: event.clientX,
      startY: event.clientY,
      lockedAxis: null
    };
    setDraggingSessionKey(sessionKey);
    setDragOffset(revealedSessionKey === sessionKey ? -144 : 0);
  }

  function moveRowDrag(event: PointerEvent<HTMLDivElement>) {
    const start = dragStartRef.current;
    if (!start) {
      return;
    }
    const deltaX = event.clientX - start.startX;
    const deltaY = event.clientY - start.startY;
    if (!start.lockedAxis && Math.max(Math.abs(deltaX), Math.abs(deltaY)) > 8) {
      start.lockedAxis = Math.abs(deltaX) > Math.abs(deltaY) ? "horizontal" : "vertical";
    }
    if (start.lockedAxis !== "horizontal") {
      return;
    }
    event.preventDefault();
    const baseOffset = revealedSessionKey === start.sessionKey ? -144 : 0;
    setDragOffset(Math.min(0, Math.max(-144, baseOffset + deltaX)));
  }

  function endRowDrag() {
    const start = dragStartRef.current;
    if (!start) {
      return;
    }
    setRevealedSessionKey(
      start.lockedAxis === "horizontal" && dragOffset < -64 ? start.sessionKey : null
    );
    setDraggingSessionKey(null);
    setDragOffset(0);
    dragStartRef.current = null;
  }
}
