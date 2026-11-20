MOSS Image Studio - portable build (v0.1.23)
============================================
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
- Fixed: improving an upscaled fast preview produced soft, "upscaled-looking"
  results. A fast preview is stored at its full target size after an internal
  enlarge, so using it as the starting image for improvement passed that
  blur on. Fast previews are now re-rendered from scratch at full quality
  with the same seed and prompt (image-to-image is skipped for them).
  Native images are still improved with image-to-image as before, and the
  "Improve using the settings in the main window" confirmation tells you
  when a fresh render is used.
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
