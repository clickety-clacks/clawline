# T1465 Padding Regression Provenance Matrix

Date: 2026-06-27
Ticket: T1465
Branch: clawline-t1465-notification-bubble-padding-regression
Current HEAD / Ansible build 14503: aefcbd68da8a0b85e22746ebaee75637fe57771f

## Product Boundary

Source of truth: `/Users/mike/shared-workspace/clawline/specs/notification-authority.html`.

- D5: short notification bubbles shrink to content without excess bottom padding.
- P1-P8/P7: dock/peek is display state and must preserve notification geometry; keyboard/chat switching must not change peek geometry.
- D9: notification geometry must not create incoherent overlap.

T354/T1193 are adjacent ordinary/composer bubble padding work and are not sufficient proof for cross-chat notification D5.

## Current Ansible Evidence Classification

The referenced Ansible asset was found on TARS and copied locally for inspection:

- Remote: `/Users/mike/.openclaw/clawline-media/assets/a_3690253e-2747-492c-8da2-5dc6a266acc1`
- Local scratch copy: `scratch/t1465-provenance/ansible-current-a_3690253e.png`
- Dimensions: 1260 x 721

Visual classification: this screenshot is not a cross-chat notification bubble. It shows an ordinary green user message bubble:

- Header/avatar: `Y`, sender `You`, timestamp `just now`.
- Body text: `That was the ticket history. Not a single mention of what shaped the development of that ticket.`
- Right edge contains dock/peek-adjacent artifacts, but the bubble with the large blank lower area is the ordinary chat/message bubble surface.

Approximate screenshot measurement from the image:

- Green chat bubble frame: roughly 18 px to 635 px vertically, about 617 px tall.
- Visible text/header content ends around 290 px.
- Lower blank area inside the bubble is roughly 340 px.

Conclusion: the live Ansible evidence is ordinary chat-bubble height/padding near dock/peek, not notification D5 internal padding. T1465 should not be patched in `CrossChatNotificationBubbleView` from this screenshot alone.

## Notification D5 Matrix

This matrix is source-derived from `ios/Clawline/Clawline/Views/Chat/ChatView.swift`, with `ChatViewModel.swift` checked only for dock/peek state relevance. Dock/peek positioning changes the display state; in the notification code below it does not add an independent internal bottom padding path.

| Baseline | Commit | Notification short content path | Normal short bubble | Dock/peek-adjacent short bubble | Relevant changed files |
| --- | --- | --- | --- | --- | --- |
| `79981b2794` | Merge T307 current source | Bad: non-scrolling notification content applies `entriesBottomBreathingRoom = 8` | Content height + 8 pt bottom blank | Same internal +8 pt blank; dock state is not the cause | `ChatView.swift`, `ChatViewModel.swift`, `MessageBubbleUIKitView.swift` |
| `c834ed86` | Repair Catalyst dictation audio import | Good: `CrossChatNotificationEntrySurfaceGeometry.bottomBreathingRoom(entriesNeedScroll:)` exists and returns 0 for non-scroll | Shrinks to content | Preserved | no notification geometry change |
| `0e45df44e8^` | Bump T320 Ansible deploy build | Bad: non-scroll path still carries bottom breathing room | Content height + 8 pt bottom blank | Same internal +8 pt blank | prior `ChatView.swift` state |
| `0e45df44e8` | Remove duplicate notification measurement rendering | Still bad: duplicate measurement removed, but measured content still applies bottom breathing room | Content height + 8 pt bottom blank | Same internal +8 pt blank | `ChatView.swift` |
| `49a7b93845^` | Fix dismissed notification reappearance | Bad: same pre-repair measured content bottom breathing room | Content height + 8 pt bottom blank | Same internal +8 pt blank | prior `ChatView.swift` state |
| `49a7b93845` | Fix notification bubble bottom padding | First good: bottom breathing room moved behind `entriesNeedScroll` | Shrinks to content; non-scroll bottom blank 0 pt | Preserved; non-scroll bottom blank 0 pt | `ChatView.swift` |
| `da9ce3bddf^` | T1182 text link rules in notifications and full content | Good | Shrinks to content | Preserved | prior `ChatView.swift` state |
| `da9ce3bddf` | Fix T1183 notification height caps | Good; changes height cap constants, not non-scroll padding | Shrinks to content | Preserved | `ChatView.swift` |
| `cb73b2d7bb^` | Fix T1205 notification markdown render stall | Good | Shrinks to content | Preserved | prior `ChatView.swift` state |
| `cb73b2d7bb` | Move notification rendering out of layout | Good; render cache/refactor preserves D5 padding repair | Shrinks to content | Preserved | `ChatView.swift` |
| `29139ac27d^` | Merge commit `05f8a8d...` | Good | Shrinks to content | Preserved | prior `ChatView.swift` state |
| `29139ac27d` | Clarify notification typography bump | Good; refactor only names the +2 typography bump | Shrinks to content | Preserved | `ChatView.swift` |
| `aefcbd68` | Bump Clawline build for T1419 deploy | Good in notification source path | Shrinks to content by source path | Preserved by source path | no notification D5 regression source found |

Notification D5 provenance conclusion:

- First bad in the requested notification history is already present before `49a7b93845`.
- First good is `49a7b938459e8d8fc29ce355984322baed5ce428`.
- Current `aefcbd68` still contains the `49a7b93845` notification D5 repair.
- The requested current screenshot does not prove a notification-bubble regression.

## Ordinary Chat Bubble Provenance Lane

Because the Ansible asset is an ordinary green user message bubble, the relevant changed files are outside the notification matrix:

- Primary observed surface: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift`
- Secondary sizing path: `ios/Clawline/Clawline/Views/Chat/BubbleSizingV2.swift`
- Dock/peek state remains contextual, but `ChatViewModel.swift` is not the surface that creates the blank lower area.

Relevant commits after the requested notification baselines:

| Commit | Title | Observed risk for green chat bubble blank lower area |
| --- | --- | --- |
| `5318e56f8d` / `994aaa5650` | T1193 fix bubble reuse padding regression | Repairs identity reuse by including session key; reduces stale reuse risk, not a first-bad for the photographed blank space. |
| `98231aa9d1` / `3db826d543` | T1193 tighten message bubble padding | Changes stack spacing 10 -> 6; cannot create a 300+ px lower blank area by itself. |
| `07c1497c7c` | Integrate T1193 bubble padding repair | Splits top/bottom padding and changes link preview cap calculation; relevant to ordinary bubble padding but not enough to explain the photographed very tall empty body. |
| `c6ef8f7fdf` | Fix text bubble reconfigure layout churn | Strongest first-bad candidate for the observed surface. Adds `dynamicContentReuseKey` and an early-return `applyReusedDynamicContentChrome(...)` path that reapplies width/chrome/sizing without rebuilding dynamic content. If the supplied `bubbleSizingV2.measurement.outerScrollViewportHeight` is stale or dock-context-sized, a short text bubble can keep a large viewport height while content remains short. |
| `f1ca6bee03` | Fix bubble sizing measurement cache churn | Adjusts measurement cache identity to ignore live viewport fields except via height-policy fingerprint. Relevant follow-up, but current non-scroll text bubbles still apply `state.measurement.outerScrollViewportHeight` directly in `MessageBubbleUIKitView.applyBubbleSizingV2`. |

Observed ordinary chat-bubble first-bad/window conclusion:

- The requested notification D5 commit pairs do not contain the first-bad for the photographed Ansible issue.
- The best source window for the photographed ordinary chat bubble is `07c1497c7c..c6ef8f7fdf`, with `c6ef8f7fdf` the strongest concrete first-bad candidate because it introduced a same-message dynamic-content reuse fast path for textual bubbles.
- Files that could introduce the photographed padding/height are `MessageBubbleUIKitView.swift` and `BubbleSizingV2.swift`, not the notification entry bottom-breathing-room code in `ChatView.swift`.

## Engram

Engram query used:

```bash
engram explain ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:945-989
```

The result returned multiple historical sessions for the dynamic-content wrapper / outer-scroll setup, including sessions touching `MessageBubbleUIKitView.swift`, `ChatView.swift`, `LinkCardUIKitView.swift`, and `LinkPreviewView.swift`. It confirmed this is a heavily revised ordinary-bubble sizing area and influenced the decision to inspect the ordinary message-bubble lane instead of patching notification D5.

## Provenance Decision

Do not patch notification D5 from the current Ansible asset. Current source keeps the known notification D5 repair, and the asset shows an ordinary chat bubble. The next implementation pass should target a minimal ordinary message-bubble sizing fix only if a local reproduction confirms `c6ef8f7fdf`/`BubbleSizingV2` preserves a stale `outerScrollViewportHeight` near dock/peek.
