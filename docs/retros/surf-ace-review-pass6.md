# Surf Ace Protocol — Adversarial Consistency Review, Pass 6

**Date:** 2026-03-03  
**Reviewer:** Subagent (adversarial pass)  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Prior passes:** 1–5 already applied  
**Focus areas:** annotation wire→register mapping, resumeGraceMs schema default, surfaces.list paired field, snapshot_hint rules 9/10, remaining contradictions

---

## Summary

**4 real issues, 3 nits.** No catastrophic contradictions, but two of the real issues (rules 9/10 numbering collision + after_reconnect sequencing) interact and need coordinated resolution.

---

## Real Issues

### Issue 1 — Duplicate rule numbers 9 and 10 in Section 7.3 (Event behavior rules)

**Lines:** ~418–423

The event behavior rule list has two rules numbered 9 and two numbered 10:

```
8. (backpressure / snapshot_hint backpressure_drop)
9. After completing a complex render... (after_render)     ← NEW
10. After a successful reconnect... (after_reconnect)      ← NEW
9. Provider deduplicates events by eventId...              ← OLD
10. If a flush send fails or disconnects mid-send...       ← OLD
```

The new `after_render` / `after_reconnect` rules were inserted after rule 8 but the old rules 9 and 10 were not renumbered. Result: two rules labeled "9" and two labeled "10" in the same numbered list. The spec's own "Adversarial Hardening Results" section (Section 11, items 3 and 18) references the reconnect/snapshot behavior but citations like "see rule 3" in rule 10 become ambiguous when there are two rule 10s.

**Fix:** Renumber old rules 9→11 and 10→12, or insert the new rules 9/10 without stealing existing numbers.

---

### Issue 2 — `after_reconnect` hint sequencing is underdetermined; conflicts with buffer-and-drain model (§7.3 rules 3–6 vs. new rule 10)

**Lines:** ~411–423

New rule 10 (the `after_reconnect` rule) reads:

> "surface emits `event.snapshot_hint` with reason `after_reconnect` to signal that snapshot state is fresh and buffered events can be applied. Provider MUST use this as the sync point after the mandatory post-reconnect `snapshot.get` (see rule 3)."

But rules 3–6 already define a complete reconnect sync model:
- Rule 3: Provider issues `snapshot.get` immediately after reconnect.
- Rule 4: Provider MUST buffer events that arrive while `snapshot.get` is in-flight.
- Rule 6: On snapshot success, provider applies snapshot state first, then processes buffered events in receive order.

Two contradictions surface depending on when `after_reconnect` is emitted:

**Case A — surface emits `after_reconnect` immediately after `pair.response` (before snapshot response arrives):**  
The hint arrives while `snapshot.get` is in-flight → it is buffered per rule 4 → it is processed after snapshot per rule 6 — as one of the buffered events in order. Rule 10 says provider MUST use it as the sync point, but by the time provider processes it, snapshot has already been applied and the buffer has already started draining. The hint is redundant and the "MUST use as sync point" instruction has nothing to act on.

**Case B — surface emits `after_reconnect` after sending the `snapshot.get` response:**  
The hint arrives as a live event after snapshot is complete → not buffered → provider sees it post-sync. This interpretation makes the hint meaningful as a secondary confirmation, but then: (a) the spec doesn't say the surface waits for `snapshot.get` before emitting `after_reconnect`; (b) if provider is already done with the sync per rules 3–6, what should it do differently on seeing this hint?

Neither case is specified. The prose doesn't say when exactly the surface emits `after_reconnect` relative to the `snapshot.get` request/response, nor what the provider's MUST action is when it encounters the hint in its event stream (buffered or live). Rule 10's "MUST use this as the sync point" is unimplementable without knowing the timing.

**Fix:** Define the exact emission timing (e.g., "surface emits `after_reconnect` after sending `pair.response` and before any other post-reconnect events"). Then either: (a) clarify that the MUST only applies if hint arrives after snapshot completes (i.e., it's the trailing confirmation, not the trigger), or (b) remove the MUST and align with rule 6's existing drain-after-snapshot model.

---

### Issue 3 — `resumeGraceMs` default documented in prose but absent from schema (inconsistent pattern)

**Prose line:** ~125 (`"During the grace window (resumeGraceMs, default 20000)"`)  
**Schema line:** ~1199  
**Schema close code table line:** ~458

The prose correctly states the default is 20000 ms. The JSON Schema `resumeGraceMs` property has no `default` annotation:

```json
"resumeGraceMs": { "type": "integer", "minimum": 5000, "description": "..." }
```

Compare with `DrawingFlushConfig` properties in the same schema, which do carry `"default": 8000` and `"default": 30000`. The `limits` block overall is inconsistent with `DrawingFlushConfig` on whether defaults appear in the schema. More importantly, `resumeGraceMs` is the only limits field where the default is meaningfully non-obvious (20s grace is a significant behavior decision), and it's the only new field from Pass 5 additions.

Secondary: the schema `description` for `resumeGraceMs` says "Provider must reconnect within this window" — this is incorrect; **any** provider can reconnect at any time, but only the **same** `providerId` can resume the session within this window. The description should say "Same provider must reconnect within this window to resume the session."

**Fix:**  
(a) Add `"default": 20000` to the `resumeGraceMs` schema property.  
(b) Correct description to "Same provider must reconnect within this window to resume the session with the same providerId."

---

### Issue 4 — `surfaces.list` `paired` field undefined during resume grace window; inconsistent with mDNS `busy` semantics

**Prose line:** ~203 (§6.0), **schema line:** ~832, **mDNS table line:** ~79, **§4.2 line:** ~105

mDNS `busy=1` is defined to cover **two** distinct states:
1. Actively paired (live socket open, paired provider connected)
2. In resume grace (socket closed after disconnect, within `resumeGraceMs`)

§4.2 rule 3: "Surface advertises `busy=1` while paired or in reconnect grace."

But `surfaces.list` `paired` is described as:

> "`paired: true` means that window is currently occupied by a provider; `pair.request` to it requires `takeover=true`."

This description matches only state (1). During resume grace (state 2), the original provider's socket is gone. The spec does not say what `paired` returns in that state.

**Practical consequence:**  
- If `paired=false` during grace: a new provider issues `pair.request` without `takeover=true` → surface rejects with `busy` error → provider is confused because `surfaces.list` told it the surface was free.
- If `paired=true` during grace: the description "currently occupied by a provider" is semantically inaccurate (no live connection exists), but the behavior is correct (new providers need `takeover=true`).

The mDNS `busy` field is at the device endpoint level and covers both states by design. The `surfaces.list` `paired` field is per-window, and its semantics during grace are unspecified.

**Fix:** Add a sentence to §6.0 and to the `paired` field description clarifying that `paired=true` is also returned when the surface is in resume grace (i.e., `paired` mirrors `busy` semantics, not "live socket open"). Example language: "`paired: true` when the surface is either actively connected to a provider or is in resume grace for a prior session. In either case, `pair.request` requires `takeover=true` unless the caller is the session owner."

---

## Nits

### Nit 1 — `bbox` field naming inconsistency: register/tool uses `{x,y,w,h}`, JSON Schema `Rect` uses `{x,y,width,height}`

**Register table line:** ~1755, **surf_ace_read tool line:** ~1943, **Rect schema line:** ~624

The `annotations` register documentation and the `surf_ace_read` tool return signature both write the bounding box as `bbox: {x, y, w, h}`. The JSON Schema `Rect` definition (used throughout the schema for `visibleRect`, `Selection.boundingRect`, etc.) requires `width` and `height`, not `w` and `h`. If any annotation bbox data flows through code that validates against `Rect`, the field names won't match. Should standardize to `width`/`height` throughout.

---

### Nit 2 — Register `annotations` points form implies `pressure` is always present; wire schema has it optional

**Register line:** ~1755, **StrokePoint schema line:** ~1379–1383

The `annotations` register shows register points as `{x, y, pressure}`, implying pressure is always in the register form. But `StrokePoint` in the JSON Schema has `pressure` as optional (not in `required`). No prose describes how the provider handles a stroke point that lacks pressure in the wire payload — should it be omitted from the register form, or defaulted to some value (0? null?).

---

### Nit 3 — Section 7.3 Event Audit table: `event.snapshot_hint` "does not appear in `activeEvents`" is not stated; only lifecycle events have that note

**Table line:** ~397–407

The "Does NOT appear in `pair.response.eventConfig.activeEvents`" note appears in the rows for `event.surface_appeared` and `event.surface_removed` (not profile-gated). The `event.snapshot_hint` row has no equivalent note, but it is also described as "provider-internal" and "NOT exposed in the CLU register model" (§7.1). It's unclear whether `snapshot_hint` appears in `activeEvents` (and is just not surfaced to CLU), or is also excluded from `activeEvents` for the same reason as lifecycle events. Given that lifecycle events are excluded from `activeEvents` because they're not profile-controlled, and `snapshot_hint` IS profile-controlled (it appears in `minimum_deep`), it probably SHOULD appear in `activeEvents` — but this should be stated explicitly rather than inferred by contrast.

---

## Focus Area Verdicts

| Focus area | Verdict |
|---|---|
| (1) Annotation wire→register mapping (bbox/startedAt/endedAt) | Prose rules are unambiguous for startedAt/endedAt. Real gap: bbox uses `{w,h}` not `{width,height}` vs Rect schema (Nit 1). Pressure optionality unaddressed (Nit 2). |
| (2) resumeGraceMs in pair.response limits schema — default in prose? | Default 20000 IS in prose (§4.4). NOT in schema default annotation. Schema description slightly inaccurate. → Issue 3. |
| (3) surfaces.list paired field vs mDNS busy | Real gap: paired field semantics during resume grace undefined. mDNS busy covers both states; paired description covers only live-socket state. → Issue 4. |
| (4) snapshot_hint after_render/after_reconnect rules 9/10 vs §4.4 | Two real defects: duplicate numbering (Issue 1) and after_reconnect sequencing conflict with buffer-and-drain model (Issue 2). |
| (5) Remaining internal contradictions | No new large-scale contradictions found. Issues above are the remaining open items. |
