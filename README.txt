MOSS Image Studio - portable build (v0.1.13)
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

Administrator code
------------------
This build uses one administrator account. On first use, you can create an
administrator code or continue without one. If a code has already been set,
MOSS asks you to enter it. If it is forgotten, choose Continue without code to
remove the administrator code and proceed. MOSS has no additional user profiles
or child settings.

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
- Multiple images are generated one after another; every requested image is
  tracked, shown in the preview list and saved.
- Cancel stops the active engine process and its child processes, then reports
  that generation was cancelled.
- Images are saved under outputs\admin\ by default (configurable in the app).

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
- The administrator code is optional and is separate from the prompt-history code.
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
