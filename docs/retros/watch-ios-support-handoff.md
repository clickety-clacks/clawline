# watch-ios-support Handoff Retro

**Branch:** `watch-ios-support`
**Date:** 2026-03-02
**Author:** Claude Sonnet 4.6 (watch agent)

---

## What This Branch Does

Adds a native watchOS companion app to Clawline. The Watch app talks to the Clawline provider using a **direct-first** transport strategy: it attempts a direct WebSocket connection to the provider, and falls back to relaying through the iPhone companion only if direct fails. Voice input (Soniox STT) and voice output (Cartesia TTS) run on-device without routing audio through the iPhone.

---

## Architecture Decisions

### Direct-First Transport (`WatchProviderTransport`)

`WatchProviderTransport` implements `ChatServicing` and manages four states:

```
.probing → .direct   (direct WebSocket succeeded)
.probing → .relay    (direct failed, iPhone relay activated)
.relay   → .probing  (relay send fails, retry direct)
.direct  → .probing  (direct connection dropped)
any      → .disconnected  (phone unreachable, direct failed, no relay)
```

The transition `.relay → .probing` on send failure was a specific bug fix (`f9eea77f9`). Originally, relay send failure went straight to `.disconnected`, which was too aggressive — the phone might still be reachable.

**Why direct-first instead of relay-first:** Relay ties voice latency to iPhone proximity and network state. Direct is only possible because the Watch shares credentials with the iOS app (provider token, base URL). If the network topology changes, relay is the safe fallback.

### Credential Sync Flow

```
iOS AuthManager / SonioxKeyStore / CartesiaKeyStore
       ↓
WatchConnectivityService.syncCredentials()
  updateApplicationContext(...)  ← Watch reads on activation (recovery path)
  transferUserInfo(...)          ← async queue, delivered even when Watch sleeps
       ↓
WatchWCSessionDelegate.session(_:didReceiveUserInfo:)
       ↓
WatchCredentialStore.apply(userInfo:)
  → writes to Keychain (service: "co.clicketyclacks.Clawline.watch")
  → fires onCredentialsChanged callback
       ↓
WatchProviderTransport reconnects if credentials changed
```

**Both paths are necessary.** `updateApplicationContext` gets picked up on Watch activation from cold start (e.g., after a Watch reset or new install). `transferUserInfo` is the live delivery path — reliable, queued, background-delivered. Without `updateApplicationContext`, a fresh Watch install never gets credentials until the iOS app sends a fresh push.

The credential push is triggered by notifications: `.authStateDidChange`, `.sonioxApiKeyDidChange`, `.cartesiaApiKeyDidChange`, `.cartesiaVoiceIdDidChange`, `.providerBaseURLDidChange`. Any of these fires `handleCredentialChange` → `syncCredentials()`. It also fires on `sessionReachabilityDidChange` becoming true (Watch just came into range).

### Relay Architecture

When direct fails, `WatchProviderTransport` sends `relay.activated` via `WCSession.default.sendMessage(_:replyHandler:)` to the iOS companion. `WatchConnectivityService` on iOS handles this by:

1. Setting `relayActive = true`
2. Starting a `UIBackgroundTaskIdentifier` (gives ~30s after app backgrounds)
3. Subscribing to `chatService.incomingMessages` and `chatService.serviceEvents`
4. Pushing each to Watch via `WCSession.default.sendMessage(_:replyHandler: nil)`

Outgoing messages from Watch go as `chat.send` WCSession messages with a reply handler — the iOS app calls `chatService.send(...)` and acks when done.

**Background task caveat:** The 30s background budget is not renewable. If the user puts their iPhone in their pocket and the Watch needs relay for more than 30s, relay silently stops. This is a known limitation; direct transport handles this better.

---

## WatchConnectivity Quirks (The Hard-Won Lessons)

### 1. Never activate twice

`WCSession.default.activate()` must only be called when `activationState == .notActivated`. Calling it again from `.activated` state causes undefined behavior. Guard on it:

```swift
guard WCSession.default.activationState == .notActivated else { return }
```

On iOS, `sessionDidDeactivate` fires during Watch handoff (user paired a new Watch). Reactivate there to allow the new Watch to connect.

### 2. `isPaired` is only valid post-activation

Calling `WCSession.default.isPaired` before `activationDidCompleteWith` fires returns `false` even if a Watch is paired. `syncCredentials()` guards on `isPaired` — make sure this is only called after activation.

### 3. Simulator pairing is NOT automatic

If you launch the Watch app in a simulator using raw `xcrun simctl install` + `xcrun simctl launch`, it shows **"Open Clawline on iPhone to pair"** screen — even if you have an iPhone simulator running. This is because WatchKit companion pairing requires a specific simulator-to-simulator link that only the Xcode build system sets up automatically.

**The fix:** Use `npx xcodebuildmcp simulator build-and-run` with the Clawline iOS scheme first, then build the Watch scheme. The tool handles companion pairing. Never use raw simctl for Watch+iPhone simulator pairs.

### 4. Watch Keychain is encrypted even in simulator debug mode

You cannot write to the Watch app's Keychain from outside (e.g., via `xcrun simctl keychain`, LLDB expression eval, or `xcrun simctl spawn`). The only way to seed credentials is through the actual WCSession transfer from the paired iOS app — or a debug env var hook inside the Watch app itself (which we removed before shipping). Plan testing around real credential flows, not shortcuts.

### 5. LLDB expression evaluation doesn't work on Watch simulators via DAP

The DAP-based debugging backend that XcodeBuildMCP uses for simulator debugging doesn't support `expr` evaluation on Watch targets. If you need to debug Watch internals, instrument with `print()` statements and capture via log streaming — not LLDB.

### 6. `receivedApplicationContext` is the recovery path

On Watch app cold start (or after reinstall), `WCSession.default.receivedApplicationContext` holds the last context pushed by the iOS app. `WatchWCSessionDelegate.session(_:activationDidCompleteWith:)` reads this and calls `credentialStore.apply(userInfo:)`. This is what makes the Watch work immediately after a fresh install without waiting for a new credential push.

---

## UI Layout Decisions

### Top Bar: Clock Collision

The Apple Watch system clock overlays the top-right corner of every app. On Series 11 (46mm) and similar models, this occupied approximately 44 points from the trailing edge.

`keyStatusBadges` (the S✓/C✓/S✗/C✗ indicators) are positioned trailing in an HStack at the top of the content view. Without padding, they collide with the clock and become partially hidden.

**Fix:** `.padding(.trailing, 44)` on `keyStatusBadges`. This is hardcoded — if Apple changes the clock overlay geometry in a future watchOS release, this may need adjustment. It worked on Series 11 (46mm) and Series 10 (46mm). On smaller watches (41mm, 40mm), the clock overlay is similar but the content area is narrower; verify on those if the badge size grows.

### RouteIndicatorChip Labels

Previous labels: `"Direct"` / `"Via iPhone"` — user research (Flynn) found these were confusing. Final labels:

| State | Label | Color |
|---|---|---|
| `.direct` | Connected | green |
| `.probing` | Reconnecting... | yellow |
| `.relay` | Relaying | blue |
| `.disconnected` | No Connection | red |

"Relaying" and "Connected" map to observable transport facts. The dots-style icon (`circle.fill` / `circle.dotted` / `arrow.left.arrow.right` / `circle`) gives a quick visual parse.

### Status Line Below Mic

The status line (`Text(statusLine)`) appears immediately below the WaveformRingView mic. It shows:
- Voice state (Listening... / Finalizing... / Sending... / Speaking...)
- Error message if `voiceSession.voiceState == .error`
- "Voice unavailable — text only" when in `.relay` state and `!canUseVoice`
- "Tap or hold to talk" as the default idle prompt

`statusOverride` provides a 2-second flash for transient messages (connection state changes, "Sending..."). It uses a cancellable Task to debounce rapid state changes.

### WaveformRingView CPU Fix

`TimelineView(.animation)` runs at display refresh rate (60/120Hz) continuously. The original implementation had the ring animating even when voice was idle, causing sustained 60%+ CPU usage and a `cpu_resource` crash in build 1572.

**Fix:** `TimelineView(.animation(paused: !isActive))` — pauses the timeline when voice is not active (not listening, finalizing, or speaking). The view is completely inert when the user isn't talking.

---

## What Broke and Why

### 1. Pasteboard XPC Deadlock (0x8BADF00D watchdog kill)

**Root cause confirmed from crash IPS files (5 kills in build 1566).**

When the device locks while a UITextView holds first responder, `UIKeyboardStateManager.canInsertAdaptiveImageGlyph` makes a synchronous XPC call to the pasteboard daemon. The pasteboard daemon suspends on device lock. The XPC never returns. The main thread is blocked. The watchdog kills the app after ~8 seconds.

**Fix:** In `willResignActiveNotification`, call `endEditing(true)` on every window in every connected scene before the app background transition completes:

```swift
.onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .forEach { $0.endEditing(true) }
}
```

This runs on the main thread synchronously before the background transition, ensuring no UITextView can trigger the XPC path.

**Rejected fix:** Disabling `adaptiveImageGlyphEnabled` via ObjC runtime (`NSClassFromString("UITextView")?.setValue(false, forKey: "adaptiveImageGlyphEnabled")`). This is a band-aid that turns off a feature rather than addressing the concurrency issue.

### 2. WCSession Activation Not Firing Credential Push

Early build (`0b0ff7ea5`): credentials never pushed to Watch on fresh install. Root cause: `syncCredentials()` was called before `activationDidCompleteWith` fired, so `WCSession.default.isPaired` returned `false` and the push was silently skipped.

**Fix:** Only call `syncCredentials()` inside `activationDidCompleteWith` after confirming `activationState == .activated && session.isPaired`.

### 3. Watch App Showing Pairing Screen in Simulator

Described above in WatchConnectivity Quirks §3. Using raw simctl for Watch simulation install bypasses companion linking.

### 4. Relay Retry Going to Disconnected

`f9eea77f9`: When relay send failed (e.g., WCSession `sendMessage` error callback), the transport jumped to `.disconnected` instead of re-entering `.probing`. This caused the Watch to show "No Connection" when the phone was actually still paired but momentarily unreachable. Fixed by entering `.probing` on relay send failure so the transport immediately retries direct.

### 5. Voice Unavailable — No Key UI on iOS

The Watch `voiceSession.canUseVoice` returns `false` when `sonioxApiKey` is empty. The credential store is populated from the iOS app via WCSession. But the iOS Settings view had no UI to enter Soniox or Cartesia API keys — there was no way for users to provide them.

**Fix:** Added a "Voice" section to iOS `SettingsView` with `SecureField` inputs for Soniox API key, Cartesia API key, and Cartesia voice ID. These write directly to `SonioxKeyStore` / `CartesiaKeyStore`, which post notifications that trigger `syncCredentials()` on `WatchConnectivityService`, which pushes the new keys to Watch via WCSession.

---

## Adversarial Review Findings (Unresolved — Next Agent Owns These)

The spec at `/Users/mike/shared-workspace/clawline/specs/watch-app.md` was reviewed adversarially. Key unresolved findings:

**1. `canUseVoice` only checks Soniox key, not Cartesia**

```swift
var canUseVoice: Bool {
    credentialStore.sonioxApiKey?.isEmpty == false
}
```

Voice uses both Soniox (STT) and Cartesia (TTS). If Soniox key is present but Cartesia key is absent, `canUseVoice` returns `true` but TTS will fail at runtime. The check should be `sonioxApiKey != nil && cartesiaApiKey != nil`.

**2. `routeChanged(to:)` in `WatchVoiceSession` only guards on `.disconnected`**

If voice is active and transport transitions to `.relay`, the voice session is not notified to stop. Current product intent is to allow voice in relay (with higher latency), but this is undocumented and untested.

**3. `WatchProviderTransport` is a 1007-line monolith**

The transport handles: WebSocket lifecycle, auth handshake, message parsing, relay activation/deactivation, retry logic, stream management, and incoming message broadcasting. This is six separate concerns in one class. Consider splitting auth, relay management, and message routing into separate types before this grows further.

**4. Parallel type hierarchies**

`WatchProviderTransportState` (Watch-side) and `connectionState` on the iOS transport are parallel enums with similar cases. No shared type. If you add a new state to one, you must remember to add it to the other.

**5. `ClawlineShared` package was never created**

The spec references a `ClawlineShared` Swift package for types shared between iOS and watchOS. Instead, types are duplicated in `WatchSharedModels.swift`. This is a DRY violation — `Message`, `Attachment`, and related types exist in both targets.

**6. Two credential write paths on Watch**

`auth.refresh` reply in `WatchWCSessionDelegate` writes credentials back from Watch to iOS via WCSession reply, but the payload construction uses optionals without nil-coalescing defensively (`as Any`). If `credentialStore.providerToken` is nil, it sends `nil` as the token value — which the iOS side may accept silently.

---

## Simulator Testing Workflow (What Works)

```bash
# Build iOS companion first (required for Watch sim pairing)
npx xcodebuildmcp simulator build-and-run \
  --scheme "Clawline" \
  --project-path ios/Clawline/Clawline.xcodeproj \
  --simulator-id "4021C3B9-7E44-473D-BBA6-C4037382933D"  # iPhone 16 Pro

# Then build Watch (will auto-pair with the above iPhone sim)
npx xcodebuildmcp simulator build-and-run \
  --scheme "Clawline Watch Watch App" \
  --project-path ios/Clawline/Clawline.xcodeproj \
  --simulator-id "518A7AF8-8011-4E3B-9150-9415E6685E5D"  # Apple Watch Series 11 (46mm)
```

Simulator UDIDs as of 2026-03-02:
- iPhone 16 Pro: `4021C3B9-7E44-473D-BBA6-C4037382933D`
- Apple Watch Series 11 (46mm): `518A7AF8-8011-4E3B-9150-9415E6685E5D`

These UDIDs change when simulators are deleted and recreated. Re-run `npx xcodebuildmcp simulator list` if they fail.

**Key limitation:** You cannot seed Watch credentials from outside the app in the simulator. The Watch will show "Open Clawline on iPhone to pair" until credentials flow through WCSession. To test the main view with badges, you need a paired physical device or add a temporary debug hook in `WatchCredentialStore.init()` (remove before committing).

---

## Key Files

| File | Purpose |
|---|---|
| `Clawline Watch Watch App/Clawline_WatchApp.swift` | App entry point, wires all services |
| `Clawline Watch Watch App/Services/WatchProviderTransport.swift` | Core transport (1007 lines — needs splitting) |
| `Clawline Watch Watch App/Services/WatchVoiceSession.swift` | STT/TTS voice flow |
| `Clawline Watch Watch App/Services/WatchCredentialStore.swift` | Keychain-backed credential persistence |
| `Clawline Watch Watch App/Services/WatchWCSessionDelegate.swift` | WCSession handler on Watch side |
| `Clawline Watch Watch App/Services/WatchChannelManager.swift` | Stream switching logic |
| `Clawline Watch Watch App/Views/WatchMainView.swift` | Primary Watch UI |
| `Clawline Watch Watch App/Views/RouteIndicatorChip.swift` | Connection state chip |
| `Clawline Watch Watch App/Views/WaveformRingView.swift` | Animated mic ring |
| `Clawline/Services/WatchConnectivityService.swift` | iOS-side WCSession handler + relay |
| `Clawline/ClawlineApp.swift` | iOS app root — instantiates WatchConnectivityService |

---

## Commit History (Branch Highlights)

```
4c3d81a  Remove WC_DIAG diagnostic prints and TEMP debug seed
52bf827  Watch sim validation: fix badge layout (trailing 44pt padding)
fcce127  Fix pasteboard XPC deadlock: endEditing on willResignActive
815740e  Fix pasteboard XPC deadlock causing iPhone hang (first attempt, later revised)
6b910b7  Fix WaveformRingView continuous render loop (cpu_resource violation)
6adcad1  Watch UI layout + voice unavailable fix (build 1574)
f9eea77  Fix Watch relay retry: enter probing on relay send failure
d994a98  Fix WatchConnectivity companion pairing (bundle ID + embed)
0b0ff7e  Fix WatchConnectivity activation and credential push
```
