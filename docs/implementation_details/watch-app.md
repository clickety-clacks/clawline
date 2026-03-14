# Watch App — Non-Obvious Details

## Two completely independent connection categories — STT/TTS failure does not affect provider connection
The Watch maintains: (1) provider connection (chat text, dual transport with phone relay fallback), and (2) cloud API connections (Soniox STT, Cartesia TTS — always direct from Watch, never relayed). These two categories are completely independent. The provider failover state machine does not affect Soniox/Cartesia connections. A Watch in relay mode for provider chat can have healthy direct Soniox/Cartesia connections if it has WiFi.

## Route indicator is a HARD UI invariant — always visible
The provider connection route indicator ("Direct" vs "Via iPhone") must ALWAYS be visible. This is not an optional status display. It is a hard invariant. Code that hides the route indicator for any reason violates the spec.

## STT and TTS are unavailable in Bluetooth-only (relay) mode
Soniox and Cartesia require direct Watch internet access (WiFi or cellular). If the Watch is Bluetooth-only (relay mode for provider), STT and TTS are unavailable. The app must clearly reflect this unavailability — not attempt connections that will fail.

## API keys synced via `transferUserInfo` — stored in shared Keychain
Soniox and Cartesia keys are synced from iPhone via `WCSession.transferUserInfo` and stored in the Watch's shared Keychain access group (`group.co.clicketyclacks.Clawline`). Keys are NOT sent over the provider connection. Any code that tries to get keys from the provider is wrong for this architecture.

## Audio processing is NEVER through the provider or the phone relay
STT audio and TTS audio always flows directly between Watch and cloud APIs. The provider handles only text-based chat messaging. There is no audio data in the provider WebSocket or the phone relay. Code that routes audio through provider or relay contradicts the fundamental Watch architecture.
