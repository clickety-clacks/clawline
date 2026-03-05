# Surf Ace Spec Cleanup Pass — Change Summary

Date: 2026-03-04

## (a) What Was Removed

- **`Supersedes:` header line** — referenced the prior REST/callback/watch design file; irrelevant to a fresh implementation.
- **§1 "Flynn-Directed Protocol Change"** — entirely replaced (see additions below). Was a history note, not a purpose section.
- **"(Flynn-directed)" suffixes** on §2.3 and §2.4 headings — attribution has no meaning to an implementation agent.
- **§2.4 "Implementation direction" paragraph** — referenced a specific git branch (`clawline-rebase-2026-03-03`) and a retired worktree (`surf-ace-manual-register`); not relevant to implementation.
- **Appendix A date-stamped resolution framing** — removed or relabeled:
  - "Status: Resolved — 2026-03-03." → replaced with "Decision:" or "Capture frame model note:"
  - "Further resolution — 2026-03-03 (capture frame model):" → relabeled without date
  - "Resolved (2026-03-02, updated 2026-03-03):" → relabeled as "Decision:"
  - "Data model (v1 decision, 2026-03-03):" → relabeled as "Data model:"
  - "Resolved (2026-03-03):" → relabeled as "Decision:"
  - "Current lean (Flynn, 2026-03-02):" → relabeled as "Design direction:"
  - "Request (Flynn, 2026-03-03):" + "Status: Committed phase work." → folded into a single declarative sentence
  - "Raised: 2026-03-03 Flynn review session." line in A.12 → removed
  - Appendix A intro "on 2026-03-02" date → removed
- **"Implementation status: ready for Flynn verification."** in §12 → changed to "ready for implementation."

## (b) What Was Added

- **§1 "Purpose and Goals"** — a complete new primary spec section covering:
  - What Surf Ace is (standalone display and annotation system)
  - Supported platforms: iOS/iPadOS, Electron on macOS/Windows/Linux
  - Actors: CLU (orchestrator), Surfaces (displays), Users (annotators)
  - All 7 original core goals explicitly stated:
    1. CLU-managed surface
    2. Content display (html/image/pdf/terminal/markdown, with video/canvas reserved)
    3. User annotation (stylus on iPad, input device on Electron)
    4. CLU interpretation of annotations
    5. Zero-config discovery via Bonjour/mDNS
    6. Multi-surface management
    7. Standalone app (not embedded in another app)
  - Architecture overview (WS-based, provider-as-client, no REST)

## (c) Sections NOT Changed and Why

- **§2 through §14 (all protocol sections)** — all normative technical content, schemas, constraints, and behavioral rules left intact. No content was altered.
- **Appendix A open questions (A.4, A.5, A.12)** — these are genuinely unresolved; their "Status: Unresolved" labels were preserved. Only minor wording cleanup was done on A.4 (removing a date reference in the status).
- **§11 Adversarial Hardening Results** — the numbered "Resolution:" labels in this section are part of the section's own format (problem + resolution pairs), not Appendix A meta-commentary. They were not in scope for cleanup.
- **JSON Schemas in §10** — not touched; schemas are normative wire-protocol definitions.
- **Appendix A.7 "Status: Resolved for v1"** end-of-section status — retained as useful implementation guidance; it has no date stamp.
