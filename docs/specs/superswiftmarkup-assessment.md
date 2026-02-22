# SuperSwiftMarkup Deep-Dive Assessment for T057

Status: Complete
Date: 2026-02-12
Owner: Spec agent (SME)
Decision target: T057 unified markdown renderer architecture for Clawline iOS

## Scope and Method

This assessment is based on source code review of both repositories (not README-only review):

1. Prototype repo: `https://github.com/SuperSwiftMarkup/SuperSwiftMarkdownPrototype`
2. Rewrite repo: `https://github.com/SuperSwiftMarkup/SuperSwiftMarkup`

Local clones reviewed:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkup`

## Critical Findings First (Code Review)

### Critical 1: The rewrite repo is not currently a usable codebase

1. `SuperSwiftMarkup` contains only workspace metadata and README (`3` files total).
2. There is no package/library source to adopt right now.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkup/README.md:1`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkup/README.md:5`

### Critical 2: Prototype iOS build currently fails

1. iOS build command fails with missing `UIColor.blended` API.
2. This blocks direct adoption in Clawline today without fixes.

Evidence:

1. Build command run: `xcodebuild -workspace SuperSwiftMarkdownPrototype.xcworkspace -scheme SSDocumentEngine -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' build`
2. Error:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSDMUtilities/SSColorMap.swift:52:31: error: value of type 'XColor' (aka 'UIColor') has no member 'blended'`
3. Error:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSDMUtilities/SSColorMap.swift:53:29: error: value of type 'XColor' (aka 'UIColor') has no member 'blended'`
4. Related source:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSDMUtilities/SSColorMap.swift:50`

### Critical 3: Parser has crash-on-unexpected-node paths

1. Multiple `fatalError("TODO - WHEN DOES THIS HAPPEN?")` branches exist in markdown parse code.
2. A renderer embedded in chat should not crash process on unsupported/unknown markdown nodes.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:50`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:52`
3. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:109`
4. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:187`

### High 4: Test coverage is effectively absent

1. `SSDocumentModelTests` has one placeholder test.
2. `SSDocumentEngineTests` has one placeholder test.
3. `swift test` passes, but this does not validate core behavior.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Tests/SSDocumentModelTests/SSDocumentModelTests.swift:5`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Tests/SSDocumentEngineTests/SSDocumentEngineTests.swift:5`

### High 5: Large unfinished action surface indicates prototype maturity

1. `DocumentView+actions.swift` is `1331` lines with many TODO handlers and debug prints.
2. This suggests the codebase is a foundation/prototype, not a hardened drop-in dependency.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+actions.swift:1`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+actions.swift:209`
3. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+actions.swift:214`

### High 6: License model is risky for direct dependency adoption

1. Prototype license is AGPLv3 or commercial.
2. AGPL obligations are likely incompatible with our default dependency posture for Clawline unless legal approves or commercial terms are negotiated.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/LICENSE.md:6`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/LICENSE.md:8`
3. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/LICENSE.md:21`

## 1) Fitness for Clawline

Question: can this deliver read-only markdown in bubble + expanded sheet with continuous cross-block selection for text/code/tables?

### What it does match

1. Uses `swiftlang/swift-markdown` parser (`Document(parsing: ...)`) and walks markdown AST.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:17`
2. Compiles full markdown document into one attributed string, which enables single-surface selection behavior.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/SSDocument+attributedString.swift:19`
3. Supports block metadata (`blockScopes`, table metadata) to draw block chrome while preserving text continuity.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/SSBlockType.swift:71`
4. Uses TextKit 2 viewport APIs and custom fragment drawing for rich block visuals.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+viewport.swift:22`

### What it does not match (or is insufficient)

1. No Clawline `==highlight==` support path is implemented.
   Evidence: inline parser handles emphasis/strong/strikethrough/link/etc but no mark node handling in switch.
   File: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:174`
2. No Clawline bubble/expanded dual-mode API (no truncation policy, no show-more behavior, no URL-strip-by-context policy).
   Evidence: renderer compiles whole document once; no bubble-specific mode flags.
   File: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/SSDocument+attributedString.swift:19`
3. The code block rendering model is textual (fence tokens + code text) rather than interactive block widgets.
   Evidence: appends "```" tokens around code string.
   File: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/SSBlock+attributedString.swift:192`
4. Horizontal per-block scrolling is explicitly noted as missing in prototype notes.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/README.md:77`
5. Current engine is macOS-first in core surface wiring (`NSView`, `NSScrollView`, `NSViewControllerRepresentable`) and is not production iOS-ready yet.
   Evidence:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView.swift:23`
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentViewController.swift:28`
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentWrapperView.swift:34`

### Fitness verdict

1. Concept fit: strong for proving cross-block selection architecture.
2. Direct product fit for Clawline today: low.
3. It is best treated as architecture reference, not adoptable runtime.

## 2) Production Quality Assessment

### Maturity signals

1. Prototype explicitly says code will remain as reference while rewrite proceeds.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/README.md:5`
2. Rewrite explicitly says work in progress / clean slate.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkup/README.md:1`
3. Crash paths (`fatalError`) on parser fallthrough.
   Evidence: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/SSDocument+parse.swift:52`
4. Placeholder tests only.
   Evidence:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Tests/SSDocumentModelTests/SSDocumentModelTests.swift:5`
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Tests/SSDocumentEngineTests/SSDocumentEngineTests.swift:5`
5. Debug assertions/prints and large TODO surfaces in core layout and action layers.
   Evidence:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+layout.swift:55`
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView.swift:76`
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+actions.swift:209`

### Memory/perf/error handling posture

1. Good conceptual performance choices exist (viewport-based fragment layout, layer reuse via map table).
   Evidence:
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+viewport.swift:88`
   `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView.swift:53`
2. Error handling is not hardened enough for production chat rendering because crash-on-unknown-node remains.
3. iOS build failure indicates platform quality gate is not met.

### Ship decision

1. I would not ship this as a production dependency in Clawline today.
2. It is prototype-grade with valuable architecture ideas.

## 3) How Close If Not Ready

Estimated effort to make prototype branch production-capable for Clawline-like read-only rendering:

1. iOS correctness and compile stabilization: 2 to 4 days.
2. Parser hardening and non-crashing fallback behavior: 3 to 5 days.
3. Test suite buildout (parser fixtures, render parity, selection, long-message perf): 1 to 2 weeks.
4. Clawline integration features (`==highlight==`, theme/font hooks, bubble truncation + expanded parity contract): 1 to 2 weeks.
5. Performance tuning + bug burn-down on iOS 18+ edge cases: 1 to 2 weeks.

Total realistic range: 4 to 8 weeks for one experienced engineer, excluding legal/commercial license work.

## 4) Popularity / Maintenance (as of 2026-02-12)

### SuperSwiftMarkdownPrototype

1. Stars: 85
2. Forks: 3
3. Watchers/subscribers: 2
4. Contributors: 1 (`colbyn`, 64 commits)
5. Open issues: 1
6. Last push: 2025-02-02T00:32:16Z
7. Commit range: 2025-01-11 to 2025-02-01

### SuperSwiftMarkup (rewrite)

1. Stars: 43
2. Forks: 1
3. Watchers/subscribers: 4
4. Contributors: 1 (`colbyn`, 40 commits)
5. Open issues: 0
6. Last push: 2025-05-10T18:46:07Z
7. Commit range: 2025-01-28 to 2025-05-10

### Maintenance interpretation

1. Single-maintainer projects with low issue volume.
2. Prototype has little recent code activity.
3. Rewrite has newer activity but no shippable source yet.
4. Responsiveness signal is limited but non-zero (issue #1 has maintainer replies on 2025-05-10 and 2025-05-13).

## 5) Adopt vs Fork vs Reference

### Option A: Adopt as dependency (SPM)

Verdict: No.

1. Rewrite repo is not implementation-complete.
2. Prototype fails iOS build in current state.
3. License model introduces legal/commercial friction.
4. Missing Clawline-specific features means significant patching anyway.

### Option B: Fork and customize

Verdict: Not recommended for T057 baseline.

1. Technically possible, but we inherit a large custom text engine and long-term maintenance burden.
2. Work required before first stable release is non-trivial (4 to 8 weeks estimate).
3. Licensing still needs explicit handling.

### Option C: Use as reference, write our own

Verdict: Recommended.

1. Matches Flynn direction to use `swiftlang/swift-markdown` in a focused Clawline renderer.
2. Lets us keep scope tight to read-only chat rendering + parity between bubble and expanded sheet.
3. Avoids dependency/legal risk and avoids carrying editor-grade complexity we do not need.
4. We can copy proven ideas (metadata-driven block rendering on a continuous attributed stream) without inheriting unfinished framework surface.

Recommendation: **Option C**.

## 6) Architecture Insights for T057

### How they solved cross-block selection

1. They do not split markdown into separate UIViews per block.
2. They compile one attributed string for the whole document (`compileAttributedString`) and preserve logical continuity.
3. They annotate block ranges with custom attributes (`blockScopes`, `tableRowMetadata`, `tableCellSpan`) and draw block visuals at layout-fragment time.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/SSDocument+attributedString.swift:19`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/DocumentContext.swift:79`
3. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentModel/Sources/SSMarkupFormat/AttributedStringRendering/SSBlockType.swift:71`
4. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/TextLayoutFragmentLayer.swift:79`

### TextKit 2 patterns they use

1. `NSTextLayoutManager` with `NSTextViewportLayoutControllerDelegate`.
2. Custom layout-fragment presentation via CALayer (`TextLayoutFragmentLayer`) rather than default text views.
3. Selection drawing via `enumerateTextSegments` and custom selection layers.

Evidence:

1. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView.swift:25`
2. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+viewport.swift:22`
3. `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentView+layout.swift:30`

### What they do not use

1. No `UITextView`-based attachment pipeline.
2. No `NSTextAttachmentViewProvider` path.
3. No custom `NSTextContentManager` subclass.
4. No custom `UITextInput` implementation.

Evidence:

1. Search results show `NSTextContentStorage` usage but no content-manager subclass declarations.
   File: `/tmp/superswiftmarkup-assessment/SuperSwiftMarkdownPrototype/SSDocumentEngine/Sources/Core/DocumentViewController.swift:29`
2. No attachment API usage found in source review (`NSTextAttachment*` not present in engine/model files).

### U+FFFC limitation insight

1. Their strongest idea is to avoid attachments for table/code block semantics.
2. By keeping payload as actual text plus metadata attributes, selection/copy spans real characters instead of object-replacement characters.
3. This directly addresses the U+FFFC limitation identified in the TextKit 2 feasibility study.

## Practical Guidance for T057

1. Keep Clawline’s unified parser/renderer based on `swiftlang/swift-markdown`.
2. For continuous selection ambitions, prefer metadata-annotated attributed text and custom drawing over attachment-only block embedding.
3. Do not adopt SuperSwiftMarkup as dependency for T057.
4. Use prototype patterns selectively:
   `blockScopes`-style block metadata
   table row metadata for drawing
   viewport-conscious fragment rendering ideas
5. Keep implementation bounded to Clawline needs:
   read-only rendering
   bubble/expanded parity
   `==highlight==`
   existing Clawline theming and truncation behavior

## Open Questions for Follow-up

1. Do we want a later R&D spike for a single-text-surface renderer in expanded sheet only, with fallback to current block stack in bubble?
2. Should we mirror metadata strategy (`blockScopes`/table metadata) in our renderer model now, or keep initial T057 plan-model simpler and add metadata in T058+?
3. Should legal review AGPL/commercial posture now in case we ever want to borrow code rather than ideas?

## Appendix: Commands Executed During Review

1. `swift test` in `SSDocumentModel` and `SSDocumentEngine` (both passed placeholder tests).
2. `xcodebuild ... -scheme SSDocumentEngine -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' build` (failed with `UIColor.blended` errors).
3. `rg`/`nl` source inspection across parser, rendering, TextKit surface, and tests.
4. GitHub API checks for stars/forks/contributors/issues/activity timestamps.
