# Multi-Agent Clawline Investigation

## 1) Is the agent-ID portion of session keys hardcoded anywhere in provider (TypeScript) or iOS client (Swift)?

### iOS client (Swift)
Yes, in production client code.

- `SessionKey.admin` is hardcoded to `"agent:main:main"` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:11](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:11)).
- `SessionKey.clawlineDMPrefix` is hardcoded to `"agent:main:clawline:"` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:12](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:12)).
- `SessionKey.clawlineMain(userId:)` constructs `"agent:main:clawline:\(userId):main"` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:18](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:18), [/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:19](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:19)).
- `isClawlinePersonalDM` explicitly requires `parts[1] == "main"` in parsing ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:28](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:28)).

Also hardcoded in non-production client artifacts:
- Stub service test/dev stream keys use `agent:main:...` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:50](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:50), [/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:103](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:103)).
- Preview sample uses `agent:main:...` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Views/Chat/ChannelToast.swift:141](/Users/mike/src/clawline/ios/Clawline/Clawline/Views/Chat/ChannelToast.swift:141)).

### Provider (TypeScript)
No provider TypeScript source is present in this checkout to inspect directly.

- Repo docs describe this repository as iOS-focused, with project structure listing `ios`, `docs`, and `shared` only ([/Users/mike/src/clawline/README.md:65](/Users/mike/src/clawline/README.md:65) to [/Users/mike/src/clawline/README.md:79](/Users/mike/src/clawline/README.md:79)).
- Platform is explicitly iOS/Swift ([/Users/mike/src/clawline/COMMON.md:32](/Users/mike/src/clawline/COMMON.md:32)).

Conclusion: hardcoding is confirmed in Swift client code; provider TS hardcoding cannot be confirmed from this repo because provider TS source is not present here.

## 2) Does the provider assume all streams belong to `agent:main`? (construction, parsing, routing)

From code available here (iOS side), routing treats session keys mostly as opaque, with one important exception in `SessionKey` helpers.

### Opaque routing behavior (no `agent:main` assumption)
- Incoming message/typing/activity routing uses `payload.sessionKey` directly, no pattern parse ([/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:668](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:668) to [/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:678](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:678)).
- Session lists are normalized by trim/dedupe only ([/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:691](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:691) to [/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:703](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:703)).
- Stream CRUD API paths use the provided session key as an opaque path component ([/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StreamAPIClient.swift:98](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StreamAPIClient.swift:98) to [/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StreamAPIClient.swift:117](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StreamAPIClient.swift:117)).
- `SessionRegistry` explicitly documents session keys as opaque canonical IDs ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionRegistry.swift:5](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionRegistry.swift:5) to [/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionRegistry.swift:7](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionRegistry.swift:7)).

### `agent:main` assumptions in client logic
- Personal-DM recognition is hardcoded to `agent:main:clawline:<user>:main` via explicit part checks, including `parts[1] == "main"` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:23](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:23) to [/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:30](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:30)).
- ChatViewModel uses these helpers in behavioral decisions (protected stream logic and fallback/default stream logic) ([/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1842](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1842) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1849](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1849), [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1993](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1993) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1995](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1995)).

Provider conclusion from this repo: cannot directly verify provider TS assumptions because provider TS source is not present here.

## 3) What would need to change to support streams bound to a different agent ID (e.g. `agent:streams`)?

### Required client changes
1. Generalize session-key helper constants/parsing in `SessionKey`.
- Replace hardcoded `main` agent segment in:
  - `admin` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:11](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:11))
  - `clawlineDMPrefix` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:12](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:12))
  - `clawlineMain(userId:)` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:18](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:18) to [/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:19](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:19))
  - `isClawlinePersonalDM` check on `parts[1] == "main"` ([/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:28](/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:28)).

2. Keep `ChatViewModel` behavior but feed it generalized `SessionKey` logic.
- It depends on `SessionKey.clawlineMain` and `SessionKey.isClawlinePersonalDM` for fallback and protected-stream decisions ([/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1842](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1842) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1849](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1849), [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1993](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1993) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1995](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1995)).

3. Update non-production hardcoded examples (optional but recommended for consistency).
- Stub stream keys ([/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:50](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:50), [/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:103](/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StubChatService.swift:103)).
- Preview literal ([/Users/mike/src/clawline/ios/Clawline/Clawline/Views/Chat/ChannelToast.swift:141](/Users/mike/src/clawline/ios/Clawline/Clawline/Views/Chat/ChannelToast.swift:141)).

### Likely provider changes (not directly inspectable in this repo)
Inference: provider must construct/validate/route session keys using a configurable agent ID (or fully opaque keys), and stream/session queries must not hardcode `agent:main` prefixes.

## 4) Impact on existing SQLite stream records and session history if agent ID segment changes; migrations needed?

### In this repo (iOS client): no SQLite storage for streams/history
- Session history is persisted as per-session JSON files under `Application Support/Clawline/MessageCache` keyed by session key-derived filename ([/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1664](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1664) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1692](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1692)).
- Stream metadata is persisted as JSON in `Application Support/Clawline/StreamCache` ([/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:2022](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:2022) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:2077](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:2077)).
- Cursor/session state is stored in `UserDefaults` keys including the full session key ([/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1606](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1606) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1623](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1623), [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1796](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1796) to [/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1813](/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1813)).

### Practical impact of changing `agent:main` to another agent ID
- Existing cached history/state keyed by old session keys will not automatically match new keys; history appears as a separate/new stream namespace.
- No SQLite migration is needed in this iOS repo because storage is JSON files + UserDefaults, not SQLite.
- If history continuity is desired, a client-side cache migration is needed (rename/rewrite keys and cached filenames from old session keys to new session keys).

### Provider SQLite question
Provider DB schema/migrations cannot be confirmed from this repository because provider TypeScript/DB code is not present here (see Q1 scope evidence).
