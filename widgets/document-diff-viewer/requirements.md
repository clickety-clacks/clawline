# T1268 Document Presenter Requirement Matrix

Source requirements:
- T1268 live ticket context retrieved from Janus on 2026-06-09.
- T1263 source spec: `/Users/mike/.openclaw/workspace/www/specs/document-diff-viewer-widget.html`.

## Event-driven document updates

| ID | Requirement | Source | Status |
| --- | --- | --- | --- |
| T1268-E1 | The privileged document reader owns file/source change detection. | T1268 expected behavior; T1263 R16 | Source-ready in `reader.ts`. |
| T1268-E2 | Native file events are the primary path when available. | T1263 R4, R16 | Source-ready via `fs.watch`. |
| T1268-E3 | Bounded polling is service-side fallback only. | T1263 H5 | Source-ready via reader fallback timer. |
| T1268-E4 | The widget receives document-id change events and then fetches the new snapshot/diff. | T1268 desired outcome; T1263 R16 | Source-ready in `document-diff-viewer.html`. |
| T1268-E5 | Browser-side polling is not the primary live update mechanism. | T1268 observed bug | Source-ready: widget has no `setInterval` polling path. |
| T1268-E6 | Preserve the security boundary: no arbitrary filesystem serving, no raw path leakage in fetch/update calls. | T1263 R13-R15 | Source-ready: registration allowlists explicit files/roots and returns opaque ids. |

## Wiki-style document requirements

These requirements are not fully captured in the T1263 source spec. They are recorded
as missing product decisions instead of implemented by inference.

| ID | Missing product decision | Source |
| --- | --- | --- |
| T1268-W1 | Whether wiki links use `[[Title]]`, Markdown links, both, or another syntax. | T1268 ticket wiki-doc gap. |
| T1268-W2 | How linked document identity resolves: title, slug, path, opaque document id, or workspace-relative target. | T1268 ticket wiki-doc gap. |
| T1268-W3 | Whether the presenter must render backlinks, a related-doc graph, a related-doc list, or no relationship surface. | T1268 ticket wiki-doc gap. |
| T1268-W4 | Anchor/heading navigation behavior for linked docs, including missing-heading handling. | T1268 ticket wiki-doc gap. |
| T1268-W5 | Whether opening linked docs replaces the current presenter, opens a side-by-side comparison, or opens another widget/surface. | T1268 ticket wiki-doc gap. |

