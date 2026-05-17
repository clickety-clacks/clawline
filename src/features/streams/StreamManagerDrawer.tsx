import { useEffect, useMemo, useState } from "react";
import { RefreshCw, X } from "lucide-react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { useCrossChatNotificationStore } from "../../runtime/chat/crossChatNotificationStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import {
  createStreamApiClient,
  type TrackableSessionPayload
} from "../../protocol/stream-api";
import { getSessionProvisioningState } from "./provisioning";

const streamApiClient = createStreamApiClient();

export function StreamManagerDrawer({
  activeSessionKey,
  isOpen,
  onClose,
  onSelectSession
}: {
  activeSessionKey?: string;
  isOpen: boolean;
  onClose: () => void;
  onSelectSession: (sessionKey?: string) => void;
}) {
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { store: notificationStore } = useCrossChatNotificationStore();
  const { state: transportState } = useTransportMachine();
  const [createName, setCreateName] = useState("");
  const [editingSessionKey, setEditingSessionKey] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isLoadingStreams, setLoadingStreams] = useState(false);
  const [isLoadingTrackables, setLoadingTrackables] = useState(false);
  const [pendingActionKey, setPendingActionKey] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [trackableSessions, setTrackableSessions] = useState<TrackableSessionPayload[]>(
    []
  );

  const session = authState.session;
  const trackableRefreshToken = useMemo(
    () =>
      [
        ...chatState.streams.map((stream) => `${stream.sessionKey}:${stream.adopted ? 1 : 0}`),
        "---",
        ...chatState.provisionedSessionKeys
      ].join("|"),
    [chatState.provisionedSessionKeys, chatState.streams]
  );

  useEffect(() => {
    if (!isOpen) {
      setErrorMessage(null);
      setEditingSessionKey(null);
      return;
    }

    if (!session) {
      return;
    }

    setErrorMessage(null);
    void refreshStreams();

    if (!session.isAdmin) {
      setTrackableSessions([]);
      return;
    }
  }, [isOpen, session?.isAdmin, session?.serverUrl, session?.token]);

  useEffect(() => {
    if (!isOpen || !session?.isAdmin) {
      return;
    }

    void refreshTrackableSessions();
  }, [
    isOpen,
    session?.isAdmin,
    session?.serverUrl,
    session?.token,
    trackableRefreshToken
  ]);

  if (!isOpen) {
    return null;
  }

  async function refreshTrackableSessions() {
    if (!session?.isAdmin) {
      setTrackableSessions([]);
      return;
    }

    setLoadingTrackables(true);
    setErrorMessage(null);

    try {
      const response = await streamApiClient.fetchTrackableSessions({
        serverUrl: session.serverUrl,
        token: session.token
      });
      setTrackableSessions(response.sessions);
    } catch (error) {
      setErrorMessage(toErrorMessage(error, "Could not load Track candidates."));
    } finally {
      setLoadingTrackables(false);
    }
  }

  async function refreshStreams() {
    if (!session) {
      return;
    }

    setLoadingStreams(true);

    try {
      const response = await streamApiClient.fetchStreams({
        serverUrl: session.serverUrl,
        token: session.token
      });
      chatStore.applyStreamSnapshot(response.streams);
    } catch (error) {
      setErrorMessage(toErrorMessage(error, "Could not load streams."));
    } finally {
      setLoadingStreams(false);
    }
  }

  async function createStream() {
    if (!session) {
      return;
    }

    const trimmedName = createName.trim();
    if (trimmedName.length === 0) {
      return;
    }

    setPendingActionKey("create");
    setErrorMessage(null);

    try {
      const response = await streamApiClient.createStream({
        displayName: trimmedName,
        idempotencyKey: generateUuidV4(),
        serverUrl: session.serverUrl,
        token: session.token
      });
      chatStore.upsertStream(response.stream);
      setCreateName("");
      onSelectSession(response.stream.sessionKey);
      void refreshStreams();
      onClose();
    } catch (error) {
      setErrorMessage(toErrorMessage(error, "Could not create stream."));
    } finally {
      setPendingActionKey(null);
    }
  }

  async function saveRename(stream: StreamRecord) {
    if (!session) {
      return;
    }

    const trimmedName = renameValue.trim();
    if (trimmedName.length === 0) {
      return;
    }

    setPendingActionKey(`rename:${stream.sessionKey}`);
    setErrorMessage(null);

    try {
      const response = await streamApiClient.renameStream({
        displayName: trimmedName,
        serverUrl: session.serverUrl,
        sessionKey: stream.sessionKey,
        token: session.token
      });
      chatStore.upsertStream(response.stream);
      void refreshStreams();
      setEditingSessionKey(null);
      setRenameValue("");
    } catch (error) {
      setErrorMessage(toErrorMessage(error, "Could not rename stream."));
    } finally {
      setPendingActionKey(null);
    }
  }

  async function deleteOrUntrackStream(stream: StreamRecord) {
    if (!session) {
      return;
    }

    setPendingActionKey(`delete:${stream.sessionKey}`);
    setErrorMessage(null);

    try {
      await streamApiClient.deleteStream({
        idempotencyKey: stream.adopted ? null : generateUuidV4(),
        serverUrl: session.serverUrl,
        sessionKey: stream.sessionKey,
        token: session.token
      });
      chatStore.removeStream(stream.sessionKey);
      notificationStore.dismissCrossChatNotification(stream.sessionKey);

      if (activeSessionKey === stream.sessionKey) {
        const remainingStreams = chatState.streams.filter(
          (entry) => entry.sessionKey !== stream.sessionKey
        );
        onSelectSession(remainingStreams[0]?.sessionKey);
      }

      if (session.isAdmin) {
        void refreshTrackableSessions();
      }
      void refreshStreams();
    } catch (error) {
      setErrorMessage(
        toErrorMessage(
          error,
          stream.adopted ? "Could not untrack session." : "Could not delete stream."
        )
      );
    } finally {
      setPendingActionKey(null);
    }
  }

  async function trackSession(trackableSession: TrackableSessionPayload) {
    if (!session?.isAdmin) {
      return;
    }

    setPendingActionKey(`track:${trackableSession.sessionKey}`);
    setErrorMessage(null);

    try {
      const response = await streamApiClient.adoptStream({
        sessionKey: trackableSession.sessionKey,
        serverUrl: session.serverUrl,
        token: session.token
      });
      chatStore.upsertStream(response.stream);
      setTrackableSessions((current) =>
        current.filter((entry) => entry.sessionKey !== trackableSession.sessionKey)
      );
      void refreshStreams();
      onSelectSession(response.stream.sessionKey);
    } catch (error) {
      setErrorMessage(toErrorMessage(error, "Could not track session."));
    } finally {
      setPendingActionKey(null);
    }
  }

  return (
    <div className="drawer-backdrop" onClick={onClose} role="presentation">
      <aside
        aria-label="Manage streams"
        className="settings-drawer stream-manager-drawer"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="settings-header">
          <div>
            <p className="eyebrow">Streams</p>
            <h2>Manage sessions</h2>
          </div>
          <button
            aria-label="Close stream manager"
            className="button-secondary button-icon"
            onClick={onClose}
            type="button"
          >
            <X size={18} strokeWidth={2.1} />
          </button>
        </div>

        {errorMessage ? <p className="field-error">{errorMessage}</p> : null}

        <section className="settings-section">
          <h3>Create stream</h3>
          <div className="stream-manager-create-row">
            <input
              aria-label="New stream name"
              onChange={(event) => setCreateName(event.target.value)}
              placeholder="Research"
              value={createName}
            />
            <button
              className="button-primary"
              disabled={pendingActionKey === "create" || createName.trim().length === 0}
              onClick={() => {
                void createStream();
              }}
              type="button"
            >
              Create
            </button>
          </div>
        </section>

        <section className="settings-section">
          <div className="stream-manager-section-header">
            <h3>Current streams</h3>
            <button
              aria-label="Refresh streams"
              className="button-secondary button-icon"
              disabled={isLoadingStreams}
              onClick={() => {
                void refreshStreams();
              }}
              title="Refresh streams"
              type="button"
            >
              <RefreshCw size={18} strokeWidth={2} />
            </button>
          </div>
          {isLoadingStreams ? <p>Refreshing streams…</p> : null}
          <div className="stream-manager-list">
            {chatState.streams.map((stream) => {
              const canRename = canRenameStream(stream);
              const canDelete = canDeleteStream(stream);
              const canUntrack = Boolean(stream.adopted) && !stream.isBuiltIn;
              const isEditing = editingSessionKey === stream.sessionKey;
              const deleteActionLabel = canUntrack ? "Untrack" : "Delete";
              const provisioningState = getSessionProvisioningState({
                hasStream: true,
                provisionedSessionKeys: chatState.provisionedSessionKeys,
                sessionKey: stream.sessionKey,
                transportPhase: transportState.phase
              });

              return (
                <article className="stream-manager-card" key={stream.sessionKey}>
                  <div className="stream-manager-card-copy">
                    {isEditing ? (
                      <input
                        aria-label={`Rename ${stream.displayName}`}
                        onChange={(event) => setRenameValue(event.target.value)}
                        value={renameValue}
                      />
                    ) : (
                      <strong>{stream.displayName}</strong>
                    )}
                    <code>{stream.sessionKey}</code>
                    <div className="stream-manager-meta-row">
                      <p className="stream-manager-meta">
                        {stream.adopted ? "Tracked session" : "Provider-managed stream"}
                      </p>
                      <span
                        className={`stream-status-pill stream-status-pill--${provisioningState}`}
                      >
                        {provisioningState}
                      </span>
                    </div>
                  </div>
                  <div className="stream-manager-actions">
                    {isEditing ? (
                      <>
                        <button
                          className="button-primary"
                          disabled={pendingActionKey === `rename:${stream.sessionKey}`}
                          onClick={() => {
                            void saveRename(stream);
                          }}
                          type="button"
                        >
                          Save
                        </button>
                        <button
                          className="button-secondary"
                          onClick={() => {
                            setEditingSessionKey(null);
                            setRenameValue("");
                          }}
                          type="button"
                        >
                          Cancel
                        </button>
                      </>
                    ) : (
                      <>
                        <button
                          className="button-secondary"
                          disabled={!canRename}
                          onClick={() => {
                            setEditingSessionKey(stream.sessionKey);
                            setRenameValue(stream.displayName);
                          }}
                          type="button"
                        >
                          Rename
                        </button>
                        <button
                          className="button-danger"
                          disabled={!canDelete && !canUntrack}
                          onClick={() => {
                            void deleteOrUntrackStream(stream);
                          }}
                          type="button"
                        >
                          {deleteActionLabel}
                        </button>
                      </>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        </section>

        {session?.isAdmin ? (
          <section className="settings-section">
            <div className="stream-manager-section-header">
              <h3>Track sessions</h3>
              <button
                aria-label="Refresh trackable sessions"
                className="button-secondary button-icon"
                disabled={isLoadingTrackables}
                onClick={() => {
                  void refreshTrackableSessions();
                }}
                title="Refresh trackable sessions"
                type="button"
              >
                <RefreshCw size={18} strokeWidth={2} />
              </button>
            </div>
            {isLoadingTrackables ? (
              <p>Loading track candidates…</p>
            ) : trackableSessions.length === 0 ? (
              <p>No trackable sessions available.</p>
            ) : (
              <div className="stream-manager-list">
                {trackableSessions.map((trackableSession) => {
                  const isTracked = chatState.streams.some(
                    (stream) => stream.sessionKey === trackableSession.sessionKey
                  );

                  return (
                    <article
                      className="stream-manager-card"
                      key={trackableSession.sessionKey}
                    >
                      <div className="stream-manager-card-copy">
                        <strong>{trackableSession.displayName}</strong>
                        <code>{trackableSession.sessionKey}</code>
                      </div>
                      <div className="stream-manager-actions">
                        <button
                          className="button-primary"
                          disabled={
                            isTracked ||
                            pendingActionKey === `track:${trackableSession.sessionKey}`
                          }
                          onClick={() => {
                            void trackSession(trackableSession);
                          }}
                          type="button"
                        >
                          Track
                        </button>
                      </div>
                    </article>
                  );
                })}
              </div>
            )}
          </section>
        ) : null}
      </aside>
    </div>
  );
}

function canRenameStream(stream: StreamRecord) {
  return stream.kind === "main" || !stream.isBuiltIn;
}

function canDeleteStream(stream: StreamRecord) {
  if (stream.adopted) {
    return false;
  }

  return stream.kind === "main" || !stream.isBuiltIn;
}

function toErrorMessage(error: unknown, fallback: string) {
  if (
    typeof error === "object" &&
    error != null &&
    "message" in error &&
    typeof error.message === "string" &&
    error.message.length > 0
  ) {
    return `${fallback} ${error.message}`;
  }

  return fallback;
}
