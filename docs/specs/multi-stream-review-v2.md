# Multi-Stream Spec v2 — Adversarial Review

Reviewer: subagent (spec review task)
Date: 2026-02-12
Spec reviewed: `multi-stream.md` (Phase A: N-Stream, revised)

---

## Executive Summary

The revised spec is dramatically cleaner than v1. Dropping fork/merge, treeVersion, and feature negotiation eliminated every previous blocker. What remains is a well-scoped CRUD feature. The issues below are real but none are blockers — they're ambiguities an implementer would have to resolve by guessing.

---

## 1. Issues That Would Slow Implementation

### 1.1 `UNIQUE(userId, orderIndex)` constraint + append-only = fragile

The schema has `UNIQUE(userId, orderIndex)` on `stream_sessions`. §5.7 says "on uniqueness conflict, recompute and retry once." But consider:

- Two concurrent `POST /api/streams` for the same user both compute `max(orderIndex)+1 = 4`. One commits, the other hits the unique constraint. Retry once means recompute to 5. Fine.
- But §5.4 says gaps are allowed after deletes and "do not renumber." Over time, `orderIndex` values become sparse (0, 1, 4, 7). This is fine for ordering but the unique constraint adds no value beyond ordering — and it creates a concurrency hazard for no benefit.

**Recommendation:** Drop the `UNIQUE(userId, orderIndex)` constraint. The index `idx_stream_sessions_user_order` already provides fast ordered queries. The unique constraint only creates conflict surface. If ordering integrity matters, enforce it at the application layer.

### 1.2 `events.sessionKey` backfill: "parsing stored message event payloads"

§5.2 step 6 says to backfill `events.sessionKey` by "parsing stored message event payloads." This implies the session key is embedded somewhere in the JSON blob stored in the events table. But:

- What field? Where in the payload? The implementer needs to know the current event storage format.
- What if some events don't have it? (e.g., system events, old format events)
- Is this a best-effort backfill or a hard requirement?

**Recommendation:** Either specify the exact JSON path to extract (e.g., `JSON_EXTRACT(payload, '$.sessionKey')`), or say it's best-effort and null is acceptable for legacy events.

### 1.3 `stream_delete_requires_user_action` (409) — unenforceable

§5.4.4 lists `409 stream_delete_requires_user_action` as an error "if request is not attributable to explicit client delete action." But REST requests are REST requests — the server can't distinguish "user tapped delete" from "automated client logic called DELETE." This error code is aspirational, not enforceable at the protocol level.

**Recommendation:** Remove this error code. The binding decision (#8) that server never auto-deletes is sufficient — it's a server implementation constraint, not a wire protocol concern. The REST endpoint either accepts DELETE or it doesn't.

### 1.4 DELETE request body for idempotency key

§5.4.4 puts `idempotencyKey` in the DELETE request body. Some HTTP clients and proxies strip or don't support bodies on DELETE requests. This is technically allowed by HTTP spec but causes real-world issues.

**Recommendation:** Accept `idempotencyKey` as a request header (e.g., `Idempotency-Key`) instead of/in addition to body. Or just use a query parameter.

### 1.5 Migration: `agent:main:main` per-user metadata rows

§4.3 says `agent:main:main` "can appear as a metadata row for any user that has access." §5.2 step 3 says backfill built-ins per user including `agent:main:main` (if present). But:

- How does migration know which users have access to `agent:main:main`? Is it all users? Only admins? Based on existing event history?
- If it's based on event history, what if a user received a message on `agent:main:main` but shouldn't have stream metadata for it?

**Recommendation:** Specify the rule: either "all users in allowlist get an `agent:main:main` row" or "only users with existing events on that session key."

---

## 2. Minor Gaps

### 2.1 `displayName` validation

§5.4.2 lists `400 invalid_display_name` but doesn't specify validation rules beyond the JSON schema's `minLength: 1, maxLength: 120`. What about:
- Whitespace-only names?
- Leading/trailing whitespace trimming?
- `maxDisplayNameBytes` config (§5.8 item 4) vs the hardcoded 120 in the schema?

Pick one source of truth for the limit.

### 2.2 No `stream_limit_reached` limit specified

§5.8 item 4 adds `streams.maxStreamsPerUser` config but no default value is given. The implementer will pick something arbitrary. State the default (e.g., 20).

### 2.3 `kind` field: `global_dm` never explained

The `kind` enum includes `global_dm` but it's never defined. Is this `agent:main:main`? The migration (§5.2) only mentions `main`, `dm`, and `agent:main:main`. Map the kind values to session key patterns.

### 2.4 Idempotency: "normalized request" undefined

§5.4 rule 4 says replay detection compares `(userId, operation, normalized request)`. What's "normalized"? Alphabetically sorted JSON keys? Exact byte match of the body? This matters for whether `{"displayName":"Foo"}` and `{"displayName": "Foo"}` (extra space) are considered the same request.

**Recommendation:** Just match on `(userId, idempotencyKey)` and return stored response regardless of body match. The 409 for mismatched bodies adds complexity for no practical gain — clients that reuse idempotency keys with different bodies are buggy, not adversarial.

### 2.5 Replay of messages for deleted streams

§5.6 rule 3 says if replay references unknown `sessionKey`, client synthesizes a temporary local stream. But §5.4.4 says hard delete removes events for that session. So replayed messages should never reference a deleted stream's sessionKey — the events are gone. This edge case can only occur if there's a race between delete and replay. Worth noting that it's effectively dead code in normal operation.

### 2.6 `PATCH` rename: should built-in rename be allowed?

§5.4.3 returns `409 built_in_stream_rename_forbidden`. §9 item 9 says "Built-in streams are immutable in Phase A." But users might want to rename "Personal" to something else. This is a product decision, not a spec gap — just flagging it as a conscious choice.

---

## 3. Scope Creep Check

The spec is clean. I found **no scope creep** beyond Phase A N-stream. Specifically:
- ✅ No fork/merge anywhere in normative sections
- ✅ Appendix A is clearly marked non-normative
- ✅ No feature negotiation
- ✅ No optimistic concurrency
- ✅ No reordering API
- ✅ No soft-delete / archive

The only thing that could be considered unnecessary complexity is the `stream_idempotency` table. For a single-user system with one or two devices, idempotency keys may be overkill. But it's small and harmless — not scope creep, just belt-and-suspenders.

---

## 4. What's Good

- Session keys as stream IDs: eliminates an entire mapping layer. Clean.
- First-wins concurrency: simple, correct for the use case.
- Hard delete semantics: unambiguous. No zombie state.
- Replay ordering (auth → snapshot → messages): correct and clearly specified.
- Wire protocol is minimal — 4 S2C events, 4 REST endpoints. Easy to implement and test.
- File-by-file guidance for both provider and iOS: reduces implementer guesswork significantly.

---

## Summary

| # | Issue | Severity | Action |
|---|-------|----------|--------|
| 1.1 | `UNIQUE(userId, orderIndex)` creates unnecessary conflict surface | Medium | Drop constraint |
| 1.2 | `events.sessionKey` backfill extraction path unspecified | Medium | Specify JSON path |
| 1.3 | `stream_delete_requires_user_action` unenforceable | Low | Remove error code |
| 1.4 | DELETE body for idempotency key — HTTP compatibility | Low | Use header instead |
| 1.5 | `agent:main:main` per-user row creation rule unclear | Medium | Specify rule |
| 2.1 | `displayName` validation rules incomplete | Low | Specify trimming/whitespace |
| 2.2 | `maxStreamsPerUser` default not specified | Low | State default |
| 2.3 | `global_dm` kind unexplained | Low | Map to session key pattern |
| 2.4 | Idempotency "normalized request" undefined | Low | Simplify to key-only match |
| 2.5 | Synthetic stream on replay is dead code post-delete | Info | Note in spec |
| 2.6 | Built-in rename forbidden — conscious choice? | Info | Confirm product intent |

**No blockers.** Spec is implementable as-is. The medium items (1.1, 1.2, 1.5) will cause implementer questions but not architectural problems.
