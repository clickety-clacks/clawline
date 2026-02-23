# Image Send Provenance Investigation

## Question
Flynn reports send errors for images larger than 256 KB from iOS client, while smaller images send successfully. Determine whether unified-md branch commits changed the send path and what stage is failing.

## Scope audited
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
- `ios/Clawline/Clawline/Models/PendingAttachment.swift`
- `ios/Clawline/Clawline/Services/UploadService.swift`
- `ios/Clawline/Clawline/Models/AttachmentError.swift`
- `ios/Clawline/Clawline/Models/WireAttachment.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift`

## Provenance vs `origin/main`

### 1) unified-md did not change the image send path files
Path-limited diff from `origin/main..unified-md` for all send-flow files above is empty.

Path-limited log from `origin/main..unified-md` only shows merge commit metadata (`2c5df2378`) and no content changes to these files.

Conclusion: none of the unified markdown work on this branch modified the attachment send pipeline.

### 2) The 256 KB thresholds predate this branch and are present on `origin/main`
Current code and `origin/main` both contain:
- `PendingAttachment.inlineByteLimit = 256 * 1024`
- `PendingAttachment.inlineTotalByteLimit = 256 * 1024`
- `PendingAttachment.totalPayloadByteLimit = 320 * 1024`

Source:
- `ios/Clawline/Clawline/Models/PendingAttachment.swift:12-15`

`git blame` for both local and `origin/main` points these lines to commit `eb58c920a8` (2026-01-25).

## Actual send flow behavior (large vs small images)

### Small image path (<= 256 KB inline budget)
`ChatViewModel.buildWireAttachments` inlines image bytes into message payload as `WireAttachment.image`:
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1284-1293`
- `ios/Clawline/Clawline/Models/WireAttachment.swift:10-13,45-52`

### Large image path (> 256 KB)
The same function switches to upload path and sends `WireAttachment.asset` with returned `assetId`:
- size gate: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1285`
- upload call: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1305-1309`
- asset wire attachment: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1312`

Upload call is multipart `POST /upload` in `UploadService.upload`:
- `ios/Clawline/Clawline/Services/UploadService.swift:38-63`

## Where failure most likely occurs
Given symptom pattern (small works, >256 KB fails):
- Threshold boundary exactly matches inline cutoff (`256 * 1024`).
- Therefore failures are most likely in the **upload stage**, not wire serialization:
  - <=256 KB: inline path, no upload needed.
  - >256 KB: forced upload path.

Potential upload failures in code:
- non-2xx from `/upload` => `AttachmentError.uploadFailed` (`UploadService.swift:58-63`)
- missing auth/base URL/network also mapped to `AttachmentError`

Then send flow catches `AttachmentError` and marks message failed with `upload_failed_retryable`:
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1199-1206`

## Is this new behavior?
Based on branch provenance and blame: **no evidence this is new on unified-md**.
- The 256 KB inline cutoff and upload fallback were introduced earlier (Jan 2026 commits) and are unchanged relative to `origin/main`.

## Notes on certainty
This investigation is source/provenance based. No live failing request/response logs from Flynn’s device were captured in this pass, so exact server status for failing uploads (e.g. 413 vs other) is not directly observed here.
