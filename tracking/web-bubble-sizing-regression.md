# Web Bubble Sizing Regression

## Status
Ready for the product owner verification on branch `clawline-web-parity-layout-batch`.

## Source Truth
Checked source docs on 2026-05-09:

- `~/shared-workspace/clawline/ios-flow-layout-rules.md`
- `~/shared-workspace/clawline/implementation_details/bubble-sizing-v2.md`
- `~/shared-workspace/clawline/implementation_details/efficient-flow-layout.md`

The relevant product rule is that even content-fit / wide markdown bubbles should preserve a comfortable max width instead of stretching to the full transcript viewport.

## Implementation Notes
`useVirtualMessageWindow` now caps wide and truncated estimated bubble width at the comfortable line cap instead of using the full container width. The change keeps row placement owned by the virtual layout while preventing wide bubbles from becoming fullscreen-width on desktop/tablet viewports.

## Evidence
Recorded 2026-05-09 10:05 PDT from `~/src/worktrees/clawline-web-parity-layout-batch`:

- `npm run build`: PASS.
- `npm run test`: PASS, 23 files / 182 tests.
- `npm run test:e2e -- playwright/tests/phase5-flow-layout.spec.ts`: PASS, 5 tests, all using local `clawline_web_test` harness identity. Browser assertion verified a wide markdown bubble stayed `<= 620px` and substantially narrower than the transcript viewport.

Recorded 2026-05-09 17:21 PDT after impl-agent review from `~/src/worktrees/clawline-web-parity-layout-batch`:

- Review result: initial review found the new resting-bottom math ignored the scroll container's actual bottom padding. Fixed the virtual window's resting bottom to derive from the real container scroll range and subtract only the footer reveal region, preserving composer-safe padding while keeping the footer hidden until extra manual scroll.
- `npm run build && npm run test && npm run test:e2e -- playwright/tests/phase5-typing-indicator.spec.ts playwright/tests/phase5-flow-layout.spec.ts`: PASS. Build succeeded with the existing Vite large-chunk warning; unit suite passed 23 files / 184 tests; affected Playwright specs passed 7 tests.

Recorded 2026-05-09 17:24 PDT after safe main push and Provider-host deploy:

- Product-code commit pushed to `origin/main`: `36e23855f52928103ab56b0d055500efa2b70559`.
- Provider-host deploy command: `rsync -a --delete dist/ user-a@provider-host:'~/Library/Application\\ Support/ClawlineWeb/dist/'`.
- Smoke/hash: `http://192.0.2.10:4173/`, `/chat/test`, and `/pair` returned `HTTP/1.1 200 OK` and served `assets/index-CCACm0zW.js` plus `assets/index-B0esVyXO.css`.
- Hash match: `dist/index.html` and served `/` both `0cecf7fa395acfe45e5d253db7da47695428ba1b2f8cc9ad495772278cdde0b3`; JS both `41d28c37889806a7e1e8ec90243652dfe114f1f8f8d648ed2b7e51753a77dea2`; CSS both `a0b389e8b1b1e27706013c41f7733205e15a55f7ccc4b4f6070ab7fe83adb1ac`.
