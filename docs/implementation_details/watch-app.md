# Watch App — Non-Obvious Details

## Two completely independent connection categories — STT/TTS failure does not affect provider connection
The Watch maintains: (1) provider connection (chat text, dual transport with phone relay fallback), and (2) cloud API connections (Soniox STT, Cartesia TTS — always direct from Watch, never relayed). These two categories are completely independent. The provider failover state machine does not affect Soniox/Cartesia connections. A Watch in relay mode for provider chat can have healthy direct Soniox/Cartesia connections if it has WiFi.

## Route indicator is a HARD UI invariant — always visible
The provider connection route indicator must ALWAYS be visible on screen at all times. This is not an optional status display. It is a hard invariant. Code that hides the route indicator for any reason violates the spec.

**Implementation:** Route state is encoded in the mic ring AND as a small SF Symbol icon to the right of the channel name (see Shell Layout below). The ring is always on screen, so the invariant is always satisfied. The text route label is supplementary only.

- Direct connection → `wifi` SF Symbol (muted/secondary color)
- Relay via iPhone → `iphone` SF Symbol (muted/secondary color)
- Disconnected / connecting → no route icon shown; ring indicates state via color

## Watch shell layout — channel page structure
Each channel is a full-screen `TabView` page. Horizontal swipe navigates between channels (native watchOS gesture, no custom recognizer needed).

### Per-page scroll structure
Each page is a single `ScrollView` (vertical). The mic ring anchors to the bottom of the scroll content. Scrolling up (dragging down) reveals chat history above the ring.

```
┌─────────────────┐
│  [msg -10]      │  ← older messages appear above when scrolled
│  [msg -9]       │    (last 10 messages or ~500 chars, whichever is less)
│  ...            │
│  [msg -1]       │
│  [msg latest]   │  ← most recent message, just above ring
│                 │
│   ( ring )      │  ← mic ring, bottom-anchored
│  Channel Name ◉ │  ← channel name + route icon (wifi or iphone SF Symbol)
└─────────────────┘
```

When at rest (not scrolled), only the ring, channel name, and route icon are visible. Chat history appears above the ring when the user scrolls up.

### Ring visual states
The ring communicates both connection state and route — it is always on screen:

| State                  | Ring appearance                          |
|------------------------|------------------------------------------|
| Connected — direct     | Multicolored animated sine waves         |
| Connected — via iPhone | Multicolored animated sine waves (distinct palette TBD — e.g. cooler/blue tones) |
| Connecting             | Single muted color, pulse animation      |
| Disconnected           | Single muted color, no animation         |
| Recording              | Active indicator (existing behavior)     |

The ring color/animation logic mirrors the iOS send button state logic — same states, watch-appropriate rendering.

### Channel name row
- Channel name text on the left
- Route SF Symbol (`wifi` or `iphone`) to the right, muted secondary color
- Hidden when disconnected (no route to show)
- This row scrolls with the page content — it is NOT a fixed overlay

### No global overlays
There is no safeAreaInset chip, no floating route overlay, no persistent header. All per-channel state lives in the channel page itself. The ring on-screen at all times satisfies the route-indicator invariant.

## STT and TTS are unavailable in Bluetooth-only (relay) mode
Soniox and Cartesia require direct Watch internet access (WiFi or cellular). If the Watch is Bluetooth-only (relay mode for provider), STT and TTS are unavailable. The app must clearly reflect this unavailability — not attempt connections that will fail.

## API keys synced via `transferUserInfo` — stored in shared Keychain
Soniox and Cartesia keys are synced from iPhone via `WCSession.transferUserInfo` and stored in the Watch's shared Keychain access group (`group.co.clicketyclacks.Clawline`). Keys are NOT sent over the provider connection. Any code that tries to get keys from the provider is wrong for this architecture.

## Audio processing is NEVER through the provider or the phone relay
STT audio and TTS audio always flows directly between Watch and cloud APIs. The provider handles only text-based chat messaging. There is no audio data in the provider WebSocket or the phone relay. Code that routes audio through provider or relay contradicts the fundamental Watch architecture.
