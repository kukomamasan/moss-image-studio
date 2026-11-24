MOSS Image Studio - portable build (v0.3.38)
===========================================

MOSS Image Studio is an independent GUI for the stable-diffusion.cpp CLI,
configured for the OpenMOSS MOSS-Image model family. Every render is a run of
bin\sd-cli.exe, and MOSS can show you the exact command it runs
(Generation... -> 'Show the exact sd-cli command line').

Unpack this ZIP into any folder you like (for example E:\MOSS\). All paths are
resolved relative to the application folder, so MOSS can be moved to another
drive or computer at any time. Start MOSS with MOSS-Image-Studio.bat (or .vbs).
The launchers locate Windows PowerShell 5.1 directly in its standard Windows
location, even when PowerShell is not on the PATH, validate the app script,
and hide the console. The BAT launcher invokes Windows Script Host by its
full system path rather than relying on executable-name search.
The current version is shown in the window title.

Generation
----------
- Choose a visual style (17 presets) or 'None (no style)'; prompts are sent as
  one line (multi-line pastes are flattened so nothing is lost).
- Size, steps, CFG scale, image count (no cap, with a runtime estimate and
  confirmation for very large batches) and seed (-1 = random, resolved once
  per batch so batch seeds stay sequential).
- MOSS-Image quality defaults follow the model guidance: 50 steps and CFG 3.
  Use width and height in multiples of 16. The engine's default sampler is
  Euler with the discrete scheduler and flow shift 5; negative-branch layer
  22 skipping is applied by the engine.
- JSON layout prompts are sent without a visual-style prefix. Use the model
  format with centered yxyx boxes; select a visual style for ordinary prompts.
- Speed selector: Exact (full quality) renders at full size; the faster modes
  (~2x / ~4x) render at a reduced size with full steps and enlarge the
  finished image in pixel space (bicubic - faithful, possibly grainy; never
  distorted, no second sampling pass). For render sizes above 3 MP, MOSS passes
  the engine's --vae-tiling flag to try to reduce VAE memory use. This is not a
  guarantee that a render will fit; reduce the render size or try CPU offload
  if you still get a memory error.
- Sampler and scheduler: full engine lists with plain-language descriptions
  inline and on hover, including verified in-house facts and the one known
  incompatibility ('ays' schedule + second-order samplers renders blank).
  'Default' entries omit the flag so the engine keeps its model choice.
- Negative prompt, safe mode (a local, opt-out prompt gate ON by default;
  it refuses sexual/gore-violence prompts and adds safety words to the
  negative prompt - a prompt gate, not a trained filter) and an optional
  exact-command-line log.

While rendering
---------------
- ONE ENGINE PROCESS PER IMAGE (v0.3.9): every image of a batch is saved,
  upscaled and listed the moment it is done - files appear one by one.
- LIVE PREVIEW: the picture forms in the Output preview pane while rendering.
  The decoder and update frequency are configurable (Generation... -> Speed &
  memory): proj (built-in), vae (uses the model VAE; default), tae (requires
  models\taesd.safetensors) or Off; update every 1-20 denoiser steps. This
  decoder setting affects previews only; it is separate from VAE tiling for
  large renders. If VAE previews do not appear in your setup, choose proj.
- SKIP abandons the image currently rendering and moves on to the next one;
  everything already saved is kept.
- PAUSE freezes the running engine process for real (nothing renders, VRAM
  stays allocated); Resume continues the same run. Paused time is excluded
  from the ETA and the power meter.
- CANCEL stops at any time and keeps every saved image. Closing MOSS also
  stops the engine and its child processes.
- The status line shows per-image progress, ETA (seeded from the benchmark
  store) and the GPU's live power draw; a power meter with session/today/
  all-time totals lives in the Benchmarks dialog.

Speed & memory and tuning (Generation... dialog)
------------------------------------------------
- The Generation... dialog is now TABBED and fits on small screens
  (v0.3.11): 'Image & sampler', 'LoRA', 'Speed & memory' and 'Advanced
  tuning' each have their own page, so the window is short instead of one
  very long scrolling column. Every caption sits directly above or next to
  its own control and grows to fit its text, so nothing is cut off or
  overlaps. The window also shrinks itself to fit the screen.
- The main window's Active options... button lists the saved generation
  features currently enabled, including previews, memory options, tuning and LoRAs.
- MOSS applies saved window bounds before showing the window, preventing a
  visible startup resize; the panels are laid out after the controls are built.
- The main window is first shown after its controls are built and laid out,
  preventing the interface from appearing in intermediate positions.
- At minimum window size, the prompt area contracts slightly so the progress
  bar remains visible inside the panel.
- Cancelling a render selects and previews the newest already-generated image;
  if none exist yet, the preview is cleared.
- SageAttention (native CUDA attention speedup, NVIDIA GPUs).
- CPU offload (weights in RAM, loaded into VRAM on demand - for low-VRAM
  setups; slower).
- The Speed & memory tab reminds you to turn CPU offload back off when you no
  longer need the extra VRAM, to restore normal generation speed.
- Recognized GPU-memory failures show one dialog per generation run; when
  CPU offload is off, choose Yes to enable and save it for future generations.
  The warning also reminds you to turn it off later if you no longer need it.
- EasyCache step cache (skips redundant DiT compute, roughly 1.3-1.6x faster).
- Advanced tuning (experimental, each optional, blank/off = engine default):
  distilled guidance, tileable output (circular padding on both axes /
  width / height), sampler RNG, max VRAM budget (GiB), eager load, disable
  weight prefetch. Benchmark before/after to see what each is worth.

LoRA models (v0.3.8 + v0.3.10 + v0.3.11)
-------------------------------
- The Generation... -> LoRA tab shows the exact folder MOSS scans. Use Open
  folder to place .safetensors files there, then press Rescan folder; check
  the ones you want and set a strength per LoRA
  (0-1.5). Checked LoRAs are applied to every generation via the engine's
  prompt-tag mechanism (<lora:name:strength>); the engine resolves them
  against the LoRA folder. Missing files are skipped with a log note and the
  prompt history stores your original prompt, without the tags.
- If generation reports insufficient GPU memory with LoRAs active, enable CPU
  offload in Generation... -> Speed & memory. This saves VRAM but may be
  slower; turning off Eager load under Advanced tuning may also help.
- GET LoRAs... (Generation... dialog, next to Rescan folder - also Options >
  LoRA models...) lists the LoRAs published for MOSS by Comfy-Org on
  Hugging Face, with their size and whether they are already installed.
  Tick the ones you want and press Download selected - MOSS fetches them
  into models\loras and logs selected files, results and cancellations to
  logs\lora-download-*.txt.
  NOTHING is downloaded automatically: every download starts only when you
  press the button in that dialog. A freshly downloaded LoRA is picked up by
  the LoRA list right away, checked with strength 1.0 and used by the next
  generation.
- DOWNLOADS NEVER FREEZE MOSS (v0.3.11): the transfer runs in a background
  runspace, so the window stays responsive and shows live progress
  (MB downloaded / MB total / percent) while the file arrives. Every ticked
  LoRA is downloaded, one after the other, and the Cancel button stops the
  transfer and removes the partial file.

Models and updates
------------------
- Options > About MOSS Image Studio opens the model information and links to the
  official OpenMOSS webpage and GitHub repository.
- Options > Reset all settings to defaults... clears saved preferences and
  closes MOSS; launch it again to apply defaults. Models, outputs, and saved
  prompt history/password are preserved.
- MODEL PRECISION: install and switch between Quantized (~11 GB, default),
  High-quality Q8 LLM (~15 GB) and Full 16-bit BF16 (~28 GB) variants -
  'Switch models...' swaps instantly between installed variants (VAE,
  tokenizer and engine are shared).
- Update engine... installs new sd-cli builds (the engine variant is
  preselected from your backend; NVIDIA-only filtering keeps ROCm packages
  out of the list on NVIDIA cards, uncheck to restore). Every install is
  backed up (compressed zip) and rolled back automatically on failure; the
  two newest engine builds are cached locally and 'Repair files...' can
  restore any lost engine file from the cache without downloading.
- Model updates are checked in the same dialog (matched by size only, old
  files are renamed <name>.old-<time>, the newest 3 backups per model are
  kept). Startup detects a missing engine or models and offers one-click
  downloads with a time estimate from your measured connection.
- All downloads (engine, models, release feed) retry and fall back to
  curl.exe when the old .NET HTTP stack receives an HTTP 504 from GitHub.

Benchmarks and estimates
------------------------
- Every completed render is recorded (size / speed mode / steps) and the
  Benchmarks dialog shows measured seconds per image, estimates for
  combinations not yet run, a quick benchmark (tiny test renders), a
  bigger-job estimator (any width/height/steps/count) and GPU power/energy
  projections (rated-wattage table, vendor-neutral).

Hardware and setup
------------------
- MOSS lists display adapters, classifies virtual adapters separately and
  never mistakes them for GPUs; on multi-GPU machines you can pick the card
  (passed through the standard per-backend device variables). Nothing is
  NVIDIA-locked: CUDA, Vulkan, ROCm, SYCL and CPU builds are supported and
  Auto falls back to Vulkan then CPU. Setup can be re-run at any time and
  never deletes models, prompts, images or other user data.

Privacy and portability
-----------------------
- Everything stays on this computer. A prompt-history code (optional,
  4-16 characters, never stored) encrypts and persists recent prompt history.
  Without a code, recent prompts remain in memory for the current session and
  are not written to settings.json. When locked history appears at startup,
  you can continue without history (preserving the encrypted history and
  saving no new prompts) or turn off the code (discarding the locked history
  and saving future history unencrypted). Per-image sidecars in the output
  folder's metadata\ subfolder store settings; when no code is configured,
  their prompts are plain text so Image Info can display them. With the code
  entered, prompts stay encrypted there too. If locked history is skipped,
  new sidecars omit prompts. Prompts are never sent anywhere; the Error report
  is built locally, copied to the clipboard and saved to logs\ - nothing is
  uploaded.
- Deleting an image also removes its sidecar from both possible locations
  and the preview goes blank; corrupt (truncated) images are detected and
  never listed as if they were fine.
- Copy the complete MOSS folder (including config\) to move everything,
  including encrypted history.

Diagnostics
-----------
- Failed generations are logged automatically to logs\; the error-report
  button builds an anonymised technical report (paths anonymised, prompts
  omitted). If MOSS cannot start at all, a technical report is written and
  a message is shown instead of failing silently.

Updating MOSS itself
--------------------
- 'Update MOSS...' checks the latest GitHub release and can update the app
  files while preserving config\, models\ and outputs\. If the release feed
  cannot be read, the Releases page is offered instead. Before installing, MOSS
  verifies the ZIP's SHA-256 digest; if GitHub does not provide a digest, the
  automatic install is refused.
- Note: MOSS runs as one .ps1 script. If the script file in your folder is
  ever truncated or corrupted externally (a partial write can look like a
  parse error and MOSS simply will not start), restore it from the ZIP -
  the logs\ folder holds a technical report when that happens.
