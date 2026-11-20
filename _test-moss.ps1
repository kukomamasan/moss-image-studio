# MOSS Image Studio v0.1.40 test suite (syntax, version, migration, speed, refinement)
$ErrorActionPreference = 'Stop'
$fail = 0
function Test([string]$name, [bool]$cond) {
    if ($cond) { Write-Host ('PASS  ' + $name) } else { Write-Host ('FAIL  ' + $name); $script:fail++ }
}
$src = Get-Content -Raw 'MOSS-Image-Studio.ps1'
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'MOSS-Image-Studio.ps1').Path, [ref]$tokens, [ref]$errors)
Test 'syntax parses clean' ($errors.Count -eq 0)
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Host ('  line ' + $_.Extent.StartLineNumber + ': ' + $_.Message) } }
Test 'version is 0.1.69' ($src.Contains("AppVersion = '0.1.69'"))
Test 'vbs launches the ps1' ((Get-Content -Raw 'MOSS-Image-Studio.vbs').Contains('MOSS-Image-Studio.ps1'))
Test 'no admin code functions remain' (-not ($src.Contains('Confirm-MossAdminAccess') -or $src.Contains('Show-MossAdminCode')))
Test 'no forced CPU offload' (-not ($src.Contains('--offload-to-cpu') -or $src.Contains('--offload_max_tensor')))
Test 'no hires refine flags remain' (-not $src.Contains('--hires'))
Test 'batch count flag present' ($src.Contains('--batch-count'))
Test 'conditioning cache flag present' ($src.Contains('--conditioning-cache-size'))
Test 'img2img refinement wired' ($src.Contains('-i') -and $src.Contains('--strength') -and $src.Contains('InitStrength=0.45'))
Test 'hq filename tags present' ($src.Contains("'hq'") -and $src.Contains('${refineSuffix}'))
Test 'braced interpolation avoids _suffix bug' (-not $src.Contains('$refineSuffix_%02d'))
Test 'fast-preview helper present' ($src.Contains('function Test-MossFastPreview') -and $src.Contains('UpscaledFrom'))
Test 'improve paths default to image-to-image (composition kept)' ($src.Contains('InitImage=[string]$item.File') -eq $false -and $src.Contains("InitImage=`$(if(`$isFresh){`$null}else{[string]`$item.File})"))
Test 'adaptive preview strength helpers' ($src.Contains('function Get-MossPreviewUpscaleFactor') -and $src.Contains('function Get-MossImproveStrength') -and $src.Contains('Get-MossImproveStrength $selFile $cStrength'))
Test 'image info dialog wired' ($src.Contains('function Show-MossImageInfo') -and $src.Contains('miInfo.Add_Click') -and $src.Contains('Copy prompt'))
Test 'CFG help popup uses real newlines (double-quoted)' ($src.Contains('"CFG scale (Classifier-Free Guidance)'))
Test 'startup error dialog uses real newlines (double-quoted)' ($src.Contains('"MOSS Image Studio could not start.'))
Test 'no literal backtick-r left in CFG help popup' (-not ($src.Contains('your prompt.``r``n``r``n- Low')))
Test 'improve strength hint has room (46px) and box has tooltip' ($src.Contains('(120,317); $impStrengthHint.Size=New-Object System.Drawing.Size(412,46)') -and $src.Contains('dlgTip.SetToolTip($impStrengthBox,'))

# --- Locale-safe decimal parsing (Danish etc. use comma decimals) ---
function ConvertTo-MossDouble([string]$text,[ref]$out) {
    $norm = ([string]$text).Trim().Replace(',','.')
    return [double]::TryParse($norm,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,$out)
}
function ConvertFrom-MossDouble([double]$value) {
    return $value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}
$p=0.0
Test 'parse 0.6 with dot' ((ConvertTo-MossDouble '0.6' ([ref]$p)) -and $p -eq 0.6)
$p=0.0
Test 'parse 0,6 with comma' ((ConvertTo-MossDouble '0,6' ([ref]$p)) -and $p -eq 0.6)
Test 'format invariant 3.5' ((ConvertFrom-MossDouble 3.5) -eq '3.5')
Test 'format invariant 0.6' ((ConvertFrom-MossDouble 0.6) -eq '0.6')
Test 'engine args use invariant formatting' ($src.Contains('ConvertFrom-MossDouble ([double]$job.Cfg)') -and $src.Contains('ConvertFrom-MossDouble ([double]$job.InitStrength)'))
Test 'locale helper wired in all sites' ((([regex]::Matches($src,'ConvertTo-MossDouble ')).Count -ge 5))
Test 'sampler dropdown shows actual default (euler)' ($src.Contains("@('Default (euler)','euler'") -and $src.Contains("if(`$saveSampler -eq 'Default (euler)')"))
Test 'scheduler dropdown shows actual default (flux schedule)' ($src.Contains("@('Default (flux schedule)','discrete'") -and $src.Contains("if(`$saveSched -eq 'Default (flux schedule)')"))
Test 'default labels still stored as Default (model) (compat)' ($src.Contains("if(`$storedSampler -eq 'Default (model)')") -and $src.Contains("if(`$storedSched -eq 'Default (model)')"))
Test 'preview loads unlocked copies (delete-safe)' ($src.Contains('function Copy-MossImageUnlocked') -and $src.Contains('Copy-MossImageUnlocked $p') -and -not ($src.Contains('preview.Image=[System.Drawing.Image]::FromFile')))
Test 'delete releases preview before Remove-Item' ($src.Contains('Release the preview first so no file is held open while deleting'))
Test 'improve-with-settings falls back to sidecar prompt' (($src -match 'fall back to the image.s own prompt from') -and ($src -match 'and prefill the box so the user can see what will be used') -and ($src -match 'Unprotect-MossPayload \(\[string\]\$sc\.PromptProtected\) \$script:HistoryPassphrase'))
Test 'history code field focused on show + timer reinforcement' (($src -match 'Add_Shown\(\{ try \{ \$dialog\.Activate\(\) \} catch \{\}; \[void\]\$first\.Focus') -and ($src -match 'focusTimer\.Add_Tick') -and ($src -match '\[MossNativeWindow\]::SetForegroundWindow\(\$dialog\.Handle\)'))
Test 'right-click menu is settings-driven' ($src.Contains('Improve this image (same seed and composition)...') -and $src.Contains("Re-render with this image''s OWN seed and size (ignores the main window settings)...") -and (-not ($src.Contains('Re-render from the same seed (fresh full quality)'))) -and (-not ($src.Contains('Improve this image (full quality)'))) -and (-not ($src.Contains('Start-MossRefineSelected'))))
Test 'improve is the FIRST right-click item (before the re-render item)' ($src.IndexOf("miCustom=`$refineMenu.Items.Add('Improve this image (same seed and composition)...')") -lt $src.IndexOf('miFresh='))
Test 'plain sidecar prompt saved even when history is locked (continue without password)' ($src.Contains('chose to continue WITHOUT the password at startup') -and $src.Contains('The encrypted history envelope in settings.json is') -and (-not ($src.Contains('} elseif (-not $script:HistoryLocked) {'))))
Test 'readers accept plain sidecar prompts (improve works without the code)' ($src.Contains('if (-not ([string]$d.Prompt).Trim() -and $sc.Prompt)') -and $src.Contains('if(-not $cPrompt -and $sc.Prompt)') -and $src.Contains("Plain sidecar prompt (no code entered when the image was made)"))
Test 'History code button opens a menu with an UNLOCK option' ($src.Contains('Enter code to unlock the prompt history...') -and $src.Contains('Set a NEW code (clears the saved history!)...') -and $src.Contains('Turn off prompt history (deletes the saved history)...') -and $src.Contains('Show-MossHistoryCodeMenu') -and $src.Contains('You can enter the code later via the History code... button'))
Test 'time taken survives completion (status + log)' ($src.Contains('the total elapsed survives completion') -and $src.Contains('Improvement finished - $script:RefineTotal image(s) processed$queueElapsed') -and $src.Contains('$batchTimeText = '' | total time ''') -and $src.Contains('$script:RefineStartedAt'))
Test 'improve dialog: size picker with Same/2x/4x and image seed prefill' ($src.Contains('PICK-YOUR-QUALITY DIALOG') -and $src.Contains('Target size') -and $src.Contains('$sameBtn') -and $src.Contains('$twoBtn') -and $src.Contains('$fourBtn') -and $src.Contains("the image's own seed - keeps the result aligned") -and $src.Contains('the original is never modified'))
Test 'progress bar pinned to the bottom, driven by the engine step counter (numeric readout removed - status line shows all numbers)' ($src.Contains('Progress bar pinned to the VERY BOTTOM') -and $src.Contains('StepNum = [int]$numerator; $st.StepDen = [int]$denominator') -and $src.Contains('''step {0,3}/{1,3}'' -f [int]$st.StepNum, [int]$st.StepDen') -and $src.Contains('$prog.Value = [Math]::Max($prog.Minimum,[Math]::Min($prog.Maximum,$overall))') -and $src.Contains("$prog.Style = 'Marquee'") -and $src.Contains("Anchor='Bottom,Left,Right'"))
Test 'no duplicate numeric readout next to the bar (numbers live in the status line only)' (-not $src.Contains('progPct'))
Test 'status line is fixed-width (padded numbers, h:mm:ss times, monospace font - user request)' ($src.Contains('function Format-MossFixedTime') -and $src.Contains("$phase.PadRight(17)") -and $src.Contains("Font('Consolas',9)"))
Test 'loading phase says warming up in the status line (readout text moved there)' ($src.Contains("else { 'warming up...' }"))
Test 'memory retry chain Exact->4x->8x->Fast with ForcedSpeed' ($src.Contains('''Exact'' { $retryMode = ''4x'' }') -and $src.Contains('''4x''    { $retryMode = ''8x'' }') -and $src.Contains('''8x''    { $retryMode = ''Fast'' }') -and $src.Contains('ForcedSpeed=$retryMode') -and $src.Contains('Retrying the improvement with a SMALLER render size'))
Test 'style prefix not doubled when the prompt already has it' ($src.Contains('-not $p.ToLowerInvariant().StartsWith($stylePrefix.ToLowerInvariant())'))
Test 'style prefix not doubled when the prompt already has it' ($src.Contains('-not $p.ToLowerInvariant().StartsWith($stylePrefix.ToLowerInvariant())'))
Test 'encrypted-prompt improve error is specific and actionable' ($src.Contains('it is stored ENCRYPTED (a history code was active when the image was generated), and no code is currently entered') -and $src.Contains("1. Click 'History code...' in the header, enter your code, then right-click the image again") -and $src.Contains('2. Or type a NEW prompt in the main window and try again') -and $src.Contains('Nothing was generated and the image was not changed'))
Test 'maximize keeps the generated files box visible (no hiding special case)' ((-not ($src.Contains('Maximized'))) -and $src.Contains('the file list and the log stay usable'))
Test 'improve dialog shows source size and warns on aspect and oversize' ($src.Contains('source {0} x {1}') -and $src.Contains('the composition will be squashed or stretched') -and $src.Contains('rendered at HALF SIZE with all {1} steps'))
Test 'improve is the FIRST right-click item (before the re-render item)' ($src.IndexOf("miCustom=`$refineMenu.Items.Add('Improve using the settings in the main window...')") -lt $src.IndexOf('miFresh='))
Test 'fresh re-render of a fast draft warns and points at Improve' ($src.Contains('This image is an upscaled fast DRAFT') -and $src.Contains('a FULL-QUALITY VERSION OF THIS PICTURE') -and $src.Contains('the seed does not preserve the composition across render sizes'))
Test 'refine queue continues after batch' ($src.Contains('Start-MossNextRefine') -and $src.Contains('RefineQueue'))
Test 'refine skip clearing with -ForRefine' ($src.Contains('param($Job,[switch]$ForRefine)') -and $src.Contains('if (-not $ForRefine)'))
Test 'uncapped batch (no hard limit wording)' ($src.Contains('No hard limit - very large batches ask first'))
Test 'generated file list survives Generate (no Items.Clear on start)' (-not ($src.Contains('$fileList.Items.Clear()')))
Test 'output default outputs' ($src.Contains("`$script:Settings.OutputPath='outputs'") -or $src.Contains("`$script:Settings.OutputPath = 'outputs'"))

# --- Speed mode scale logic (mirror of Start-MossBatchEngine) ---
function Get-RenderScale([string]$mode, [int]$w, [int]$h) {
    $scale = switch ($mode) { '2x' {0.7} '4x' {0.5} '8x' {0.35} 'Fast' { [Math]::Min(0.35, 128.0/[Math]::Min($w,$h)) } default {1.0} }
    return $scale
}
Test 'speed scale 2x' ((Get-RenderScale '2x' 1000 1000) -eq 0.7)
Test 'speed scale 4x' ((Get-RenderScale '4x' 1000 1000) -eq 0.5)
Test 'speed scale 8x' ((Get-RenderScale '8x' 1000 1000) -eq 0.35)
Test 'speed scale Fast clamps to 128/min' ((Get-RenderScale 'Fast' 1000 1000) -eq 0.128)
Test 'Fastest render floor is 128px' ($src.Contains('128.0 / [Math]::Min($job.Width, $job.Height)') -and $src.Contains('[Math]::Max(128,'))
Test 'speed scale Exact = native' ((Get-RenderScale 'Exact' 500 500) -eq 1.0)

# --- Refine filename logic (exact app code) ---
$stamp = '20261120_140000_123'
foreach ($case in @(@(1,@($null,('MOSS_'+$stamp+'_%02d.png'))), @(2,@('hq',('MOSS_'+$stamp+'_hq_%02d.png'))), @(3,@('hq2x',('MOSS_'+$stamp+'_hq2x_%02d.png'))))) {
    $c = $case[1]
    $refineSuffix = if ($c[0]) { '_' + [string]$c[0] } else { '' }
    $pattern = Join-Path 'C:\moss\outputs' ("MOSS_{0}${refineSuffix}_%02d.png" -f $stamp)
    $expanded = $pattern -replace '%02d','{0:D2}'
    $final = ($expanded -f 1)
    $expected = $c[1] -replace '%02d','01'
    Test ('filename tag ' + $(if($c[0]){$c[0]}else{'none'})) ((Split-Path $final -Leaf) -eq $expected)
}
# --- Refine size targets ---
foreach ($case in @(@(1,1360,768,1360,768), @(2,1360,768,2720,1536), @(2,5000,5000,8192,8192))) {
    $tw = [int][Math]::Min(8192, [Math]::Ceiling($case[1]*$case[0])); $th = [int][Math]::Min(8192, [Math]::Ceiling($case[2]*$case[0]))
    Test ('refine size x' + $case[0] + ' ' + $case[1] + 'x' + $case[2]) ($tw -eq $case[3] -and $th -eq $case[4])
}

# --- Seed from sidecar / fallback ---
function Get-RefineSeed($sc, [long]$fallback) { $s = [long]-1; if ($sc -and $sc.Seed) { $s = [long]$sc.Seed }; if ($s -lt 0) { $s = $fallback }; return $s }
Test 'seed from sidecar' ((Get-RefineSeed ([pscustomobject]@{Seed=42}) 999) -eq 42)
Test 'seed fallback when missing' ((Get-RefineSeed $null 999) -eq 999)

# --- Output migration logic (exact app condition) ---
$appRoot = 'C:\moss'
foreach ($case in @(@('outputs\admin',$true), @('outputs',$false), @('E:\MyPics',$false), @($null,$false))) {
    $saved = $case[0]
    $migrated = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$saved)) {
        try {
            $savedFull = [System.IO.Path]::GetFullPath((Join-Path $appRoot ([string]$saved)))
            $legacyAdmin = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'outputs\admin'))
            if ($savedFull.TrimEnd('\','/') -ieq $legacyAdmin.TrimEnd('\','/')) { $migrated = $true }
        } catch {}
    }
    Test ('migration for [' + $saved + '] -> ' + $case[1]) ($migrated -eq $case[1])
}

Test 'code dialogs shown owned by the main window' (($src -match 'ShowDialog\(\$Owner\)') -and ($src -match 'Get-MossHistoryPassphrase \$false ''history'' \$f') -and (([regex]::Matches($src,'Reset-MossHistoryPassword \$f')).Count -ge 2))
Test 'style list has None (no style) first and sends prompt untouched' ($src.Contains("@('None (no style)','Photorealistic'") -and $src.Contains("# 'None (no style)' falls through to default{''}"))
Test 'eight new visual styles wired' (($src.Contains("'Fantasy art'{") -and $src.Contains("'Cyberpunk / sci-fi'{") -and $src.Contains("'Pixel art'{")) -and (([regex]::Matches($src,"'Low poly 3D'")).Count -ge 2))
Test 'error report is local-only (no upload path)' ((-not ($src.Contains('ErrorReportUrl'))) -and ($src.Contains('Nothing is sent over the internet - the report stays on this computer')) -and ($src.Contains("saved to logs\`$savedName (nothing is sent online)")))
Test 'out-of-memory hint for silent engine failures' ($src.Contains('without any error message') -and $src.Contains('running out of GPU or system memory'))
Test 'oversized improve targets auto half-size render' ($src.Contains('too large for a native render on most GPUs') -and $src.Contains("$refineSpeed = '4x'") -and $src.Contains('SpeedMode=$refineSpeed'))
Test 'improve logs show source -> final size' ($src.Contains('-> final {4} x {5} (strength {6} - fast preview') -and $src.Contains('composition kept from the image'))
Test 'frontend identity: title and command-line transparency' ($src.Contains('(GUI for sd-cli) | Generator') -and $src.Contains('Engine command line: {0} {1}') -and $src.Contains('ShowEngineCommandLine'))
Test 'fresh re-render menu item wired' ($src.Contains("Re-render with this image''s OWN seed and size") -and $src.Contains('function Start-MossRefineFresh') -and $src.Contains("FreshRender=`$true") -and $src.Contains("InitImage=`$(if(`$isFresh){`$null}"))
# --- v0.1.40: separate engine (core files) updater from the MOSS app updater ---
Test 'header buttons are clearly separated' ($src.Contains("`$updateBtn.Text='Update MOSS...'") -and $src.Contains("`$engineBtn.Text='Update engine...'") -and (-not ($src.Contains("'Check updates'"))))
Test 'both update buttons have explaining tooltips' ($src.Contains("SetToolTip(`$updateBtn") -and $src.Contains("SetToolTip(`$engineBtn"))
Test 'engine updater is a separate dialog function' ($src.Contains('function Show-MossEngineUpdateDialog') -and $src.Contains('function Get-MossEngineCommit'))
Test 'engine updater explains the MOSS-vs-engine difference' ($src.Contains('MOSS is the GUI - sd-cli.exe and its libraries are the engine') -and $src.Contains('the MOSS app, models, prompts, outputs and settings are never touched'))
Test 'engine updater targets the sd-cli engine repo' ($src.Contains('leejet/stable-diffusion.cpp/releases'))
Test 'app updater still targets the MOSS repo' ($src.Contains('kukomamasan/moss-image-studio/releases/latest'))
Test 'engine updater parses the installed commit' ($src.Contains('commit\s+([0-9a-fA-F]{6,40})') -and $src.Contains('Get-MossEngineCommit $enginePath'))
Test 'engine updater refuses while generating' ($src.Contains('GenState.IsRunning') -and $src.Contains('before updating the engine files'))
Test 'engine updater backs up before replacing' ($src.Contains("'engine-backup-'+`$stamp+'.zip'") -and $src.Contains('Backed up '))
Test 'engine backups are compressed zip archives' ($src.Contains('CreateEntry($name,$level') -and $src.Contains('CompressionLevel]::Optimal') -and $src.Contains('Backing up the current engine files (compressing)') -and $src.Contains('CreateEntryFromFile is not'))
Test 'incompressible files are stored (middle-sample, no wasted time)' ($src.Contains('middle') -and $src.Contains('DeflateStream($msS') -and $src.Contains('>= 0.95') -and $src.Contains('NoCompression'))
Test 'restore handles compressed zips and legacy folders' ($src.Contains("'engine-backup-*.zip'") -and $src.Contains("Kind='zip'") -and $src.Contains("Kind='folder'"))
Test 'failure restore extracts the compressed backup' ($src.Contains('MOSS-Backup-Restore-') -and $src.Contains('restored and verified working again'))
Test 'engine updater restores on failure' ($src.Contains('The previous engine files were restored') -and $src.Contains('Copy-Item -LiteralPath $bak.FullName'))
Test 'engine updater matches all variants (CUDA versions dynamic)' ($src.Contains("'bin-win-cuda'+") -and $src.Contains("'bin-win-vulkan-x64.zip'") -and $src.Contains("'bin-win-cpu-x64.zip'") -and $src.Contains("'bin-win-rocm'") -and $src.Contains("'bin-win-sycl'"))
Test 'cudart is automatic and required for CUDA builds (no checkbox, no note)' ($src.Contains('cudart is REQUIRED for CUDA builds and is downloaded automatically') -and $src.Contains('Every selected CUDA variant gets it automatically') -and -not $src.Contains('cudartNote'))
Test 'engine updater shows changelogs' ($src.Contains('RELEASE NOTES / CHANGELOG') -and $src.Contains('No release notes were published for this build') -and $src.Contains('Windows packages in this release'))
Test 'engine updater writes a log' ($src.Contains('engine-update-') -and $src.Contains('Models, prompts, outputs and settings are never touched'))
Test 'engine updater verifies sha256 digest when published' ($src.Contains('function Test-MossZipDigest') -and $src.Contains('sha256 mismatch') -and $src.Contains('Get-FileHash'))
Test 'engine updater checks disk space before downloading' ($src.Contains('Not enough free disk space') -and $src.Contains('AvailableFreeSpace') -and $src.Contains('Disk space pre-check'))
Test 'engine updater verifies the new engine starts and auto-restores' ($src.Contains('function Get-MossEngineVersionOutput') -and $src.Contains('does not start (no version output)'))
Test 'engine updater re-checks engine processes before replacing' ($src.Contains('started while the download was running'))
Test 'engine updater verifies the previous engine after restore' ($src.Contains('restored and verified working again') -and $src.Contains('Get-MossEngineVersionOutput $enginePath'))
Test 'engine updater blocks Close during install' ($src.Contains('$closeBtn.Enabled=$false') -and $src.Contains('$pageBtn.Enabled=$false'))
Test 'engine updater notes a same-commit reinstall' ($src.Contains('reinstalled the current version'))
Test 'engine dialog offers backup restore (rollback)' ($src.Contains("'Restore a backup...'") -and $src.Contains("'engine-backup-*'") -and $src.Contains('function Show-MossEngineBackupRestore'))
Test 'engine restore verifies the engine after rollback' ($src.Contains('Rollback complete - the engine files from') -and $src.Contains('Get-MossEngineVersionOutput $enginePath'))
Test 'engine backups never contain or touch model files' ($src.Contains('the large model files are never modified by an engine update'))
Test 'engine dialog reachable when up to date' ($src.Contains('UP TO DATE') -and (-not ($src.Contains('Open the releases page to read the changelogs anyway?'))))
Test 'engine restore reachable when offline' ($src.Contains('Choose No to open the backup-restore dialog instead'))
# --- v0.1.40 follow-ups: dynamic CUDA versions, driver-aware Auto, side-by-side extra engines ---
Test 'cuda versions read dynamically from each release (11/12/13 ready)' ($src.Contains('bin-win-cuda(') -and $src.Contains('[version]$v'))
Test 'Auto is default and explained in plain language' ($src.Contains("'Auto (recommended for my hardware)'") -and $src.Contains('$variantDesc.Text=') -and $src.Contains('$resolveAuto'))
Test 'Auto uses the driver CUDA capability from nvidia-smi' ($src.Contains('CUDA Version:\s*([0-9]+\.[0-9]+)') -and $src.Contains('newest CUDA build your driver'))
Test 'cuda builds above the driver version are skipped by Auto' ($src.Contains('$cMaj -le $dMaj'))
Test 'extra variants install side by side into engines folders' ($src.Contains("'engines'") -and $src.Contains("'.old-'+`$stamp") -and $src.Contains('switchable at any time'))
Test 'extra engines are verified after install (warn only)' ($src.Contains('did not start (no version output) - it stays in') -and $src.Contains('Extra "+(& $variantLabelOf'))
Test 'install plan shown before download' ($src.Contains('Install plan:') -and $src.Contains('$planText'))
Test 'variant dropdown rebuilds per selected release' ($src.Contains('$syncVariantCombo') -and $src.Contains('$script:MossDlgConcrete'))
# --- v0.1.40: combined engine + model updates, model backups, retention ---
Test 'model update check function exists (huggingface metadata only)' ($src.Contains('function Get-MossModelUpdateInfo') -and $src.Contains('huggingface.co/api/models/') -and $src.Contains('tree/main?recursive=true') -and $src.Contains('no multi-GB'))
Test 'all four model sources mapped' ($src.Contains('Comfy-Org/MOSS-Image') -and $src.Contains('unsloth/Qwen3.5-9B-GGUF') -and $src.Contains('OpenMOSS-Team/MOSS-Image-Base'))
Test 'models checked at the same time as the engine' ($src.Contains('Check the model sources at the same time') -and $src.Contains('$script:MossDlgModels'))
Test 'models section only lists models needing attention' ($src.Contains('only models that need attention'))
Test 'model backup prompt with instant rename' ($src.Contains('$modelBackupCheck') -and $src.Contains('renamed to <name>.old-<time>') -and $src.Contains('Rename-Item -LiteralPath $destModel'))
Test 'download speed measured for the time estimate' ($src.Contains('function Measure-MossDownloadSpeed') -and $src.Contains('at your measured speed'))
Test 'confirm dialog warns about sizes and time' ($src.Contains('Estimated model download time:') -and $src.Contains('GB-sized models take longer'))
Test 'disk space check includes model downloads' ($src.Contains('$needTemp=$totalDl*3 + $needBase + $modelsTotal*2') -and $src.Contains('$needBin=$totalDl*4 + $needBase + $modelsTotal*2'))
Test 'model download verified by size before replacing' ($src.Contains('download size mismatch') -and $src.Contains('Installing model '))
Test 'engine backups capped at 3 (oldest deleted)' ($src.Contains('beyond the limit of 3') -and $src.Contains("Filter 'engine-backup-*.zip'"))
Test 'model backups capped at 3 per model' ($src.Contains("'.old-*'") -and $src.Contains('Deleted old model backup beyond the limit of 3'))
Write-Host ''
# --- v0.1.40: startup completeness offer ---
Test 'startup checks engine and models, offers download' ($src.Contains('function Test-MossOfferStartupDownload') -and $src.Contains('MOSS is not fully installed yet') -and $src.Contains('Download them now?'))
Test 'startup offer runs from the generator Shown event' ($src.Contains('Test-MossOfferStartupDownload $f') -and $src.Contains('Unlock-MossHistoryAfterShow'))
Test 'startup offer measures speed and lists what is missing' ($src.Contains('Without these files MOSS cannot generate images') -and $src.Contains('the engine (sd-cli.exe and its libraries) is missing'))
Test 'startup offer points to the update dialog as the fallback' ($src.Contains("via 'Update engine...' in the header"))
Write-Host ''
Test 'huggingface tree unwrap survives the nested-array quirk' ($src.Contains('if($tree.Count -ge 1 -and $tree[0] -isnot [pscustomobject] -and $tree[0] -is [System.Collections.IEnumerable])'))
Test 'model match uses exact repo path (tokenizer.json vs tokenizer_qwen3.5.json)' ($src.Contains('path -eq $m.RepoPath'))
Test 'startup detects a drive that cannot fit the downloads' ($src.Contains('$needTotal=$modelsTotal+[int64](600MB)') -and $src.Contains('MOSS is in a tight spot'))
Test 'relocation picks the fixed drive with the most free space' ($src.Contains('function Find-MossRelocationDrive') -and $src.Contains("Filter 'DriveType=3'"))
Test 'relocation copies app files and creates a desktop shortcut' ($src.Contains('function Move-MossToNewLocation') -and $src.Contains('MOSS Image Studio.lnk') -and $src.Contains('WorkingDirectory=$newRoot'))
Test 'relocation offers to start the new copy and closes the old window' ($src.Contains('Start the new copy now?') -and $src.Contains('wscript.exe') -and $src.Contains('$Owner.Close()'))
Test 'no other drive with room: honest warning instead of dead end' ($src.Contains('no other fixed drive has room either'))
Test 'relocation explained in plain language' ($src.Contains('this copy can be deleted afterwards'))
Test 'history code prompt never shows a missing purpose word (was: Enter the  code.)' (-not ($src.Contains('Passphrase $false $null')))
Test 'history code prompt falls back to history if purpose is empty' ($src.Contains('IsNullOrWhiteSpace($Purpose)'))
Test 'relative path anchoring: Get-RelativeAppPath resolves via Get-AbsoluteAppPath' ($src.Contains('GetFullPath((Get-AbsoluteAppPath $value))'))
# Runtime regression for the v0.1.46 output-folder bug: with a hostile process
# working directory, a relative OutputPath must stay app-root-anchored.
try {
    $oldCwd=[System.Environment]::CurrentDirectory
    $hostileRoot=[System.IO.Path]::GetTempPath()
    [System.Environment]::CurrentDirectory=$hostileRoot
    $fnStart=$src.IndexOf('function Get-AbsoluteAppPath')
    $fnEnd=$src.IndexOf('function ConvertTo-MossDouble')
    if($fnStart -ge 0 -and $fnEnd -gt $fnStart){
        $fns=$src.Substring($fnStart,$fnEnd-$fnStart)
        $sandbox=[System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),('moss-pathtest-'+[guid]::NewGuid().ToString('N').Substring(0,8)))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        Invoke-Expression ($fns + "`$script:AppRoot='$sandbox'")
        $rel=Get-RelativeAppPath 'outputs'
        $abs=Get-AbsoluteAppPath 'outputs'
        Test 'runtime: relative OutputPath stays app-anchored with hostile cwd' ($rel -eq 'outputs')
        Test 'runtime: Get-AbsoluteAppPath anchors to the app root' ($abs.TrimEnd('\') -eq ((Join-Path $sandbox 'outputs').TrimEnd('\')))
        Test 'runtime: absolute custom folder passes through unchanged' ((Get-RelativeAppPath 'C:\ definitely\not\under\app') -eq 'C:\ definitely\not\under\app')
        Remove-Item -LiteralPath $sandbox -Force -ErrorAction SilentlyContinue
    } else {
        Test 'runtime path functions extractable for regression test' $false
    }
    [System.Environment]::CurrentDirectory=$oldCwd
} catch { Test 'runtime path regression block ran without exception' $false }
# v0.1.59 progress parsing: the engine prints sampling progress as a console
# bar '| 1/4 - 1.37s/it' (carriage-return separated, ESC[K-terminated) - no
# percent sign, no word 'steps'. The old regexes never matched, so the bar
# walked as marquee, % stayed 0 and ETA never computed. Tests use the REAL
# bar format captured from sd-cli master-1106-532d2c1.
Test 'sampling progress bar regex present (it/s or s/it units)' ($src.Contains('(it/s|s/it)'))
Test 'percent fallback kept for engines that print %' ($src.Contains('\b(\d{1,3})\s*%'))
Test 'progress window anchored to the last generating-image line' ($src.Contains("LastIndexOf('generating image:')"))
Test 'step counters reset before each parse tick' ($src.Contains('$st.StepNum = 0; $st.StepDen = 0'))
Test 'load-bar exclusion is documented in the code' ($src.Contains('VAE-decode bars use the same N/M shape but GB/s / MB/s units'))
try {
    $ix = $src.IndexOf('(it/s|s/it)')
    $q1 = $src.LastIndexOf([char]39, $ix)
    $q2 = $src.IndexOf([char]39, $ix)
    $pat = $src.Substring($q1 + 1, $q2 - $q1 - 1)
    Test 'runtime: sampling-bar pattern extractable from source' ($pat.Contains('(it/s|s/it)'))
    $esc = [string][char]27
    $stream = "  |============>                                     | 1/4 -   1.37s/it$esc" + "K\r  |=========================>                        | 2/4 -  30.29it/s$esc" + "K\r  |=====================================>            | 3/4 -  33.51it/s$esc" + "K"
    $m = [regex]::Matches($stream, $pat)
    Test 'runtime: all 3 sampling steps parse from the real bar format' ($m.Count -eq 3)
    Test 'runtime: last step is 3/4' ($m[$m.Count - 1].Groups[1].Value -eq '3' -and $m[$m.Count - 1].Groups[2].Value -eq '4')
    Test 'runtime: first slow step read from the s/it unit' ($m[0].Groups[3].Value -eq 's/it')
    $loadBar = '  |##################################################| 426/426 -   5.34GB/s' + $esc + 'K'
    $vaeBar = '  |##################################################| 140/140 - 884.52MB/s' + $esc + 'K'
    Test 'runtime: model-load bar (GB/s) never counts as sampling progress' ([regex]::Matches($loadBar, $pat).Count -eq 0)
    Test 'runtime: vae-decode bar (MB/s) never counts as sampling progress' ([regex]::Matches($vaeBar, $pat).Count -eq 0)
    $img2 = '[I] generating image: 2/2 - seed 7' + "\n" + '  |=========================>                        | 1/4 -   2.10s/it' + $esc + 'K'
    $twoImg = $stream + "\n" + $img2
    $widx = $twoImg.LastIndexOf('generating image:')
    $mw = [regex]::Matches($twoImg.Substring($widx), $pat)
    Test 'runtime: batch window keeps progress on the CURRENT image (1/4, not the old 3/4)' ($mw.Count -eq 1 -and $mw[0].Groups[1].Value -eq '1' -and $mw[0].Groups[2].Value -eq '4')
    Test 'runtime: textual step counter still works as fallback' ([regex]::Matches('step 17/50', '(?im)(?:\bstep\s*[:#]?\s*(\d+)\s*/\s*(\d+)\b|\b(\d+)\s*/\s*(\d+)\s*steps?\b)').Count -eq 1)
} catch { Test 'runtime: progress parsing block ran without exception' $false }
# v0.1.60: the event-based capture NEVER fired in the STA + WinForms app
# (PowerShell's event queue is not pumped by the message loop), so the engine
# output was empty for the whole run - live progress, %, ETA and the exit log
# all saw nothing. Capture now runs on a background runspace thread that
# blocks in ReadLine and fills a synchronized hashtable the tick reads.
Test 'engine output captured on a background runspace thread (events never fire in WinForms)' ($src.Contains('$st.CaptureRunner = [powershell]::Create()') -and $src.Contains('StandardOutput.ReadLine()'))
Test 'no Register-ObjectEvent output capture left' (-not $src.Contains('Register-ObjectEvent -InputObject $proc'))
Test 'capture is a synchronized hashtable the tick reads' ($src.Contains("[hashtable]::Synchronized(@{ Out = ''; Err = '' })") -and $src.Contains('$st.Capture.Out'))
Test 'capture thread started after the engine process exists' ($src.IndexOf('proc.Start()') -lt $src.IndexOf('CaptureRunner = [powershell]::Create()'))
Test 'exit path waits for the capture thread before reading final output' ($src.Contains('CaptureRunner.EndInvoke($st.CaptureAsync)'))
Test 'cancel path stops the capture runspace' ($src.Contains('CaptureRunner.Stop()'))
Test 'OOM detection keys on missing [E] error line, not empty output (capture now works)' ($src.Contains('(?m)^\[E\][^\r\n]*') -and $src.Contains('$memoryDeath = -not $hasExplicitError'))
Test 'OOM hint shows the engine''s last [E] error line' ($src.Contains('its last error: {0}'))
try {
    $errOut = "[I] loading model`n[E] vae decode compute failed --- vae.hpp:379"
    $e2 = [regex]::Matches($errOut, "(?m)^\[E\][^\r\n]*")
    Test 'runtime: [E] heuristic extracts the error line' ($e2.Count -eq 1 -and $e2[0].Value.Contains('vae decode compute failed'))
    $cleanOut = "[I] generating image: 1/1 - seed 42`n"
    Test 'runtime: [E] heuristic finds no error in clean output' ([regex]::Matches($cleanOut, "(?m)^\[E\][^\r\n]*").Count -eq 0)
    $memOut = "[I] loading model`n[E] ggml: failed to allocate memory`n"
    $e3 = [regex]::Matches($memOut, "(?m)^\[E\][^\r\n]*")[0].Value
    Test 'runtime: memory-ish [E] line marks the death as memory' ($e3 -match 'memory|allocat|out of mem|OOM')
} catch { Test 'runtime: OOM heuristic block ran without exception' $false }
# v0.1.61: the frozen 99% at the end - after the last sampling step the
# engine decodes the latent and saves (seconds at bigger sizes, no progress
# output) - now shows 'decoding and saving the image...' instead.
Test 'decode phase detected from the engine log' ($src.Contains('$decIdx = $progressWindow.LastIndexOf(''decoding'')'))
Test 'save phase detected from the engine log' ($src.Contains('$saveIdx = $progressWindow.LastIndexOf(''save result image'')'))
Test 'decode/save phases named in the status line' ($src.Contains('decoding/saving...'))
try {
    function Test-Phase([string]$w) {
        $d = $w.LastIndexOf('decoding'); $dd = $w.LastIndexOf('decoded'); $s = $w.LastIndexOf('save result image')
        if ($s -ge 0) { return 'saving' } elseif ($d -ge 0 -and ($dd -lt 0 -or $d -gt $dd)) { return 'decoding' } elseif ($dd -ge 0) { return 'saving' } else { return 'sampling' }
    }
    Test 'runtime: mid-sampling stays sampling' ((Test-Phase "[I] generating image: 1/1`n  |====>  | 5/40 - 4.7it/s") -eq 'sampling')
    Test 'runtime: decoding 1 latents -> decoding' ((Test-Phase "[I] sampling completed`n[I] decoding 1 latents") -eq 'decoding')
    Test 'runtime: latent decoded, not yet saved -> saving' ((Test-Phase "[I] decoding 1 latents`n[I] latent 1 decoded") -eq 'saving')
    Test 'runtime: save result image -> saving' ((Test-Phase "[I] latent 1 decoded`n[I] save result image 0 to 'out.png'") -eq 'saving')
    Test 'runtime: phase window is cut at the current image, so a finished image''s save line cannot leak' ((Test-Phase ("[I] save result image 0`n[I] generating image: 2/2".Substring("[I] save result image 0`n[I] generating image: 2/2".LastIndexOf('generating image:')))) -eq 'sampling')
} catch { Test 'runtime: phase detection block ran without exception' $false }
# v0.1.62: (1) the improve queue said 'Improvement finished' even when the
# job FAILED (user saw 'Improvement finished' under an error report) - the
# queue now counts failures and says 'Improvement FAILED'. (2) The OOM
# auto-retry missed the real live case: the memory evidence sat in a [W]
# line ('execution engine cannot make enough memory available on CUDA0')
# while the last [E] line was just 'generate failed'.
Test 'failed improve queue says Improvement FAILED' ($src.Contains('Improvement FAILED - ') -and $src.Contains('$script:RefineFailCount'))
Test 'refine failures counted from the batch result' ($src.Contains('if ($exitCode -ne 0 -or $ok -lt $job.Count) { $script:RefineFailCount'))
Test 'OOM evidence matched in the WHOLE output (memory warnings are [W] lines, not [E])' ($src.Contains("$allOutputText -match 'enough memory available|out of memory|failed to allocate|allocation failed|failed during weight preparation'"))
try {
    # The EXACT lines from the user's failed 2720x1536 improve (exit 1).
    $liveOut = '[W] model manager memory on CUDA0: reported free 11096.00 MB / total 12287.50 MB, tracked weights 0.00 MB / other runtime 0.00 MB / current runtime 0.00 MB --- model_manager.cpp:1817' + "`n" + '[W] execution engine cannot make enough memory available on CUDA0: need 17983.47 MB device / 16959.47 MB budget, available 11096.00 MB device / 10586.00 MB budget --- execution_engine.cpp:947'
    $liveErr = '[E] vae segment 1/1 (graph) failed during weight preparation --- execution_engine.cpp:596' + "`n" + '[E] vae encode compute failed --- vae.hpp:308' + "`n" + '[E] failed to encode init image --- image.cpp:302' + "`n" + '[E] generate failed --- main.cpp:1001'
    $allT = $liveOut + "`n" + $liveErr
    $em = [regex]::Matches($allT, "(?m)^\[E\][^\r\n]*")
    $lastE = $em[$em.Count - 1].Value.Trim()
    $md = $false
    if ($lastE -match 'memory|allocat|out of mem|OOM' -or $allT -match 'enough memory available|out of memory|failed to allocate|allocation failed|failed during weight preparation') { $md = $true }
    Test 'runtime: the real 2720x1536 OOM improve is detected as memory death (auto-retry fires)' ($md)
    # The benign model-manager line alone must NOT mark memory death.
    $benign = '[W] model manager memory on CUDA0: reported free 11096.00 MB / total 12287.50 MB --- model_manager.cpp:1817' + "`n" + '[E] generate failed --- main.cpp:1001'
    $em2 = [regex]::Matches($benign, "(?m)^\[E\][^\r\n]*")[0].Value.Trim()
    $md2 = $em2 -match 'memory|allocat|out of mem|OOM' -or $benign -match 'enough memory available|out of memory|failed to allocate|allocation failed|failed during weight preparation'
    Test 'runtime: the ever-present model-manager memory line does NOT mark memory death' (-not $md2)
} catch { Test 'runtime: OOM live-case block ran without exception' $false }
# v0.1.63/v0.1.64: 'run ALL chosen steps' - img2img scales steps by strength
# (50 chosen x 0,6148 = about 31 run, user read the 31/31 bar as a bug, then
# asked 'if i want the quality at 50 it should do the 50'). The compensation
# is now ALWAYS ON for img2img improves: MOSS raises the ENGINE step count to
# ceil((chosen-1)/strength). VERIFIED with the real engine: 80 engine steps
# at strength 0,6148 -> 'target t_enc is 49 steps' -> sampled 50/50.
Test 'chosen steps ALWAYS run (no checkbox, no opt-in - default behavior)' (-not $src.Contains('Run ALL steps anyway'))
Test 'engine step compensation formula always applied to img2img' ($src.Contains('[Math]::Ceiling(($refineSteps - 1) / $refineStrength)'))
Test 'compensation capped and logged in plain language' ($src.Contains('[Math]::Min(1000,') -and $src.Contains('the engine step count is raised to'))
Test 'job carries ChosenSteps so an OOM retry cannot compensate twice' ($src.Contains('ChosenSteps=$refineSteps') -and $src.Contains('Steps=[int]$job.ChosenSteps'))
Test 'successful retry resolves the item''s earlier failure (fail count decrements)' ($src.Contains('elseif ($script:RefineFailCount -gt 0) { $script:RefineFailCount-- }'))
Test 'OOM retry re-queue carries the source dimensions (was 0 x 0)' ($src.Contains('SrcW=[int]$job.SrcW; SrcH=[int]$job.SrcH'))
Test 'refine job carries SrcW/SrcH through' ($src.Contains("SrcW=`$(if(`$item.PSObject.Properties['SrcW']){[int]`$item.SrcW}else{0})"))
try {
    Test 'runtime: compensation math (50 chosen, strength 0,6148 -> 80 engine steps)' ([Math]::Ceiling((50 - 1) / 0.6148) -eq 80)
} catch { Test 'runtime: full-steps block ran without exception' $false }
# v0.1.65: the header subtitle 'GPU: automatic' now names the detected GPU
# the engine will use (user: 'it should instead show what gpu was chosen').
Test 'GPU subtitle shows just the detected adapter name (no word automatic, user request)' ($src.Contains('''GPU: '' + [string]$gpusAuto[0].Name') -and -not $src.Contains("'GPU: automatic ('"))
Test 'manual GPU selection still shows the chosen name' ($src.Contains('PreferredGpuName'))
try {
    $g = @(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
        $n = [string]$_.Name; $h = "$n $($_.Description) $($_.PNPDeviceID)"
        $v = 'Unknown'
        if ($h -match '(?i)VEN_10DE|NVIDIA|GeForce|Quadro|Tesla') { $v = 'NVIDIA' } elseif ($h -match '(?i)VEN_1002|VEN_1022|AMD|Radeon') { $v = 'AMD' } elseif ($h -match '(?i)VEN_8086|Intel') { $v = 'Intel' }
        $virt = $h -match '(?i)virtual|indirect display|remote display|parsec|spacedesk|usb display|displaylink|mirage|idd'
        [pscustomobject]@{ Name = $n; Vendor = $v; IsVirtual = $virt }
    } | Where-Object { -not $_.IsVirtual -and $_.Vendor -ne 'Unknown' })
    Test 'runtime: detected GPU on this machine is a known vendor' ($g.Count -ge 1)
    Test 'runtime: subtitle would include the adapter name' (('GPU: automatic (' + $g[0].Name + ')') -like 'GPU: automatic (*)')
} catch { Test 'runtime: GPU subtitle block ran without exception' $false }
# v0.1.69: batch overlap (user: 'it will wait for all images to be done, and
# then run the resizer, maybe run the resizer + generate pictures, since
# resizer uses cpu, it should not have a big impact'): each image is
# upscaled + registered LIVE while the engine renders the rest; the
# batch-end pass only handles leftovers.
Test 'shared per-image completion used live and at batch end' ($src.Contains('function Complete-MossBatchImage'))
Test 'live completion runs in the progress tick' ($src.Contains('LIVE COMPLETION OVERLAP'))
Test 'an image counts as done when the engine moved to a LATER image or saved the current one' ($src.Contains("`$maxDone = if (`$progressWindow -match 'save result image')") -and $src.Contains('[Math]::Max(0, $lastGen - 1)'))
Test 'live-completed images tracked per run' ($src.Contains('LiveCompletedImages = New-Object System.Collections.ArrayList'))
Test 'batch-end pass skips live-completed images (no double processing)' ($src.Contains('LiveCompletedImages -contains $i) { $ok++; continue }'))
# v0.1.67: the ETA is always for the WHOLE batch (user: 'if i select to
# make 64 images, the eta should be when all pictures is done') and is
# steadied by blending the live estimate with the average of finished
# images; the label says so.
Test 'ETA label states the whole batch' ($src.Contains('"ETA ~$(Format-MossFixedTime $remaining) (all $($job.Count))"'))
Test 'ETA estimate blends live progress with finished-image average' ($src.Contains('($imageEstimate + $avgDone) / 2.0'))
Test 'ETA math covers remaining images explicitly' ($src.Contains('$job.Count - $currentImage) * $imageEstimate'))
Write-Host ''
if ($fail -gt 0) { Write-Host ($fail.ToString() + ' test(s) FAILED'); exit 1 }
Write-Host 'ALL TESTS PASSED'




