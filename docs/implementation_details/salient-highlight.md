# AI-Powered Salient Highlight (Client) — Non-Obvious Details

## Analysis must run on Rendered Text — not raw markdown
The model operates on the **exact string the user sees** (post-markdown parse, post-URL stripping). Offsets computed against raw markdown do not map to the rendered NSAttributedString. Failing to use Rendered Text as analysis input produces highlights that appear at wrong character positions.

## Do NOT ask model to return character offsets — it's unreliable with Unicode
Ask the model for exact substrings. Compute UTF-16 ranges locally by searching within Rendered Text. LLMs are unreliable at character/byte indexing especially with multi-byte Unicode and emoji. A model-returned offset of 42 may be wrong; a model-returned substring "important phrase" found in the attributed string is reliable.

## Cache key includes `renderedTextHash` — not message ID alone
The cache key is `(messageId, renderedTextHash, algorithmVersion)`. A stale cache entry for a different rendered text version (e.g., after markdown parser update) must be treated as a cache miss. Using message ID alone means cache hits serve incorrect highlights after any rendering change.

## Do not call model from inside `UIView.configure(...)` synchronously
Highlights are applied from cached results synchronously; model generation is async and must be scheduled externally. Any synchronous model call in configure blocks the main thread and stalls cell dequeue.

## Span application rules: do not modify link attributes, skip inline code runs
Font-trait spans must not be applied to link attribute ranges (only `.font` changes). Spans intersecting inline code runs (`.traitMonoSpace` or `inlinePresentationIntent == .code`) must be skipped. Applying bold/italic to a hyperlink URL changes its visual appearance in unexpected ways.

## Per-request `LanguageModelSession` — never reuse sessions across messages
Create a fresh `LanguageModelSession` per generation request. Reason: sessions may retain context, and cross-message context contamination affects extraction quality. This is more expensive but required for correctness.

## Concurrency limit: max 1-2 in-flight generations — debounce during fast scroll-back
Without concurrency limiting, rapidly scrolling back through user messages queues dozens of model calls that spike CPU. Max 1-2 concurrent generations plus debounce prevents this. Dropping excess requests is correct — they will be regenerated when the user scrolls back to those messages.

## `renderedTextLengthUTF16` sanity check before applying spans
Before applying cached spans, verify `renderedTextLengthUTF16` matches the current attributed string's length. If lengths don't match (e.g., the renderer changed and produced different text), drop the cached spans rather than applying them to wrong offsets.
