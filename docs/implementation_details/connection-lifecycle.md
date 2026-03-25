# Connection Lifecycle — Non-Obvious Details

## Root cause of reconnect loop: no stale-attempt rejection token + late cache restores overwriting fresh state
Three separate systems (`ProviderChatService`, `ChatViewModel` reconnect scheduler, `restoreCachedMessagesIfNeeded`) each independently mutated connection/cursor state with no shared epoch. A late cache restore arriving after a successful reconnect would overwrite `lastServerMessageIdBySession` with stale values, triggering another replay from scratch, then another reconnect — the 2s cycle. The fix is a single `ConnectionLifecycleCoordinator` with an epoch token that gates all callbacks.

## `ConnectionLifecycleCoordinator` must be the only writer of connection phase transitions
`ChatViewModel`, `ProviderChatService`, and `URLSessionWebSocketConnector` emit events/intents. They must NOT transition connection phase directly. Any code that writes connection phase outside the coordinator is a boundary violation. The historical root of all three bugs was multiple independent writers each assuming they were authoritative.

## Reconnect intents while in `connecting/authenticating/replaying/live` are ignored (not queued)
A reconnect intent received when already in an active phase is silently dropped. There is no queue of pending reconnect intents. This is intentional: a late reconnect trigger for a resolved problem must not re-trigger reconnection.

## Manual retry during `recovering` has special treatment
Manual retry while in `recovering` phase: (1) cancels pending backoff timer, (2) executes immediate `recovering -> connecting` transition, (3) resets backoff delay to 1s for that attempt, (4) does NOT increment the automatic recovering-attempt counter. Subsequent automatic attempts continue from 1s doubling policy.

## `connectionSnapshot()` must send ALL per-stream cursors — not just the active session cursor
Current code sends only one cursor (`engineActiveSessionKey` cursor fallback). Replay and message apply occur for many session keys. A connection snapshot that sends only the active cursor causes all other streams to replay from scratch on every reconnect — the T099 "stale/empty streams at login" bug.

## Cache restore (`restoreCachedMessagesIfNeeded`) must not overwrite in-progress live state
Cache restore can apply asynchronously after connection/replay events. The `ConversationStoreWriter` seam must enforce: cache messages are gap-fill only and cannot overwrite server-sourced messages. Without this barrier, a slow cache restore arriving after live messages clears them from the stream.

## Phase `recovering` backoff is the sole reconnect mechanism while active
While in `recovering`, only the backoff timer triggers reconnect. External reconnect intents (transport interruption, scene activation) are ignored. This prevents the rapid-reconnect loop that occurs when multiple triggers all fire within a short window during a flaky connection.

## `ConversationStoreWriter` is the only path to mutate session messages/cursors
No direct writes to `sessionMessages`, `lastServerMessageIdBySession`, `messages`, or `lastServerMessageId` outside writer methods. This is the store equivalent of the message-stream-seam — same compiler-error-first migration discipline applies.
