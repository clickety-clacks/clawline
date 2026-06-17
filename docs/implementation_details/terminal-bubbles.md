# Terminal Bubbles — Non-Obvious Details

## Terminal sessions use a SEPARATE WebSocket connection — not the chat WebSocket
Terminal traffic is high-volume, binary, and has different lifecycle than chat messages. `TerminalSessionService` manages its own WebSocket, independent of `ProviderChatService`. The existing `WebSocketClient` abstraction is text-only — terminal sessions require either a new binary-capable socket abstraction or a direct `URLSessionWebSocketTask` implementation that handles both `.string` and `.data` messages.

## Client parsing rule: detect by MIME type, not message structure
Terminal sessions are encoded as `AttachmentType.document` with `mimeType: application/vnd.clawline.terminal-session+json`. The client MUST intercept this MIME type during presentation building and render as a terminal bubble. Old clients fall back to generic document attachment preview — this is acceptable and is the designed backward-compat path.

## PTY resize must be sent to provider — rows/cols derived from TerminalBubbleView bounds
When the bubble view changes size (rotation, keyboard, split view), the new cols/rows must be sent to the provider's terminal session. Not sending resize signals means the PTY remains configured for the original terminal dimensions and output wraps incorrectly.

## Remote tmux path: provider SSHes to terminal host — the provider, not the client, manages the SSH connection
For remote tmux (e.g., provider on TARS, tmux on eezo), the provider SSHes to the terminal host and proxies PTY output to the client over the terminal WebSocket. The client never SSHes directly. Any code that tries to initiate SSH from the iOS client is wrong for this deployment shape.

## TerminalBubbleView participates in normal cell reuse — SwiftTerm view is created/torn down on reuse
`TerminalBubbleView` participates in normal `UICollectionView` cell reuse. SwiftTerm `TerminalView` is created on cell bind and torn down on `prepareForReuse`. No persistent terminal state in reuse pool. Large terminal history for an off-screen bubble is not preserved across scroll-away.
