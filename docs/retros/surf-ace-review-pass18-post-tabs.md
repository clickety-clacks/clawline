# Surf Ace Spec — Adversarial Review Pass 18 (Post-Tab Model)

**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Review date:** 2026-03-04  
**Reviewer:** CLU (subagent, adversarial pass)  
**Context:** Tab model pass added tabs as first-class topology across §2a, §3.1.1, §6.1.1, §6.2, §7.3, §10, §13.2, §14.3, §A.13. Prior pass added §1 and removed historical language. Prior-prior pass added pane op schemas.

---

## Verdict: **REAL ISSUES** (7 real issues + 6 nits)

---

## Real Issues

### ISSUE 1 — `content.clear` has no tab targeting (§6.5 + §10 ContentClearRequest)

**Problem:** `content.clear` clears "current content" and carries only `revision`. No `sessionId`, no `paneId`. In a multi-tab pane (e.g. Chat A and Chat B both have tabs), which tab does `content.clear` target? The prose says nothing. The schema (`ContentClearRequest`) only has `revision` in its payload. §6.2 explicitly added `sessionId` to `content.set` for tab routing — but the same logic applies to `content.clear`. Without a session anchor, the surface cannot know which tab's content to clear.

**Contrast:** `content.set` added `sessionId` as required (§6.2 rule 5 and ContentSetRequest schema). `content.clear` was not updated in parallel.

**Impact:** Implementors of the surface will have to guess. If they clear "the active/focused tab" that may clobber another session's visible content. If they clear "all tabs in the pane" that's worse. If they clear "the calling session's tab" there's no wire field to identify the session.

**Proposed fix:** Add `sessionId` as a required field to `content.clear` prose (§6.5 rule 1.5) and to `ContentClearRequest.payload` schema in §10, analogous to `content.set`. Clarify that `content.clear` targets the calling session's tab in the target pane (consistent with the tab model's "each session owns its own tab" principle). Similarly, `ContentClearRequest` should accept optional `paneId` (default `root`) once the pane gap (Issue 7) is addressed.

---

### ISSUE 2 — sessionId injection mechanism is undocumented (§6.2 + §14.1 + §14.3)

**Problem:** §6.2 states: "`sessionId` is a required field on `content.set` requests." §14.3 `surf_ace_push` shows no `sessionId` parameter — CLU doesn't pass it. The intent is that the provider injects the calling session's ID automatically. But nowhere in the spec is it documented:

1. What is the source of `sessionId` at the provider layer? (Clawline session context? Tool dispatch metadata?)
2. Does `sessionId` in the wire schema (`^sa_[A-Za-z0-9._:-]{8,128}$`) correspond 1:1 with the Clawline session identifier, or is it a derived/mapped value?
3. Is the injection responsibility on the provider's `surf_ace_push` tool handler specifically, or a middleware layer?

The `TabId` schema says tabId is "derived from sessionId" but the upstream question of where `sessionId` itself comes from at the wire layer is not answered in any section.

**Impact:** Surface implementors know they receive `sessionId` for routing. Provider implementors know they must inject it. But neither knows the contract between the Clawline session ID namespace and the wire `SessionId` type, or where in the provider codebase the mapping happens.

**Proposed fix:** Add a sentence to §6.2 or §14.1 explaining: "The provider injects `sessionId` from the tool invocation context — specifically, the Clawline session ID of the CLU session that called `surf_ace_push`. The `SessionId` wire type (`sa_` prefixed) is a stable provider-assigned identifier derived from the Clawline session key and maintained for the lifetime of the provider process. See §14.1 for provider session lifecycle." (Or specify the actual mapping if it's 1:1.)

---

### ISSUE 3 — Tab switch mid-annotation is unspecified (§6.10 + §6.1.1 tab events)

**Problem:** §6.10 defines annotation mode as a surface-level UX lock. §6.1.1 defines `event.tab_focused` (user switches to a different tab within a pane). The interaction between these two is completely unspecified:

- Is annotation mode per-tab or per-pane? (If per-pane, tab switching mid-annotation doesn't change annotation mode. If per-tab, switching away exits annotation mode on the old tab.)
- When the user switches from Tab A to Tab B while Tab A has an open live annotation frame, what happens to Tab A's live dirty channel? Does the frame get finalized? Does it stay open?
- Where do new strokes go after a tab switch — to the newly focused tab, or is annotation mode exited entirely?
- Does `event.tab_focused` fire before or after annotation mode exits (if it exits)?

§13.2 says the annotation buffer is per-tab and the frame finalization model says "When annotation begins in a **different context**, provider finalizes the previous context frame." A tab switch is conceptually a context switch, but the spec never says this explicitly.

**Impact:** Surface UI implementors, provider implementors, and CLU behavior are all affected. Without a clear answer, two surfaces can implement this differently, breaking interop expectations.

**Proposed fix:** Add a subsection to §6.1.1 or §6.10 covering: "Tab switch during active annotation: If the user switches tabs while annotation mode is active (an open live frame exists), annotation mode exits on the departing tab. The provider finalizes the departing tab's open context frame (Channel B finalization per §13.2 lifecycle rule 4 analog: tab-switch is treated as a context switch). The new tab starts without an active annotation frame. `event.tab_focused` is emitted after the tab switch is complete; annotation mode on the new tab is inactive until the user re-engages."

---

### ISSUE 4 — `pane.close` does not specify tab teardown order or `event.tab_removed` emission (§6.1.1)

**Problem:** `pane.close` prose says: "Content and annotation state for the closed pane are discarded." Surface emits `event.pane_removed`. Full stop.

What it doesn't say:
1. Are all tabs in the pane closed first (per-tab cleanup before pane removal)?
2. Does `event.tab_removed` fire for each tab in the pane, or only `event.pane_removed`?
3. Is the tab teardown order specified (e.g., non-focused tabs before focused tab)?
4. Do tab annotation buffers (live dirty + closed frames) get discarded on pane close, or should they be drained first?

This is a real gap: if a CLU session is actively annotating in a tab of the closing pane, it may be waiting for annotation buffers that will never arrive if the pane is silently torn down without per-tab `event.tab_removed` events.

**Contrast:** `tab.close` is well-specified — it emits `event.tab_removed`, reports `closedFramesDiscarded`, and defines what happens to the focused tab. `pane.close` should reference or mirror this behavior for each of its tabs.

**Proposed fix:** Add to `pane.close` behavior: "Before emitting `event.pane_removed`, the surface MUST close all tabs within the pane (as if `tab.close` were called for each), emitting `event.tab_removed` for each tab in the pane. `closedFramesDiscarded` in the `pane.close` response is the sum of discarded closed frames across all tabs. Tab close events fire in surface-defined order; all `event.tab_removed` events are emitted before `event.pane_removed`."

---

### ISSUE 5 — §7.3 event audit table is missing all pane lifecycle events

**Problem:** §7.3 was updated to include all three tab lifecycle events (`tab_created`, `tab_removed`, `tab_focused`). But the four pane lifecycle events (`pane_created`, `pane_removed`, `pane_focused`, `pane_renamed`) are completely absent from the audit table.

§6.1.1 says these events "are always-on (not profile-gated), analogous to `event.surface_appeared`/`event.surface_removed`." The surface events appear in §7.3. The pane events do not.

**Impact:** The §7.3 table is supposed to be the authoritative audit of all events — "Deep vs Shallow." Missing four entries breaks that contract. Implementors relying on §7.3 for a complete event inventory will miss the pane events.

**Proposed fix:** Add four rows to the §7.3 table:

| Event | Classification | Default | Rationale |
|---|---|---|---|
| `event.pane_created` | Lifecycle — **not profile-gated** | Always | Emitted when a new pane is created (split or standalone). Always active regardless of `eventProfile`. Does NOT appear in `pair.response.eventConfig.activeEvents`. |
| `event.pane_removed` | Lifecycle — **not profile-gated** | Always | Emitted when a pane is closed. Always active. Does NOT appear in `activeEvents`. |
| `event.pane_focused` | Lifecycle — **not profile-gated** | Always | Emitted when a pane receives focus. Always active. Does NOT appear in `activeEvents`. |
| `event.pane_renamed` | Lifecycle — **not profile-gated** | Always | Emitted when a pane name changes. Always active. Does NOT appear in `activeEvents`. |

---

### ISSUE 6 — Revision counter scope is ambiguous with panes and tabs (§5.4)

**Problem:** §5.4 says: "Mutating content operations (`content.set`, `content.append`, `content.patch`, `content.clear`) carry monotonic `revision`." No mention of whether revision is global per surface, per pane, or per tab.

With multiple panes (each with independent content) and multiple tabs per pane (each with independent content), a single global revision counter makes no sense — two independent content items in different panes would collide. But revision scope is never stated.

The `pair.response` schema includes `state.currentRevision` (singular), suggesting global-per-surface scope. But the `panes.list` response doesn't include per-pane revision, and there's no `tab.list` response field for per-tab revision.

**Specific ambiguities:**
- If Session A pushes to pane_0 (revision 3 → 4) and Session B pushes to pane_1 (revision 3 → 4), whose revision counter advances?
- When `pair.response` returns `state.currentRevision: 7`, which pane/tab's revision is this?
- Can `content.append` use revision 5 on pane_0 if pane_1 is at revision 5?

**Proposed fix:** Explicitly state in §5.4: "Revision is scoped per tab (`{surfaceId, paneId, tabId}`). Each tab maintains its own independent monotonic revision counter starting at 0. `pair.response.state.currentRevision` reflects the revision of the root pane's default tab (or the most recently active pane's active tab) for backward compatibility; `panes.list` and `tab.list` responses expose per-tab revision when Phase 1 pane targeting is complete." (Or clarify the actual intended scope if different.)

---

### ISSUE 7 — Wire-level `paneId` gap in content operation schemas undocumented at wire layer (§10 schemas + §6.2–6.5)

**Problem:** §14.3 explicitly acknowledges: "Pane note: pane selector is currently omitted from v1 tool signatures in this document; Phase 1 completion requires adding optional `paneId` (default `root`) to all screen-scoped tools." This note covers CLU tools only.

The wire protocol schemas in §10 (`ContentSetRequest`, `ContentAppendRequest`, `ContentPatchRequest`, `ContentClearRequest`) also lack `paneId` — but there is no equivalent note in §10 or §6.2–6.5 calling this out as a known gap requiring Phase 1 completion.

An implementor reading §6.1.1 (which introduces multi-pane routing and states "all screen-scoped operations target `{surfaceId, paneId}`") then reading §6.2 (`content.set` description) and §10 (`ContentSetRequest` schema) will find no `paneId` and no explanation. They'll wonder: is this intentional (omitted by design for Phase 1)? Or is it a bug in the spec?

The CLU tool layer acknowledgment doesn't propagate to the wire layer.

**Proposed fix:** Add a note to the `ContentSetRequest`, `ContentAppendRequest`, `ContentPatchRequest`, and `ContentClearRequest` schemas in §10, and to the corresponding prose in §6.2–6.5: "Phase 1 note: `paneId` (optional, default `root`) is not yet in this schema. It will be added as part of Phase 1 pane-targeting completion. Until then, all content operations target `paneId="root"`. See §14.3 pane note." Mirror the §14.3 language at the wire layer.

---

## Nits

### NIT 1 — `TabId` derivation underdescribed (§3.1.1 rule 10, §10 TabId schema)

§3.1.1 rule 10: "tabId format: derived from sessionId (e.g., a stable short hash or the full sessionId string)." The schema says the same.

The "surface-defined" opaqueness is fine. But the spec should state the required properties explicitly: (a) stable within a tab's lifetime, (b) unique within a pane (enforces the one-tab-per-session-per-pane rule), (c) opaque to providers. As written, it's implied but not stated. An implementor might use a collision-prone hash and not realize uniqueness-within-pane is required.

**Proposed fix:** Add to §3.1.1 rule 10: "Required properties: (1) stable for the tab's lifetime, (2) unique within its containing pane (enforces one-tab-per-session-per-pane), (3) treated as opaque by providers — surface is free to use any derivation scheme."

---

### NIT 2 — Inline date in §A.13 prose

§A.13 contains: "**Resolution (2026-03-04):**" — an inline date in prose. The cleanup pass removed historical language elsewhere; this one was missed.

**Proposed fix:** Remove the date. Change to: "**Resolution:** Tab model adopted as the v1 resolution."

---

### NIT 3 — Appendix A intro blanket "deferred" language applies to resolved entries

The Appendix A header says: "These questions are deferred pending further thought... Do not implement against these areas until they are resolved."

§A.13 is explicitly marked "(Resolved)." The blanket intro incorrectly characterizes it as deferred.

**Proposed fix:** Change the Appendix A intro to: "This appendix records design decisions and deferred open questions. Entries marked (Resolved) are finalized; entries without that marker are still open and should not be implemented against until resolved."

---

### NIT 4 — `ProfileControlledEventType` description is incomplete (§10)

The `ProfileControlledEventType` schema description says: "Excludes lifecycle events (`event.surface_appeared`, `event.surface_removed`) which are always active and never appear in `activeEvents`."

It should also exclude pane and tab lifecycle events, which are equally always-on. The description only mentions the surface events — a reader won't know pane/tab events are also excluded.

**Proposed fix:** Update description to: "Excludes all lifecycle events — `event.surface_appeared`, `event.surface_removed`, `event.pane_created`, `event.pane_removed`, `event.pane_focused`, `event.pane_renamed`, `event.tab_created`, `event.tab_removed`, `event.tab_focused` — which are always active regardless of profile and never appear in `activeEvents`."

---

### NIT 5 — Content-scoped events carry no paneId/tabId; correlation via contentId is implied but unstated (§10 event schemas)

`DrawingFlushEvent`, `TapEvent`, `SelectionEvent`, `PageEvent`, `NavigationEvent`, `ScrollEvent` all carry `contentId` and `revision` but no `paneId` or `tabId`. In a multi-pane/multi-tab surface, the provider must correlate events to pane/tab via its internal `contentId → {paneId, tabId}` mapping.

This correlation path works (contentId is globally unique per push), but it's never specified. Implementors may not realize this mapping is how pane/tab attribution for events is derived.

**Proposed fix:** Add a sentence to §13.2 or §6.1.1: "Content-scoped events (`event.drawing_flush`, `event.tap`, etc.) carry `contentId` but not `paneId` or `tabId`. The provider resolves the originating pane and tab by looking up `contentId` in its content→topology map maintained from `content.set` responses. This mapping is the authoritative pane/tab attribution path for all content-scoped events."

---

### NIT 6 — §12 Implementation Readiness Checks has no tab-specific checks

§2.3 Phase 1 done checklist has 10 items including tab-specific checks (items 9–10). §12 has 14 readiness checks and none reference tabs. Specifically missing: verifying tab auto-creation on first push, `event.tab_created`/`event.tab_removed` fire correctly, tab isolation (Session A and Session B don't overwrite each other), and `tab.list`/`tab.close` are operable.

**Proposed fix:** Add to §12: "15. Tab model is active: `content.set` from a new session auto-creates a tab; `event.tab_created` fires. `content.set` from the same session updates in-place (no new tab). Two sessions pushing to the same pane each get independent tabs. `tab.list` returns correct per-session tab entries. `tab.close` discards tab state and emits `event.tab_removed`. `surf_ace_push` response includes correct `tabId`. Session A and Session B content coexist without overwriting."

---

## Summary Table

| # | Area | Severity | One-liner |
|---|---|---|---|
| 1 | §6.5 + §10 ContentClearRequest | **REAL** | `content.clear` has no `sessionId` — can't target the calling session's tab |
| 2 | §6.2 + §14.1 + §14.3 | **REAL** | Provider `sessionId` injection source is undocumented at wire+provider level |
| 3 | §6.10 + §6.1.1 | **REAL** | Tab switch mid-annotation: behavior completely unspecified |
| 4 | §6.1.1 pane.close | **REAL** | `pane.close` silent on tab teardown order and `event.tab_removed` per tab |
| 5 | §7.3 | **REAL** | Four pane lifecycle events absent from event audit table |
| 6 | §5.4 | **REAL** | Revision counter scope undefined with panes/tabs |
| 7 | §10 + §6.2–6.5 | **REAL** | Wire-level `paneId` gap in content schemas has no note (only CLU layer does) |
| N1 | §3.1.1 rule 10 / TabId | NIT | tabId uniqueness-within-pane not stated explicitly |
| N2 | §A.13 | NIT | Inline date "2026-03-04" in resolved entry prose |
| N3 | Appendix A intro | NIT | Blanket "deferred/do not implement" applies to resolved §A.13 |
| N4 | §10 ProfileControlledEventType | NIT | Description lists only surface events; pane/tab exclusions unstated |
| N5 | §10 event schemas | NIT | contentId→{paneId,tabId} correlation path for events not documented |
| N6 | §12 | NIT | No tab-specific implementation readiness checks |

---

## Addressing the 11 Checklist Items

1. **Tab completeness:** `content.clear` (§6.5) is the main gap — it never got `sessionId` treatment. `content.append`/`content.patch` are implicitly OK (contentId is unique enough for routing). See Issue 1.

2. **sessionId threading:** The provider injection path is undocumented. CLU doesn't pass it; the provider must inject it from the tool invocation context. Where/how is not specified. See Issue 2.

3. **tabId consistency:** Derivation is intentionally surface-defined and opaque. NIT-level: uniqueness-within-pane should be stated explicitly. See Nit 1.

4. **surf_ace_read tab scoping:** Correctly handled. §13.2 and §14.3 both say session-keyed = implicit tabId. No `tabId` parameter needed or accepted. The paneId gap is acknowledged (Phase 1 known gap). This check passes with the paneId caveat.

5. **event.tab_focused vs annotation mode:** Entirely unspecified. Real issue. See Issue 3.

6. **pane.close + tabs:** `event.tab_removed` per tab not specified; teardown order not specified; annotation buffer fate not specified. See Issue 4.

7. **Cross-reference integrity:** All tested cross-references resolve correctly after heading renames. §3.1.1, §6.1.1, §A.13 are all reachable and correctly named. No broken references found.

8. **§10 schema completeness:** oneOf is complete (all tab types present). SessionId is in ContentSetRequest. TabId is in TabCloseRequest, TabCreatedEvent, TabRemovedEvent, TabFocusedEvent, TabListResponse. EventType enum includes all 7 tab/pane events. ErrorResponse.op includes `tab.list` and `tab.close`. ProfileControlledEventType correctly excludes lifecycle events (description incomplete — Nit 4). Pane/tab event schemas are all present.

9. **§7.3 event audit table:** Tab events correctly added. Pane lifecycle events entirely missing. Real issue. See Issue 5.

10. **Historical/changelog language:** One inline date missed: §A.13 "Resolution (2026-03-04)". See Nit 2. No other "replaces", "supersedes", "per Flynn", or stray dates found in prose.

11. **§A.13 closure:** Reads as resolved — description and resolution both present. The "(Resolved)" tag in the heading is clear. The problem is the appendix intro blanket "do not implement" language that covers A.13 by accident. See Nit 3.
