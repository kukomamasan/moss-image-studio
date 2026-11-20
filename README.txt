MOSS Image Studio - portable build (v0.1.17)
============================================
Unpack this ZIP into any folder you like (for example E:\MOSS\). All paths are
resolved relative to the application folder, so MOSS can be moved to another
drive or computer at any time.
Start MOSS with MOSS-Image-Studio.bat (or MOSS-Image-Studio.vbs).
The launcher locates Windows PowerShell 5.1 directly in its standard Windows
installation location, even when PowerShell is not on the PATH.
After the MOSS form appears, it hides the PowerShell console; the MOSS
application stays visible and shows its current version in the title and header.
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
- Render speed selector (next to the image settings): Exact (native render),
  or faster modes that render at a reduced size with the FULL step count and
  then upscale the finished image in pixel space (high-quality bicubic).
  No second sampling pass runs, so results are faithful - possibly grainy or
  soft at high speeds, but never distorted. Measured on an RTX 3080 Ti at
  2K portrait, 50 steps: Exact about 4 minutes; ~4x (upscale from 50%) about
  1 minute; Fastest (upscale from the smallest render, 256-pixel side) about
  15 seconds. 'Fastest' and '~8x' are draft quality: good enough to see what
  the picture is; use Exact when detail matters. Multipliers are approximate
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

Native refinement of generated files (right-click)
---------------------------------------------------
- In the "Generated files" list, right-click any image to refine it natively:
  MOSS re-renders exactly that picture (same seed and prompt, read from the
  image's sidecar) at full quality using image-to-image - the composition
  (same apple, same table) stays, the detail becomes genuinely native.
- "Refine natively (same size)" keeps the image's size; "Refine natively
  (2x bigger)" doubles it (large sizes ask for confirmation first).
- The strength (0.45) keeps most of the composition while replacing the
  low-resolution detail; the full step count applies.
- Refined files are easy to spot in the output folder: ..._hq_01.png for
  same-size refinement, ..._hq2x_01.png for the 2x version.
- A typical workflow: render a fast preview batch with the speed selector,
  pick the previews you like, right-click each winner and refine it natively
  while you look at something else.
- If you know the prompt-history code, MOSS reuses the exact prompt of the
  refined image; otherwise it uses the text currently in the prompt box.

Sampler, scheduler and negative prompt
--------------------------------------
- Next to Steps/CFG there are optional Sampler and Scheduler dropdowns.
  "Default (model)" omits the flag, so the engine keeps its model-specific
  choice. Power users can experiment (euler, dpm++2m, karras, gits, ...) -
  the lists are the exact values supported by the bundled engine.
- "Negative prompt..." (next to Image settings) opens a dialog for what the
  image should NOT contain (e.g. blurry, extra fingers, watermark). Empty
  means no negative prompt is sent. The negative prompt is stored in the
  config and, like the positive prompt, encrypted in the image sidecars.
- Native refinement reuses the refined image's own sampler, scheduler and
  negative prompt when they are recorded in its sidecar.

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
