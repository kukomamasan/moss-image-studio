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
$script:AppVersion = '0.1.33'
$script:ConfigDir = Join-Path $script:AppRoot 'config'
$script:ConfigFile = Join-Path $script:ConfigDir 'settings.json'
$script:Settings = [ordered]@{ Backend = 'Auto'; BackendSelectionSaved = $false; EnginePath = (Join-Path $script:AppRoot 'bin\sd-cli.exe'); HardwareSetupComplete = $false; ImageStyle = 'Photorealistic'; PreferredGpuIndex = -1; PreferredGpuName = '' }
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
}
"@
    }
    $consoleHandle=[MossNativeWindow]::GetConsoleWindow()
    if($consoleHandle -ne [IntPtr]::Zero){[void][MossNativeWindow]::ShowWindow($consoleHandle,0)}
}

function Get-MossHistoryPassphrase([bool]$Create,[string]$Purpose='history',[System.Windows.Forms.Form]$Owner=$null) {
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
    # When this prompt is raised from the main window's Shown event, Windows
    # can activate another window right after the dialog's own Shown event
    # and steal the focus, so a short one-shot timer re-applies it.
    $dialog.Add_Shown({ [void]$first.Focus(); $first.Select() }.GetNewClosure())
    $focusTimer = New-Object System.Windows.Forms.Timer
    $focusTimer.Interval = 50
    $focusTimer.Add_Tick({ [void]$first.Focus(); $first.Select(); $focusTimer.Stop() }.GetNewClosure())
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
    $f.Text = "MOSS Image Studio v$($script:AppVersion) | Generator"; $f.Size = New-Object System.Drawing.Size(1180,850); $f.MinimumSize = New-Object System.Drawing.Size(1000,740); $f.StartPosition='CenterScreen'
    $f.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $f.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $f.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cPanel=[System.Drawing.Color]::FromArgb(25,32,45); $cCard=[System.Drawing.Color]::FromArgb(27,34,47); $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185); $cAccent=[System.Drawing.Color]::FromArgb(45,112,173)

    $head=New-Object System.Windows.Forms.Panel; $head.Dock='Top'; $head.Height=68; $head.BackColor=$cPanel; $f.Controls.Add($head)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text="MOSS  /  IMAGE STUDIO  v$($script:AppVersion)"; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(20,9); $head.Controls.Add($ttl)
    $gpuSubtitle='GPU: automatic'
    if($script:Settings.Contains('PreferredGpuIndex') -and [int]$script:Settings.PreferredGpuIndex -ge 0){ $gpuSubtitle="GPU: $($script:Settings.PreferredGpuName)" }
    $subt=New-Object System.Windows.Forms.Label; $subt.Text="LOCAL IMAGE GENERATION  -  $gpuSubtitle"; $subt.ForeColor=$cMuted; $subt.AutoSize=$true; $subt.Location=New-Object System.Drawing.Point(23,42); $head.Controls.Add($subt)
    $backendText=[string]$script:Settings.Backend; if (-not $script:Settings.BackendSelectionSaved) { $backendText='Not configured' }
    $backendBadge=New-Object System.Windows.Forms.Label; $backendBadge.Text="BACKEND  $backendText"; $backendBadge.AutoSize=$true; $backendBadge.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164); $backendBadge.Location=New-Object System.Drawing.Point(680,25); $backendBadge.Anchor='Top,Right'; $head.Controls.Add($backendBadge)
    $setupBtn=New-Object System.Windows.Forms.Button; $setupBtn.Text='Hardware / Setup'; $setupBtn.Size=New-Object System.Drawing.Size(130,30); $setupBtn.Location=New-Object System.Drawing.Point(1025,18); $setupBtn.Anchor='Top,Right'; $setupBtn.FlatStyle='Flat'; $setupBtn.BackColor=$cAccent; $setupBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($setupBtn)
    $setupBtn.Add_Click({ $f.Tag='SETUP'; $f.Close() })
$updateBtn=New-Object System.Windows.Forms.Button; $updateBtn.Text='Check updates'; $updateBtn.Size=New-Object System.Drawing.Size(130,30); $updateBtn.Location=New-Object System.Drawing.Point(880,18); $updateBtn.Anchor='Top,Right'; $updateBtn.FlatStyle='Flat'; $updateBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $updateBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($updateBtn)
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
            $candidate = Get-MossHistoryPassphrase $false $null $f
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
        $g.Text='Generation options'; $g.Size=New-Object System.Drawing.Size(560,500); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
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
        $note=New-Object System.Windows.Forms.Label; $note.Text="'Default (euler)' and 'Default (flux schedule)' use the engine's own choice - recommended unless you want to experiment. Quick improve reuses the image's own settings; 'Improve using the settings in the main window' applies the values you see now."; $note.Location=New-Object System.Drawing.Point(12,366); $note.Size=New-Object System.Drawing.Size(520,34); $note.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($note)
        $negOk=Add-Button $g 'Save' 350 404 80 30
        $negCancel=Add-Button $g 'Cancel' 440 404 90 30
        $negOk.Add_Click({
            $impCheck=0.0
            $script:Settings.NegativePrompt=($box.Text -replace "(\r?\n)+",' ').Trim()
            $saveSampler=[string]$optSampler.SelectedItem; if($saveSampler -eq 'Default (euler)'){$saveSampler='Default (model)'}
            $saveSched=[string]$optSched.SelectedItem; if($saveSched -eq 'Default (flux schedule)'){$saveSched='Default (model)'}
            $script:Settings.SamplingMethod=$saveSampler
            $script:Settings.Scheduler=$saveSched
            if(-not (ConvertTo-MossDouble $impStrengthBox.Text ([ref]$impCheck)) -or $impCheck -lt 0.05 -or $impCheck -gt 0.95){[System.Windows.Forms.MessageBox]::Show('Improve strength must be between 0.05 and 0.95 (use a dot or a comma for decimals, e.g. 0.6 or 0,6).','Invalid strength')|Out-Null;return}
            $script:Settings.ImproveStrength=ConvertFrom-MossDouble $impCheck
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
        # Same sidecar-aware path as the right-click menu: seed, prompt, sampler,
        # scheduler and negative prompt are reused from the image itself, the
        # output gets the _hq tag, and the strength adapts to the source.
        if ($script:GenState.IsRunning) { return }
        if ($script:GeneratedFiles -and $script:GeneratedFiles.Count -gt 0) {
            $script:SelectedFile = [string]$script:GeneratedFiles[$script:GeneratedFiles.Count - 1]
            Start-MossRefineSelected 1
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
    $tip.SetToolTip($refineNative,'Takes your most recent image and re-renders it at full quality: same composition, same seed and prompt, more detail. Right-click any file in Generated files to improve that one instead.')
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
    $miSame=$refineMenu.Items.Add('Improve this image (full quality)')
    $miBig=$refineMenu.Items.Add('Improve this image (2x bigger)')
    $miCustom=$refineMenu.Items.Add('Improve using the settings in the main window...')
    $miAll=$refineMenu.Items.Add('Improve ALL files that can be improved...')
    $miInfo=$refineMenu.Items.Add('Show image info (prompt, seed, settings)...')
    $miDelete=$refineMenu.Items.Add('Delete this file')
    $fileList.ContextMenuStrip=$refineMenu
    $miSame.Add_Click({ Start-MossRefineSelected 1 })
    $miBig.Add_Click({ Start-MossRefineSelected 2 })
    $miCustom.Add_Click({ Start-MossRefineWithCurrentSettings })
    $miAll.Add_Click({ Start-MossRefineAll })
    $miInfo.Add_Click({ Show-MossImageInfo })
    $miDelete.Add_Click({ Remove-MossSelectedFile })
    $refineMenu.ShowItemToolTips=$true
    $miSame.ToolTipText='Improve this image at its current size: same seed and prompt, image-to-image keeps the composition. Fast previews get a higher strength automatically so detail is regenerated instead of the blurry enlargement.'
    $miBig.ToolTipText='Improve this image at double size: more resolution, about four times the rendering time.'
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
        if ($exitCode -ne 0 -or $missing.Count -gt 0) { $log.AppendText("`r`nOne or more images failed. Engine output above; a technical report was saved to the logs folder.") }
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

    function Start-MossRefineSelected([double]$sizeFactor) {
        # Quick improve: re-render the file selected in Generated Files with the
        # image's own settings (same seed and prompt), one click.
        if ($script:GenState.IsRunning) { $status.Text='Busy - wait for the current run to finish, then right-click again.'; return }
        $selFile = [string]$script:SelectedFile
        if (-not $selFile -or -not (Test-Path -LiteralPath $selFile -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first (left-click it), then right-click to improve it.','Improve image')|Out-Null;return
        }
        # A fresh right-click is a new user action: forget any earlier cancel.
        $script:GenState.CancelRequested = $false
        $d = Get-MossImproveDefaults $selFile $sizeFactor
        if ($d.Error -eq 'size') { [System.Windows.Forms.MessageBox]::Show('Could not determine the image size.','Improve image')|Out-Null;return }
        if (($d.TW -ge 2560 -or $d.TH -ge 2560) -and [System.Windows.Forms.MessageBox]::Show(("Improving will render at {0} x {1}. Large renders use substantial VRAM/RAM and take a long time. Continue?" -f $d.TW,$d.TH),'Large image improvement',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes){return}
        if ($d.Seed -lt 0) { $d.Seed = Get-Random -Minimum 1 -Maximum 2147483000 }
        $quickStrength=0.6; $t=0.0; if (ConvertTo-MossDouble ([string]$script:Settings.ImproveStrength) ([ref]$t)) { if($t -ge 0.05 -and $t -le 0.95){ $quickStrength=$t } }
        $quickStrength=Get-MossImproveStrength $d.File $quickStrength
        [void]$script:RefineQueue.Add([pscustomobject]@{ File=$d.File; W=$d.TW; H=$d.TH; Seed=$d.Seed; Prompt=[string]$d.Prompt; NegativePrompt=[string]$d.NegativePrompt; SamplingMethod=$d.SamplingMethod; Scheduler=$d.Scheduler; Strength=$quickStrength; Steps=$null; Cfg=$null; Tag=$(if($sizeFactor -gt 1){'hq2x'}else{'hq'}) })
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
        if(($cw -ge 2560 -or $chh -ge 2560) -and [System.Windows.Forms.MessageBox]::Show(("Improving will render at {0} x {1}. Large renders use substantial VRAM/RAM and take a long time. Continue?" -f $cw,$chh),'Large image improvement',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $isPreview=Test-MossFastPreview $selFile
        if($isPreview){
            $settingsLine=("`r`n{0} x {1}, steps {2}, CFG {3}, seed {4}, strength {5}`r`n`r`nThis is an upscaled fast preview, so a raised strength is used automatically: detail is regenerated instead of inheriting the blurry enlargement, while the composition comes from your image. If the result still looks soft, raise 'Improve strength' in Options; if the scene starts to drift, lower it." -f $cw,$chh,$cst,$ccf,$useSeed,$cStrength)
        }else{
            $settingsLine=("`r`n{0} x {1}, steps {2}, CFG {3}, seed {4}, strength {5}`r`n`r`nImage-to-image: the composition comes from the selected image." -f $cw,$chh,$cst,$ccf,$useSeed,$cStrength)
        }
        $answer=[System.Windows.Forms.MessageBox]::Show(("Improving {0} using the settings currently in the main window:{1}`r`n`r`nThe prompt is the text in the prompt box. Start?" -f [System.IO.Path]::GetFileName($selFile),$settingsLine),'Improve with current settings',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $useSampler=$null; if([string]$script:Settings.SamplingMethod -ne 'Default (model)'){ $useSampler=[string]$script:Settings.SamplingMethod }
        $useSched=$null; if([string]$script:Settings.Scheduler -ne 'Default (model)'){ $useSched=[string]$script:Settings.Scheduler }
        [void]$script:RefineQueue.Add([pscustomobject]@{ File=$selFile; W=$cw; H=$chh; Seed=$useSeed; Prompt=$cPrompt; NegativePrompt=[string]$script:Settings.NegativePrompt; SamplingMethod=$useSampler; Scheduler=$useSched; Strength=$cStrength; Steps=$cst; Cfg=$ccf; Tag='hq' })
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
            [void]$eligible.Add([pscustomobject]@{ File=[string]$f; W=$tw; H=$th; Seed=$d.Seed; Prompt=[string]$d.Prompt; NegativePrompt=[string]$d.NegativePrompt; SamplingMethod=$d.SamplingMethod; Scheduler=$d.Scheduler; Strength=(Get-MossImproveStrength ([string]$f) $bulkStrength); Steps=$null; Cfg=$null; Tag='hq'; Reason=$reason })
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
        $job=[pscustomobject]@{Engine=$refinePaths[0];Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$refinePaths[1];Llm=$refinePaths[2];Vae=$refinePaths[3];Tokenizer=$refinePaths[4];OutputPath=(Get-AbsoluteAppPath ([string]$script:Settings.OutputPath));Steps=$(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps});Cfg=$(if($null -ne $item.Cfg){[double]$item.Cfg}else{[double]$script:Settings.CfgScale});Width=[int]$item.W;Height=[int]$item.H;Count=1;Seed=[long]$item.Seed;Prompt=[string]$item.Prompt;GpuIndex=$gpuIdx;SpeedMode='Exact';InitImage=[string]$item.File;InitStrength=[double]$item.Strength;RefineTag=[string]$item.Tag;NegativePrompt=$item.NegativePrompt;SamplingMethod=$item.SamplingMethod;Scheduler=$item.Scheduler}
        $status.Text = ("Improving image {0} of {1} at {2} x {3}..." -f ($script:RefineTotal - $script:RefineQueue.Count), $script:RefineTotal, $item.W, $item.H)
        if (Test-MossFastPreview ([string]$item.File)) {
            $log.AppendText(("`r`nImproving: seed {0}, image-to-image from {1} (strength {2} - fast preview, detail regenerated over the enlarged draft, composition kept from the image)" -f $item.Seed, [System.IO.Path]::GetFileName([string]$item.File), $item.Strength))
        } else {
            $log.AppendText(("`r`nImproving: same seed {0}, same prompt, image-to-image from {1} (strength {2})" -f $item.Seed, [System.IO.Path]::GetFileName([string]$item.File), $item.Strength))
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











