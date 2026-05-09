# T163 Popup Architecture

## Goal

Redesign the stream popup open/close path so the popup, track picker, and popup search-focus flows all route through one authority, with one visible control owning the presentation anchor.

This redesign must:

- preserve the existing `uiSelectedSessionKey` vs `engineActiveSessionKey` split
- remove the current split-state popup bug class where tapping the pager/status indicator can fail to open the popup
- avoid any Mac/Catalyst-specific fork unless later evidence requires one

## Non-Goals

- Do not change the stream-switch architecture that separates UI intent from engine activation.
- Do not redesign popup visuals, reorder behavior, rename/delete behavior, or track-picker product behavior.
- Do not introduce separate popup implementations by platform.
- Do not move popup/track presentation state into transport or provider layers.

## Problem Summary

Today the popup route is fragmented:

- popup presentation is owned by local `ChatView` booleans
- popup dismissal can be driven by parent view logic, child view binding writes, or system dismissal
- keyboard command open uses a different path from tap open
- track flow is coordinated by closing one presentation surface, yielding, then opening another
- the tapped page-dots/status control is not the same view that owns the popover anchor

This is an architecture problem, not just one bad tap target. The current design allows multiple layers to answer the same product-state question: "what popup-related surface is currently presented?" That violates SSOT.

## Target Architecture

### 1. Keep the two-key stream-switch model

The existing stream-switch split remains unchanged:

- `uiSelectedSessionKey`: immediate pager/UI intent
- `engineActiveSessionKey`: delayed heavy engine activation

This spec does not collapse those keys. Popup routing is a separate concern and gets its own owner.

### 2. Introduce a single popup-route owner

Add one `@MainActor` popup-route owner in the chat UI layer.

Recommended shape:

- `StreamPopupRouteController` or equivalent
- owned once by `ChatView`
- the only mutable authority for popup-route state

Its single source of truth is one route enum:

```swift
enum StreamPopupRoute: Equatable {
    case closed
    case popup(searchFocus: StreamPopupSearchFocus)
    case trackPicker
}

enum StreamPopupSearchFocus: Equatable {
    case none
    case request(id: Int)
}
```

Equivalent shapes are acceptable if they preserve the same invariant: one mutable route value, one owner, one mutation seam.

### 3. Popup route intent seam

All popup-related writes must go through route-owner methods. No direct bool writes from parent or child views.

Required mutation seam:

- `openPopup(focusSearch: Bool)`
- `closePopup()`
- `presentTrackPicker()`
- `dismissTrackPicker()`
- `consumeSearchFocusRequest()` or equivalent one-shot handling

Forbidden after this redesign:

- direct writes to `isStreamManagerPopoverPresented`
- direct writes to `isTrackPickerPresented`
- child-view dismissal via raw `Binding<Bool>`
- separate ad hoc search-focus side-channel booleans

### 4. The tapped control must own the presentation anchor

The visible page-dots/status control and the presentation anchor must be the same rendered control.

Required invariant:

- the exact view that receives the user tap also owns the `.popover` presentation modifier

That means the redesign must remove the current pattern where:

- `StreamPageDotsView` handles the tap
- a separate invisible overlay owns the popover anchor

On iOS/iPadOS, if the control is hosted through the pinned-container UIKit bridge, the pinned-container host must mount one popup-trigger host that contains both:

- the visible page-dots control
- the popover modifier bound to popup-route state

The bridge may still exist. The split between tap target and anchor must not.

### 5. One authority for popup, track picker, and search-focus routing

The route owner answers all three questions:

- is the popup visible?
- is the track picker visible?
- should popup search be focused on this open cycle?

Routing rules:

1. Tap on page dots/status control:
   - send `openPopup(focusSearch: false)`
2. Keyboard/menu open command:
   - send `openPopup(focusSearch: true)`
3. Popup row selection:
   - send `closePopup()`
   - trigger stream selection through the existing stream-switch seam
4. Track button inside popup:
   - send `presentTrackPicker()`
5. Track picker dismiss:
   - send `closePopup()` or stay closed unless a future spec explicitly requires reopen

The key rule is that surface transitions are expressed as route mutations, not as "close this bool, yield, open that bool" choreography.

### 6. Child views emit intents; they do not own route state

`StreamManagerSheet` and track-picker views must become intent emitters only.

They may send callbacks such as:

- `onSelectStream(sessionKey)`
- `onRequestTrackPicker()`
- `onDismissRequested()`

They must not:

- mutate route bindings directly
- own fallback popup booleans
- schedule presentation-order fixes with `Task.yield()` to coordinate parent presentation state

`Task.yield()` may remain inside unrelated view-local behavior if required, but not as the core popup-route coordination mechanism.

### 7. Search focus is part of the popup route transaction

Search focus should no longer be represented by separate long-lived booleans in `ChatView`.

Instead:

- search-focus intent is attached to `openPopup`
- popup content consumes that request once during the active popup presentation cycle
- closing the popup clears the outstanding request as part of route teardown

This makes tap-open and command-open variants different inputs to the same route seam instead of separate systems.

## Implementation Shape

### Preferred ownership boundary

`ChatView` remains the owner of popup presentation because this is view-routing state, not domain state.

The redesign should not move popup-route ownership into `ChatViewModel` unless implementation proves SwiftUI presentation APIs require it. The default design is:

- `ChatViewModel` owns stream/domain state
- popup-route controller owns popup/track/search presentation state
- `ChatView` composes the two

### Preferred presentation composition

Create one compositional wrapper around the page-dots control, for example:

- `StreamPopupTrigger`

Responsibilities:

- render the visible dots/status control
- attach the popover modifier directly to that control
- derive its presentation binding from the popup-route owner
- forward popup intents upward

This wrapper becomes the only place where popup-route state meets the presentation API.

## Migration Plan

### Step 1. Add route owner without changing product behavior

Introduce the popup-route owner and route enum alongside the current booleans.

Temporary rule during migration:

- all new popup opens/closes are mirrored through the route owner
- existing booleans remain only as adapter state

This step is complete when route transitions can be observed in one place.

### Step 2. Move all open paths onto the route seam

Convert:

- tap open
- keyboard/menu command open
- popup dismiss requests
- track-picker present/dismiss

to route-owner methods.

After this step, no call site should write popup-related booleans directly.

### Step 3. Re-anchor presentation to the visible control

Replace the invisible overlay popover anchor with a trigger component that owns both:

- visible control
- popover modifier

For iOS pinned-container hosting, mount that trigger component directly in the pinned host path.

### Step 4. Convert child popup views from binding writers to intent emitters

Remove raw route bindings from `StreamManagerSheet` except where SwiftUI presentation APIs absolutely require a derived read-only binding adapter.

Popup child actions become callbacks into the route owner and existing stream-switch seam.

### Step 5. Remove legacy popup booleans and search-focus side channels

Delete the old split popup state once all call sites have migrated:

- `isStreamManagerPopoverPresented`
- `isTrackPickerPresented`
- popup-specific search-focus booleans/counters that duplicate route state

At the end of this step, route state lives only in the popup-route owner.

### Step 6. Add regression coverage around the invariant

Add targeted tests for:

- tap on visible page-dots/status control presents popup
- keyboard/menu open presents popup and focuses search
- selecting a stream closes popup and still routes stream change correctly
- track button transitions from popup route to track-picker route through the same owner
- dismissing popup or track picker leaves route owner in `.closed`

The tests should verify route transitions and presentation behavior, not just helper method output.

## Acceptance Checks

1. There is exactly one popup-route owner for popup/track/search presentation state.
2. The visible tapped page-dots/status control is the same control that owns the popover anchor.
3. No child view directly mutates popup presentation booleans.
4. Tap open and keyboard/menu open use the same route seam.
5. Track picker transitions use the same route seam.
6. The existing `uiSelectedSessionKey` vs `engineActiveSessionKey` split remains intact.
7. No Mac/Catalyst-specific popup fork is introduced.

## Risks

- SwiftUI popover APIs may still require a small adapter binding. That is acceptable only if the adapter is derived from the single route owner and does not become a second mutable authority.
- The pinned-container bridge may still need sizing or hit-test fixes. Those are acceptable only if anchor ownership stays unified in one hosted trigger component.

## Open Questions

1. Should the popup reopen automatically after track-picker dismissal, or remain closed? This spec keeps it closed unless product direction changes.
2. If future flows add another popup-related surface, should the route enum absorb it or should that surface live outside this owner? Default: absorb it if it competes for the same page-dots/status control affordance.

## Implementation Handoff

Scope:

- popup-route ownership
- anchor ownership
- intent routing for popup/track/search
- migration off split popup booleans

Out of scope:

- stream-switch model changes
- popup visual redesign
- platform-specific fork

Primary invariant to preserve:

- one owner answers "which popup-related surface is presented right now?"

Primary invariant to add:

- the visible tapped control and the presentation anchor are the same control
