# T1460 Siri iOS 27 Messages App Schema Proof Slice

Date: 2026-06-27
Branch/worktree: `clawline-t1460-siri-schema-proof` at `/Users/mike/src/worktrees/clawline-t1460-siri-schema-proof`

## Source Inputs

- Tracker T1460 read through Janus/Tracker REST. A constrained `janus-ticket-context` read was attempted from a sibling Janus worktree because this Clawline worktree does not contain the helper; later review rerun hit `remote_fetch_failed` / `scp: Connection closed`, so live Janus REST readback is the durable ticket-state source for this report.
- T1414 recon: `/Users/mike/shared-workspace/clawline/specs/t1414-siri-voice-send-recon.html`.
- T1454 spike: `/Users/mike/shared-workspace/clawline/specs/t1454-siri-app-schema-implementation-spike.html` and `.json`.
- Apple docs lookup attempted with `sosumi search` for Messages App Schema and AppIntent authentication terms; the installed local doc index returned no matching iOS 27 schema pages.

## Environment Proof

- `xcodebuild -version`: Xcode 26.4.1, build 17E202.
- `xcrun --sdk iphoneos --show-sdk-version`: 26.4.
- `xcrun --sdk iphonesimulator --show-sdk-version`: 26.4.
- XcodeBuildMCP build/run gate observed in-session: Clawline app built and launched on iPhone 17 Pro iOS Simulator 26.4.1. No durable result bundle/log path was produced in this worktree.
- Focused source proof observed in-session: `ClawlineTests/ClawlineSiriSessionResolverTests` passed 4/4 on iPhone 17 Pro iOS Simulator 26.4.1. No durable result bundle/log path was produced in this worktree; later rerun was blocked by CoreSimulatorService access from the review sandbox.
- Serenity topology correction: `/Users/mike/shared-workspace/environment/environments.md` and `topology/network-topology.yaml` identify Serenity as the Xcode 27 host for Cyberbrain deploys/proofs. `ssh serenity` works as `mike`.
- Serenity active default Xcode is 26.6, but `/Applications/Xcode-beta.app` is Xcode 27.0 build 27A5209h with iOS SDK 27.0, iOS Simulator SDK 27.0, visionOS SDK 27.0, and visionOS Simulator SDK 27.0.

Eezo cannot compile or run iOS 27 Messages App Schema APIs. Serenity can attempt the Xcode 27 compile leg by setting `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Acceptance Matrix

| ID | Result | Evidence |
| --- | --- | --- |
| A1 | Cleanly rejected for the finite conversation-first proof slice | Serenity/Xcode 27 exposes the Messages schema symbols, but app metadata export rejects a small `@AppIntent(schema: .messages.sendMessage)` proof using a Clawline conversation destination. Xcode requires destination to be `MessagePerson`/Person, requires full send-message parameters (`attachments`, `links`, `locations`, `audioMessage`, `subject`, `scheduledDate`), and requires the result to return `[Schema<MessageEntity>]`. A follow-up `MessagePerson` probe still failed metadata export because `messages.messagePerson` requires `person`, `messages.message` requires the full message property set, attachments/links/locations must be nonoptional, and file parameters require UTType constraints. Building that honestly is full Messages-domain implementation, outside T1460. Build logs: Serenity `~/Library/Developer/XcodeBuildMCP/workspaces/clawline-t1460-proof-5b3818aadc2e/logs/build_sim_2026-06-27T06-41-08-978Z_pid85957_b832f7ad.log` and `build_sim_2026-06-27T06-43-28-134Z_pid86508_a8607bd0.log`. |
| A2 | Source proof added for fail-closed session resolution | `ClawlineSiriSessionResolver` resolves only exact session keys or one unambiguous display name; duplicate display names and unknown/empty destinations fail closed. Tests cover exact key, one display-name match, duplicates, and unknown input. |
| A3 | Blocked by compile/product-scope boundary | Serenity has Xcode 27, but no Siri phrase/device test can be product-faithfully run until Clawline has a compileable Messages-domain implementation. The finite proof slice stopped before full Messages-domain implementation. |
| A4 | Static product-path proof only | Existing normal path is `ProviderChatService.send(id:content:attachments:sessionKey:references:)`, which encodes `ClientMessagePayload` with `sessionKey` and waits for normal ack events. T1414/T1454 require future schema intent to call this path with an explicit resolved session key. This slice does not add a Siri-only provider endpoint. |
| A5 | Bounded by existing fallback timeouts, not measured for iOS 27 schema | Existing Siri sender uses 6s connect, 3s send, 3s ack timeouts. The proof-slice schema intent deliberately does not send; actual App Schema runtime budget still requires a Siri/App Intents runtime proof after full-send authorization. |
| A6 | Source proof added for wrong-chat risk | Resolver returns `.ambiguous` instead of selecting among duplicate display names and `.notFound` for empty/unknown destinations. No fallback to Main is added. |
| A7 | Preserved | Existing iOS 17 App Shortcut remains unchanged and is not promoted to the primary architecture. |

## Implementation-Owned Review

Review against T1414/T1454:

- Scope: finite proof slice only; no full Siri-send implementation, no provider changes, no deployment, no launchd changes.
- Schema claim: no compile success is claimed because current SDK is 26.4.
- Entity/session resolution: implemented only the product resolver over `StreamSession`; it uses `sessionKey` as routing authority and fails closed on ambiguity.
- Send path: no new provider path exists; proof points at the existing normal provider send/ack contract.
- Privacy: no transcript indexing, Spotlight indexing, or message-content storage added.
- Fallback: existing App Shortcuts remain fallback-only; no architecture promotion.

Owner review result: implementation-owned GPT-5.5 review cycle returned no blocking source findings for the T1460 proof slice. The only findings were proof-recording/documentation nits: attach durable build/test proof paths if available, and clarify ticket-context readback source. Review summary artifact: `scratch/t1460-gpt55-review-r1-summary-20260627.md`.

T1460 remains in Code Review because no protected transition proof rows were created for `Code Review -> Code Review Done`.

T1460 is no longer blocked by local eezo Xcode. Serenity/Xcode 27 proved the local spec assumption was too narrow: the send-message schema cannot be compiled as a small conversation-first send proof. Proceeding requires a product decision to model Clawline sessions as `messages.messagePerson`/Person destinations and implement the required Messages message/entity/parameter surface honestly, or to reject the Messages App Schema path for Clawline.

## Engram

Queried:

- `engram explain ios/Clawline/Clawline/Intents/SiriSendMessageIntent.swift:1-140`
- `engram explain ios/Clawline/Clawline/Models/SessionRegistry.swift:1-80`

Result: Siri intent provenance points to prior Siri-send work; SessionRegistry provenance points to multi-stream/session tracking work. This influenced the scope decision to add an independent resolver and avoid changing the existing fallback intent behavior.

Later GPT-5.5 review reran Engram against nearby source ranges, but the local Engram database could not be opened from that sandbox; that rerun did not change the review findings.
