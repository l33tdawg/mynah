# Store assets

icon-24.png is a monochrome adaptation of the existing Mynah bird mark.
The 24×24 pixel design preserves the Mac icon's right-facing rounded head,
beak and broad portrait bust. Its signature yellow eye patch becomes a
transparent cutout. It uses hard-edged white pixels, no grayscale or shadow,
and matches the strokes saved in Even Hub's native icon editor.

Regenerate only the icon: `python3 g2/store/make-assets.py --icon-only`.

The three 576 × 288 PNGs are rendered UI previews with sample content, not
physical glasses captures or proof that a task was executed. The sample answer
is illustrative. Do not upload these as final store screenshots: the current
[submission requirements](https://hub.evenrealities.com/docs/ship/app-submission#store-listing-visual-assets)
require screenshots matching the actual app rendering, captured through the
simulator screenshot function. Replace the three previews with captures before
submission; preserve the originals as design references.

Regenerate: python3 g2/store/make-assets.py

## Actual simulator capture

`simulator-first-run.png` is the unmodified 576×288 RGBA framebuffer from the
official Even Hub simulator 0.9.3 running the current app on localhost. It shows
"MYNAH / Connect on your phone to begin." Captured September 5, 2026 through
the documented `/api/screenshot/glasses` endpoint and visually verified with
transparency rendered by the browser. Preserve the alpha channel: the simulator
stores green in RGB even for fully transparent background pixels.

This image was uploaded to Even Hub and paired with its Home backdrop for the
listing cover. The portal icon is a crisp monochrome bird traced from the
existing mark using its native 24×24 editor. No hardware test is implied by
either asset.

## Task-list cover replacement

`simulator-tasks.png` is a 576×288 RGBA capture from the official simulator,
using the production reply handler, pagination and SDK renderer with sample
task data. It shows a three-item task list and a follow-up question. It contains
no private tasks and is not evidence of live task retrieval or execution.

Reproduce from `g2`: `npx vite --config store/capture.vite.config.ts`, launch the
official simulator at `http://127.0.0.1:5173 --automation-port 9898`, then save
`http://127.0.0.1:9898/api/screenshot/glasses`. Preserve alpha. The separate
serve-only config never runs in normal dev/build/pack. Production build and
five tests passed; the sample strings are absent from `dist`.

Visually verified all three tasks and the follow-up fit without clipping.
Uploaded and saved to Even Hub after the user refreshed Chrome. The task-list
capture now replaces the first-run screenshot and is the Home-background cover.
The original first-run PNG remains available locally for recovery/reference.

## Dashboard replacement — September 8, 2026

`simulator-dashboard.png` is a fresh, unmodified official simulator framebuffer
capture of companion 0.2.0: dot-matrix clock, date, battery, optional weather and
spacious queue cards. Sample questions and weather are illustrative. The capture
uses `capture.vite.config.ts`; production builds do not include the fixture.
The same capture is used on GitHub Pages as `mynah-g2-dashboard.png`.

`simulator-dashboard-selected.png` shows the same dashboard after scrolling to select the first question. Both updated screenshots preserve simulator alpha.

Both dashboard captures replaced the old task-list screenshot in Even Hub on September 8, 2026, with the first dashboard selected as the Home-background cover. The website uses only the Even promotional photo and the first dashboard capture, per the owner’s two-image layout preference.

The two dashboard captures were refreshed for 0.2.1 with wider, centered clock digits and a 12-pixel inter-digit gap.
