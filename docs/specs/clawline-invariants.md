# Clawline Invariants (Canonical)

## Invariants
1. **Session keys are the only routing identifiers.** Every message, delivery, and reply uses the session key (e.g., `agent:main:main` or `agent:main:clawline:{userId}:main`). Do not invent or parse alternate identifiers; keep delivery routing anchored in the session store or plugin adapter.
2. **No deployment-specific configuration in tracked repo files.** Core OpenClaw code ships everywhere. Clawline routing semantics, session key guidance, and deployment overrides belong in runtime config like this file—not in shared `src/` or `docs/` files under version control.
3. **Rebase merge philosophy:** minimize shared/core divergence, adopt upstream patterns, avoid inventing new core hooks, and confine Clawline-specific behavior to extension/plugin directories unless a shared change is absolutely necessary.
