# Multi-Stream Spec — Adversarial Review

Reviewer: subagent (spec review task)
Date: 2026-02-11
Spec reviewed: `multi-stream.md` (Draft)

---

## Executive Summary

The spec is well-structured and clearly thought through. The main risks are: (1) fork message history semantics are underspecified and will cause confusion during implementation, (2) the `treeVersion` optimistic concurrency model has gaps, (3) several protocol details won't survive contact with the real codebase, and (4) v1 scope is ambitious — fork+merge could be deferred without losing the core value of N-stream.

---

## 1. Protocol Correctness

### 1.1 `forkRefs` on messages: retrofit problem
§5.7.1 says "Parent source message gets anchored fork indicator metadata (`forkRefs`)." But `forkRefs` appears as a field on the **WS `message` payload** (§5.5.3). This means:

- **On replay**, the server must dynamically join `stream_forks` onto every replayed message to populate `forkRefs`. This is a query-time concern, not stored on the event. The spec doesn't say this explicitly — an implementer might try to mutate the stored event JSON, which would be destructive.
- **On live delivery**, when a fork is created *after* the source message was already delivered, how does the client learn the source message now has a `forkRefs`? The `stream_forked` event tells the client about the new stream, but doesn't tell the client to update an already-rendered message bubble. **The client must synthesize this** — the spec should state this explicitly.

**Recommendation:** Add a note that `forkRefs` is computed at replay time (never stored in the events table), and that on live `stream_forked`, the client must locally attach the fork ref to the matching cached message.

### 1.2 `treeVersion` optimistic concurrency: half-specified
§9.8 says stale commands return `409 tree_version_conflict`, but:

- **No request field for it.** None of the REST request bodies include a `treeVersion` field. How does the server know the client's version is stale? The client sends no version. This is a concurrency check with no mechanism.
- **Single-user system anyway.** Clawline is currently single-user-per-account. The main concurrency risk is client retry or multi-device, not multi-user races. Is optimistic concurrency worth the complexity in v1?

**Recommendation:** Either add `expectedTreeVersion` to mutation requests, or drop optimistic concurrency from v1 and just use idempotency keys (which are already specified).

### 1.3 Replay + `stream_snapshot` ordering ambiguity
§5.6 says: `auth_result` → `stream_snapshot` → replay messages. But:

- Replayed messages carry `sessionKey`. The client needs the snapshot *first* to map `sessionKey → streamId`. This ordering is correct. ✓
- **But**: what if a message's `sessionKey` doesn't match any stream in the snapshot (deleted stream, race condition)? §5.6.6 says "synthesize ghost archived stream." This is reasonable but **completely unspecified** — what `streamId`? what `displayName`? what `orderKey`? An implementer will have to invent this.

**Recommendation:** Specify the ghost stream synthesis: `streamId` derived deterministically from `sessionKey`, `displayName` = sessionKey suffix, appended to end of order.

### 1.4 `stream_snapshot` vs incremental: no catch-up mechanism
If the WS disconnects and reconnects, the client gets a fresh `stream_snapshot`. But between disconnect and reconnect, topology may have changed AND messages may have been sent to new streams the client doesn't know about. The replay will include those messages. This *should* work because snapshot comes before replay. ✓

However: **there's no mechanism for a connected client to request a snapshot refresh** if it suspects drift. Not critical for v1, but worth noting.

### 1.5 Auth negotiation for `multi_stream_v1`
§10.1 says the provider emits stream events "only when client advertises `multi_stream_v1`." But §5.5.4 says no new C2S message types. **How does the client advertise feature support?** The `auth` message from client presumably needs an additive field. This is unspecified.

**Recommendation:** Specify the client auth message additive field, e.g. `"features": ["multi_stream_v1"]`.

---

## 2. Migration Safety

### 2.1 Root stream `streamId` format
§5.2 says seed root stream nodes for main/dm/global. But what `streamId` do they get? The example in §5.3.1 shows `"st_root_main"` as a `parentStreamId` — but the schema says `streamId` pattern is `st_<uuidv4>`. `st_root_main` doesn't match the UUID pattern in the JSON schema (§7.4). **Contradiction.**

**Recommendation:** Either use real UUIDs for root streams (and reference them by lookup, not convention), or explicitly exempt root streams from the UUID pattern.

### 2.2 Session key for legacy `agent:main:main`
The global admin stream session key is `agent:main:main` — a 3-part key, not matching the `agent:*:clawline:*:*` 5-part pattern. §4.2 acknowledges this exists but the stream_nodes table has `UNIQUE(userId, sessionKey)`. What `userId` owns the global admin stream? Every admin user? One shared row? This affects both migration and runtime routing.

**Recommendation:** Clarify whether `agent:main:main` gets one stream_node row (shared) or one per admin user. If shared, the `userId` column semantics break.

### 2.3 Migration step 4: orphan detection
"For each historical message sessionKey not mapped to a stream node, create imported custom root stream." This is safe but: how does the migration discover all historical sessionKeys? It needs to `SELECT DISTINCT sessionKey FROM events` or from the messages table. The spec doesn't say which table to scan. Given the current schema, `events` seems right, but the implementer needs to know.

---

## 3. Implementation Feasibility

### 3.1 Fork "child gets parent history through sourceMessageId inclusive"
§5.7.1: "Child gets parent history through `sourceMessageId` inclusive." This is the **most underspecified critical behavior** in the entire spec.

- Does this mean messages are **copied** into the child stream's event history? If so, that's a massive data duplication problem and the events table needs new rows with the child's sessionKey.
- Or does the client **display** parent messages up to the fork point when viewing the child? If so, the client needs to fetch/replay from the parent stream up to that message, which is a cross-stream query the replay protocol doesn't support.
- Or is it just a **conceptual** statement and the fork origin bubble is the only UI manifestation?

This is the core semantic question of forking and it's hand-waved. An implementer cannot build this without guessing.

**Recommendation:** Explicitly state whether fork history is (a) copied, (b) virtually inherited via client-side cross-stream display, or (c) not displayed at all (just the origin bubble provides context). Each has radically different implementation cost.

### 3.2 Merge summary message: who generates it?
§5.4.6 offers an optional `merge-draft` endpoint. §5.4.7 requires a `summary` field in the merge request. But:

- If the user skips `merge-draft`, they must write the summary manually. Is there a UI for this? The stream manager (§6.4.2) has a "Merge" toolbar button but no merge flow is described — no summary editor, no confirmation dialog.
- The `merge-draft` endpoint says "provider-generated summary" — this implies the provider calls an LLM to summarize the fork's conversation. Is this in scope for v1? It's a significant feature (prompt engineering, token costs, latency).

**Recommendation:** Either descope `merge-draft` from v1 (manual summary only) or spec the LLM summarization behavior.

### 3.3 Order key: "sparse lexicographic keys"
§5.3.2 says use midpoint keys between neighbors. This is a well-known approach but:

- What alphabet? Base36? Base62? Fractional strings?
- "Rebalance only when no midpoint possible" — what triggers rebalance? What's the rebalance algorithm? This is a can of worms for edge cases (rapid sequential inserts).
- Why not just use integer ordering with gaps (e.g., 1000, 2000) and renumber on collision? Simpler, proven, and the stream count will never be large enough for perf to matter.

**Recommendation:** Specify the exact algorithm or simplify to integer ordering with renumber.

### 3.4 `streamSuffixId` derivation
§4.2: "`streamSuffixId` is deterministic from `streamId`, e.g. `s_2f6f1be9`." The `streamId` is `st_<uuidv4>` (36 chars). The suffix appears to be the first 8 hex chars of the UUID. But:

- Is it the first 8 chars? First segment? A hash?
- Collision probability with 8 hex chars across a user's streams is negligible, but the spec should state the exact derivation.
- What happens on collision? (Probably never, but spec should say.)

### 3.5 `events` table: `ALTER TABLE ADD COLUMN` with `NOT NULL DEFAULT`
§5.1.3 adds `eventType TEXT NOT NULL DEFAULT 'message'` to existing events table. SQLite supports this for `ALTER TABLE ADD COLUMN` **only if the default is a constant** (not an expression). `'message'` is a constant, so this works. ✓ But worth noting that existing rows will have the default applied at read time, not written — so a `SELECT` with `WHERE eventType = 'message'` will correctly match old rows. ✓

---

## 4. Scope: Is v1 Trying to Do Too Much?

**Yes.** The spec bundles three distinct features:

1. **N-stream** (dynamic named streams, page dots, stream manager) — core value, moderate complexity
2. **Fork** (fork from message, fork indicators, origin bubbles, fork identity chrome) — high complexity, novel UX
3. **Merge** (summary generation, merge metadata, archive/delete after merge) — high complexity, potentially needs LLM

Each of these is a major feature. Shipping all three simultaneously means:

- The PR will be enormous and hard to review
- Testing surface is multiplicative (N-stream × fork × merge interactions)
- If fork UX doesn't feel right, you can't ship N-stream independently

**Recommendation:** Phase v1 into:
- **v1a:** N-stream (create/rename/delete/reorder) + page dots + stream manager. This alone is valuable.
- **v1b:** Fork (from message, indicators, origin bubble, fork chrome). Builds on v1a.
- **v1c:** Merge. Builds on v1b.

The schema can be designed for all three upfront, but implementation/shipping can be phased.

---

## 5. Edge Cases the Spec Missed

### 5.1 Provider-initiated fork
§5.4.5 has `forkCreatedBy: "user" | "provider"`. When does the **provider** create a fork? What triggers it? There's no server-side fork initiation flow described. If this is for future use, mark it as reserved.

### 5.2 Deleting a stream with pending/unsent messages
Client may have queued messages for a stream that gets deleted (by another device, or by a race). What happens? The send will target a sessionKey that maps to a deleted stream. Does the server reject it? Silently accept it? The spec doesn't address message delivery to deleted streams.

### 5.3 Stream count limits
§5.8.3 mentions `streams.maxStreamsPerUser` config. Good. But the REST endpoints don't specify the error response when the limit is hit. Should be `429` or `409` with a specific code.

### 5.4 Renaming built-in streams
Can the user rename "Personal" or "Admin"? The spec doesn't restrict `PATCH` to custom streams only. Presumably built-in streams (rootKind = main/dm/global_dm) should have rename restrictions or at least defaults that can be restored.

### 5.5 Empty fork stream deletion
If a fork stream has no messages (user forked then changed their mind), can it be deleted? The spec says delete is leaf-only, which is fine. But should there be a simpler "cancel fork" flow that cleans up the fork ref from the parent message too?

### 5.6 Message ID format inconsistency
The spec uses `s_` prefix for message IDs (e.g., `"id": "s_..."`), and the JSON schema patterns use `^s_[0-9a-fA-F-]{36}$`. Is this the actual message ID format in the current codebase? If current message IDs don't match this pattern, the schema validation will break on existing data.

### 5.7 WebSocket broadcast scope
When a stream topology event fires, who receives it? All connected WS clients for that user? Only the client that made the REST call? The spec doesn't specify broadcast scope. For multi-device support, it should be all authenticated sessions for the user.

### 5.8 `stream_forked` event doesn't include `forkRefs` update
When a fork is created, the parent message needs its `forkRefs` updated. But `stream_forked` only contains the new child stream info, not an updated parent message. The client has to **infer** that the parent message's `forkRefs` should include this new fork. This works but is implicit — worth documenting.

### 5.9 No `stream_reordered` event
If stream ordering changes (drag-to-reorder in stream manager?), there's no dedicated event. `stream_updated` could carry a new `orderKey`, but only for one stream at a time. A bulk reorder would need N `stream_updated` events with intermediate `treeVersion` bumps. Clunky but workable for small N.

### 5.10 Merge of a stream that has children
§9.6 says delete rejects non-leaf. But merge? Can you merge a fork that itself has sub-forks? The spec says "direct child → direct parent only" but doesn't address whether the source must be a leaf. If a forked stream has its own forks, merging it would orphan or reparent the grandchildren. This needs a rule.

---

## 6. Minor Issues

- §5.3.1 example: `parentStreamId: "st_root_main"` doesn't match UUID format — use a real UUID or define root stream ID conventions.
- §5.4.4 DELETE response is `200` — should be `204` (no content) or the body should be documented as intentional.
- `stream_idempotency` table has no TTL/cleanup mechanism. Will grow unbounded.
- §6.1.1 Swift `StreamNode` uses `Date` for `createdAt/updatedAt` but wire format is epoch millis `Integer`. Codable will need a custom decoder — worth noting.
- The `features` array in `auth_result` (§5.5.2) includes `"multi_stream_v1"` but this is server-advertised. The client also needs to advertise support (see §1.5 above). Different direction, same field name — confusing.

---

## Summary of Critical Items

| # | Issue | Severity | Section |
|---|-------|----------|---------|
| 1 | Fork history semantics completely unspecified (copy vs virtual vs none) | **Blocker** | §5.7.1 |
| 2 | `treeVersion` concurrency check has no request-side mechanism | High | §9.8 |
| 3 | Client feature advertisement for `multi_stream_v1` unspecified | High | §10.1 |
| 4 | Root stream IDs contradict UUID pattern in schema | Medium | §5.3.1, §7.4 |
| 5 | `forkRefs` on messages: live update path undocumented | Medium | §5.5.3 |
| 6 | Merge of non-leaf fork undefined | Medium | §5.4.7 |
| 7 | `agent:main:main` ownership in stream_nodes unclear | Medium | §4.2 |
| 8 | Scope: fork+merge in v1 is risky | Advisory | §all |
