# Voice Dictation — Non-Obvious Details

## Client connects DIRECTLY to Soniox — no provider involvement in dictation transport
The architecture decision is client-direct Soniox connection. The provider does not proxy, buffer, or relay audio. Any code that routes audio through the provider WebSocket is architecturally wrong. Future server-issued temp key hardening is explicitly deferred — when it happens, transport remains client-direct (client mints a temp key then connects directly to Soniox).

## Key verification must be real network validation — not local format/length checks
The key status enum (`missing/unverified/validating/invalid/validated`) requires actual network verification against Soniox's auth surface. Local format checks (key length, prefix pattern) are not sufficient and must not be used as the source of truth for key validity. A key can be well-formed but revoked.

## Mic icon visibility driven ONLY by dictation surface open/closed state — not key presence
The mic icon visibility is never conditioned on key presence. The icon remains visible regardless of whether a Soniox key is configured. A missing key shows a different affordance (key prompt UI) but does not hide the mic icon.

## `soniox.apiKey` may be a regular OR temporary API key — both are valid
The config value accepts both regular Soniox API keys and Soniox temporary API keys for `transcribe_websocket` usage. The client does not distinguish the key type at connection time — both are passed directly to the Soniox WebSocket auth.

## Legacy dictation UX mechanics are fully superseded — this is a clean break
The push-up-to-reveal spec is a complete replacement for the prior gesture model. Legacy state indicators, mic-motion behaviors, and all prior gesture activation/deactivation patterns are removed. Code that preserves any legacy gesture handler alongside the new model creates conflicts.
