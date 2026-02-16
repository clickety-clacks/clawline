# T031 Architecture Retro: HTML Attachment File-Icon Fallback

Date: 2026-02-15
Issue: `sendAttachment` HTML payloads arrived but rendered as generic file icons instead of inline interactive HTML bubbles.

## 1) Original fix and why it did not work

Original fix: provider commit `eb49601db` changed outbound rich-attachment writes from `runPerUserTask(...)` to `enqueueWriteTask(...)` in `src/clawline/server.ts`.

What it fixed:
- Removed queue contention where outbound `sendAttachment` could stall behind long inbound turn processing and time out.

Why it did not fix T031 end-to-end:
- That change only fixed transport timing.
- The iOS client still failed the rich-document hydration path when the attachment arrived as `type=document` + `assetId` (no inline `data`).
- Without hydrated `attachment.data`, MIME dispatch could not decode `InteractiveHTMLDescriptor`, so rendering fell back to `.file` (file icon).

## 2) Client-side code path: receive -> inline render vs file icon

1. WebSocket message decode:
- `ios/Clawline/Clawline/Models/ProviderWireModels.swift` decodes payload attachments into `[Attachment]`.

2. Message ingestion:
- `ChatViewModel.handleIncoming(...)` stores message and calls `resolveAssetAttachmentsIfNeeded(for:)`.

3. Attachment hydration seam:
- `ChatViewModel.resolveAssetAttachmentsIfNeeded(...)` decides whether to download attachment bytes for `assetId`-backed attachments.

4. Presentation routing:
- `ChatViewModel.presentation(for:metrics:)` -> `MessagePresentationBuilder.build(...)`.
- `MessagePresentationBuilder.partitionAttachments(...)` attempts rich MIME dispatch:
  - `.document` + interactive MIME + decodable JSON `attachment.data` -> `.interactiveHTML(...)`
  - otherwise -> `.file(...)`

5. Bubble rendering:
- `MessageBubbleUIKitView` renders `.interactiveHTML` with `InteractiveHTMLBubbleUIKitView`.
- `.file` renders the generic file icon row.

## 3) Failing condition that triggered fallback

Failure was at the hydration seam:

- In `ChatViewModel.resolveAssetAttachmentsIfNeeded(...)`, download eligibility only included image-like attachments.
- `type=document` interactive HTML attachments were not selected for download.
- The download path also had `UIImage(data:)` validation, which rejects non-image payloads.

Result:
- `attachment.data` remained `nil` for interactive HTML document attachments.
- `MessagePresentationBuilder.decodeInteractiveHTMLDescriptor(...)` guard (`let data = attachment.data`) failed.
- Attachment was classified as `.file`, so UI showed file icon fallback.

## 4) Right fix

Implement rich-document payload hydration as a shared boundary for both rich bubble types:

1. Expand hydration eligibility in `ChatViewModel` for `.document` attachments whose MIME normalizes to:
- `application/vnd.clawline.interactive-html+json`
- `application/vnd.clawline.terminal-session+json`

2. Keep image integrity guard for image attachments only.
- Preserve `UIImage(data:)` validation for image/image-like attachments.
- Allow non-image payload bytes for the two rich document MIME types.

3. Preserve single MIME dispatch path in `MessagePresentationBuilder`.
- Once hydrated data is present, existing decode route produces `.interactiveHTML` / `.terminalSession` parts.

4. Add regression test for this exact seam.
- `ChatViewModelTests`: asset-backed interactive HTML document now hydrates data and routes to `.interactiveHTML` instead of `.file`.

## Boundary/Invariants to prevent recurrence

- Transport delivery and client renderability are separate invariants; both must pass for E2E success.
- Any rich bubble MIME that requires local JSON decode must be included in one explicit hydration policy (single mutation seam), not image-only heuristics.
- Rich MIME dispatch should depend on normalized MIME + decoded payload, not attachment storage mode (inline `data` vs `assetId` + download).
