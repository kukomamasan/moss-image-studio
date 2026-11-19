MOSS Image Studio - portable build
=================================
Unpack this ZIP into your MOSS folder (for example E:\MOSS\) so that
MOSS-Image-Studio.ps1 sits beside the bin\, models\, config\, and outputs\ folders.
Run MOSS-Image-Studio.bat to close the first launcher window after startup.
After the MOSS form appears, it hides only the PowerShell console; the MOSS
application stays visible and shows its current version in the title and header.
Closing MOSS ends its launcher and PowerShell host, and stops active image-engine
processes. Temporary update files are removed after installation or download failure.

This build uses one administrator account. On first use, you can create an
administrator code or continue without one. If a code has already been set,
MOSS asks you to enter it. If it is forgotten, choose Continue without code to
remove the administrator code and proceed. MOSS has no additional user profiles
or child settings.

Image generation
- Choose a visual style: Photorealistic, Anime, Digital illustration, Oil painting,
  Watercolor, 3D render, Comic book, or Cinematic.
- MOSS adds the selected style guidance to the generation prompt.
- During generation, MOSS shows text progress and total elapsed time for the
  entire image batch, with an ETA when the engine reports step progress or
  enough images have completed. CPU offload is selected automatically only when
  detected GPU memory is too limited for the model.
- Images are saved under outputs\admin\.

Updating MOSS
- Select Check updates in the generator. MOSS checks the latest GitHub release
  and reports whether this version is current or a newer release is available.
- If an update is available, choose Yes to download it. MOSS asks before changing
  local files, closes, replaces only the app files, preserves config\, models\,
  and outputs\, and restarts.
- The repository and release assets must be publicly readable for the automatic updater to work. If MOSS
  cannot read the release feed, it offers to open the Releases page instead.

Privacy and portability
- The administrator code is optional and is separate from the prompt-history code.
- Prompt history is encrypted with a code you choose; the code is not stored.
- New history codes must be 4-16 characters; letters, numbers, and symbols are allowed.
- If an existing history code is wrong or cancelled, MOSS can continue without history
  while preserving the encrypted history.
- Use Set / reset history code in Hardware / Setup to replace a forgotten code. This
  clears old history permanently. You can also reset it from the Generator screen.
- Copy the complete MOSS folder, including config\settings.json, to move encrypted
  history and portable settings.

Other features
- Cancel stops the active engine process and its child processes, then reports
  that generation was cancelled.
- Resizing MOSS gives extra vertical space to the image preview; maximizing it
  hides the file list and log until the window is restored.
- Timer-based generation worker.
- Copy Error Report button omits prompts for privacy and suggests asking an AI coding
  assistant such as ChatGPT or Grok to diagnose a script error.
- Designed for Windows PowerShell 5.1.
