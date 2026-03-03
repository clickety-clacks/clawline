# Surf Ace Spec — Adversarial Architecture Review

Reviewer: Claude (adversarial review agent)
Date: 2026-02-24
Spec reviewed: `specs/surf-ace.md` (design draft, 2026-02-24)
Post-spec design decisions also incorporated (numbered 1-7, provided by Flynn).

---

## 1. Blocking Issues

### 1.1 FATAL: "CLU connects directly to screens" is physically impossible as specified

**The contradiction:** The spec's entire architecture (Section 5) is built on "phone is the bridge" — content flows CLU → gateway → phone → screen. Post-spec decision #5 reverses this: "CLU (provider on TARS) connects DIRECTLY to screens — phone is NOT a middleman."

**Why this breaks:** Screens are local-network mDNS devices. TARS is a remote server. mDNS does not cross network boundaries. There is no mechanism for a remote CLU to reach a `_surf-ace._tcp` device on someone's home Wi-Fi. The phone-as-bridge was the *solution* to this reachability gap. Removing the bridge without replacing it creates an impossible topology.

**Possible resolutions (pick one):**

| Option | How it works | Trade-offs |
|--------|-------------|------------|
| **A: Phone relays (spec as-is)** | Phone bridges LAN ↔ WAN. Content flows through phone. | Decision #5 must be retracted. Phone battery/bandwidth cost. |
| **B: Screen connects outbound to gateway** | Screen maintains a WebSocket to TARS (like Clawline app does). CLU pushes directly over that connection. | Screens are no longer "dumb" — they need internet, gateway auth, and CLU awareness. Violates core "dumb projector" metaphor. Doesn't work for friend's screens (they'd need YOUR gateway creds). |
| **C: Phone opens a tunnel** | Phone discovers screens locally, then opens a relay tunnel (e.g., TCP proxy, WebSocket tunnel) so TARS can reach them. | Phone is still a middleman — just for the transport layer, not the application layer. Complexity. But preserves "dumb screen" model. |
| **D: Dual-mode — direct when on same network, relayed otherwise** | TARS tries direct mDNS (Tailscale home network) first, falls back to phone relay (friend's house). | Two code paths. "Direct" only works on Tailscale/same-LAN. Most real-world use still goes through phone. |

**Recommendation:** Option C or A. Option C gives the *spirit* of decision #5 (CLU owns the logical connection, phone is just plumbing) without requiring screens to be internet-aware. But it's still a phone relay at the transport layer, so call it what it is. If the goal is "CLU's protocol session is directly with the screen, not proxied through app-layer logic," then the phone opens a dumb TCP/WS tunnel and CLU speaks Surf Ace protocol directly through it. The phone doesn't interpret or enrich frames — it's a pipe.

**This must be resolved before any implementation work begins.** Every component's design depends on who talks to whom.

### 1.2 BLOCKING: Separate Surf Ace app (decision #6) invalidates the entire iOS implementation section

**The contradiction:** Section 12 describes all Surf Ace code living inside the Clawline app (`ios/Clawline/Clawline/Services/Surf Ace/...`). Decision #6 says Surf Ace is a separate app on iPhone.

**What breaks:**
- All 14 file paths in Section 12.6 are wrong.
- The ScreenRelay (Section 12.3) can't share the Clawline app's gateway WebSocket — separate app, separate process.
- The Surf Ace app needs its own gateway authentication and connection.
- The mDNS browser, pair manager, and relay all move to the Surf Ace app.
- Clawline loses the screen picker UI, or it becomes a deep-link launcher to Surf Ace.
- The "surface view" (Section 12.5) on iPhone is now the Surf Ace app itself, not a modal in Clawline.

**Cascading questions:**
1. How does the Surf Ace app authenticate to the gateway? Does it share Clawline's auth token (keychain sharing via app group)?
2. Does the Surf Ace app maintain its own persistent gateway WebSocket, or does it only connect when foregrounded?
3. If CLU pushes a frame while Surf Ace is backgrounded, where does it go? Is there a notification to open Surf Ace?
4. How does the Clawline app trigger Surf Ace? Universal link? Custom URL scheme?
5. What does the iPad story look like? Two separate apps in split view means two gateway connections.

**Recommendation:** The spec needs a new "Surf Ace App Architecture" section that replaces Section 12. Must cover: app-to-app communication, shared auth, gateway connection lifecycle, and the exact surface boundary between Clawline (chat) and Surf Ace (display). Consider whether Surf Ace is also the app that runs on Mac/TV/etc. as a screen, or if the "screen" and "viewer" are different things.

### 1.3 BLOCKING: Auto-connect has zero authentication

Section 7.4 explicitly states: "The screen accepts any connection that completes the handshake... Anyone who can reach it on the network can use it."

For `pair_auto`, the screen doesn't verify the client at all. Any device on the local network that sends `{ type: "pair_auto" }` gets a session token. The `busy` flag is the only barrier, and it's advisory (race condition between checking Bonjour and connecting).

**Attack scenario:** Attacker on same Wi-Fi (coffee shop, hotel, conference) sends `pair_auto` to every Surf Ace screen on the network. Any idle screen immediately grants a session. Attacker can push arbitrary content to strangers' screens.

**This isn't theoretical edge-case security theater — it's the default behavior on any shared network.**

**Recommendation:** Auto-connect must have mutual authentication. Options:
- Screen remembers trusted client public keys (contradicts "stateless screen" but necessary).
- Screen requires PIN every time on untrusted networks (user configures "home" vs "public" mode).
- Screen requires a pre-shared token derived from first pairing (stored on both sides).

The simplest fix: screen stores a set of trusted client public key fingerprints (just like the app stores trusted screen fingerprints). Symmetric trust. During `pair_auto`, the client proves identity by signing a challenge with its private key, and the screen checks against its trust store. This adds maybe 200 bytes of persistent state to the screen. Still "dumb," but not "exploitable."

---

## 2. Design Tensions

### 2.1 "Dumb stateless screen" vs. security requirements

The spec wants screens to store nothing except a keypair. But security requires the screen to remember *something* about trusted clients (see 1.3). Every authentication scheme that isn't "anyone can connect" requires persistent state.

**The tension:** The more stateless the screen, the less secure. The more secure, the less dumb.

**Decision needed:** What's the minimum persistent state a screen must hold? Proposal: keypair + a set of trusted client public key fingerprints (max ~100 entries, ~3KB). Still trivially simple. Still no user accounts, no CLU knowledge.

### 2.2 Session scoping vs. reconnection UX

Decision #4 says: leave the network, screen forgets you. Decision #7 says: background socket death is fine, Surf Ace reconnects on foreground. Section 15.2 says: after reconnection, "CLU decides whether to re-push."

**The tension:** If the phone goes to sleep for 30 seconds (lock screen), the WebSocket drops, the screen clears, and when the phone wakes up, everything has to be re-pushed. Every time you lock your phone, every screen goes blank. Is that acceptable UX?

**Decision needed:** Should there be a grace period? e.g., screen holds its last frame for 60 seconds after WebSocket drop before clearing. This adds trivial state (one frame buffer, one timer) but vastly improves the experience. The screen is still "session-scoped" — it just has a reconnect window.

### 2.3 Phone as relay vs. phone battery life

If the phone remains the relay (because blocking issue 1.1 requires it), then for N screens, the phone maintains N+1 WebSocket connections (N local + 1 gateway) and relays all content bidirectionally. During active use with viewport reports every 500ms per screen:

- 3 screens = 6 viewport reports/second through the phone
- Plus content pushes (potentially multi-MB)
- Plus the phone's own Clawline traffic

**Decision needed:** Is this acceptable? If not, the tunnel approach (option C in 1.1) is better — the phone opens dumb TCP tunnels and doesn't process the traffic, letting the OS handle it more efficiently. Or: viewport report throttling should be much more aggressive (2s, or scroll-end-only).

### 2.4 One screen, one session vs. collaborative scenarios

Section 11.4 describes a "collaborative review" where two colleagues look at the same screen. But Section 7.6 says one active session per screen, and Section 3 (non-goals) explicitly excludes multi-user on one screen.

**The tension:** The collaborative scenario works ONLY because one person controls the screen and the other just physically looks at it. The second person's CLU has no awareness of what's on the screen. They can't say "what's this error?" and have their CLU understand the screen context.

**Decision needed:** Is this acceptable for v1? If yes, document the limitation explicitly. If not, consider read-only observer sessions (screen accepts multiple connections, only one can push frames, others receive viewport-read-only access).

---

## 3. Missing Pieces

### 3.1 No error reporting from screens

The screen has no way to tell the client "I couldn't render that." Failed render, out of memory, unsupported content type despite capability advertisement — all silent failures. CLU pushes a frame and assumes it worked. The user sees a broken render or nothing, and CLU doesn't know.

**Add:** A `frame_error` message from screen → client:
```json
{
  "type": "frame_error",
  "frameId": "fr_8e9f0a1b",
  "error": "render_failed",
  "detail": "HTML exceeded memory limit"
}
```

### 3.2 No keepalive/heartbeat

WebSocket connections over Wi-Fi can go stale silently (NAT timeout, AP roaming, phone sleep). TCP keepalive defaults are often 2+ hours. Without an application-layer ping, the screen thinks it's connected for minutes after the client is gone. The client thinks the screen is alive for minutes after it's unreachable.

**Add:** WebSocket ping/pong at 15-second intervals. Screen drops connection after 3 missed pongs (45s). This also informs the grace period decision in 2.2.

### 3.3 No graceful disconnect message

The only way to disconnect is WebSocket close. There's no way to distinguish:
- Intentional disconnect ("I'm done with this screen")
- Network failure (Wi-Fi dropped)
- App backgrounding (iOS suspended the socket)

These should have different screen-side behaviors (e.g., intentional = clear immediately, network failure = grace period, backgrounding = grace period).

**Add:** A `disconnect` message type with a `reason` field, sent before intentional WebSocket close.

### 3.4 Occupancy leak: `occupant_name` is unimplemented

Section 7.6 returns `occupant_name: "Flynn's iPhone"` when a screen is busy. But the pairing protocol never transmits the user's name or device name. Where does the screen learn this? This field is specified in the response but impossible to populate.

**Fix:** Either add `device_name` to the pairing handshake (privacy implication on shared networks), or remove `occupant_name` from the busy response and let the Clawline app show only "This screen is in use."

### 3.5 No mechanism for CLU to learn about `surf-ace_push`

The spec says CLU invokes `surf-ace_push` as a provider action. But there's no specification of how CLU discovers this capability. Is `surf-ace_push` a tool in CLU's tool list? Is it injected when screens are available and removed when they aren't? How does CLU know the schema?

**Add:** A section specifying the tool definition that the provider registers with CLU when screens are reported, and removes when no screens are available.

### 3.6 No content size enforcement

Section 8.2 says "Max 256KB" for HTML. Who enforces this? What happens when CLU generates 300KB of HTML? The spec doesn't define enforcement points or overflow behavior.

**Add:** Enforcement at the relay layer. If content exceeds limits, the relay truncates or rejects with an error to the provider. Define limits per content type:
- HTML: 256KB
- Image: 5MB (or whatever is practical)
- PDF: 10MB
- Terminal: 64KB
- Markdown: 128KB

### 3.7 No reconnection state

After disconnect and reconnect (Section 15.2), CLU has no record of what was on each screen. The `frameId → sourceRef` mapping in the ScreenRelay dies with the relay instance. CLU must re-derive what to show from conversation context alone. For "follow mode" this might work. For "sticky mode" (user said "keep this up"), CLU has no way to know what was sticky.

**Add:** The provider's screen context cache should persist the last pushed frame metadata per screen (not the content — just the frame ID, content type, title, and source ref). On reconnect, CLU can re-push the same content. Cache is still in-memory and ephemeral to the provider process, but survives screen-level reconnections.

### 3.8 First-pairing TLS chicken-and-egg

Section 14.2 says the local WebSocket uses TLS with the screen's self-signed cert, and the app pins the key after first pairing. But during FIRST pairing, the app hasn't yet learned the screen's public key. The TLS connection is established BEFORE the pairing handshake (it's a WebSocket over TLS). So on first connect, the app accepts an unverified self-signed cert.

This means the first pairing is vulnerable to MITM: an attacker could intercept the TLS connection, present their own cert, relay the PIN challenge, and learn the PIN when the user types it. The app would then pin the ATTACKER's key.

**Fix:** The first pairing flow should verify the screen's TLS certificate fingerprint matches the `pk` advertised in the Bonjour TXT record. The app knows the expected fingerprint from mDNS before connecting. If the TLS cert doesn't match the advertised `pk`, reject the connection before sending any pairing messages.

### 3.9 No wire protocol version in WebSocket messages

The Bonjour TXT has `v=1` but the actual WebSocket messages have no version field. If the wire format evolves, there's no negotiation after the WebSocket is established. Bonjour version only tells you the protocol is supported, not which message shapes to expect.

**Add:** Include `v: 1` in WebSocket messages, or add a version handshake immediately after WebSocket connect and before pairing begins.

### 3.10 8-hex fingerprint is too short

8 hex characters = 32 bits. While birthday-collision probability is negligible for small home networks, a determined attacker can brute-force an Ed25519 key with a specific 32-bit fingerprint prefix in seconds on modern hardware. They could then impersonate a screen's Bonjour advertisement.

The Bonjour TXT `pk` fingerprint is the identity shorthand used for auto-connect trust matching. If it's spoofable, auto-connect is spoofable.

**Fix:** Minimum 16 hex characters (64 bits). Still compact for TXT records. Makes brute-force impractical.

---

## 4. Strengths

### 4.1 Session-scoped stateless screens are exactly right
The "projector in a conference room" metaphor is excellent and should be preserved. No user accounts, no persistent state, no ownership. This is a genuine insight that simplifies everything downstream.

### 4.2 Surfaces vs. Streams separation is clean
Section 4 draws a crisp boundary. Surfaces are not conversations. `sourceRef` links them without coupling them. This preserves Invariant #1 (session keys for routing) without forcing surfaces into the stream model.

### 4.3 Bonjour zero-config discovery is the right choice
No registry, no server coordination, no manual IP entry. Screens appear. This leverages existing Apple ecosystem infrastructure and makes the "visit a friend's house" scenario work naturally.

### 4.4 Content frames as the display unit
One screen, one frame, simple lifecycle. The frame model is easy to reason about and implement. The append/patch extensions for live content are pragmatic.

### 4.5 Inline content (no external URLs) is correct
Screens may not have internet access. Base64-inlining images and PDFs keeps screens truly isolated. This was a good call.

### 4.6 Phased implementation plan is well-scoped
Phase 1 is genuinely minimal (HTML-only, single screen). Each phase has clear value. The ordering makes sense.

### 4.7 Gateway restart resilience
Section 15.8's observation that screen connections survive gateway restart is a real architectural win over a registry-based approach.

---

## 5. Recommended Changes

### 5.1 Resolve the network topology (BLOCKING)
Decide how CLU reaches local-network screens. Write a new Section 5 that reflects the chosen topology. Every other component depends on this. See options in 1.1.

### 5.2 Write a Surf Ace App Architecture section (BLOCKING)
Replace Section 12 with the separate-app architecture. Define: auth sharing, gateway connection lifecycle, app-to-app communication, notification strategy for background pushes.

### 5.3 Add mutual authentication to auto-connect (BLOCKING)
Screens must store trusted client fingerprints. Add a `trusted_clients` persistent set to the screen's state (alongside the keypair). Update Section 7.4 with client identity verification.

### 5.4 Add TLS fingerprint verification on first connect
Before pairing begins, verify the TLS cert matches the Bonjour-advertised `pk`. Closes the first-pairing MITM gap. Update Section 7.3.

### 5.5 Increase fingerprint length to 16 hex chars
Update Sections 6.2, 7.2, and 10.1. Minimal spec change, meaningful security improvement.

### 5.6 Add a reconnect grace period
Screen holds its last frame for 60 seconds after WebSocket drop. Clears after grace period expires or on explicit `disconnect` with `reason: "intentional"`. Add to Section 7.5.

### 5.7 Add error, heartbeat, and disconnect messages
Three new message types: `frame_error` (screen → client), ping/pong (bidirectional, 15s interval), `disconnect` (client → screen). Add to Section 8.

### 5.8 Define the `surf-ace_push` tool schema
Add a subsection to Section 10 with the exact tool definition CLU receives, including when it's registered and unregistered.

### 5.9 Add content size limits with enforcement points
Define per-content-type limits and where enforcement happens. Add to Section 8.2.

### 5.10 Remove `occupant_name` or specify how it's populated
Either add `device_name` to the pairing handshake or drop the field from the busy response. Update Section 7.6.

### 5.11 Move viewport text extraction to scroll-end only
Resolve open question #1 as a design constraint: `visibleText` is only extracted and sent on scroll-end, not during active scrolling. Viewport reports during scrolling include position data only. This keeps scrolling smooth on all screen implementations.

---

## Architecture Principles Audit

| Principle | Status | Notes |
|-----------|--------|-------|
| Pattern propagation | OK | Frame model is clean and copyable. |
| Right-weight | OK | Minimal structure — frames, screens, relay. Not over-engineered. |
| Separation of concerns | VIOLATION | Network topology conflates discovery (phone), transport (phone or CLU?), and protocol (CLU). Must be separated. |
| Mutation seam | WARNING | "What's on screen" has three write paths: CLU push, CLU clear, and disconnect-auto-clear. Screen is SSOT for display state, but CLU's cached view can be stale. Provider cache partially addresses this but reconnection gap remains. |
| SSOT | WARNING | Screen status has two sources: Bonjour `busy` TXT and `surf-ace_screens` status from app. Can disagree during races. Designate one as authoritative (Bonjour is real-time, app report is best-effort). |
| DRY | OK | No obvious duplication in the protocol. |
| Spec compliance | N/A | Spec itself under review. |
