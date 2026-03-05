# Surf Ace WS Protocol — Adversarial Review Pass 7

**Date:** 2026-03-03  
**Reviewer:** Subagent (adversarial consistency pass)  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Prior passes:** 1–6 applied.

---

## Verdict

**3 REAL ISSUES** remain. None are show-stoppers; all are fixable with targeted prose/schema edits. After these three are addressed, the spec should converge to NITS ONLY.

---

## Focused Checks (as tasked)

### ✅ `after_reconnect` rule 10 — UNAMBIGUOUS

Rule 10 is clear and internally consistent:

- Surface emits `event.snapshot_hint(after_reconnect)` **immediately after** `pair.response`, before any other post-reconnect events.
- Provider already triggers mandatory `snapshot.get` per rule 3, then buffers all incoming events per rule 4.
- The hint arrives while `snapshot.get` is in-flight → it is buffered (rule 4).
- After snapshot completes, buffered events drain in order (rule 6) — hint included.
- Rule 10 explicitly states: "trailing confirmation, not a trigger; no additional action required beyond rules 3–6 sync model."

No ambiguity. The phrase "trailing confirmation" is accurate in processing order (hint is processed *after* the snapshot it references). ✓

### ✅ `surfaces.list` paired/grace semantics — PARTIALLY OK, ONE REAL ISSUE (see Issue 3)

The `paired` boolean correctly mirrors `busy=1` mDNS semantics and the description in the schema `description` field matches the prose in §6.0. The grace window coverage is accurate.

However, the spec misleads implementors about who can actually succeed with `takeover=true` — see Issue 3 below.

### ⚠️ bbox width/height consistency — ONE REAL ISSUE (see Issue 1)

Inconsistent dimension naming between `surf_ace_read_buffer.bounds` and every other place that describes a rectangular region in this spec.

---

## Real Issues

### Issue 1 — `surf_ace_read_buffer.bounds` uses `w, h` but all other rects use `width, height`

**Location:** §14.3 `surf_ace_read_buffer` params block (line ~1965)

**Evidence:**

`surf_ace_read_buffer` `bounds` param:
```
bounds   object?   Optional crop region: { x, y, w, h } in surface pixels.
```

Every other rect-like structure in the spec uses the `Rect` schema field names `width`/`height`:
- `Rect` schema (§10): `width`, `height`
- `annotations.bbox` in §13.2: `bbox: {x, y, width, height}` — explicitly notes "(using `Rect` schema field names `width`/`height`)"
- `surf_ace_read` output annotations: `bbox:{x,y,width,height}` (line ~1943)
- `surf_ace_read_buffer` return value: `width: int`, `height: int` (the returned image dimensions)

**Impact:** An implementor reads the stroke's `bbox.width`/`bbox.height` fields and passes them as `bounds.w`/`bounds.h` to `surf_ace_read_buffer`. The field names don't match — introducing a transcription bug risk. The spec itself contradicts its own convention on the same page.

**Fix:** Change `{ x, y, w, h }` to `{ x, y, width, height }` in the `surf_ace_read_buffer` params description.

---

### Issue 2 — `activeEvents` schema accepts `event.surface_appeared` and `event.surface_removed`, but prose explicitly prohibits this

**Location:** `EventType` `$defs` + `PairResponse.eventConfig.activeEvents` items (§10 schema); §7.3 event audit table (line ~405–406)

**Evidence:**

§7.3 event audit table:
> `event.surface_appeared` — "Does NOT appear in `pair.response.eventConfig.activeEvents` (which lists only profile-controlled events)."  
> `event.surface_removed` — "Does NOT appear in `pair.response.eventConfig.activeEvents`."

The `EventType` enum in the schema includes:
```json
"event.surface_appeared",
"event.surface_removed"
```

The `activeEvents` field is:
```json
"activeEvents": {
  "type": "array",
  "items": { "$ref": "#/$defs/EventType" },
  "uniqueItems": true
}
```

Because `EventType` includes these lifecycle events, a conforming schema validator will accept them in `activeEvents` — directly contradicting the prose invariant.

**Impact:** A surface implementation that includes `event.surface_appeared` in its `pair.response.eventConfig.activeEvents` will pass schema validation but violate the protocol semantics. The implementation readiness check item 14 ("All messages validate against the schema in §10") cannot catch this violation.

**Fix (two options):**

Option A — Create a separate `ProfiledEventType` enum that excludes `event.surface_appeared` and `event.surface_removed`, and use it for `activeEvents.items`.

Option B — Add a `not` constraint or `description` note on `activeEvents` to flag this. At minimum, add a JSON Schema `description` that explicitly states lifecycle events must not appear here.

Option A is cleaner for machine validation; Option B is lower diff.

---

### Issue 3 — `surfaces.list` `paired=true` misleads different-provider consumers about `takeover=true` efficacy

**Location:** §6.0 (line ~203) and `SurfacesListResponse` schema `paired` field description (line ~832)

**Evidence:**

§6.0 prose:
> `paired: true` when the surface is either actively connected to a provider OR is in resume grace. In either case, **`pair.request` requires `takeover=true`**.

Schema `description`:
> "`pair.request` requires `takeover=true` when `paired=true`."

§4.2, rule 4 (the actual authority):
> "**Same-provider takeover** is explicit: if a new `pair.request` has the **same `providerId`** and `takeover=true`, surface accepts the new socket…"

There is no provision for cross-provider takeover. A **different** provider that reads `paired=true`, concludes "I need `takeover=true`," sends `pair.request` with `takeover=true`, and expects success — will receive `busy` rejection. The spec's guidance ("requires `takeover=true`") is technically accurate (the same-provider reconnect case does require it) but is phrased in a way that implies takeover will succeed for *any* provider, which is false.

**Impact:** Implementors building a new provider against `surfaces.list` may implement a retry-with-takeover loop that will never succeed for occupied surfaces, looping indefinitely before backoff. Also: the schema description ("pair.request requires takeover=true when paired=true") will appear as inline documentation in generated SDKs and carries the same misleading implication.

**Fix:** Expand the prose and schema `description` to clarify:
> `paired: true` means the surface is actively connected to or in resume grace for a prior provider session. For the **same provider** reconnecting: `pair.request` with `takeover=true` will succeed. For a **different provider**: the surface is unavailable and will reject `pair.request` with `busy` regardless of `takeover` flag — wait until `paired=false` (grace expires or previous provider gracefully disconnects).

---

## Nits (not real issues — pass-or-note only)

- **`PairResponse.viewport` not using `$ref: SurfaceViewport`** — the inline definition is byte-for-byte identical to `SurfaceViewport`. Redundant schema definition, not a correctness issue.
- **`DrawingFlushConfig.maxIntervalMs` and `DrawingFlushEvent.maxIntervalMs` have no upper bound** — allows arbitrarily large values. Prose only specifies default (30000). Not a wire-level issue since parties negotiate this at pair time.
- **§5.5 limits list omits `resumeGraceMs`** — the schema includes it in `limits`, the prose doesn't list it as a surface-advertised limit in §5.5. Minor gap in the informative text.
- **`MutationAckResponse.contentType` not in `required`** — present as optional. §6.1's pair response includes contentType as required in `state`; mutation ack does not enforce it. Clients tracking content type from mutation acks will need to handle absent field. Probably intentional but worth a note.

---

## Summary Table

| # | Area | Severity | One-line |
|---|---|---|---|
| 1 | `surf_ace_read_buffer.bounds` | **Real** | `w, h` vs `width, height` — naming inconsistency vs all other rects in spec |
| 2 | `activeEvents` schema | **Real** | Schema allows lifecycle events in `activeEvents`; prose prohibits them — validator can't catch violation |
| 3 | `surfaces.list` `paired=true` | **Real** | Implies `takeover=true` works for any provider; only same-provider takeover is defined |
| — | Nits | Nit | 4 minor items, no correctness impact |

---

*Pass 7 complete. Three targeted fixes and the spec is ready to ship.*
