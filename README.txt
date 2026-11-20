MOSS Image Studio - portable build (v0.1.53)
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
  2K portrait, 50 steps: Exact about 4 minutes; ~4x (upscale from 50%) about
  1 minute; Fastest (upscale from the smallest render, 128-pixel side) a few
  seconds. 'Fastest' and '~8x' are draft quality: good enough to see what
  the picture is, and 'Fastest' can be visibly soft at large sizes - right-click
  it and choose Improve to re-render it sharp with the same seed. Use Exact
  when detail matters. Multipliers are approximate
  and vary with size and step count. Works the same on NVIDIA, AMD, Intel and
  CPU builds.
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
- In the "Generated files" list, right-click any image to improve it:
  MOSS re-renders exactly that picture (same seed and prompt, read from the
  image's sidecar) at full quality using image-to-image - the composition
  (same apple, same table) stays, the detail becomes genuinely native.
- "Improve this image (full quality)" re-renders at the image's current size
  with full detail (about as long as a native render of that size).
  "Improve this image (2x bigger)" doubles width and height (e.g. 768x1024
  becomes 1536x2048): more resolution to work with, but it takes about four
  times as long because the pixel count quadruples.
- "Improve using the settings in the main window..." renders the selected
  file with the values you currently see (size, steps, CFG, seed, prompt
  box, Options values). A confirmation shows exactly which settings apply
  to that file before anything starts.
- "Improve ALL files that can be improved..." queues every generated image
  that still has quality headroom: soft fast-mode previews, renders with
  fewer steps than the current setting, or images smaller than the current
  size (scaled up with the aspect preserved). Files already at full quality
  or with an improved copy are skipped and reported in the confirmation.
- The improve strength is set in Options ("Improve strength"): 0.45 keeps
  the look, 0.6 refreshes detail, 0.8 re-renders strongly.
- Improved files are easy to spot in the output folder: ..._hq_01.png for
  same-size improvement, ..._hq2x_01.png for the 2x version.
- The "Improve last image" button does the same for the most recent image.
- A typical workflow: render a fast preview batch with the speed selector,
  right-click "Improve ALL files that can be improved" and let MOSS work
  through the good ones while you look at something else.
- If you know the prompt-history code, MOSS reuses the exact prompt of the
  improved image; otherwise it uses the text currently in the prompt box.

- Right-clicking a file in the list selects it automatically, so Improve
  always acts on the file you clicked.
- "Delete this file" removes the image (and its sidecar) from disk and the
  list after a confirmation.

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

What is new in v0.1.53----------------------- The 'History code...' button is now a small menu: 'Enter code to  unlock the prompt history...' (shown when the code has not been  entered), 'Set a NEW code (clears the saved history)...' and 'Turn  off prompt history...'. Previously the button only RESET the code -  there was no way to enter the existing code after skipping it at  startup. Skipping the startup prompt now also says where to enter  the code later.
What is new in v0.1.52----------------------- Better progress display: a slim progress bar above the status line -  marquee while the engine starts, then driven by the engine's STEP  COUNTER, full when the batch completes. The status line now shows  'step 17/50' from the engine's step counter together with the overall  percentage and the ETA.- Time taken is no longer lost when a job completes: 'Improvement  finished' keeps the total elapsed time in the status line, and the  generation log now records the total time of every batch and of the  whole improvement queue (persistent record).
What is new in v0.1.51----------------------- Trying to improve (or re-render) an image whose prompt is stored  ENCRYPTED while no history code is entered now shows a specific,  actionable error: what happened, and the two ways forward - enter  the code via 'History code...' so MOSS reads the stored prompt, or  type a new prompt in the main window and use that instead. Nothing  is generated and the image is never changed in this case.
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
  The "Improve last image" button does the same for the most recent image.
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











