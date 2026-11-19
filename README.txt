MOSS Image Studio - portable build
=================================
Unpack this ZIP into your MOSS folder (for example E:\MOSS\) so that
MOSS-Image-Studio.ps1 sits beside the bin\, models\, config\, and outputs\ folders.
Run MOSS-Image-Studio.ps1 as usual.

This build uses one administrator account. On first use, you can create an
administrator code or continue without one. If a code has already been set,
MOSS asks you to enter it. If it is forgotten, choose Continue without code to
remove the administrator code and proceed. MOSS has no additional user profiles
or child settings.

Image generation
- Choose a visual style: Photorealistic, Anime, Digital illustration, Oil painting,
  Watercolor, 3D render, Comic book, or Cinematic.
- MOSS adds the selected style guidance to the generation prompt.
- During generation, MOSS shows elapsed time, overall progress, and an ETA when
  the engine reports step progress or enough previous images have completed.
- Images are saved under outputs\admin\.

Updating MOSS
- Select Update MOSS in the generator to open the private GitHub Releases page.
- Download MOSS-Image-Studio.zip, close MOSS, and extract its app files over the
  existing MOSS folder. Keep config\, models\, and outputs\ unchanged.
- The app's updater source is the private repository kukomamasan/moss-image-studio.

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
- Timer-based generation worker.
- Copy Error Report button omits prompts for privacy and suggests asking an AI coding
  assistant such as ChatGPT or Grok to diagnose a script error.
- Designed for Windows PowerShell 5.1.
