# MOSS Image Studio - portable hardware setup foundation
# Windows PowerShell 5.1 | All paths are resolved relative to this script.
[CmdletBinding()]
param([switch]$SetupOnly,[switch]$ReturnToGenerator)

$ErrorActionPreference = 'Stop'
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigDir = Join-Path $script:AppRoot 'config'
$script:ConfigFile = Join-Path $script:ConfigDir 'settings.json'
$script:Settings = [ordered]@{ Backend = 'Auto'; BackendSelectionSaved = $false; EnginePath = (Join-Path $script:AppRoot 'bin\sd-cli.exe'); HardwareSetupComplete = $false; ImageStyle = 'Photorealistic' }
$script:HistoryPassphrase = $null
$script:HistoryLocked = $false
$script:LockedHistoryEnvelope = $null
$script:HistoryStoredEnvelope = $null
$script:HistoryPasswordVerifier = $null
$script:HistoryEnabled = $true
$script:AdultAccessVerifier = $null
$script:AdultPassphrase = $null
$script:AdultCodeSetup = 'Undecided'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-MossHistoryPassphrase([bool]$Create,[string]$Purpose='history') {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Create) { "Set $Purpose code" } else { "Enter $Purpose code" }
    $dialog.Size = New-Object System.Drawing.Size(440,220); $dialog.StartPosition='CenterScreen'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false; $dialog.Topmost=$true
    $label = New-Object System.Windows.Forms.Label; $label.Text = if ($Create) { "Choose a 4 to 16 character $Purpose code. Letters, numbers and symbols are allowed." } else { "Enter the $Purpose code." }; $label.Location=New-Object System.Drawing.Point(16,14); $label.Size=New-Object System.Drawing.Size(395,38); $dialog.Controls.Add($label)
    $first = New-Object System.Windows.Forms.TextBox; $first.Location=New-Object System.Drawing.Point(18,62); $first.Size=New-Object System.Drawing.Size(385,25); $first.UseSystemPasswordChar=$true; $dialog.Controls.Add($first)
    $confirm = $null
    if ($Create) { $confirmLabel=New-Object System.Windows.Forms.Label; $confirmLabel.Text='Confirm password'; $confirmLabel.Location=New-Object System.Drawing.Point(18,91); $confirmLabel.Size=New-Object System.Drawing.Size(150,18); $dialog.Controls.Add($confirmLabel); $confirm = New-Object System.Windows.Forms.TextBox; $confirm.Location=New-Object System.Drawing.Point(18,111); $confirm.Size=New-Object System.Drawing.Size(385,25); $confirm.UseSystemPasswordChar=$true; $dialog.Controls.Add($confirm) }
    $ok=New-Object System.Windows.Forms.Button; $ok.Text='Continue'; $ok.Location=New-Object System.Drawing.Point(218,145); $ok.DialogResult=[System.Windows.Forms.DialogResult]::OK; $dialog.Controls.Add($ok)
    $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Cancel'; $cancel.Location=New-Object System.Drawing.Point(308,145); $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $dialog.Controls.Add($cancel); $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    try {
        while ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
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

function Show-MossAdminCodeSetupChoice {
    $f=New-Object System.Windows.Forms.Form; $f.Text='Administrator code'; $f.Size=New-Object System.Drawing.Size(540,220); $f.StartPosition='CenterScreen'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.Topmost=$true
    $label=New-Object System.Windows.Forms.Label; $label.Text='No administrator code is set. You can create one now, or continue without using an administrator code.'; $label.Location=New-Object System.Drawing.Point(18,18); $label.Size=New-Object System.Drawing.Size(490,48); $f.Controls.Add($label)
    $create=New-Object System.Windows.Forms.Button; $create.Text='Create a code'; $create.Location=New-Object System.Drawing.Point(72,98); $create.Size=New-Object System.Drawing.Size(170,44); $create.Add_Click({$f.Tag='create';$f.Close()}.GetNewClosure()); $f.Controls.Add($create)
    $skip=New-Object System.Windows.Forms.Button; $skip.Text='Continue without a code'; $skip.Location=New-Object System.Drawing.Point(270,98); $skip.Size=New-Object System.Drawing.Size(190,44); $skip.Add_Click({$f.Tag='skip';$f.Close()}.GetNewClosure()); $f.Controls.Add($skip)
    try { [void]$f.ShowDialog(); if($f.Tag){return [string]$f.Tag}; return 'skip' } finally { $f.Dispose() }
}

function Show-MossAdminCodeRecoveryChoice {
    $f=New-Object System.Windows.Forms.Form; $f.Text='Administrator code'; $f.Size=New-Object System.Drawing.Size(540,220); $f.StartPosition='CenterScreen'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.Topmost=$true
    $label=New-Object System.Windows.Forms.Label; $label.Text='The administrator code was not accepted. Try entering it again, or remove the administrator code and continue without code protection.'; $label.Location=New-Object System.Drawing.Point(18,18); $label.Size=New-Object System.Drawing.Size(490,52); $f.Controls.Add($label)
    $retry=New-Object System.Windows.Forms.Button; $retry.Text='Try again'; $retry.Location=New-Object System.Drawing.Point(82,100); $retry.Size=New-Object System.Drawing.Size(160,44); $retry.Add_Click({$f.Tag='retry';$f.Close()}.GetNewClosure()); $f.Controls.Add($retry)
    $skip=New-Object System.Windows.Forms.Button; $skip.Text='Continue without code'; $skip.Location=New-Object System.Drawing.Point(270,100); $skip.Size=New-Object System.Drawing.Size(190,44); $skip.Add_Click({$f.Tag='skip';$f.Close()}.GetNewClosure()); $f.Controls.Add($skip)
    try { [void]$f.ShowDialog(); if($f.Tag){return [string]$f.Tag}; return 'retry' } finally { $f.Dispose() }
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

function Reset-MossHistoryPassword {
    $answer=[System.Windows.Forms.MessageBox]::Show('This clears the saved prompt history and replaces its code. The old history cannot be recovered afterward. Continue?','Reset history code',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $newPassword=Get-MossHistoryPassphrase $true
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

function Confirm-MossAdminAccess {
    if($script:AdultAccessVerifier){
        while($true){
            $code=Get-MossHistoryPassphrase $false 'administrator access'
            if($code -and (Test-MossHistoryPassphrase $code $script:AdultAccessVerifier)){$script:AdultPassphrase=$code;break}
            $choice=Show-MossAdminCodeRecoveryChoice
            if($choice -eq 'skip'){
                $script:AdultAccessVerifier=$null
                $script:AdultPassphrase=$null
                $script:AdultCodeSetup='Skipped'
                [void](Save-Settings)
                return $true
            }
        }
        return $true
    }
    if($script:AdultCodeSetup -eq 'Skipped'){return $true}
    $choice=Show-MossAdminCodeSetupChoice
    if($choice -eq 'create'){
        $code=Get-MossHistoryPassphrase $true 'administrator access'
        if(-not $code){return $false}
        $script:AdultAccessVerifier=Protect-MossPayload 'MOSS-ADULT-ACCESS-CHECK-V1' $code
        $script:AdultPassphrase=$code
        $script:AdultCodeSetup='Enabled'
        [void](Save-Settings)
        return $true
    }
    $script:AdultCodeSetup='Skipped'
    [void](Save-Settings)
    return $true
}

function Load-Settings([switch]$UnlockHistory) {
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($p.Name -notin @('PromptHistory','PromptHistoryProtected','HistoryPasswordVerifier','PromptHistoryEnabled','AdultAccessVerifier','ChildProfiles')) { $script:Settings[$p.Name] = $p.Value }
            }
            if ($saved.HistoryPasswordVerifier) { $script:HistoryPasswordVerifier=[string]$saved.HistoryPasswordVerifier }
            if ($saved.AdultAccessVerifier) { $script:AdultAccessVerifier=[string]$saved.AdultAccessVerifier }
            if ($saved.AdultCodeSetup) { $script:AdultCodeSetup=[string]$saved.AdultCodeSetup }
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
    $persist.AdultAccessVerifier=$script:AdultAccessVerifier
    $persist.AdultCodeSetup=$script:AdultCodeSetup
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
$form.Text = 'MOSS Image Studio | Hardware Setup'
$form.Size = New-Object System.Drawing.Size(900,650)
$form.MinimumSize = New-Object System.Drawing.Size(760,560)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(18,22,31)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230,236,245)
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)

$header = New-Object System.Windows.Forms.Panel
$header.Dock='Top'; $header.Height=76; $header.BackColor=[System.Drawing.Color]::FromArgb(25,32,45)
$form.Controls.Add($header)
$title = New-Object System.Windows.Forms.Label
$title.Text='MOSS  /  IMAGE STUDIO'; $title.Font=New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold)
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

$engineLabel=New-Object System.Windows.Forms.Label; $engineLabel.Text='Engine executable:'; $engineLabel.Location=New-Object System.Drawing.Point(24,496); $engineLabel.AutoSize=$true; $form.Controls.Add($engineLabel)
$engine=New-Object System.Windows.Forms.TextBox; $engine.Location=New-Object System.Drawing.Point(145,492); $engine.Size=New-Object System.Drawing.Size(590,26); $engine.Anchor='Top,Left,Right'; $engine.Text=[string]$script:Settings.EnginePath; $form.Controls.Add($engine)
$browse=New-Object System.Windows.Forms.Button; $browse.Text='Browse...'; $browse.Location=New-Object System.Drawing.Point(746,490); $browse.Size=New-Object System.Drawing.Size(114,30); $browse.Anchor='Top,Right'; $form.Controls.Add($browse)
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

$note=New-Object System.Windows.Forms.Label; $note.Location=New-Object System.Drawing.Point(24,535); $note.Size=New-Object System.Drawing.Size(830,36); $note.ForeColor=[System.Drawing.Color]::FromArgb(150,166,190)
$note.Text='Note: Windows display enumeration cannot prove CUDA / ROCm / SYCL support. The selected sd-cli.exe must be compiled for the chosen backend.'; $form.Controls.Add($note)

$refresh=New-Object System.Windows.Forms.Button; $refresh.Text='Rescan hardware'; $refresh.Location=New-Object System.Drawing.Point(24,580); $refresh.Size=New-Object System.Drawing.Size(130,32); $refresh.Anchor='Bottom,Left'; $form.Controls.Add($refresh)
$setupHistoryCode=New-Object System.Windows.Forms.Button; $setupHistoryCode.Text='Set / reset history code'; $setupHistoryCode.Location=New-Object System.Drawing.Point(350,580); $setupHistoryCode.Size=New-Object System.Drawing.Size(190,32); $setupHistoryCode.Anchor='Bottom,Left'; $form.Controls.Add($setupHistoryCode)
$setupHistoryCode.Add_Click({ if(Reset-MossHistoryPassword){[System.Windows.Forms.MessageBox]::Show('New history code saved. No prompt history is stored yet.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
$test=New-Object System.Windows.Forms.Button; $test.Text='Check backend support'; $test.Location=New-Object System.Drawing.Point(166,580); $test.Size=New-Object System.Drawing.Size(170,32); $test.Anchor='Bottom,Left'; $form.Controls.Add($test)
$save=New-Object System.Windows.Forms.Button; $save.Text='Save setup'; $save.Location=New-Object System.Drawing.Point(720,580); $save.Size=New-Object System.Drawing.Size(140,32); $save.Anchor='Bottom,Right'; $save.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $save.ForeColor=[System.Drawing.Color]::White; $save.FlatStyle='Flat'; $form.Controls.Add($save)
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
    $script:Settings.EnginePath=$engine.Text.Trim()
    $script:Settings.HardwareSetupComplete=$true
    Save-Settings
    $savedBackend = [string]$script:Settings.Backend
    $backendDisplay = "Backend: $savedBackend"
    $msg="Settings saved to:`r`n$script:ConfigFile`r`n`r`n$backendDisplay`r`nEngine: $($script:Settings.EnginePath)"
    if (-not (Test-Path -LiteralPath $script:Settings.EnginePath)) { $msg += "`r`n`r`nWARNING: Engine executable not found at this path. You can browse to it later." }
    [System.Windows.Forms.MessageBox]::Show($msg,'MOSS setup saved',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $form.Close()
})

$form.Add_Shown({ if (-not $script:Settings.HardwareSetupComplete) { [System.Windows.Forms.MessageBox]::Show('Welcome to MOSS Image Studio. Review the detected adapters and choose the backend that matches your engine build.','First-run setup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null } })

# ---------------- IMAGE GENERATOR ----------------
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
function Quote-ProcessArgument([string]$value) {
    if ($null -eq $value) { return '""' }
    return '"' + ($value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}
function Show-GeneratorWindow {
    $adminOutput=Join-Path $script:AppRoot 'outputs\admin'
    if(-not(Test-Path -LiteralPath $adminOutput)){New-Item -ItemType Directory -Path $adminOutput -Force|Out-Null}
    $script:Settings.OutputPath=Get-RelativeAppPath $adminOutput
    $defaults = [ordered]@{
        DiffusionModelPath = (Join-Path $script:AppRoot 'models\moss_image_sft_int8_convrot.safetensors')
        LlmPath = (Join-Path $script:AppRoot 'models\Qwen3.5-9B-Q4_K_M.gguf')
        VaePath = (Join-Path $script:AppRoot 'models\flux2-vae.safetensors')
        TokenizerPath = (Join-Path $script:AppRoot 'models\tokenizer_qwen3.5.json')
        OutputPath = $script:Settings.OutputPath
        Steps = 25; CfgScale = 3.0; Width = 1360; Height = 768; ImageCount = 1; Seed = -1
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

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'MOSS Image Studio | Generator'; $f.Size = New-Object System.Drawing.Size(1180,850); $f.MinimumSize = New-Object System.Drawing.Size(1000,740); $f.StartPosition='CenterScreen'
    $f.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $f.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $f.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cPanel=[System.Drawing.Color]::FromArgb(25,32,45); $cCard=[System.Drawing.Color]::FromArgb(27,34,47); $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185); $cAccent=[System.Drawing.Color]::FromArgb(45,112,173)

    $head=New-Object System.Windows.Forms.Panel; $head.Dock='Top'; $head.Height=68; $head.BackColor=$cPanel; $f.Controls.Add($head)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text='MOSS  /  IMAGE STUDIO'; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(20,9); $head.Controls.Add($ttl)
    $subt=New-Object System.Windows.Forms.Label; $subt.Text='LOCAL IMAGE GENERATION  -  RTX / CPU'; $subt.ForeColor=$cMuted; $subt.AutoSize=$true; $subt.Location=New-Object System.Drawing.Point(23,42); $head.Controls.Add($subt)
    $backendText=[string]$script:Settings.Backend; if (-not $script:Settings.BackendSelectionSaved) { $backendText='Not configured' }
    $backendBadge=New-Object System.Windows.Forms.Label; $backendBadge.Text="BACKEND  $backendText"; $backendBadge.AutoSize=$true; $backendBadge.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164); $backendBadge.Location=New-Object System.Drawing.Point(710,25); $backendBadge.Anchor='Top,Right'; $head.Controls.Add($backendBadge)
    $setupBtn=New-Object System.Windows.Forms.Button; $setupBtn.Text='Hardware / Setup'; $setupBtn.Size=New-Object System.Drawing.Size(130,30); $setupBtn.Location=New-Object System.Drawing.Point(1025,18); $setupBtn.Anchor='Top,Right'; $setupBtn.FlatStyle='Flat'; $setupBtn.BackColor=$cAccent; $setupBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($setupBtn)
    $setupBtn.Add_Click({ $f.Tag='SETUP'; $f.Close() })
$updateBtn=New-Object System.Windows.Forms.Button; $updateBtn.Text='Update MOSS'; $updateBtn.Size=New-Object System.Drawing.Size(130,30); $updateBtn.Location=New-Object System.Drawing.Point(880,18); $updateBtn.Anchor='Top,Right'; $updateBtn.FlatStyle='Flat'; $updateBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $updateBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($updateBtn)
$updateBtn.Add_Click({
    [System.Windows.Forms.MessageBox]::Show('The private MOSS releases page will open. Download MOSS-Image-Studio.zip, close MOSS, and extract the app files over the existing folder. Keep config, models, and outputs.','Update MOSS',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    try { Start-Process 'https://github.com/kukomamasan/moss-image-studio/releases/latest' } catch { [System.Windows.Forms.MessageBox]::Show('The releases page could not be opened. Go to the MOSS repository on GitHub and open Releases.','Update MOSS')|Out-Null }
})

    $left=New-Object System.Windows.Forms.Panel; $left.Location=New-Object System.Drawing.Point(18,84); $left.Size=New-Object System.Drawing.Size(700,710); $left.Anchor='Top,Bottom,Left'; $left.BackColor=$cCard; $f.Controls.Add($left)
    $right=New-Object System.Windows.Forms.Panel; $right.Location=New-Object System.Drawing.Point(735,84); $right.Size=New-Object System.Drawing.Size(415,710); $right.Anchor='Top,Bottom,Left,Right'; $right.BackColor=$cCard; $f.Controls.Add($right)
    function Add-Label($parent,[string]$text,[int]$x,[int]$y,[int]$w=200) { $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,22); $l.ForeColor=$cMuted; $parent.Controls.Add($l); return $l }
    function Add-TextBox($parent,[string]$value,[int]$x,[int]$y,[int]$w,[int]$h=26) { $t=New-Object System.Windows.Forms.TextBox; $t.Text=$value; $t.Location=New-Object System.Drawing.Point($x,$y); $t.Size=New-Object System.Drawing.Size($w,$h); $t.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $t.ForeColor=$cText; $t.BorderStyle='FixedSingle'; $parent.Controls.Add($t); return $t }
    function Add-Button($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h=29) { $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location=New-Object System.Drawing.Point($x,$y); $b.Size=New-Object System.Drawing.Size($w,$h); $b.FlatStyle='Flat'; $b.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $b.ForeColor=$cText; $parent.Controls.Add($b); return $b }

    Add-Label $left 'PROMPT' 18 14 180 | Out-Null
    $historyPick=New-Object System.Windows.Forms.ComboBox; $historyPick.DropDownStyle='DropDownList'; $historyPick.Location=New-Object System.Drawing.Point(315,9); $historyPick.Size=New-Object System.Drawing.Size(200,27); $historyPick.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $historyPick.ForeColor=$cText; $left.Controls.Add($historyPick)
    $resetHistoryCode=Add-Button $left 'Reset history code' 525 8 155 28
    $resetHistoryCode.Add_Click({ if(Reset-MossHistoryPassword){$history=@();$historyPick.Items.Clear();[System.Windows.Forms.MessageBox]::Show('New history code saved. The old history was cleared.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
    $resetHistoryCode.Enabled=$true
    foreach($oldPrompt in @($history | Select-Object -First 10)){[void]$historyPick.Items.Add([string]$oldPrompt)}
    $paste=Add-Button $left 'Paste from clipboard' 525 9 155
    $paste.Enabled=$true
    $prompt=New-Object System.Windows.Forms.TextBox; $prompt.Multiline=$true; $prompt.AcceptsReturn=$true; $prompt.AcceptsTab=$true; $prompt.ScrollBars='Vertical'; $prompt.Location=New-Object System.Drawing.Point(18,39); $prompt.Size=New-Object System.Drawing.Size(662,150); $prompt.Anchor='Top,Left,Right'; $prompt.Font=New-Object System.Drawing.Font('Segoe UI',10); $prompt.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $prompt.ForeColor=$cText; $prompt.BorderStyle='FixedSingle'; $left.Controls.Add($prompt)
    $prompt.ReadOnly=$false
    $paste.Add_Click({ try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $prompt.Text=[System.Windows.Forms.Clipboard]::GetText() } } catch { [System.Windows.Forms.MessageBox]::Show('Clipboard text could not be read.','Clipboard') | Out-Null } })
    $historyPick.Add_SelectedIndexChanged({if($historyPick.SelectedIndex -ge 0){$prompt.Text=[string]$historyPick.SelectedItem}})

    Add-Label $left 'IMAGE SETTINGS' 18 202 160 | Out-Null
    Add-Label $left 'VISUAL STYLE' 205 202 100 | Out-Null
    $style=New-Object System.Windows.Forms.ComboBox; $style.DropDownStyle='DropDownList'; $style.Location=New-Object System.Drawing.Point(290,199); $style.Size=New-Object System.Drawing.Size(250,28); $style.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $style.ForeColor=$cText; foreach($item in @('Photorealistic','Anime','Digital illustration','Oil painting','Watercolor','3D render','Comic book','Cinematic')){[void]$style.Items.Add($item)}; $style.SelectedItem=[string]$script:Settings.ImageStyle; if($style.SelectedIndex -lt 0){$style.SelectedIndex=0}; $left.Controls.Add($style)
    Add-Label $left 'Resolution' 18 231 90 | Out-Null
    $res=New-Object System.Windows.Forms.ComboBox; $res.DropDownStyle='DropDownList'; $res.Location=New-Object System.Drawing.Point(18,254); $res.Size=New-Object System.Drawing.Size(250,28); $res.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $res.ForeColor=$cText
    $resItems=@('Landscape 16:9  |  1360 x 768','Square  |  1024 x 1024','Portrait 3:4  |  768 x 1024','Landscape 4:3  |  1280 x 960','Portrait 9:16  |  768 x 1360','2K Landscape  |  2560 x 1440','2K Square  |  2048 x 2048','2K Portrait  |  1536 x 2048','2K 4:3  |  2048 x 1536','2K 9:16  |  1440 x 2560','4K Landscape  |  3840 x 2160','4K Square  |  4096 x 4096','4K Portrait  |  3072 x 4096','4K 4:3  |  4096 x 3072','4K 9:16  |  2160 x 3840','Custom dimensions')
    foreach($ri in $resItems){[void]$res.Items.Add($ri)}; $left.Controls.Add($res)
    $wBox=Add-TextBox $left ([string]$script:Settings.Width) 300 254 82; $hBox=Add-TextBox $left ([string]$script:Settings.Height) 395 254 82
    Add-Label $left 'Width' 300 231 80 | Out-Null; Add-Label $left 'Height' 395 231 80 | Out-Null
    $resMap=@(@(1360,768),@(1024,1024),@(768,1024),@(1280,960),@(768,1360),@(2560,1440),@(2048,2048),@(1536,2048),@(2048,1536),@(1440,2560),@(3840,2160),@(4096,4096),@(3072,4096),@(4096,3072),@(2160,3840))
    $matched=-1; for($ri=0;$ri -lt $resMap.Count;$ri++){if([int]$script:Settings.Width -eq $resMap[$ri][0] -and [int]$script:Settings.Height -eq $resMap[$ri][1]){$matched=$ri;break}}; if($matched -ge 0){$res.SelectedIndex=$matched}else{$res.SelectedIndex=15}
    $res.Add_SelectedIndexChanged({ if($res.SelectedIndex -ge 0 -and $res.SelectedIndex -lt $resMap.Count){$wBox.Text=[string]$resMap[$res.SelectedIndex][0];$hBox.Text=[string]$resMap[$res.SelectedIndex][1]} })
    Add-Label $left 'Steps' 18 302 70 | Out-Null; $steps=Add-TextBox $left ([string]$script:Settings.Steps) 18 325 75
    Add-Label $left 'CFG scale' 110 302 90 | Out-Null; $cfg=Add-TextBox $left ([string]$script:Settings.CfgScale) 110 325 75
    Add-Label $left 'Images' 202 302 70 | Out-Null; $count=New-Object System.Windows.Forms.ComboBox; $count.DropDownStyle='DropDownList'; $count.Location=New-Object System.Drawing.Point(202,325); $count.Size=New-Object System.Drawing.Size(75,26); foreach($n in @(1,2,4,8)){[void]$count.Items.Add([string]$n)}; $count.SelectedItem=[string]$script:Settings.ImageCount; if($count.SelectedIndex -lt 0){$count.SelectedIndex=0}; $left.Controls.Add($count)
    Add-Label $left 'Seed (-1 = random)' 300 302 150 | Out-Null; $seed=Add-TextBox $left ([string]$script:Settings.Seed) 300 325 90
    $performance=New-Object System.Windows.Forms.Label; $performance.Text='Performance: Automatic'; $performance.Location=New-Object System.Drawing.Point(410,327); $performance.Size=New-Object System.Drawing.Size(270,24); $performance.ForeColor=$cMuted; $left.Controls.Add($performance)
    Add-Label $left 'ADMIN OUTPUT FOLDER' 18 372 190 | Out-Null
    $out=Add-TextBox $left ([string]$script:Settings.OutputPath) 18 397 540; $out.Anchor='Top,Left,Right'; $out.ReadOnly=$true; $outBrowse=Add-Button $left 'Browse...' 570 396 110; $outBrowse.Anchor='Top,Right'; $outBrowse.Enabled=$false

    Add-Label $left 'MODEL FILES  (defaults use the portable models folder)' 18 440 500 | Out-Null
    $modelRows=@(
      @('Diffusion model','DiffusionModelPath','moss_image_sft_int8_convrot.safetensors'),
      @('LLM','LlmPath','Qwen3.5-9B-Q4_K_M.gguf'),
      @('VAE','VaePath','flux2-vae.safetensors'),
      @('Tokenizer','TokenizerPath','tokenizer_qwen3.5.json')
    )
    $modelControls=@{}
    $yy=466
    foreach($mr in $modelRows){
        Add-Label $left $mr[0] 18 ($yy+3) 105 | Out-Null
        $val=[string]$script:Settings[$mr[1]]; if([string]::IsNullOrWhiteSpace($val)){$val=Join-Path $script:AppRoot ('models\'+$mr[2])} else {$val=Get-AbsoluteAppPath $val}
        $tb=Add-TextBox $left $val 125 $yy 445; $tb.Anchor='Top,Left,Right'
        $br=Add-Button $left '...' 580 ($yy-1) 100; $br.Anchor='Top,Right'
        $key=$mr[1]; $br.Add_Click({$dlg=New-Object System.Windows.Forms.OpenFileDialog;$dlg.Title="Select $($mr[0]) file";$dlg.Filter='Model and data files|*.safetensors;*.gguf;*.json|All files (*.*)|*.*';$dlg.CheckFileExists=$true;$cur=Get-AbsoluteAppPath $tb.Text;if(Test-Path -LiteralPath $cur -PathType Leaf){$dlg.InitialDirectory=Split-Path -Parent $cur;$dlg.FileName=Split-Path -Leaf $cur}else{$modelsDir=Join-Path $script:AppRoot 'models';if(Test-Path -LiteralPath $modelsDir -PathType Container){$dlg.InitialDirectory=$modelsDir}};if($dlg.ShowDialog($f) -eq 'OK'){$tb.Text=$dlg.FileName};$dlg.Dispose()}.GetNewClosure())
        $modelControls[$key]=$tb; $yy+=34
    }

    $generate=Add-Button $left 'GENERATE IMAGES' 18 615 205 42; $generate.BackColor=$cAccent; $generate.ForeColor=[System.Drawing.Color]::White; $generate.Font=New-Object System.Drawing.Font('Segoe UI Semibold',10,[System.Drawing.FontStyle]::Bold)
    $cancel=Add-Button $left 'Cancel' 235 615 95 42; $cancel.Enabled=$false
    $openOut=Add-Button $left 'Open output folder' 342 615 140 42
    $btnReport=Add-Button $left 'Copy Error Report' 490 615 150 42
    $btnReport.Add_Click({ Copy-MossErrorReport })
    $status=New-Object System.Windows.Forms.Label; $status.Text='Ready'; $status.Location=New-Object System.Drawing.Point(18,670); $status.Size=New-Object System.Drawing.Size(660,24); $status.ForeColor=$cMuted; $left.Controls.Add($status)

    Add-Label $right 'OUTPUT PREVIEW' 16 14 200 | Out-Null
    $preview=New-Object System.Windows.Forms.PictureBox; $preview.Location=New-Object System.Drawing.Point(16,42); $preview.Size=New-Object System.Drawing.Size(383,285); $preview.Anchor='Top,Left,Right'; $preview.SizeMode='Zoom'; $preview.BackColor=[System.Drawing.Color]::FromArgb(13,17,24); $right.Controls.Add($preview)
    Add-Label $right 'GENERATED FILES' 16 342 200 | Out-Null
    $fileList=New-Object System.Windows.Forms.ListBox; $fileList.Location=New-Object System.Drawing.Point(16,368); $fileList.Size=New-Object System.Drawing.Size(383,150); $fileList.Anchor='Top,Left,Right'; $fileList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $fileList.ForeColor=$cText; $right.Controls.Add($fileList)
    $fileList.Add_SelectedIndexChanged({if($fileList.SelectedItem){$p=[string]$fileList.SelectedItem;if(Test-Path -LiteralPath $p){try{$old=$preview.Image;$preview.Image=[System.Drawing.Image]::FromFile($p);if($old){$old.Dispose()}}catch{}}}})
    Add-Label $right 'GENERATION LOG' 16 535 200 | Out-Null
    $log=New-Object System.Windows.Forms.TextBox; $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.Location=New-Object System.Drawing.Point(16,560); $log.Size=New-Object System.Drawing.Size(383,130); $log.Anchor='Top,Bottom,Left,Right'; $log.BackColor=[System.Drawing.Color]::FromArgb(13,17,24); $log.ForeColor=$cMuted; $right.Controls.Add($log)

    # --- Timer + Process generation worker (no BackgroundWorker) ---
    $script:GenState = @{
        IsRunning = $false
        Process = $null
        Timer = $null
        Job = $null
        Index = 0
        Results = $null
        StdOut = $null
        StdErr = $null
        OutEvent = $null
        ErrEvent = $null
        CancelRequested = $false
        CurrentFile = $null
        CurrentSeed = 0
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
        $script:GenState.CancelRequested = $true
        if ($null -ne $script:GenState.Timer) {
            try { $script:GenState.Timer.Stop() } catch {}
            try { $script:GenState.Timer.Dispose() } catch {}
            $script:GenState.Timer = $null
        }
        if ($null -ne $script:GenState.Process) {
            try {
                if (-not $script:GenState.Process.HasExited) {
                    $script:GenState.Process.Kill()
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
        $lines.Add(('Current index: ' + $st.Index))
        if ($null -ne $st.LastExitCode) { $lines.Add(('Last exit code: ' + $st.LastExitCode)) }
        if ($st.LastErrorSummary) { $lines.Add(('Last error summary: ' + $st.LastErrorSummary)) }
        if ($st.Job) {
            $j = $st.Job
            $lines.Add(('Job size: {0} x {1}, steps {2}, cfg {3}, count {4}, seed base {5}' -f $j.Width, $j.Height, $j.Steps, $j.Cfg, $j.Count, $j.Seed))
            $lines.Add(('Job offload: ' + $j.Offload))
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
            # Also save a copy under logs\
            try {
                $logDir = Join-Path $script:AppRoot 'logs'
                if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                $reportFile = Join-Path $logDir ('error-report-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
                $report | Set-Content -LiteralPath $reportFile -Encoding UTF8
                $status.Text = "Error report copied + saved to logs\\$(Split-Path -Leaf $reportFile)"
            } catch {}
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

    function Get-MossAutoOffload([string]$Backend) {
        # Prefer GPU-only execution for speed. CPU offload is enabled only when
        # available VRAM is below the model's approximate 12 GB working set.
        if ($Backend -eq 'CPU') { return $false }
        $freeMb = $null
        if ($Backend -eq 'CUDA') {
            $smi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
            if (-not $smi) {
                foreach ($candidate in @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:WINDIR\System32\nvidia-smi.exe")) {
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $smi = Get-Item -LiteralPath $candidate; break }
                }
            }
            if ($smi) {
                try {
                    $smiPath = if ($smi.PSObject.Properties.Name -contains 'Source' -and $smi.Source) { $smi.Source } else { $smi.FullName }
                    $reported = & $smiPath --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                    $parsed = 0
                    if ([int]::TryParse(([string]$reported).Trim(), [ref]$parsed)) { $freeMb = $parsed }
                } catch {}
            }
        } else {
            # Windows reports AdapterRAM as a 32-bit value. A value below 4 GB
            # proves the adapter is too small; larger values may be truncated.
            try {
                $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -notmatch '(?i)virtual|indirect|remote|displaylink' })
                $match = $null
                if ($Backend -match 'AMD|HIP|Vulkan') { $match = $controllers | Where-Object { $_.Name -match '(?i)AMD|Radeon' } | Select-Object -First 1 }
                elseif ($Backend -match 'SYCL|Intel') { $match = $controllers | Where-Object { $_.Name -match '(?i)Intel' } | Select-Object -First 1 }
                if ($match -and [long]$match.AdapterRAM -gt 0 -and [long]$match.AdapterRAM -lt 4294967295) { $freeMb = [Math]::Max(0, [Math]::Floor([long]$match.AdapterRAM / 1MB) - 2048) }
            } catch {}
        }
        if ($null -ne $freeMb) { return ([double]$freeMb -lt 12288) }
        return $false
    }

    function Update-MossLiveProgress {
        $st = $script:GenState
        if (-not $st.IsRunning -or $null -eq $st.Process -or $st.Process.HasExited) { return }
        $elapsed = 0.0
        if ($st.JobStartedAt) { $elapsed = [Math]::Max(0, ((Get-Date) - $st.JobStartedAt).TotalSeconds) }
        $imageElapsed = 0.0
        if ($st.ImageStartedAt) { $imageElapsed = [Math]::Max(0, ((Get-Date) - $st.ImageStartedAt).TotalSeconds) }
        $stdoutNow = [string]$st.StdOut.ToString()
        $stderrNow = [string]$st.StdErr.ToString()
        $engineProgress = $null
        $matches = [regex]::Matches(($stdoutNow + "`n" + $stderrNow), '(?im)\b(\d{1,3})\s*%')
        if ($matches.Count -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int]$matches[$matches.Count - 1].Groups[1].Value)) }
        if ($null -eq $engineProgress) {
            $matches = [regex]::Matches(($stdoutNow + "`n" + $stderrNow), '(?im)(?:\bstep\s*[:#]?\s*(\d+)\s*/\s*(\d+)\b|\b(\d+)\s*/\s*(\d+)\s*steps?\b)')
            if ($matches.Count -gt 0) {
                $last = $matches[$matches.Count - 1]
                if ($last.Groups[1].Success) { $numerator = [double]$last.Groups[1].Value; $denominator = [double]$last.Groups[2].Value }
                else { $numerator = [double]$last.Groups[3].Value; $denominator = [double]$last.Groups[4].Value }
                if ($denominator -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int](($numerator * 100) / $denominator))) }
            }
        }
        if ($null -ne $engineProgress) { $st.ImageProgress = [int]$engineProgress }
        $job = $st.Job
        $overall = [int][Math]::Floor((($st.Index * 100) + [int]$st.ImageProgress) / [Math]::Max(1, [int]$job.Count))
        $overall = [Math]::Max(0, [Math]::Min(99, $overall))
        $etaText = 'ETA calculating'
        $remaining = $null
        if ($null -ne $engineProgress -and $engineProgress -gt 0) {
            $imageTotalEstimate = $imageElapsed * 100.0 / $engineProgress
            $remaining = ($imageTotalEstimate - $imageElapsed) + ([Math]::Max(0, $job.Count - $st.Index - 1) * $imageTotalEstimate)
        } elseif ($st.ImageDurations.Count -gt 0) {
            $average = (($st.ImageDurations | Measure-Object -Average).Average)
            $remaining = [Math]::Max(0, $average - $imageElapsed) + ([Math]::Max(0, $job.Count - $st.Index - 1) * $average)
        }
        if ($null -ne $remaining) { $etaText = "ETA ~$(Format-MossDuration $remaining)" }
        $progressNote = if ($null -ne $engineProgress) { " | image $([int]$st.ImageProgress)%" } else { '' }
        $status.Text = "Image $($st.Index + 1) of $($job.Count) | $overall% overall$progressNote | total elapsed $(Format-MossDuration $elapsed) | $etaText"
    }


    function Complete-MossGen {
        param([string]$FinalStatus)
        Stop-MossGen
        $generate.Enabled = $true
        $cancel.Enabled = $false
        if ($FinalStatus) { $status.Text = $FinalStatus }
        if ($script:GenState.JobStartedAt) { $status.Text += " | total elapsed $(Format-MossDuration ((Get-Date) - $script:GenState.JobStartedAt).TotalSeconds)" }
    }

    function Start-MossNextImage {
        $st = $script:GenState
        $job = $st.Job
        if ($st.CancelRequested) {
            Complete-MossGen 'Generation cancelled'
            $log.AppendText("`r`nGeneration was cancelled by the user.")
            return
        }
        if ($st.Index -ge $job.Count) {
            $ok = @($st.Results | Where-Object { $_.ExitCode -eq 0 }).Count
            $total = $st.Results.Count
            if ($ok -eq $total -and $total -gt 0) { $msg = "Completed - $ok of $total image(s) generated" }
            elseif ($ok -gt 0) { $msg = "Partially completed - $ok of $total image(s) generated" }
            else { $msg = 'Generation failed - engine returned no successful images' }
            Complete-MossGen $msg
            if ($ok -gt 0) { $log.AppendText("`r`nCompleted. Output folder: $($job.OutputPath)") }
            if ($ok -lt $total) { $log.AppendText("`r`nOne or more engine runs failed. Review each image's exit code and engine output above.") }
            return
        }

        $i = $st.Index
        $thisSeed = $job.Seed + $i
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $file = Join-Path $job.OutputPath ("MOSS_{0}_{1:D2}.png" -f $stamp, ($i + 1))
        $st.CurrentFile = $file
        $st.CurrentSeed = $thisSeed

        $argsList = New-Object System.Collections.Generic.List[string]
        $argsList.Add('--diffusion-model'); $argsList.Add((Quote-ProcessArgument $job.Diffusion))
        $argsList.Add('--llm'); $argsList.Add((Quote-ProcessArgument $job.Llm))
        $argsList.Add('--vae'); $argsList.Add((Quote-ProcessArgument $job.Vae))
        $argsList.Add('--tokenizer'); $argsList.Add((Quote-ProcessArgument $job.Tokenizer))
        $argsList.Add('--cfg-scale'); $argsList.Add([string]$job.Cfg)
        $argsList.Add('--steps'); $argsList.Add([string]$job.Steps)
        $argsList.Add('-H'); $argsList.Add([string]$job.Height)
        $argsList.Add('-W'); $argsList.Add([string]$job.Width)
        $argsList.Add('-s'); $argsList.Add([string]$thisSeed)
        if ($job.Offload) { $argsList.Add('--offload-to-cpu') }
        $argsList.Add('-p'); $argsList.Add((Quote-ProcessArgument $job.Prompt))
        $argsList.Add('-o'); $argsList.Add((Quote-ProcessArgument $file))

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $job.Engine
        $psi.Arguments = ($argsList -join ' ')
        $psi.WorkingDirectory = $job.Root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

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
            $status.Text = ("Starting image {0} of {1} (seed {2})..." -f ($i + 1), $job.Count, $thisSeed)
        } catch {
            $msg = "Failed to start engine: $($_.Exception.Message)"
            $log.AppendText("`r`n$msg")
            [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = -1; Seed = $thisSeed; Output = $msg })
            $st.Index++
            Start-MossNextImage
        }
    }

    function On-MossGenTimerTick {
        $st = $script:GenState
        if ($null -eq $st.Process) { return }
        if (-not $st.Process.HasExited) { Update-MossLiveProgress; return }

        # Process finished
        $exitCode = $st.Process.ExitCode
        $st.LastExitCode = $exitCode
        $file = $st.CurrentFile
        $thisSeed = $st.CurrentSeed
        $i = $st.Index
        $job = $st.Job
        if ($st.ImageStartedAt) { [void]$st.ImageDurations.Add([Math]::Max(0.1, ((Get-Date) - $st.ImageStartedAt).TotalSeconds)) }

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
            $st.LastErrorSummary = "Engine exit code $exitCode for seed $thisSeed"
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

        $outputText = "Engine: $($job.Engine)`r`nWorking directory: $($job.Root)`r`nExit code: $exitCode`r`n--- STDOUT ---`r`n$stdout`r`n--- STDERR ---`r`n$stderr"

        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $file)) {
            try {
                $meta = [ordered]@{
                    Width = $job.Width; Height = $job.Height
                    Steps = $job.Steps; CfgScale = $job.Cfg; Seed = $thisSeed
                    Backend = $job.Backend; OffloadToCpu = $job.Offload
                    GeneratedAt = (Get-Date).ToString('o'); Engine = $job.Engine
                }
                if (-not $script:HistoryLocked -and $script:HistoryPassphrase) { $meta.PromptProtected = Protect-MossPayload ([string]$job.Prompt) $script:HistoryPassphrase }
                $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ([System.IO.Path]::ChangeExtension($file, '.json')) -Encoding UTF8
            } catch {
                $outputText += "`r`nMetadata sidecar could not be saved: $($_.Exception.Message)"
            }
        }
        if ($exitCode -ne 0) {
            $outputText = "ERROR: Engine process returned exit code $exitCode.`r`n" + $outputText
        } elseif (-not (Test-Path -LiteralPath $file)) {
            $outputText = "ERROR: Engine returned exit code 0 but the expected image file was not created: $file`r`n" + $outputText
        }

        [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = $outputText })

        # UI update (we are on the GUI thread via Timer)
        $status.Text = "Image $($i + 1) of $($job.Count) finished (exit $exitCode)"
        $log.AppendText("`r`n--- Image $($i + 1) | seed $thisSeed | exit $exitCode ---`r`n$outputText`r`n")
        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $file)) {
            [void]$fileList.Items.Add($file)
            [void]$script:GeneratedFiles.Add($file)
            $fileList.SelectedIndex = $fileList.Items.Count - 1
        }

        $st.Index++
        Start-MossNextImage
    }

    function Start-MossGeneration {
        param($Job)
        if ($script:GenState.IsRunning) { return }
        $script:GenState.IsRunning = $true
        $script:GenState.CancelRequested = $false
        $script:GenState.Job = $Job
        $script:GenState.Index = 0
        $script:GenState.Results = New-Object System.Collections.ArrayList
        $script:GenState.Process = $null
        $script:GenState.CurrentFile = $null
        $script:GenState.JobStartedAt = Get-Date

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 400
        $timer.Add_Tick({ On-MossGenTimerTick })
        $script:GenState.Timer = $timer
        $timer.Start()

        $generate.Enabled = $false
        $cancel.Enabled = $true
        $log.Clear()
        $fileList.Items.Clear()
        $status.Text = 'Starting engine...'

        Start-MossNextImage
    }
    # --- end Timer + Process worker ---

    $generate.Add_Click({
        $p=$prompt.Text.Trim(); if(-not $p){[System.Windows.Forms.MessageBox]::Show('Enter an image prompt first.','Prompt required')|Out-Null;return}
        $enginePath=Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
        $paths=@($enginePath,(Get-AbsoluteAppPath $modelControls.DiffusionModelPath.Text),(Get-AbsoluteAppPath $modelControls.LlmPath.Text),(Get-AbsoluteAppPath $modelControls.VaePath.Text),(Get-AbsoluteAppPath $modelControls.TokenizerPath.Text))
        foreach($path in $paths){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){[System.Windows.Forms.MessageBox]::Show("Required file not found:`r`n$path`r`n`r`nCheck Hardware / Setup or the model file paths.",'Missing file',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null;return}}
        $outPath=Get-AbsoluteAppPath $out.Text.Trim();if(-not $outPath){[System.Windows.Forms.MessageBox]::Show('Choose an output folder.','Output folder')|Out-Null;return};if(-not(Test-Path -LiteralPath $outPath)){New-Item -ItemType Directory -Path $outPath -Force|Out-Null}
        $wi=0;$he=0;if(-not [int]::TryParse($wBox.Text,[ref]$wi) -or -not [int]::TryParse($hBox.Text,[ref]$he) -or $wi -lt 64 -or $he -lt 64 -or $wi -gt 8192 -or $he -gt 8192){[System.Windows.Forms.MessageBox]::Show('Width and height must be between 64 and 8192 pixels.','Invalid dimensions')|Out-Null;return}
        $st=0;$cf=0.0;$sd=0;if(-not [int]::TryParse($steps.Text,[ref]$st) -or $st -lt 1 -or $st -gt 200){[System.Windows.Forms.MessageBox]::Show('Steps must be between 1 and 200.','Invalid steps')|Out-Null;return};if(-not [double]::TryParse($cfg.Text,[ref]$cf) -or $cf -le 0 -or $cf -gt 30){[System.Windows.Forms.MessageBox]::Show('CFG scale must be greater than 0 and no more than 30.','Invalid CFG')|Out-Null;return};if(-not [int]::TryParse($seed.Text,[ref]$sd) -or $sd -lt -1){[System.Windows.Forms.MessageBox]::Show('Seed must be -1 (random) or a non-negative integer.','Invalid seed')|Out-Null;return}
        $n=[int]$count.SelectedItem; $baseSeed=$sd;if($baseSeed -eq -1){$baseSeed=Get-Random -Minimum 1 -Maximum 2147483000}
        if(($wi -ge 2560 -or $he -ge 2560) -and [System.Windows.Forms.MessageBox]::Show("You are about to render at $wi x $he directly. Large renders can use substantial VRAM and RAM and may take a long time. Continue?",'Large image warning',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -ne 'Yes'){return}
        $script:Settings.ImageStyle=[string]$style.SelectedItem;$script:Settings.EnginePath=Get-RelativeAppPath $enginePath;$script:Settings.DiffusionModelPath=Get-RelativeAppPath $paths[1];$script:Settings.LlmPath=Get-RelativeAppPath $paths[2];$script:Settings.VaePath=Get-RelativeAppPath $paths[3];$script:Settings.TokenizerPath=Get-RelativeAppPath $paths[4];$script:Settings.OutputPath=Get-RelativeAppPath $outPath;$script:Settings.Steps=$st;$script:Settings.CfgScale=$cf;$script:Settings.Width=$wi;$script:Settings.Height=$he;$script:Settings.ImageCount=$n;$script:Settings.Seed=$sd
        if (-not $script:HistoryLocked) { $hist=@($p)+@($history|Where-Object{$_ -ne $p});$history=@($hist|Select-Object -First 20);$script:Settings.PromptHistory=$history } else { $script:Settings.PromptHistory=@() };if(-not (Save-Settings)){[System.Windows.Forms.MessageBox]::Show('Set a password to save private prompt history. Generation was not started.','Password required')|Out-Null;return};if (-not $script:HistoryLocked) { if($historyPick.Items.Count -eq 0 -or [string]$historyPick.Items[0] -ne $p){$historyPick.Items.Insert(0,$p)};while($historyPick.Items.Count -gt 10){$historyPick.Items.RemoveAt($historyPick.Items.Count-1)} }
        $stylePrefix=switch([string]$style.SelectedItem){'Photorealistic'{'photorealistic, lifelike, realistic textures, natural lighting'}'Anime'{'anime style, expressive line art, cel shading'}'Digital illustration'{'polished digital illustration'}'Oil painting'{'oil painting, rich brush strokes'}'Watercolor'{'watercolor painting, soft pigment texture'}'3D render'{'high quality 3D render, detailed materials'}'Comic book'{'comic book art, inked outlines, bold colors'}'Cinematic'{'cinematic composition, dramatic lighting'}default{''}}
        $generationPrompt=if($stylePrefix){"$stylePrefix, $p"}else{$p}
        $autoOffload = Get-MossAutoOffload ([string]$script:Settings.Backend)
        $job=[pscustomobject]@{Engine=$enginePath;Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$paths[1];Llm=$paths[2];Vae=$paths[3];Tokenizer=$paths[4];OutputPath=$outPath;Steps=$st;Cfg=$cf;Width=$wi;Height=$he;Count=$n;Seed=$baseSeed;Offload=$autoOffload;Prompt=$generationPrompt}
        $generate.Enabled=$false;$cancel.Enabled=$true;$log.Clear();$fileList.Items.Clear();$status.Text='Starting engine...';Start-MossGeneration -Job $job
    })
    $cancel.Add_Click({if($script:GenState.IsRunning){Stop-MossGen;$status.Text='Cancelling...';$generate.Enabled=$true;$cancel.Enabled=$false}})
    $openOut.Add_Click({$folder=Get-AbsoluteAppPath $out.Text;if(Test-Path -LiteralPath $folder){Start-Process explorer.exe -ArgumentList (Quote-ProcessArgument $folder)}})
    $f.Add_FormClosing({if($script:GenState.IsRunning){Stop-MossGen}})
    [void]$f.ShowDialog()
    if($preview.Image){$preview.Image.Dispose()}
    if($f.Tag -eq 'SETUP'){
        $psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if(Test-Path -LiteralPath $psExe){Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-ProcessArgument $PSCommandPath),'-SetupOnly','-ReturnToGenerator')}
    }
}

# Show setup on first run or when explicitly requested. Otherwise open the generator directly.
if ($SetupOnly -or -not [bool]$script:Settings.HardwareSetupComplete) {
    [void]$form.ShowDialog()
}
if ((-not $SetupOnly -or $ReturnToGenerator) -and [bool]$script:Settings.HardwareSetupComplete) {
    Load-Settings
    if(-not (Confirm-MossAdminAccess)){return}
    Load-Settings -UnlockHistory
    if($script:HistoryLocked){[System.Windows.Forms.MessageBox]::Show('MOSS will continue without prompt history. The encrypted adult history is preserved.','History locked')|Out-Null}
    Show-GeneratorWindow
}











