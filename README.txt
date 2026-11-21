MOSS Image Studio - portable build (v0.1.99)
============================================
MOSS is a graphical front-end (GUI) for the sd-cli command-line engine: every
render is a command line run of bin\sd-cli.exe, and MOSS can show you the
exact command it runs (see Options).
Unpack this ZIP into any folder you like (for example E:\MOSS\). All paths are
resolved relative to the application folder, so MOSS can be moved to another
drive or computer at any time.
Start MOSS with MOSS-Image-Studio.bat (or MOSS-Image-Studio.vbs).
The launcher locates Windows PowerShell 5.1 directly in its standard Windows
installation location, even when PowerShell is not on the PATH.
The PowerShell console is hidden as soon as MOSS starts (password prompt
included); the MOSS application stays visible and shows its current version
in the title and header.
Closing MOSS ends its launcher and PowerShell host, and stops active image-engine
processes. Temporary update files are removed after installation or download failure.

Prompt history code
-------------------
Access to saved prompts is protected by the prompt-history code you choose; the
code itself is never stored. If you forget it, MOSS can continue without history
while preserving the encrypted history until you reset it.

Image generation
----------------
- Choose a visual style: Photorealistic, Anime, Digital illustration, Oil painting,
  Watercolor, 3D render, Comic book, or Cinematic.
- MOSS adds the selected style guidance to the generation prompt.
- Prompts are sent to the engine as a single line. Pasted multi-line text is
  flattened automatically, so no characters are lost.
- During generation, MOSS shows text progress and total elapsed time for the
  entire image batch, with an ETA when the engine reports step progress or
  enough images have completed. CPU offload is selected automatically only when
  detected GPU memory is too limited for the model.
- Batch size has no cap: type any whole number of images (1 and up). Common
  sizes are offered as presets (1 to 1000), and a plain-language warning with
  a rough runtime estimate appears before very large batches. Cancel stops a
  long batch at any time; Cancel or closing MOSS also stops the engine and
  its child processes.
- Multiple images are rendered in a single engine run: the model is loaded once
  and the prompt conditioning is reused for every image in the batch, which is
  noticeably faster than restarting the engine for each image. Seeds increment
  automatically (base seed, base+1, ...) exactly as before.
- Render speed selector (next to the image settings): Exact (full quality),
  or faster modes that render at a reduced size with the FULL step count and
  then upscale the finished image in pixel space (high-quality bicubic).
  No second sampling pass runs, so results are faithful - possibly grainy or
  soft at high speeds, but never distorted. Measured on an RTX 3080 Ti at
  2K portrait, 50 steps: Exact about 4 minutes; ~2x (upscale from 70%)
  about 2 minutes; ~4x (upscale from 50%) about 1 minute. Draft modes are
  good enough to see what the picture is; at ~4x the result can be visibly
  soft - right-click it and choose Improve (the sharp modes there produce
  first-run-level detail on native sources). Use Exact when detail matters.
  Multipliers are approximate and vary with size and step count. Works the
  same on NVIDIA, AMD, Intel and CPU builds.
- Weight placement (GPU, then RAM, then disk as needed) is decided by the
  engine's built-in auto-fit system, which works the same way for NVIDIA, AMD,
  Intel and CPU builds. MOSS no longer forces a CPU-offload mode itself.
- Cancel stops the active engine process and its child processes, then reports
  that generation was cancelled.
- Images are saved under outputs\ by default (configurable in the app).
  Installs that still point at the old outputs\admin default are moved to
  outputs\ automatically; folders you chose yourself are never changed.

Improving generated images (right-click)
----------------------------------------
- In the "Generated files" list, right-click any image:
  "Improve this image (same seed and composition)..." opens the improve
  dialog: MOSS re-renders exactly that picture (same seed and prompt, read
  from the image's sidecar) with image-to-image - the composition stays,
  the detail is reworked. Three quality modes:
  * "Same size (fastest) - plain improve": re-renders at the image's own
    size. Good for refreshing a native render; it cannot add detail that
    an upscaled draft never had.
  * "Sharp - fast upscaler" (default for drafts): renders at HALF the
    image's size in ONE pass, then the ESRGAN upscaler model sharpens and
    enlarges to about 2x - the fastest sharp result (needs the upscaler
    model file; MOSS offers the download).
  * "Sharp - detail regeneration" (slowest, 3-4x): the composition pass at
    the image's size, then a full second sampling pass at 2x.
  The target size (Same/2x/4x buttons) applies to the plain mode; steps,
  CFG and seed are prefilled from the image and editable, and the time
  estimate in the dialog comes from your own measured runs.
  Note: images that were rendered TINY and enlarged (drafts of the very
  soft speed modes that were removed in v0.1.93) cannot be made first-run
  sharp by any improve mode - the dialog says so when it detects one.
- "Improve ALL files that can be improved..." queues every generated image
  that still has quality headroom: soft fast-mode previews, renders with
  fewer steps than the current setting, or images smaller than the current
  size (scaled up with the aspect preserved). Files already at full quality
  or with an improved copy are skipped and reported in the confirmation.
- "Re-render with this image's OWN seed..." is a brand-new full-quality
  render from the image's seed, prompt and settings - a related look, but
  the composition can differ from the draft.
- "Show image info (prompt, seed, settings)..." displays what the image's
  sidecar recorded.
- The improve strength is set in Options ("Improve strength"): 0.45 keeps
  the look, 0.6 refreshes detail, 0.8 re-renders strongly.
- Improved files carry ..._hq_01.png in the name; the sidecar records the
  actual output size and which improve mode made it.
- A typical workflow: render a fast preview batch with the speed selector,
  right-click "Improve ALL files that can be improved" and let MOSS work
  through the good ones while you look at something else.
- If you know the prompt-history code, MOSS reuses the exact prompt of the
  improved image; otherwise it uses the text currently in the prompt box.

- Right-clicking a file in the list selects it automatically, so Improve
  always acts on the file you clicked.
- "Delete selected file(s)..." removes the image(s) (and their sidecars)
  from disk and the list after a confirmation.

Generated files list
--------------------
- The list shows ALL images ever generated into the output folder, not just
  the ones from this session. The newest is selected when MOSS starts.
- Left-click shows the image in the preview pane; right-click offers the
  improve and delete actions.

Generation options (Options...)
-------------------------------
- The "Options..." button next to Image settings opens one dialog with the
  negative prompt, sampler and scheduler.
- Negative prompt: what the image should NOT contain (e.g. blurry, extra
  fingers, watermark). Empty means no negative prompt is sent. It is stored
  in the config and, like the positive prompt, encrypted in the image
  sidecars.
- Sampler and scheduler: "Default (model)" omits the flag, so the engine
  keeps its model-specific choice (recommended). The lists are the exact
  values supported by the bundled engine for experimenting.
- Improving an image reuses that image's own sampler, scheduler and negative
  prompt when they are recorded in its sidecar.

What is new in v0.1.99
-----------------------
- RESOLUTION NOW SITS UNDER VISUAL STYLE (your tidy-up): the two selectors
  are stacked in one column on the left; Width/Height keep their place to
  the right of them. Same snug widths as before.
- NORMAL-CASE TEXTS: 'PROMPT' -> Prompt, 'VISUAL STYLE' -> Visual style,
  'OUTPUT PREVIEW' -> Output preview, 'GENERATED FILES' -> Generated
  files, and the render button is 'Generate' instead of 'GENERATE'.
  (The header title 'MOSS / IMAGE STUDIO' and its uppercase tagline stay
  as branding - say the word if you want those normal case too.)
- VISUAL ARTIFACT HUNT (button texts measured against their widths with
  real text metrics, not eyeballed): 'Open output' was clipped to
  'Open outpu' at 84 px - widened to 92 px. Every other button and label
  now provably fits its control.
- 47 checks in test_v0196.ps1 pin the stacking, the casing and the
  measured button widths; all suites green: 239 tests.

What is new in v0.1.98
-----------------------
- THE HEADER OPTIONS MENU IS NOW THE HOME FOR APP-LEVEL ENTRIES (your
  tidying): Output folder..., Model files..., Benchmarks... and Error
  report joined Hardware / Setup, Update engine and Update MOSS in the
  'Options' dropdown at the top right. The main window now holds ONLY
  generation controls.
  * Output folder...: opens the folder picker; the item label shows the
    current folder's name while the menu is open.
  * Model files...: opens a dialog with the four model file paths and a
    live 'all found / N missing' health line; OK applies the changes,
    Cancel discards. The menu label shows the health count.
  * The in-panel Output folder row, the Model files section, the Error
    report button and the Benchmarks button are GONE. Your generation
    settings (prompt, style, resolution, steps, CFG, images, seed, speed)
    stay on the main window; generation itself works exactly as before.
- MUCH SHORTER WINDOW: 1052 x 551 (was 607 tall) - the freed rows no
  longer exist, and the action row (GENERATE | Cancel | Pause | Open
  output) sits directly below the speed hint. Minimum window 900 x 550.
- Also carried in this version: the negative prompt box in Options is the
  same size as the main prompt box (331 x 96), dropdowns fit their text
  'but only barely', the in-panel generation button is named 'Generation...'
  and the IMAGE SETTINGS heading was removed.
- 45 checks in test_v0196.ps1 pin all of the above; all suites green:
  237 tests.

What is new in v0.1.97
-----------------------
- NARROWER WINDOW (your 'more compact width wise'): 1052 px wide (was
  1180). The left settings panel shrank from 700 to 620 px and the
  preview panel from 415 to 380 px; the minimum window is now 900 px
  (was 1000). The settings grid's second column moved left to use the
  freed space (Resolution / Width / Height / Seed).
- HEADER FOLDED INTO ONE OPTIONS MENU (your idea that Update engine /
  Update MOSS / Hardware Setup 'are really options'): one 'Options'
  button in the top-right opens a dropdown with Hardware / Setup...,
  Update engine... and Update MOSS... (tooltips on each item). The
  three separate header buttons are gone.
- DROPDOWNS FIT THEIR TEXT, BARELY (your rule): the visual style combo
  (215 -> 160 px), resolution combo (215 -> 190), speed selector
  (shortened labels '~2x faster (70%)' / '~4x faster (50%)') and in the
  Options dialog the sampler (250 -> 130) and scheduler (250 -> 175)
  combos are only as wide as their longest entry needs. The open list
  still auto-expands to the longest item, so nothing is hidden.
- OPTIONS DIALOG: the negative prompt box is no longer huge - it is now
  the SAME size as the main-window prompt box (331 x 96, scrolls). The
  in-panel button was renamed 'Generation...' so it cannot be confused
  with the new header Options menu (it opens negative prompt, sampler
  and scheduler).
- 61 unit tests in test_v0196.ps1 (was 49) pin all of the above; all
  suites green: 253 tests.

What is new in v0.1.96
-----------------------
- COMPACT UI, ACTION BUTTONS HALF SIZE (your request): the button row
  (GENERATE | Cancel | Pause | Open output | Error report | Benchmarks)
  is now 24 px tall (was 42) with narrower widths, and it FLOWS: it is
  placed directly below the last visible setting (the Model files
  section), so the large empty band that used to sit above the buttons
  is gone. With Model files collapsed the row moves up about 100 px;
  expanding Model files moves it down again and grows the window only
  by the space actually needed (collapsing shrinks it back - never
  more than MOSS itself grew it, your own window resizes are kept).
- WHOLE WINDOW COMPACTED: default size 1180 x 607 (was 1180 x 850),
  header 50 px tall with a 13 pt title and 24 px header buttons, all
  setting rows tightened (23 px fields, 26 px row pitch). Everything
  fits without dead space; the two-line status line and the progress
  bar flow right below the action row instead of hanging at a fixed
  bottom edge.
- The speed hint under the speed selector is rewritten shorter and no
  longer clipped (all 3 lines fully visible).
- Kept unchanged: the 331 x 96 half-width prompt box (v0.1.95), the
  responsive header placement, and the shrink-to-work-area behavior on
  small screens.
- 49 new unit tests (test_v0196.ps1) including a real behavioral test
  of the flow layout (collapsed/expanded row positions, window grow
  and shrink). Also repaired two silently broken older checks: the
  button-overlap loop in test_v0191 aborted on a PowerShell case
  sensitivity bug ($A vs $a are the same variable - it passed
  vacuously), and test_v0194's README-body slice included the newer
  changelog entries, whose own "what changed" wording tripped the
  no-legacy-_hq2x check. All suites green: 241 tests.

What is new in v0.1.95
-----------------------
- PROMPT BOX HALF WIDTH: the prompt editor is now 331 px wide (half of
  its previous full-panel width) with the same 96 px height (4 lines).
  It keeps that size when the window grows (no right anchor). Long pasted
  prompts still work: the box scrolls, and pasted multi-line text is
  flattened to one line for the engine.
- Tested with the kept suites; all 192 tests still pass.

What is new in v0.1.94
-----------------------
- CLEANUP OF REMOVED-FEATURE LEFTOVERS (your request): no more info about
  things that were removed or are not used any more.
  * README manual: the speed-selector section no longer describes the
    removed 8x/Fastest modes (now Exact / ~2x / ~4x with the measured
    times); the improve section now describes the ACTUAL right-click menu
    ("Improve this image (same seed and composition)..." with the three
    quality modes, "Re-render with this image's OWN seed...", "Show image
    info") instead of the old two-item menu, and the legacy _hq2x file
    tag mention is gone (every improved copy is ..._hq_01.png; the
    sidecar records the actual size and mode).
  * The speed dropdown's tooltip no longer talks about the removed
    modes; a stale code comment about the _hq2x tag was corrected.
  * Kept ON PURPOSE: the internal engine support for old 8x/Fast data
    (old benchmark entries, old queue items, the OOM auto-retry ladder)
    and the improve-dialog warning for old ultra-soft files - those are
    still needed for files that already exist.
- Tested with 10 new unit tests (test_v0194.ps1) that pin the manual
  text to the real app; all 182 previous tests still pass.

What is new in v0.1.93
-----------------------
- 8x AND FASTEST SPEED MODES REMOVED (your decision, backed by the
  measurements): their drafts are rendered at only 35% of the size
  (or a 128-pixel side) and the blur is baked into the pixels - no
  improve mode can rescue them (proven with the controlled A/B in
  v0.1.92). The speed dropdown now offers Exact (full quality),
  ~2x faster (70%) and ~4x faster (50%); the bigger-jobs estimator in
  the Benchmarks dialog matches. Old benchmark entries and old files
  made with those modes still display, are still estimated and their
  info still works - the engine and all internal helpers (including
  the OOM auto-retry ladder) still support the modes. Old ultra-soft
  files still get the honest improve-dialog warning.
- Tested with 15 new unit tests (test_v0193.ps1); all 167 previous
  tests still pass.

What is new in v0.1.92
-----------------------
- THE TRUTH ABOUT 'NOT SHARP' (you were right to be suspicious - the
  measurements settle it): fast sharpen WAS working - your improves came
  out at 5120 x 2880 with the ESRGAN model loaded and running. Measured
  detail (full-image laplacian, matched scale): your improve of the
  NATIVE planets render reached 1421 - essentially the sharpness of a
  fresh first-run render (1431). What could NOT be sharpened was the
  FASTEST draft: it was rendered at only 227 x 128 pixels and enlarged,
  so the blur is baked into the pixels; a controlled A/B on that exact
  source (same seed, 50 vs 100 chosen steps) landed at the SAME softness
  both times (58 vs 58). No improve mode can create first-run detail
  from an ultra-soft draft - that is a physical limit of image-to-image,
  now proven twice on real runs.
- HONEST WARNING FOR ULTRA-SOFT DRAFTS: the improve dialog's fast
  sharpen confirmation now says up front when the selected image is an
  ultra-soft draft (rendered tiny, then enlarged): the copy will stay
  soft, render fresh at full quality for a sharp image. Detection is a
  new helper (Test-MossUltraSoftDraft): sidecar speed mode Fastest/8x,
  or a pixel-enlarged source with a side of 320 px or less.
- SIDECAR BUG FIX (regression): a fast-sharpen improve is a single-image
  job and its sidecar is written by the BATCH-END path - which had LOST
  the v0.1.84 fixes in a later edit round: it recorded the RENDER size
  (e.g. 1280 x 720 in the sidecar of a 5120 x 2880 file), no 'fast
  sharpen (<model>)' note and no HiresScale field. The batch-end path
  now records the ACTUAL file size, the fast sharpen note and
  HiresScale, exactly like the live path. The three improves from
  today's testing were corrected in place. Verified with a test that
  runs the exact shipped sidecar code against a real 5120 x 2880 file.
- Tested with 19 new unit tests (test_v0192.ps1); all 148 previous
  tests still pass.

What is new in v0.1.91
-----------------------
- PAUSE / RESUME FOR RUNNING RENDERS: a new Pause button in the main
  window freezes the RUNNING engine process mid-batch for real (Windows
  ntdll NtSuspendProcess - not a fake pause): sampling stops where it
  is, nothing is lost, images already saved are kept. Resume continues
  the same run. Made for large batches you want to put on hold (render,
  pause overnight or while you use the PC for something else, resume
  later). While paused the status line says so, the ETA and the power
  meter exclude the paused time (the resumed run's total time stays
  honest), and VRAM stays allocated - that is inherent to a frozen
  process. Pause works for fresh renders and for the improve queue
  alike; Cancel still works while paused; if the engine dies while
  paused, the run completes normally.
  Verified on a REAL engine run: 15 steps rendered, frozen for 8 s (the
  step counter stayed at exactly 15), resumed, the run finished all
  images. Plus 43 new unit tests.
- LAYOUT FITS SMALLER SCREENS NOW (2K / 1080p / resized windows):
  the window used a fixed 1180 x 850 design and the header's BACKEND
  badge and buttons were anchored to the RIGHT edge - on narrower
  windows Windows slid them LEFT on top of the MOSS version title
  (text behind text). The whole header right side (badge + 3 buttons)
  is now re-placed on every resize: buttons from the right edge, the
  BACKEND badge between title and buttons, clamped so it can never
  overlap the title whatever the width. Long GPU names in the header
  subtitle are shortened with an ellipsis.
- SMALL SCREENS: on a screen whose work area is smaller than the
  window (e.g. 1366 x 768 laptops), the window now shrinks to the work
  area on startup instead of being cut off at the bottom, and the
  minimum size adapts to what the screen actually offers.
- COMPACT MAIN WINDOW: the prompt box is 96 px tall (4 lines) instead
  of 150 px, and everything below moved up accordingly - the whole
  settings block and the GENERATE row sit 54 px higher, so they stay
  visible even in short windows. The drop-down lists open with 5-7
  visible items (scroll for the rest) instead of spanning the screen.
- TWO-LINE STATUS LINE: the bottom status line (progress %, step N/M,
  ETA, watts, notes) now wraps over TWO lines instead of truncating
  with '...' on one line (same position, progress bar below it).
- The GENERATE row is now GENERATE | Cancel | PAUSE | Open output |
  Error report | Benchmarks (no overlapping buttons; verified by a
  layout test that checks every button rectangle).
- Tested with 43 new unit tests (test_v0191.ps1); all 105 previous
  tests still pass (32 + 30 + 20 + 5 + 18 kept suites).

What is new in v0.1.90
-----------------------
- BUG FIX - FAST SHARPEN ACTUALLY SHARPENS NOW: the improve dialog and
  'Improve all' selected the upscaler model for the fast-sharpen mode,
  but the queue runner DROPPED it before starting the engine - every
  fast sharpen silently ran as a HALF-SIZE plain improve with no
  sharpening at all (your 688 x 384 result instead of a sharp
  2720 x 1536). The model now reaches the engine.
- SHARP MODES RUN FULL STEPS: the fast sampler's step-halving now
  applies to PLAIN improves only. For the sharp modes (fast sharpen /
  detail regeneration) ALL chosen steps run - measured on a real draft
  with a matched measurement scale: fast sharpen at 58 engine steps
  reached a detail metric of 387, at the full 134 steps it reached 1308
  (16x the plain improve's 80, the draft itself was 81). The end-to-end
  fixed fast sharpen took 33 s and produced the sharpest improve of
  every tested pipeline; the sampler speed advantage is kept.
  If you picked a sampler yourself in Options it is still used exactly
  as chosen.
- Tested with 18 new unit tests; all 87 existing tests still pass.

What is new in v0.1.89
-----------------------
- OPTIONS NOW SAVE IMMEDIATELY (bug fix): the Save button in Options
  updated the running app but did NOT write settings.json - the change
  only reached disk at the NEXT generation. Deleting the negative
  prompt and restarting MOSS brought the old text back (user report);
  the same silent revert affected the sampler, scheduler, improve
  strength and the Safe mode checkbox. Options changes now persist the
  moment you click Save: delete the negative prompt, restart, and it
  stays empty. A deliberately set negative prompt still persists.

What is new in v0.1.88
-----------------------
- FASTER, MORE PRECISE DOWNLOAD SPEED MEASUREMENT: the 4 MB probe that
  estimates 'this download takes about X minutes' no longer makes you
  wait - it now gives up after 8 s (connect) / 5 s (stalled read) and a
  hard 5-second wall budget (the old version could block a dialog for
  20+ seconds on a bad connection). The speed is computed WITHOUT the
  first 0.5 MB (TCP slow start / TLS ramp-up measure connection setup,
  not the steady speed a multi-GB download settles at) and reads up to
  6 MB within the budget.
- IT LEARNS FROM YOUR REAL DOWNLOADS: every completed model download
  records its true average speed (config\downloadspeed.json, last 3
  kept, logged as 'Model download ok (X GB at Y MB/s)'). The next
  estimate then prefers a real measurement less than 7 days old
  outright (no probe, dialog opens instantly); otherwise the fresh
  probe is blended 50/50 with the last real number.

What is new in v0.1.87
-----------------------
- POWER METER with cumulative totals: MOSS now measures the GPU's power
  draw while the engine renders and integrates it over time. The live
  draw is shown in the status line during a run ('~231 W (measured)')
  and the Benchmarks dialog gained a Power meter section with
  SESSION (since app start), TODAY and ALL TIME totals (kWh, hours of
  rendering, runs, images) plus a reset button for the cumulative
  numbers.
- MEASURED where possible: on NVIDIA machines the draw is read from the
  driver (nvidia-smi, present on this PC) - real measurements. On other
  vendors (AMD/Intel) or when the tool is absent, the draw is estimated
  from the GPU's rated board power (75% of TDP, 250 W typical when
  unknown) and clearly labelled '(estimate)'. Each total shows how much
  of it was measured directly.
- The per-run energy lands in config\energy.json as day buckets plus an
  all-time bucket (730 days kept); every finished run - even a failed or
  cancelled one - records the power it actually drew, and the generation
  log notes the kWh per run.

What is new in v0.1.86
-----------------------
- FAST SAMPLER DEFAULT FOR IMPROVES (verified on this PC): the improve
  dialogs now have a 'Fast sampler' checkbox (ON by default). It renders
  improves with the dpm++2m sampler + karras schedule at HALF the chosen
  steps: verified same detail at roughly HALF the time (euler 67 steps
  took 40.9 s; dpm++2m+karras 34 steps took 24.3 s at 1360 x 768, same
  seed - sharpness metric 30.1 vs 26.9, i.e. equal or slightly better;
  and the full v0.1.86 default path for 'improve at 100 steps' now takes
  47 s instead of about 100 s). Uncheck it (or pick a sampler/scheduler
  in Options) to keep the previous behavior - your explicit choice is
  always used exactly as picked, and the checkbox disables itself when
  you have chosen a sampler or scheduler in Options.
- BLANK-IMAGE BUG SHIELD: the engine REJECTS some scheduler/sampler
  combinations with an error line and then CONTINUES RENDERING - the
  saved image comes out blank white (verified: scheduler 'ays' with
  'dpm++2m' rendered a fully white picture with exit code 0). MOSS now
  detects that rejection in the engine output, tells you clearly in the
  log and status line ('scheduler was REJECTED by the engine') and saves
  a technical report to the logs folder. The scheduler descriptions in
  Options carry the verified warning for 'ays' and the in-house facts
  for 'karras' and 'dpm++2m'.
- Every sampler (21) and scheduler (17) offered in Options was verified
  against the real engine on this model (each one rendered a valid
  image); the 'ays' limitation is the only incompatible combination
  found.

What is new in v0.1.85
-----------------------
- FAST SHARPEN - improves are now up to 25x faster when you want a sharp
  2x copy: the improve dialog offers three quality modes - 'Same size',
  'Sharp - fast upscaler' (default for drafts) and 'Sharp - detail
  regeneration' (the previous pipeline, kept for best composition
  fidelity). Fast sharpen renders at HALF the image's size in ONE pass
  and the ESRGAN upscaler model then sharpens/enlarges the result to
  about 2x - verified on this PC: the same improve took 36 s instead of
  ~14 min, and its sharpness metric (laplacian variance) measured 1016
  vs 363 for the detail-regeneration output. The 'Improve all' dialog
  offers the same three modes for the whole batch.
- YOUR CHOICE OF UPSCALER: the dialogs show every .pth model in
  models\upscalers and use exactly the one you pick (an anime or
  black-and-white specialist model works the same way) - MOSS never
  overrides that choice. Output size follows the model (the standard
  x4 model gives 2x from a half-size render).
- THE UPSCALER IS PART OF THE STANDARD INSTALL: on first start (and in
  'Update engine...') MOSS treats RealESRGAN_x4plus.pth like any other
  model file - it is offered for download with the rest, and update
  checks compare local vs remote size to detect new versions. If the
  download is unavailable (offline / source down), MOSS keeps working:
  the fast option is disabled and drafts fall back to detail
  regeneration - the pipeline that always worked (also at render time,
  if the file vanishes between dialog and render).
- Notes: the upscaler needs no extra VRAM budget beyond the render; the
  sidecar records 'fast sharpen (<model>)' and the actual output size;
  fast runs are recorded in the benchmark table as plain img2img runs at
  the half-size render (their times are honest estimates for the mode).

What is new in v0.1.84
-----------------------
- SIDECARS RECORD THE REAL IMAGE SIZE: the settings file next to an
  improved image used to store the requested render size - for a detail
  regeneration (highres) run that is the BASE size, while the actual
  file is 2x bigger (live case: the sidecar said 1360 x 768 for a
  2720 x 1536 image, which would mislead a later improve or the image
  info dialog). The sidecar now always records the ACTUAL saved size
  (read back from the finished file), plus the hires scale when one ran.
  The two existing hires sidecars on this PC were corrected in place.
- NOTE: improving the same image twice with the SAME seed, prompt and
  settings gives a BIT-IDENTICAL copy - the engine is deterministic
  (verified: two runs of the same improve produced identical files).
  That is expected, not a bug: for a different result change the seed
  (e.g. -1) or the strength, or use 'Re-render from seed'.

What is new in v0.1.83
-----------------------
- HONEST PROGRESS FOR DETAIL REGENERATION: a hires improve samples TWICE
  in one engine run - the base pass keeps the composition (fast), then
  the highres pass re-synthesizes sharp detail at 2x (the slow part).
  Previously the second pass's step bar RESTARTED at 1/N, so the progress
  bar fell back toward 0% and the naive ETA extrapolation exploded (live
  case: 'ETA ~30 min' right after the base pass had finished). The status
  line now tracks the two phases separately: it shows 'pass 1/2' /
  'pass 2/2' with the step counts, the progress bar counts BOTH passes
  and never runs backwards, a log line says when the base pass is done,
  and the ETA is computed from the benchmark store's base/second-pass
  parts (no more extrapolation blow-ups). 42 regression tests.
- REAL TIME ESTIMATES IN THE IMPROVE DIALOG: the popup no longer claims
  a hardcoded 'about 15 minutes at 100 steps' that ignored the image
  size and steps. The dialog now shows a live estimate under the fields
  (updates with size, steps and the detail-regeneration checkbox), and
  every start popup quotes the estimate extrapolated from YOUR measured
  runs (with a plain 'no benchmark data yet' fallback). The bulk improve
  dialog reuses the same estimator.

What is new in v0.1.82
-----------------------
- BENCHMARKS NOW UNDERSTAND DETAIL REGENERATION: a hires improve run used
  to be recorded as a PLAIN img2img run of the same size and steps - the
  853-second verify run made every future plain 1360 x 768 estimate
  about 5x too slow, and a hires job's own ETA only counted the base
  pass. Now: hires runs are recorded with their scale (and their true
  source size), get their own row in the benchmark table ('img2img +
  highres 2x'), are excluded from every plain estimate, and a hires
  job's ETA is estimated as base pass + highres second pass. The one
  known hires entry already in the store was re-labelled (it is the
  documented v0.1.81 verify render). Verified against the real data:
  plain 1360 x 768 estimates ~3 min again, a hires estimate ~12 min
  (the real run took ~14).
- IMPROVE ALL NOW OFFERS DETAIL REGENERATION: the bulk improve dialog
  shows which files qualify and why, a rough TOTAL time estimate from
  the benchmark store, and an opt-in 'Detail regeneration (highres
  fix)' checkbox that applies ONLY to the soft fast-mode drafts (much
  sharper, output 2x each draft's size, about 3-4x the render time per
  draft). Files that are merely small or were made with fewer steps are
  native-quality renders and gain nothing from a hires pass - they are
  never given one. Without the checkbox the drafts stay soft (MOSS says
  so and asks once), matching the single-image improve dialog.
- The improvement log now states the size the finished file will really
  have for detail-regeneration runs (base x 2), and an out-of-memory
  auto-retry of a hires run says plainly that the retry runs WITHOUT
  detail regeneration (the enlarged second pass is what ran out of
  memory) and how to get a sharp copy afterwards.
- Verified with a real engine render: bulk-style hires job (640 x 384
  source, 2x) produced its sharp 1280 x 768 output
  (benchmarks\repro_bulk_hires82_01.png).

What is new in v0.1.81
-----------------------
- IMPROVE QUALITY FIXED: improving an upscaled fast draft no longer
  delivers a soft copy. Verified cause: a plain img2img CANNOT make an
  upscaled draft sharp - the blur is part of the structure it follows
  (measured: the improved copy was no sharper than the draft at strength
  0.6, 0.75, 0.85 or with higher CFG; only letting the composition drift
  made it sharp). The improve dialog now offers DETAIL REGENERATION
  (the engine's own highres fix, ON for fast drafts): a base pass keeps
  the composition at the image's size, then a second pass re-synthesizes
  real sharp detail at 2x size - verified: 1360 x 768 draft -> sharp
  2720 x 1536, same scene, textured rocks, clean rings. Takes about
  3-4x the normal improve time (roughly 15 min at 100 steps on a 12 GB
  card); MOSS asks before starting and warns when the option is off for
  a draft. VAE tiling is always on for the enlarged pass. The 4.5 MP
  half-size demotion never applies to these runs.

What is new in v0.1.80
-----------------------
- Fixed: improving ANY image popped the 'orphaned settings' dialog that
  claimed 'This image has no stored settings (no sidecar)' even when the
  image HAD a sidecar. Root cause: the orphan-scan returned an empty
  list in a way that made the caller always count ONE 'orphan' (the
  classic PowerShell empty-collection gotcha) - so the offer fired on
  every improve with a blank file name. The scan now returns its
  elements directly (zero orphans = zero items), and the offer has a
  guard: it can only appear for an image that really has no sidecar.
  17 regression tests including the exact zero-orphan case.

What is new in v0.1.79
-----------------------
- Files deleted/renamed/moved OUTSIDE MOSS no longer linger: clicking a
  list entry whose file no longer exists prunes every dead entry at once
  (the list matches the disk again) and says how many were removed.
- ORPHANED SETTINGS RECOVERY: a picture that was RENAMED outside MOSS
  used to lose its stored settings silently (the sidecar is named after
  the picture). Now, when improving or re-rendering a picture that has
  no sidecar, and exactly one orphaned sidecar exists in the output
  folder, MOSS offers to attach it - showing its seed, size and prompt
  so you can confirm it belongs to this picture. Yes attaches it, No
  leaves everything untouched.
- After deleting images (from inside MOSS or after pruning dead
  entries), the preview now goes BLANK: the deleted picture no longer
  stays on screen, and no other image is auto-selected - click a file
  in the list to view it.

What is new in v0.1.78
-----------------------
- SINGLE INSTANCE: starting MOSS a second time (double-clicking the bat
  while it already runs) now refuses with a message instead of launching
  a second app. Two instances used to share the same settings.json (the
  last one to save clobbered the other's settings and history) and
  compete for the same GPU memory, so renders failed out-of-memory. The
  guard is a named mutex: Windows releases it automatically when the
  process exits, even after a crash, so it can never lock the folder
  permanently. Verified with two real processes.
- CORRUPT IMAGE PROTECTION: a finished render is only counted as a
  picture when the file is a complete, decodable PNG (PNG signature +
  IEND trailer + full decode). A truncated file (disk full, power loss,
  antivirus interference mid-write) is no longer added to the file list
  as if it were fine - the batch result says exactly how many files were
  corrupt and names them in the log; the broken files stay on disk.
  This closes the case where a half-written image silently passed as
  'OK' because the file existed.

What is new in v0.1.77
-----------------------
- The output folder stays clean: the per-image .json sidecars (seed,
  prompt, settings - what powers Improve, re-render from seed and the
  Info dialog) now live in a 'metadata' SUBFOLDER of the output folder,
  so you only see the pictures. New sidecars are written there; reads
  fall back to the old location next to the image for existing pictures,
  and AT STARTUP every MOSS_* sidecar still sitting next to the images
  is moved into the subfolder automatically (never overwriting anything,
  foreign .json files are left alone). Deleting images removes their
  sidecar from BOTH locations. The Info dialog texts no longer claim the
  file sits 'next to' the image.

What is new in v0.1.76
-----------------------
- The bigger-job estimator in the Benchmarks dialog now also calculates
  POWER: a vendor-neutral table of rated GPU wattages (NVIDIA, AMD and
  Intel) shows your GPU's draw, how much energy 1 hour (and an 8-hour
  overnight run) of continuous rendering uses, and how many kWh the
  whole estimated job costs. Example on the 3080 Ti: 1 hour ~ 0.35 kWh,
  8 hours ~ 2.8 kWh, job of 100 renders ~ 0.2 kWh (GPU only; the rest of
  the PC adds roughly 50-150 W). GPUs not in the table say so instead of
  inventing a number - no NVIDIA-only assumptions.

What is new in v0.1.75
-----------------------
- NEW in the Benchmarks dialog: a bigger-job estimator. Type ANY width,
  height, steps, speed mode and image count and it shows the expected
  render time per image and the total for the whole job (e.g. '1360 x
  768 at 25 steps, Exact: ~21 s per image -> ~5:36 for all 16'),
  extrapolated from the measured data above (scaled by render size x
  engine steps, the same rule the live ETA uses). It is pre-filled with
  the main window's current settings, tells you which measured run it
  based the extrapolation on, and refuses nonsense input politely.

What is new in v0.1.74
----------------------
- Fixed: the quick benchmark in the Benchmarks dialog always failed with
  'unknown argument: (model)' - it passed the options dialog's display
  label 'Default (model)' into the engine command line as if it were a
  sampler/scheduler value. Like every other render path, the label now
  means 'omit the flag so the model keeps its own default'. Verified
  against the real engine (512 x 512 @ 8 steps renders in about 5 s).

What is new in v0.1.73
----------------------
- NEW: Benchmarks button (bottom left, where 'Improve last image' used to
  be). Every completed render is recorded into config\benchmarks.json and
  the dialog shows the real measured seconds per image for every size /
  speed mode / step combination that ran on this PC. It also estimates
  times for combinations you have not run yet (scaled by render size x
  engine steps from the nearest recorded run) and has a quick benchmark
  (3 tiny test renders into a separate benchmarks folder) to fill the
  table fast. Recorded data can be cleared at any time.
- The live ETA is now correct from the first second: it starts from the
  benchmark store's prediction for the current settings instead of
  showing 'ETA calculating' until the engine reports progress.
What is new in v0.1.72
----------------------
- NEW: Safe mode in Options... - a family-friendly prompt gate, ON BY
  DEFAULT: prompts containing sexual, gore/violence or self-harm/suicide
  terms are REFUSED before anything runs (generation, improving,
  re-render and the automatic retry all go through the same gate), and
  safety words (nsfw, nude, naked, explicit, gore) are added to the
  negative prompt. When a prompt is blocked, MOSS says
  exactly how to allow it: open Options... and untick 'Safe mode' if you
  want that prompt to run (adult users keep full control - it is a
  local, opt-out filter, not a server-side policy). Important
  background: a NEGATIVE PROMPT CANNOT CENSOR - it only steers sampling
  with concept words and loses against an explicit positive prompt, and
  instruction-style text such as 'should be censored' does nothing
  there. The real block has to be in the application, which is what
  Safe mode is. It is a keyword gate, not a trained image filter -
  creative wording can still slip past. ALWAYS ON, even with Safe mode
  unticked: prompts that sexualize minors (a minor-age word combined
  with a sexual term, plus the known tags like loli/shota/jailbait).
- Fixed: the setup screen checked the engine path against the working
  directory instead of the MOSS folder ('Check backend support' could
  report 'engine executable was not found' purely because of where MOSS
  was started from). All path checks are now anchored to the app root.
- Launchers start the engine console hidden from the first moment and
  the batch host closes itself (no more empty 'E:\Moss>' window).
What is new in v0.1.71
----------------------
- Large renders no longer die in the VAE: for renders above about 3 MP
  MOSS passes --vae-tiling to the engine, so encode/decode runs in
  memory-safe tiles (live case: a 2720 x 1536 improve needed 18 GB for
  the VAE graph on a 12 GB card and failed before step 1 - verified to
  complete with tiling). Fewer wasted retry cycles on big improvements.
- The 'Improve last image' button was removed (right-click improve on
  the file list does everything it did).
- Removed dead code left behind by earlier features: two unused dialog/
  check functions, two never-read state variables, and the leftover
  'start generation from an image' hook.
- Faster everywhere a code is in use: the 250000-iteration key
  derivation now runs once per code instead of on EVERY encrypt/
  decrypt - previously each image sidecar write/read (up to 2 per
  image), every settings save and every code attempt re-ran it on the
  UI thread. A 16-image batch with a history code no longer stalls the
  interface for seconds. Wrong codes are still rejected exactly as
  before (verified).
- Portable on every vendor's GPU: the selected graphics card is now
  applied for ALL backends - Intel SYCL builds used to silently ignore
  the GPU selection in Hardware / Setup (they need a 'backend:index'
  style selector, not a bare index). Nothing in MOSS is NVIDIA-locked:
  detection covers NVIDIA / AMD / Intel / virtual adapters, the engine
  variant selector offers CUDA, Vulkan, ROCm, SYCL and CPU, and
  Auto falls back to Vulkan (any GPU) and then CPU when no NVIDIA card
  is found.
What is new in v0.1.58
----------------------
- The automatic memory retry now steps down gradually: Exact -> 4x ->
  8x -> Fast, so very large improvements (e.g. 5440 x 3072, where even
  the half-size render was too much) still land a picture. Each retry
  renders smaller with all steps and enlarges to the full target.
- The visual style prefix is no longer doubled when the prompt already
  starts with it (e.g. a prompt picked from the history dropdown).

What is new in v0.1.57
----------------------
- The 'Improve this image' dialog was re-laid-out: every explanation
  label now has room for its text (no more clipped/overlapping lines),
  shorter wording, taller dialog with the buttons in their own row.

What is new in v0.1.56
----------------------
- Automatic half-size retry for improvements: if a native image-to-image
  render dies instantly with no output (almost always out of GPU or
  system memory, e.g. 2720 x 1536 on a 12 GB card), MOSS now retries
  the same improvement at HALF SIZE with all steps and enlarges the
  result to the full target - composition still kept from the image.
  The log explains the retry. Previously this just failed.

What is new in v0.1.55
----------------------
- The progress bar is now pinned to the very bottom edge of the left
  panel (it used to float mid-panel when the window was taller or
  maximized), with a numeric readout to its right showing the overall
  percentage and the engine's step counter (e.g. '38%  step 17/50',
  or 'starting...' while the engine warms up). The status line sits
  directly above and stays with it.

What is new in v0.1.54
----------------------
- Layout fix: the progress bar sits in its own thin strip at the very
  bottom of the left panel (below the status line), so it no longer
  overlaps the GENERATE / Cancel / Open output button row.

What is new in v0.1.53
----------------------
- The 'History code...' button is now a small menu: 'Enter code to
  unlock the prompt history...' (shown when the code has not been
  entered), 'Set a NEW code (clears the saved history)...' and 'Turn
  off prompt history...'. Previously the button only RESET the code -
  there was no way to enter the existing code after skipping it at
  startup. Skipping the startup prompt now also says where to enter
  the code later.

What is new in v0.1.52
----------------------
- Better progress display: a slim progress bar above the status line -
  marquee while the engine starts, then driven by the engine's STEP
  COUNTER, full when the batch completes. The status line now shows
  'step 17/50' from the engine's step counter together with the overall
  percentage and the ETA.
- Time taken is no longer lost when a job completes: 'Improvement
  finished' keeps the total elapsed time in the status line, and the
  generation log now records the total time of every batch and of the
  whole improvement queue (persistent record).

What is new in v0.1.51
----------------------
- Trying to improve (or re-render) an image whose prompt is stored
  ENCRYPTED while no history code is entered now shows a specific,
  actionable error: what happened, and the two ways forward - enter
  the code via 'History code...' so MOSS reads the stored prompt, or
  type a new prompt in the main window and use that instead. Nothing
  is generated and the image is never changed in this case.
What is new in v0.1.50
----------------------
- If you continue WITHOUT the password (history code) at startup, the
  prompt is now saved with the image anyway - PLAIN TEXT, not encrypted.
  Improving such images works without entering the code (the prompt is
  read from the image's sidecar). Your encrypted prompt history in
  settings.json is untouched; only the small .json sidecar next to each
  image carries the plain prompt. If you want prompts encrypted, enter
  your code when MOSS asks.

What is new in v0.1.49
----------------------
- 'Improve this image' now opens a pick-your-quality dialog: the target
  size defaults to the image's own size with Same / 2x / 4x buttons,
  steps and CFG are prefilled from the main window and stay editable,
  and the seed is prefilled with the image's own seed (change it to
  experiment). The composition and seed always come from the image, and
  the result is saved as a NEW file - the original is never modified.
- Fixed: maximizing the window hid the Generated Files box, its title
  and the generation log. One layout is now used for all window states,
  so the file list stays available when maximized.

What is new in v0.1.48
----------------------
- The right-click menu on a generated image was reordered and clarified:
  'Improve using the settings in the main window...' is now the FIRST
  item. The re-render item was renamed to 'Re-render with this image's
  OWN seed and size (ignores the main window settings)' - it previously
  sat first and sounded like the way to make a full-quality version of
  the image, but it deliberately ignores the main-window settings and
  re-renders with the image's own seed, so different settings in the
  main window had no effect on it.
- Re-rendering an upscaled fast draft now warns before starting: the
  same seed on a full-size canvas is different noise, so the picture
  will NOT look like the draft. The warning points at the Improve
  action, which keeps the composition. Choosing 'No' cancels.

What is new in v0.1.47
----------------------
- Fixed: the output folder could silently be saved as a wrong absolute
  path when MOSS was started from a working directory other than its
  own folder (for example from a terminal in another folder). Relative
  paths such as 'outputs' are now always anchored to the MOSS folder
  before they are normalized - they no longer depend on where MOSS was
  started from. If a wrong absolute output folder was already saved in
  your settings, open Options and set the folder again (or restore the
  default 'outputs'); your images are not affected by the fix itself.

What is new in v0.1.46
----------------------
- Fixed: a crash right at startup (error dialog 'You cannot call a
  method on a null-valued expression' repeated in the background).
  The startup prompt timer lived in a scope that no longer existed
  when it fired; it now lives in script scope and any unexpected
  startup-dialog error is logged to the logs folder instead of
  crashing.

- Fixed: the history code prompt was no longer staying on top of the
  main window at startup (a side effect of the Topmost removal). The
  prompt is now opened right after the main window has finished its
  first activation, so it reliably sits on top of MOSS, focused and
  ready for typing - while still letting other programs take focus
  when you click them.

- Engine updater: when everything is already up to date, pressing
  'Download and install...' now asks for a deliberate confirmation
  first (showing the download size) instead of silently re-downloading
  the same files - no more wasted time and bandwidth by accident.
  Model updates and extra engine variants are unaffected.
- Faster cleanup in Generated Files: the list is multi-select now
  (Ctrl+click or Shift+click), and the right-click menu has 'Delete
  selected file(s)...' and 'Delete ALL files...' - one confirmation
  shows the count and how much disk space is freed, then everything
  (images + sidecars) is deleted in one go. No per-file prompts.

- Fixed: the history code dialog no longer pins itself above ALL windows
  (Topmost removed) - it stays above MOSS where it belongs, but other
  programs can take focus normally while it waits. It still grabs the
  foreground at startup so you can type the code immediately.
- Safe improves: 'Re-render from the same seed' and 'Improve ALL files'
  now refuse/skip images whose prompt cannot be read (stored encrypted
  by an older MOSS version and no history code entered) - without the
  prompt they would create a completely different picture. The confirm
  explains it and how to unlock the prompt instead.
- Generation NEVER asks you to create a history code any more: with no
  code in use, prompt history and the per-image prompts are stored as
  plain text, so improving works at any time (no nag, no blocked
  generation). Setting a code stays optional via 'History code...' -
  with a code entered, history is encrypted as before.

- Fixed: improving an image could produce a WORSE result than the
  original. Two causes, both fixed:
  1) "Improve using the settings in the main window" used the main
     window's seed - with random seed the image-to-image noise pattern
     does not align with the picture and the result comes out muddy
     (verified with real renders: same-seed improves are sharp, random
     -seed improves soft). Improve now reuses the image's own recorded
     seed automatically (shown in the confirm dialog as "from the
     image"); a seed you type yourself is still honored.
  2) When the target size has a different aspect ratio than the source,
     the composition is squashed - the confirm dialog now warns about
     it clearly.
What is new in v0.1.41
----------------------
- Fixed: the history code prompt could show the wrong text ('Enter the
  code.' with a word missing) and - more importantly - was not reliably
  ready for typing on startup: the prompt now keeps pulling itself to
  the foreground and focusing the code field until it really has focus.
- Improved: the MOSS updater also accepts a release zip with a version
  number in its file name, so future releases cannot be missed.

What is new in v0.1.40
----------------------
- NEW: "Update engine..." in the header - updates the sd-cli core files
  (the rendering engine in the bin folder) separately from MOSS itself.
  The dialog shows the installed engine version, the latest official
  stable-diffusion.cpp release, recent release changelogs, and can
  download and install the matching build automatically: the engine
  variant (CUDA 12 / Vulkan / ROCm / SYCL / CPU) is preselected from
  your backend, the optional CUDA runtime (cudart) can be included,
  the current engine files are backed up to engine-backup-<time> and
  restored automatically if the install fails. Models, prompts, outputs
  and settings are never touched.
- NEW: "Restore a backup..." in the engine dialog - lists the automatic
  engine-backup-<time> folders and copies a chosen one back over the
  current engine files (a manual rollback, verified by running the
  engine afterwards). Also reachable when the release feed cannot be
  read (works offline), and the dialog now always opens even when the
  engine is already up to date (marked UP TO DATE), so changelogs and
  the rollback stay available at any time. Engine backups contain only
  the small engine files - the large model files are never modified by
  an engine update, so they are never backed up or rolled back.
- The old "Check updates" button is now called "Update MOSS..." so it is
  obvious that it updates the MOSS application itself, not the engine.
  Both header buttons have tooltips explaining exactly what each one
  updates.
- Engine updates are logged to logs\engine-update-<time>.txt.
- NEW: the engine dialog now also checks the model files at the same time
  (the 11 GB of downloads on Hugging Face are matched by size only - no
  multi-GB download just for a check). Models that are out of date or not
  installed appear in a checklist with their sizes; old model files are
  renamed to <name>.old-<time> before a new one is downloaded (instant,
  needs no extra disk space), and the newest 3 backups per model are kept.
  The confirm dialog shows each model's size, the disk space needed and
  the expected download time measured from your connection, and the
  download is verified by size before anything replaces an existing file.
- NEW: at startup MOSS checks whether the engine or the model files are
  missing (for example right after a fresh download) and offers to
  download them immediately, with a time estimate from your measured
  connection speed - so a fresh MOSS can get to work in one click.
- NEW: if MOSS was unpacked on a drive that is too small for the model
  downloads, it suggests a better place (the fixed drive with the most
  free space), moves itself there with one click and creates a "MOSS
  Image Studio" desktop shortcut pointing at the new copy; downloads
  then run from the new location and the old copy can be deleted.
- Backups are kept lean: engine backups are single compressed zips
  (files that cannot shrink are stored raw - this made backups 15%
  faster in testing), and only the newest 3 engine backups are kept;
  older ones are deleted automatically with a note in the log.

What is new in v0.1.39
----------------------
- Simplified: the right-click improve menu is now fully settings-driven.
  The entries "Improve this image (full quality)" and "Improve this image
  (2x bigger)" (which used the image's own size) are gone. Improving now
  uses the size, steps, CFG, seed and prompt you set in the main window:
  right-click -> "Improve using the settings in the main window...".
  New: "Re-render from the same seed (fresh full quality)" - a brand-new
  full-quality generation with the image's own seed and prompt.

What is new in v0.1.37
----------------------
- NEW: MOSS now presents itself as what it is - a GUI front-end for the
  sd-cli command-line engine. The window title says so, the README explains
  it, and Options has a new checkbox: "Show the exact sd-cli command line
  in the generation log" (on by default), so you can see precisely which
  flags MOSS passes to the engine for every render.

What is new in v0.1.36
----------------------
- Improved: improves now always show the real dimensions: the source
  image's size and the final size in megapixels, both in the confirmation
  dialogs and in the generation log ("source 1536 x 2048 -> final 3072 x
  4096").
- Improved: when the final size is bigger than what most GPUs render
  natively (over ~4.5 MP), the confirmation explains the automatic
  half-size render and suggests the better route: work natively up to
  2048 x 2048, then improve THAT image 2x.

What is new in v0.1.35
----------------------
- Improved: improving an image to a very large size (bigger than about
  4.5 megapixels, e.g. 4K landscape or a 2x of a 2K image) no longer fails
  with a silent engine crash. Those targets are rendered at half size with
  the full step count and enlarged to the full size afterwards - the same
  reliable fast-mode pipeline used for quick drafts, and the log explains it.

What is new in v0.1.34
----------------------
- Improved: when the engine stops with an error and no message at all (the
  most common cause is running out of GPU or system memory at very large
  render sizes), the generation log now explains this and suggests a
  smaller size, fewer steps, or a fast speed mode.

What is new in v0.1.33
----------------------
- Changed: the "Error report" button no longer offers to upload anything.
  It copies the anonymised report to the clipboard and saves it in the logs
  folder, and tells you so. Nothing ever leaves your computer. (The old
  "no upload address configured" step is gone.)

What is new in v0.1.32
----------------------
- NEW: "None (no style)" is now the first entry in the Visual style list.
  It sends your prompt exactly as typed, with no style words added. If a
  saved config has an unknown style, MOSS now defaults to "None (no style)".
- NEW: eight more visual styles: Fantasy art, Dark fantasy / gothic,
  Cyberpunk / sci-fi, Studio portrait, Sketch / pencil drawing, Pixel art,
  Synthwave / retro 80s and Low poly 3D.

What is new in v0.1.31
----------------------
- Fixed (properly this time): the history code prompt could still leave
  typing going to the main window. The prompt is now shown as a real modal
  dialog owned by the main window (Windows guarantees it takes the keyboard
  focus), in addition to the focus-on-show and re-focus timer from before.

What is new in v0.1.30
----------------------
- Fixed: the history code prompt did not reliably have the code field
  selected for typing (another window could take the focus right after the
  prompt opened). The field is now focused on show AND re-focused by a
  short one-shot timer, so you can type the code straight away.

What is new in v0.1.29
----------------------
- Fixed: "Improve using the settings in the main window" asked for a prompt
  even when the image had one stored. If the prompt box is empty, MOSS now
  reads the image's own prompt from its info file (decrypted with your
  history code), fills it into the prompt box and uses it. If neither is
  available, the message now explains what to do.

What is new in v0.1.28
----------------------
- Fixed: deleting an image failed with "the file is in use" while the image
  was shown in the preview. The preview no longer keeps a lock on the file
  (it shows a copy), and the preview is released before the delete runs.

What is new in v0.1.27
----------------------
- Changed: in Options, the first entry of the Sampler and Scheduler lists
  now shows what is actually used: "Default (euler)" and "Default (flux
  schedule)" instead of the vague "Default (model)". Saving keeps the
  internal setting unchanged, so existing configs still work.

What is new in v0.1.26
----------------------
- Fixed: the app now works the same on every Windows language and regional
  format. On systems that use a comma for decimals (Danish, German and many
  others), entering 0.6 as Improve strength was rejected as invalid, a saved
  Improve strength was silently ignored, and values sent to the engine (CFG
  scale, improvement strength) could be misread. Numbers now accept both
  0.6 and 0,6 everywhere and are always stored and sent to the engine with
  a dot, regardless of country settings - no language check needed.

What is new in v0.1.25
----------------------
- Fixed: the explanation text next to "Improve strength" in Options was cut
  off at the end. It now has room for all three lines, and the Improve
  strength box itself got a proper tooltip (including how it interacts with
  fast previews).

What is new in v0.1.24
----------------------
- Fixed: the CFG explanation popup (and the startup error popup) showed
  strange letter sequences like `r`n instead of line breaks. They now show
  real line breaks.

What is new in v0.1.23
----------------------
- Fixed: the small "?" button next to CFG scale was misplaced (it overlapped
  the Images column and floated above the label row). It now sits neatly
  inline with the CFG scale box, and its tooltip explains what CFG does.
  The tooltip on the CFG scale box itself now contains the real explanation
  (low = more artistic freedom, high = burned or distorted images, the
  model is tuned for about 3) instead of only pointing to the button.

What is new in v0.1.22
----------------------
- Fixed: clicking Generate emptied the "Generated files" box. The list is
  the history of every image you created (it is filled from the output
  folder when MOSS starts), so it is no longer cleared when you generate -
  new images are simply added to it and selected.
- Fixed: improving an upscaled fast preview no longer produces soft, "upscaled-looking"
  results, and it always keeps the composition of the original image
  (image-to-image). Fast previews are stored as enlarged drafts, so MOSS
  raises the image-to-image strength for them automatically (0.5 to 0.74,
  depending on how much they were enlarged) - detail is regenerated instead
  of inheriting the blur. If a result still looks soft, raise 'Improve
  strength' in Options; if the scene starts to drift, lower it. Native
  images keep your own 'Improve strength' setting.
- NEW: right-click an image in "Generated files" -> "Show image info
  (prompt, seed, settings)..." - shows the prompt, negative prompt, seed,
  size, steps, CFG, speed mode, sampler, scheduler and whether the image is
  an original or an improved copy, with a "Copy prompt" button. Prompts are
  decrypted only when the history code was entered; otherwise the dialog
  says so (they are stored encrypted in the .json sidecar).

What is new in v0.1.21
----------------------
- Fixed: second startup crash (.NET dialog about 'System.Void'). A PowerShell
  5.1 compiler bug was triggered by one line in the history unlock code;
  that single line made the whole function fail to compile, so MOSS crashed
  the moment the main window appeared. The line is fixed and the pattern was
  audited out of the entire script.

What is new in v0.1.20
----------------------
- Fixed: a PowerShell scoping error crashed MOSS on startup and window resize
  (the history code prompt could not be shown; reported as a .NET exception
  dialog). Closure-bound event handlers cannot call functions defined inside
  the window builder - the two affected handlers now use normal dynamic scope.

What is new in v0.1.19
----------------------
- The history code prompt now appears after the main MOSS window is shown,
  opening centered over the app instead of as a floating startup dialog.

What is new in v0.1.18
----------------------
- Fixed: fast render modes (Fastest / ~2x / ~4x / ~8x) kept their images at
  the small render size because the pixel-space enlargement failed with a
  generic GDI+ error (the file was still open while MOSS tried to save over
  it). The enlargement now reads the file into memory first and works.
- Fixed: "Improve last image" now uses the same sidecar-aware path as the
  right-click menu (seed, prompt, sampler, scheduler, negative prompt are
  reused; output gets the _hq tag in the filename).
- Improvement strength now adapts to the source: 0.6 for upscaled previews
  (they are soft and need stronger re-synthesis), 0.45 for already-native
  renders. The used strength is shown in the log.
- Clearer controls: the two confusing buttons are now one "Improve last
  image" button (the old "Render natively" is covered by the speed selector:
  set Exact and press GENERATE). Right-click items read "Improve this image".
- "Options..." dialog holds the negative prompt, sampler and scheduler; every
  sampler and scheduler option shows a plain-language description inline and
  on hover, and "Default (model)" states what the engine actually uses
  (euler; Flux-family schedule).
- Model file paths are collapsed by default behind a "Model files" toggle
  with a health summary; it opens automatically only when a file is missing.
- Every main button explains itself on hover.
- The PowerShell console is hidden from the start (password prompt included)
  and the history code field is focused immediately.

Hardware and setup
------------------
- MOSS lists the display adapters Windows reports, but classifies virtual
  display adapters (remote desktop, USB display, virtual monitors) separately
  so they are never mistaken for physical graphics cards.
- On computers with several physical graphics cards you can select the card
  MOSS should use (Hardware / Setup, "Select GPU"). The choice is passed to
  the engine through the standard device selection variables for the active
  backend (CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES / GGML_VK_VISIBLE_DEVICES).
- Setup can be re-run at any time from Hardware / Setup. Re-running setup never
  deletes models, prompts, generated images or other user data.
- The header shows the actual active backend (for example "BACKEND CUDA"),
  never a permanent "Auto" placeholder.

Updating MOSS
-------------
- Select Check updates in the generator. MOSS checks the latest GitHub release
  and reports whether this version is current or a newer release is available.
- If an update is available, choose Yes to download it. MOSS asks before changing
  local files, closes, replaces only the app files, preserves config\, models\,
  and outputs\, and restarts.
- The repository and release assets must be publicly readable for the automatic
  updater to work. If MOSS cannot read the release feed, it offers to open the
  Releases page instead.

Errors and diagnostics
----------------------
- Failed generations are always written to the logs\ folder automatically.
- Copy Error Report builds an anonymous diagnostic report (paths anonymised,
  prompts omitted), copies it to the clipboard and saves a copy in logs\.
- MOSS then asks whether to upload the report. Nothing is sent without your
  explicit Yes, and a local copy always exists first. Uploading requires an
  upload address to be configured in config\settings.json (key "ErrorReportUrl");
  if none is set, MOSS keeps the report locally. If the computer is offline,
  the local copy is preserved and you can try again later.
- The report text is designed to be pasted into an AI coding assistant such as
  ChatGPT or Grok for diagnosis.
- If MOSS cannot start at all, it writes a technical report to logs\ and shows
  an error message instead of failing silently.

Privacy and portability
-----------------------
- The prompt-history code is the only password MOSS uses; it protects saved prompts and is never stored.
- Prompt history is encrypted with a code you choose; the code is not stored.
- New history codes must be 4-16 characters; letters, numbers, and symbols are allowed.
- If an existing history code is wrong or cancelled, MOSS can continue without history
  while preserving the encrypted history.
- Use History code... (generator) or Set / reset history code (Hardware / Setup)
  to replace a forgotten code. This clears old history permanently.
- Copy the complete MOSS folder, including config\settings.json, to move encrypted
  history and portable settings.

Interface
---------
- MOSS is resizable; resizing gives extra vertical space to the image preview;
  maximizing hides the file list and log until the window is restored.
- Designed for Windows PowerShell 5.1. No installation is required.











