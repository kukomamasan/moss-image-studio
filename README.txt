SOOTGLASS STUDIO (v0.3.44)
===========================
Generate images with the open MOSS-Image model on your own computer - with
one download, one window, and zero command line.

    unzip  ->  double-click  ->  Sootglass finds your GPU  ->  you type a prompt

That is the whole setup story. Sootglass detects your graphics card, downloads
exactly the files it needs (engine + models, with a live time estimate from
your measured connection), and is ready to generate when the bars finish.
No Python. No environment variables. No cloud account. Nothing you type
ever leaves this computer.

____________________________________________________________________________

 WHY Sootglass
____________________________________________________________________________

Sootglass was built around one promise: image generation should be as easy as
installing an app - and as private as keeping a diary.

 * EASIEST POSSIBLE START
   One script, one folder, no dependencies. First start detects your GPU and
   offers the missing engine and model files with free-space checks, a time
   estimate, size verification and automatic backups. When the download is
   done, you are ready - there is no step three.

 * A VRAM SAFETY NET THAT ACTS BEFORE IT HURTS
   Before every generation, Sootglass compares the selected models against the
   GPU memory that is actually free right now - measured from what a past
   run of the same model pair really put into VRAM, not just file sizes.
   If the pair cannot fit and CPU offload is off, Sootglass offers to enable it
   and re-runs the generation immediately - the doomed run never starts.
   If a run still hits a memory error (LoRAs are hungry), the same
   one-click offer appears afterward, and accepting it re-runs your failed
   batch automatically.

 * REAL-TIME CONTROL OF EVERY RENDER
   One engine process per image: every picture is saved to disk the moment
   it is finished, even in the middle of a batch. Watch it form in the live
   preview. PAUSE freezes the engine for real (VRAM stays allocated, nothing
   renders). SKIP abandons the current image and moves to the next. CANCEL
   keeps everything already saved.

 * YOUR SPEED, YOUR CALL
   Exact mode renders at full size and quality. The fast modes (~2x / ~4x)
   render smaller with full steps and enlarge the finished image - great for
   browsing ideas before committing to an Exact render. Every render is
   benchmarked, so Sootglass can tell you how long the next batch will take
   before you press the button.

 * MEASURED, NOT GUESSED
   The Benchmarks dialog records real seconds per image for every size,
   speed mode and step count you have run - and estimates the combinations
   you have not. It also tracks GPU power and energy: session, day and
   all-time totals, measured via nvidia-smi where available instead of
   guessing from a rated wattage.

 * LoRAs WITHOUT THE RITUAL
   Drop .safetensors files into models\loras (or fetch the official
   MOSS-Image LoRAs with the built-in GET LoRAs... dialog), tick them, set
   a strength.
   Downloads run in a background with live progress and a working Cancel -
   the interface never freezes while a file arrives.

 * PRECISIONS THAT SWITCH INSTANTLY
   Quantized (~11 GB), high-quality Q8 (~15 GB) or full 16-bit BF16
   (~28 GB): switching between installed variants is instant and shares the
   VAE, tokenizer and engine. Missing files download through the same
   dialog - models only, engine and graphics runtime untouched.

 * PRIVATE BY DESIGN
   Prompts are never sent anywhere. Failed runs are logged locally; the
   error report is built locally and anonymised. For extra security, set a
   password code (4-16 characters): prompt history and the per-image
   metadata sidecars are then stored encrypted, the code itself is never
   written to disk, and startup asks for it before showing your history.
   Without a code, prompts stay in memory for the session only.

 * PORTABLE BY NATURE
   Copy the folder to another drive or another computer and everything moves
   with it: settings, models, outputs and even the encrypted history.

 * UPDATES WITHOUT FEAR
   Engine updates are backed up and rolled back automatically on failure;
   the two newest engine builds stay cached, and Repair files... restores a
   lost engine file without downloading. App updates verify the ZIP's
   SHA-256 digest before installing and keep your config, models and images.

____________________________________________________________________________

 HOW IT WAS MADE
____________________________________________________________________________

 Sootglass is an honest example of building with AI: the script is
 written entirely by an AI coding assistant, while the ideas, the
 direction, the testing against the real app and every picture it
 renders come from a human. The result is a tool that does exactly what
 its author wanted - and nothing it did not agree to.

____________________________________________________________________________

 QUICK START
____________________________________________________________________________

 1. Unpack the ZIP into any folder (for example E:\Sootglass\).
 2. Start Sootglass-Studio.bat (or .vbs). First-time setup detects your GPU
    and downloads the required files - when it finishes, Sootglass is ready.
 3. Type a prompt and press Generate.

____________________________________________________________________________

 GOOD TO KNOW
____________________________________________________________________________

 - Quality defaults follow the model guidance: 50 steps, CFG 3, sizes in
   multiples of 16. JSON layout prompts use centered yxyx boxes and skip the
   style prefix.
 - 17 visual styles, negative prompt, safe mode (local prompt gate, opt-out)
   and an optional exact-command-line log are all in the Generation dialog.
 - Speed & memory extras: SageAttention, EasyCache (1.3-1.6x faster), VAE
   tiling for renders above 3 MP, and advanced tuning (distilled guidance,
   tileable output, sampler RNG, max VRAM budget, eager load, prefetch).
 - Sampler facts are verified in-house and shown on hover - including the one
   known trap: the 'ays' schedule with second-order samplers renders blank.
 - Reset all settings (Options) preserves models, outputs and history.
 - If the app ever fails to start with a parse error, the script file may
   have been truncated - restore it from the ZIP; a technical report is in
   logs\.

____________________________________________________________________________

 LINKS
____________________________________________________________________________

 MOSS-Image model ........... https://github.com/OpenMOSS/MOSS-Image
 Engine (stable-diffusion.cpp) https://github.com/leejet/stable-diffusion.cpp
