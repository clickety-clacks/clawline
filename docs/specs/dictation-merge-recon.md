# Dictation Merge Recon (Post-Fetch)

Repo: `/Users/mike/src/clawline-dictation`
Branch: `feature/voice-dictation`

This was a read-only recon pass after `git fetch origin`. No merge was started. No deploy was attempted.

## Commands Run

```bash
git fetch origin
git log origin/main..HEAD --oneline
git log HEAD..origin/main --oneline
git merge-base HEAD origin/main
```

## Updated Divergence

- Merge base: `c10be684bdb5b39cb061b2fd86e6a9327bfd376a`
- `origin/main..HEAD`: branch still has the dictation unification stack and related fixes on top of main
- `HEAD..origin/main`: `65` commits

## What We Have That `origin/main` Does Not

The branch-only range still includes the dictation unification work and follow-up fixes, including:

```text
a55866ff0 Lock dictation transcript anchor during live updates
5dd1c72ff Preserve dictation surface on background pause
ac2b5f38f Unify dictation state ownership and restore invariants
c677dcaf6 Add dictation regression coverage
78d394b47 Fix dictation drag gesture locking
4af452a05 Fix managed provider fallback and test prefs leak
...
```

## What `origin/main` Has That We Do Not

The main-only range is currently headed by:

```text
974964280 Merge branch 't155-track-untrack-impl'
b8ff8f6a3 Add engram config
3db9661ff Make popup divider explicitly visible
acc954fa3 Restore popup toolbar separator rule
df9132666 Fix popup toolbar list viewport split
ee962f6ae Fix popup footer list inset ownership
537984314 Add engram config
5a5c0edb0 Merge remote-tracking branch 'origin/main' into t155-track-untrack-impl
bc4b91ad7 Trim excessive code block indentation
98c78e3d5 docs: sync top-level docs and implementation_details from NFS
16ccf287f T168 reduce typing latency
6671b662c Wire font scale toast and reset shortcut
0f6710026 Fix live font scale rerender across chat views
cf5b54cdb T167 increase Catalyst default font sizes
...
```

The dominant feature in the main-only range is the `t155-track-untrack-impl` work, plus a small font-scale/typing-latency pass and doc syncs.

## Files Touched By Main-Only Commits

Aggregate touched files in `HEAD..origin/main`:

```text
.engram/config.yml
docs/specs/dictation-state-machine-unification.md
docs/specs/track-adopted-delivery-recon.md
docs/specs/track-non-clawline-sessions.md
ios/Clawline/Clawline Watch Watch App/Services/WatchProviderTransport.swift
ios/Clawline/Clawline/ClawlineApp.swift
ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift
ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift
ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/ScrollToBottomButton.swift
ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Theme/ChatFlowTheme.swift
ios/Clawline/Clawline/Models/SessionRegistry.swift
ios/Clawline/Clawline/Models/StreamSession.swift
ios/Clawline/Clawline/Models/UnifiedMarkdownParser.swift
ios/Clawline/Clawline/Protocols/ChatServicing.swift
ios/Clawline/Clawline/Services/ProviderChatService.swift
ios/Clawline/Clawline/Services/StreamAPIClient.swift
ios/Clawline/Clawline/Services/StubChatService.swift
ios/Clawline/Clawline/Services/ToastManager.swift
ios/Clawline/Clawline/Settings/SettingsManager.swift
ios/Clawline/Clawline/Support/AppFontScale.swift
ios/Clawline/Clawline/Support/ClawlineTypography.swift
ios/Clawline/Clawline/ViewModels/ChatViewModel.swift
ios/Clawline/Clawline/Views/Chat/ChatView.swift
ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift
ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift
ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift
ios/Clawline/Clawline/Views/RootView.swift
ios/Clawline/ClawlineTests/ChatViewModelTests.swift
ios/Clawline/ClawlineTests/ClawlineTests.swift
ios/Clawline/ClawlineTests/ProviderServiceTests.swift
ios/Clawline/ClawlineTests/ScrollToBottomUnreadTests.swift
ios/Clawline/ClawlineTests/UnifiedMarkdownRenderingAcceptanceTests.swift
ios/Clawline/Info.plist
```

## Overlap With Dictation Unification Work

Requested dictation overlap surface:

- `DictationCoordinator.swift`
- `DictationTranscriptApplicator.swift`
- `MessageInputBar.swift`
- `ChatView.swift`
- `ChatLayoutCoordinator.swift`
- `DictationCoordinatorTests.swift`
- related dictation files

### No Main-Only Overlap

There are **no main-only commits** touching these files:

- `ios/Clawline/Clawline/Dictation/DictationCoordinator.swift`
- `ios/Clawline/Clawline/Dictation/DictationTranscriptApplicator.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatLayoutCoordinator.swift`
- `ios/Clawline/ClawlineTests/DictationCoordinatorTests.swift`

That is important: the core state-machine unification work is not being directly modified by main.

### Direct Overlap

There are main-only touches to:

- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift`

### Related Dictation-Adjacent Overlap

There are also main-only touches to adjacent files that matter to dictation behavior:

- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift`
- `ios/Clawline/Clawline/Settings/SettingsManager.swift`
- `ios/Clawline/Clawline/Support/AppFontScale.swift`
- `ios/Clawline/Clawline/Support/ClawlineTypography.swift`

## Detailed Overlap Analysis

### 1. `MessageInputBar.swift`

Main changed:

- Font-scale propagation and rerender plumbing:
  - `fontScaleChangeSequence`
  - `refreshMaxBarWidth()`
  - `UIFont.clawline(.bodyText)` usage for width calculation and placeholder rendering
- Text-edit activity callback wiring:
  - `onTextEditActivity`
- Minor cleanup:
  - removed the ad hoc `OSLog` tap diagnostics in the main-only version shown by the diff from the merge base

Representative main-only commits:

- `16ccf287f T168 reduce typing latency`
- `0f6710026 Fix live font scale rerender across chat views`

We changed:

- The dictation pan gesture system and intent classification
- `DictationInteractionProjection`
- `DictationInteractionIntent`
- `DictationInteractionEmitter`
- Gesture locking / editable region arbitration
- Dictation drag teardown and selection-lock behavior
- The large refactor that turned the input bar into a dictation-aware gesture adapter

Conflict risk: **HIGH**

Why:

- Main changed the same file in active UI/editor plumbing areas.
- The branch changed this file much more heavily: `1964` lines of diff from the merge base versus main’s `44`.
- Even though main’s intent is unrelated to dictation unification, the edits land in constructor signatures, editor-chrome wiring, and state owned by the input bar. Those are classic text-level merge conflict zones.

Likely merge shape:

- Main’s `fontScaleChangeSequence` and `onTextEditActivity` additions would need to be preserved somewhere inside our much larger dictation-adapter version of the file.
- Blind “main wins” on this file would discard the branch dictation pan/intent adapter entirely.
- Blind “branch wins” would drop main’s font-scale and typing-activity changes.

### 2. `ChatView.swift`

Main changed:

- Track/untrack popup and adopted-stream flow:
  - `isTrackPickerPresented`
  - track picker presentation / dismissal flow
  - adopted-stream UX handling
- Font-scale toast and typing activity plumbing:
  - `isTypingActive`
  - `typingActivityResetTask`
  - `fontScaleChangeSequence`
  - `settings.fontScaleToastSequence`
  - `showPendingFontScaleToastIfNeeded(...)`
- Message-input wiring changes:
  - passes `fontScaleChangeSequence`
  - wires `onTextEditActivity`
- Toast banner action wiring

Representative main-only commits:

- `cb72c6991 Refine stream manager track controls and keyboard gap`
- `8e2b3bb81 Fix popup track tap and SBB fallback`
- `b023e2d4e Fetch trackable sessions for Track flow`
- `935f4e7a6 Add Track adoption ceremony and undo`
- `fafcf5f5e Restore composer focus after track picker`
- `2cdf05280 Fix track picker footer and focus restore`
- `6671b662c Wire font scale toast and reset shortcut`
- `0f6710026 Fix live font scale rerender across chat views`
- `16ccf287f T168 reduce typing latency`

We changed:

- The dictation projection/emitter contract
- Input-bar integration and dictation state projection
- Lifecycle / keyboard / selection observation paths for dictation
- UI ownership cleanup for the unification refactor
- Multiple dictation and session-surface fixes that pass through `ChatView`

Conflict risk: **HIGH**

Why:

- `ChatView.swift` is already one of the branch’s hot spots.
- Main’s changes touch the same constructor and local-state plumbing that our dictation unification also touches.
- The current branch-only diff from the merge base is already large: `644` lines changed.
- The main-only diff is not huge, but it lands in state declarations, change handlers, toast wiring, and the `MessageInputBar` call site. That is enough for either a textual conflict or a semantic conflict.

Likely merge shape:

- Main’s track picker work and font-scale plumbing need to be carried into our branch’s dictation-aware `ChatView`.
- This is the highest-risk merge file on the dictation surface.

### 3. `RichTextEditor.swift` (related dictation file)

Main changed:

- Font-scale awareness and rerender logic:
  - `fontScaleChangeSequence`
  - `UIFont.clawline(.bodyText)`
  - font-aware base-attribute reapplication
- Text-edit activity callback:
  - `onTextEditActivity`
- Minor cleanup:
  - removed some trace logging from the main-only version

Representative main-only commits:

- `16ccf287f T168 reduce typing latency`
- `0f6710026 Fix live font scale rerender across chat views`

We changed:

- Programmatic dictation update handling
- Selection callback suppression
- Dictation programmatic-edit guard behavior
- Multiple transcript-application and selection/anchor fixes

Conflict risk: **HIGH**

Why:

- This file sits directly under the dictation applicator/coordinator path.
- Main’s edits are smaller, but they touch function signatures and edit callbacks.
- The branch-only diff from the merge base is substantial: `237` lines changed.
- Even if there is no literal conflict, this is a semantic merge hotspot because both sides modify editor callback behavior.

### 4. `SettingsManager.swift`

Main changed:

- Font-scale reset helper:
  - `resetFontScale()`
- Refactor so all font-scale changes route through `applyFontScale(_:)`
- Toast sequencing remains attached to font-scale changes

Representative main-only commit:

- `6671b662c Wire font scale toast and reset shortcut`

We changed:

- Soniox and dictation-related settings work earlier in the branch history
- Dictation caustics / related settings changes

Conflict risk: **MEDIUM**

Why:

- Same file, but not the same conceptual area.
- Main is adding font-scale reset/toast behavior.
- The branch has settings churn from dictation features.
- This is more likely a non-trivial merge than a dictation correctness conflict.

### 5. `AppFontScale.swift` and `ClawlineTypography.swift`

Main changed:

- Catalyst-specific base point delta
- `scaledPointSize(for:)`
- Typography now routes through `AppFontScale.scaledPointSize(for:)`

Representative main-only commit:

- `cf5b54cdb T167 increase Catalyst default font sizes`

We changed:

- No substantial branch-only work in these files beyond earlier merges.

Conflict risk: **LOW**

Why:

- These files are adjacent to dictation UI because they affect editor and input-bar sizing.
- But they are not part of the branch’s unification logic.
- Risk is mostly “must preserve main’s font behavior,” not “likely to break transcript ownership.”

## Non-Overlap But Still Relevant Main-Only Files

These files are touched by main-only commits but are not part of the dictation unification surface requested here:

- `ProviderChatService.swift`
- `ChatViewModel.swift`
- `ChatServicing.swift`
- `StreamAPIClient.swift`
- `StubChatService.swift`
- `ProviderServiceTests.swift`
- `ChatViewModelTests.swift`

Those matter for the separate PCS / adopted-stream / track feature merge, but they are not direct overlap with the dictation state-machine unification files.

## Overall Conflict Assessment

### Safe From Main-Side Direct Conflict

- `DictationCoordinator.swift`
- `DictationTranscriptApplicator.swift`
- `ChatLayoutCoordinator.swift`
- `DictationCoordinatorTests.swift`

These have no main-only touches after the fetch.

### Main Merge Hotspots

1. `ChatView.swift`
2. `MessageInputBar.swift`
3. `RichTextEditor.swift`

These are the files where a future merge is most likely to require real judgment.

## Bottom Line

After fetching, `origin/main` is materially ahead, but the new upstream work is not editing the core dictation-unification owner files. The real merge danger is in the UI seam:

- main added track/untrack flow and font-scale/typing-latency plumbing
- the branch heavily rewired the same `ChatView` / `MessageInputBar` / `RichTextEditor` seam for dictation ownership

So the expected conflict profile is:

- **No direct conflict in the core unification owner files**
- **High conflict risk in the shared UI/editor integration files**
- **Medium conflict risk in settings/font-scale plumbing**
