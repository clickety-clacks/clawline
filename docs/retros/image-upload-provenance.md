# Image Upload Provenance (T057)

Date: 2026-02-19
Worktree: `~/src/worktrees/clawline-unified-md` (currently detached at `bfb4ece2e`)

## Scope

Investigate two questions:

1. Is `inlineByteLimit` still `256KB` upstream?
2. What commit broke the large-image upload path?

---

## 1) Upstream `inlineByteLimit` status

`inlineByteLimit` is still `256KB` in the current Clawline iOS mainline.

Evidence:

- `ios/Clawline/Clawline/Models/PendingAttachment.swift` has:
  - `inlineByteLimit = 256 * 1024`
  - `inlineTotalByteLimit = 256 * 1024`
- `git blame` attributes this to `eb58c920a` (2026-01-25).
- `origin/main` comparison shows no divergence in this file from `unified-md`.

Conclusion: no upstream reversion; 256KB remains the active threshold.

---

## 2) What broke the upload path?

## 2a) iOS client provenance (unified-md vs main)

No commits on `unified-md` changed the attachment upload/send decision path compared with `origin/main`.

Evidence:

- `buildWireAttachments` still routes `> inlineByteLimit` to `uploadService.upload(...)` in `ChatViewModel.swift`.
- `PendingAttachment` limits are unchanged versus `origin/main`.
- `UploadService.upload(...)` path is unchanged in behavior since initial introduction; later edits were logging-only.
- `git diff origin/main..unified-md` for `PendingAttachment.swift`, `ChatViewModel.swift`, `UploadService.swift`, `WireAttachment.swift` showed no upload-path behavior changes attributable to T057 markdown work.

Conclusion: this is not a unified-md markdown regression.

## 2b) Server-side provenance (provider `/upload`)

Most likely break commit: `c23e45f55` (2026-01-31, "Rebase onto upstream main with Clawline changes").

Why this commit is the primary suspect:

- It introduced `src/clawline/http-assets.ts` with a new `Busboy` upload implementation.
- In that initial implementation, upload completion resolved on Busboy `finish` without waiting for file write completion. This can race on larger files and produce intermittent/size-sensitive upload failures.

Follow-up fix commit:

- `1113e729f` (2026-02-01, "Clawline: fix review findings") added a `writeDone`/`settled` flow to wait for stream finish before resolve/re-entrant reject, specifically hardening this race.

Related later commit:

- `de7fd22c9` (2026-02-01) added cleanup on DB insert failure after file rename; good hygiene, not the likely initial break.

### Confidence

- High confidence that iOS `unified-md` did **not** introduce this failure.
- Medium confidence that `c23e45f55` introduced the first concrete upload-path bug (race), with `1113e729f` intended to fix it.

### What cannot be proven from code history alone

Without runtime logs from Flynn’s failing environment, we cannot prove whether the current failure is:

- the historical upload race (if runtime is missing `1113e729f`),
- auth rejection on `/upload` (401/403), or
- environment config/proxy body-size cap (which would also appear as "large only" failures).

The provenance result is still clear: T057/unified-md iOS markdown commits did not change this path; the meaningful code churn happened in provider `/upload` around `c23e45f55` and `1113e729f`.
