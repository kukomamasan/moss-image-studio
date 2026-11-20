# MOSS Image Studio - portable hardware setup foundation
# Windows PowerShell 5.1 | All paths are resolved relative to this script.
[CmdletBinding()]
param([switch]$SetupOnly,[switch]$ReturnToGenerator)

$ErrorActionPreference = 'Stop'
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# The launcher console is hidden at the end of the definitions (just before
# any UI appears), so the password prompt and every window run without a
# visible console. Startup problems still surface: a top-level try/catch
# shows a message box and writes a log file.
$script:AppVersion = '0.1.41'
$script:ConfigDir = Join-Path $script:AppRoot 'config'
$script:ConfigFile = Join-Path $script:ConfigDir 'settings.json'
$script:Settings = [ordered]@{ Backend = 'Auto'; BackendSelectionSaved = $false; EnginePath = (Join-Path $script:AppRoot 'bin\sd-cli.exe'); HardwareSetupComplete = $false; ImageStyle = 'Photorealistic'; PreferredGpuIndex = -1; PreferredGpuName = ''; ShowEngineCommandLine = '1' }
$script:HistoryPassphrase = $null
$script:HistoryLocked = $false
$script:LockedHistoryEnvelope = $null
$script:HistoryStoredEnvelope = $null
$script:HistoryPasswordVerifier = $null
$script:HistoryEnabled = $true
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Hide-MossConsoleWindow {
    if(-not ('MossNativeWindow' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MossNativeWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
    }
    $consoleHandle=[MossNativeWindow]::GetConsoleWindow()
    if($consoleHandle -ne [IntPtr]::Zero){[void][MossNativeWindow]::ShowWindow($consoleHandle,0)}
}

function Get-MossHistoryPassphrase([bool]$Create,[string]$Purpose='history',[System.Windows.Forms.Form]$Owner=$null) {
    # A call site that passes $null (older code did) would render the sentence
    # with a missing word ('Enter the  code.') - fall back to 'history'.
    if([string]::IsNullOrWhiteSpace($Purpose)){ $Purpose='history' }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Create) { "Set $Purpose code" } else { "Enter $Purpose code" }
    $dialog.Size = New-Object System.Drawing.Size(440,220); $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false; $dialog.Topmost=$true
    $label = New-Object System.Windows.Forms.Label; $label.Text = if ($Create) { "Choose a 4 to 16 character $Purpose code. Letters, numbers and symbols are allowed." } else { "Enter the $Purpose code." }; $label.Location=New-Object System.Drawing.Point(16,14); $label.Size=New-Object System.Drawing.Size(395,38); $dialog.Controls.Add($label)
    $first = New-Object System.Windows.Forms.TextBox; $first.Location=New-Object System.Drawing.Point(18,62); $first.Size=New-Object System.Drawing.Size(385,25); $first.UseSystemPasswordChar=$true; $dialog.Controls.Add($first)
    $confirm = $null
    if ($Create) { $confirmLabel=New-Object System.Windows.Forms.Label; $confirmLabel.Text='Confirm password'; $confirmLabel.Location=New-Object System.Drawing.Point(18,91); $confirmLabel.Size=New-Object System.Drawing.Size(150,18); $dialog.Controls.Add($confirmLabel); $confirm = New-Object System.Windows.Forms.TextBox; $confirm.Location=New-Object System.Drawing.Point(18,111); $confirm.Size=New-Object System.Drawing.Size(385,25); $confirm.UseSystemPasswordChar=$true; $dialog.Controls.Add($confirm) }
    $ok=New-Object System.Windows.Forms.Button; $ok.Text='Continue'; $ok.Location=New-Object System.Drawing.Point(218,145); $ok.DialogResult=[System.Windows.Forms.DialogResult]::OK; $dialog.Controls.Add($ok)
    $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Cancel'; $cancel.Location=New-Object System.Drawing.Point(308,145); $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $dialog.Controls.Add($cancel); $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    # The code field must be ready for typing the moment the dialog appears.
    # Windows can take the foreground back right after the dialog's own Shown
    # event (startup without an owner window, or the parent activating), so a
    # retry timer keeps pulling the dialog to the foreground and focusing the
    # code field until it REALLY has focus (max ~2 s). The counter lives in
    # $dialog.Tag because scriptblock writes do not persist in function scope.
    $dialog.Add_Shown({ try { $dialog.Activate() } catch {}; [void]$first.Focus(); $first.Select() }.GetNewClosure())
    $focusTimer = New-Object System.Windows.Forms.Timer
    $focusTimer.Interval = 60
    $dialog.Tag=0
    $focusTimer.Add_Tick({
        $n=0
        if($dialog.Tag){ $n=[int]$dialog.Tag }
        $n++
        $dialog.Tag=$n
        if($first.Focused -or $n -gt 30){ $focusTimer.Stop(); return }
        try { [void][MossNativeWindow]::SetForegroundWindow($dialog.Handle) } catch {}
        try { $dialog.Activate() } catch {}
        [void]$first.Focus(); $first.Select()
    }.GetNewClosure())
    $focusTimer.Start()
    try {
        while ($dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            $maxLength = if ($Create) { 16 } else { 64 }
            if ($first.Text.Length -lt 4 -or $first.Text.Length -gt $maxLength) {
                $limit = if ($Create) { '4 to 16' } else { '4 to 64 (older codes may be longer)' }
                [System.Windows.Forms.MessageBox]::Show("Use $limit characters.",'Password length') | Out-Null
                continue
            }
            if ($Create -and $first.Text -cne $confirm.Text) { [System.Windows.Forms.MessageBox]::Show('The passwords do not match.','Check password') | Out-Null; continue }
            return [string]$first.Text
        }
        return $null
    } finally { $dialog.Dispose() }
}

function Show-MossHistoryRecoveryChoice {
    $f=New-Object System.Windows.Forms.Form; $f.Text='Prompt history options'; $f.Size=New-Object System.Drawing.Size(520,270); $f.StartPosition='CenterScreen'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.Topmost=$true
    $label=New-Object System.Windows.Forms.Label; $label.Text='The code was not accepted. Choose how MOSS should continue.'; $label.Location=New-Object System.Drawing.Point(18,16); $label.Size=New-Object System.Drawing.Size(475,32); $f.Controls.Add($label)
    $items=@(@('Try again','retry'),@('Continue without history','skip'),@('Set a new code','reset'),@('Turn off prompt history','disable'))
    $positions=@(@(18,70),@(258,70),@(18,125),@(258,125))
    for($i=0;$i -lt $items.Count;$i++) { $b=New-Object System.Windows.Forms.Button; $b.Text=$items[$i][0]; $b.Location=New-Object System.Drawing.Point($positions[$i][0],$positions[$i][1]); $b.Size=New-Object System.Drawing.Size(220,38); $choiceTag=[string]$items[$i][1]; $b.Add_Click({$f.Tag=$choiceTag;$f.Close()}.GetNewClosure()); $f.Controls.Add($b) }
    try { [void]$f.ShowDialog(); if($f.Tag){return [string]$f.Tag}; return 'skip' } finally { $f.Dispose() }
}

function Show-MossHistorySetupChoice {
    $f=New-Object System.Windows.Forms.Form; $f.Text='Prompt history'; $f.Size=New-Object System.Drawing.Size(500,205); $f.StartPosition='CenterScreen'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.Topmost=$true
    $label=New-Object System.Windows.Forms.Label; $label.Text='Choose whether MOSS should save prompt history.'; $label.Location=New-Object System.Drawing.Point(18,18); $label.Size=New-Object System.Drawing.Size(455,30); $f.Controls.Add($label)
    $items=@(@('Create a history code','create'),@('Continue without history','skip'),@('Turn off prompt history','disable'))
    $positions=@(@(18,72),@(175,72),@(332,72))
    for($i=0;$i -lt $items.Count;$i++) { $b=New-Object System.Windows.Forms.Button; $b.Text=$items[$i][0]; $b.Location=New-Object System.Drawing.Point($positions[$i][0],$positions[$i][1]); $b.Size=New-Object System.Drawing.Size(145,45); $choiceTag=[string]$items[$i][1]; $b.Add_Click({$f.Tag=$choiceTag;$f.Close()}.GetNewClosure()); $f.Controls.Add($b) }
    try { [void]$f.ShowDialog(); if($f.Tag){return [string]$f.Tag}; return 'skip' } finally { $f.Dispose() }
}

function Protect-MossPayload([string]$Text,[string]$Password) {
    $salt=New-Object byte[] 16; $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt)
    $iv=New-Object byte[] 16; $rng.GetBytes($iv); $rng.Dispose(); $iterations=250000
    $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$salt,$iterations)
    try { $keys=$derive.GetBytes(64) } finally { $derive.Dispose() }
    $aes=[System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Mode=[System.Security.Cryptography.CipherMode]::CBC; $aes.Padding=[System.Security.Cryptography.PaddingMode]::PKCS7; $aes.Key=$keys[0..31]; $aes.IV=$iv
    try { $enc=$aes.CreateEncryptor(); try { $cipher=$enc.TransformFinalBlock([System.Text.Encoding]::UTF8.GetBytes($Text),0,[System.Text.Encoding]::UTF8.GetByteCount($Text)) } finally { $enc.Dispose() } } finally { $aes.Dispose() }
    $authData=New-Object byte[] ($salt.Length+$iv.Length+$cipher.Length); [System.Buffer]::BlockCopy($salt,0,$authData,0,$salt.Length); [System.Buffer]::BlockCopy($iv,0,$authData,$salt.Length,$iv.Length); [System.Buffer]::BlockCopy($cipher,0,$authData,$salt.Length+$iv.Length,$cipher.Length)
    $hmac=[System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys[32..63]); try { $mac=$hmac.ComputeHash($authData) } finally { $hmac.Dispose() }
    return ([ordered]@{ Version=1; Iterations=$iterations; Salt=[Convert]::ToBase64String($salt); IV=[Convert]::ToBase64String($iv); Ciphertext=[Convert]::ToBase64String($cipher); MAC=[Convert]::ToBase64String($mac) } | ConvertTo-Json -Compress)
}

function Unprotect-MossPayload([string]$EnvelopeText,[string]$Password) {
    $envelope=$EnvelopeText | ConvertFrom-Json
    if ([int]$envelope.Version -ne 1 -or [int]$envelope.Iterations -lt 100000 -or [int]$envelope.Iterations -gt 1000000) { throw 'Unsupported encrypted history format.' }
    $salt=[Convert]::FromBase64String([string]$envelope.Salt); $iv=[Convert]::FromBase64String([string]$envelope.IV); $cipher=[Convert]::FromBase64String([string]$envelope.Ciphertext); $expected=[Convert]::FromBase64String([string]$envelope.MAC)
    $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$salt,[int]$envelope.Iterations); try { $keys=$derive.GetBytes(64) } finally { $derive.Dispose() }
    $authData=New-Object byte[] ($salt.Length+$iv.Length+$cipher.Length); [System.Buffer]::BlockCopy($salt,0,$authData,0,$salt.Length); [System.Buffer]::BlockCopy($iv,0,$authData,$salt.Length,$iv.Length); [System.Buffer]::BlockCopy($cipher,0,$authData,$salt.Length+$iv.Length,$cipher.Length)
    $hmac=[System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys[32..63]); try { $actual=$hmac.ComputeHash($authData) } finally { $hmac.Dispose() }
    $diff=$actual.Length -bxor $expected.Length; for($i=0;$i -lt [Math]::Min($actual.Length,$expected.Length);$i++){ $diff=$diff -bor ($actual[$i] -bxor $expected[$i]) }; if($diff -ne 0){ throw 'Incorrect password or damaged encrypted history.' }
    $aes=[System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Mode=[System.Security.Cryptography.CipherMode]::CBC; $aes.Padding=[System.Security.Cryptography.PaddingMode]::PKCS7; $aes.Key=$keys[0..31]; $aes.IV=$iv
    try { $dec=$aes.CreateDecryptor(); try { $plain=$dec.TransformFinalBlock($cipher,0,$cipher.Length) } finally { $dec.Dispose() } } finally { $aes.Dispose() }
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Test-MossHistoryPassphrase([string]$Password,[string]$Verifier) {
    if ([string]::IsNullOrWhiteSpace($Verifier)) { return $false }
    try { return ((Unprotect-MossPayload $Verifier $Password) -ceq 'MOSS-HISTORY-PASSWORD-CHECK-V1') } catch { return $false }
}

function Reset-MossHistoryPassword([System.Windows.Forms.Form]$Owner=$null) {
    $answer=[System.Windows.Forms.MessageBox]::Show('This clears the saved prompt history and replaces its code. The old history cannot be recovered afterward. Continue?','Reset history code',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $newPassword=Get-MossHistoryPassphrase $true 'history' $Owner
    if(-not $newPassword){return $false}
    $script:HistoryPassphrase=$newPassword
    $script:HistoryPasswordVerifier=Protect-MossPayload 'MOSS-HISTORY-PASSWORD-CHECK-V1' $newPassword
    $script:HistoryLocked=$false
    $script:LockedHistoryEnvelope=$null
    $script:HistoryEnabled=$true
    $script:Settings.PromptHistory=@()
    return (Save-Settings)
}

function Disable-MossHistory {
    $answer=[System.Windows.Forms.MessageBox]::Show('This permanently deletes saved prompt history and stops MOSS from storing future prompts. Continue?','Turn off prompt history',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $script:HistoryEnabled=$false
    $script:HistoryLocked=$false
    $script:LockedHistoryEnvelope=$null
    $script:HistoryPassphrase=$null
    $script:HistoryPasswordVerifier=$null
    $script:Settings.PromptHistory=@()
    return (Save-Settings)
}

function Load-Settings([switch]$UnlockHistory) {
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($p.Name -notin @('PromptHistory','PromptHistoryProtected','HistoryPasswordVerifier','PromptHistoryEnabled','AdultAccessVerifier','AdultCodeSetup','ChildProfiles')) { $script:Settings[$p.Name] = $p.Value }
            }
            if ($saved.HistoryPasswordVerifier) { $script:HistoryPasswordVerifier=[string]$saved.HistoryPasswordVerifier }
            if ($saved.PSObject.Properties.Name -contains 'PromptHistoryEnabled') { $script:HistoryEnabled=[bool]$saved.PromptHistoryEnabled }
            $script:HistoryStoredEnvelope=[string]$saved.PromptHistoryProtected
            if ($script:HistoryEnabled -and $saved.PromptHistoryProtected) {
                $script:LockedHistoryEnvelope = [string]$saved.PromptHistoryProtected
                $script:HistoryLocked=$true
                $script:Settings.PromptHistory=@()
                if (-not $UnlockHistory) { return }
                while ($true) {
                    $candidate = Get-MossHistoryPassphrase $false
                    if ($candidate) {
                        try {
                            $plain = Unprotect-MossPayload ([string]$saved.PromptHistoryProtected) $candidate
                            $script:HistoryPassphrase=$candidate
                            $script:Settings.PromptHistory = @($plain | ConvertFrom-Json)
                            $script:HistoryLocked=$false
                            $script:LockedHistoryEnvelope = $null
                            break
                        } catch { $script:HistoryPassphrase=$null }
                    }
                    $choice=Show-MossHistoryRecoveryChoice
                    if($choice -eq 'retry'){continue}
                    if($choice -eq 'skip'){$script:HistoryLocked=$true;$script:Settings.PromptHistory=@();return}
                    if($choice -eq 'reset'){if(Reset-MossHistoryPassword){return};continue}
                    if($choice -eq 'disable'){if(Disable-MossHistory){return};continue}
                }
            } elseif ($script:HistoryEnabled -and $saved.PSObject.Properties.Name -contains 'PromptHistory' -and $UnlockHistory ) {
                # Migrate older plaintext settings in memory; the next save encrypts the history.
                $script:Settings.PromptHistory = @($saved.PromptHistory)
            }
            # Older builds could leave CPU selected as a fallback default.
            # Migrate that legacy default to Auto once; explicit new selections are preserved.
            if (($saved.PSObject.Properties.Name -notcontains 'BackendSelectionSaved' -or -not [bool]$saved.BackendSelectionSaved) -and [string]$script:Settings.Backend -eq 'CPU') {
                $script:Settings.Backend = 'Auto'
            }
        } catch { Write-Warning "Settings could not be read; defaults will be used. $($_.Exception.Message)" }
    }
}
function Save-Settings {
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
    $persist = [ordered]@{}
    foreach ($key in $script:Settings.Keys) { if ($key -ne 'PromptHistory') { $persist[$key] = $script:Settings[$key] } }
    $persist.PromptHistoryEnabled=[bool]$script:HistoryEnabled
    $history = @($script:Settings.PromptHistory)
    if (-not $script:HistoryEnabled) {
        # Disabled means no prompt history or password verifier is persisted.
    } elseif ($script:HistoryLocked) {
        if ($script:LockedHistoryEnvelope) { $persist.PromptHistoryProtected = $script:LockedHistoryEnvelope }
    } elseif ($history.Count -gt 0) {
        if (-not $script:HistoryPassphrase) {
            if ($script:HistoryPasswordVerifier) {
                $candidate=Get-MossHistoryPassphrase $false
                if ($candidate -and (Test-MossHistoryPassphrase $candidate $script:HistoryPasswordVerifier)) { $script:HistoryPassphrase=$candidate }
                else { $script:HistoryLocked=$true; $script:Settings.PromptHistory=@() }
            } else {
                $script:HistoryPassphrase = Get-MossHistoryPassphrase $true
                if (-not $script:HistoryPassphrase) { return $false }
                $script:HistoryPasswordVerifier=Protect-MossPayload 'MOSS-HISTORY-PASSWORD-CHECK-V1' $script:HistoryPassphrase
            }
        }
        if (-not $script:HistoryLocked) {
            if (-not $script:HistoryPasswordVerifier) { $script:HistoryPasswordVerifier=Protect-MossPayload 'MOSS-HISTORY-PASSWORD-CHECK-V1' $script:HistoryPassphrase }
            $historyJson = ConvertTo-Json -InputObject $history -Compress
            $persist.PromptHistoryProtected = Protect-MossPayload ([string]$historyJson) $script:HistoryPassphrase
        }
    }
    if ($script:HistoryEnabled -and $script:HistoryPasswordVerifier) { $persist.HistoryPasswordVerifier=$script:HistoryPasswordVerifier }
    $persist | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    return $true
}

function Get-GpuInventory {
    $items = @()
    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        foreach ($c in $controllers) {
            $name = [string]$c.Name
            $pnp = [string]$c.PNPDeviceID
            $desc = [string]$c.Description
            $hay = "$name $desc $pnp"
            $vendor = 'Unknown'
            if ($hay -match '(?i)VEN_10DE|NVIDIA|GeForce|Quadro|Tesla') { $vendor = 'NVIDIA' }
            elseif ($hay -match '(?i)VEN_1002|VEN_1022|AMD|Radeon') { $vendor = 'AMD' }
            elseif ($hay -match '(?i)VEN_8086|Intel') { $vendor = 'Intel' }
            $isVirtual = $false
            if ($hay -match '(?i)virtual|indirect display|remote display|parsec|spacedesk|usb display|displaylink|mirage|idd') { $isVirtual = $true }
            # Hyper-V/VMware virtual graphics are reported as virtual adapters; keep them visible.
            $kind = if ($isVirtual) { 'Virtual display adapter' } elseif ($vendor -ne 'Unknown') { 'Physical/vendor adapter (compute capability not yet verified)' } else { 'Unclassified display adapter' }
            $backend = switch ($vendor) { 'NVIDIA' { 'CUDA' } 'AMD' { 'HIP/ROCm or Vulkan' } 'Intel' { 'SYCL or Vulkan' } default { 'Manual check required' } }
            $items += [pscustomobject]@{ Name=$name; Vendor=$vendor; Type=$kind; SuggestedBackend=$backend; PNPDeviceID=$pnp; IsVirtual=$isVirtual }
        }
    } catch { Write-Warning "Windows adapter query failed: $($_.Exception.Message)" }

    # nvidia-smi is a stronger signal that an NVIDIA compute driver is available.
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $candidates = @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:WINDIR\System32\nvidia-smi.exe")
        foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { $nvidiaSmi = Get-Item -LiteralPath $candidate; break } }
    }
    $nvidiaCompute = $false
    if ($nvidiaSmi) {
        try { $smiPath = if ($nvidiaSmi.PSObject.Properties.Name -contains 'Source' -and $nvidiaSmi.Source) { $nvidiaSmi.Source } elseif ($nvidiaSmi.PSObject.Properties.Name -contains 'FullName') { $nvidiaSmi.FullName } else { $null }; if ($smiPath) { & $smiPath -L 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $nvidiaCompute = $true } } } catch {}
    }
    foreach ($item in $items) {
        if ($item.Vendor -eq 'NVIDIA' -and -not $item.IsVirtual) {
            if ($nvidiaCompute) { $item.Type = 'NVIDIA adapter (nvidia-smi compute driver detected)'; $item.SuggestedBackend = 'CUDA (verify engine build)' }
            else { $item.Type = 'NVIDIA display adapter (compute driver not verified)'; $item.SuggestedBackend = 'CUDA only if driver/engine support it' }
        }
    }
    # Return each adapter object through the pipeline. The unary comma here would
    # wrap the whole collection in one nested array and display System.Object[].
    return $items
}

function Get-BackendRecommendation([object[]]$inventory) {
    $physical = @($inventory | Where-Object { -not $_.IsVirtual })
    $n = @($physical | Where-Object Vendor -eq 'NVIDIA').Count
    $a = @($physical | Where-Object Vendor -eq 'AMD').Count
    $i = @($physical | Where-Object Vendor -eq 'Intel').Count
    if ($n -gt 0) { return 'CUDA' }
    if ($a -gt 0) { return 'Vulkan' }
    if ($i -gt 0) { return 'Vulkan' }
    return 'CPU'
}

Load-Settings
$script:Inventory = @(Get-GpuInventory)
$script:RecommendedBackend = Get-BackendRecommendation $script:Inventory

$form = New-Object System.Windows.Forms.Form
$form.Text = "MOSS Image Studio v$($script:AppVersion) | Hardware Setup"
$form.Size = New-Object System.Drawing.Size(900,700)
$form.MinimumSize = New-Object System.Drawing.Size(780,660)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(18,22,31)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230,236,245)
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)

$header = New-Object System.Windows.Forms.Panel
$header.Dock='Top'; $header.Height=76; $header.BackColor=[System.Drawing.Color]::FromArgb(25,32,45)
$form.Controls.Add($header)
$title = New-Object System.Windows.Forms.Label
$title.Text="MOSS  /  IMAGE STUDIO  v$($script:AppVersion)"; $title.Font=New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold)
$title.AutoSize=$true; $title.Location=New-Object System.Drawing.Point(22,12); $header.Controls.Add($title)
$sub = New-Object System.Windows.Forms.Label
$sub.Text='PORTABLE HARDWARE CONFIGURATION'; $sub.ForeColor=[System.Drawing.Color]::FromArgb(142,158,181)
$sub.AutoSize=$true; $sub.Location=New-Object System.Drawing.Point(25,47); $header.Controls.Add($sub)

$intro = New-Object System.Windows.Forms.Label
$intro.Text='Detected adapters are listed below. Virtual display adapters remain visible, but are not treated as compute GPUs.'
$intro.Location=New-Object System.Drawing.Point(24,94); $intro.Size=New-Object System.Drawing.Size(830,38); $intro.ForeColor=[System.Drawing.Color]::FromArgb(190,202,219)
$form.Controls.Add($intro)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location=New-Object System.Drawing.Point(24,137); $grid.Size=New-Object System.Drawing.Size(836,260)
$grid.Anchor='Top,Left,Right'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
$grid.AutoSizeColumnsMode='Fill'; $grid.RowHeadersVisible=$false; $grid.BackgroundColor=[System.Drawing.Color]::FromArgb(24,30,42)
$grid.BorderStyle='None'; $grid.EnableHeadersVisualStyles=$false; $grid.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(38,48,65)
$grid.ColumnHeadersDefaultCellStyle.ForeColor=[System.Drawing.Color]::White; $grid.DefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(24,30,42)
$grid.DefaultCellStyle.ForeColor=[System.Drawing.Color]::FromArgb(225,232,242); $grid.DefaultCellStyle.SelectionBackColor=[System.Drawing.Color]::FromArgb(48,75,108)
$grid.DefaultCellStyle.SelectionForeColor=[System.Drawing.Color]::White
[void]$grid.Columns.Add('Name','Adapter'); [void]$grid.Columns.Add('Vendor','Vendor'); [void]$grid.Columns.Add('Type','Classification'); [void]$grid.Columns.Add('SuggestedBackend','Backend hint')
foreach ($g in $script:Inventory) { [void]$grid.Rows.Add($g.Name,$g.Vendor,$g.Type,$g.SuggestedBackend) }
if ($script:Inventory.Count -eq 0) { [void]$grid.Rows.Add('No display adapters returned by Windows','Unknown','Not detected','CPU / manual check') }
$form.Controls.Add($grid)

$recommend = New-Object System.Windows.Forms.Label
$recommend.Location=New-Object System.Drawing.Point(24,410); $recommend.Size=New-Object System.Drawing.Size(830,28)
$recommend.Font=New-Object System.Drawing.Font('Segoe UI Semibold',10,[System.Drawing.FontStyle]::Bold)
$recommend.Text="Recommended starting backend: $($script:RecommendedBackend)  (based on non-virtual adapter vendor only)"
$form.Controls.Add($recommend)

$backendLabel=New-Object System.Windows.Forms.Label; $backendLabel.Text='Select backend (you can override the recommendation):'; $backendLabel.Location=New-Object System.Drawing.Point(24,452); $backendLabel.AutoSize=$true; $form.Controls.Add($backendLabel)
$backend=New-Object System.Windows.Forms.ComboBox
$backend.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList
$backend.Location=New-Object System.Drawing.Point(365,448)
$backend.Size=New-Object System.Drawing.Size(285,30)
$backend.DropDownWidth=285
$backend.IntegralHeight=$true
# Add entries individually: this avoids AddRange overload/coercion issues in some PS 5.1 hosts.
$backendChoices = @('Auto (recommended)','CUDA (NVIDIA)','Vulkan','HIP/ROCm (AMD)','SYCL (Intel)','CPU only','Manual / virtual GPU')
foreach ($choice in $backendChoices) { [void]$backend.Items.Add([string]$choice) }
$existing = [string]$script:Settings.Backend
$selected = switch -Regex ($existing) { '^CUDA' {'CUDA (NVIDIA)';break} '^Vulkan$' {'Vulkan';break} '^HIP' {'HIP/ROCm (AMD)';break} '^SYCL' {'SYCL (Intel)';break} '^CPU' {'CPU only';break} '^Manual' {'Manual / virtual GPU';break} default {'Auto (recommended)'} }
$backend.SelectedIndex = [Math]::Max(0, $backend.Items.IndexOf($selected))
# Add the selector to the form (previous build populated it but never displayed it).
$form.Controls.Add($backend)

# Multi-GPU support: let the user pick a physical card. Virtual display adapters
# are never offered as generation hardware.
$gpuLabel=New-Object System.Windows.Forms.Label; $gpuLabel.Text='Select GPU (for multi-GPU computers):'; $gpuLabel.Location=New-Object System.Drawing.Point(24,496); $gpuLabel.AutoSize=$true; $form.Controls.Add($gpuLabel)
$gpu=New-Object System.Windows.Forms.ComboBox
$gpu.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList
$gpu.Location=New-Object System.Drawing.Point(365,492)
$gpu.Size=New-Object System.Drawing.Size(285,30)
$gpu.DropDownWidth=320
$gpu.IntegralHeight=$true
[void]$gpu.Items.Add('All compatible GPUs (automatic)')
$physGpuCount=0
foreach($g in $script:Inventory){ if(-not $g.IsVirtual){ [void]$gpu.Items.Add(('{0}: {1}' -f $physGpuCount,$g.Name)); $physGpuCount++ } }
$savedGpu=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $savedGpu=[int]$script:Settings.PreferredGpuIndex } catch { $savedGpu=-1 } }
$gpuSelectedIndex=0
for($gi=0;$gi -lt $gpu.Items.Count;$gi++){ if($savedGpu -ge 0 -and ([string]$gpu.Items[$gi]) -match ('^'+$savedGpu+'\s*:')){ $gpuSelectedIndex=$gi;break} }
$gpu.SelectedIndex=$gpuSelectedIndex
$form.Controls.Add($gpu)

$engineLabel=New-Object System.Windows.Forms.Label; $engineLabel.Text='Engine executable:'; $engineLabel.Location=New-Object System.Drawing.Point(24,536); $engineLabel.AutoSize=$true; $form.Controls.Add($engineLabel)
$engine=New-Object System.Windows.Forms.TextBox; $engine.Location=New-Object System.Drawing.Point(145,532); $engine.Size=New-Object System.Drawing.Size(590,26); $engine.Anchor='Top,Left,Right'; $engine.Text=[string]$script:Settings.EnginePath; $form.Controls.Add($engine)
$browse=New-Object System.Windows.Forms.Button; $browse.Text='Browse...'; $browse.Location=New-Object System.Drawing.Point(746,530); $browse.Size=New-Object System.Drawing.Size(114,30); $browse.Anchor='Top,Right'; $form.Controls.Add($browse)
$browse.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'MOSS engine (sd-cli.exe)|sd-cli.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*'
    $d.Title = 'Select the MOSS engine executable'
    $d.CheckFileExists = $true
    $d.CheckPathExists = $true
    $d.RestoreDirectory = $true

    # Start browsing beside the currently suggested/selected engine path.
    # If that folder is unavailable, fall back to this portable install's bin folder.
    $suggestedPath = [Environment]::ExpandEnvironmentVariables(([string]$engine.Text).Trim().Trim('"'))
    $startFolder = $null
    $suggestedName = 'sd-cli.exe'
    if ($suggestedPath) {
        if (Test-Path -LiteralPath $suggestedPath -PathType Container) {
            $startFolder = (Resolve-Path -LiteralPath $suggestedPath).Path
        } else {
            $suggestedParent = Split-Path -Parent $suggestedPath
            if ($suggestedParent -and (Test-Path -LiteralPath $suggestedParent -PathType Container)) {
                $startFolder = (Resolve-Path -LiteralPath $suggestedParent).Path
            }
            $leaf = Split-Path -Leaf $suggestedPath
            if ($leaf) { $suggestedName = $leaf }
        }
    }
    if (-not $startFolder) {
        $binFolder = Join-Path $script:AppRoot 'bin'
        if (Test-Path -LiteralPath $binFolder -PathType Container) {
            $startFolder = (Resolve-Path -LiteralPath $binFolder).Path
        } else {
            $startFolder = $script:AppRoot
        }
    }
    $d.InitialDirectory = $startFolder
    $d.FileName = $suggestedName

    if ($d.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $engine.Text = $d.FileName
    }
    $d.Dispose()
})

$note=New-Object System.Windows.Forms.Label; $note.Location=New-Object System.Drawing.Point(24,572); $note.Size=New-Object System.Drawing.Size(830,30); $note.ForeColor=[System.Drawing.Color]::FromArgb(150,166,190)
$note.Text='Note: display enumeration cannot prove CUDA / ROCm / SYCL support. The selected sd-cli.exe must be compiled for the chosen backend.'; $form.Controls.Add($note)

$refresh=New-Object System.Windows.Forms.Button; $refresh.Text='Rescan hardware'; $refresh.Location=New-Object System.Drawing.Point(24,612); $refresh.Size=New-Object System.Drawing.Size(130,32); $refresh.Anchor='Bottom,Left'; $form.Controls.Add($refresh)
$setupHistoryCode=New-Object System.Windows.Forms.Button; $setupHistoryCode.Text='Set / reset history code'; $setupHistoryCode.Location=New-Object System.Drawing.Point(350,612); $setupHistoryCode.Size=New-Object System.Drawing.Size(190,32); $setupHistoryCode.Anchor='Bottom,Left'; $form.Controls.Add($setupHistoryCode)
$setupHistoryCode.Add_Click({ if(Reset-MossHistoryPassword $form){[System.Windows.Forms.MessageBox]::Show('New history code saved. No prompt history is stored yet.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
$test=New-Object System.Windows.Forms.Button; $test.Text='Check backend support'; $test.Location=New-Object System.Drawing.Point(166,612); $test.Size=New-Object System.Drawing.Size(170,32); $test.Anchor='Bottom,Left'; $form.Controls.Add($test)
$save=New-Object System.Windows.Forms.Button; $save.Text='Save setup'; $save.Location=New-Object System.Drawing.Point(720,612); $save.Size=New-Object System.Drawing.Size(140,32); $save.Anchor='Bottom,Right'; $save.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $save.ForeColor=[System.Drawing.Color]::White; $save.FlatStyle='Flat'; $form.Controls.Add($save)
$refresh.Add_Click({ [System.Windows.Forms.MessageBox]::Show('Close and reopen MOSS Image Studio to perform a fresh hardware scan.','Hardware scan',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null; $form.Close() })
$test.Add_Click({
    $choice = [string]$backend.SelectedItem
    # Resolve the automatic choice immediately to the backend detected from hardware.
    if ($choice -eq 'Auto (recommended)') {
        $choice = switch ([string]$script:RecommendedBackend) {
            'CUDA' { 'CUDA (NVIDIA)' }
            'Vulkan' { 'Vulkan' }
            'CPU' { 'CPU only' }
            default { 'CPU only' }
        }
    }
    $enginePath = $engine.Text.Trim()
    $storedBackend = [string]$script:Settings.Backend
    $mappedChoice = switch ($choice) { 'CUDA (NVIDIA)' {'CUDA'} 'HIP/ROCm (AMD)' {'HIP/ROCm'} 'SYCL (Intel)' {'SYCL'} 'CPU only' {'CPU'} 'Manual / virtual GPU' {'Manual'} default {$choice} }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Selected backend: $mappedChoice")
    if ($mappedChoice -ne $storedBackend) { $lines.Add('Setting status: NOT SAVED YET - click Save setup to store this selection.') }
    else { $lines.Add('Setting status: SAVED selection matches.') }
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        $lines.Add('')
        $lines.Add('RESULT: FAILED - engine executable was not found.')
        $lines.Add("Path checked: $enginePath")
        $lines.Add('Use Browse to select the correct sd-cli.exe, then run this check again.')
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"),'Backend check - FAILED',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $lines.Add("Engine file: $enginePath")
    $lines.Add('')
    $lines.Add('CHECK TYPE: Command-line startup only. This does NOT run a GPU test or generate an image.')
    $lines.Add('Running sd-cli.exe --help...')
    $status = 'INCONCLUSIVE'
    $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $enginePath
        $psi.Arguments = '--help'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(15000)) {
            try { $proc.Kill() } catch {}
            $lines.Add('RESULT: INCONCLUSIVE - the engine did not finish its help command within 15 seconds.')
            $lines.Add('This does not tell us whether the selected backend is supported.')
        } else {
            $output = [string]$stdoutTask.Result + "`n" + [string]$stderrTask.Result
            $lines.Add("Help command exit code: $($proc.ExitCode)")
            $pattern = switch ($mappedChoice) {
                'CUDA' { '(?i)CUDA|GGML_CUDA|ggml_cuda' }
                'Vulkan' { '(?i)Vulkan|GGML_VULKAN|ggml_vulkan' }
                'HIP/ROCm' { '(?i)HIP|ROCm|GGML_HIP|ggml_hip' }
                'SYCL' { '(?i)SYCL|GGML_SYCL|ggml_sycl' }
                'CPU' { '(?i)CPU|GGML_CPU|ggml_cpu' }
                default { $null }
            }
            if ($mappedChoice -eq 'Manual') {
                $lines.Add('RESULT: ENGINE STARTED, BACKEND NOT VERIFIED.')
                $lines.Add('Manual mode needs a real generation test.')
            } elseif ($pattern -and $output -match $pattern) {
                $status = 'MENTIONED'
                $lines.Add("RESULT: $mappedChoice IS MENTIONED IN THE ENGINE HELP TEXT.")
                $lines.Add('Meaning: there is a positive clue that this build may include the backend.')
                $lines.Add('It is NOT confirmation that the backend initializes or that your GPU can render with it.')
            } else {
                $lines.Add("RESULT: NO $($mappedChoice.ToUpperInvariant()) SUPPORT CLUE FOUND.")
                $lines.Add('Meaning: this check could not verify support. It is NOT proof that the backend is unsupported; some builds do not list compiled backends in --help.')
            }
            if ($proc.ExitCode -ne 0) {
                $lines.Add("Additional warning: --help returned exit code $($proc.ExitCode). Review the engine build if it did not print normal help text.")
                if ($status -eq 'INCONCLUSIVE') { $lines.Add('RESULT: ENGINE HELP COMMAND RETURNED AN ERROR - BACKEND SUPPORT UNKNOWN.') }
            }
        }
        $proc.Dispose()
    } catch {
        $lines.Add("RESULT: FAILED TO START ENGINE - $($_.Exception.Message)")
        $lines.Add('Backend support is unknown.')
    }
    $lines.Add('')
    $lines.Add('WHAT WOULD CONFIRM IT? A small real image-generation test using this backend, then checking that the engine reports the backend initialized and (for GPU backends) that the GPU is doing the work.')
    $lines.Add('This button only checks --help. It does not change the executable, install drivers, or prove GPU inference.')
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"),'Backend check results',$([System.Windows.Forms.MessageBoxButtons]::OK),$icon) | Out-Null
})
$save.Add_Click({
    $choice=[string]$backend.SelectedItem
    # When the user chooses automatic detection, commit the detected backend itself.
    # From this point onward the interface and saved configuration show only that backend.
    if ($choice -eq 'Auto (recommended)') {
        $choice = switch ([string]$script:RecommendedBackend) {
            'CUDA' { 'CUDA (NVIDIA)' }
            'Vulkan' { 'Vulkan' }
            'CPU' { 'CPU only' }
            default { 'CPU only' }
        }
        $backend.SelectedItem = $choice
    }
    $script:Settings.Backend = switch ($choice) { 'CUDA (NVIDIA)' {'CUDA'} 'HIP/ROCm (AMD)' {'HIP/ROCm'} 'SYCL (Intel)' {'SYCL'} 'CPU only' {'CPU'} 'Manual / virtual GPU' {'Manual'} default {$choice} }
    $script:Settings.BackendSelectionSaved=$true
    # Remember which physical GPU the user picked so generation can target it.
    $gpuChoice=[string]$gpu.SelectedItem
    $gpuIdx=-1; if($gpuChoice -match '^(\d+)\s*:'){ $gpuIdx=[int]$Matches[1] }
    $script:Settings.PreferredGpuIndex=$gpuIdx
    $script:Settings.PreferredGpuName= if($gpuIdx -ge 0){ ([string]$gpuChoice) -replace '^\d+\s*:\s*','' } else { '' }
    $script:Settings.EnginePath=$engine.Text.Trim()
    $script:Settings.HardwareSetupComplete=$true
    Save-Settings
    $savedBackend = [string]$script:Settings.Backend
    $gpuSavedText = if([int]$script:Settings.PreferredGpuIndex -ge 0){ "  |  GPU: $($script:Settings.PreferredGpuName)" } else { '  |  GPU: automatic' }
    $backendDisplay = "Backend: $savedBackend$gpuSavedText"
    $msg="Settings saved to:`r`n$script:ConfigFile`r`n`r`n$backendDisplay`r`nEngine: $($script:Settings.EnginePath)"
    if (-not (Test-Path -LiteralPath $script:Settings.EnginePath)) { $msg += "`r`n`r`nWARNING: Engine executable not found at this path. You can browse to it later." }
    [System.Windows.Forms.MessageBox]::Show($msg,'MOSS setup saved',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $form.Close()
})

$form.Add_Shown({ if (-not $script:Settings.HardwareSetupComplete) { [System.Windows.Forms.MessageBox]::Show('Welcome to MOSS Image Studio. Review the detected adapters and choose the backend that matches your engine build.','First-run setup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null } })

# ---------------- IMAGE GENERATOR ----------------
function Write-MossErrorLog([string]$Title,[string]$Body) {
    # Always keep a local copy, even if later uploading fails or the PC is offline.
    try {
        $logDir = Join-Path $script:AppRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $file = Join-Path $logDir ('error-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
        ("$Title`r`n$Body") | Set-Content -LiteralPath $file -Encoding UTF8
        return $file
    } catch { return $null }
}

function Get-AbsoluteAppPath([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    if ([System.IO.Path]::IsPathRooted($value)) { return [System.IO.Path]::GetFullPath($value) }
    return [System.IO.Path]::GetFullPath((Join-Path $script:AppRoot $value))
}
function Get-RelativeAppPath([string]$value) {
    try {
        $root = [System.IO.Path]::GetFullPath($script:AppRoot).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath($value)
        if ($full.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($root.Length) }
        return $full
    } catch { return $value }
}
function ConvertTo-MossDouble([string]$text,[ref]$out) {
    # Locale-safe decimal parsing: accept both '0.6' and '0,6' regardless of
    # the Windows regional format (e.g. Danish uses comma and would otherwise
    # read '0.6' as the integer 6 because the dot is the thousands separator).
    $norm = ([string]$text).Trim().Replace(',','.')
    return [double]::TryParse($norm,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,$out)
}

function ConvertFrom-MossDouble([double]$value) {
    # Locale-safe decimal formatting for engine arguments and stored settings:
    # always '0.6' style, never the regional '0,6' that the engine cannot read.
    return $value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Quote-ProcessArgument([string]$value) {
    if ($null -eq $value) { return '""' }
    return '"' + ($value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}
function Get-MossEngineCommit([string]$enginePath) {
    # Reads the installed engine version: sd-cli.exe prints e.g.
    # 'stable-diffusion.cpp version unknown, commit c6dfa9d'. Returns the
    # commit hash in lower case, or '' when it cannot be determined.
    if ([string]::IsNullOrWhiteSpace($enginePath) -or -not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { return '' }
    try {
        $out = & $enginePath --version 2>&1 | Out-String
        if ($out -match 'commit\s+([0-9a-fA-F]{6,40})') { return $Matches[1].ToLowerInvariant() }
    } catch {}
    return ''
}
function Get-MossEngineVersionOutput([string]$enginePath) {
    # Runs the engine once and returns its version output. Empty result means
    # the executable did not produce any output (missing DLLs, broken exe,
    # antivirus blocking) - used to verify the engine actually starts after
    # an update and again after a failure-restore.
    if ([string]::IsNullOrWhiteSpace($enginePath) -or -not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { return '' }
    try {
        $out = & $enginePath --version 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($out)) { return '' }
        return $out.Trim()
    } catch { return '' }
}
function Test-MossZipDigest([string]$zipPath,$asset) {
    # GitHub publishes a sha256 digest for release assets when available; a
    # mismatch means the download is corrupt and must not be installed.
    $digest=[string]$asset.digest
    if([string]::IsNullOrWhiteSpace($digest)){ return }
    if($digest -match '^sha256:([0-9a-fA-F]{64})$'){
        $expected=$Matches[1].ToLowerInvariant()
        $hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -ne $expected){ throw ('The downloaded file is corrupt (sha256 mismatch: expected '+$expected+', got '+$hash+').') }
    }
}
function Show-MossEngineBackupRestore([System.Windows.Forms.Form]$Owner,[string]$enginePath,[string]$engineBin,[System.Collections.ArrayList]$log,[string]$stamp) {
    # Manual rollback: lists the automatic engine-backup-<time> folders the
    # updater created next to the engine folder and copies a chosen one back.
    # Backups contain only the engine files (exe + DLLs) - the large model
    # files in the models folder are never backed up or modified by an engine
    # update, so they need no backup and are never touched by a rollback.
    $backupParent=[System.IO.Path]::GetDirectoryName($engineBin)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Backups are compressed zip archives (engine-backup-<time>.zip); older
    # uncompressed engine-backup-<time> folders from previous versions are
    # still listed and restorable.
    $backups=@()
    try {
        $backups+=@(Get-ChildItem -LiteralPath $backupParent -File -Filter 'engine-backup-*.zip' -ErrorAction SilentlyContinue | ForEach-Object {
            $cnt=0; $bytes=0
            try { $ar=[System.IO.Compression.ZipFile]::OpenRead($_.FullName); try { $cnt=@($ar.Entries).Count; foreach($e2 in $ar.Entries){ $bytes+=$e2.Length } } finally { $ar.Dispose() } } catch {}
            @{ Path=$_.FullName; Kind='zip'; Name=$_.Name; Count=$cnt; Bytes=$bytes }
        })
        $backups+=@(Get-ChildItem -LiteralPath $backupParent -Directory -Filter 'engine-backup-*' -ErrorAction SilentlyContinue | ForEach-Object {
            $bf=@(Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue); $sz=0; foreach($f in $bf){ $sz+=$f.Length }
            @{ Path=$_.FullName; Kind='folder'; Name=$_.Name; Count=$bf.Count; Bytes=$sz }
        })
    } catch {}
    $backups=@($backups | Sort-Object -Property Name -Descending)
    if($backups.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show($Owner,("No engine backups were found next to:`r`n{0}`r`n`r`nA compressed backup archive is created automatically every time the engine is updated. Backups only contain the engine files - the large model files are never modified by an engine update, so they need no backup." -f $backupParent),'Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        return
    }
    $d=New-Object System.Windows.Forms.Form
    $d.Text='Restore engine backup (roll back)'
    $d.Size=New-Object System.Drawing.Size(640,400); $d.StartPosition='CenterParent'; $d.FormBorderStyle='FixedDialog'; $d.MaximizeBox=$false
    $d.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $d.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $d.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185)
    $info=New-Object System.Windows.Forms.Label; $info.Text='Automatic backups made before each engine update. Restoring copies the backup files back over the current ones; the engine must not be running.'; $info.Location=New-Object System.Drawing.Point(12,12); $info.Size=New-Object System.Drawing.Size(600,34); $info.ForeColor=$cMuted; $d.Controls.Add($info)
    $lb=New-Object System.Windows.Forms.ListBox; $lb.Location=New-Object System.Drawing.Point(12,52); $lb.Size=New-Object System.Drawing.Size(600,180); $lb.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $lb.ForeColor=$cText; $lb.BorderStyle='FixedSingle'; $d.Controls.Add($lb)
    foreach($b in $backups){
        [void]$lb.Items.Add(($b.Name+'   ('+$b.Count+' files, '+[math]::Round($b.Bytes/1MB)+' MB'+$(if($b.Kind -eq 'zip'){', compressed'}else{''})+')'))
    }
    if($lb.Items.Count -gt 0){ $lb.SelectedIndex=0 }
    $status=New-Object System.Windows.Forms.Label; $status.Location=New-Object System.Drawing.Point(12,244); $status.Size=New-Object System.Drawing.Size(600,44); $status.ForeColor=$cMuted; $d.Controls.Add($status)
    $restoreBtn=New-Object System.Windows.Forms.Button; $restoreBtn.Text='Restore this backup...'; $restoreBtn.Location=New-Object System.Drawing.Point(12,296); $restoreBtn.Size=New-Object System.Drawing.Size(170,32); $restoreBtn.FlatStyle='Flat'; $restoreBtn.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $restoreBtn.ForeColor=[System.Drawing.Color]::White; $d.Controls.Add($restoreBtn)
    $cancelBtn=New-Object System.Windows.Forms.Button; $cancelBtn.Text='Cancel'; $cancelBtn.Location=New-Object System.Drawing.Point(510,296); $cancelBtn.Size=New-Object System.Drawing.Size(90,32); $cancelBtn.FlatStyle='Flat'; $cancelBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $cancelBtn.ForeColor=$cText; $d.Controls.Add($cancelBtn)
    $cancelBtn.Add_Click({$d.Close()})
    $restoreBtn.Add_Click({
        if($lb.SelectedIndex -lt 0){ [System.Windows.Forms.MessageBox]::Show($d,'Select a backup first.','Restore engine backup')|Out-Null; return }
        $b=$backups[$lb.SelectedIndex]
        $bf=@()
        if($b.Kind -eq 'zip'){
            try { $ar=[System.IO.Compression.ZipFile]::OpenRead($b.Path); try { $bf=@($ar.Entries | ForEach-Object { @{ Name=[System.IO.Path]::GetFileName($_.FullName); Length=$_.Length } }) } finally { $ar.Dispose() } } catch { $bf=@() }
        } else {
            $bf=@(Get-ChildItem -LiteralPath $b.Path -File -ErrorAction SilentlyContinue | ForEach-Object { @{ Name=$_.Name; Length=$_.Length; FullName=$_.FullName } })
        }
        if($bf.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show($d,'That backup is empty or unreadable.','Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return }
        $busy=@(Get-Process -Name 'sd-cli','sd-server' -ErrorAction SilentlyContinue)
        if($busy.Count -gt 0){ [System.Windows.Forms.MessageBox]::Show($d,'sd-cli or sd-server is currently running. Wait for it to finish and try again.','Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return }
        $sz=0; foreach($f in $bf){ $sz+=$f.Length }
        $answer=[System.Windows.Forms.MessageBox]::Show($d,("Roll back the engine to this backup?`r`n`r`nBackup: {0}`r`nFiles copied into: {1}`r`nContents: {2} files ({3} MB)`r`n`r`nThe current engine files are overwritten by the backup contents. Models, prompts, outputs and settings are never touched.`r`n`r`nRestore now?" -f $b.Name,$engineBin,$bf.Count,[math]::Round($sz/1MB)),'Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){ return }
        $restoreStage=''
        try {
            $d.Cursor='WaitCursor'; $restoreBtn.Enabled=$false; $cancelBtn.Enabled=$false
            $status.Text='Restoring the backup files...'
            [System.Windows.Forms.Application]::DoEvents()
            if($b.Kind -eq 'zip'){
                $restoreStage=Join-Path ([System.IO.Path]::GetTempPath()) ('MOSS-Backup-Restore-'+[guid]::NewGuid().ToString('N'))
                [System.IO.Compression.ZipFile]::ExtractToDirectory($b.Path,$restoreStage)
                foreach($f in (Get-ChildItem -LiteralPath $restoreStage -File)){ Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $engineBin $f.Name) -Force; [void]$log.Add(('Restored '+$f.Name+' from '+$b.Name+' (compressed backup)')) }
            } else {
                foreach($f in $bf){ Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $engineBin $f.Name) -Force; [void]$log.Add(('Restored '+$f.Name+' from '+$b.Name)) }
            }
            $out=Get-MossEngineVersionOutput $enginePath
            if([string]::IsNullOrWhiteSpace($out)){
                [void]$log.Add(('WARNING: rollback from '+$b.Name+' did not produce a working engine version output'))
                $status.Text='Backup restored, but sd-cli.exe does not report a version.'
                [System.Windows.Forms.MessageBox]::Show($d,("The backup files were copied, but sd-cli.exe does not report a version.`r`nIf the engine does not start, the backup itself may be incomplete - copy files manually from:`r`n{0}" -f $b.Path),'Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
            } else {
                [void]$log.Add(('Rollback from '+$b.Name+' verified, engine reports: '+$out))
                $status.Text=('Rollback complete. Engine now: '+$out)
                [System.Windows.Forms.MessageBox]::Show($d,("Rollback complete - the engine files from {0} were restored and the engine was verified working.`r`n`r`nEngine reports: {1}" -f $b.Name,$out),'Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
            }
        } catch {
            [void]$log.Add(('ERROR during backup restore: '+$_.Exception.Message))
            $status.Text=('Restore failed: '+$_.Exception.Message)
            [System.Windows.Forms.MessageBox]::Show($d,("The restore failed: {0}`r`nCopy the files manually from the backup folder if needed.`r`n`r`nDetails: logs\engine-update-{1}.txt" -f $_.Exception.Message,$stamp),'Restore engine backup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        } finally {
            $d.Cursor='Default'; $restoreBtn.Enabled=$true; $cancelBtn.Enabled=$true
            if($restoreStage -and (Test-Path -LiteralPath $restoreStage)){ Remove-Item -LiteralPath $restoreStage -Recurse -Force -ErrorAction SilentlyContinue }
            try { $logDir=Join-Path $script:AppRoot 'logs'; if(-not(Test-Path -LiteralPath $logDir)){New-Item -ItemType Directory -Path $logDir -Force|Out-Null}; ($log -join "`r`n") | Set-Content -LiteralPath (Join-Path $logDir ('engine-update-'+$stamp+'.txt')) -Encoding UTF8 } catch {}
        }
    })
    [void]$d.ShowDialog($Owner)
}
function Get-MossModelUpdateInfo {
    # Checks the known model sources on Hugging Face against the local files:
    # remote LFS size vs local file size (metadata only - no multi-GB
    # downloads). Sizes of multi-GB LFS files are a reliable version signal.
    $known=@(
        @{ Name='moss_image_sft_int8_convrot.safetensors'; Setting='DiffusionModelPath'; Repo='Comfy-Org/MOSS-Image'; RepoPath='diffusion_models/moss_image_sft_int8_convrot.safetensors' },
        @{ Name='flux2-vae.safetensors'; Setting='VaePath'; Repo='Comfy-Org/MOSS-Image'; RepoPath='vae/flux2-vae.safetensors' },
        @{ Name='Qwen3.5-9B-Q4_K_M.gguf'; Setting='LlmPath'; Repo='unsloth/Qwen3.5-9B-GGUF'; RepoPath='Qwen3.5-9B-Q4_K_M.gguf' },
        @{ Name='tokenizer_qwen3.5.json'; Setting='TokenizerPath'; Repo='OpenMOSS-Team/MOSS-Image-Base'; RepoPath='tokenizer/tokenizer.json' }
    )
    $out=@()
    $treeCache=@{}
    foreach($m in $known){
        $localPath=''
        if($script:Settings.Contains($m.Setting)){
            $candidate=Get-AbsoluteAppPath ([string]$script:Settings[$m.Setting])
            if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){ $localPath=$candidate }
        }
        if(-not $localPath){
            $modelsDir=Join-Path $script:AppRoot 'models'
            $p=Join-Path $modelsDir $m.Name
            if(Test-Path -LiteralPath $p -PathType Leaf){ $localPath=$p }
        }
        $info=@{ Name=$m.Name; Repo=$m.Repo; RepoPath=$m.RepoPath; RemoteUrl=('https://huggingface.co/'+$m.Repo+'/resolve/main/'+$m.RepoPath); LocalPath=$localPath; LocalSize=0; RemoteSize=0; RemoteDate=''; Status='check failed' }
        if($localPath){ $info.LocalSize=(Get-Item -LiteralPath $localPath).Length }
        try {
            if(-not $treeCache.ContainsKey($m.Repo)){
                $treeRaw=Invoke-RestMethod -Uri ('https://huggingface.co/api/models/'+$m.Repo+'/tree/main?recursive=true') -Headers @{Accept='application/json';'User-Agent'='MOSS-Image-Studio'} -TimeoutSec 20
                $tree=@($treeRaw)
                # PS 5.1 can deliver the JSON array as one nested array object
                # (nondeterministic, seen live); unwrap it so matching works.
                if($tree.Count -ge 1 -and $tree[0] -isnot [pscustomobject] -and $tree[0] -is [System.Collections.IEnumerable]){
                    $tree=@($tree[0] | ForEach-Object { $_ })
                }
                $treeCache[$m.Repo]=$tree
            }
            # Match by the exact repository path (the local file name may
            # differ from the remote one, e.g. tokenizer.json is saved as
            # tokenizer_qwen3.5.json).
            $hit=@($treeCache[$m.Repo] | Where-Object { [string]$_.path -eq $m.RepoPath } | Select-Object -First 1)
            if(-not $hit){ $info.Status='no matching file at the source'; $out+=$info; continue }
            $rs=$hit.size; if($hit.lfs -and $hit.lfs.size){ $rs=$hit.lfs.size }
            $info.RemoteSize=$rs
            $info.RemoteDate=[string]$hit.lastCommit.date
            # Missing files keep the 'not installed' status; the remote size
            # above lets the startup offer and the update dialog show how
            # much a fresh download needs.
            if(-not $localPath){ $info.Status='not installed' }
            elseif($rs -eq $info.LocalSize){ $info.Status='up to date' } else { $info.Status='update available' }
        } catch { $info.Status='check failed' }
        $out+=$info
    }
    return $out
}
function Measure-MossDownloadSpeed([string]$url) {
    # Downloads 4 MB of the file and returns the measured speed in MB/s
    # (0 when it cannot be measured) - used for the download-time estimate.
    try {
        $req=[System.Net.HttpWebRequest]::Create($url)
        $req.Method='GET'; $req.AddRange(0,4194303); $req.Timeout=20000; $req.ReadWriteTimeout=20000; $req.UserAgent='MOSS-Image-Studio'
        $resp=$req.GetResponse()
        try {
            $sw=[System.Diagnostics.Stopwatch]::StartNew()
            $stream=$resp.GetResponseStream()
            $buf=New-Object byte[] (256KB)
            $total=0
            while($true){ $r=$stream.Read($buf,0,$buf.Length); if($r -le 0){ break }; $total+=$r; if($total -ge 4MB){ break } }
            $sw.Stop()
            if($total -gt 1MB){ return ($total/1MB)/$sw.Elapsed.TotalSeconds }
        } finally { $resp.Close() }
    } catch {}
    return 0
}
function Find-MossRelocationDrive([int64]$needBytes) {
    # Returns the fixed local drive (other than MOSS's current one) with the
    # most free space, if it can hold the downloads plus a healthy margin.
    try {
        $currentRoot=[System.IO.Path]::GetPathRoot((Get-AbsoluteAppPath '.')).ToUpperInvariant()
        $best=$null
        foreach($d in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')){
            $root=([string]$d.DeviceID+'\').ToUpperInvariant()
            if($root -eq $currentRoot){ continue }
            if([int64]$d.FreeSpace -gt $needBytes -and ($null -eq $best -or [int64]$d.FreeSpace -gt [int64]$best.Free)){ $best=@{ Root=$root; Free=[int64]$d.FreeSpace } }
        }
        return $best
    } catch { return $null }
}
function Move-MossToNewLocation([string]$newRoot) {
    # Copies the MOSS application files to a roomier location and creates a
    # desktop shortcut there. Models/bin are NOT copied - the startup offer
    # in the new location downloads them fresh.
    try {
        New-Item -ItemType Directory -Path $newRoot -Force | Out-Null
        foreach($sub in @('models','bin','config','logs')){ New-Item -ItemType Directory -Path (Join-Path $newRoot $sub) -Force | Out-Null }
        $copied=@()
        foreach($f in (@(Get-ChildItem -LiteralPath $script:AppRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'MOSS-Image-Studio.*' }) + @(Get-ChildItem -LiteralPath $script:AppRoot -File -Filter 'README.txt' -ErrorAction SilentlyContinue))){
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $newRoot $f.Name) -Force
            $copied+=$f.Name
        }
        $oldConfig=Join-Path $script:AppRoot 'config\settings.json'
        if(Test-Path -LiteralPath $oldConfig){ Copy-Item -LiteralPath $oldConfig -Destination (Join-Path $newRoot 'config\settings.json') -Force }
        if($copied.Count -eq 0){ return $null }
        # Desktop shortcut pointing at the new copy.
        $desktop=[Environment]::GetFolderPath('Desktop')
        $target=$null
        foreach($cand in @('MOSS-Image-Studio.vbs','MOSS-Image-Studio.bat')){ if(Test-Path -LiteralPath (Join-Path $newRoot $cand) -PathType Leaf){ $target=(Join-Path $newRoot $cand); break } }
        if(-not $target){ return $null }
        $ws=New-Object -ComObject WScript.Shell
        $sc=$ws.CreateShortcut((Join-Path $desktop 'MOSS Image Studio.lnk'))
        $sc.TargetPath=$target
        $sc.WorkingDirectory=$newRoot
        $sc.Description='MOSS Image Studio'
        $sc.Save()
        return $newRoot
    } catch {
        return $null
    }
}
function Test-MossOfferStartupDownload([System.Windows.Forms.Form]$Owner) {
    # Startup completeness check: if the engine or the known model files are
    # missing, offer to download them right away so MOSS works as intended.
    # Updates for already-installed files are NOT prompted here - they live in
    # the 'Update engine...' dialog.
    try {
        $enginePath=Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
        $engineOk=Test-Path -LiteralPath $enginePath -PathType Leaf
        $missing=@()
        $modelsTotal=0
        $firstMissingUrl=''
        $infos=@(Get-MossModelUpdateInfo)
        foreach($i in $infos){
            if($i.Status -eq 'not installed'){
                $missing+=($i.Name+'  ('+[math]::Round($i.RemoteSize/1GB,2)+' GB)')
                $modelsTotal+=$i.RemoteSize
                if(-not $firstMissingUrl){ $firstMissingUrl=[string]$i.RemoteUrl }
            }
        }
        if(-not $engineOk -or $missing.Count -gt 0){
            $lines=@()
            if(-not $engineOk){ $lines+='  - the engine (sd-cli.exe and its libraries) is missing' }
            foreach($m in $missing){ $lines+=('  - model '+$m+' is missing') }
            $est=''
            if($modelsTotal -gt 0 -and $firstMissingUrl){
                $spd=Measure-MossDownloadSpeed $firstMissingUrl
                if($spd -gt 0){ $est=' At your measured speed ('+[math]::Round($spd,1)+' MB/s) this takes about '+[math]::Round($modelsTotal/1MB/$spd/60,0)+' minutes.' }
            }
            # Not enough room on MOSS's current drive? Suggest a better place
            # first - a fresh install with models needs roughly 12 GB plus
            # the engine package and headroom.
            $needTotal=$modelsTotal+[int64](600MB)
            $driveRoot=[System.IO.Path]::GetPathRoot((Get-AbsoluteAppPath '.')).TrimEnd('\')
            try { $freeHere=(New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace } catch { $freeHere=[int64]::MaxValue }
            if($freeHere -lt $needTotal){
                $better=Find-MossRelocationDrive ($needTotal*2)
                if($better){
                    $suggested=Join-Path $better.Root 'MOSS Image Studio'
                    $msg=("MOSS is in a tight spot:`r`n`r`n`"{0}`" only has {1} GB free, but the missing files need about {2} GB.`r`n`r`nDrive {3} has {4} GB free. Move MOSS there?`r`n`r`nMOSS will be copied to `"{5}`" and a desktop shortcut will be created - then the downloads run from the new place (this copy can be deleted afterwards)." -f $driveRoot,[math]::Round($freeHere/1GB,1),[math]::Round($needTotal/1GB,1),$better.Root.TrimEnd('\'),[math]::Round($better.Free/1GB,1),$suggested)
                    $answer=[System.Windows.Forms.MessageBox]::Show($Owner,$msg,'Better place for MOSS',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
                    if($answer -eq [System.Windows.Forms.DialogResult]::Yes){
                        $newRoot=Move-MossToNewLocation $suggested
                        if($newRoot){
                            try { [void](Write-MossErrorLog 'Relocated MOSS' ('New location: '+$newRoot)) } catch {}
                            $startAnswer=[System.Windows.Forms.MessageBox]::Show($Owner,("MOSS was copied to `""+$newRoot+"`" and a desktop shortcut (MOSS Image Studio) now points there.`r`n`r`nStart the new copy now? The downloads then run from the new place - you can close this old window and delete this old copy afterwards."),'Better place for MOSS',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information)
                            if($startAnswer -eq [System.Windows.Forms.DialogResult]::Yes){
                                $starter=Join-Path $newRoot 'MOSS-Image-Studio.vbs'
                                if(Test-Path -LiteralPath $starter -PathType Leaf){ Start-Process -FilePath 'wscript.exe' -ArgumentList ('"'+$starter+'"') } else { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+$newRoot+'"') }
                                $Owner.Close()
                            }
                            return
                        }
                    }
                } else {
                    [System.Windows.Forms.MessageBox]::Show($Owner,("MOSS is in a tight spot:`r`n`r`n`""+$driveRoot+"`" only has "+[math]::Round($freeHere/1GB,1)+" GB free, but the missing files need about "+[math]::Round($needTotal/1GB,1)+" GB, and no other fixed drive has room either.`r`n`r`nFree up space (or plug in a larger drive) and start MOSS again.`r`nYou can also continue now and install only what fits."),'Better place for MOSS',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
                    return
                }
            }
            $msg=("MOSS is not fully installed yet:`r`n`r`n"+(($lines) -join "`r`n")+"`r`n`r`nWithout these files MOSS cannot generate images.`r`n`r`nDownload them now?"+$est+"`r`n(You can also do this later via 'Update engine...' in the header.)")
            $answer=[System.Windows.Forms.MessageBox]::Show($Owner,$msg,'MOSS setup',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if($answer -eq [System.Windows.Forms.DialogResult]::Yes){ Show-MossEngineUpdateDialog $Owner }
        }
    } catch {}
}
function Show-MossEngineUpdateDialog([System.Windows.Forms.Form]$Owner=$null) {
    # UPDATING THE ENGINE (sd-cli core files) - deliberately separate from the
    # 'Update MOSS...' header button: MOSS is only the GUI, while sd-cli.exe
    # and its libraries in the bin folder are the engine that renders images.
    # This dialog updates those engine files from the official
    # stable-diffusion.cpp releases and shows the published changelogs.
    # Models, outputs, config and the MOSS application files are never touched.
    if ($null -ne $script:GenState -and $script:GenState.IsRunning) {
        [System.Windows.Forms.MessageBox]::Show($Owner,'A generation is running. Wait for it to finish (or cancel it) before updating the engine files.','Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        return
    }
    $enginePath=Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
    if(-not (Test-Path -LiteralPath $enginePath -PathType Leaf)){
        [System.Windows.Forms.MessageBox]::Show($Owner,("The engine executable was not found:`r`n{0}`r`n`r`nRun Hardware / Setup and locate sd-cli.exe first." -f $enginePath),'Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        return
    }
    $engineBin=[System.IO.Path]::GetDirectoryName($enginePath)
    $installedCommit=Get-MossEngineCommit $enginePath
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
    $log=New-Object System.Collections.ArrayList
    [void]$log.Add(('Engine update started '+(Get-Date -Format 'u')))
    [void]$log.Add(('Engine path: '+$enginePath))
    [void]$log.Add(('Installed commit: '+$(if($installedCommit){$installedCommit}else{'unknown'})))
    try {
        [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
        $rawReleases=Invoke-RestMethod -Uri 'https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=10' -Method Get -Headers @{Accept='application/vnd.github+json';'User-Agent'='MOSS-Image-Studio'} -TimeoutSec 15
        $releases=@($rawReleases)
        # Windows PowerShell 5.1 can deliver a JSON array as one nested array
        # object; unwrap it so $releases holds one PSCustomObject per release.
        if($releases.Count -ge 1 -and $releases[0] -isnot [pscustomobject] -and $releases[0] -is [System.Collections.IEnumerable]){
            $releases=@($releases[0] | ForEach-Object { $_ })
        }
        $releases=@($releases | Where-Object { $_.PSObject.Properties['tag_name'] })
    } catch { $releases=@() }
    if($releases.Count -eq 0){
        [void]$log.Add('ERROR: the release feed could not be read (offline or blocked)')
        try { $logDir=Join-Path $script:AppRoot 'logs'; if(-not(Test-Path -LiteralPath $logDir)){New-Item -ItemType Directory -Path $logDir -Force|Out-Null}; ($log -join "`r`n") | Set-Content -LiteralPath (Join-Path $logDir ('engine-update-'+$stamp+'.txt')) -Encoding UTF8 } catch {}
        $answer=[System.Windows.Forms.MessageBox]::Show($Owner,"MOSS could not read the engine release feed (offline or blocked?).`r`n`r`nOpen the releases page to check and download manually?`r`nChoose No to open the backup-restore dialog instead (works offline).",'Engine update',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -eq [System.Windows.Forms.DialogResult]::Yes){ try { Start-Process 'https://github.com/leejet/stable-diffusion.cpp/releases' } catch {} } else { Show-MossEngineBackupRestore $Owner $enginePath $engineBin $log $stamp }
        return
    }
    $latest=$releases[0]
    $latestTag=[string]$latest.tag_name
    [void]$log.Add(('Latest release: '+$latestTag))
    $upToDate=($installedCommit -ne '' -and $latestTag -match [regex]::Escape($installedCommit))
    if($upToDate){ [void]$log.Add('The installed engine matches the latest release (up to date) - the dialog also offers changelogs and backup restore') }
    # Check the model sources at the same time (metadata only - no multi-GB
    # downloads): remote LFS size vs local file size per known source.
    $modelInfos=@(Get-MossModelUpdateInfo)
    $script:MossDlgModels=@($modelInfos | Where-Object { $_.Status -eq 'update available' -or $_.Status -eq 'not installed' })
    $modelFailed=@($modelInfos | Where-Object { $_.Status -eq 'check failed' -or $_.Status -eq 'no matching file at the source' })
    [void]$log.Add(('Model check: '+$modelInfos.Count+' known sources, '+$script:MossDlgModels.Count+' need attention'))
    foreach($mi in $modelInfos){ [void]$log.Add(('Model '+$mi.Name+': '+$mi.Status)) }
    # Measure the download speed once (4 MB range request) so the confirm
    # dialog can give a real time estimate instead of a guess.
    $measuredSpeed=0
    foreach($mi in $script:MossDlgModels){ if($mi.RemoteUrl){ $measuredSpeed=Measure-MossDownloadSpeed $mi.RemoteUrl; break } }
    if($measuredSpeed -gt 0){ [void]$log.Add(('Measured download speed: '+[math]::Round($measuredSpeed,1)+' MB/s')) } else { [void]$log.Add('Download speed could not be measured') }

    # Dialog: release list + changelog reader + variant selection + installer.
    $g=New-Object System.Windows.Forms.Form
    $g.Text='Update engine (sd-cli core files)'
    $g.Size=New-Object System.Drawing.Size(730,768); $g.MinimumSize=New-Object System.Drawing.Size(700,748); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
    $g.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text='UPDATE ENGINE  -  sd-cli core files'; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(12,10); $g.Controls.Add($ttl)
    $sub=New-Object System.Windows.Forms.Label; $sub.Text="MOSS is the GUI - sd-cli.exe and its libraries are the engine that renders the images. This dialog updates only those engine files; the MOSS app, models, prompts, outputs and settings are never touched."; $sub.Location=New-Object System.Drawing.Point(12,40); $sub.Size=New-Object System.Drawing.Size(690,44); $sub.ForeColor=$cMuted; $g.Controls.Add($sub)
    $installedText=$(if($installedCommit){'commit '+$installedCommit}else{'version could not be read'}); $pubDate=$(if($latest.published_at){([datetime]$latest.published_at).ToString('yyyy-MM-dd')}else{'unknown date'})
    $verPanel=New-Object System.Windows.Forms.Panel; $verPanel.Location=New-Object System.Drawing.Point(12,88); $verPanel.Size=New-Object System.Drawing.Size(690,46); $verPanel.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $g.Controls.Add($verPanel)
    $vin=New-Object System.Windows.Forms.Label; $vin.Text='INSTALLED'; $vin.Location=New-Object System.Drawing.Point(10,4); $vin.Size=New-Object System.Drawing.Size(340,15); $vin.Font=New-Object System.Drawing.Font('Segoe UI',8); $vin.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $verPanel.Controls.Add($vin)
    $vinv=New-Object System.Windows.Forms.Label; $vinv.Text=$installedText; $vinv.Location=New-Object System.Drawing.Point(10,20); $vinv.Size=New-Object System.Drawing.Size(340,20); $vinv.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $verPanel.Controls.Add($vinv)
    $vla=New-Object System.Windows.Forms.Label; $vla.Text='LATEST RELEASE'; $vla.Location=New-Object System.Drawing.Point(370,4); $vla.Size=New-Object System.Drawing.Size(310,15); $vla.Font=New-Object System.Drawing.Font('Segoe UI',8); $vla.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $verPanel.Controls.Add($vla)
    $vlav=New-Object System.Windows.Forms.Label; $vlav.Text=($(if($upToDate){$latestTag+'   -  UP TO DATE'}else{$latestTag})); $vlav.Location=New-Object System.Drawing.Point(370,20); $vlav.Size=New-Object System.Drawing.Size(310,20); $vlav.ForeColor=($(if($upToDate){[System.Drawing.Color]::FromArgb(125,205,164)}else{[System.Drawing.Color]::FromArgb(125,205,164)})); if(-not $upToDate){$vlav.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245)}; $verPanel.Controls.Add($vlav)
    $listLabel=New-Object System.Windows.Forms.Label; $listLabel.Text='RECENT RELEASES (select one to read its changelog)'; $listLabel.Location=New-Object System.Drawing.Point(12,116); $listLabel.Size=New-Object System.Drawing.Size(330,20); $listLabel.ForeColor=$cMuted; $g.Controls.Add($listLabel)
    $releaseList=New-Object System.Windows.Forms.ListBox; $releaseList.Location=New-Object System.Drawing.Point(12,138); $releaseList.Size=New-Object System.Drawing.Size(330,200); $releaseList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $releaseList.ForeColor=$cText; $releaseList.BorderStyle='FixedSingle'; $g.Controls.Add($releaseList)
    $notesLabel=New-Object System.Windows.Forms.Label; $notesLabel.Text='RELEASE NOTES / CHANGELOG'; $notesLabel.Location=New-Object System.Drawing.Point(356,116); $notesLabel.Size=New-Object System.Drawing.Size(330,20); $notesLabel.ForeColor=$cMuted; $g.Controls.Add($notesLabel)
    $notes=New-Object System.Windows.Forms.TextBox; $notes.Multiline=$true; $notes.ReadOnly=$true; $notes.ScrollBars='Vertical'; $notes.WordWrap=$false; $notes.Location=New-Object System.Drawing.Point(356,138); $notes.Size=New-Object System.Drawing.Size(346,200); $notes.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $notes.ForeColor=$cText; $notes.BorderStyle='FixedSingle'; $notes.Font=New-Object System.Drawing.Font('Consolas',8); $g.Controls.Add($notes)
    foreach($rel in $releases){ $relDate=$(if($rel.published_at){([datetime]$rel.published_at).ToString('yyyy-MM-dd')}else{'?'}); [void]$releaseList.Items.Add(([string]$rel.tag_name+'   ('+$relDate+')')) }
    $releaseList.SelectedIndex=0
    $showNotes={
        if($releaseList.SelectedIndex -lt 0 -or $releaseList.SelectedIndex -ge $releases.Count){ $notes.Text=''; return }
        $rel=$releases[$releaseList.SelectedIndex]
        $body=[string]$rel.body
        if([string]::IsNullOrWhiteSpace($body)){ $body='(No release notes were published for this build.)' }
        $sb=New-Object System.Text.StringBuilder
        [void]$sb.Append($body)
        $winAssets=@($rel.assets | Where-Object { [string]$_.name -match '-win-' })
        if($winAssets.Count -gt 0){
            [void]$sb.Append("`r`n`r`nWindows packages in this release:`r`n")
            foreach($wa in $winAssets){ [void]$sb.Append(('  '+$wa.name+'  ('+[math]::Round($wa.size/1MB)+' MB)'+"`r`n")) }
        }
        $notes.Text=$sb.ToString()
    }
    $releaseList.Add_SelectedIndexChanged($showNotes)
    & $showNotes
    $variantLabel=New-Object System.Windows.Forms.Label; $variantLabel.Text='ENGINE VARIANT (what your current engine becomes)'; $variantLabel.Location=New-Object System.Drawing.Point(12,344); $variantLabel.Size=New-Object System.Drawing.Size(400,20); $variantLabel.ForeColor=$cMuted; $g.Controls.Add($variantLabel)
    $variant=New-Object System.Windows.Forms.ComboBox; $variant.DropDownStyle='DropDownList'; $variant.Location=New-Object System.Drawing.Point(12,364); $variant.Size=New-Object System.Drawing.Size(280,26); $variant.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $variant.ForeColor=$cText; $g.Controls.Add($variant)
    # The CUDA versions offered are read from the selected release itself, so
    # cuda11 / cuda12 / a future cuda13 all appear automatically. The driver's
    # own CUDA capability is read from nvidia-smi so Auto can pick a build the
    # driver can actually run.
    $script:MossDlgDriverCuda=''
    try {
        $smiCmd=Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
        if(-not $smiCmd){ foreach($smiCand in @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe","$env:WINDIR\System32\nvidia-smi.exe")){ if(Test-Path -LiteralPath $smiCand){ $smiCmd=$smiCand; break } } }
        if($smiCmd){ $smiOut=(& $smiCmd 2>&1 | Out-String); if($smiOut -match 'CUDA Version:\s*([0-9]+\.[0-9]+)'){ $script:MossDlgDriverCuda=$Matches[1] } }
    } catch {}
    $variantDesc=New-Object System.Windows.Forms.Label; $variantDesc.Location=New-Object System.Drawing.Point(306,364); $variantDesc.Size=New-Object System.Drawing.Size(396,44); $variantDesc.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($variantDesc)
    $extraLabel=New-Object System.Windows.Forms.Label; $extraLabel.Text='ALSO MAKE AVAILABLE - extra variants in their own folders (switch later via Hardware / Setup):'; $extraLabel.Location=New-Object System.Drawing.Point(12,414); $extraLabel.Size=New-Object System.Drawing.Size(690,16); $extraLabel.ForeColor=$cMuted; $g.Controls.Add($extraLabel)
    $extraFlow=New-Object System.Windows.Forms.FlowLayoutPanel; $extraFlow.Location=New-Object System.Drawing.Point(12,432); $extraFlow.Size=New-Object System.Drawing.Size(690,30); $extraFlow.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $extraFlow.WrapContents=$false; $g.Controls.Add($extraFlow)
    $variantLabelOf={
        param($key)
        if($key -like 'cuda*'){ return ('CUDA '+$key.Substring(4)+' (NVIDIA)') }
        switch($key){ 'vulkan' { return 'Vulkan (any GPU)' } 'rocm' { return 'AMD ROCm' } 'sycl' { return 'Intel SYCL' } 'cpu' { return 'CPU only' } }
        return $key
    }
    $resolveAuto={
        param($availKeys)
        $key='vulkan'; $detail='no NVIDIA card detected - Vulkan runs on most GPUs'
        try {
            $physGpus=@(Get-GpuInventory | Where-Object { -not $_.IsVirtual })
            if(@($physGpus | Where-Object { $_.Vendor -eq 'NVIDIA' }).Count -gt 0){
                $cands=@($availKeys | Where-Object { $_ -like 'cuda*' })
                if($cands.Count -gt 0){
                    $detail='NVIDIA GPU detected'
                    $pick=$null
                    if($script:MossDlgDriverCuda){
                        $dMaj=0
                        try { $dMaj=[int](([string]$script:MossDlgDriverCuda).Split('.')[0]) } catch { $dMaj=0 }
                        foreach($c in $cands){ $cMaj=0; try { $cMaj=[int]($c.Substring(4).Split('.')[0]) } catch { $cMaj=0 }; if($cMaj -le $dMaj){ $pick=$c; break } }
                        if($pick){ $detail=('NVIDIA GPU detected - newest CUDA build your driver (up to CUDA '+$script:MossDlgDriverCuda+') supports') }
                    }
                    if(-not $pick){ $pick=$cands[0]; if(-not $script:MossDlgDriverCuda){ $detail='NVIDIA GPU detected - newest CUDA build in this release (driver capability unreadable)' } }
                    $key=$pick
                } else { $detail='NVIDIA GPU detected, but this release ships no CUDA build - Vulkan' }
            }
        } catch {}
        return @($key,$detail)
    }
    $syncInstallOptions={
        $vIdxNow=$variant.SelectedIndex
        $primaryNow='auto'
        if($vIdxNow -ge 0 -and $vIdxNow -lt $script:MossDlgKeys.Count){ $primaryNow=[string]$script:MossDlgKeys[$vIdxNow] }
        $detailNow=''
        if($primaryNow -eq 'auto'){ $r=& $resolveAuto $script:MossDlgConcrete; $primaryNow=[string]$r[0]; $detailNow=[string]$r[1] }
        $desc=''
        if($vIdxNow -eq 0){
            $desc=('Auto picks '+(& $variantLabelOf $primaryNow)+' - '+$detailNow+'.')
        } elseif($primaryNow -like 'cuda*'){
            $desc=('For NVIDIA cards using CUDA '+$primaryNow.Substring(4)+' - the fastest option.')
            if($script:MossDlgDriverCuda){ $desc+=(' Your driver supports up to CUDA '+$script:MossDlgDriverCuda+' - a higher CUDA build may not start on it.') } else { $desc+=' The driver CUDA version could not be read - if the engine fails to start, pick a lower CUDA version or Vulkan.' }
        } else {
            switch($primaryNow){
                'vulkan' { $desc='Runs on almost any modern GPU - NVIDIA, AMD and Intel. Slightly slower than a native CUDA build, but the most compatible choice.' }
                'rocm' { $desc='For supported AMD Radeon cards (official ROCm build). If it fails to start on your card, switch to Vulkan. No CUDA runtime is needed.' }
                'sycl' { $desc='For Intel Arc and integrated Intel graphics (SYCL build). Not in every release - Vulkan is the safe alternative.' }
                'cpu' { $desc='Needs no graphics card at all. Works on any PC but is much slower - mainly for testing or small models.' }
            }
        }
        $variantDesc.Text=$desc
        foreach($k in @($script:MossDlgConcrete)){
            $cb=$script:MossDlgExtras[$k]
            if($null -eq $cb){ continue }
            if($k -eq $primaryNow){ $cb.Enabled=$false; $cb.Checked=$false } else { $cb.Enabled=$true }
        }
        # cudart is REQUIRED for CUDA builds and is downloaded automatically
        # (version-matched) whenever a CUDA variant is selected - nothing to
        # configure, no checkbox, no note.
    }
    $syncVariantCombo={
        if($releaseList.SelectedIndex -lt 0 -or $releaseList.SelectedIndex -ge $releases.Count){ return }
        $rel=$releases[$releaseList.SelectedIndex]
        $cudaVers=@()
        foreach($a in @($rel.assets)){ $an=[string]$a.name; if($an -match 'bin-win-cuda([0-9]+(?:\.[0-9]+)?)-x64\.zip'){ $cudaVers+=$Matches[1] } }
        $cudaVers=@($cudaVers | Sort-Object -Unique | Sort-Object -Property { $v=[string]$_; if($v -notmatch '\.'){ $v=$v+'.0' }; [version]$v } -Descending)
        $concrete=@()
        foreach($cv in $cudaVers){ $concrete+=('cuda'+$cv) }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-vulkan-x64.zip' }).Count -gt 0){ $concrete+='vulkan' }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-rocm*' }).Count -gt 0){ $concrete+='rocm' }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-sycl*' }).Count -gt 0){ $concrete+='sycl' }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-cpu-x64.zip' }).Count -gt 0){ $concrete+='cpu' }
        $script:MossDlgConcrete=$concrete
        $script:MossDlgKeys=@('auto')+$concrete
        $variant.Items.Clear()
        [void]$variant.Items.Add('Auto (recommended for my hardware)')
        foreach($k in $concrete){ [void]$variant.Items.Add((& $variantLabelOf $k)) }
        if($variant.Items.Count -gt 0){ $variant.SelectedIndex=0 }
        while($extraFlow.Controls.Count -gt 0){ $extraFlow.Controls.RemoveAt(0) }
        $newExtras=@{}
        foreach($k in $concrete){
            $cb=New-Object System.Windows.Forms.CheckBox; $cb.Text=(& $variantLabelOf $k); $cb.AutoSize=$true; $cb.ForeColor=$cMuted; $cb.Tag=$k
            $cb.Add_CheckedChanged($syncInstallOptions)
            [void]$extraFlow.Controls.Add($cb)
            $newExtras[$k]=$cb
        }
        $script:MossDlgExtras=$newExtras
        & $syncInstallOptions
    }
    $releaseList.Add_SelectedIndexChanged({ & $syncVariantCombo })
    & $syncVariantCombo
    # MODELS section: only models that need attention are listed (updates
    # available or not installed); up-to-date models do not appear.
    $modelsLabelText=$(if($script:MossDlgModels.Count -gt 0){'MODELS - '+$script:MossDlgModels.Count+' update(s) available (checked = download and install):'}else{'MODELS - all known models are up to date.'})
    if($modelFailed.Count -gt 0){ $modelsLabelText+=' (some sources could not be checked - offline?)' }
    $modelsLabel=New-Object System.Windows.Forms.Label; $modelsLabel.Text=$modelsLabelText; $modelsLabel.Location=New-Object System.Drawing.Point(12,470); $modelsLabel.Size=New-Object System.Drawing.Size(690,16); $modelsLabel.ForeColor=$cMuted; $g.Controls.Add($modelsLabel)
    $modelsList=New-Object System.Windows.Forms.CheckedListBox; $modelsList.Location=New-Object System.Drawing.Point(12,488); $modelsList.Size=New-Object System.Drawing.Size(690,96); $modelsList.CheckOnClick=$true; $modelsList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $modelsList.ForeColor=$cText; $modelsList.BorderStyle='FixedSingle'
    foreach($mi in $script:MossDlgModels){
        [void]$modelsList.Items.Add(($mi.Name+'   ('+[math]::Round($mi.RemoteSize/1GB,2)+' GB download'+$(if($mi.Status -eq 'update available'){', update'}else{', new install'})+')'))
        $modelsList.SetItemChecked($modelsList.Items.Count-1,$true)
    }
    $modelsList.Visible=($script:MossDlgModels.Count -gt 0)
    $g.Controls.Add($modelsList)
    $modelBackupCheck=New-Object System.Windows.Forms.CheckBox; $modelBackupCheck.Text='Back up the old model files first (renamed to <name>.old-<time> - instant; the newest 3 backups are kept)'; $modelBackupCheck.Location=New-Object System.Drawing.Point(12,590); $modelBackupCheck.Size=New-Object System.Drawing.Size(690,22); $modelBackupCheck.ForeColor=$cMuted; $modelBackupCheck.Visible=($script:MossDlgModels.Count -gt 0); $modelBackupCheck.Checked=$true; $g.Controls.Add($modelBackupCheck)
    $installBtn=New-Object System.Windows.Forms.Button; $installBtn.Text='Download and install...'; $installBtn.Location=New-Object System.Drawing.Point(12,618); $installBtn.Size=New-Object System.Drawing.Size(180,32); $installBtn.FlatStyle='Flat'; $installBtn.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $installBtn.ForeColor=[System.Drawing.Color]::White; $g.Controls.Add($installBtn)
    $restoreBtn=New-Object System.Windows.Forms.Button; $restoreBtn.Text='Restore a backup...'; $restoreBtn.Location=New-Object System.Drawing.Point(202,618); $restoreBtn.Size=New-Object System.Drawing.Size(150,32); $restoreBtn.FlatStyle='Flat'; $restoreBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $restoreBtn.ForeColor=$cText; $g.Controls.Add($restoreBtn)
    $pageBtn=New-Object System.Windows.Forms.Button; $pageBtn.Text='Open releases page'; $pageBtn.Location=New-Object System.Drawing.Point(362,618); $pageBtn.Size=New-Object System.Drawing.Size(150,32); $pageBtn.FlatStyle='Flat'; $pageBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $pageBtn.ForeColor=$cText; $g.Controls.Add($pageBtn)
    $closeBtn=New-Object System.Windows.Forms.Button; $closeBtn.Text='Close'; $closeBtn.Location=New-Object System.Drawing.Point(610,618); $closeBtn.Size=New-Object System.Drawing.Size(80,32); $closeBtn.FlatStyle='Flat'; $closeBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $closeBtn.ForeColor=$cText; $g.Controls.Add($closeBtn)
    $status=New-Object System.Windows.Forms.Label; $status.Location=New-Object System.Drawing.Point(12,658); $status.Size=New-Object System.Drawing.Size(690,50); $status.ForeColor=$cMuted; $status.Text='Pick a release above to read its changelog. Engine files and models are checked at the same time; the current engine files are backed up before anything changes; models are only touched when you select a model update. Use Restore a backup... to roll back the engine.'; $g.Controls.Add($status)
    $pageBtn.Add_Click({ try { Start-Process 'https://github.com/leejet/stable-diffusion.cpp/releases' } catch { [System.Windows.Forms.MessageBox]::Show($g,'The releases page could not be opened. Visit github.com/leejet/stable-diffusion.cpp and open Releases.','Engine update')|Out-Null } })
    $closeBtn.Add_Click({$g.Close()})
    $restoreBtn.Add_Click({ Show-MossEngineBackupRestore $g $enginePath $engineBin $log $stamp })
    $installBtn.Add_Click({
        if($releaseList.SelectedIndex -lt 0){ [System.Windows.Forms.MessageBox]::Show($g,'Select a release first.','Engine update')|Out-Null; return }
        $rel=$releases[$releaseList.SelectedIndex]; $relTag=[string]$rel.tag_name
        # Re-derive the variants actually present in the SELECTED release (the
        # dropdown is built from the latest release; older ones may differ).
        $availKeys=@()
        $cudaVers=@()
        foreach($a in @($rel.assets)){ $an=[string]$a.name; if($an -match 'bin-win-cuda([0-9]+(?:\.[0-9]+)?)-x64\.zip'){ $cudaVers+=$Matches[1] } }
        $cudaVers=@($cudaVers | Sort-Object -Unique | Sort-Object -Property { $v=[string]$_; if($v -notmatch '\.'){ $v=$v+'.0' }; [version]$v } -Descending)
        foreach($cv in $cudaVers){ $availKeys+=('cuda'+$cv) }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-vulkan-x64.zip' }).Count -gt 0){ $availKeys+='vulkan' }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-rocm*' }).Count -gt 0){ $availKeys+='rocm' }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-sycl*' }).Count -gt 0){ $availKeys+='sycl' }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-cpu-x64.zip' }).Count -gt 0){ $availKeys+='cpu' }
        if($availKeys.Count -eq 0){
            [void]$log.Add(('ERROR: release '+$relTag+' has no Windows engine builds'))
            [System.Windows.Forms.MessageBox]::Show($g,'This release does not include any Windows engine builds. Choose another release or open the releases page to download manually.','Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
            return
        }
        $vIdx=$variant.SelectedIndex
        $primaryKey=''
        if($vIdx -le 0){ $r=& $resolveAuto $availKeys; $primaryKey=[string]$r[0] }
        else { $primaryKey=[string]$script:MossDlgKeys[$vIdx]; if($availKeys -notcontains $primaryKey){
            [void]$log.Add(('ERROR: '+$primaryKey+' not available in release '+$relTag))
            $availText=(($availKeys | ForEach-Object { & $variantLabelOf $_ }) -join ', ')
            [System.Windows.Forms.MessageBox]::Show($g,("The selected release does not include a build for {0}.`r`nThis release offers: {1}`r`nChoose another release or pick one of the available variants." -f (& $variantLabelOf $primaryKey),$availText),'Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
            return
        } }
        # Additional variants checked in 'ALSO MAKE AVAILABLE' - each installed
        # side by side into its own engines\<variant> folder next to the main
        # one, so several engines can coexist (switch via Hardware / Setup).
        $extras=@()
        foreach($k in $availKeys){
            $cb=$script:MossDlgExtras[$k]
            if($null -ne $cb -and $cb.Enabled -and $cb.Checked -and $k -ne $primaryKey){ $extras+=$k }
        }
        $enginesRoot=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) 'engines'
        $plan=@()
        $plan+=@{ Key=$primaryKey; Target=$engineBin; IsPrimary=$true }
        foreach($k in $extras){ $plan+=@{ Key=$k; Target=(Join-Path $enginesRoot $k); IsPrimary=$false } }
        $assetFor={
            param($relIn,$keyIn)
            $pat=$(if($keyIn -like 'cuda*'){('bin-win-cuda'+$keyIn.Substring(4)+'-x64.zip')}elseif($keyIn -eq 'vulkan'){'bin-win-vulkan-x64.zip'}elseif($keyIn -eq 'rocm'){'bin-win-rocm'}elseif($keyIn -eq 'sycl'){'bin-win-sycl'}else{'bin-win-cpu-x64.zip'})
            $hits=@($relIn.assets | Where-Object { [string]$_.name -like ('*'+$pat+'*') } | Select-Object -First 1)
            if($hits.Count -gt 0){ return $hits[0] }
            return $null
        }
        $engineAssets=@{}
        foreach($k in (@($plan | ForEach-Object { $_.Key }) | Sort-Object -Unique)){
            $hit=& $assetFor $rel $k
            if(-not $hit -or -not $hit.browser_download_url){
                [void]$log.Add(('ERROR: no '+$k+' package in release '+$relTag))
                [System.Windows.Forms.MessageBox]::Show($g,("This release does not include a Windows build for {0}.`r`nChoose another variant or open the releases page to download manually." -f (& $variantLabelOf $k)),'Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
                return
            }
            $engineAssets[$k]=$hit
        }
        # CUDA runtime (cudart) is required for CUDA builds, in the matching
        # major version (cu12 files do not run a cu13 engine and vice versa).
        # Every selected CUDA variant gets it automatically (primary and
        # side-by-side extras alike).
        $cudartNeededMajors=@()
        foreach($p in $plan){
            if($p.Key -like 'cuda*'){
                $mj=$p.Key.Substring(4).Split('.')[0]
                if($cudartNeededMajors -notcontains $mj){ $cudartNeededMajors+=$mj }
            }
        }
        $cudartAssets=@{}
        foreach($mj in $cudartNeededMajors){
            $ca=@($rel.assets | Where-Object { [string]$_.name -like ('cudart-sd-bin-win-cu'+$mj+'*-x64.zip') } | Select-Object -First 1)
            if($ca){ $cudartAssets[$mj]=$ca[0] }
        }
        $missingCudartExtra=$false
        foreach($p in $plan){
            if(-not $p.IsPrimary -and $p.Key -like 'cuda*'){
                $mj=$p.Key.Substring(4).Split('.')[0]
                if(-not $cudartAssets.ContainsKey($mj)){ $missingCudartExtra=$true }
            }
        }
        if($missingCudartExtra){
            [void]$log.Add(('ERROR: no cudart package for an extra CUDA variant in release '+$relTag))
            [System.Windows.Forms.MessageBox]::Show($g,'This release has no CUDA runtime package for one of the extra CUDA variants you selected, and a fresh CUDA engine folder cannot start without it.`r`nUncheck that extra variant (or choose Vulkan for it) and try again.','Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
            return
        }
        # Models selected in the MODELS section - downloaded and installed
        # after the engine update succeeds. Sizes warn the user; the old
        # files are renamed (instant) or overwritten per the checkbox.
        $modelPlan=@()
        foreach($idx in @($modelsList.CheckedIndices)){ if($idx -lt $script:MossDlgModels.Count){ $modelPlan+=$script:MossDlgModels[$idx] } }
        $modelsTotal=0
        foreach($mi in $modelPlan){ if($mi.RemoteSize -gt 0){ $modelsTotal+=$mi.RemoteSize } }
        if($modelPlan.Count -gt 0){ [void]$log.Add(('Models to update: '+(($modelPlan | ForEach-Object { $_.Name }) -join ', ')+' ('+[math]::Round($modelsTotal/1GB,2)+' GB total)')) }
        # Disk space pre-check: download + unpack + backup must fit on both
        # the temp drive and the drive holding the engine/models, or the
        # install would fail halfway through replacing files.
        $needBase=500MB
        $totalDl=0
        foreach($k in $engineAssets.Keys){ $totalDl+=[int64]$engineAssets[$k].size }
        foreach($mj in $cudartAssets.Keys){ $totalDl+=[int64]$cudartAssets[$mj].size }
        $needTemp=$totalDl*3 + $needBase + $modelsTotal*2
        $needBin=$totalDl*4 + $needBase + $modelsTotal*2
        try { $freeTemp=(New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath()))).AvailableFreeSpace } catch { $freeTemp=[int64]::MaxValue }
        try { $freeBin=(New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($engineBin))).AvailableFreeSpace } catch { $freeBin=[int64]::MaxValue }
        if($freeTemp -lt $needTemp -or $freeBin -lt $needBin){
            [void]$log.Add(('ERROR: insufficient disk space (temp free '+[math]::Round($freeTemp/1GB,1)+' GB, engine-drive free '+[math]::Round($freeBin/1GB,1)+' GB, need ~'+[math]::Round($needTemp/1GB,1)+' GB and ~'+[math]::Round($needBin/1GB,1)+' GB)'))
            [System.Windows.Forms.MessageBox]::Show($g,("Not enough free disk space for the engine update.`r`n`r`nNeeded: about {0} GB on the temp drive ({1}) and {2} GB on {3}`r`nAvailable: {4} GB and {5} GB`r`n`r`nFree up some space (or install fewer variants) and try again." -f [math]::Round($needTemp/1GB,1),[System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath()).TrimEnd('\'),[math]::Round($needBin/1GB,1),[System.IO.Path]::GetPathRoot($engineBin).TrimEnd('\'),[math]::Round($freeTemp/1GB,1),[math]::Round($freeBin/1GB,1)),'Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
            return
        }
        $busy=@(Get-Process -Name 'sd-cli','sd-server' -ErrorAction SilentlyContinue)
        if($busy.Count -gt 0){ [System.Windows.Forms.MessageBox]::Show($g,'sd-cli or sd-server is currently running. Wait for it to finish and try again.','Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return }
        $planText=''
        foreach($p in $plan){ $planText+=((('  '+(& $variantLabelOf $p.Key))+$(if($p.IsPrimary){''}else{' (extra)'})+'  ->  '+$p.Target)+"`r`n") }
        $modelText=if($modelPlan.Count -gt 0){ ((($modelPlan | ForEach-Object { '  '+$_.Name+'  ('+[math]::Round($_.RemoteSize/1GB,2)+' GB download, current file: '+$(if($_.LocalSize -gt 0){[math]::Round($_.LocalSize/1GB,2)+' GB'}else{'not installed'})+')' }) -join "`r`n")+"`r`n  Old model files: "+$(if($modelBackupCheck.Checked){'kept as <name>.old-<time> (renamed, instant - older backups beyond the newest 3 are deleted automatically)'}else{'overwritten WITHOUT a backup'})) } else { '  (no model updates selected)' }
        $modelText+="`r`n"
        $timeText='depends on your connection'
        if($measuredSpeed -gt 0 -and $modelsTotal -gt 0){ $timeText='about '+[math]::Round(($modelsTotal/1MB)/$measuredSpeed/60,0)+' minutes for the models at your measured speed ('+[math]::Round($measuredSpeed,1)+' MB/s)' }
        $dlText=''
        foreach($p in $plan){ $a=$engineAssets[$p.Key]; $dlText+=((('  '+$a.name)+'  ('+[math]::Round($a.size/1MB)+' MB)')+"`r`n") }
        foreach($mj in ($cudartAssets.Keys | Sort-Object)){ $ca=$cudartAssets[$mj]; $dlText+=((('  '+$ca.name)+'  ('+[math]::Round($ca.size/1MB)+' MB)')+"`r`n") }
        foreach($mi in $modelPlan){ $dlText+=(('  '+$mi.Name+'  ('+[math]::Round($mi.RemoteSize/1GB,2)+' GB)')+"`r`n") }
        $backupZip=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) ('engine-backup-'+$stamp+'.zip')
        # Legacy (pre-compression) folder name, only checked when no zip exists.
        $backupDir=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) ('engine-backup-'+$stamp)
        $answer=[System.Windows.Forms.MessageBox]::Show($g,("Ready to install the update:`r`n`r`nRelease: {0}`r`nInstall plan:`r`n{1}Models to update:`r`n{2}Download:`r`n{3}Engine backup (compressed zip): {4}`r`nDisk space needed: about {5} GB on the temp drive and {6} GB on the engine+models drive`r`nEstimated model download time: {7}`r`n`r`nMOSS will be unresponsive during the download (several minutes on slower connections; GB-sized models take longer).`r`n`r`nInstall now?" -f $relTag,$planText,$modelText,$dlText,$backupZip,[math]::Round($needTemp/1GB,1),[math]::Round($needBin/1GB,1),$timeText),'Install engine & model update',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){ return }
        $oldProgress=$ProgressPreference; $ProgressPreference='SilentlyContinue'
        $tempRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('MOSS-Engine-Update-'+[guid]::NewGuid().ToString('N'))
        try {
            $g.Cursor='WaitCursor'; $installBtn.Enabled=$false; $pageBtn.Enabled=$false; $closeBtn.Enabled=$false
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $engineFiles=@{}
            $dlTotal=@($engineAssets.Keys).Count + @($cudartAssets.Keys).Count
            $dlIndex=0
            foreach($k in (@($plan | ForEach-Object { $_.Key }) | Sort-Object -Unique)){
                $a=$engineAssets[$k]; $dlIndex++
                $status.Text=('Downloading '+(& $variantLabelOf $k)+': '+$a.name+' ('+[math]::Round($a.size/1MB)+' MB) ['+$dlIndex+'/'+$dlTotal+']...')
                [System.Windows.Forms.Application]::DoEvents()
                [void]$log.Add(('Downloading '+$a.browser_download_url))
                New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
                $zipPath=Join-Path $tempRoot ($k+'.zip')
                Invoke-WebRequest -Uri ([string]$a.browser_download_url) -OutFile $zipPath -UseBasicParsing -TimeoutSec 3600
                if(-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -le 0){ throw ('The '+$k+' download did not produce a file. Nothing has been changed.') }
                Test-MossZipDigest $zipPath $a
                [void]$log.Add(($k+' download ok ('+[math]::Round((Get-Item -LiteralPath $zipPath).Length/1MB)+' MB)'))
                $status.Text=('Verifying and unpacking '+(& $variantLabelOf $k)+'...')
                [System.Windows.Forms.Application]::DoEvents()
                $archive=[System.IO.Compression.ZipFile]::OpenRead($zipPath)
                try {
                    $relEntry=@($archive.Entries | Where-Object { [string]$_.FullName -match '(^|/)sd-cli\.exe$' } | Select-Object -First 1)
                    if(-not $relEntry){ throw ('The '+$k+' package does not contain sd-cli.exe. Nothing has been changed.') }
                    $entryDir=[System.IO.Path]::GetDirectoryName([string]$relEntry.FullName)
                } finally { $archive.Dispose() }
                $stageK=Join-Path $tempRoot ('stage-'+$k)
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$stageK)
                $srcK=$stageK; if(-not [string]::IsNullOrWhiteSpace($entryDir)){ $srcK=Join-Path $stageK ($entryDir -replace '/','\') }
                $filesK=@(Get-ChildItem -LiteralPath $srcK -Recurse -File | ForEach-Object { $_.FullName })
                if($filesK.Count -eq 0){ throw ('The '+$k+' package unpacked to no files. Nothing has been changed.') }
                $engineFiles[$k]=$filesK
            }
            $cudartFilesByMaj=@{}
            foreach($mj in (@($cudartAssets.Keys) | Sort-Object)){
                $ca=$cudartAssets[$mj]; $dlIndex++
                $status.Text=('Downloading the CUDA '+$mj+' runtime: '+$ca.name+' ('+[math]::Round($ca.size/1MB)+' MB) ['+$dlIndex+'/'+$dlTotal+']...')
                [System.Windows.Forms.Application]::DoEvents()
                [void]$log.Add(('Downloading '+$ca.browser_download_url))
                $cudartZip=Join-Path $tempRoot ('cudart-cu'+$mj+'.zip')
                Invoke-WebRequest -Uri ([string]$ca.browser_download_url) -OutFile $cudartZip -UseBasicParsing -TimeoutSec 3600
                if(-not (Test-Path -LiteralPath $cudartZip -PathType Leaf) -or (Get-Item -LiteralPath $cudartZip).Length -le 0){ throw 'The CUDA runtime download did not produce a file. Nothing has been changed.' }
                Test-MossZipDigest $cudartZip $ca
                [void]$log.Add(('CUDA '+$mj+' runtime download ok ('+[math]::Round((Get-Item -LiteralPath $cudartZip).Length/1MB)+' MB)'))
                $stageC=Join-Path $tempRoot ('stage-cudart-'+$mj)
                [System.IO.Compression.ZipFile]::ExtractToDirectory($cudartZip,$stageC)
                $cudartFilesByMaj[$mj]=@(Get-ChildItem -LiteralPath $stageC -Recurse -File | ForEach-Object { $_.FullName })
            }
            # The download took minutes: re-check that no engine process has
            # appeared, otherwise replacing its files would fail or corrupt it.
            $busyNow=@(Get-Process -Name 'sd-cli','sd-server' -ErrorAction SilentlyContinue)
            if($busyNow.Count -gt 0){ throw 'sd-cli or sd-server started while the download was running. Nothing has been changed - try again when no engine process is running.' }
            $status.Text='Backing up the current engine files (compressing)...'
            [System.Windows.Forms.Application]::DoEvents()
            [void]$log.Add(('Backup archive: '+$backupZip))
            $primaryPlan=@($plan | Where-Object { $_.IsPrimary })[0]
            Add-Type -AssemblyName System.IO.Compression
            $replaced=@()
            $backupArchive=[System.IO.Compression.ZipFile]::Open($backupZip,[System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach($src in @($engineFiles[$primaryPlan.Key])){
                    $name=[System.IO.Path]::GetFileName($src); $dest=Join-Path $engineBin $name
                    if(Test-Path -LiteralPath $dest -PathType Leaf){
                        # Zip via stream copy (CreateEntryFromFile is not
                        # available on every .NET/PowerShell 5.1 setup). Files
                        # larger than 8 MB get a 4 MB sample from the MIDDLE
                        # of the file compressed first: DLL headers at the
                        # start compress far better than the code bulk and
                        # would mislead a start sample. If the middle sample
                        # barely shrinks (>= 0.95), the file is stored
                        # uncompressed - no time wasted on incompressible
                        # machine code (e.g. ggml-cuda.dll: 4% whole-file
                        # gain). Small gains on huge files are still taken
                        # (cublasLt: 29% = ~186 MB).
                        $level=[System.IO.Compression.CompressionLevel]::Optimal
                        $fiB=Get-Item -LiteralPath $dest
                        if($fiB.Length -gt 8MB){
                            $fsS=[System.IO.File]::OpenRead($dest)
                            try {
                                $sampleBytes=4MB
                                $offS=[int][math]::Max(0,(($fsS.Length/2)-($sampleBytes/2)))
                                [void]$fsS.Seek($offS,[System.IO.SeekOrigin]::Begin)
                                $bufS=New-Object byte[] $sampleBytes
                                $readS=$fsS.Read($bufS,0,$sampleBytes)
                                $msS=New-Object System.IO.MemoryStream
                                try {
                                    $dsS=New-Object System.IO.Compression.DeflateStream($msS,[System.IO.Compression.CompressionLevel]::Optimal,$true)
                                    try { $dsS.Write($bufS,0,$readS) } finally { $dsS.Dispose() }
                                    if(($msS.Length / [double]$readS) -ge 0.95){ $level=[System.IO.Compression.CompressionLevel]::NoCompression }
                                } finally { $msS.Dispose() }
                            } finally { $fsS.Dispose() }
                        }
                        $entry=$backupArchive.CreateEntry($name,$level)
                        $es=$entry.Open()
                        try { $fs=[System.IO.File]::OpenRead($dest); try { $fs.CopyTo($es) } finally { $fs.Dispose() } } finally { $es.Dispose() }
                        $replaced+=$name
                    }
                }
            } finally { $backupArchive.Dispose() }
            [void]$log.Add(('Backed up '+$replaced.Count+' files, '+[math]::Round((Get-Item -LiteralPath $backupZip).Length/1MB)+' MB compressed: '+(($replaced | Sort-Object) -join ', ')))
            # Keep at most 3 engine backups: delete the oldest beyond that.
            $backupParent=[System.IO.Path]::GetDirectoryName($engineBin)
            $oldBackups=@(Get-ChildItem -LiteralPath $backupParent -File -Filter 'engine-backup-*.zip' -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)
            $oldBackups+=@(Get-ChildItem -LiteralPath $backupParent -Directory -Filter 'engine-backup-*' -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)
            for($bi=3; $bi -lt $oldBackups.Count; $bi++){
                try { Remove-Item -LiteralPath $oldBackups[$bi].FullName -Recurse -Force -ErrorAction Stop; [void]$log.Add(('Deleted old engine backup beyond the limit of 3: '+$oldBackups[$bi].Name)) } catch { [void]$log.Add(('Could not delete old engine backup '+$oldBackups[$bi].Name+': '+$_.Exception.Message)) }
            }
            # Install every target: the primary replaces the current engine, the
            # extras land in their own engines\<variant> folders (a previous
            # extra folder of the same variant is moved aside to *.old-<time>).
            foreach($p in $plan){
                $filesP=@($engineFiles[$p.Key])
                if($p.Key -like 'cuda*'){
                    $mjP=$p.Key.Substring(4).Split('.')[0]
                    if($cudartFilesByMaj.ContainsKey($mjP)){ $filesP=@($filesP)+@($cudartFilesByMaj[$mjP]) }
                }
                if($p.IsPrimary){
                    $status.Text='Replacing the engine files...'
                    [System.Windows.Forms.Application]::DoEvents()
                    foreach($src in $filesP){ Copy-Item -LiteralPath $src -Destination (Join-Path $engineBin ([System.IO.Path]::GetFileName($src))) -Force }
                } else {
                    $status.Text=('Installing extra '+(& $variantLabelOf $p.Key)+'...')
                    [System.Windows.Forms.Application]::DoEvents()
                    if(Test-Path -LiteralPath $p.Target -PathType Container){
                        $oldTarget=Join-Path ([System.IO.Path]::GetDirectoryName($p.Target)) (($p.Key)+'.old-'+$stamp)
                        Move-Item -LiteralPath $p.Target -Destination $oldTarget -Force
                        [void]$log.Add(('Previous extra folder moved aside: '+$p.Target+' -> '+$oldTarget))
                    }
                    New-Item -ItemType Directory -Path $p.Target -Force | Out-Null
                    foreach($src in $filesP){ Copy-Item -LiteralPath $src -Destination (Join-Path $p.Target ([System.IO.Path]::GetFileName($src))) -Force }
                    [void]$log.Add(('Installed extra variant '+$p.Key+' into '+$p.Target))
                }
            }
            # Verify the new engine actually starts BEFORE declaring success:
            # no version output means missing DLLs or a broken exe - restore.
            $status.Text='Checking that the new engine starts...'
            [System.Windows.Forms.Application]::DoEvents()
            $newOut=Get-MossEngineVersionOutput $enginePath
            if([string]::IsNullOrWhiteSpace($newOut)){ throw 'The new engine files were copied, but sd-cli.exe does not start (no version output). The previous engine files will be restored.' }
            $newCommit=''
            if($newOut -match 'commit\s+([0-9a-fA-F]{6,40})'){ $newCommit=$Matches[1].ToLowerInvariant() }
            [void]$log.Add(('New engine version output: '+$newOut))
            $extraLines=''; $extraOk=0; $extraWarn=0
            foreach($p in @($plan | Where-Object { -not $_.IsPrimary })){
                $exeP=Join-Path $p.Target 'sd-cli.exe'
                if(Test-Path -LiteralPath $exeP -PathType Leaf){
                    $oP=Get-MossEngineVersionOutput $exeP
                    if([string]::IsNullOrWhiteSpace($oP)){
                        $extraWarn++
                        $extraLines+=("`r`nWARNING: the extra "+(& $variantLabelOf $p.Key)+" did not start (no version output) - it stays in "+$p.Target+" but may need a different variant.")
                        [void]$log.Add(('WARNING: extra '+$p.Key+' did not report a version'))
                    } else {
                        $extraOk++
                        $extraLines+=("`r`nExtra "+(& $variantLabelOf $p.Key)+": verified working.")
                        [void]$log.Add(('Extra '+$p.Key+' verified: '+$oP))
                    }
                }
            }
            $modelLines=''; $modelOk=0; $modelFail=0
            foreach($mi in $modelPlan){
                try {
                    $status.Text=('Downloading model '+$mi.Name+' ('+[math]::Round($mi.RemoteSize/1GB,2)+' GB)...')
                    [System.Windows.Forms.Application]::DoEvents()
                    [void]$log.Add(('Downloading model '+$mi.RemoteUrl))
                    $mTemp=Join-Path $tempRoot ('model-'+$mi.Name+'.part')
                    Invoke-WebRequest -Uri ([string]$mi.RemoteUrl) -OutFile $mTemp -UseBasicParsing -TimeoutSec 7200
                    $got=(Get-Item -LiteralPath $mTemp).Length
                    if($mi.RemoteSize -gt 0 -and $got -ne $mi.RemoteSize){ throw ('download size mismatch (got '+[math]::Round($got/1GB,2)+' GB, expected '+[math]::Round($mi.RemoteSize/1GB,2)+' GB)') }
                    [void]$log.Add(('Model download ok ('+[math]::Round($got/1GB,2)+' GB)'))
                    $destModel=$mi.LocalPath; if(-not $destModel){ $destModel=Join-Path $script:AppRoot ('models\'+$mi.Name) }
                    if((Test-Path -LiteralPath $destModel -PathType Leaf) -and $modelBackupCheck.Checked){
                        $oldName=([System.IO.Path]::GetFileNameWithoutExtension($destModel))+'.old-'+$stamp+([System.IO.Path]::GetExtension($destModel))
                        Rename-Item -LiteralPath $destModel -Destination (Join-Path ([System.IO.Path]::GetDirectoryName($destModel)) $oldName) -Force
                        [void]$log.Add(('Old model kept as '+$oldName))
                        # Keep at most 3 backups per model: delete the oldest.
                        $oldSiblings=@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($destModel)) -File -Filter (([System.IO.Path]::GetFileNameWithoutExtension($destModel))+'.old-*') -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)
                        for($bi=3; $bi -lt $oldSiblings.Count; $bi++){
                            try { Remove-Item -LiteralPath $oldSiblings[$bi].FullName -Force -ErrorAction Stop; [void]$log.Add(('Deleted old model backup beyond the limit of 3: '+$oldSiblings[$bi].Name)) } catch { [void]$log.Add(('Could not delete old model backup '+$oldSiblings[$bi].Name+': '+$_.Exception.Message)) }
                        }
                    }
                    $status.Text=('Installing model '+$mi.Name+'...')
                    [System.Windows.Forms.Application]::DoEvents()
                    Copy-Item -LiteralPath $mTemp -Destination $destModel -Force
                    Remove-Item -LiteralPath $mTemp -Force -ErrorAction SilentlyContinue
                    $modelOk++
                    $modelLines+=("`r`nModel updated: "+$mi.Name+" ("+[math]::Round($mi.RemoteSize/1GB,2)+" GB)")
                    [void]$log.Add(('Model updated: '+$mi.Name))
                } catch {
                    $modelFail++
                    $modelLines+=("`r`nWARNING: model "+$mi.Name+" could not be updated: "+$_.Exception.Message)
                    [void]$log.Add(('ERROR updating model '+$mi.Name+': '+$_.Exception.Message))
                    try { if($mTemp -and (Test-Path -LiteralPath $mTemp)){ Remove-Item -LiteralPath $mTemp -Force -ErrorAction SilentlyContinue } } catch {}
                }
            }
            $switchHint=''
            if(@($plan | Where-Object { -not $_.IsPrimary }).Count -gt 0){ $switchHint="`r`n`r`nExtra engines are switchable at any time: Hardware / Setup -> Browse -> select that engine's sd-cli.exe." }
            $sameNote=''
            if($newCommit -and $installedCommit -and ($newCommit -eq $installedCommit)){
                $sameNote="`r`nNote: this is the same commit as before - you reinstalled the current version (useful as a repair)."
                [void]$log.Add('Note: the installed commit is unchanged (reinstall)')
            }
            $status.Text=('Done. Engine now: '+$(if($newCommit){'commit '+$newCommit}else{$newOut})+'   -   details in logs\engine-update-'+$stamp+'.txt')
            [System.Windows.Forms.MessageBox]::Show($g,("The update was completed.`r`n`r`nEngine - previous: {0}, now: {1}{2}{3}{4}{5}`r`n`r`nIf anything behaves strangely, you can restore the previous engine files from the compressed backup:`r`n{6}" -f $(if($installedCommit){'commit '+$installedCommit}else{'unknown'}),$(if($newCommit){'commit '+$newCommit}else{$newOut}),$sameNote,$extraLines,$modelLines,$switchHint,$backupZip),'Engine & models updated',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        } catch {
            [void]$log.Add(('ERROR: '+$_.Exception.Message))
            $restoredNote='No files needed restoring - the failure happened before anything was replaced.'
            try {
                $hadBackup=@()
                $restoreStage=''
                if(Test-Path -LiteralPath $backupZip -PathType Leaf){
                    $restoreStage=Join-Path ([System.IO.Path]::GetTempPath()) ('MOSS-Backup-Restore-'+[guid]::NewGuid().ToString('N'))
                    New-Item -ItemType Directory -Path $restoreStage -Force | Out-Null
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($backupZip,$restoreStage)
                    $hadBackup=@(Get-ChildItem -LiteralPath $restoreStage -File)
                } elseif(Test-Path -LiteralPath $backupDir){
                    $hadBackup=@(Get-ChildItem -LiteralPath $backupDir -File)
                }
                if($hadBackup.Count -gt 0){
                    foreach($bak in $hadBackup){ Copy-Item -LiteralPath $bak.FullName -Destination (Join-Path $engineBin $bak.Name) -Force }
                    # Verify the previous engine works again after the restore.
                    $bakOut=Get-MossEngineVersionOutput $enginePath
                    if(-not [string]::IsNullOrWhiteSpace($bakOut)){
                        $restoredNote='The previous engine files were restored and verified working again.'
                        [void]$log.Add('Previous engine verified working after restore')
                    } else {
                        $restoredNote='The previous engine files were restored, but sd-cli.exe still does not report a version - copy the files back manually from the backup archive if needed.'
                        [void]$log.Add(('WARNING: the previous engine did not report a version after restore'))
                    }
                }
            } catch { [void]$log.Add(('ERROR during restore: '+$_.Exception.Message)) }
            $status.Text=('Engine update failed: '+$_.Exception.Message)
            [System.Windows.Forms.MessageBox]::Show($g,("The engine update failed: {0}`r`n`r`n{1}`r`n`r`nDetails: logs\engine-update-{2}.txt" -f $_.Exception.Message,$restoredNote,$stamp),'Engine update failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        } finally {
            $g.Cursor='Default'; $installBtn.Enabled=$true; $pageBtn.Enabled=$true; $closeBtn.Enabled=$true; $ProgressPreference=$oldProgress
            try { $logDir=Join-Path $script:AppRoot 'logs'; if(-not(Test-Path -LiteralPath $logDir)){New-Item -ItemType Directory -Path $logDir -Force|Out-Null}; ($log -join "`r`n") | Set-Content -LiteralPath (Join-Path $logDir ('engine-update-'+$stamp+'.txt')) -Encoding UTF8 } catch {}
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    })
    [void]$g.ShowDialog($Owner)
}
function Show-GeneratorWindow {
    $defaultOutput=Join-Path $script:AppRoot 'outputs'
    if(-not(Test-Path -LiteralPath $defaultOutput)){New-Item -ItemType Directory -Path $defaultOutput -Force|Out-Null}
    # Migrate the pre-0.1.15 default 'outputs\admin' to the standard 'outputs'.
    # Custom folders chosen by the user are never touched.
    $savedOutput=[string]$script:Settings.OutputPath
    if(-not [string]::IsNullOrWhiteSpace($savedOutput)){
        try {
            $savedFull=[System.IO.Path]::GetFullPath((Get-AbsoluteAppPath $savedOutput))
            $legacyAdmin=[System.IO.Path]::GetFullPath((Join-Path $script:AppRoot 'outputs\admin'))
            if($savedFull.TrimEnd('\','/') -ieq $legacyAdmin.TrimEnd('\','/')){ $script:Settings.OutputPath='outputs' }
        } catch {}
    }
    if([string]::IsNullOrWhiteSpace([string]$script:Settings.OutputPath)){ $script:Settings.OutputPath='outputs' }
    $script:Settings.OutputPath=Get-RelativeAppPath ([string]$script:Settings.OutputPath)
    $defaults = [ordered]@{
        DiffusionModelPath = (Join-Path $script:AppRoot 'models\moss_image_sft_int8_convrot.safetensors')
        LlmPath = (Join-Path $script:AppRoot 'models\Qwen3.5-9B-Q4_K_M.gguf')
        VaePath = (Join-Path $script:AppRoot 'models\flux2-vae.safetensors')
        TokenizerPath = (Join-Path $script:AppRoot 'models\tokenizer_qwen3.5.json')
        OutputPath = $script:Settings.OutputPath
        Steps = 25; CfgScale = 3.0; Width = 1360; Height = 768; ImageCount = 1; Seed = -1
        NegativePrompt = ''; SamplingMethod = 'Default (model)'; Scheduler = 'Default (model)'; ImproveStrength = '0.6'
    }
    foreach ($key in $defaults.Keys) { if (-not $script:Settings.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$script:Settings[$key])) { $script:Settings[$key] = $defaults[$key] } }
    # Resolve saved model paths against the portable app folder. If an old
    # absolute path no longer exists, reuse the matching file in this app's models folder.
    foreach ($key in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')) {
        $savedPath = Get-AbsoluteAppPath ([string]$script:Settings[$key])
        if (-not (Test-Path -LiteralPath $savedPath -PathType Leaf)) {
            $portablePath = Join-Path (Join-Path $script:AppRoot 'models') ([System.IO.Path]::GetFileName([string]$script:Settings[$key]))
            if (Test-Path -LiteralPath $portablePath -PathType Leaf) { $script:Settings[$key] = Get-RelativeAppPath $portablePath }
        }
    }
    $history = @()
    if ($script:HistoryEnabled -and -not $script:HistoryLocked -and $script:Settings.PromptHistory) { $history = @($script:Settings.PromptHistory) }
    $script:GeneratedFiles = New-Object System.Collections.ArrayList
    $script:SelectedFile = $null
    $script:RefineQueue = New-Object System.Collections.ArrayList
    $script:RefineTotal = 0

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "MOSS Image Studio v$($script:AppVersion) (GUI for sd-cli) | Generator"; $f.Size = New-Object System.Drawing.Size(1180,850); $f.MinimumSize = New-Object System.Drawing.Size(1000,740); $f.StartPosition='CenterScreen'
    $f.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $f.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $f.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cPanel=[System.Drawing.Color]::FromArgb(25,32,45); $cCard=[System.Drawing.Color]::FromArgb(27,34,47); $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185); $cAccent=[System.Drawing.Color]::FromArgb(45,112,173)

    $head=New-Object System.Windows.Forms.Panel; $head.Dock='Top'; $head.Height=68; $head.BackColor=$cPanel; $f.Controls.Add($head)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text="MOSS  /  IMAGE STUDIO  v$($script:AppVersion)"; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(20,9); $head.Controls.Add($ttl)
    $gpuSubtitle='GPU: automatic'
    if($script:Settings.Contains('PreferredGpuIndex') -and [int]$script:Settings.PreferredGpuIndex -ge 0){ $gpuSubtitle="GPU: $($script:Settings.PreferredGpuName)" }
    $subt=New-Object System.Windows.Forms.Label; $subt.Text="LOCAL IMAGE GENERATION  -  $gpuSubtitle"; $subt.ForeColor=$cMuted; $subt.AutoSize=$true; $subt.Location=New-Object System.Drawing.Point(23,42); $head.Controls.Add($subt)
    $backendText=[string]$script:Settings.Backend; if (-not $script:Settings.BackendSelectionSaved) { $backendText='Not configured' }
    $backendBadge=New-Object System.Windows.Forms.Label; $backendBadge.Text="BACKEND  $backendText"; $backendBadge.AutoSize=$true; $backendBadge.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164); $backendBadge.Location=New-Object System.Drawing.Point(535,25); $backendBadge.Anchor='Top,Right'; $head.Controls.Add($backendBadge)
    $setupBtn=New-Object System.Windows.Forms.Button; $setupBtn.Text='Hardware / Setup'; $setupBtn.Size=New-Object System.Drawing.Size(130,30); $setupBtn.Location=New-Object System.Drawing.Point(1025,18); $setupBtn.Anchor='Top,Right'; $setupBtn.FlatStyle='Flat'; $setupBtn.BackColor=$cAccent; $setupBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($setupBtn)
    $setupBtn.Add_Click({ $f.Tag='SETUP'; $f.Close() })
$headTip=New-Object System.Windows.Forms.ToolTip; $headTip.InitialDelay=300
$updateBtn=New-Object System.Windows.Forms.Button; $updateBtn.Text='Update MOSS...'; $updateBtn.Size=New-Object System.Drawing.Size(130,30); $updateBtn.Location=New-Object System.Drawing.Point(880,18); $updateBtn.Anchor='Top,Right'; $updateBtn.FlatStyle='Flat'; $updateBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $updateBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($updateBtn)
$headTip.SetToolTip($updateBtn,"Updates the MOSS application itself (the program files). Models, outputs and the sd-cli engine are not touched. Use 'Update engine...' for the rendering engine.")
$engineBtn=New-Object System.Windows.Forms.Button; $engineBtn.Text='Update engine...'; $engineBtn.Size=New-Object System.Drawing.Size(130,30); $engineBtn.Location=New-Object System.Drawing.Point(735,18); $engineBtn.Anchor='Top,Right'; $engineBtn.FlatStyle='Flat'; $engineBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $engineBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($engineBtn)
$headTip.SetToolTip($engineBtn,'Updates the sd-cli engine core files (the renderer in the bin folder): shows release changelogs and installs the newest engine build. MOSS itself is not changed.')
$engineBtn.Add_Click({ Show-MossEngineUpdateDialog $f })
$updateBtn.Add_Click({
    $release=$null
    try {
        [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
        $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/kukomamasan/moss-image-studio/releases/latest' -Method Get -Headers @{Accept='application/vnd.github+json';'User-Agent'='MOSS-Image-Studio'} -TimeoutSec 8
    } catch { $release=$null }
    if($release -and $release.tag_name){
        $latestVersion=$null; $currentVersion=$null; $tagText=([string]$release.tag_name).TrimStart('v','V')
        if([version]::TryParse($tagText,[ref]$latestVersion) -and [version]::TryParse([string]$script:AppVersion,[ref]$currentVersion)){
            if($latestVersion -eq $currentVersion){[System.Windows.Forms.MessageBox]::Show("MOSS is up to date (v$($script:AppVersion)).",'MOSS updates',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return}
            if($latestVersion -lt $currentVersion){[System.Windows.Forms.MessageBox]::Show("This MOSS build (v$($script:AppVersion)) is newer than the latest published release (v$tagText).",'MOSS updates',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return}
            $answer=[System.Windows.Forms.MessageBox]::Show("A new MOSS version is available: v$tagText (you have v$($script:AppVersion)). Download and install it now? MOSS will close, replace the app files, keep config/models/outputs, and restart.",'MOSS update available',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information)
            if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
            $asset=@($release.assets | Where-Object { $_.name -eq 'MOSS-Image-Studio.zip' } | Select-Object -First 1)
            if(-not $asset){ $asset=@($release.assets | Where-Object { [string]$_.name -like 'MOSS-Image-Studio*.zip' } | Select-Object -First 1) }
            if(-not $asset -or -not $asset[0].browser_download_url){[System.Windows.Forms.MessageBox]::Show('This release does not include MOSS-Image-Studio.zip, so MOSS cannot install it automatically.','MOSS updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return}
            try {
                $tempRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('MOSS-Update-'+[guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
                $zipPath=Join-Path $tempRoot 'MOSS-Image-Studio.zip'
                Invoke-WebRequest -Uri ([string]$asset[0].browser_download_url) -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive=[System.IO.Compression.ZipFile]::OpenRead($zipPath)
                try {
                    $archiveNames=@($archive.Entries | ForEach-Object { $_.FullName })
                    $allowedNames=@('MOSS-Image-Studio.ps1','MOSS-Image-Studio.bat','MOSS-Image-Studio.vbs','README.txt')
                    if($archiveNames -notcontains 'MOSS-Image-Studio.ps1' -or @($archiveNames | Where-Object { $_ -notin $allowedNames }).Count -gt 0){throw 'The release ZIP contains unexpected files.'}
                } finally { $archive.Dispose() }
                $helperPath=Join-Path $tempRoot 'Install-MOSS-Update.ps1'
                $helperBody=@'
param([int]$ProcessId,[string]$AppRoot,[string]$ZipPath,[string]$TempRoot)
$ErrorActionPreference='Stop'
try {
    $running=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if($running){$running.WaitForExit()}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Windows.Forms
    $stage=Join-Path $TempRoot 'stage'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath,$stage)
    $allowed=@('MOSS-Image-Studio.ps1','MOSS-Image-Studio.bat','MOSS-Image-Studio.vbs','README.txt')
    $backup=Join-Path $TempRoot 'backup'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach($name in $allowed){$current=Join-Path $AppRoot $name;if(Test-Path -LiteralPath $current -PathType Leaf){Copy-Item -LiteralPath $current -Destination (Join-Path $backup $name) -Force}}
    try {foreach($name in $allowed){$source=Join-Path $stage $name;if(Test-Path -LiteralPath $source -PathType Leaf){Copy-Item -LiteralPath $source -Destination (Join-Path $AppRoot $name) -Force}}}
    catch {foreach($name in $allowed){$saved=Join-Path $backup $name;if(Test-Path -LiteralPath $saved -PathType Leaf){Copy-Item -LiteralPath $saved -Destination (Join-Path $AppRoot $name) -Force}};throw}
    $launcher=Join-Path $AppRoot 'MOSS-Image-Studio.vbs'
    if(Test-Path -LiteralPath $launcher){Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"'+$launcher+'"')}
} catch {
    [System.Windows.Forms.MessageBox]::Show(('MOSS update failed: '+$_.Exception.Message),'MOSS updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
} finally {Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue}
'@
                Set-Content -LiteralPath $helperPath -Value $helperBody -Encoding UTF8
                $helperArgs='-NoProfile -ExecutionPolicy Bypass -File "'+$helperPath+'" -ProcessId '+[string]$PID+' -AppRoot "'+$script:AppRoot+'" -ZipPath "'+$zipPath+'" -TempRoot "'+$tempRoot+'"'
                $powershellExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Start-Process -FilePath $powershellExe -ArgumentList $helperArgs -WindowStyle Hidden | Out-Null
                [System.Windows.Forms.MessageBox]::Show("MOSS v$tagText is downloaded. This window will close while the app files are replaced; MOSS will restart when the update is complete.",'MOSS updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
                $f.Close()
                return
            } catch {
                [System.Windows.Forms.MessageBox]::Show(('MOSS could not download or prepare the update: '+$_.Exception.Message),'MOSS updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
                if($tempRoot -and (Test-Path -LiteralPath $tempRoot)){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
                return
            }
        } else {[System.Windows.Forms.MessageBox]::Show("MOSS found release '$($release.tag_name)' but could not compare its version automatically.",'MOSS updates',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null}
    } else {
        $answer=[System.Windows.Forms.MessageBox]::Show("MOSS could not read the GitHub release feed. Open the releases page to check manually? The automatic updater needs publicly readable releases.",'MOSS update check',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
    }
    try { Start-Process 'https://github.com/kukomamasan/moss-image-studio/releases/latest' } catch { [System.Windows.Forms.MessageBox]::Show('The releases page could not be opened. Go to the MOSS repository on GitHub and open Releases.','MOSS updates')|Out-Null }
})

    $left=New-Object System.Windows.Forms.Panel; $left.Location=New-Object System.Drawing.Point(18,84); $left.Size=New-Object System.Drawing.Size(700,710); $left.Anchor='Top,Bottom,Left'; $left.BackColor=$cCard; $f.Controls.Add($left)
    $right=New-Object System.Windows.Forms.Panel; $right.Location=New-Object System.Drawing.Point(735,84); $right.Size=New-Object System.Drawing.Size(415,710); $right.Anchor='Top,Bottom,Left,Right'; $right.BackColor=$cCard; $f.Controls.Add($right)
    function Add-Label($parent,[string]$text,[int]$x,[int]$y,[int]$w=200) { $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,22); $l.ForeColor=$cMuted; $parent.Controls.Add($l); return $l }
    function Add-TextBox($parent,[string]$value,[int]$x,[int]$y,[int]$w,[int]$h=26) { $t=New-Object System.Windows.Forms.TextBox; $t.Text=$value; $t.Location=New-Object System.Drawing.Point($x,$y); $t.Size=New-Object System.Drawing.Size($w,$h); $t.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $t.ForeColor=$cText; $t.BorderStyle='FixedSingle'; $parent.Controls.Add($t); return $t }
    function Add-Button($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h=29) { $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location=New-Object System.Drawing.Point($x,$y); $b.Size=New-Object System.Drawing.Size($w,$h); $b.FlatStyle='Flat'; $b.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $b.ForeColor=$cText; $parent.Controls.Add($b); return $b }

    Add-Label $left 'PROMPT' 18 14 180 | Out-Null
    $historyPick=New-Object System.Windows.Forms.ComboBox; $historyPick.DropDownStyle='DropDownList'; $historyPick.Location=New-Object System.Drawing.Point(315,9); $historyPick.Size=New-Object System.Drawing.Size(150,27); $historyPick.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $historyPick.ForeColor=$cText; $left.Controls.Add($historyPick)
    $resetHistoryCode=Add-Button $left 'History code...' 471 8 90 28
    $resetHistoryCode.Add_Click({ if(Reset-MossHistoryPassword $f){$history=@();$historyPick.Items.Clear();[System.Windows.Forms.MessageBox]::Show('New history code saved. The old history was cleared.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
    $resetHistoryCode.Enabled=$true
    foreach($oldPrompt in @($history | Select-Object -First 10)){[void]$historyPick.Items.Add([string]$oldPrompt)}
    $paste=Add-Button $left 'Paste' 567 8 95 28
    $paste.Enabled=$true
    $prompt=New-Object System.Windows.Forms.TextBox; $prompt.Multiline=$true; $prompt.AcceptsReturn=$true; $prompt.AcceptsTab=$true; $prompt.ScrollBars='Vertical'; $prompt.Location=New-Object System.Drawing.Point(18,39); $prompt.Size=New-Object System.Drawing.Size(662,150); $prompt.Anchor='Top,Left,Right'; $prompt.Font=New-Object System.Drawing.Font('Segoe UI',10); $prompt.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $prompt.ForeColor=$cText; $prompt.BorderStyle='FixedSingle'; $left.Controls.Add($prompt)
    $prompt.ReadOnly=$false
    $paste.Add_Click({ try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $clipText=[System.Windows.Forms.Clipboard]::GetText(); $prompt.Text=$clipText; $status.Text=('Pasted {0} characters from clipboard.' -f $clipText.Length) } else { $status.Text='The clipboard does not contain any text.' } } catch { [System.Windows.Forms.MessageBox]::Show('Clipboard text could not be read.','Clipboard') | Out-Null } })
    $historyPick.Add_SelectedIndexChanged({if($historyPick.SelectedIndex -ge 0){$prompt.Text=[string]$historyPick.SelectedItem}})
    function Unlock-MossHistoryAfterShow {
        # The history code prompt appears after the main window is visible, so
        # it opens in context over MOSS instead of floating alone at startup.
        if (-not $script:LockedHistoryEnvelope) { return }
        while ($true) {
            $candidate = Get-MossHistoryPassphrase $false 'history' $f
            if ($candidate) {
                try {
                    $plain = Unprotect-MossPayload ([string]$script:LockedHistoryEnvelope) $candidate
                    $script:HistoryPassphrase = $candidate
                    $script:Settings.PromptHistory = @($plain | ConvertFrom-Json)
                    $script:HistoryLocked = $false
                    $script:LockedHistoryEnvelope = $null
                    $historyPick.Items.Clear()
                    foreach($oldPrompt in @($script:Settings.PromptHistory | Select-Object -First 10)){ [void]$historyPick.Items.Add([string]$oldPrompt) }
                    # Legacy CPU fallback migration (same as in Load-Settings,
                    # which returns early while the history is locked).
                    if ($script:Settings.Backend -eq 'CPU' -and -not [bool]$script:Settings.BackendSelectionSaved) { $script:Settings.Backend = 'Auto' }
                    return
                } catch { $script:HistoryPassphrase = $null }
            }
            $choice = Show-MossHistoryRecoveryChoice
            if($choice -eq 'retry'){continue}
            if($choice -eq 'skip'){$script:HistoryLocked=$true;$script:Settings.PromptHistory=@();[System.Windows.Forms.MessageBox]::Show('MOSS will continue without prompt history. The encrypted history is preserved.','History locked')|Out-Null;return}
            if($choice -eq 'reset'){if(Reset-MossHistoryPassword $f){$historyPick.Items.Clear();return};continue}
            if($choice -eq 'disable'){if(Disable-MossHistory){$historyPick.Items.Clear();return};continue}
        }
    }

    Add-Label $left 'IMAGE SETTINGS' 18 202 160 | Out-Null
    $negInitial=if([string]$script:Settings.NegativePrompt){'negative prompt: set'}else{'negative prompt: not set'}
    $negState=Add-Label $left $negInitial 310 202 240
    function Show-MossGenerationOptionsDialog {
        # Advanced generation options in one dialog so the compact main window
        # stays uncluttered: negative prompt (engine flag -n), sampler and
        # scheduler. 'Default (model)' omits the flag so the engine keeps its
        # model-specific choice (euler for Flux/SD3/Wan).
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Generation options'; $g.Size=New-Object System.Drawing.Size(560,530); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $hint=New-Object System.Windows.Forms.Label; $hint.Text='Negative prompt - what the image should NOT contain, e.g. blurry, extra fingers, watermark. Left empty = none.'; $hint.Location=New-Object System.Drawing.Point(12,10); $hint.Size=New-Object System.Drawing.Size(520,20); $hint.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($hint)
        $box=New-Object System.Windows.Forms.TextBox; $box.Multiline=$true; $box.ScrollBars='Vertical'; $box.Text=[string]$script:Settings.NegativePrompt; $box.Location=New-Object System.Drawing.Point(12,34); $box.Size=New-Object System.Drawing.Size(520,120); $box.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $box.ForeColor=$cText; $box.BorderStyle='FixedSingle'; $g.Controls.Add($box)
        Add-Label $g 'Sampler' 12 170 100 | Out-Null
        $optSampler=New-Object System.Windows.Forms.ComboBox; $optSampler.DropDownStyle='DropDownList'; $optSampler.Location=New-Object System.Drawing.Point(12,192); $optSampler.Size=New-Object System.Drawing.Size(250,26); $optSampler.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $optSampler.ForeColor=$cText
        foreach($s in @('Default (euler)','euler','euler_a','heun','dpm2','dpm++2s_a','dpm++2m','dpm++2mv2','ipndm','ipndm_v','lcm','ddim_trailing','tcd','res_multistep','res_2s','er_sde','euler_cfg_pp','euler_a_cfg_pp','euler_ge','dpm++2m_sde','dpm++2m_sde_bt','lms')){[void]$optSampler.Items.Add($s)}
        $storedSampler=[string]$script:Settings.SamplingMethod; if($storedSampler -eq 'Default (model)'){$storedSampler='Default (euler)'}
        $optSampler.SelectedItem=$storedSampler; if($optSampler.SelectedIndex -lt 0){$optSampler.SelectedIndex=0}; $g.Controls.Add($optSampler)
        Add-Label $g 'Scheduler' 280 170 100 | Out-Null
        $optSched=New-Object System.Windows.Forms.ComboBox; $optSched.DropDownStyle='DropDownList'; $optSched.Location=New-Object System.Drawing.Point(280,192); $optSched.Size=New-Object System.Drawing.Size(250,26); $optSched.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $optSched.ForeColor=$cText
        foreach($s in @('Default (flux schedule)','discrete','karras','exponential','ays','gits','sgm_uniform','simple','smoothstep','kl_optimal','lcm','bong_tangent','ltx2','logit_normal','flux2','flux','beta','llada_image')){[void]$optSched.Items.Add($s)}
        $storedSched=[string]$script:Settings.Scheduler; if($storedSched -eq 'Default (model)'){$storedSched='Default (flux schedule)'}
        $optSched.SelectedItem=$storedSched; if($optSched.SelectedIndex -lt 0){$optSched.SelectedIndex=0}; $g.Controls.Add($optSched)
        # Plain-language descriptions: shown inline below each dropdown and on
        # hover, updated as the user browses the lists.
        $samplerDescriptions=@{
          'Default (euler)'="Uses the engine's default for this model: euler. Recommended."
          'euler'='Simple, reliable all-rounder; good at any step count.'
          'euler_a'='Ancestral euler: adds randomness each step - more variety, but the same seed can give slightly different images.'
          'heun'='More accurate per step, but roughly twice the work per step.'
          'dpm2'='Deterministic second-order solver: crisp, sensitive to step count.'
          'dpm++2s_a'='Ancestral second-order solver: sharp detail with some randomness.'
          'dpm++2m'='Fast, converging solver; very good quality at moderate steps.'
          'dpm++2mv2'='Improved variant of dpm++2m, often a little more detail.'
          'ipndm'='Improved pseudo-numerical method: smooth and conservative.'
          'ipndm_v'='Variant of ipndm with a different update schedule.'
          'lcm'='Latent Consistency sampling: tuned for very few steps (4-8) on distilled models.'
          'ddim_trailing'='DDIM sampled from the end of the schedule; useful for some distilled models.'
          'tcd'='Trajectory Consistency Distillation: few-step friendly.'
          'res_multistep'='Resolution multistep solver: detailed but slower.'
          'res_2s'='Two-step variant of the resolution multistep solver.'
          'er_sde'='Extended reverse-time SDE: often good texture and detail.'
          'euler_cfg_pp'='Euler with CFG++ guidance handling; can reduce burning at high CFG.'
          'euler_a_cfg_pp'='Ancestral euler with CFG++ guidance handling.'
          'euler_ge'='Euler with geometric extrapolation.'
          'dpm++2m_sde'='dpm++2m in stochastic form: often softer, painterly detail.'
          'dpm++2m_sde_bt'='Stochastic dpm++2m with Brownian-tree noise.'
          'lms'='Linear multistep: classic, conservative solver.'
        }
        $schedulerDescriptions=@{
          'Default (flux schedule)'="Uses the engine's default for this model: a Flux-family sigma schedule, chosen automatically. Recommended."
          'discrete'='Classic discrete sigma schedule (the traditional default).'
          'karras'='Karras schedule: more steps on fine detail near the end; often sharper texture.'
          'exponential'='Exponential sigma spacing: smooth, even denoising.'
          'ays'='Align Your Steps: optimized step placement, good with fewer steps.'
          'gits'='GITS: trained step distribution, good quality at low step counts.'
          'sgm_uniform'='Uniform schedule from the SGM paper: even coverage of the range.'
          'simple'='Plain uniform sigma spacing.'
          'smoothstep'='Smoothstep spacing: gentler start and finish.'
          'kl_optimal'='Schedule from KL-diffusion optimization research.'
          'lcm'='Schedule matched to LCM (few-step distilled) sampling.'
          'bong_tangent'='Aggressive experimental schedule: can be very fast or unstable.'
          'ltx2'='Schedule tuned for LTX video models.'
          'logit_normal'='Sigmas from a logit-normal distribution: modern Flux-family schedule.'
          'flux2'='Schedule tuned for the newer Flux models; a good fit for this engine.'
          'flux'='Original Flux schedule.'
          'beta'='Beta-distribution spacing: modern alternative, often good detail.'
          'llada_image'='Schedule tuned for the LLaDA image model.'
        }
        $dlgTip=New-Object System.Windows.Forms.ToolTip; $dlgTip.InitialDelay=200
        $samplerDesc=New-Object System.Windows.Forms.Label; $samplerDesc.Location=New-Object System.Drawing.Point(12,222); $samplerDesc.Size=New-Object System.Drawing.Size(250,64); $samplerDesc.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($samplerDesc)
        $schedDesc=New-Object System.Windows.Forms.Label; $schedDesc.Location=New-Object System.Drawing.Point(280,222); $schedDesc.Size=New-Object System.Drawing.Size(250,64); $schedDesc.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($schedDesc)
        $samplerDesc.Text=[string]$samplerDescriptions[[string]$optSampler.SelectedItem]
        $schedDesc.Text=[string]$schedulerDescriptions[[string]$optSched.SelectedItem]
        $dlgTip.SetToolTip($optSampler,$samplerDesc.Text); $dlgTip.SetToolTip($optSched,$schedDesc.Text)
        $optSampler.Add_SelectedIndexChanged({ $samplerDesc.Text=[string]$samplerDescriptions[[string]$optSampler.SelectedItem]; $dlgTip.SetToolTip($optSampler,$samplerDesc.Text) })
        $optSched.Add_SelectedIndexChanged({ $schedDesc.Text=[string]$schedulerDescriptions[[string]$optSched.SelectedItem]; $dlgTip.SetToolTip($optSched,$schedDesc.Text) })
        Add-Label $g 'Improve strength' 12 292 200 | Out-Null
        $impStrengthBox=Add-TextBox $g ([string]$script:Settings.ImproveStrength) 12 314 100
        $impStrengthHint=New-Object System.Windows.Forms.Label; $impStrengthHint.Text='How strongly an image is re-rendered when improving it. 0.45 keeps the look; 0.6 refreshes detail; 0.8 re-renders strongly.'; $impStrengthHint.Location=New-Object System.Drawing.Point(120,317); $impStrengthHint.Size=New-Object System.Drawing.Size(412,46); $impStrengthHint.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($impStrengthHint)
        $dlgTip.SetToolTip($impStrengthBox,'Improvement strength: how freely the image is re-rendered when improving. Low keeps it mostly as it is; high repaints more. Fast previews automatically use at least 0.5-0.74 regardless of this setting.')
        $note=New-Object System.Windows.Forms.Label; $note.Text="'Default (euler)' and 'Default (flux schedule)' use the engine's own choice - recommended unless you want to experiment. Quick improve reuses the image's own settings; 'Improve using the settings in the main window' applies the values you see now."; $note.Location=New-Object System.Drawing.Point(12,392); $note.Size=New-Object System.Drawing.Size(520,34); $note.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($note)
        # MOSS is a GUI front-end for the sd-cli command-line engine: optionally
        # log the exact command line before every run (full transparency).
        $cmdCheck=New-Object System.Windows.Forms.CheckBox; $cmdCheck.Text='Show the exact sd-cli command line in the generation log (see what MOSS runs)'; $cmdCheck.Location=New-Object System.Drawing.Point(12,364); $cmdCheck.Size=New-Object System.Drawing.Size(520,24); $cmdCheck.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($cmdCheck)
        $cmdCheck.Checked= (-not $script:Settings.Contains('ShowEngineCommandLine')) -or ([string]$script:Settings.ShowEngineCommandLine -eq '1')
        $negOk=Add-Button $g 'Save' 350 434 80 30
        $negCancel=Add-Button $g 'Cancel' 440 434 90 30
        $negOk.Add_Click({
            $impCheck=0.0
            $script:Settings.NegativePrompt=($box.Text -replace "(\r?\n)+",' ').Trim()
            $saveSampler=[string]$optSampler.SelectedItem; if($saveSampler -eq 'Default (euler)'){$saveSampler='Default (model)'}
            $saveSched=[string]$optSched.SelectedItem; if($saveSched -eq 'Default (flux schedule)'){$saveSched='Default (model)'}
            $script:Settings.SamplingMethod=$saveSampler
            $script:Settings.Scheduler=$saveSched
            if(-not (ConvertTo-MossDouble $impStrengthBox.Text ([ref]$impCheck)) -or $impCheck -lt 0.05 -or $impCheck -gt 0.95){[System.Windows.Forms.MessageBox]::Show('Improve strength must be between 0.05 and 0.95 (use a dot or a comma for decimals, e.g. 0.6 or 0,6).','Invalid strength')|Out-Null;return}
            $script:Settings.ImproveStrength=ConvertFrom-MossDouble $impCheck
            $script:Settings.ShowEngineCommandLine= if($cmdCheck.Checked){'1'}else{'0'}
            $negState.Text=if($script:Settings.NegativePrompt){('negative prompt: set ('+$script:Settings.NegativePrompt.Length+' chars)')}else{'negative prompt: not set'}
            $g.Close()
        })
        $negCancel.Add_Click({$g.Close()})
        [void]$g.ShowDialog($f)
    }
    $negBtn=Add-Button $left 'Options...' 200 199 100 27
    $negBtn.Add_Click({ Show-MossGenerationOptionsDialog })
    Add-Label $left 'VISUAL STYLE' 18 231 130 | Out-Null
    $style=New-Object System.Windows.Forms.ComboBox; $style.DropDownStyle='DropDownList'; $style.Location=New-Object System.Drawing.Point(18,254); $style.Size=New-Object System.Drawing.Size(250,28); $style.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $style.ForeColor=$cText; foreach($item in @('None (no style)','Photorealistic','Anime','Digital illustration','Oil painting','Watercolor','3D render','Comic book','Cinematic','Fantasy art','Dark fantasy / gothic','Cyberpunk / sci-fi','Studio portrait','Sketch / pencil drawing','Pixel art','Synthwave / retro 80s','Low poly 3D')){[void]$style.Items.Add($item)}; $style.SelectedItem=[string]$script:Settings.ImageStyle; if($style.SelectedIndex -lt 0){$style.SelectedIndex=0}; $left.Controls.Add($style)
    Add-Label $left 'Resolution' 300 231 90 | Out-Null
    $res=New-Object System.Windows.Forms.ComboBox; $res.DropDownStyle='DropDownList'; $res.Location=New-Object System.Drawing.Point(300,254); $res.Size=New-Object System.Drawing.Size(250,28); $res.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $res.ForeColor=$cText
    $resItems=@('Landscape 16:9  |  1360 x 768','Square  |  1024 x 1024','Portrait 3:4  |  768 x 1024','Landscape 4:3  |  1280 x 960','Portrait 9:16  |  768 x 1360','2K Landscape  |  2560 x 1440','2K Square  |  2048 x 2048','2K Portrait  |  1536 x 2048','2K 4:3  |  2048 x 1536','2K 9:16  |  1440 x 2560','4K Landscape  |  3840 x 2160','4K Square  |  4096 x 4096','4K Portrait  |  3072 x 4096','4K 4:3  |  4096 x 3072','4K 9:16  |  2160 x 3840','Custom dimensions')
    foreach($ri in $resItems){[void]$res.Items.Add($ri)}; $left.Controls.Add($res)
    $wBox=Add-TextBox $left ([string]$script:Settings.Width) 300 314 82; $hBox=Add-TextBox $left ([string]$script:Settings.Height) 395 314 82
    Add-Label $left 'Width' 300 291 80 | Out-Null; Add-Label $left 'Height' 395 291 80 | Out-Null
    $resMap=@(@(1360,768),@(1024,1024),@(768,1024),@(1280,960),@(768,1360),@(2560,1440),@(2048,2048),@(1536,2048),@(2048,1536),@(1440,2560),@(3840,2160),@(4096,4096),@(3072,4096),@(4096,3072),@(2160,3840))
    $matched=-1; for($ri=0;$ri -lt $resMap.Count;$ri++){if([int]$script:Settings.Width -eq $resMap[$ri][0] -and [int]$script:Settings.Height -eq $resMap[$ri][1]){$matched=$ri;break}}; if($matched -ge 0){$res.SelectedIndex=$matched}else{$res.SelectedIndex=15}
    $res.Add_SelectedIndexChanged({ if($res.SelectedIndex -ge 0 -and $res.SelectedIndex -lt $resMap.Count){$wBox.Text=[string]$resMap[$res.SelectedIndex][0];$hBox.Text=[string]$resMap[$res.SelectedIndex][1]} })
    Add-Label $left 'Steps' 18 344 70 | Out-Null; $steps=Add-TextBox $left ([string]$script:Settings.Steps) 18 367 75
    Add-Label $left 'CFG scale' 110 344 90 | Out-Null; $cfg=Add-TextBox $left ([string]$script:Settings.CfgScale) 110 367 62
    $cfgHelp=Add-Button $left '?' 174 367 20 26
    $cfgHelp.Add_Click({
        [System.Windows.Forms.MessageBox]::Show("CFG scale (Classifier-Free Guidance) controls how strictly the image follows your prompt.`r`n`r`n- Low (1-4): more artistic freedom, softer prompt adherence. This model is tuned for this range - the default 3 suits it well.`r`n- Medium (5-10): stronger prompt following; colors and contrast grow.`r`n- High (15-30): forces the prompt hard - often causes burned, oversaturated or distorted images.`r`n`r`nRule of thumb: raise it only if the image ignores parts of your prompt; lower it if images look overcooked.",'What is CFG scale?',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    })
    Add-Label $left 'Images' 202 344 70 | Out-Null; $count=New-Object System.Windows.Forms.ComboBox; $count.DropDownStyle='DropDown'; $count.Location=New-Object System.Drawing.Point(202,367); $count.Size=New-Object System.Drawing.Size(75,26); foreach($n in @(1,2,4,8,16,32,64,128,256,512,1000)){[void]$count.Items.Add([string]$n)}; $count.Text=[string]$script:Settings.ImageCount; $left.Controls.Add($count)
    Add-Label $left 'Seed (-1 = random)' 300 344 150 | Out-Null; $seed=Add-TextBox $left ([string]$script:Settings.Seed) 300 367 90
    $speedCombo=New-Object System.Windows.Forms.ComboBox; $speedCombo.DropDownStyle='DropDownList'; $speedCombo.Location=New-Object System.Drawing.Point(410,367); $speedCombo.Size=New-Object System.Drawing.Size(270,24); $speedCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $speedCombo.ForeColor=$cText; foreach($si in @('Exact (full quality)','~2x faster (upscale from 70%)','~4x faster (upscale from 50%)','~8x faster (upscale from 35%)','Fastest (upscale from smallest)')){[void]$speedCombo.Items.Add($si)}; $speedCombo.SelectedIndex=0; $left.Controls.Add($speedCombo)
    $speedHint=New-Object System.Windows.Forms.Label; $speedHint.Text='Faster settings render the image small and enlarge it - quick drafts, never distorted. Exact = full quality at full size and full steps.'; $speedHint.Location=New-Object System.Drawing.Point(410,392); $speedHint.Size=New-Object System.Drawing.Size(270,30); $speedHint.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $left.Controls.Add($speedHint)
    Add-Label $left 'OUTPUT FOLDER' 18 404 190 | Out-Null
    $out=Add-TextBox $left ([string]$script:Settings.OutputPath) 18 429 540; $out.Anchor='Top,Left,Right'; $out.ReadOnly=$true; $outBrowse=Add-Button $left 'Browse...' 570 428 110; $outBrowse.Anchor='Top,Right'; $outBrowse.Enabled=$true
    $outBrowse.Add_Click({
        $dlg=New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description='Select the output folder for generated images.'
        $dlg.ShowNewFolderButton=$true
        $current=Get-AbsoluteAppPath $out.Text
        if(Test-Path -LiteralPath $current -PathType Container){$dlg.SelectedPath=$current}
        elseif(-not [string]::IsNullOrWhiteSpace($current)){
            $currentParent=Split-Path -Parent $current
            if(Test-Path -LiteralPath $currentParent -PathType Container){$dlg.SelectedPath=$currentParent}
        }
        if($dlg.ShowDialog($f) -eq 'OK'){$out.Text=$dlg.SelectedPath}
        $dlg.Dispose()
    }.GetNewClosure())

    # Model files live in a collapsible section: hidden by default, with a
    # one-line health summary. Auto-expands only when a file is missing.
    $modelToggle=Add-Button $left 'Model files' 18 458 110 27
    $modelSummary=Add-Label $left '' 134 462 546
    $script:ModelFilesExpanded=$false
    $modelRowControls=New-Object System.Collections.ArrayList
    $modelRows=@(
      @('Diffusion model','DiffusionModelPath','moss_image_sft_int8_convrot.safetensors'),
      @('LLM','LlmPath','Qwen3.5-9B-Q4_K_M.gguf'),
      @('VAE','VaePath','flux2-vae.safetensors'),
      @('Tokenizer','TokenizerPath','tokenizer_qwen3.5.json')
    )
    $modelControls=@{}
    $yy=492
    foreach($mr in $modelRows){
        $mrLabel=Add-Label $left $mr[0] 18 ($yy+3) 105; [void]$modelRowControls.Add($mrLabel)
        $val=[string]$script:Settings[$mr[1]]; if([string]::IsNullOrWhiteSpace($val)){$val=Join-Path $script:AppRoot ('models\'+$mr[2])} else {$val=Get-AbsoluteAppPath $val}
        $tb=Add-TextBox $left $val 125 $yy 445; $tb.Anchor='Top,Left,Right'; [void]$modelRowControls.Add($tb)
        $br=Add-Button $left '...' 580 ($yy-1) 100 27; $br.Anchor='Top,Right'; [void]$modelRowControls.Add($br)
        $key=$mr[1]; $br.Add_Click({$dlg=New-Object System.Windows.Forms.OpenFileDialog;$dlg.Title="Select $($mr[0]) file";$dlg.Filter='Model and data files|*.safetensors;*.gguf;*.json|All files (*.*)|*.*';$dlg.CheckFileExists=$true;$cur=Get-AbsoluteAppPath $tb.Text;if(Test-Path -LiteralPath $cur -PathType Leaf){$dlg.InitialDirectory=Split-Path -Parent $cur;$dlg.FileName=Split-Path -Leaf $cur}else{$modelsDir=Join-Path $script:AppRoot 'models';if(Test-Path -LiteralPath $modelsDir -PathType Container){$dlg.InitialDirectory=$modelsDir}};if($dlg.ShowDialog($f) -eq 'OK'){$tb.Text=$dlg.FileName};$dlg.Dispose()}.GetNewClosure())
        $modelControls[$key]=$tb; $yy+=29
    }
    function Update-MossModelSummary {
        $check=@((Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)))
        foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $check+=(Get-AbsoluteAppPath $modelControls[$k].Text) }
        $missingModels=@($check | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if($missingModels.Count -eq 0){ $modelSummary.Text='All 5 engine/model files found.'; $modelSummary.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164) }
        else { $modelSummary.Text=('{0} of 5 engine/model file(s) not found - click Model files to check the paths.' -f $missingModels.Count); $modelSummary.ForeColor=[System.Drawing.Color]::FromArgb(224,138,138) }
        return $missingModels.Count
    }
    if((Update-MossModelSummary) -gt 0){ $script:ModelFilesExpanded=$true } else { $script:ModelFilesExpanded=$false }
    foreach($c in $modelRowControls){ $c.Visible=$script:ModelFilesExpanded }
    $modelToggle.Text=if($script:ModelFilesExpanded){'Model files  [-]'}else{'Model files  [+]'}
    $modelToggle.Add_Click({
        $script:ModelFilesExpanded=-not $script:ModelFilesExpanded
        foreach($c in $modelRowControls){ $c.Visible=$script:ModelFilesExpanded }
        $modelToggle.Text=if($script:ModelFilesExpanded){'Model files  [-]'}else{'Model files  [+]'}
        [void](Update-MossModelSummary)
    })

    $generate=Add-Button $left 'GENERATE' 18 615 145 42; $generate.BackColor=$cAccent; $generate.ForeColor=[System.Drawing.Color]::White; $generate.Font=New-Object System.Drawing.Font('Segoe UI Semibold',10,[System.Drawing.FontStyle]::Bold)
    $cancel=Add-Button $left 'Cancel' 189 615 70 42; $cancel.Enabled=$false
    $openOut=Add-Button $left 'Open output' 285 615 105 42
    $btnReport=Add-Button $left 'Error report' 416 615 105 42
    $refineNative=Add-Button $left 'Improve last image' 547 615 140 42; $refineNative.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164)
    $refineNative.Add_Click({
        # Settings-driven improve of the most recent image: the size, steps,
        # CFG, seed and prompt come from the main window (same as right-click
        # "Improve using the settings in the main window"), and the prompt
        # falls back to the image's own stored prompt when the box is empty.
        if ($script:GenState.IsRunning) { return }
        if ($script:GeneratedFiles -and $script:GeneratedFiles.Count -gt 0) {
            $script:SelectedFile = [string]$script:GeneratedFiles[$script:GeneratedFiles.Count - 1]
            Start-MossRefineWithCurrentSettings
        } else {
            [System.Windows.Forms.MessageBox]::Show('Generate an image first - the most recent one is then used as the starting picture for the improvement.','Nothing to improve')|Out-Null
        }
    })
    $btnReport.Add_Click({ Copy-MossErrorReport })
    # Hover explanations for every control, so nothing is guesswork.
    $tip=New-Object System.Windows.Forms.ToolTip; $tip.InitialDelay=300; $tip.ReshowDelay=300
    $tip.SetToolTip($generate,'Renders your prompt. Quality follows the selector above: Exact (full quality) renders at full size and full steps; faster modes render small and enlarge - quick drafts, never distorted.')
    $tip.SetToolTip($cancel,'Stops the current generation and its engine processes.')
    $tip.SetToolTip($openOut,'Opens the output folder in Explorer.')
    $tip.SetToolTip($btnReport,'Copies an anonymised technical error report to the clipboard and saves it under logs. Nothing is sent over the internet.')
    $tip.SetToolTip($refineNative,'Improves your most recent image using the settings currently in the main window (size, steps, CFG, seed, prompt) - same as right-click "Improve using the settings in the main window".')
    $tip.SetToolTip($speedCombo,'How new images are rendered: Exact (full quality), or a faster draft mode that renders small and enlarges. Fastest renders at a 128-pixel side - very rough, but one click of Improve re-renders it sharp.')
    $tip.SetToolTip($negBtn,'Generation options: negative prompt, sampler and scheduler.')
    $tip.SetToolTip($modelToggle,'Show or hide the engine and model file paths.')
    $tip.SetToolTip($prompt,'Describe the image you want. Pasted multi-line text is flattened to one line automatically.')
    $tip.SetToolTip($historyPick,'Recent prompts (needs the history code to have been entered).')
    $tip.SetToolTip($resetHistoryCode,'Set a new history code (clears the current history) or manage the locked history.')
    $tip.SetToolTip($paste,'Fills the prompt box from the clipboard.')
    $tip.SetToolTip($style,'Visual style added to your prompt: photorealistic, anime, fantasy art, cyberpunk, ... None (no style) sends your prompt exactly as typed.')
    $tip.SetToolTip($res,'Common aspect ratios and sizes - picking one fills the Width and Height boxes.')
    $tip.SetToolTip($wBox,'Image width in pixels (64 to 8192).')
    $tip.SetToolTip($hBox,'Image height in pixels (64 to 8192).')
    $tip.SetToolTip($steps,'More steps = more refined detail and slower rendering. 25-50 is a good range; this model is tuned around 50.')
    $tip.SetToolTip($cfg,'How strictly the image follows the prompt: low = more artistic freedom, high = burned or distorted images. This model is tuned for about 3. Click the ? button for details.')
    $tip.SetToolTip($cfgHelp,'Explains what CFG scale does: how strictly the image follows your prompt.')
    $tip.SetToolTip($count,'How many images to render in one batch. No hard limit - very large batches ask first.')
    $tip.SetToolTip($seed,'Same seed + same prompt = the same image. -1 picks a random seed each run.')
    $tip.SetToolTip($out,'Where finished images are saved.')
    $tip.SetToolTip($outBrowse,'Choose the output folder.')
    $status=New-Object System.Windows.Forms.Label; $status.Text='Ready'; $status.Location=New-Object System.Drawing.Point(18,670); $status.Size=New-Object System.Drawing.Size(660,24); $status.ForeColor=$cMuted; $left.Controls.Add($status)

    Add-Label $right 'OUTPUT PREVIEW' 16 14 200 | Out-Null
    $preview=New-Object System.Windows.Forms.PictureBox; $preview.Location=New-Object System.Drawing.Point(16,42); $preview.Size=New-Object System.Drawing.Size(383,285); $preview.Anchor='Top,Left,Right'; $preview.SizeMode='Zoom'; $preview.BackColor=[System.Drawing.Color]::FromArgb(13,17,24); $right.Controls.Add($preview)
    $filesTitle=Add-Label $right 'GENERATED FILES  (right-click: improve or delete)' 16 342 340
    function Copy-MossImageUnlocked([string]$path) {
        # Returns a Bitmap copy of an image file without keeping the file
        # locked. Image.FromFile holds a file lock for the lifetime of the
        # image, which blocked deleting the file while it was shown in the
        # preview. The copy decouples the control from the file on disk.
        try {
            $src=[System.Drawing.Image]::FromFile($path)
            try { return New-Object System.Drawing.Bitmap($src) } finally { $src.Dispose() }
        } catch { return $null }
    }

    $fileList=New-Object System.Windows.Forms.ListBox; $fileList.Location=New-Object System.Drawing.Point(16,368); $fileList.Size=New-Object System.Drawing.Size(383,150); $fileList.Anchor='Top,Left,Right'; $fileList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $fileList.ForeColor=$cText; $right.Controls.Add($fileList)
    $fileList.Add_SelectedIndexChanged({if($fileList.SelectedItem){$p=[string]$fileList.SelectedItem;$script:SelectedFile=$p;if(Test-Path -LiteralPath $p){try{$newImg=Copy-MossImageUnlocked $p;if($newImg){$old=$preview.Image;$preview.Image=$newImg;if($old){$old.Dispose()}}}catch{}}}})
    # A plain right-click does not change the ListBox selection - select the
    # file under the cursor first, so Improve always acts on that file.
    $fileList.Add_MouseClick({ param($sender,$e) if($e.Button -eq [System.Windows.Forms.MouseButtons]::Right){ $idx=$fileList.IndexFromPoint($e.Location); if($idx -ge 0 -and $fileList.SelectedIndex -ne $idx){ $fileList.SelectedIndex=$idx } } })
    # Right-click a generated file to re-render exactly that picture at full
    # quality: same seed and prompt (read from its sidecar), full steps,
    # image-to-image at the chosen size. Grain stays, distortion does not come back.
    $refineMenu=New-Object System.Windows.Forms.ContextMenuStrip
    $miFresh=$refineMenu.Items.Add('Re-render from the same seed (fresh full quality)')
    $miCustom=$refineMenu.Items.Add('Improve using the settings in the main window...')
    $miAll=$refineMenu.Items.Add('Improve ALL files that can be improved...')
    $miInfo=$refineMenu.Items.Add('Show image info (prompt, seed, settings)...')
    $miDelete=$refineMenu.Items.Add('Delete this file')
    $fileList.ContextMenuStrip=$refineMenu
    $miFresh.Add_Click({ Start-MossRefineFresh })
    $miCustom.Add_Click({ Start-MossRefineWithCurrentSettings })
    $miAll.Add_Click({ Start-MossRefineAll })
    $miInfo.Add_Click({ Show-MossImageInfo })
    $miDelete.Add_Click({ Remove-MossSelectedFile })
    $refineMenu.ShowItemToolTips=$true
    $miFresh.ToolTipText='Brand-new full-quality render using this image''s seed, prompt and settings - like a new generation with the same seed. Related look, but the composition can differ from the draft. Use Improve instead to keep the exact composition.'
    $miCustom.ToolTipText='Improve this image using the size, steps, CFG, seed and prompt currently shown in the main window. Fast previews get a higher strength automatically.'
    $miAll.ToolTipText='Queue every generated image that still has quality headroom (soft previews, fewer steps, smaller than the current size).'
    $miDelete.ToolTipText='Delete this image and its sidecar from disk (asks first).'
    $miInfo.ToolTipText='Shows what is stored for this image: prompt, negative prompt, seed, size, steps, CFG, speed mode, sampler and scheduler. The prompt is decrypted only if the history code was entered. Copy the prompt with one click.'
    # Show ALL previously generated images at startup, not just this session's:
    # scan the output folder and list everything (oldest first, newest selected).
    try {
        $outFolder=Get-AbsoluteAppPath ([string]$script:Settings.OutputPath)
        if(Test-Path -LiteralPath $outFolder){
            $existing=Get-ChildItem -LiteralPath $outFolder -Filter 'MOSS_*.png' -File | Sort-Object LastWriteTime
            foreach($fi in $existing){ [void]$fileList.Items.Add($fi.FullName); [void]$script:GeneratedFiles.Add($fi.FullName) }
            if($fileList.Items.Count -gt 0 -and -not $script:SelectedFile){ $fileList.SelectedIndex=$fileList.Items.Count-1 }
        }
    } catch {}
    $logTitle=Add-Label $right 'GENERATION LOG' 16 535 200
    $log=New-Object System.Windows.Forms.TextBox; $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.Location=New-Object System.Drawing.Point(16,560); $log.Size=New-Object System.Drawing.Size(383,130); $log.Anchor='Top,Bottom,Left,Right'; $log.BackColor=[System.Drawing.Color]::FromArgb(13,17,24); $log.ForeColor=$cMuted; $right.Controls.Add($log)
    # The generation log is collapsed by default, like the model files; the
    # freed space goes to the preview and the file list.
    $logToggle=Add-Button $right 'Generation log  [+]' 16 535 150 27
    $logToggle.Add_Click({
        $script:LogVisible = -not $script:LogVisible
        $logToggle.Text = if ($script:LogVisible) { 'Generation log  [-]' } else { 'Generation log  [+]' }
        Update-MossRightLayout
    })
    function Update-MossRightLayout {
        if ($f.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized) {
            $filesTitle.Visible = $false
            $fileList.Visible = $false
            $logTitle.Visible = $false
            $log.Visible = $false
            $logToggle.Visible = $false
            $preview.Location = New-Object System.Drawing.Point(16,42)
            $preview.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),[Math]::Max(100,$right.ClientSize.Height - 60))
        } else {
            $filesTitle.Visible = $true
            $fileList.Visible = $true
            $panelHeight = $right.ClientSize.Height
            $fileHeight = [Math]::Min(150,[Math]::Max(80,[int][Math]::Round($panelHeight * 150.0 / 710.0)))
            $logTargetHeight = [Math]::Min(130,[Math]::Max(70,[int][Math]::Round($panelHeight * 130.0 / 710.0)))
            $logSpace = if ($script:LogVisible) { $logTargetHeight + 42 } else { 0 }
            $previewHeight = [Math]::Max(180,$panelHeight - 145 - $fileHeight - $logSpace)
            $filesTop = 42 + $previewHeight + 15
            $listTop = $filesTop + 26
            $logTitleTop = $listTop + $fileHeight + 17
            $logTop = $logTitleTop + 25
            $preview.Location = New-Object System.Drawing.Point(16,42)
            $preview.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),$previewHeight)
            $filesTitle.Location = New-Object System.Drawing.Point(16,$filesTop)
            $fileList.Location = New-Object System.Drawing.Point(16,$listTop)
            $fileList.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),$fileHeight)
            $logTitle.Location = New-Object System.Drawing.Point(16,$logTitleTop)
            $log.Location = New-Object System.Drawing.Point(16,$logTop)
            $log.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),[Math]::Max(70,$panelHeight - $logTop - 20))
            if ($script:LogVisible) {
                $logTitle.Visible = $true
                $log.Visible = $true
                $logToggle.Visible = $false
            } else {
                $logTitle.Visible = $false
                $log.Visible = $false
                $logToggle.Location = New-Object System.Drawing.Point(16,$logTitleTop)
                $logToggle.Visible = $true
            }
        }
    }
    $script:LogVisible = $false
    Update-MossRightLayout
    # No GetNewClosure here: closures run in a module scope that cannot see
    # functions defined inside Show-GeneratorWindow (caused a
    # CommandNotFoundException crash on show/resize in v0.1.19).
    $right.Add_Resize({ Update-MossRightLayout })
    $tip.SetToolTip($logToggle,'Show or hide the generation log.')
    $tip.SetToolTip($preview,'Preview of the selected generated image.')
    $tip.SetToolTip($fileList,'Images you generated. Left-click to preview; right-click for improve and delete options.')

    # --- Timer + Process generation worker (no BackgroundWorker) ---
    $script:GenState = @{
        IsRunning = $false
        Process = $null
        Timer = $null
        Job = $null
        Results = $null
        StdOut = $null
        StdErr = $null
        OutEvent = $null
        ErrEvent = $null
        CancelRequested = $false
        CurrentFile = $null
        CurrentImageIndex = 0
        CurrentImageSeed = 0
        LastErrorSummary = ''
        LastStdout = ''
        LastStderr = ''
        LastExitCode = $null
        LastReport = ''
        ImageStartedAt = $null
        ImageDurations = New-Object System.Collections.ArrayList
        ImageProgress = 0
        JobStartedAt = $null
    }

    function Stop-MossGen {
        # This only stops processes and the timer. The cancel flag itself is set
        # by the Cancel button / window close, so normal completion can still
        # continue the improvement queue.
        if ($null -ne $script:GenState.Timer) {
            try { $script:GenState.Timer.Stop() } catch {}
            try { $script:GenState.Timer.Dispose() } catch {}
            $script:GenState.Timer = $null
        }
        if ($null -ne $script:GenState.Process) {
            try {
                if (-not $script:GenState.Process.HasExited) {
                    $processId = $script:GenState.Process.Id
                    $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
                    if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
                        try { Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$processId,'/T','/F') -WindowStyle Hidden -Wait | Out-Null } catch {}
                    }
                    if (-not $script:GenState.Process.HasExited) { $script:GenState.Process.Kill() }
                    [void]$script:GenState.Process.WaitForExit(4000)
                }
            } catch {}
            try { $script:GenState.Process.Dispose() } catch {}
            $script:GenState.Process = $null
        }
        if ($script:GenState.OutEvent) {
            try { Unregister-Event -SourceIdentifier $script:GenState.OutEvent.Name -ErrorAction SilentlyContinue } catch {}
            $script:GenState.OutEvent = $null
        }
        if ($script:GenState.ErrEvent) {
            try { Unregister-Event -SourceIdentifier $script:GenState.ErrEvent.Name -ErrorAction SilentlyContinue } catch {}
            $script:GenState.ErrEvent = $null
        }
        $script:GenState.IsRunning = $false
        $script:ActiveProcess = $null
    }

    
    function Get-MossAnonymisedPath([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
            $root = [System.IO.Path]::GetFullPath($script:AppRoot)
            if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $full.Substring($root.Length).TrimStart('\', '/')
                return '<AppRoot>\' + $rel
            }
        } catch {}
        # Fall back to filename only for privacy
        return [System.IO.Path]::GetFileName($Path)
    }

    function Build-MossErrorReport {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('MOSS Image Studio - Error / Diagnostic Report')
        $lines.Add(('Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        $lines.Add(('Script: ' + (Get-MossAnonymisedPath $PSCommandPath)))
        $lines.Add(('AppRoot: <AppRoot>'))
        $lines.Add('')
        $lines.Add('--- Settings ---')
        $lines.Add(('Backend: ' + [string]$script:Settings.Backend))
        $lines.Add(('Engine: ' + (Get-MossAnonymisedPath ([string]$script:Settings.EnginePath))))
        $lines.Add(('Diffusion model: ' + (Get-MossAnonymisedPath ([string]$script:Settings.DiffusionModelPath))))
        $lines.Add(('LLM: ' + (Get-MossAnonymisedPath ([string]$script:Settings.LlmPath))))
        $lines.Add(('VAE: ' + (Get-MossAnonymisedPath ([string]$script:Settings.VaePath))))
        $lines.Add(('Tokenizer: ' + (Get-MossAnonymisedPath ([string]$script:Settings.TokenizerPath))))
        $lines.Add(('Output folder: ' + (Get-MossAnonymisedPath ([string]$script:Settings.OutputPath))))
        $lines.Add(('Default size: {0} x {1}' -f $script:Settings.Width, $script:Settings.Height))
        $lines.Add(('Steps: {0}  CFG: {1}  Seed: {2}' -f $script:Settings.Steps, $script:Settings.CfgScale, $script:Settings.Seed))
        $lines.Add('')
        $lines.Add('--- Last generation state ---')
        $st = $script:GenState
        $lines.Add(('IsRunning: ' + $st.IsRunning))
        $lines.Add(('CancelRequested: ' + $st.CancelRequested))
        $lines.Add(('Current image: ' + [int]$st.CurrentImageIndex))
        if ($null -ne $st.LastExitCode) { $lines.Add(('Last exit code: ' + $st.LastExitCode)) }
        if ($st.LastErrorSummary) { $lines.Add(('Last error summary: ' + $st.LastErrorSummary)) }
        if ($st.Job) {
            $j = $st.Job
            $lines.Add(('Job size: {0} x {1}, steps {2}, cfg {3}, count {4}, seed base {5}' -f $j.Width, $j.Height, $j.Steps, $j.Cfg, $j.Count, $j.Seed))
            $lines.Add(('Weight placement: engine auto-fit (GPU, then RAM, then disk as needed)'))
            # Prompt intentionally omitted from error reports for privacy
        }
        $lines.Add('')
        $lines.Add('--- Last STDOUT ---')
        if ($st.LastStdout) { $lines.Add($st.LastStdout) } else { $lines.Add('(empty)') }
        $lines.Add('')
        $lines.Add('--- Last STDERR ---')
        if ($st.LastStderr) { $lines.Add($st.LastStderr) } else { $lines.Add('(empty)') }
        $lines.Add('')
        $lines.Add('--- Recent log text (tail) ---')
        try {
            if ($log -and $log.Text) {
                $tail = $log.Text
                if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
                $lines.Add($tail)
            } else { $lines.Add('(log empty)') }
        } catch { $lines.Add('(could not read log)') }
        $lines.Add('')
        $lines.Add('--- End of report ---')
        $lines.Add('Paste this report into ChatGPT, Grok, or another AI coding assistant and ask it to diagnose the error and suggest a fix for this PowerShell script. Personal folder paths are anonymised and prompts are omitted.')
        return ($lines -join "`r`n")
    }

    function Copy-MossErrorReport {
        try {
            $report = Build-MossErrorReport
            $script:GenState.LastReport = $report
            [System.Windows.Forms.Clipboard]::SetText($report)
            $status.Text = 'Error report copied to clipboard (paths anonymised)'
            # Local only by design: the report is copied and saved, never sent
            # anywhere (MOSS has no report server, and nothing leaves this PC).
            $savedName = ''
            try {
                $logDir = Join-Path $script:AppRoot 'logs'
                if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                $reportFile = Join-Path $logDir ('error-report-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
                $report | Set-Content -LiteralPath $reportFile -Encoding UTF8
                $savedName = Split-Path -Leaf $reportFile
                $status.Text = "Error report copied + saved to logs\$savedName (nothing is sent online)"
            } catch { $status.Text = 'Error report copied to clipboard (paths anonymised)' }
            [System.Windows.Forms.MessageBox]::Show(("The anonymised error report is now on the clipboard and saved as logs\$savedName. Nothing is sent over the internet - the report stays on this computer.`r`n`r`nPaste it into an AI assistant (or send it to the developer) if you want help diagnosing the problem."),'Error report',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(('Could not build/copy report: ' + $_.Exception.Message), 'Error report') | Out-Null
        }
    }

    function Format-MossDuration([double]$Seconds) {
        if ($Seconds -lt 0) { $Seconds = 0 }
        $span = [TimeSpan]::FromSeconds([Math]::Min([int]::MaxValue, [Math]::Ceiling($Seconds)))
        if ($span.TotalHours -ge 1) { return $span.ToString('h\:mm\:ss') }
        return $span.ToString('m\:ss')
    }

    function Update-MossLiveProgress {
        $st = $script:GenState
        if (-not $st.IsRunning -or $null -eq $st.Process -or $st.Process.HasExited) { return }
        $elapsed = 0.0
        if ($st.JobStartedAt) { $elapsed = [Math]::Max(0, ((Get-Date) - $st.JobStartedAt).TotalSeconds) }
        $combined = ([string]$st.StdOut.ToString()) + "`n" + ([string]$st.StdErr.ToString())
        # The whole batch runs in one engine process. Track which image of the
        # batch is currently rendering from the engine's own progress lines.
        $batchMatches = [regex]::Matches($combined, '(?i)generating image:\s*(\d+)\s*/\s*(\d+)\s*-\s*seed\s*(-?\d+)')
        if ($batchMatches.Count -gt 0) {
            $lastBatch = $batchMatches[$batchMatches.Count - 1]
            $thisImage = [int]$lastBatch.Groups[1].Value
            if ($thisImage -ne [int]$st.CurrentImageIndex) {
                if ($st.ImageStartedAt -and [int]$st.CurrentImageIndex -gt 0) {
                    [void]$st.ImageDurations.Add([Math]::Max(0.1, ((Get-Date) - $st.ImageStartedAt).TotalSeconds))
                }
                $st.CurrentImageIndex = $thisImage
                $st.CurrentImageSeed = [long]$lastBatch.Groups[3].Value
                $st.ImageStartedAt = Get-Date
                $st.ImageProgress = 0
            }
        }
        $imageElapsed = 0.0
        if ($st.ImageStartedAt) { $imageElapsed = [Math]::Max(0, ((Get-Date) - $st.ImageStartedAt).TotalSeconds) }
        $engineProgress = $null
        $matches = [regex]::Matches($combined, '(?im)\b(\d{1,3})\s*%')
        if ($matches.Count -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int]$matches[$matches.Count - 1].Groups[1].Value)) }
        if ($null -eq $engineProgress) {
            $matches = [regex]::Matches($combined, '(?im)(?:\bstep\s*[:#]?\s*(\d+)\s*/\s*(\d+)\b|\b(\d+)\s*/\s*(\d+)\s*steps?\b)')
            if ($matches.Count -gt 0) {
                $last = $matches[$matches.Count - 1]
                if ($last.Groups[1].Success) { $numerator = [double]$last.Groups[1].Value; $denominator = [double]$last.Groups[2].Value }
                else { $numerator = [double]$last.Groups[3].Value; $denominator = [double]$last.Groups[4].Value }
                if ($denominator -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int](($numerator * 100) / $denominator))) }
            }
        }
        if ($null -ne $engineProgress) { $st.ImageProgress = [int]$engineProgress }
        $job = $st.Job
        $currentImage = [Math]::Max(1, [int]$st.CurrentImageIndex)
        $overall = [int][Math]::Floor(((($currentImage - 1) * 100) + [int]$st.ImageProgress) / [Math]::Max(1, [int]$job.Count))
        $overall = [Math]::Max(0, [Math]::Min(99, $overall))
        $etaText = 'ETA calculating'
        $remaining = $null
        if ($null -ne $engineProgress -and $engineProgress -gt 0) {
            $imageTotalEstimate = $imageElapsed * 100.0 / $engineProgress
            $remaining = ($imageTotalEstimate - $imageElapsed) + ([Math]::Max(0, $job.Count - $currentImage) * $imageTotalEstimate)
        } elseif ($st.ImageDurations.Count -gt 0) {
            $average = (($st.ImageDurations | Measure-Object -Average).Average)
            $remaining = [Math]::Max(0, $average - $imageElapsed) + ([Math]::Max(0, $job.Count - $currentImage) * $average)
        }
        if ($null -ne $remaining) { $etaText = "ETA ~$(Format-MossDuration $remaining)" }
        $progressNote = if ($null -ne $engineProgress) { " | image $([int]$st.ImageProgress)%" } else { '' }
        $status.Text = "Image $currentImage of $($job.Count) | $overall% overall$progressNote | total elapsed $(Format-MossDuration $elapsed) | $etaText"
    }


    function Complete-MossGen {
        param([string]$FinalStatus)
        Stop-MossGen
        $generate.Enabled = $true
        $cancel.Enabled = $false
        if ($FinalStatus) { $status.Text = $FinalStatus }
        if ($script:GenState.JobStartedAt) { $status.Text += " | total elapsed $(Format-MossDuration ((Get-Date) - $script:GenState.JobStartedAt).TotalSeconds)" }
    }

    function Start-MossBatchEngine {
        # One engine process renders the whole batch: the model is loaded once and
        # the prompt conditioning is reused (--batch-count + --conditioning-cache-size).
        # Weight placement (GPU, RAM, disk) is decided by the engine's built-in
        # auto-fit, which works the same way for CUDA, Vulkan, SYCL and CPU builds.
        $st = $script:GenState
        $job = $st.Job

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        # Refined (image-to-image) outputs carry an easy-to-spot tag in the name:
        # ..._hq_01.png (same size, native quality) or ..._hq2x_01.png (2x size).
        $refineSuffix = if ($job.RefineTag) { '_' + [string]$job.RefineTag } else { '' }
        # Braces are required: "$refineSuffix_" would be parsed as a variable
        # named 'refineSuffix_' and the tag would silently disappear.
        $pattern = Join-Path $job.OutputPath ("MOSS_{0}${refineSuffix}_%02d.png" -f $stamp)
        $st.CurrentFile = $pattern

        $argsList = New-Object System.Collections.Generic.List[string]
        $argsList.Add('--diffusion-model'); $argsList.Add((Quote-ProcessArgument $job.Diffusion))
        $argsList.Add('--llm'); $argsList.Add((Quote-ProcessArgument $job.Llm))
        $argsList.Add('--vae'); $argsList.Add((Quote-ProcessArgument $job.Vae))
        $argsList.Add('--tokenizer'); $argsList.Add((Quote-ProcessArgument $job.Tokenizer))
        $argsList.Add('--cfg-scale'); $argsList.Add((ConvertFrom-MossDouble ([double]$job.Cfg)))
        $argsList.Add('--steps'); $argsList.Add([string]$job.Steps)
        $argsList.Add('-H'); $argsList.Add([string]$job.Height)
        $argsList.Add('-W'); $argsList.Add([string]$job.Width)
        $argsList.Add('-s'); $argsList.Add([string]$job.Seed)
        $argsList.Add('--batch-count'); $argsList.Add([string]$job.Count)
        $argsList.Add('--output-begin-idx'); $argsList.Add('1')
        $argsList.Add('--conditioning-cache-size'); $argsList.Add([string][Math]::Min([Math]::Max(1, [int]$job.Count), 32))
        # Speed modes: render at a reduced size, upscale in latent space, then a
        # short refine pass at the chosen size. Same engine feature for every
        # backend (Latent upscaler needs no extra model file). 'Exact' renders
        # natively at full size and steps.
        # Speed modes render at a reduced size with the FULL step count and then
        # MOSS upscales the finished image in pixel space. No second sampling
        # pass runs at all, so nothing can introduce distorted detail - the
        # result is a faithful, possibly grainy enlargement of a small render.
        $speedScale = 0.0
        switch ([string]$job.SpeedMode) {
            '2x' { $speedScale = 0.7 }
            '4x' { $speedScale = 0.5 }
            '8x' { $speedScale = 0.35 }
            'Fast' { $speedScale = [Math]::Min(0.35, 128.0 / [Math]::Min($job.Width, $job.Height)) }
        }
        $st.UpscaleTarget = $null
        if ($speedScale -gt 0) {
            $smallW = [int][Math]::Max(128, [Math]::Floor($job.Width * $speedScale))
            $smallH = [int][Math]::Max(128, [Math]::Floor($job.Height * $speedScale))
            if ($smallW -lt $job.Width -and $smallH -lt $job.Height) {
                $argsList.Add('-W'); $argsList.Add([string]$smallW)
                $argsList.Add('-H'); $argsList.Add([string]$smallH)
                $st.UpscaleTarget = @{ W = [int]$job.Width; H = [int]$job.Height; FromW = $smallW; FromH = $smallH }
            }
        }
        $argsList.Add('-p'); $argsList.Add((Quote-ProcessArgument $job.Prompt))
        $argsList.Add('-o'); $argsList.Add((Quote-ProcessArgument $pattern))
        # Native refinement: start from an existing picture (e.g. an upscaled fast
        # preview) and re-synthesize it at full size. Same composition, new detail.
        if ($job.InitImage -and (Test-Path -LiteralPath ([string]$job.InitImage) -PathType Leaf)) {
            $argsList.Add('-i'); $argsList.Add((Quote-ProcessArgument ([string]$job.InitImage)))
            $argsList.Add('--strength'); $argsList.Add((ConvertFrom-MossDouble ([double]$job.InitStrength)))
        }
        # Optional sampler/scheduler: 'Default (model)' means the flag is omitted
        # so the engine keeps its model-specific choice.
        if ($job.SamplingMethod) { $argsList.Add('--sampling-method'); $argsList.Add([string]$job.SamplingMethod) }
        if ($job.Scheduler) { $argsList.Add('--scheduler'); $argsList.Add([string]$job.Scheduler) }
        # Negative prompt (engine flag -n), flattened to a single line like the
        # positive prompt.
        if ($job.NegativePrompt) { $argsList.Add('-n'); $argsList.Add((Quote-ProcessArgument ([string]$job.NegativePrompt))) }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $job.Engine
        $psi.Arguments = ($argsList -join ' ')
        # MOSS is a GUI front-end for the sd-cli command-line engine. When the
        # user wants full transparency, log the exact command line it runs
        # (prompts included - the log never leaves this computer).
        if (-not $script:Settings.Contains('ShowEngineCommandLine') -or [string]$script:Settings.ShowEngineCommandLine -eq '1') {
            $log.AppendText(("`r`nEngine command line: {0} {1}" -f $job.Engine, $psi.Arguments))
        }
        $psi.WorkingDirectory = $job.Root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # Target a specific physical GPU when the user selected one in setup.
        if ($job.GpuIndex -ge 0) {
            $deviceEnv = switch -Regex ([string]$job.Backend) { '^CUDA' { 'CUDA_VISIBLE_DEVICES'; break } '^HIP' { 'HIP_VISIBLE_DEVICES'; break } 'Vulkan' { 'GGML_VK_VISIBLE_DEVICES'; break } default { $null } }
            if ($deviceEnv) { $psi.EnvironmentVariables[$deviceEnv] = [string]$job.GpuIndex }
        }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.EnableRaisingEvents = $false

        $st.StdOut = New-Object System.Text.StringBuilder
        $st.StdErr = New-Object System.Text.StringBuilder

        $outAction = {
            if ($null -ne $EventArgs.Data -and $EventArgs.Data.Length -gt 0) {
                [void]$script:GenState.StdOut.AppendLine($EventArgs.Data)
            }
        }
        $errAction = {
            if ($null -ne $EventArgs.Data -and $EventArgs.Data.Length -gt 0) {
                [void]$script:GenState.StdErr.AppendLine($EventArgs.Data)
            }
        }

        $st.OutEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outAction
        $st.ErrEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errAction

        try {
            [void]$proc.Start()
            $proc.BeginOutputReadLine()
            $proc.BeginErrorReadLine()
            $st.Process = $proc
            $script:ActiveProcess = $proc
            $st.ImageStartedAt = Get-Date
            $st.ImageProgress = 0
            $st.CurrentImageIndex = 0
            $status.Text = ("Rendering {0} image(s) in one run (base seed {1})..." -f $job.Count, $job.Seed)
            if ($up) { $status.Text = ("Fast mode: rendering {0} image(s) small (will upscale after render)..." -f $job.Count) }
        } catch {
            $msg = "Failed to start engine: $($_.Exception.Message)"
            $log.AppendText("`r`n$msg")
            [void](Write-MossErrorLog 'MOSS engine start failure' $msg)
            [void]$st.Results.Add([pscustomobject]@{ Path = ([string]$st.CurrentFile); ExitCode = -1; Seed = $job.Seed; Output = $msg })
            Complete-MossGen 'Generation failed - the engine could not be started'
            Start-MossNextRefine
        }
    }

    function Resize-MossImageTo([string]$Path,[int]$TargetW,[int]$TargetH) {
        # Faithful pixel-space enlargement (high-quality bicubic): geometry is
        # preserved exactly; grain may show but features never warp.
        # Read the file bytes first: Image.FromFile keeps a lock on the file and
        # saving over that same locked file fails with a generic GDI+ error -
        # which silently kept every fast-mode render at its small size.
        $srcBytes=[System.IO.File]::ReadAllBytes($Path)
        $ms=New-Object System.IO.MemoryStream (,$srcBytes)
        $img=[System.Drawing.Image]::FromStream($ms)
        try {
            $bmp=New-Object System.Drawing.Bitmap($TargetW,$TargetH)
            try {
                $g=[System.Drawing.Graphics]::FromImage($bmp)
                try {
                    $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $g.CompositingQuality=[System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $g.DrawImage($img,0,0,$TargetW,$TargetH)
                } finally { $g.Dispose() }
                $bmp.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)
            } finally { $bmp.Dispose() }
        } finally { $img.Dispose(); $ms.Dispose() }
    }

    function On-MossGenTimerTick {
        $st = $script:GenState
        if ($null -eq $st.Process) { return }
        if (-not $st.Process.HasExited) { Update-MossLiveProgress; return }

        # The whole batch has finished (one process rendered every image).
        $exitCode = $st.Process.ExitCode
        $st.LastExitCode = $exitCode
        $job = $st.Job
        if ($st.ImageStartedAt -and [int]$st.CurrentImageIndex -gt 0) { [void]$st.ImageDurations.Add([Math]::Max(0.1, ((Get-Date) - $st.ImageStartedAt).TotalSeconds)) }

        $stdout = [string]$st.StdOut.ToString()
        $stderr = [string]$st.StdErr.ToString()
        # Engines sometimes echo their input. Keep prompt text out of logs and diagnostic reports.
        if (-not [string]::IsNullOrEmpty([string]$job.Prompt)) {
            $stdout = $stdout.Replace([string]$job.Prompt, '[prompt redacted]')
            $stderr = $stderr.Replace([string]$job.Prompt, '[prompt redacted]')
        }
        $st.LastStdout = $stdout
        $st.LastStderr = $stderr
        $st.LastExitCode = $exitCode
        if ($exitCode -ne 0) {
            $st.LastErrorSummary = "Engine exit code $exitCode for a batch of $($job.Count) image(s)"
        }

        # Drain remaining data
        try { $st.Process.CancelOutputRead() } catch {}
        try { $st.Process.CancelErrorRead() } catch {}

        if ($st.OutEvent) {
            try { Unregister-Event -SourceIdentifier $st.OutEvent.Name -ErrorAction SilentlyContinue } catch {}
            $st.OutEvent = $null
        }
        if ($st.ErrEvent) {
            try { Unregister-Event -SourceIdentifier $st.ErrEvent.Name -ErrorAction SilentlyContinue } catch {}
            $st.ErrEvent = $null
        }

        try { $st.Process.Dispose() } catch {}
        $st.Process = $null
        $script:ActiveProcess = $null

        # Per-image seeds as reported by the engine ('generating image: i/N - seed S').
        $seedMap = @{}
        foreach ($m in [regex]::Matches($stdout, '(?i)generating image:\s*(\d+)\s*/\s*(\d+)\s*-\s*seed\s*(-?\d+)')) {
            $seedMap[[int]$m.Groups[1].Value] = [long]$m.Groups[3].Value
        }

        # Speed modes: enlarge the small renders to the chosen target size now.
        $up = $st.UpscaleTarget
        if ($up) {
            $status.Text = 'Upscaling results to full size...'
            $f.Refresh()
        }

        $patternBase = ([string]$st.CurrentFile) -replace '%02d','{0:D2}'
        $ok = 0
        $missing = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -le $job.Count; $i++) {
            $file = $patternBase -f $i
            $thisSeed = if ($seedMap.ContainsKey($i)) { $seedMap[$i] } else { $job.Seed + ($i - 1) }
            if ($exitCode -eq 0 -and (Test-Path -LiteralPath $file)) {
                $ok++
                $upscaledNote = $null
                if ($up) {
                    try {
                        Resize-MossImageTo $file ([int]$up.W) ([int]$up.H)
                        $upscaledNote = ('upscaled from {0} x {1}' -f $up.FromW, $up.FromH)
                    } catch {
                        $upscaledNote = ('kept at engine size {0} x {1} (resize failed: {2})' -f $up.FromW, $up.FromH, $_.Exception.Message)
                    }
                }
                try {
                    $meta = [ordered]@{
                        Width = $job.Width; Height = $job.Height
                        Steps = $job.Steps; CfgScale = $job.Cfg; Seed = $thisSeed
                        Backend = $job.Backend
                        SpeedMode = [string]$job.SpeedMode
                        UpscaledFrom = $upscaledNote
                        InitImage = $(if($job.InitImage){ [System.IO.Path]::GetFileName([string]$job.InitImage) }else{ $null })
                        InitStrength = $(if($job.InitImage){ [double]$job.InitStrength }else{ $null })
                        Sampler = $(if($job.SamplingMethod){ [string]$job.SamplingMethod }else{ $null })
                        Scheduler = $(if($job.Scheduler){ [string]$job.Scheduler }else{ $null })
                        GeneratedAt = (Get-Date).ToString('o'); Engine = $job.Engine
                    }
                    if (-not $script:HistoryLocked -and $script:HistoryPassphrase) {
                        $meta.PromptProtected = Protect-MossPayload ([string]$job.Prompt) $script:HistoryPassphrase
                        if ($job.NegativePrompt) { $meta.NegativePromptProtected = Protect-MossPayload ([string]$job.NegativePrompt) $script:HistoryPassphrase }
                    }
                    $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ([System.IO.Path]::ChangeExtension($file, '.json')) -Encoding UTF8
                } catch {}
                [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = 'OK' })
                [void]$fileList.Items.Add($file)
                [void]$script:GeneratedFiles.Add($file)
                $fileList.SelectedIndex = $fileList.Items.Count - 1
            } else {
                $missing.Add($file)
                [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = 'Image file was not created' })
            }
        }

        $outputText = "Engine: $($job.Engine)`r`nWorking directory: $($job.Root)`r`nExit code: $exitCode`r`n--- STDOUT ---`r`n$stdout`r`n--- STDERR ---`r`n$stderr"
        $finalMsg = $null
        if ($exitCode -ne 0) {
            $outputText = "ERROR: Engine process returned exit code $exitCode.`r`n" + $outputText
            [void](Write-MossErrorLog ("MOSS generation error - batch of {0} image(s) (exit {1})" -f $job.Count, $exitCode) $outputText)
            $finalMsg = if ($ok -gt 0) { "Partially completed - $ok of $($job.Count) image(s) generated (engine exit $exitCode)" } else { "Generation failed - engine returned exit code $exitCode" }
        } elseif ($missing.Count -gt 0) {
            $outputText = ("ERROR: Engine returned exit code 0 but {0} expected image file(s) were not created:`r`n" -f $missing.Count) + (($missing | ForEach-Object { '  ' + $_ }) -join "`r`n") + "`r`n" + $outputText
            [void](Write-MossErrorLog ("MOSS generation error - {0} of {1} image(s) missing" -f $missing.Count, $job.Count) $outputText)
            $finalMsg = "Partially completed - $ok of $($job.Count) image(s) generated"
        }

        if ($null -eq $finalMsg) { $finalMsg = "Completed - $ok of $($job.Count) image(s) generated" }
        Complete-MossGen $finalMsg
        if ($ok -gt 0) { $log.AppendText("`r`nCompleted. Output folder: $($job.OutputPath)") }
        if ($exitCode -ne 0 -or $missing.Count -gt 0) {
            $log.AppendText("`r`nOne or more images failed. Engine output above; a technical report was saved to the logs folder.")
            # Most common silent failure: the engine dies without any output at
            # very large render sizes (out of GPU/RAM). Give plain guidance.
            if ($exitCode -ne 0 -and -not $stdout.Trim() -and -not $stderr.Trim()) {
                $mp = [Math]::Round(([double]$job.Width * [double]$job.Height / 1000000.0), 1)
                $log.AppendText(("`r`nHint: the engine stopped without any message. At {0} x {1} ({2} MP, {3} steps) the most common cause is running out of GPU or system memory. Try a smaller size, fewer steps, or a fast speed mode (which renders small and enlarges)." -f $job.Width, $job.Height, $mp, $job.Steps))
            }
        }
        $log.AppendText("`r`n--- Batch finished | exit $exitCode | $ok of $($job.Count) image(s) ---`r`n$outputText`r`n")
        # Continue any pending native refinement queue unless the user cancelled.
        if (-not $st.CancelRequested) { Start-MossNextRefine } else { $script:RefineQueue.Clear(); $script:RefineTotal = 0 }
    }

    function Start-MossGeneration {
        param($Job,[switch]$ForRefine)
        if ($script:GenState.IsRunning) { return }
        $script:GenState.IsRunning = $true
        $script:GenState.CancelRequested = $false
        $script:GenState.Job = $Job
        $script:GenState.Results = New-Object System.Collections.ArrayList
        $script:GenState.Process = $null
        $script:GenState.CurrentFile = $null
        $script:GenState.CurrentImageIndex = 0
        $script:GenState.CurrentImageSeed = 0
        $script:GenState.ImageStartedAt = $null
        $script:GenState.JobStartedAt = Get-Date

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 400
        $timer.Add_Tick({ On-MossGenTimerTick })
        $script:GenState.Timer = $timer
        $timer.Start()

        $generate.Enabled = $false
        $cancel.Enabled = $true
        if (-not $ForRefine) { $log.Clear() }
        # Keep the existing file list: it is the full history of generated
        # files (populated at startup). New images are appended as they land.
        $status.Text = 'Starting engine...'

        Start-MossBatchEngine
    }

    function Test-MossFastPreview([string]$file) {
        # A fast-mode preview is saved at its TARGET size after an in-place
        # bicubic upscale (sidecar notes UpscaledFrom). The soft look is baked
        # into the pixels, so image-to-image from this file inherits the blur.
        # True when the file should be re-rendered from scratch instead.
        $side=[System.IO.Path]::ChangeExtension($file,'.json')
        if (Test-Path -LiteralPath $side -PathType Leaf) {
            try { $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json; if ($sc.UpscaledFrom) { return $true }; if ($sc.SpeedMode -and [string]$sc.SpeedMode -ne 'Exact') { return $true } } catch {}
        }
        return $false
    }

    function Get-MossPreviewUpscaleFactor([string]$file) {
        # How many times the stored image was enlarged from its original small
        # render (sidecar note 'upscaled from W x H'). Returns 1.0 when the
        # file is not a fast preview.
        $side=[System.IO.Path]::ChangeExtension($file,'.json')
        if (Test-Path -LiteralPath $side -PathType Leaf) {
            try {
                $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json
                if ($sc.UpscaledFrom -and ([string]$sc.UpscaledFrom) -match 'upscaled from (\d+) x (\d+)') {
                    $fromMin = [Math]::Min([int]$Matches[1],[int]$Matches[2])
                    $tw = 0; $th = 0
                    if ($sc.Width) { $tw = [int]$sc.Width }
                    if ($sc.Height) { $th = [int]$sc.Height }
                    if ($fromMin -gt 0 -and $tw -gt 0 -and $th -gt 0) {
                        $f = [Math]::Min($tw,$th) / $fromMin
                        if ($f -gt 1) { return [Math]::Round($f,2) }
                    }
                }
            } catch {}
        }
        return 1.0
    }

    function Get-MossImproveStrength([string]$file,[double]$userStrength) {
        # Fast previews are stored as enlarged drafts - image-to-image from
        # them at a low strength inherits the soft upscale. A higher strength
        # makes the model regenerate detail; the composition still comes from
        # the image itself. The bigger the enlargement, the higher the strength
        # (0.5 at 2x up to 0.74 at 6x or more).
        $factor = Get-MossPreviewUpscaleFactor $file
        if ($factor -gt 1.01) {
            $previewStrength = 0.5 + 0.04*[Math]::Min($factor,6)
            return [Math]::Max([Math]::Min(0.75,$previewStrength), $userStrength)
        }
        return $userStrength
    }

    function Get-MossImproveDefaults([string]$selFile,[double]$sizeFactor) {
        # Shared prefill for all improve paths: target size, seed, prompt
        # (decrypted only if the history code was entered), negative prompt,
        # sampler, scheduler and adaptive strength.
        $d = [pscustomobject]@{ File=[string]$selFile; TW=0; TH=0; Seed=[long]-1; Prompt=''; NegativePrompt=[string]$script:Settings.NegativePrompt; SamplingMethod=$null; Scheduler=$null; Strength=0.45; Error='' }
        $sidecar = [System.IO.Path]::ChangeExtension($selFile, '.json')
        if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
            try { $sc = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json; if($sc.Width){$d.TW=[int]$sc.Width}; if($sc.Height){$d.TH=[int]$sc.Height} } catch {}
        }
        if ($d.TW -le 0 -or $d.TH -le 0) {
            try { $img=[System.Drawing.Image]::FromFile($selFile); $d.TW=$img.Width; $d.TH=$img.Height; $img.Dispose() } catch { $d.TW=0; $d.TH=0 }
        }
        if ($d.TW -le 0 -or $d.TH -le 0) { $d.Error='size'; return $d }
        $d.TW=[int][Math]::Min(8192,[Math]::Ceiling($d.TW*$sizeFactor)); $d.TH=[int][Math]::Min(8192,[Math]::Ceiling($d.TH*$sizeFactor))
        $d.Prompt = $prompt.Text
        if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
            try {
                $sc = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
                if ($sc.Seed) { $d.Seed = [long]$sc.Seed }
                if ($sc.Sampler) { $d.SamplingMethod = [string]$sc.Sampler }
                if ($sc.Scheduler) { $d.Scheduler = [string]$sc.Scheduler }
                if (-not $script:HistoryLocked -and $script:HistoryPassphrase -and $sc.PromptProtected) {
                    try { $p = Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase; if ($p) { $d.Prompt = [string]$p } } catch {}
                    if ($sc.NegativePromptProtected) { try { $np = Unprotect-MossPayload ([string]$sc.NegativePromptProtected) $script:HistoryPassphrase; if ($null -ne $np) { $d.NegativePrompt = [string]$np } } catch {} }
                }
            } catch {}
        }
        if (-not $d.SamplingMethod -and [string]$script:Settings.SamplingMethod -ne 'Default (model)') { $d.SamplingMethod = [string]$script:Settings.SamplingMethod }
        if (-not $d.Scheduler -and [string]$script:Settings.Scheduler -ne 'Default (model)') { $d.Scheduler = [string]$script:Settings.Scheduler }
        return $d
    }

    function Start-MossRefineFresh {
        # Fresh full-quality re-render from the image's own seed, prompt and
        # settings: no image-to-image - the seed is used like a brand-new
        # generation. Same seed gives a related look; because the full-quality
        # canvas is bigger than a fast draft, the composition can differ.
        if ($script:GenState.IsRunning) { $status.Text='Busy - wait for the current run to finish, then right-click again.'; return }
        $selFile = [string]$script:SelectedFile
        if (-not $selFile -or -not (Test-Path -LiteralPath $selFile -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first (left-click it), then right-click to re-render it.','Re-render from seed')|Out-Null;return
        }
        $script:GenState.CancelRequested = $false
        $d = Get-MossImproveDefaults $selFile 1
        if ($d.Error -eq 'size') { [System.Windows.Forms.MessageBox]::Show('Could not determine the image size.','Re-render from seed')|Out-Null;return }
        if ($d.Seed -lt 0) { $d.Seed = Get-Random -Minimum 1 -Maximum 2147483000 }
        [void]$script:RefineQueue.Add([pscustomobject]@{ File=$d.File; W=$d.TW; H=$d.TH; Seed=$d.Seed; Prompt=[string]$d.Prompt; NegativePrompt=[string]$d.NegativePrompt; SamplingMethod=$d.SamplingMethod; Scheduler=$d.Scheduler; Strength=0.0; Steps=$null; Cfg=$null; Tag='hq'; FreshRender=$true })
        $script:RefineTotal = $script:RefineQueue.Count
        Start-MossNextRefine
    }


    function Start-MossRefineWithCurrentSettings {
        # Improves the selected file using the values currently visible in the
        # main window (size, steps, CFG, seed, prompt box, Options values).
        # The confirmation states clearly that these settings apply to that file.
        if ($script:GenState.IsRunning) { $status.Text='Busy - wait for the current run to finish, then right-click again.'; return }
        $selFile = [string]$script:SelectedFile
        if (-not $selFile -or -not (Test-Path -LiteralPath $selFile -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first (left-click it), then right-click to improve it.','Improve image')|Out-Null;return
        }
        $script:GenState.CancelRequested = $false
        # The visible controls are validated exactly like GENERATE does.
        $cw=0; $chh=0
        if(-not [int]::TryParse($wBox.Text,[ref]$cw) -or -not [int]::TryParse($hBox.Text,[ref]$chh) -or $cw -lt 64 -or $chh -lt 64 -or $cw -gt 8192 -or $chh -gt 8192){[System.Windows.Forms.MessageBox]::Show('Width and height (main window) must be between 64 and 8192 pixels.','Invalid dimensions')|Out-Null;return}
        $cst=0; $ccf=0.0; $csd=0
        if(-not [int]::TryParse($steps.Text,[ref]$cst) -or $cst -lt 1 -or $cst -gt 200){[System.Windows.Forms.MessageBox]::Show('Steps (main window) must be between 1 and 200.','Invalid steps')|Out-Null;return}
        if(-not (ConvertTo-MossDouble $cfg.Text ([ref]$ccf)) -or $ccf -le 0 -or $ccf -gt 30){[System.Windows.Forms.MessageBox]::Show('CFG scale (main window) must be greater than 0 and no more than 30.','Invalid CFG')|Out-Null;return}
        if(-not [int]::TryParse($seed.Text,[ref]$csd) -or $csd -lt -1){[System.Windows.Forms.MessageBox]::Show('Seed (main window) must be -1 (random) or a non-negative integer.','Invalid seed')|Out-Null;return}
        $cPrompt=($prompt.Text -replace "(\r?\n)+",' ').Trim()
        if(-not $cPrompt){
            # The prompt box is empty: fall back to the image's own prompt from
            # its sidecar (decrypted only when the history code was entered),
            # and prefill the box so the user can see what will be used.
            $side=[System.IO.Path]::ChangeExtension($selFile,'.json')
            if (Test-Path -LiteralPath $side -PathType Leaf) {
                try {
                    $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json
                    if (-not $script:HistoryLocked -and $script:HistoryPassphrase -and $sc.PromptProtected) {
                        try { $dp = Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase; if ($dp) { $cPrompt = ([string]$dp -replace "(\r?\n)+",' ').Trim(); $prompt.Text=[string]$dp } } catch {}
                    }
                } catch {}
            }
        }
        if(-not $cPrompt){[System.Windows.Forms.MessageBox]::Show('No prompt found. Enter one in the main window, or enter your history code so MOSS can read the prompt stored with this image.','Prompt required')|Out-Null;return}
        $cStrength=0.6; $t=0.0; if (ConvertTo-MossDouble ([string]$script:Settings.ImproveStrength) ([ref]$t)) { if($t -ge 0.05 -and $t -le 0.95){ $cStrength=$t } }
        $cStrength=Get-MossImproveStrength $selFile $cStrength
        $useSeed=$csd; if($useSeed -lt 0){ $useSeed=Get-Random -Minimum 1 -Maximum 2147483000 }
        # Show the source image's real dimensions and the final size up front.
        $csW=0; $csH=0
        try { $img=[System.Drawing.Image]::FromFile($selFile); $csW=$img.Width; $csH=$img.Height; $img.Dispose() } catch {}
        $finalMP = [Math]::Round((([double]$cw * [double]$chh) / 1000000.0), 1)
        $sizeLine = ''
        if ($csW -gt 0) { $sizeLine = ("`r`nSource image: {0} x {1} ({2} MP)  ->  final: {3} x {4} ({5} MP)" -f $csW,$csH,[Math]::Round((([double]$csW * [double]$csH) / 1000000.0),1),$cw,$chh,$finalMP) }
        $bigNote = if ($finalMP -gt 4.5) { "`r`n`r`nAbove what most GPUs render natively - it will be rendered at HALF SIZE with all steps and enlarged automatically. Tip: for the best big-image quality, work natively up to 2048 x 2048 and improve THAT image 2x." } else { '' }
        $isPreview=Test-MossFastPreview $selFile
        $settingsLine=("`r`n{0} x {1}, steps {2}, CFG {3}, seed {4}, strength {5}" -f $cw,$chh,$cst,$ccf,$useSeed,$cStrength)
        if($isPreview){
            $settingsLine+=("`r`n`r`nThis is an upscaled fast preview, so a raised strength is used automatically: detail is regenerated instead of inheriting the blurry enlargement, while the composition comes from your image. If the result still looks soft, raise 'Improve strength' in Options; if the scene starts to drift, lower it.")
        }else{
            $settingsLine+=("`r`n`r`nImage-to-image: the composition comes from the selected image.")
        }
        $settingsLine+=$sizeLine+$bigNote
        $answer=[System.Windows.Forms.MessageBox]::Show(("Improving {0} using the settings currently in the main window:{1}`r`n`r`nThe prompt is the text in the prompt box. Start?" -f [System.IO.Path]::GetFileName($selFile),$settingsLine),'Improve with current settings',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $useSampler=$null; if([string]$script:Settings.SamplingMethod -ne 'Default (model)'){ $useSampler=[string]$script:Settings.SamplingMethod }
        $useSched=$null; if([string]$script:Settings.Scheduler -ne 'Default (model)'){ $useSched=[string]$script:Settings.Scheduler }
        [void]$script:RefineQueue.Add([pscustomobject]@{ File=$selFile; W=$cw; H=$chh; Seed=$useSeed; Prompt=$cPrompt; NegativePrompt=[string]$script:Settings.NegativePrompt; SamplingMethod=$useSampler; Scheduler=$useSched; Strength=$cStrength; Steps=$cst; Cfg=$ccf; Tag='hq'; SrcW=$csW; SrcH=$csH })
        $script:RefineTotal = $script:RefineQueue.Count
        Start-MossNextRefine
    }

    function Start-MossRefineAll {
        # Bulk improve: only files that still have quality headroom are queued -
        # soft fast-mode previews, renders with fewer steps than the current
        # setting, or images smaller than the current size setting. Files that
        # are already at full quality (or already have an improved copy) are
        # skipped and reported.
        if ($script:GenState.IsRunning) { $status.Text='Busy - wait for the current run to finish.'; return }
        if ($script:GeneratedFiles.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Generate images first.','Nothing to improve')|Out-Null;return }
        $script:GenState.CancelRequested = $false
        $curSteps=[int]$script:Settings.Steps; $curW=[int]$script:Settings.Width; $curH=[int]$script:Settings.Height
        $bulkStrength=0.6; $t=0.0; if (ConvertTo-MossDouble ([string]$script:Settings.ImproveStrength) ([ref]$t)) { if($t -ge 0.05 -and $t -le 0.95){ $bulkStrength=$t } }
        $improvedSources=New-Object System.Collections.Generic.List[string]
        foreach($f in @($script:GeneratedFiles)){
            $j=[System.IO.Path]::ChangeExtension([string]$f,'.json')
            if(Test-Path -LiteralPath $j){ try { $sc=Get-Content -LiteralPath $j -Raw|ConvertFrom-Json; if($sc.InitImage){ $improvedSources.Add([string]$sc.InitImage) } } catch {} }
        }
        $eligible=New-Object System.Collections.ArrayList
        $skippedQuality=0; $skippedImproved=0; $skippedBroken=0
        foreach($f in @($script:GeneratedFiles)){
            $name=[System.IO.Path]::GetFileName([string]$f)
            if($improvedSources -contains $name){ $skippedImproved++; continue }
            $d = Get-MossImproveDefaults ([string]$f) 1
            if($d.Error -ne ''){ $skippedBroken++; continue }
            $speedMode='Exact'; $upscaled=$false; $oldSteps=0
            $sidecar=[System.IO.Path]::ChangeExtension([string]$f,'.json')
            if(Test-Path -LiteralPath $sidecar){
                try { $sc=Get-Content -LiteralPath $sidecar -Raw|ConvertFrom-Json
                      if($sc.SpeedMode){$speedMode=[string]$sc.SpeedMode}
                      if($sc.UpscaledFrom){$upscaled=$true}
                      if($sc.Steps){$oldSteps=[int]$sc.Steps} } catch {}
            }
            $realW=0; $realH=0
            try { $img=[System.Drawing.Image]::FromFile([string]$f); $realW=$img.Width; $realH=$img.Height; $img.Dispose() } catch {}
            $canImprove=$false; $reason=''
            if($speedMode -ne 'Exact' -or $upscaled){ $canImprove=$true; $reason='soft preview (fast mode)' }
            elseif($oldSteps -gt 0 -and $oldSteps -lt $curSteps){ $canImprove=$true; $reason=("only {0} steps" -f $oldSteps) }
            elseif($realW -gt 0 -and $realW -lt $curW -and $realH -lt $curH){ $canImprove=$true; $reason='smaller than the current size' }
            if(-not $canImprove){ $skippedQuality++; continue }
            # Size headroom: scale the image up, aspect preserved, so its larger
            # side matches the current size setting.
            $tw=$d.TW; $th=$d.TH
            if($realW -gt 0 -and ($realW -lt $curW -or $realH -lt $curH)){
                $curLarge=[Math]::Max($curW,$curH); $realLarge=[Math]::Max($realW,$realH)
                if($curLarge -gt $realLarge){
                    $scale=$curLarge/$realLarge
                    $tw=[int][Math]::Min(8192,[Math]::Ceiling($d.TW*$scale)); $th=[int][Math]::Min(8192,[Math]::Ceiling($d.TH*$scale))
                }
            }
            if($d.Seed -lt 0){ $d.Seed=Get-Random -Minimum 1 -Maximum 2147483000 }
            [void]$eligible.Add([pscustomobject]@{ File=[string]$f; W=$tw; H=$th; Seed=$d.Seed; Prompt=[string]$d.Prompt; NegativePrompt=[string]$d.NegativePrompt; SamplingMethod=$d.SamplingMethod; Scheduler=$d.Scheduler; Strength=(Get-MossImproveStrength ([string]$f) $bulkStrength); Steps=$null; Cfg=$null; Tag='hq'; Reason=$reason; SrcW=$realW; SrcH=$realH })
        }
        if($eligible.Count -eq 0){
            [System.Windows.Forms.MessageBox]::Show(("No file qualifies for improvement - all {0} generated file(s) are already at full quality for the current settings." -f $script:GeneratedFiles.Count),'Improve all',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return
        }
        $skipNote=''
        if($skippedImproved -gt 0){ $skipNote+=("`r`n{0} already have an improved copy and will be skipped." -f $skippedImproved) }
        if($skippedQuality -gt 0){ $skipNote+=("`r`n{0} are already at full quality and will be skipped." -f $skippedQuality) }
        if($skippedBroken -gt 0){ $skipNote+=("`r`n{0} could not be read and will be skipped." -f $skippedBroken) }
        $answer=[System.Windows.Forms.MessageBox]::Show(("{0} of {1} file(s) qualify for improvement ({2} rendered in a fast mode, with fewer steps, or smaller than the current size).{3}`r`n`r`nThey are improved one after another with the current settings (steps {4}), each using its own seed, prompt and strength - fast previews automatically get a higher strength so detail is regenerated instead of the blurry enlargement. Cancel stops the queue. Start?" -f $eligible.Count,$script:GeneratedFiles.Count,(($eligible | ForEach-Object { $_.Reason } | Select-Object -Unique) -join ', '),$skipNote,$curSteps),'Improve all',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        foreach($e in $eligible){ [void]$script:RefineQueue.Add($e) }
        $script:RefineTotal = $script:RefineQueue.Count
        $log.AppendText(("`r`nBulk improvement: {0} file(s) queued." -f $eligible.Count))
        Start-MossNextRefine
    }

    function Remove-MossSelectedFile {
        # Deletes the selected image (and its sidecar) from disk and the list.
        $selFile = [string]$script:SelectedFile
        if(-not $selFile -or -not (Test-Path -LiteralPath $selFile -PathType Leaf)){
            [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first.','Delete file')|Out-Null;return
        }
        $answer=[System.Windows.Forms.MessageBox]::Show(("Delete this image permanently?`r`n$selFile"),'Delete file',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        # Release the preview first so the file is not held open while deleting.
        try { $old=$preview.Image; $preview.Image=$null; if($old){ $old.Dispose() } } catch {}
        try { Remove-Item -LiteralPath $selFile -Force } catch { [System.Windows.Forms.MessageBox]::Show(('Could not delete the image: '+$_.Exception.Message),'Delete file')|Out-Null;return }
        $side=[System.IO.Path]::ChangeExtension($selFile,'.json')
        if(Test-Path -LiteralPath $side){ try { Remove-Item -LiteralPath $side -Force } catch {} }
        $idx=-1; for($i=0;$i -lt $fileList.Items.Count;$i++){ if([string]$fileList.Items[$i] -eq $selFile){ $idx=$i; break } }
        if($idx -ge 0){ $fileList.Items.RemoveAt($idx) }
        [void]$script:GeneratedFiles.Remove($selFile)
        $script:SelectedFile=$null
        if($fileList.Items.Count -gt 0){ $fileList.SelectedIndex=$fileList.Items.Count-1 }
        $status.Text='File deleted.'
    }

    function Show-MossImageInfo {
        # Shows what is stored for the selected image: prompt (decrypted only
        # when the history code was entered), negative prompt, seed, size,
        # steps, CFG, speed mode, sampler, scheduler and origin. Read-only.
        $selFile = [string]$script:SelectedFile
        if (-not $selFile -or -not (Test-Path -LiteralPath $selFile -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first (left-click it), then right-click again.','Image info')|Out-Null;return
        }
        $imgW=0; $imgH=0
        try { $img=[System.Drawing.Image]::FromFile($selFile); $imgW=$img.Width; $imgH=$img.Height; $img.Dispose() } catch {}
        $prompt=''; $promptLockedNote=''; $neg=''
        $lines=New-Object System.Collections.Generic.List[string]
        $lines.Add(('File: ' + [System.IO.Path]::GetFileName($selFile)))
        if($imgW -gt 0){ $lines.Add(('Size: ' + $imgW + ' x ' + $imgH)) }
        $side=[System.IO.Path]::ChangeExtension($selFile,'.json')
        if (Test-Path -LiteralPath $side -PathType Leaf) {
            try {
                $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json
                if ($sc.Seed) { $lines.Add(('Seed: ' + [string]$sc.Seed)) }
                $setLine=''
                if ($sc.Steps) { $setLine=('steps ' + [string]$sc.Steps) }
                if ($sc.CfgScale) { if($setLine){$setLine+=', '}; $setLine+=('CFG ' + [string]$sc.CfgScale) }
                if ($sc.Sampler) { $setLine+=(', sampler ' + [string]$sc.Sampler) }
                if ($sc.Scheduler) { $setLine+=(', scheduler ' + [string]$sc.Scheduler) }
                if ($setLine) { $lines.Add(('Settings: ' + $setLine)) }
                $speedLine=''
                if ($sc.SpeedMode) { $speedLine=('Speed mode: ' + [string]$sc.SpeedMode) }
                if ($sc.UpscaledFrom) { $speedLine+=(' (rendered small, enlarged: ' + [string]$sc.UpscaledFrom + ')') }
                if ($speedLine) { $lines.Add($speedLine) }
                if ($sc.InitImage) {
                    $lines.Add(('Origin: improved copy of ' + [string]$sc.InitImage + $(if($sc.InitStrength){' (image-to-image strength ' + [string]$sc.InitStrength + ')'}else{''})))
                } else {
                    $lines.Add('Origin: original generation')
                }
                if ($sc.GeneratedAt) { $lines.Add(('Created: ' + [string]$sc.GeneratedAt)) }
                if ($sc.PromptProtected) {
                    if (-not $script:HistoryLocked -and $script:HistoryPassphrase) {
                        try { $p = Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase; if ($p) { $prompt=[string]$p } else { $promptLockedNote='(encrypted - the history code did not unlock it)' } } catch { $promptLockedNote='(encrypted - enter your history code in MOSS to see the prompt)' }
                    } else {
                        $promptLockedNote='(encrypted - enter your history code in MOSS to see the prompt)'
                    }
                } else {
                    $promptLockedNote='(not saved - no history code was active when this image was created)'
                }
                if ($sc.NegativePromptProtected) {
                    if (-not $script:HistoryLocked -and $script:HistoryPassphrase) {
                        try { $np = Unprotect-MossPayload ([string]$sc.NegativePromptProtected) $script:HistoryPassphrase; if ($np) { $neg=[string]$np } } catch {}
                    }
                }
            } catch {
                $lines.Add('Info file could not be read: ' + $_.Exception.Message)
            }
        } else {
            $lines.Add('No info file (.json) was found next to this image.')
        }
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Image info'; $g.Size=New-Object System.Drawing.Size(660,540); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $lp=New-Object System.Windows.Forms.Label; $lp.Text='Prompt used for this image'; $lp.Location=New-Object System.Drawing.Point(12,10); $lp.Size=New-Object System.Drawing.Size(400,18); $lp.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($lp)
        $pBox=New-Object System.Windows.Forms.TextBox; $pBox.Multiline=$true; $pBox.ReadOnly=$true; $pBox.ScrollBars='Vertical'; $pBox.WordWrap=$true; $pBox.Text=$(if($prompt){$prompt}else{$promptLockedNote}); $pBox.Location=New-Object System.Drawing.Point(12,30); $pBox.Size=New-Object System.Drawing.Size(620,120); $pBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $pBox.ForeColor=$cText; $pBox.BorderStyle='FixedSingle'; $g.Controls.Add($pBox)
        $ln=New-Object System.Windows.Forms.Label; $ln.Text='Negative prompt'; $ln.Location=New-Object System.Drawing.Point(12,158); $ln.Size=New-Object System.Drawing.Size(400,18); $ln.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($ln)
        $nBox=New-Object System.Windows.Forms.TextBox; $nBox.Multiline=$true; $nBox.ReadOnly=$true; $nBox.ScrollBars='Vertical'; $nBox.WordWrap=$true; $nBox.Text=$(if($neg){$neg}else{'(none)'}); $nBox.Location=New-Object System.Drawing.Point(12,178); $nBox.Size=New-Object System.Drawing.Size(620,48); $nBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $nBox.ForeColor=$cText; $nBox.BorderStyle='FixedSingle'; $g.Controls.Add($nBox)
        $ls=New-Object System.Windows.Forms.Label; $ls.Text='Settings and origin (also stored in the .json file next to the image)'; $ls.Location=New-Object System.Drawing.Point(12,234); $ls.Size=New-Object System.Drawing.Size(560,18); $ls.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($ls)
        $sBox=New-Object System.Windows.Forms.TextBox; $sBox.Multiline=$true; $sBox.ReadOnly=$true; $sBox.ScrollBars='Vertical'; $sBox.Text=($lines -join "`r`n"); $sBox.Location=New-Object System.Drawing.Point(12,254); $sBox.Size=New-Object System.Drawing.Size(620,190); $sBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $sBox.ForeColor=$cText; $sBox.BorderStyle='FixedSingle'; $g.Controls.Add($sBox)
        $copyBtn=New-Object System.Windows.Forms.Button; $copyBtn.Text='Copy prompt'; $copyBtn.Location=New-Object System.Drawing.Point(400,456); $copyBtn.Size=New-Object System.Drawing.Size(110,30); $copyBtn.Enabled=[bool]$prompt; $g.Controls.Add($copyBtn)
        $closeBtn=New-Object System.Windows.Forms.Button; $closeBtn.Text='Close'; $closeBtn.Location=New-Object System.Drawing.Point(522,456); $closeBtn.Size=New-Object System.Drawing.Size(110,30); $g.Controls.Add($closeBtn)
        $copyBtn.Add_Click({ if($prompt){ try { [System.Windows.Forms.Clipboard]::SetText($prompt) } catch {} } })
        $closeBtn.Add_Click({ $g.Close() })
        $g.AcceptButton=$closeBtn; $g.CancelButton=$closeBtn
        $g.ShowDialog()|Out-Null
        $g.Dispose()
    }

    function Start-MossNextRefine {
        # Sequentially processes the improvement queue (one engine run per image).
        if ($script:GenState.IsRunning) { return }
        if ($script:GenState.CancelRequested) { if($script:RefineQueue.Count -gt 0){ $log.AppendText("`r`nImprovement queue cancelled.") }; $script:RefineQueue.Clear(); $script:RefineTotal = 0; return }
        if ($script:RefineQueue.Count -eq 0) {
            if ($script:RefineTotal -gt 0) {
                $status.Text = "Improvement finished - $script:RefineTotal image(s) processed"
                $log.AppendText("`r`nImprovement finished - $script:RefineTotal image(s) processed.")
                $script:RefineTotal = 0
            }
            return
        }
        $item = $script:RefineQueue[0]
        $script:RefineQueue.RemoveAt(0)
        $refineEngine = Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
        $refinePaths = @($refineEngine,
            (Get-AbsoluteAppPath ([string]$script:Settings.DiffusionModelPath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.LlmPath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.VaePath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.TokenizerPath)))
        $missingRefine = @($refinePaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if ($missingRefine.Count -gt 0) {
            $log.AppendText("`r`nImprovement stopped - required file(s) not found: $($missingRefine -join ', ')")
            $script:RefineQueue.Clear(); $script:RefineTotal = 0
            $status.Text = 'Improvement stopped - missing model files (click Model files to check the paths)'
            return
        }
        $gpuIdx=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $gpuIdx=[int]$script:Settings.PreferredGpuIndex } catch { $gpuIdx=-1 } }
        # Very large improve targets cannot be rendered natively on most GPUs
        # (the engine then dies silently, usually out of memory). Above ~4.5
        # megapixels the improve is rendered at HALF SIZE with the full step
        # count and enlarged to the full target afterwards - the same faithful
        # pipeline as the fast generation speed modes (no second sampling pass).
        $refineSpeed = 'Exact'
        $targetMP = ([double]$item.W * [double]$item.H) / 1000000.0
        if ($targetMP -gt 4.5) {
            $refineSpeed = '4x'
            $log.AppendText(("`r`nNote: {0} x {1} is too large for a native render on most GPUs - rendering at half size with all {2} steps and enlarging to full size (fast-mode pipeline, never distorted)." -f $item.W, $item.H, $(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps})))
        }
        $isFresh = $false; if ($item.PSObject.Properties['FreshRender']) { $isFresh = [bool]$item.FreshRender }
        $job=[pscustomobject]@{Engine=$refinePaths[0];Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$refinePaths[1];Llm=$refinePaths[2];Vae=$refinePaths[3];Tokenizer=$refinePaths[4];OutputPath=(Get-AbsoluteAppPath ([string]$script:Settings.OutputPath));Steps=$(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps});Cfg=$(if($null -ne $item.Cfg){[double]$item.Cfg}else{[double]$script:Settings.CfgScale});Width=[int]$item.W;Height=[int]$item.H;Count=1;Seed=[long]$item.Seed;Prompt=[string]$item.Prompt;GpuIndex=$gpuIdx;SpeedMode=$refineSpeed;InitImage=$(if($isFresh){$null}else{[string]$item.File});InitStrength=$(if($isFresh){0.0}else{[double]$item.Strength});RefineTag=[string]$item.Tag;NegativePrompt=$item.NegativePrompt;SamplingMethod=$item.SamplingMethod;Scheduler=$item.Scheduler}
        $status.Text = ("Improving image {0} of {1} at {2} x {3}..." -f ($script:RefineTotal - $script:RefineQueue.Count), $script:RefineTotal, $item.W, $item.H)
        if ($isFresh) {
            $status.Text = ("Re-rendering image {0} of {1} at {2} x {3}..." -f ($script:RefineTotal - $script:RefineQueue.Count), $script:RefineTotal, $item.W, $item.H)
            $log.AppendText(("`r`nRe-rendering from the same seed: {0}, same prompt, fresh full-quality sampling at {1} x {2} (no image-to-image - like a new generation; the composition can differ from the draft)" -f $item.Seed, $item.W, $item.H))
        } elseif (Test-MossFastPreview ([string]$item.File)) {
            $log.AppendText(("`r`nImproving: seed {0}, image-to-image from {1} ({2} x {3}) -> final {4} x {5} (strength {6} - fast preview, detail regenerated over the enlarged draft, composition kept from the image)" -f $item.Seed, [System.IO.Path]::GetFileName([string]$item.File), $(if($item.SrcW){[int]$item.SrcW}else{0}), $(if($item.SrcH){[int]$item.SrcH}else{0}), $item.W, $item.H, $item.Strength))
        } else {
            $log.AppendText(("`r`nImproving: same seed {0}, same prompt, image-to-image from {1} ({2} x {3}) -> final {4} x {5} (strength {6})" -f $item.Seed, [System.IO.Path]::GetFileName([string]$item.File), $(if($item.SrcW){[int]$item.SrcW}else{0}), $(if($item.SrcH){[int]$item.SrcH}else{0}), $item.W, $item.H, $item.Strength))
        }
        Start-MossGeneration -Job $job -ForRefine
    }

    # --- end Timer + Process worker ---

    $generate.Add_Click({
        # Prompts are sent to the engine as a single line; pasted multi-line text is
        # flattened so no characters are lost or misinterpreted in process arguments.
        $p=($prompt.Text -replace "(\r?\n)+",' ').Trim(); if(-not $p){[System.Windows.Forms.MessageBox]::Show('Enter an image prompt first.','Prompt required')|Out-Null;return}
        $enginePath=Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
        $paths=@($enginePath,(Get-AbsoluteAppPath $modelControls.DiffusionModelPath.Text),(Get-AbsoluteAppPath $modelControls.LlmPath.Text),(Get-AbsoluteAppPath $modelControls.VaePath.Text),(Get-AbsoluteAppPath $modelControls.TokenizerPath.Text))
        foreach($path in $paths){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){[System.Windows.Forms.MessageBox]::Show("Required file not found:`r`n$path`r`n`r`nCheck Hardware / Setup or the model file paths.",'Missing file',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null;return}}
        $outPath=Get-AbsoluteAppPath $out.Text.Trim();if(-not $outPath){[System.Windows.Forms.MessageBox]::Show('Choose an output folder.','Output folder')|Out-Null;return};if(-not(Test-Path -LiteralPath $outPath)){New-Item -ItemType Directory -Path $outPath -Force|Out-Null}
        $wi=0;$he=0;if(-not [int]::TryParse($wBox.Text,[ref]$wi) -or -not [int]::TryParse($hBox.Text,[ref]$he) -or $wi -lt 64 -or $he -lt 64 -or $wi -gt 8192 -or $he -gt 8192){[System.Windows.Forms.MessageBox]::Show('Width and height must be between 64 and 8192 pixels.','Invalid dimensions')|Out-Null;return}
        $st=0;$cf=0.0;$sd=0;if(-not [int]::TryParse($steps.Text,[ref]$st) -or $st -lt 1 -or $st -gt 200){[System.Windows.Forms.MessageBox]::Show('Steps must be between 1 and 200.','Invalid steps')|Out-Null;return};if(-not (ConvertTo-MossDouble $cfg.Text ([ref]$cf)) -or $cf -le 0 -or $cf -gt 30){[System.Windows.Forms.MessageBox]::Show('CFG scale must be greater than 0 and no more than 30 (dot or comma both work, e.g. 3.5 or 3,5).','Invalid CFG')|Out-Null;return};if(-not [int]::TryParse($seed.Text,[ref]$sd) -or $sd -lt -1){[System.Windows.Forms.MessageBox]::Show('Seed must be -1 (random) or a non-negative integer.','Invalid seed')|Out-Null;return}
        # Image count: any whole number >= 1 - no artificial cap. Practical
        # limits (disk space, hours of runtime) are the user's choice, with a
        # plain-language warning for very large batches.
        $n=0; if(-not [int]::TryParse(([string]$count.Text).Trim(),[ref]$n) -or $n -lt 1){[System.Windows.Forms.MessageBox]::Show('Number of images must be a whole number of 1 or more.','Invalid image count')|Out-Null;return}
        if($n -gt 200){
            $hours=[Math]::Round($n*0.35/60,1)
            $bigAnswer=[System.Windows.Forms.MessageBox]::Show(("You are about to render {0} images in one batch. This can run for many hours (rough estimate: {1} h) and needs disk space for {0} images. Cancel stops it at any time. Start now?" -f $n,$hours),'Large batch',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if($bigAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        }
        # Keep the random base seed low enough that base+count stays inside the
        # engine's 32-bit seed range even for very large batches.
        $baseSeed=$sd;if($baseSeed -eq -1){$baseSeed=Get-Random -Minimum 1 -Maximum ([Math]::Max(2, 2147483000 - [Math]::Min($n, 2000000000)))}
        if(($wi -ge 2560 -or $he -ge 2560) -and [System.Windows.Forms.MessageBox]::Show("You are about to render at $wi x $he directly. Large renders can use substantial VRAM and RAM and may take a long time. Continue?",'Large image warning',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -ne 'Yes'){return}
        $script:Settings.ImageStyle=[string]$style.SelectedItem;$script:Settings.EnginePath=Get-RelativeAppPath $enginePath;$script:Settings.DiffusionModelPath=Get-RelativeAppPath $paths[1];$script:Settings.LlmPath=Get-RelativeAppPath $paths[2];$script:Settings.VaePath=Get-RelativeAppPath $paths[3];$script:Settings.TokenizerPath=Get-RelativeAppPath $paths[4];$script:Settings.OutputPath=Get-RelativeAppPath $outPath;$script:Settings.Steps=$st;$script:Settings.CfgScale=$cf;$script:Settings.Width=$wi;$script:Settings.Height=$he;$script:Settings.ImageCount=$n;$script:Settings.Seed=$sd
        if (-not $script:HistoryLocked) { $hist=@($p)+@($history|Where-Object{$_ -ne $p});$history=@($hist|Select-Object -First 20);$script:Settings.PromptHistory=$history } else { $script:Settings.PromptHistory=@() };if(-not (Save-Settings)){[System.Windows.Forms.MessageBox]::Show('Set a password to save private prompt history. Generation was not started.','Password required')|Out-Null;return};if (-not $script:HistoryLocked) { if($historyPick.Items.Count -eq 0 -or [string]$historyPick.Items[0] -ne $p){$historyPick.Items.Insert(0,$p)};while($historyPick.Items.Count -gt 10){$historyPick.Items.RemoveAt($historyPick.Items.Count-1)} }
        # 'None (no style)' falls through to default{''}: the prompt is sent
        # exactly as typed, with nothing prepended.
        $stylePrefix=switch([string]$style.SelectedItem){'Photorealistic'{'photorealistic, lifelike, realistic textures, natural lighting'}'Anime'{'anime style, expressive line art, cel shading'}'Digital illustration'{'polished digital illustration'}'Oil painting'{'oil painting, rich brush strokes'}'Watercolor'{'watercolor painting, soft pigment texture'}'3D render'{'high quality 3D render, detailed materials'}'Comic book'{'comic book art, inked outlines, bold colors'}'Cinematic'{'cinematic composition, dramatic lighting'}'Fantasy art'{'epic fantasy art, dramatic lighting, highly detailed'}'Dark fantasy / gothic'{'dark fantasy, gothic atmosphere, moody dramatic shadows'}'Cyberpunk / sci-fi'{'cyberpunk, neon lights, futuristic, rain-slick streets'}'Studio portrait'{'professional studio portrait, softbox lighting, clean background'}'Sketch / pencil drawing'{'detailed pencil sketch, graphite shading, white background'}'Pixel art'{'pixel art, 16-bit retro game style, crisp pixels'}'Synthwave / retro 80s'{'retro 80s synthwave, neon grid, sunset glow'}'Low poly 3D'{'low poly 3d render, flat shaded, minimalist'}default{''}}
        $generationPrompt=if($stylePrefix){"$stylePrefix, $p"}else{$p}
        $gpuIndex=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $gpuIndex=[int]$script:Settings.PreferredGpuIndex } catch { $gpuIndex=-1 } }
        $speedMode=switch([string]$speedCombo.SelectedItem){'~2x faster (upscale from 70%)'{'2x'}'~4x faster (upscale from 50%)'{'4x'}'~8x faster (upscale from 35%)'{'8x'}'Fastest (upscale from smallest)'{'Fast'}default{'Exact'}}
        $negPrompt=[string]$script:Settings.NegativePrompt
        $samplingMethod=$null; if([string]$script:Settings.SamplingMethod -and [string]$script:Settings.SamplingMethod -ne 'Default (model)'){ $samplingMethod=[string]$script:Settings.SamplingMethod }
        $scheduler=$null; if([string]$script:Settings.Scheduler -and [string]$script:Settings.Scheduler -ne 'Default (model)'){ $scheduler=[string]$script:Settings.Scheduler }
        $initImg=$null; if($script:PendingInitImage){ $initImg=[string]$script:PendingInitImage; $script:PendingInitImage=$null }
        $job=[pscustomobject]@{Engine=$enginePath;Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$paths[1];Llm=$paths[2];Vae=$paths[3];Tokenizer=$paths[4];OutputPath=$outPath;Steps=$st;Cfg=$cf;Width=$wi;Height=$he;Count=$n;Seed=$baseSeed;Prompt=$generationPrompt;GpuIndex=$gpuIndex;SpeedMode=$speedMode;InitImage=$initImg;InitStrength=0.45;NegativePrompt=$negPrompt;SamplingMethod=$samplingMethod;Scheduler=$scheduler}
        $generate.Enabled=$false;$cancel.Enabled=$true;$log.Clear();$status.Text='Starting engine...';Start-MossGeneration -Job $job
    })
    $cancel.Add_Click({
        if ($script:GenState.IsRunning) {
            $script:GenState.CancelRequested = $true
            $cancel.Enabled = $false
            $generate.Enabled = $false
            $status.Text = 'Cancelling generation...'
            $log.AppendText("`r`nCancellation requested. Stopping the engine and any child processes...")
            $f.Refresh()
            Stop-MossGen
            $generate.Enabled = $true
            $cancel.Enabled = $false
            $elapsedText = if ($script:GenState.JobStartedAt) { Format-MossDuration ((Get-Date) - $script:GenState.JobStartedAt).TotalSeconds } else { '0:00' }
            $status.Text = "Generation cancelled | total elapsed $elapsedText"
            $log.AppendText("`r`nGeneration cancelled. No further images will be started.")
        }
    })
    $openOut.Add_Click({$folder=Get-AbsoluteAppPath $out.Text;if(Test-Path -LiteralPath $folder){Start-Process explorer.exe -ArgumentList (Quote-ProcessArgument $folder)}})
    $f.Add_FormClosing({if($script:GenState.IsRunning){$script:GenState.CancelRequested=$true;Stop-MossGen}})
    $f.Add_Shown({
        Hide-MossConsoleWindow
        Unlock-MossHistoryAfterShow
        Test-MossOfferStartupDownload $f
    })
    [void]$f.ShowDialog()
    if($preview.Image){$preview.Image.Dispose()}
    if($f.Tag -eq 'SETUP'){
        $psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if(Test-Path -LiteralPath $psExe){Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-ProcessArgument $PSCommandPath),'-SetupOnly','-ReturnToGenerator')}
    }
}

# Show setup on first run or when explicitly requested. Otherwise open the generator directly.
# Hide the launcher console before ANY window appears (password prompt included).
try { Hide-MossConsoleWindow } catch {}
try {
    if ($SetupOnly -or -not [bool]$script:Settings.HardwareSetupComplete) {
        $form.Add_Shown({Hide-MossConsoleWindow}.GetNewClosure())
        [void]$form.ShowDialog()
    }
    if ((-not $SetupOnly -or $ReturnToGenerator) -and [bool]$script:Settings.HardwareSetupComplete) {
        Load-Settings
        # The history code prompt is raised from the generator's Shown event so
        # it appears over the main window, not as a floating pre-dialog.
        Show-GeneratorWindow
    }
} catch {
    # A startup error must never disappear silently (the console may already be hidden).
    $errText = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n$($_.Exception.GetType().FullName): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    try { [void](Write-MossErrorLog 'MOSS startup error' $errText) } catch {}
    try { [System.Windows.Forms.MessageBox]::Show(("MOSS Image Studio could not start.`r`n`r`n"+$_.Exception.Message+"`r`n`r`nA technical report was saved to the logs folder."),'MOSS Image Studio',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch {}
    exit 1
}













