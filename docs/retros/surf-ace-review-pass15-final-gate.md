# Surf Ace Spec Final Gate — Pass 15 (Post Selection-Fix)

Spec reviewed: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
Scope: final adversarial consistency check focused on selection semantics across §7.1, schema `$defs.Selection`, §13.2 register rules, and §14.3 `surf_ace_read`; plus quick sweep for contradictions introduced by recent phase/pane edits.

## 1) Verdict

**NITS ONLY**

## 2) Findings

No real blocking inconsistencies found in the targeted selection path.

Selection semantics are now internally consistent across the four required loci:
- **§7.1** states v1 interoperability guarantees `kind:"text"`; `point`/`region` are reserved unless explicitly negotiated.
- **Schema `$defs.Selection` (§10)** allows `text | point | region | null`, with explicit v1 ignore guidance for `point`/`region` when no negotiation is active.
- **§13.2 register rule** requires provider to discard wire `kind:"point"`/`kind:"region"` and leave the `selection` register unchanged.
- **§14.3 `surf_ace_read` contract** now matches kind-gated behavior (text selection mapping + explicit discard note for `point`/`region` unless negotiated), removing the prior non-HTML hard-null contradiction.

Quick phase/pane sweep: no new normative contradiction detected. The pane gap is explicitly called out as pending Phase 1 completion in §14.3 (optional `paneId` default `root`), which is consistent with the phased language in §2.3 and the appendix notes.

## 3) Optional editorial nits (non-blocking)

- `surf_ace_read.selection` return shape in §14.3 does not include a `kind` field, while nearby text says providers “preserve `kind:\"text\"` selections.” This is understandable (mapped CLU-layer schema), but a one-line clarifier could reduce reader confusion: e.g., “`kind` is implicit as text in CLU-layer selection mapping.”
