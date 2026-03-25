# Watch iOS Support — Non-Obvious Details

## Soniox and Cartesia key storage doesn't exist yet in iOS — must be added as Phase 0 prerequisite
The iOS app currently has NO storage for Soniox API keys, Cartesia API keys, or Cartesia voice ID. The Watch credential sync assumes iOS holds these. `SonioxKeyStore` and `CartesiaKeyStore` (Keychain-backed with `@Observable`) must be created before credential sync can work. This is not obvious from the Watch spec alone.

## Phone relay is a transparent proxy — Watch sends the full WebSocket message, iOS forwards it
The phone relay proxy is NOT an application-level message bridge. iOS acts as a transparent proxy: Watch sends a WebSocket message via WCSession, iOS forwards it as-is to its existing `ProviderChatService` WebSocket, and reverses responses. The protocol on the relay path is identical to the direct path. iOS does not parse or transform the content.

## Token refresh relay — iOS must support `auth.refresh` operation from Watch
When the provider token needs refresh, the Watch sends an `auth.refresh` operation via WCSession relay. iOS handles the refresh against the provider and relays the new token back. If iOS doesn't implement this relay path, Watch sessions expire and cannot re-authenticate while in relay mode.

## Background task management for relay continuity
The relay proxy must hold a background task while a relay session is active. Without a background task, iOS suspends the relay when backgrounded, breaking Watch's provider connection. This is a common iOS mistake: the foreground service path works but background drops silently.

## No iOS UI required for any Watch support feature
All Watch support features (credential sync, relay proxy, key storage) are invisible to the iOS user. No settings, no status indicator, no user opt-in for Phase 0. This is an explicit non-goal to avoid scope creep.
