# T113 Architecture Plan — Non-Obvious Details

## Dependency stack direction: prewarm → per-stream-state → message-stream-seam → connection-lifecycle
The four specs have a one-way dependency stack. Per-stream-state-encapsulation depends on T105 message-stream-seam coherence. Any change to the message write path must maintain coherence with per-stream runtime state. Implementing the layers in bottom-up order (connection-lifecycle first, then message-seam, then per-stream-state) avoids invalidating earlier work.

## T104 (SBB missing after switch) is already implemented on the per-stream-state branch
SBB state is already per-stream and initialized from persisted `atBottom` on incoming entry creation on the implementation branch. Do not re-implement this from spec — check the branch state first.

## T077 (stream switch latency) is RESOLVED — evidence consolidated into core docs
No remaining work for T077. The two-key split (ui/engine separation) is on main. Evidence and latency review were consolidated into core docs on 2026-03-09.

## T100 (send button reconnect pulse animation) is OUT OF SCOPE for T113
T100 is explicitly excluded from the T113 closure set. Do not include it in T113 implementation work.

## Two cursor concepts — two separate owners, must not be conflated
- **Per-stream replay cursors**: transport layer (`ProviderChatService`), keyed by `sessionKey`, track replay progress per stream for UI populate. These are the T099 cursors.
- **Active stream send cursor**: UI/VM layer, keyed by active session key, for send routing.
These are different things stored in different places. Conflating them causes T099 (non-active streams under-replayed at login) or incorrect send routing.
