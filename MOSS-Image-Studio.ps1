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
$script:AppVersion = '0.2.6'
$script:ConfigDir = Join-Path $script:AppRoot 'config'
$script:ConfigFile = Join-Path $script:ConfigDir 'settings.json'
$script:Settings = [ordered]@{ Backend = 'Auto'; BackendSelectionSaved = $false; EnginePath = (Join-Path $script:AppRoot 'bin\sd-cli.exe'); HardwareSetupComplete = $false; ImageStyle = 'Photorealistic'; PreferredGpuIndex = -1; PreferredGpuName = ''; ShowEngineCommandLine = '1'; SafeMode = $true; PowerSaver = 'Off' }
$script:HistoryPassphrase = $null
# POWER SAVER (v0.2.5): top-level setter because menu click handlers run in
# closures where '$script:' may not reach the app scope (same rule the GPU
# scan follows with Set-MossInventory).
function Set-MossPowerSaver([string]$Mode) {
    if (@('Off','Gentle','Max saving') -notcontains $Mode) { $Mode = 'Off' }
    $script:Settings.PowerSaver = $Mode
    Save-Settings
}
$script:HistoryLocked = $false
$script:LockedHistoryEnvelope = $null
$script:HistoryPasswordVerifier = $null
# Cache of derived key material (PBKDF2, 250000 iterations): one full
# derivation takes a noticeable moment on the UI thread, and it used to run
# AGAIN for every single encrypt/decrypt - saving settings, writing each
# image sidecar, opening the improve dialog, every wrong code attempt.
# Protected by a random IV per envelope, the cache only removes repeated
# key derivation, not any security check.
$script:MossKdfCache = @{}
$script:HistoryEnabled = $true
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- v0.2.2: dark theme for the native dropdowns --------------------------------
# WinForms draws a ComboBox with the WINDOWS theme whenever visual styles are
# enabled, so BackColor/ForeColor are IGNORED: every dropdown showed up as a
# bright white box inside the dark MOSS window (Visual style, Resolution,
# Images, the speed mode and the prompt-history list). The themed drop-down
# button was also painted by the system itself, and at 175 % scaling that
# button landed a few pixels off the field, so the combo looked split in two.
# FlatStyle=Flat makes WinForms paint the whole control itself - dark field,
# no system button - and the small chevron overlay below takes the place of
# the pale button that FlatStyle still leaves at the right edge.
function Set-MossComboTheme([System.Windows.Forms.ComboBox]$Combo,[System.Windows.Forms.Control]$Parent){
    $field=[System.Drawing.Color]::FromArgb(16,21,30)
    $text=[System.Drawing.Color]::FromArgb(230,236,245)
    $line=[System.Drawing.Color]::FromArgb(70,85,110)
    try {
        $Combo.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat
        $Combo.BackColor=$field
        $Combo.ForeColor=$text
    } catch { return }
    # Owner-draw the open list as well: a DropDownList renders its popup
    # with the system list colours, which would flash a white box over the
    # dark window every time a dropdown is opened. (The editable Images
    # combo keeps the standard list - its popup is typed into.)
    if ($Combo.DropDownStyle -eq [System.Windows.Forms.ComboBoxStyle]::DropDownList) {
        try {
            $Combo.DrawMode=[System.Windows.Forms.DrawMode]::OwnerDrawFixed
            $Combo.ItemHeight=18
            $Combo.Add_DrawItem({
                param($sender,$e)
                $g=$e.Graphics
                $b=$e.Bounds
                # The selected row keeps a clear highlight - filling every row
                # with the field colour would otherwise hide it completely.
                $isSel=(($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
                $bg=$field; $fg=$text
                if($isSel){ $bg=[System.Drawing.Color]::FromArgb(45,112,173); $fg=[System.Drawing.Color]::FromArgb(255,255,255) }
                $g.FillRectangle((New-Object System.Drawing.SolidBrush($bg)),$b)
                $txt=''
                if($e.Index -lt 0){ $txt=[string]$sender.Text } else { $txt=[string]$sender.Items[$e.Index] }
                $br=New-Object System.Drawing.SolidBrush($fg)
                $fmt=New-Object System.Drawing.StringFormat
                $fmt.LineAlignment=[System.Drawing.StringAlignment]::Center
                $fmt.Trimming=[System.Drawing.StringTrimming]::EllipsisCharacter
                $fmt.FormatFlags=([System.Drawing.StringFormatFlags]::LineLimit -bor [System.Drawing.StringFormatFlags]::NoWrap)
                $rect=New-Object System.Drawing.RectangleF(($b.X+4),($b.Y+0.5),($b.Width-8),($b.Height-1))
                $g.DrawString($txt,$sender.Font,$br,$rect,$fmt)
                $br.Dispose(); $fmt.Dispose()
            }.GetNewClosure())
        } catch {}
    }
    if (-not $Parent) { $Parent=$Combo.Parent }
    if (-not $Parent) { return }
    $arrowW=22
    $ov=New-Object System.Windows.Forms.Panel
    $ov.Name='mossComboChevron'
    $ov.BackColor=$field
    $ov.TabStop=$false
    $ov.Size=New-Object System.Drawing.Size($arrowW,([int]$Combo.Height-1))
    $ov.Location=New-Object System.Drawing.Point(([int]$Combo.Left+[int]$Combo.Width-$arrowW),[int]$Combo.Top)
    $ov.Add_Paint({
        param($s,$e)
        $g=$e.Graphics
        $g.FillRectangle((New-Object System.Drawing.SolidBrush($field)),$s.ClientRectangle)
        $pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170,188,214),1.6)
        $cx=[int]($s.ClientRectangle.Width/2); $cy=[int]($s.ClientRectangle.Height/2)
        $g.DrawLines($pen,@((New-Object System.Drawing.Point(($cx-4),($cy-2))),(New-Object System.Drawing.Point($cx,($cy+3))),(New-Object System.Drawing.Point(($cx+4),($cy-2)))))
        $pen.Dispose()
    }.GetNewClosure())
    $ov.Add_MouseDown({ param($s,$e) $Combo.Focus(); try { $Combo.DroppedDown=$true } catch {} }.GetNewClosure())
    $Parent.Controls.Add($ov)
    $Parent.Controls.SetChildIndex($ov,0)
    $sync={ $ov.Location=New-Object System.Drawing.Point(([int]$Combo.Left+[int]$Combo.Width-[int]$ov.Width),[int]$Combo.Top) }.GetNewClosure()
    $Combo.Add_LocationChanged($sync)
    $Combo.Add_SizeChanged($sync)
}


# SINGLE INSTANCE: launching the .bat twice would run two complete MOSS apps
# against the SAME settings.json and output folder - the instances overwrite
# each other's settings and compete for the same GPU memory (renders fail
# out-of-memory). A named mutex makes the second launch refuse politely.
# Windows releases the mutex automatically when the process exits, even
# after a crash, so a stuck MOSS can never lock the folder permanently.
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'MOSS-Image-Studio-Instance')
$instanceAcquired = $false
try { $instanceAcquired = $script:InstanceMutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $instanceAcquired = $true }
if (-not $instanceAcquired) {
    [System.Windows.Forms.MessageBox]::Show('MOSS is already running. Only one instance may use this folder at a time - two instances would overwrite each other''s settings and compete for the same GPU memory.','MOSS Image Studio',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 0
}

function Hide-MossConsoleWindow {
    if(-not ('Moss.MossNativeWindow' -as [type])) {
        # v0.2.3: -MemberDefinition instead of -TypeDefinition. -TypeDefinition
        # launches the C# compiler as a separate process: ~310 ms on EVERY
        # MOSS start. -MemberDefinition compiles the same three P/Invoke
        # signatures in ~60 ms.
        Add-Type -Namespace Moss -Name MossNativeWindow -MemberDefinition @'
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@ | Out-Null
    }
    $consoleHandle=[Moss.MossNativeWindow]::GetConsoleWindow()
    if($consoleHandle -ne [IntPtr]::Zero){[void][Moss.MossNativeWindow]::ShowWindow($consoleHandle,0)}
}

function Get-MossHistoryPassphrase([bool]$Create,[string]$Purpose='history',[System.Windows.Forms.Form]$Owner=$null) {
    # A call site that passes $null (older code did) would render the sentence
    # with a missing word ('Enter the  code.') - fall back to 'history'.
    if([string]::IsNullOrWhiteSpace($Purpose)){ $Purpose='history' }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Create) { "Set $Purpose code" } else { "Enter $Purpose code" }
    $dialog.Size = New-Object System.Drawing.Size(440,220); $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
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
    $f=New-Object System.Windows.Forms.Form; $f.Text='Prompt history options'; $f.Size=New-Object System.Drawing.Size(520,270); $f.StartPosition='CenterScreen'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false
    $label=New-Object System.Windows.Forms.Label; $label.Text='The code was not accepted. Choose how MOSS should continue.'; $label.Location=New-Object System.Drawing.Point(18,16); $label.Size=New-Object System.Drawing.Size(475,32); $f.Controls.Add($label)
    $items=@(@('Try again','retry'),@('Continue without history','skip'),@('Set a new code','reset'),@('Turn off prompt history','disable'))
    $positions=@(@(18,70),@(258,70),@(18,125),@(258,125))
    for($i=0;$i -lt $items.Count;$i++) { $b=New-Object System.Windows.Forms.Button; $b.Text=$items[$i][0]; $b.Location=New-Object System.Drawing.Point($positions[$i][0],$positions[$i][1]); $b.Size=New-Object System.Drawing.Size(220,38); $choiceTag=[string]$items[$i][1]; $b.Add_Click({$f.Tag=$choiceTag;$f.Close()}.GetNewClosure()); $f.Controls.Add($b) }
    try { [void]$f.ShowDialog(); if($f.Tag){return [string]$f.Tag}; return 'skip' } finally { $f.Dispose() }
}

function Protect-MossPayload([string]$Text,[string]$Password) {
    $iterations=250000
    # Derive the key material ONCE per code (session cache) instead of on
    # every call: sidecar writes for a 16-image batch used to run the full
    # 250000-iteration derivation up to 32 times on the UI thread. The salt
    # stays fixed per code for the session (standard practice - the key is
    # derived once, every envelope still gets its own random IV, and the
    # MAC covers salt, IV and ciphertext).
    $cacheKey='protect|'+[string]$Password
    $cached=$script:MossKdfCache[$cacheKey]
    if ($null -eq $cached) {
        $salt=New-Object byte[] 16; $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.Dispose()
        $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$salt,$iterations)
        try { $keys=$derive.GetBytes(64) } finally { $derive.Dispose() }
        $cached=@{ Salt=$salt; Keys=$keys }
        $script:MossKdfCache[$cacheKey]=$cached
    }
    $salt=[byte[]]$cached.Salt; $keys=[byte[]]$cached.Keys
    $iv=New-Object byte[] 16; $rngIv=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $rngIv.GetBytes($iv); $rngIv.Dispose()
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
    # Reuse derived key material per (code, salt, iteration count): the same
    # sidecars get decrypted again and again (improve dialog, improve runs),
    # and a wrong code attempt must not cost a second full derivation on the
    # next try. The cache is keyed by the code itself, so a wrong attempt can
    # never satisfy a later check with a different code.
    $cacheKey='unprotect|'+[string]$Password+'|'+[string]$envelope.Salt+'|'+[int]$envelope.Iterations
    $keys=$script:MossKdfCache[$cacheKey]
    if ($null -eq $keys) {
        $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$salt,[int]$envelope.Iterations)
        try { $keys=$derive.GetBytes(64) } finally { $derive.Dispose() }
        $script:MossKdfCache[$cacheKey]=[byte[]]$keys
    }
    $keys=[byte[]]$keys
    $authData=New-Object byte[] ($salt.Length+$iv.Length+$cipher.Length); [System.Buffer]::BlockCopy($salt,0,$authData,0,$salt.Length); [System.Buffer]::BlockCopy($iv,0,$authData,$salt.Length,$iv.Length); [System.Buffer]::BlockCopy($cipher,0,$authData,$salt.Length+$iv.Length,$cipher.Length)
    $hmac=[System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys[32..63]); try { $actual=$hmac.ComputeHash($authData) } finally { $hmac.Dispose() }
    $diff=$actual.Length -bxor $expected.Length; for($i=0;$i -lt [Math]::Min($actual.Length,$expected.Length);$i++){ $diff=$diff -bor ($actual[$i] -bxor $expected[$i]) }; if($diff -ne 0){ throw 'Incorrect password or damaged encrypted history.' }
    $aes=[System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Mode=[System.Security.Cryptography.CipherMode]::CBC; $aes.Padding=[System.Security.Cryptography.PaddingMode]::PKCS7; $aes.Key=$keys[0..31]; $aes.IV=$iv
    try { $dec=$aes.CreateDecryptor(); try { $plain=$dec.TransformFinalBlock($cipher,0,$cipher.Length) } finally { $dec.Dispose() } } finally { $aes.Dispose() }
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Reset-MossHistoryPassword([System.Windows.Forms.Form]$Owner=$null) {
    $answer=[System.Windows.Forms.MessageBox]::Show('This clears the saved prompt history and replaces its code. The old history cannot be recovered afterward. Continue?','Reset history code',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $newPassword=Get-MossHistoryPassphrase $true 'history' $Owner
    if(-not $newPassword){return $false}
    $script:HistoryPassphrase=$newPassword
    $script:HistoryPasswordVerifier=Protect-MossPayload 'MOSS-HISTORY-PASSWORD-CHECK-V1' $newPassword
    # The old code's cached key material is dead weight after a reset.
    $script:MossKdfCache.Clear()
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
    $script:MossKdfCache.Clear()
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
        # A code is set but was not entered: keep the encrypted envelope and
        # ask for the code at the next startup. Generation is NEVER blocked.
        if ($script:LockedHistoryEnvelope) { $persist.PromptHistoryProtected = $script:LockedHistoryEnvelope }
    } elseif ($script:HistoryPassphrase -and $script:HistoryPasswordVerifier) {
        # Code entered and unlocked: history stays encrypted.
        $historyJson = ConvertTo-Json -InputObject $history -Compress
        $persist.PromptHistoryProtected = Protect-MossPayload ([string]$historyJson) $script:HistoryPassphrase
        $persist.HistoryPasswordVerifier=$script:HistoryPasswordVerifier
    } elseif ($history.Count -gt 0) {
        # No code in use: history is stored PLAIN TEXT and generation is never
        # blocked. Setting a code remains possible via 'History code...'.
        $persist.PromptHistory = $history
    }
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

# --- v0.2.4: the GPU header without freezing the UI -------------------------
# The adapter scan (Get-CimInstance, ~120 ms) used to run on the UI thread
# right after the window appeared, so MOSS froze for a moment exactly when
# the user starts to work. It now runs on a BACKGROUND runspace: the header
# shows the CACHED card name instantly and the live scan replaces it when it
# lands. The setup dialog still runs its own full scan (with the nvidia-smi
# compute probe) when the user asks for it.
$script:GpuScanStarted = $false
$script:GpuScanConsumed = $false
$script:GpuScanItems = @()
$script:GpuScanJob = $null
$script:GpuScanRunner = $null
$script:GpuScanDone = $false

function Get-MossGpuCacheFile { return (Join-Path $script:ConfigDir 'gpu-cache.json') }
function Get-MossCachedGpuName {
    # The card name of the last successful scan ('' when there is none).
    try {
        $f = Get-MossGpuCacheFile
        if (Test-Path -LiteralPath $f) {
            $d = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($d -and $d.PSObject.Properties.Name -contains 'Name' -and [string]$d.Name) { return [string]$d.Name }
        }
    } catch {}
    return ''
}
function Save-MossCachedGpuName([string]$Name) {
    if (-not $Name) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $o = [ordered]@{ Name = $Name; SavedAt = (Get-Date).ToString('s') }
        [System.IO.File]::WriteAllText((Get-MossGpuCacheFile), ($o | ConvertTo-Json -Compress))
    } catch {}
}
function Start-MossGpuScan {
    # Starts the adapter scan on a background runspace. The scan script is
    # self-contained (a separate runspace cannot call the app's functions)
    # and returns the same fields as the adapter inventory helper.
    if ($script:GpuScanStarted) { return }
    $script:GpuScanStarted = $true
    try {
        $code = @'
$out = @()
try {
    foreach ($c in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
        $name = [string]$c.Name; $pnp = [string]$c.PNPDeviceID; $desc = [string]$c.Description
        $hay = "$name $desc $pnp"
        $vendor = 'Unknown'
        if ($hay -match '(?i)VEN_10DE|NVIDIA|GeForce|Quadro|Tesla') { $vendor = 'NVIDIA' }
        elseif ($hay -match '(?i)VEN_1002|VEN_1022|AMD|Radeon') { $vendor = 'AMD' }
        elseif ($hay -match '(?i)VEN_8086|Intel') { $vendor = 'Intel' }
        $isVirtual = ($hay -match '(?i)virtual|indirect display|remote display|parsec|spacedesk|usb display|displaylink|mirage|idd')
        $kind = if ($isVirtual) { 'Virtual display adapter' } elseif ($vendor -ne 'Unknown') { 'Physical/vendor adapter (compute capability not yet verified)' } else { 'Unclassified display adapter' }
        $backend = switch ($vendor) { 'NVIDIA' { 'CUDA' } 'AMD' { 'HIP/ROCm or Vulkan' } 'Intel' { 'SYCL or Vulkan' } default { 'Manual check required' } }
        $out += [pscustomobject]@{ Name=$name; Vendor=$vendor; Type=$kind; SuggestedBackend=$backend; PNPDeviceID=$pnp; IsVirtual=$isVirtual }
    }
} catch {}
$out
'@
        $script:GpuScanRunner = [powershell]::Create()
        [void]$script:GpuScanRunner.AddScript($code)
        $script:GpuScanJob = $script:GpuScanRunner.BeginInvoke()
    } catch {
        $script:GpuScanJob = $null
        $script:GpuScanRunner = $null
    }
}
function Get-MossGpuScanResult {
    # $null = the scan is still running. An array = the adapters (empty when
    # the scan failed - the caller then falls back to the slow path).
    if (-not $script:GpuScanStarted) { return $null }
    if ($script:GpuScanConsumed) { return $script:GpuScanItems }
    if ($null -eq $script:GpuScanJob) { $script:GpuScanConsumed = $true; $script:GpuScanItems = @(); return $script:GpuScanItems }
    try {
        if (-not $script:GpuScanJob.IsCompleted) { return $null }
        $items = @($script:GpuScanRunner.EndInvoke($script:GpuScanJob))
        try { $script:GpuScanRunner.Dispose() } catch {}
        $script:GpuScanRunner = $null
        $script:GpuScanJob = $null
        $script:GpuScanConsumed = $true
        $script:GpuScanItems = @($items)
        return $script:GpuScanItems
    } catch {
        $script:GpuScanConsumed = $true
        $script:GpuScanItems = @()
        return $script:GpuScanItems
    }
}

function Set-MossInventory($items) { $script:Inventory = @($items) }
function Set-MossGpuScanDone { $script:GpuScanDone = $true }
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
$script:Inventory = @()
$script:RecommendedBackend = ''

# ---- HARDWARE SETUP DIALOG (built on demand) ---------------------------------
# v0.2.3: the setup form (and the GPU scan it needs) used to be built on EVERY
# launch, even though it is only shown on the first run or when Hardware / Setup
# is opened. Building it cost ~240 ms + a 155 ms adapter scan of startup time.
# It is now a function that is called only when the dialog is really needed.
function Show-MossSetupDialog {
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
$form.Controls.Add($backend); Set-MossComboTheme $backend

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
$form.Controls.Add($gpu); Set-MossComboTheme $gpu

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
    # Relative stored paths are anchored to the MOSS folder, not to wherever
    # the process happens to be running from.
    $suggestedPath = [Environment]::ExpandEnvironmentVariables(([string]$engine.Text).Trim().Trim('"'))
    if ($suggestedPath -and -not [System.IO.Path]::IsPathRooted($suggestedPath)) { $suggestedPath = Get-AbsoluteAppPath $suggestedPath }
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
    # Relative engine paths must be anchored to the MOSS folder, NOT to the
    # process working directory: MOSS can be started with any working
    # directory (launcher chain, terminal, shortcut) - the generation paths
    # are already anchored this way, and this check used to fail with
    # 'engine executable was not found' purely because of WHERE MOSS was
    # started from (live-reproduced).
    $enginePath = Get-AbsoluteAppPath ($engine.Text.Trim())
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
    # Anchor relative paths to the MOSS folder before checking/storage (same
    # reason as the backend check above - the working directory must not
    # matter), and store the engine path relative when it lives inside the
    # MOSS folder so the install stays movable.
    $engineAbs = Get-AbsoluteAppPath ($engine.Text.Trim())
    $script:Settings.EnginePath=Get-RelativeAppPath $engineAbs
    $script:Settings.HardwareSetupComplete=$true
    Save-Settings
    $savedBackend = [string]$script:Settings.Backend
    $gpuSavedText = if([int]$script:Settings.PreferredGpuIndex -ge 0){ "  |  GPU: $($script:Settings.PreferredGpuName)" } else { '  |  GPU: automatic' }
    $backendDisplay = "Backend: $savedBackend$gpuSavedText"
    $msg="Settings saved to:`r`n$script:ConfigFile`r`n`r`n$backendDisplay`r`nEngine: $($script:Settings.EnginePath)"
    if (-not (Test-Path -LiteralPath $engineAbs -PathType Leaf)) { $msg += "`r`n`r`nWARNING: Engine executable not found at this path ($engineAbs). You can browse to it later." }
    [System.Windows.Forms.MessageBox]::Show($msg,'MOSS setup saved',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $form.Close()
})

$form.Add_Shown({ if (-not $script:Settings.HardwareSetupComplete) { [System.Windows.Forms.MessageBox]::Show('Welcome to MOSS Image Studio. Review the detected adapters and choose the backend that matches your engine build.','First-run setup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null } })
[void]$form.ShowDialog()
}

# ---------------- IMAGE GENERATOR ----------------
function Test-MossPromptSafe([string]$Prompt) {
    # Safe mode content check: returns $true when the prompt may run.
    # Two separate layers:
    #  1) ALWAYS on, regardless of the Safe mode toggle - narrowed to the
    #     genuinely dangerous combinations so harmless prompts never hit it:
    #       - a CHILD-age word (child, kid, preteen, schoolgirl...) with ANY
    #         sexual term
    #       - a TEEN/age-ambiguous word (teen, girl, boy, student...) with an
    #         EXPLICIT sexual term (nude, naked, sex, porn...)
    #       - the known minor-sexualization tags (loli, shota, jailbait...)
    #         standalone
    #     Soft pairings ('seductive girl', 'sexy teen') are allowed with the
    #     toggle off - Safe mode OFF means full control over everything
    #     except this floor.
    #  2) Safe mode ON (opt-out): sexual content, graphic violence/gore and
    #     self-harm/suicide terms.
    # Deliberately NOT listed: battle/war/sword/knight/fighting, 'dead'
    # alone (dead tree, dead sea), plain 'murder'/'killer' (murder-mystery
    # art), 'hanging' alone (hanging laundry) - common art staples; the
    # gate targets the GRAPHIC wording. Word-boundary matching so
    # 'assassin'/'Essex'/'cocktail'/'analysis' do not trigger. Creative
    # wording can still slip past - a keyword filter is a gate, not a
    # trained classifier.
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $true }
    $sexualTerms = @('nsfw','nude','nudes','nudity','naked','porn','pornographic','xxx','erotic','sex','sexual','sexually','sexy','fuck','fucking','cum','cumming','penis','vagina','pussy','cock','tits','titties','boobs','breasts','nipples','areola','topless','bottomless','undressed','undressing','anal','blowjob','handjob','gangbang','bdsm','bondage','fetish','hentai','masturbat','orgasm','horny','aroused','explicit','lewd','suggestive','lingerie','seductive','striptease','stripping','g-string','buttocks','thong')
    $sexualPattern = '(?i)\b(' + (($sexualTerms | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
    $explicitPattern = '(?i)\b(nudes?|nudity|naked|sex(?:ual|ually)?|porn(?:ographic)?|xxx|explicit|erotic|hentai|lewd|topless|bottomless|undressed|undressing)\b'
    $strictMinorPattern = '(?i)\b(child|children|kid|kids|preteen|tween|schoolgirl|schoolboy|underage|loli|lolicon|shota|shotacon)\b'
    # girl/boy/student are age-AMBIGUOUS (in image prompts they overwhelmingly
    # mean adults) and are deliberately NOT in the minor lists - with the
    # toggle off, 'naked girl' runs like 'naked woman'. The floor covers the
    # unambiguous minor terms only.
    $teenPattern = '(?i)\b(teen|teens|teenage|teenager)\b'
    # Layer 1 - never allowed, toggle or not:
    if ($Prompt -match $strictMinorPattern -and $Prompt -match $sexualPattern) { return $false }
    if ($Prompt -match $teenPattern -and $Prompt -match $explicitPattern) { return $false }
    # Known minor-sexualization tags are blocked on their own, with no
    # second term needed:
    if ($Prompt -match '(?i)\b(loli|lolicon|shota|shotacon|jailbait)\b') { return $false }
    # Layer 2 - Safe mode:
    if (-not [bool]$script:Settings.SafeMode) { return $true }
    $terms = $sexualTerms + @(
        # --- graphic violence / gore ---
        'gore','gory','mutilated','mutilation','mutilate','dismembered','dismembering','dismemberment','decapitated','decapitation','beheaded','beheading','disemboweled','disembowelment','corpse','corpses','cadaver','massacre','massacring','torture','torturing','tortured','cannibal','cannibalism','snuff','mangled','impaled','impalement','necrophilia','autopsy','murdered','murdering','killings','bloodbath','butchering','butchered','maimed','eviscerated','strangled','strangling','strangulation',
        # --- self-harm / suicide ---
        'suicide','suicidal','self-harm','self harm','selfharm','noose','slit wrist','slit wrists','cutting wrists','dead girl','dead girls','dead boy','dead boys','dead child','dead children','dead kid','dead kids'
    )
    $pattern = '(?i)\b(' + (($terms | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
    return -not ($Prompt -match $pattern)
}

# ---------------- PERFORMANCE BENCHMARK STORE ----------------
# Every completed batch records its actual render speed into
# config\benchmarks.json. The Benchmarks dialog shows real averages per
# resolution/steps/speed-mode, estimates untested combinations by scaling on
# (render megapixels x engine steps), and feeds the live ETA so it is correct
# from the first second instead of 'ETA calculating'.
function Get-MossBenchmarkFile { Join-Path $script:AppRoot 'config\benchmarks.json' }

function Load-MossBenchmarks {
    $list = New-Object System.Collections.ArrayList
    try {
        $f = Get-MossBenchmarkFile
        if (Test-Path -LiteralPath $f) {
            $data = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            foreach ($e in @($data)) { [void]$list.Add($e) }
        }
    } catch {}
    # The comma matters: an EMPTY ArrayList returned normally collapses to
    # $null (classic PowerShell pipeline gotcha), and Add-MossBenchmarkEntry
    # then crashes calling .Add on null. The unary comma keeps the list
    # object intact even when empty.
    return ,$list
}

function Save-MossBenchmarks($List) {
    try {
        $dir = Join-Path $script:AppRoot 'config'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # An empty list piped through ConvertTo-Json produces NO output (the
        # pipeline just does not run downstream) and the file would silently
        # keep its old content - 'Clear recorded data' would never clear.
        $json = if (@($List).Count -eq 0) { '[]' } else { (@($List) | ConvertTo-Json -Depth 5) }
        Set-Content -LiteralPath (Get-MossBenchmarkFile) -Value $json -Encoding UTF8
    } catch {}
}

# --- GPU power meter (v0.1.87) -----------------------------------------
# During a render the app samples the GPU's power draw and integrates it
# over time (Wh). MEASURED values come from nvidia-smi (NVIDIA driver
# tool - used when present, never required). Without it the draw is
# ESTIMATED from the GPU's rated board power (Get-MossGpuTdp, vendor
# neutral) with a documented 0.75 utilization factor; unknown GPUs fall
# back to a 250 W typical. Cumulative energy is kept per day and all
# time in config\energy.json, the session total in memory.
function New-MossEnergyBucket {
    return [pscustomobject]@{ Seconds = 0.0; Wh = 0.0; MeasuredWh = 0.0; Runs = 0; Images = 0 }
}
function Add-MossEnergyToBucket($Bucket, [double]$Joules, [double]$MeasuredJoules, [double]$Seconds, [int]$Images) {
    if ($null -eq $Bucket) { return }
    $Bucket.Seconds = [Math]::Round([double]$Bucket.Seconds + $Seconds, 1)
    $Bucket.Wh = [Math]::Round([double]$Bucket.Wh + ($Joules / 3600.0), 4)
    $Bucket.MeasuredWh = [Math]::Round([double]$Bucket.MeasuredWh + ($MeasuredJoules / 3600.0), 4)
    $Bucket.Runs = [int]$Bucket.Runs + 1
    $Bucket.Images = [int]$Bucket.Images + [Math]::Max(0, $Images)
}
function Get-MossEnergyFile { return (Join-Path $script:AppRoot 'config\energy.json') }
function Load-MossEnergy {
    $ledger = [pscustomobject]@{ Days = New-Object System.Collections.ArrayList; AllTime = (New-MossEnergyBucket) }
    try {
        $f = Get-MossEnergyFile
        if (Test-Path -LiteralPath $f) {
            $data = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($data) {
                if ($data.Days) { foreach ($d in @($data.Days)) { [void]$ledger.Days.Add($d) } }
                if ($data.AllTime) { $ledger.AllTime = $data.AllTime }
            }
        }
    } catch {}
    return ,$ledger
}
function Save-MossEnergy($Ledger) {
    try {
        $dir = Join-Path $script:AppRoot 'config'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Keep roughly two years of day buckets, prune the oldest.
        while (@($Ledger.Days).Count -gt 730) { $Ledger.Days.RemoveAt(0) }
        $Ledger | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-MossEnergyFile) -Encoding UTF8
    } catch {}
}
function Add-MossEnergyUsage([double]$Joules, [double]$MeasuredJoules, [double]$Seconds, [int]$Images, [string]$Date = $null) {
    # Records one finished engine run's energy into the day + all-time
    # buckets (config\energy.json) and the in-memory session total.
    # $Date override exists for tests; default is today.
    if ($Seconds -le 0 -and $Joules -le 0) { return }
    if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
    $ledger = Load-MossEnergy
    # NOTE: '@(... | Select-Object -First 1)' returns a 1-element ARRAY in
    # this PS 5.1 - the bucket helper would then fail every property set.
    # Pipe directly: the assignment yields the scalar object (or nothing).
    $day = $ledger.Days | Where-Object { [string]$_.Date -eq $Date } | Select-Object -First 1
    if (-not $day) { $day = [pscustomobject]@{ Date = $Date; Seconds = 0.0; Wh = 0.0; MeasuredWh = 0.0; Runs = 0; Images = 0 }; [void]$ledger.Days.Add($day) }
    Add-MossEnergyToBucket $day $Joules $MeasuredJoules $Seconds $Images
    Add-MossEnergyToBucket $ledger.AllTime $Joules $MeasuredJoules $Seconds $Images
    Save-MossEnergy $ledger
    if ($null -ne $script:SessionEnergy) {
        Add-MossEnergyToBucket $script:SessionEnergy $Joules $MeasuredJoules $Seconds $Images
    }
}
function Get-MossEnergySummary {
    # Returns today's bucket, the all-time bucket, today's date and the
    # date energy tracking STARTED (the oldest day bucket - day buckets
    # are appended chronologically and pruned oldest-first, so Days[0]
    # is the beginning of the recorded history). $null when no day is
    # recorded yet.
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $ledger = Load-MossEnergy
    $day = $ledger.Days | Where-Object { [string]$_.Date -eq $today } | Select-Object -First 1
    if (-not $day) { $day = New-MossEnergyBucket; $day | Add-Member -NotePropertyName Date -NotePropertyValue $today }
    $started = $null
    $dayList = @($ledger.Days)
    if ($dayList.Count -gt 0) {
        # The oldest recorded day is the tracking start. Day buckets are
        # normally appended chronologically (and pruned oldest-first), but
        # Take the MINIMUM date so an out-of-order entry cannot lie.
        # NOTE: '@(... | Select-Object -First 1)' yields a 1-element ARRAY
        # in PS 5.1 - '-f' would render it as 'System.Object[]'. Pipe
        # directly: the assignment is the scalar object.
        $started = $dayList | ForEach-Object { [string]$_.Date } | Sort-Object | Select-Object -First 1
    }
    return [pscustomobject]@{ Date = $today; Day = $day; AllTime = $ledger.AllTime; Started = $started }
}
function Get-MossNvidiaSmiPath {
    # Vendor-neutral: returns the nvidia-smi.exe path when the NVIDIA
    # driver tool is present, otherwise $null (the TDP estimate is used).
    $candidates = @(
        (Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue).Source,
        (Join-Path $env:WINDIR 'System32\nvidia-smi.exe'),
        (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
    return $null
}
function Parse-MossPowerCsvLine([string]$Line) {
    # nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits prints
    # one line per GPU, e.g. '231.45' or ' N/A' (idle/no permission).
    if (-not $Line) { return $null }
    $t = ([string]$Line).Split(',')[0].Trim()
    $v = 0.0
    if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -ge 0 -and $v -lt 2000) { return $v }
    return $null
}
function Get-MossPowerEstimateWatts([double]$Tdp) {
    # Draw estimate without a measurement tool: 75% of the rated board
    # power while sampling (rendering is GPU-heavy but not 100% TDP the
    # whole time), 250 W typical when the model is not in the table.
    if ($Tdp -gt 0) { return [Math]::Round($Tdp * 0.75, 1) }
    return 250.0
}

function Get-MossRenderMP([int]$W,[int]$H,[string]$SpeedMode) {
    # The size the ENGINE actually renders for the given speed mode.
    $scale = switch ([string]$SpeedMode) {
        '2x' { 0.7 }
        '4x' { 0.5 }
        '8x' { 0.35 }
        'Fast' { [Math]::Min(0.35, 128.0 / [Math]::Min($W, $H)) }
        default { 0 }
    }
    if ($scale -gt 0 -and $scale -lt 1) {
        $rw = [int][Math]::Max(128, [Math]::Floor($W * $scale))
        $rh = [int][Math]::Max(128, [Math]::Floor($H * $scale))
        if ($rw -lt $W -and $rh -lt $H) { return (([double]$rw * [double]$rh) / 1000000.0) }
    }
    return (([double]$W * [double]$H) / 1000000.0)
}

function Add-MossBenchmarkEntry {
    param($Job, [double]$SecondsPerImage, [int]$Images)
    if ($SecondsPerImage -le 0.05 -or $Images -le 0) { return }
    $list = Load-MossBenchmarks
    $gpuName = ''
    try { $g0 = @($script:Inventory | Where-Object { -not $_.IsVirtual } | Select-Object -First 1); if ($g0) { $gpuName = [string]$g0.Name } } catch {}
    $rw = [int]$Job.Width; $rh = [int]$Job.Height
    # Detail-regeneration (highres) runs: the job's own W/H is IGNORED by the
    # args builder - the base pass renders at the SOURCE size and the highres
    # second pass enlarges it. Record the source size so the entry matches
    # what the engine actually rendered, plus the scale itself: a hires run
    # costs far more than a plain run at the same size/steps (measured 853 s
    # vs about 177 s at 1360 x 768 / 165 steps), so estimates must be able to
    # tell them apart (0 = plain run).
    $hiresScale = 0.0
    if ($Job.PSObject.Properties['HiresScale']) { $hiresScale = [double]$Job.HiresScale }
    if ($hiresScale -ge 1.5 -and $Job.PSObject.Properties['SrcW'] -and [int]$Job.SrcW -ge 64 -and $Job.PSObject.Properties['SrcH'] -and [int]$Job.SrcH -ge 64) {
        $rw = [int]$Job.SrcW; $rh = [int]$Job.SrcH
    }
    $scale = switch ([string]$Job.SpeedMode) { '2x' { 0.7 } '4x' { 0.5 } '8x' { 0.35 } 'Fast' { [Math]::Min(0.35, 128.0 / [Math]::Min($Job.Width, $Job.Height)) } default { 0 } }
    if ($scale -gt 0 -and $scale -lt 1) {
        $rw2 = [int][Math]::Max(128, [Math]::Floor($Job.Width * $scale))
        $rh2 = [int][Math]::Max(128, [Math]::Floor($Job.Height * $scale))
        if ($rw2 -lt $rw -and $rh2 -lt $rh) { $rw = $rw2; $rh = $rh2 }
    }
    $entry = [ordered]@{
        Date = (Get-Date).ToString('o'); Backend = [string]$Job.Backend; Gpu = $gpuName
        W = [int]$rw; H = [int]$rh; RenderW = [int]$rw; RenderH = [int]$rh
        SpeedMode = [string]$Job.SpeedMode; Steps = [int]$Job.Steps
        Sampler = [string]$Job.SamplingMethod; Scheduler = [string]$Job.Scheduler
        Img2Img = [bool]($null -ne $Job.InitImage)
        HiresScale = [double]$hiresScale
        SecondsPerImage = [Math]::Round([double]$SecondsPerImage, 2); Images = [int]$Images
    }
    [void]$list.Add($entry)
    while ($list.Count -gt 400) { $list.RemoveAt(0) }
    Save-MossBenchmarks $list
}

function Get-MossBenchmarkEstimate {
    # Seconds-per-image extrapolated from the benchmark store. For a detail-
    # regeneration (highres) job pass -HiresScale plus the SOURCE size: the
    # estimate is then base img2img pass at the source size + engine highres
    # second pass at HiresScale x, both from plain (non-hires) measurements.
    param([int]$W, [int]$H, [string]$SpeedMode, [int]$Steps, [bool]$IsImg2Img, [double]$HiresScale = 0.0, [int]$SrcW = 0, [int]$SrcH = 0)
    try {
        $list = Load-MossBenchmarks
        # Detail-regeneration runs are recorded with HiresScale >= 1.5: their
        # measured time includes the enlarged second pass, so they must never
        # be matched for a PLAIN estimate (the 853 s hires verify run would
        # otherwise make every plain 1360 x 768 estimate ~5x too slow), and
        # plain entries would grossly underestimate a hires run. Old entries
        # have no HiresScale property: they count as plain.
        $plain = @($list | Where-Object { -not ($_.PSObject.Properties['HiresScale'] -and [double]$_.HiresScale -ge 1.5) })
        # Best matching recorded run for a target render size (MP x steps
        # score, same rule as the live ETA), scaled to the target.
        $bestMatch = {
            param($targetMP, $isI2I)
            $best = $null; $bestScore = [double]::MaxValue
            foreach ($e in $plain) {
                if ([bool]$e.Img2Img -ne $isI2I) { continue }
                $recMP = (([double]$e.RenderW * [double]$e.RenderH) / 1000000.0)
                if ($recMP -le 0) { continue }
                $recSteps = [Math]::Max(1, [int]$e.Steps)
                $score = [Math]::Abs([Math]::Log((($targetMP * [Math]::Max(1, $Steps)) + 1.0) / (($recMP * $recSteps) + 1.0)))
                if ($score -lt $bestScore) { $bestScore = $score; $best = $e }
            }
            if (-not $best) { return $null }
            $recMP = (([double]$best.RenderW * [double]$best.RenderH) / 1000000.0)
            return @{ Sec = [double]$best.SecondsPerImage * ($targetMP / $recMP) * ([double]$Steps / [Math]::Max(1, [int]$best.Steps)); E = $best }
        }
        if ($HiresScale -ge 1.5 -and $SrcW -ge 64 -and $SrcH -ge 64) {
            # Detail-regeneration run = base img2img pass at the SOURCE size
            # (composition, all engine steps) + the engine highres second pass
            # at HiresScale x with the full step count. Both parts are
            # estimated from plain measurements - the recorded hires runs
            # themselves are excluded above (they would double-count).
            $mBase = & $bestMatch (([double]$SrcW * [double]$SrcH) / 1000000.0) $true
            if (-not $mBase) { return $null }
            $est = [double]$mBase.Sec
            $hiW = [int][Math]::Round($SrcW * $HiresScale); $hiH = [int][Math]::Round($SrcH * $HiresScale)
            $based = ('base pass from {0} x {1} img2img @ {2} steps' -f $mBase.E.W, $mBase.E.H, $mBase.E.Steps)
            $mSecond = & $bestMatch (([double]$hiW * [double]$hiH) / 1000000.0) $false
            if ($mSecond) {
                $est += [double]$mSecond.Sec
                $based += (' + highres pass from {0} x {1} fresh @ {2} steps' -f $mSecond.E.W, $mSecond.E.H, $mSecond.E.Steps)
            } else {
                $based += ' + highres pass (no fresh measurements yet - not included, the real time will be higher)'
            }
            return @{ Sec = [Math]::Max(1.0, [Math]::Round($est, 1)); BaseSec = [Math]::Max(1.0, [Math]::Round([double]$mBase.Sec, 1)); SecondSec = $(if ($mSecond) { [Math]::Max(1.0, [Math]::Round([double]$mSecond.Sec, 1)) } else { 0.0 }); Based = $based }
        }
        $targetMP = Get-MossRenderMP $W $H $SpeedMode
        $m = & $bestMatch $targetMP $IsImg2Img
        if (-not $m) { return $null }
        return @{ Sec = [Math]::Max(1.0, [Math]::Round([double]$m.Sec, 1)); Based = ('{0} x {1} {2} @ {3} steps' -f $m.E.W, $m.E.H, $m.E.SpeedMode, $m.E.Steps) }
    } catch { return $null }
}

function Get-MossGpuTdp([string]$GpuName) {
    # Rated board power (watts) for common GPUs, used ONLY for the energy
    # estimate in the Benchmarks dialog. Vendor-neutral: NVIDIA, AMD and
    # Intel entries; returns $null when the GPU is not in the table so the
    # app never invents a number. First match wins, so specific variants
    # (e.g. '3080 ti') must be listed before their base model ('3080').
    if (-not $GpuName) { return $null }
    # Strip '(R)'/'(TM)' decorations (Intel names like 'Intel(R) Arc(TM) A770')
    $n = (([string]$GpuName) -replace '\((r|tm)\)', '').ToLowerInvariant()
    $table = @(
        @('rtx 5090', 575), @('rtx 5080', 360), @('rtx 5070 ti', 300), @('rtx 5070', 250),
        @('rtx 4090', 450), @('rtx 4080', 320), @('rtx 4070 ti', 285), @('rtx 4070', 200),
        @('rtx 3090 ti', 450), @('rtx 3080 ti', 350), @('rtx 3090', 350), @('rtx 3080', 320),
        @('rtx 3070 ti', 290), @('rtx 3060 ti', 200), @('rtx 3070', 220), @('rtx 3060', 170), @('rtx 3050', 130),
        @('rtx 2080 ti', 250), @('rtx 2080', 215), @('rtx 2070', 175), @('rtx 2060', 160),
        @('gtx 1080 ti', 250), @('gtx 1080', 180), @('gtx 1070', 150), @('gtx 1660', 120),
        @('rx 7900 xtx', 355), @('rx 7900 xt', 315), @('rx 7800 xt', 263), @('rx 7700 xt', 245),
        @('rx 6950 xt', 335), @('rx 6900 xt', 300), @('rx 6800 xt', 300), @('rx 6800', 250),
        @('rx 6700 xt', 230), @('rx 6600 xt', 182), @('rx 6600', 132),
        @('arc a770', 225), @('arc a750', 225), @('arc a580', 175), @('arc a380', 75)
    )
    foreach ($e in $table) { if ($n.Contains($e[0])) { return [int]$e[1] } }
    return $null
}

function Get-MossUpscalerModels {
    # ALL upscaler models the user placed in models\upscalers (.pth). The
    # USER chooses which one to use - MOSS never overrides that choice (a
    # different model, e.g. an anime or black-and-white specialist, is just
    # as valid). Returns an EMPTY list when none exist (the fast option is
    # then unavailable; MOSS falls back to detail regeneration). The unary
    # comma keeps the list object intact even when empty (pipeline gotcha).
    $dir = Join-Path $script:AppRoot 'models\upscalers'
    $list = New-Object System.Collections.ArrayList
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.pth' -File -ErrorAction SilentlyContinue | Sort-Object Name)) { [void]$list.Add([string]$f.FullName) }
    } catch {}
    return ,$list
}

function Get-MossDefaultUpscaleModel {
    # Preferred DEFAULT selection only: the RealESRGAN x4 model - verified to
    # load in the bundled engine (the x2 'x2plus' variant uses a feature-32
    # architecture the engine's ESRGAN loader rejects). The pipeline renders
    # at HALF the image's size and the x4 model sharpens it to 2x. The user
    # can pick any other model in the dialogs; $null when none exist.
    $models = Get-MossUpscalerModels
    if ($models.Count -eq 0) { return $null }
    $hit = @($models | Where-Object { (Split-Path -Leaf $_) -ieq 'RealESRGAN_x4plus.pth' } | Select-Object -First 1)
    if ($hit) { return [string]$hit[0] }
    return [string]$models[0]
}

function Get-MossSidecarPath([string]$ImagePath) {
    # Where a NEW per-image sidecar is written: '<image folder>\metadata\
    # <name>.json'. The output folder therefore only shows the pictures;
    # the JSON sidecars (seed/prompt/settings that power Improve, re-render
    # from seed and the Info dialog) live in their own subfolder. Returns
    # the path WITHOUT checking that it exists.
    $dir = [System.IO.Path]::GetDirectoryName([string]$ImagePath)
    if ([string]::IsNullOrEmpty($dir)) { return [System.IO.Path]::ChangeExtension([string]$ImagePath, '.json') }
    return (Join-Path (Join-Path $dir 'metadata') ([System.IO.Path]::GetFileNameWithoutExtension([string]$ImagePath) + '.json'))
}

function Get-MossSidecarReadPath([string]$ImagePath) {
    # Where to READ a sidecar: the metadata subfolder when present, otherwise
    # the legacy location next to the image (images made by older versions).
    $p = Get-MossSidecarPath $ImagePath
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    return [System.IO.Path]::ChangeExtension([string]$ImagePath, '.json')
}

function Get-MossOrphanSidecars([string]$ImagePath) {
    # Sidecar files whose picture no longer exists: they appear when a
    # picture is RENAMED or MOVED outside MOSS (the sidecar is named after
    # the picture), or when a picture was deleted by hand. Only MOSS's own
    # sidecars are considered; the sidecar matching THIS image is skipped.
    $result = New-Object System.Collections.ArrayList
    $dir = [System.IO.Path]::GetDirectoryName([string]$ImagePath)
    if ([string]::IsNullOrEmpty($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $result.ToArray() }
    $imgName = [System.IO.Path]::GetFileNameWithoutExtension([string]$ImagePath)
    $seen = @{}
    foreach ($loc in @((Join-Path $dir 'metadata'), $dir)) {
        if (-not (Test-Path -LiteralPath $loc -PathType Container)) { continue }
        foreach ($js in @(Get-ChildItem -LiteralPath $loc -Filter 'MOSS_*.json' -File -ErrorAction SilentlyContinue)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($js.Name)
            if ($base -eq $imgName -or $seen.ContainsKey($js.Name)) { continue }
            $seen[$js.Name] = $true
            $imgCandidate = Join-Path $dir ($base + '.png')
            if (-not (Test-Path -LiteralPath $imgCandidate -PathType Leaf)) { [void]$result.Add($js.FullName) }
        }
    }
    # Return the ELEMENTS (not a wrapped collection): an empty list then
    # collapses to no output, so @(Get-MossOrphanSidecars ...) in the caller
    # yields Count 0 for 'no orphans' - with 'return ,$result' the empty
    # ArrayList arrived as ONE item and made Count always >= 1, which fired
    # the adoption offer on every improve even for images WITH a sidecar.
    return $result.ToArray()
}

function Approve-MossSidecarAdoption([string]$ImagePath) {
    # Called when a picture has NO sidecar at all: if exactly ONE orphaned
    # sidecar exists (its picture was renamed/moved/deleted outside MOSS),
    # offer to attach it to this picture - with seed and prompt shown so
    # the user can judge whether it belongs. Returns $true when adopted.
    # GUARD: only when THIS picture really has no sidecar - the offer must
    # never claim 'no sidecar' for an image that has one.
    if (Test-Path -LiteralPath (Get-MossSidecarReadPath $ImagePath) -PathType Leaf) { return $false }
    $orphans = @(Get-MossOrphanSidecars $ImagePath)
    if ($orphans.Count -ne 1) { return $false }
    $op = [string]$orphans[0]
    $info = ''
    try {
        $sc = Get-Content -LiteralPath $op -Raw | ConvertFrom-Json
        $pr = ''
        if ($sc.PromptProtected) {
            if (-not $script:HistoryLocked -and $script:HistoryPassphrase) {
                try { $pr = [string](Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase) } catch { $pr = '' }
            }
            if (-not $pr) { $pr = '(encrypted - enter the history code to read it)' }
        } elseif ($sc.Prompt) { $pr = [string]$sc.Prompt }
        if ($pr.Length -gt 140) { $pr = $pr.Substring(0, 140) + '...' }
        $info = ('Stored: seed {0}, {1} x {2}, {3} steps{4}Prompt: {5}' -f $(if ($sc.Seed) { [string]$sc.Seed } else { '?' }), $(if ($sc.Width) { [string]$sc.Width } else { '?' }), $(if ($sc.Height) { [string]$sc.Height } else { '?' }), $(if ($sc.Steps) { [string]$sc.Steps } else { '?' }), [Environment]::NewLine, $(if ($pr) { $pr } else { '(no prompt stored)' }))
    } catch { $info = 'Could not read its contents.' }
    $a = [System.Windows.Forms.MessageBox]::Show(("This image has no stored settings (no sidecar).`r`n`r`nThere is exactly one ORPHANED settings file: {0}`r`n{1}`r`n`r`nIts picture no longer exists - usually because the picture was RENAMED or MOVED outside MOSS. Attach these settings to this image? (If they belong to a different picture, choose No.)" -f ([System.IO.Path]::GetFileName($op)), $info), 'Orphaned settings found', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    $target = Get-MossSidecarPath $ImagePath
    $tdir = [System.IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $tdir -PathType Container)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
    try { Move-Item -LiteralPath $op -Destination $target -Force; return $true } catch { return $false }
}

function Test-MossPngValid([string]$ImagePath) {
    # True only when the file exists AND is a complete, decodable PNG.
    # Guards against truncated writes (disk full, power loss, antivirus
    # interference): the engine 'creates' the file, but a half-written PNG
    # is not a picture - it must never enter the generated-files list.
    try {
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
        if ($bytes.Length -lt 33) { return $false }
        if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { return $false }
        $t = $bytes.Length
        # PNG ends with the IEND chunk: 4 zero length bytes + 'IEND' + 4-byte CRC.
        if (-not ($bytes[$t-8] -eq 0x49 -and $bytes[$t-7] -eq 0x45 -and $bytes[$t-6] -eq 0x4E -and $bytes[$t-5] -eq 0x44)) { return $false }
        $ms = New-Object System.IO.MemoryStream (,$bytes)
        try {
            $img = [System.Drawing.Image]::FromStream($ms)
            try { return ($img.Width -gt 0 -and $img.Height -gt 0) } finally { $img.Dispose() }
        } finally { $ms.Dispose() }
    } catch { return $false }
}

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
    # Anchor relative paths to the app root FIRST: [IO.Path]::GetFullPath on a
    # bare relative path resolves against the PROCESS working directory (which
    # is NOT necessarily the app folder - a launcher or terminal can start
    # MOSS from anywhere), so 'outputs' once became '<cwd>\outputs' and got
    # saved as a wrong absolute path (v0.1.46 bug, live-reproduced). Values
    # that are already absolute pass through Get-AbsoluteAppPath unchanged.
    try {
        $root = [System.IO.Path]::GetFullPath($script:AppRoot).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath((Get-AbsoluteAppPath $value))
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
        @{ Name='tokenizer_qwen3.5.json'; Setting='TokenizerPath'; Repo='OpenMOSS-Team/MOSS-Image-Base'; RepoPath='tokenizer/tokenizer.json' },
        # The fast-sharpen upscaler: part of the standard install (the fast
        # improve mode depends on it). Lives in models\upscalers; without it
        # MOSS still generates and falls back to detail regeneration.
        @{ Name='RealESRGAN_x4plus.pth'; Setting=''; Repo='nateraw/real-esrgan'; RepoPath='RealESRGAN_x4plus.pth' }
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
            # Upscaler models live in their own subfolder.
            if(-not $localPath){ $p=Join-Path (Join-Path $modelsDir 'upscalers') $m.Name; if(Test-Path -LiteralPath $p -PathType Leaf){ $localPath=$p } }
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
function Get-MossProbeSpeed([int64]$TotalBytes, [double]$ElapsedSec, [int64]$RampBytes, [double]$RampSec) {
    # Speed for the download probe, in MB/s (0 when not measurable).
    # The first RampBytes (TCP slow start / TLS handshake ramp-up) are
    # EXCLUDED from the timing: they measure connection setup, not the
    # steady-state speed a multi-GB model download would run at.
    if ($TotalBytes -lt 1MB) { return 0 }
    $dataBytes = $TotalBytes - $RampBytes
    $dataSec = $ElapsedSec - $RampSec
    if ($dataBytes -ge 1MB -and $dataSec -gt 0.05) { return ($dataBytes / 1MB) / $dataSec }
    # Too little data past the ramp: fall back to the full average rather
    # than answering 0 (a rough number beats none).
    if ($ElapsedSec -gt 0.05) { return ($TotalBytes / 1MB) / $ElapsedSec }
    return 0
}

function Measure-MossDownloadSpeed([string]$url) {
    # Downloads up to 2 MB of the file with a HARD 5-second wall budget and
    # returns the steady-state speed in MB/s (0 when it cannot be measured)
    # - used for the download-time estimate. Timeouts are deliberately
    # short: the probe must NEVER make the user wait - 2.5 s to connect, 5 s
    # per stalled read, 5 s total read budget (previous version waited up
    # to 20+ seconds, which the user rightly found too long; the connect
    # timeout came down from 8 s to 4 s and then to 2.5 s in v0.2.3, and the
    # sample shrank from 6 MB to 2 MB - the speed math needs 1 MB past the
    # 512 KB ramp, so 2 MB is enough).
    # An unreachable server is the NORMAL case on a machine that is offline
    # or behind a blocking proxy: it must cost ~2.5 s, not 20.
    try {
        $req=[System.Net.HttpWebRequest]::Create($url)
        $req.Method='GET'; $req.AddRange(0,2097151); $req.Timeout=2500; $req.ReadWriteTimeout=5000; $req.UserAgent='MOSS-Image-Studio'
        $resp=$req.GetResponse()
        try {
            $sw=[System.Diagnostics.Stopwatch]::StartNew()
            $stream=$resp.GetResponseStream()
            $buf=New-Object byte[] (256KB)
            $total=0; $rampSec=-1.0; $rampBytes=512KB
            while($true){
                $r=$stream.Read($buf,0,$buf.Length)
                if($r -le 0){ break }
                $total+=$r
                if($rampSec -lt 0 -and $total -ge $rampBytes){ $rampSec=$sw.Elapsed.TotalSeconds }
                if($total -ge 2MB){ break }
                if($sw.Elapsed.TotalSeconds -ge 5.0){ break }
            }
            $sw.Stop()
            $elapsed=$sw.Elapsed.TotalSeconds
            if($rampSec -lt 0){ $rampSec=$elapsed; $rampData=0 } else { $rampData=$rampBytes }
            return Get-MossProbeSpeed $total $elapsed $rampData $rampSec
        } finally { $resp.Close() }
    } catch {}
    return 0
}

function Get-MossDownloadSpeedFile { return (Join-Path $script:AppRoot 'config\downloadspeed.json') }
function Save-MossRealDownloadSpeed([double]$MBps, [int64]$Bytes) {
    # Records the REAL average speed of a completed model download
    # (bytes transferred / wall time) - the most honest speed signal this
    # machine has. Speeds <= 0 are ignored. Last 3 entries kept.
    if ($MBps -le 0 -or $MBps -gt 2000) { return }
    try {
        $list = New-Object System.Collections.ArrayList
        $f = Get-MossDownloadSpeedFile
        if (Test-Path -LiteralPath $f) {
            try { $data = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; foreach ($e in @($data)) { [void]$list.Add($e) } } catch {}
        }
        [void]$list.Add([ordered]@{ Date = (Get-Date).ToString('o'); MBps = [Math]::Round([double]$MBps, 2); Bytes = [int64]$Bytes })
        while ($list.Count -gt 3) { $list.RemoveAt(0) }
        $dir = Join-Path $script:AppRoot 'config'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $list | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $f -Encoding UTF8
    } catch {}
}
function Load-MossRealDownloadSpeed {
    # The most recent REAL model-download speed (MB/s), or $null. Entries
    # are appended chronologically, so the LAST valid entry is the newest
    # (date strings tie when downloads complete within the same second -
    # comparing dates would then keep an older one).
    try {
        $f = Get-MossDownloadSpeedFile
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        $data = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $best = $null
        foreach ($e in @($data)) { if ([double]$e.MBps -gt 0) { $best = $e } }
        if ($best) { return [pscustomobject]@{ MBps = [double]$best.MBps; Date = [string]$best.Date; Bytes = [int64]$best.Bytes } }
    } catch {}
    return $null
}
function Get-MossCachedDownloadSpeed([int]$MaxAgeDays = 7) {
    # The last MEASURED download speed, taken from the CACHE ONLY - this
    # function never touches the network.
    # v0.2.3: measuring the speed means downloading 6 MB from the model
    # server. That is only worth doing when a download is really about to
    # start. Everywhere else (startup, opening a dialog) MOSS uses this
    # cached number and says 'depends on your connection' when there is none.
    try {
        $real = Load-MossRealDownloadSpeed
        if ($real) {
            try { if (((Get-Date) - [datetime]$real.Date) -le [TimeSpan]::FromDays($MaxAgeDays)) { return [double]$real.MBps } } catch {}
        }
    } catch {}
    return 0
}
function Get-MossDownloadSpeedEstimate([string]$url, [int]$MaxAgeDays = 7) {
    # The best available download speed (MB/s, 0 when unknown):
    # 1. A REAL completed model download from the last $MaxAgeDays days is
    #    used ALONE - no probe, the dialog opens instantly.
    # 2. Otherwise a fresh 5-second probe is run and BLENDED 50/50 with any
    #    older real measurement (the probe sees today's network, the real
    #    number shows what a full multi-GB transfer settles at).
    $real = Load-MossRealDownloadSpeed
    $maxAge = [TimeSpan]::FromDays($MaxAgeDays)
    if ($real) {
        try { if (((Get-Date) - [datetime]$real.Date) -le $maxAge) { return [double]$real.MBps } } catch {}
    }
    $probe = Measure-MossDownloadSpeed $url
    if ($probe -gt 0 -and $real -and [double]$real.MBps -gt 0) { return [Math]::Round((($probe + [double]$real.MBps) / 2.0), 2) }
    if ($probe -gt 0) { return $probe }
    if ($real -and [double]$real.MBps -gt 0) { return [double]$real.MBps }
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
        # v0.2.3: LOCAL FIRST. When the engine and every known model file are
        # present on disk, NOTHING can be 'not installed', so the remote size
        # lookup (4 network calls to huggingface.co, ~0.9 s) is not needed at
        # all - that was the last slow thing left in MOSS's startup.
        $knownLocal=@(
            @{ Name='moss_image_sft_int8_convrot.safetensors'; Setting='DiffusionModelPath' },
            @{ Name='flux2-vae.safetensors'; Setting='VaePath' },
            @{ Name='Qwen3.5-9B-Q4_K_M.gguf'; Setting='LlmPath' },
            @{ Name='tokenizer_qwen3.5.json'; Setting='TokenizerPath' },
            @{ Name='RealESRGAN_x4plus.pth'; Setting='' }
        )
        $allLocal=$true
        foreach($k in $knownLocal){
            $found=$false
            if($k.Setting -and $script:Settings.Contains($k.Setting)){
                $cand=Get-AbsoluteAppPath ([string]$script:Settings[$k.Setting])
                if($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)){ $found=$true }
            }
            if(-not $found){
                $mdir=Join-Path $script:AppRoot 'models'
                if(Test-Path -LiteralPath (Join-Path $mdir $k.Name) -PathType Leaf){ $found=$true }
                elseif(Test-Path -LiteralPath (Join-Path (Join-Path $mdir 'upscalers') $k.Name) -PathType Leaf){ $found=$true }
            }
            if(-not $found){ $allLocal=$false; break }
        }
        if($engineOk -and $allLocal){ return }
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
                # v0.2.3: CACHED speed only - the startup offer must not
                # download 6 MB just to print an estimate. The real probe
                # runs later, when a download is actually confirmed.
                $spd=Get-MossCachedDownloadSpeed
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
            $msg=("MOSS is not fully installed yet:`r`n`r`n"+(($lines) -join "`r`n")+"`r`n`r`nWithout the engine and model files MOSS cannot generate images; the upscaler model powers the fast-sharpen improve mode (without it MOSS falls back to the slower detail regeneration).`r`n`r`nDownload them now?"+$est+"`r`n(You can also do this later via 'Update engine...' in the header.)")
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
    # The download speed for the time estimate, from the CACHE only.
    # v0.2.3: this used to MEASURE the speed (a 6 MB download) as soon as
    # the dialog opened - even when the user only wanted to LOOK and closed
    # the dialog again. The real probe now runs only just before a download
    # is actually confirmed.
    $measuredSpeed=Get-MossCachedDownloadSpeed
    if($measuredSpeed -gt 0){ [void]$log.Add(('Measured download speed: '+[math]::Round($measuredSpeed,1)+' MB/s')) } else { [void]$log.Add('Download speed could not be measured') }

    # Dialog: release list + changelog reader + variant selection + installer.
    $g=New-Object System.Windows.Forms.Form
    $g.Text='Update engine (sd-cli core files)'
    $g.Size=New-Object System.Drawing.Size(730,768); $g.MinimumSize=New-Object System.Drawing.Size(700,748); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
    $g.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text='UPDATE ENGINE  -  sd-cli core files'; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(12,10); $g.Controls.Add($ttl)
    $sub=New-Object System.Windows.Forms.Label; $sub.Text="MOSS is the GUI - sd-cli.exe and its libraries are the engine that renders the images. This dialog updates only those engine files; the MOSS app, models, prompts, outputs and settings are never touched."; $sub.Location=New-Object System.Drawing.Point(12,40); $sub.Size=New-Object System.Drawing.Size(690,44); $sub.ForeColor=$cMuted; $g.Controls.Add($sub)
    $installedText=$(if($installedCommit){'commit '+$installedCommit}else{'version could not be read'})
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
    $variant=New-Object System.Windows.Forms.ComboBox; $variant.DropDownStyle='DropDownList'; $variant.Location=New-Object System.Drawing.Point(12,364); $variant.Size=New-Object System.Drawing.Size(280,26); $variant.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $variant.ForeColor=$cText; $g.Controls.Add($variant); Set-MossComboTheme $variant $g
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
            [System.Windows.Forms.MessageBox]::Show($g,"This release has no CUDA runtime package for one of the extra CUDA variants you selected, and a fresh CUDA engine folder cannot start without it.`r`nUncheck that extra variant (or choose Vulkan for it) and try again.",'Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
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
        # Accidental-reinstall guard: when the engine is ALREADY up to date and
        # no model update is selected, installing would just re-download the
        # same files (user: do not waste time and bandwidth by accident). Ask
        # for a deliberate confirmation instead, with the download size shown.
        if($upToDate -and $modelPlan.Count -eq 0){
            $extrasNote=''
            if(@($plan | Where-Object { -not $_.IsPrimary }).Count -gt 0){ $extrasNote=' Only the extra engine variants would be newly installed; the main engine files would be downloaded again.' }
            $dupAnswer=[System.Windows.Forms.MessageBox]::Show($g,("Everything is already up to date (engine commit "+$installedCommit+" is in release "+$relTag+")."+$extrasNote+"`r`n`r`nDownload about "+[math]::Round($totalDl/1MB)+" MB again anyway?"),'Already up to date',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if($dupAnswer -ne [System.Windows.Forms.DialogResult]::Yes){ [void]$log.Add('Reinstall cancelled at the up-to-date guard'); return }
        }
        $planText=''
        foreach($p in $plan){ $planText+=((('  '+(& $variantLabelOf $p.Key))+$(if($p.IsPrimary){''}else{' (extra)'})+'  ->  '+$p.Target)+"`r`n") }
        $modelText=if($modelPlan.Count -gt 0){ ((($modelPlan | ForEach-Object { '  '+$_.Name+'  ('+[math]::Round($_.RemoteSize/1GB,2)+' GB download, current file: '+$(if($_.LocalSize -gt 0){[math]::Round($_.LocalSize/1GB,2)+' GB'}else{'not installed'})+')' }) -join "`r`n")+"`r`n  Old model files: "+$(if($modelBackupCheck.Checked){'kept as <name>.old-<time> (renamed, instant - older backups beyond the newest 3 are deleted automatically)'}else{'overwritten WITHOUT a backup'})) } else { '  (no model updates selected)' }
        $modelText+="`r`n"
        $timeText='depends on your connection'
        if($measuredSpeed -le 0 -and $modelsTotal -gt 0){
            # v0.2.3: the user is about to download - this is the ONE moment
            # where measuring the speed (6 MB range request) is worth it.
            $probeUrl=''
            foreach($mi in $modelPlan){ if($mi.RemoteUrl){ $probeUrl=[string]$mi.RemoteUrl; break } }
            if($probeUrl){ $measuredSpeed=Get-MossDownloadSpeedEstimate $probeUrl }
        }
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
                    $dlSw=[System.Diagnostics.Stopwatch]::StartNew()
                    Invoke-WebRequest -Uri ([string]$mi.RemoteUrl) -OutFile $mTemp -UseBasicParsing -TimeoutSec 7200
                    $dlSw.Stop()
                    $got=(Get-Item -LiteralPath $mTemp).Length
                    if($mi.RemoteSize -gt 0 -and $got -ne $mi.RemoteSize){ throw ('download size mismatch (got '+[math]::Round($got/1GB,2)+' GB, expected '+[math]::Round($mi.RemoteSize/1GB,2)+' GB)') }
                    # Record the REAL download speed (v0.1.88): the most honest
                    # signal for future 'about X minutes' estimates - blended
                    # with fresh probes when the cache is stale.
                    $dlMBps=0.0
                    if($dlSw.Elapsed.TotalSeconds -gt 1 -and $got -gt 1MB){ $dlMBps=($got/1MB)/$dlSw.Elapsed.TotalSeconds; Save-MossRealDownloadSpeed $dlMBps $got }
                    [void]$log.Add(('Model download ok ('+[math]::Round($got/1GB,2)+' GB'+$(if($dlMBps -gt 0){(' at '+[math]::Round($dlMBps,1)+' MB/s')}else{''})+'))'))
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
    $script:RefineFailCount = 0
    $script:RefineStartedAt = $null

    function Get-MossShortName([string]$Text,[int]$MaxChars) {
        # Shortens long device/model names for one-line UI labels: keeps the
        # start of the string and marks the cut with an ellipsis, so a label
        # never pushes neighbouring text off-screen on small displays.
        $t = [string]$Text
        if ([string]::IsNullOrWhiteSpace($t)) { return $t }
        if ($t.Length -le $MaxChars) { return $t }
        return ($t.Substring(0, [Math]::Max(1, $MaxChars - 1)).TrimEnd() + [char]0x2026)
    }

    $f = New-Object System.Windows.Forms.Form
    # v0.2.4: the layout is suspended while the controls are built. Every
    # Controls.Add used to trigger a full layout pass of the (already
    # visible) window - one pass at the end is ~45 ms faster.
    try { $f.SuspendLayout() } catch {}
    # Compact window (v0.1.96-98): 1052 x 551 - the app-level entries
    # (output folder, model files, benchmarks, error report) moved into the
    # header Options menu, so the left panel holds only generation controls
    # and got much shorter. Update-MossLeftActionLayout is static now.
    $f.Text = "MOSS Image Studio v$($script:AppVersion) (GUI for sd-cli) | Generator"; $f.ClientSize = New-Object System.Drawing.Size(1000,500); $f.MinimumSize = New-Object System.Drawing.Size(880,539); $f.StartPosition='CenterScreen'
    # Small screens (v0.1.91): shrink to the work area on first show (the
    # layout is anchored and adapts) and lower the minimum size to what the
    # screen actually offers. The caps track the compact default height.
    # v0.2.3: the window is shown EARLY (frame + header + the two card
    # panels) and the controls are added while the user already looks at it.
    # The old code built every control first and only then showed the
    # window, so MOSS stayed invisible for ~0.8 s. The screen-fit code that
    # used to run in the Shown event now runs explicitly after the build
    # (see below) - the Shown event fires far too early for it.
    # v0.2.3: this lives in a SCRIPT variable, not on the Form: assigning an
    # unknown property to a .NET object ('$f.ScreenFit = {...}') throws in
    # PowerShell (the same trap as ComboBox.FlatAppearance).
    $script:MossScreenFit={
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $mw = [Math]::Min(880, $wa.Width - 16)
        $mh = [Math]::Min(539, $wa.Height - 16)
        $f.MinimumSize = New-Object System.Drawing.Size([Math]::Max(600,$mw), [Math]::Max(500,$mh))
        $nw = [Math]::Min($f.Width, $wa.Width - 16)
        $nh = [Math]::Min($f.Height, $wa.Height - 16)
        if ($nw -ne $f.Width -or $nh -ne $f.Height) {
            $f.Size = New-Object System.Drawing.Size($nw, $nh)
            $f.Location = New-Object System.Drawing.Point([Math]::Max(0, [int](($wa.Width - $nw) / 2)), [Math]::Max(0, [int](($wa.Height - $nh) / 2)))
        }
    }
    $f.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $f.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $f.Font=New-Object System.Drawing.Font('Segoe UI',9)
    # v0.2.3: SHOW THE WINDOW AS EARLY AS POSSIBLE. The frame is on screen
    # within a few hundred milliseconds; the header, panels and controls are
    # added to the visible window right after this, so MOSS pops up now
    # instead of after the whole UI has been built (~0.8 s).
    try { $f.Show(); $f.Activate() } catch {}
    try { $f.Refresh() } catch {}
    # v0.2.3: SHOW THE WINDOW AS EARLY AS POSSIBLE. The frame is on screen
    # within a few hundred milliseconds; the header, panels and controls are
    # added to the visible window right after this, so MOSS pops up now
    # instead of after the whole UI has been built (~0.8 s).
    # v0.2.3: Refresh() paints the window synchronously. Without it the paint
    # is queued until the message loop starts, so the user would stare at an
    # empty frame for the whole build.
    try { $f.Refresh() } catch {}
    $cPanel=[System.Drawing.Color]::FromArgb(25,32,45); $cCard=[System.Drawing.Color]::FromArgb(27,34,47); $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185); $cAccent=[System.Drawing.Color]::FromArgb(45,112,173)

    # Compact header (v0.1.96): 68 -> 50 px, title 17 pt -> 13 pt, buttons
    # 30 px -> 24 px tall. Same responsive placement logic as before.
    $head=New-Object System.Windows.Forms.Panel; $head.Dock='Top'; $head.Height=50; $head.BackColor=$cPanel; $f.Controls.Add($head)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text="MOSS  /  IMAGE STUDIO  v$($script:AppVersion)"; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(20,5); $head.Controls.Add($ttl)
    $gpuSubtitle='GPU: automatic'
    if($script:Settings.Contains('PreferredGpuIndex') -and [int]$script:Settings.PreferredGpuIndex -ge 0){
        $gpuSubtitle="GPU: $(Get-MossShortName ([string]$script:Settings.PreferredGpuName) 34)"
        if([string]::IsNullOrWhiteSpace([string]$script:Settings.PreferredGpuName)){ $gpuSubtitle="GPU: device $($script:Settings.PreferredGpuIndex)" }
    } else {
        # Automatic still SHOWS which GPU will be used (user: 'it should
        # instead show what gpu was chosen'). The engine picks the best
        # available device at start; the detected discrete adapter is what it
        # will be in practice.
        # v0.2.3: the adapter scan takes ~155 ms, so it no longer runs BEFORE
        # the window is shown. The header starts with 'GPU: detecting...' and
        # the label is filled in as soon as the window is up (see the Shown
        # handler below).
        # v0.2.4: the CACHED card name is shown instantly (no 'GPU:
        # detecting...' wait). The live scan runs on a background runspace and
        # refreshes the label when it lands.
        $cachedGpu = Get-MossCachedGpuName
        if ($cachedGpu) { $gpuSubtitle = "GPU: $(Get-MossShortName $cachedGpu 34)" } else { $gpuSubtitle = 'GPU: detecting...' }
    }
    $subt=New-Object System.Windows.Forms.Label; $subt.Text="LOCAL IMAGE GENERATION  -  $gpuSubtitle"; $subt.ForeColor=$cMuted; $subt.AutoSize=$true; $subt.Location=New-Object System.Drawing.Point(23,29); $head.Controls.Add($subt)
    # v0.2.3: the GPU name is filled in AFTER the window is visible (the scan
    # costs ~155 ms and must not delay the first paint).
    # v0.2.3: the truncation is inlined on purpose. Get-MossShortName is a
    # NESTED function of this one, and GetNewClosure captures variables but
    # NOT nested function definitions - calling it from the closure ended in
    # 'Get-MossShortName is not recognized' and the header stayed on
    # 'GPU: detecting...' forever.
    # v0.2.4: the header is filled from the BACKGROUND scan - the UI thread
    # is never blocked by the ~120 ms CIM query. If the background scan
    # failed, the slow synchronous path is used as a fallback.
    # v0.2.4: the header is filled from the BACKGROUND scan - the UI thread
    # is never blocked by the ~120 ms CIM query. If the background scan
    # failed, the slow synchronous path is used as a fallback.
    # NOTE: inside a GetNewClosure '$script:' may point at the closure's own
    # module scope, so every write to the app state goes through a top-level
    # function (Set-MossInventory / Set-MossGpuScanDone) instead.
    $script:RefreshGpuSubtitle={ $items=Get-MossGpuScanResult; if($null -eq $items){ return }; $all=@($items); if($all.Count -eq 0){ $all=@(Get-GpuInventory) }; Set-MossInventory $all; Set-MossGpuScanDone; $tryGpus=@($all | Where-Object { -not $_.IsVirtual -and $_.Vendor -ne 'Unknown' }); if($tryGpus.Count -gt 0){ $gname=[string]$tryGpus[0].Name; if($gname.Length -gt 34){ $gname=$gname.Substring(0,33).TrimEnd()+[char]0x2026 }; $subt.Text="LOCAL IMAGE GENERATION  -  GPU: $gname"; Save-MossCachedGpuName $gname } else { $subt.Text="LOCAL IMAGE GENERATION  -  GPU: not detected" } }.GetNewClosure()
    $backendText=[string]$script:Settings.Backend; if (-not $script:Settings.BackendSelectionSaved) { $backendText='Not configured' }
    $backendBadge=New-Object System.Windows.Forms.Label; $backendBadge.Text="BACKEND  $backendText"; $backendBadge.AutoSize=$true; $backendBadge.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164); $backendBadge.Location=New-Object System.Drawing.Point(535,17); $head.Controls.Add($backendBadge)
    # Header OPTIONS MENU (v0.1.97, user: 'these are really options'): the
    # three former header buttons (Hardware / Setup, Update engine, Update
    # MOSS) fold into ONE 'Options' dropdown button - the header stays
    # uncluttered and narrower windows keep room for the BACKEND badge.
    # Header OPTIONS MENU (v0.1.97/98): app-level entries live here instead
    # of cluttering the main window - Output folder..., Model files...,
    # Benchmarks..., Error report plus Hardware / Setup and the updaters.
    # Item labels show live status (folder name, model-file health) on open.
    $mossOptionsMenu=New-Object System.Windows.Forms.ContextMenuStrip
    $mossOptionsMenu.ShowItemToolTips=$true
    $miOut=$mossOptionsMenu.Items.Add('Output folder...')
    $miOut.ToolTipText='Where finished images are saved. Set once - this menu is all you need.'
    $miOut.Add_Click({
        $dlg=New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description='Select the output folder for generated images.'
        $dlg.ShowNewFolderButton=$true
        $current=Get-AbsoluteAppPath $out.Text
        if(Test-Path -LiteralPath $current -PathType Container){$dlg.SelectedPath=$current}
        elseif(-not [string]::IsNullOrWhiteSpace($current)){$currentParent=Split-Path -Parent $current;if(Test-Path -LiteralPath $currentParent -PathType Container){$dlg.SelectedPath=$currentParent}}
        if($dlg.ShowDialog($f) -eq 'OK'){$out.Text=$dlg.SelectedPath}
        $dlg.Dispose()
    })
    $miModels=$mossOptionsMenu.Items.Add('Model files...')
    $miModels.ToolTipText='Shows and changes the engine and model file paths, and reports whether all five files are found.'
    $miModels.Add_Click({ Show-MossModelFilesDialog })
    [void]$mossOptionsMenu.Items.Add('-')
    $miBench=$mossOptionsMenu.Items.Add('Benchmarks...')
    $miBench.ToolTipText='Measured render times per size/steps, time estimates for your settings and bigger jobs, and the quick benchmark.'
    $miBench.Add_Click({ Show-MossBenchmarkDialog })
    $miReport=$mossOptionsMenu.Items.Add('Error report')
    $miReport.ToolTipText='Copies an anonymised technical error report to the clipboard and saves it under logs. Nothing is sent over the internet.'
    $miReport.Add_Click({ Copy-MossErrorReport })
    [void]$mossOptionsMenu.Items.Add('-')
    # POWER SAVER (v0.2.5): a three-level submenu. The chosen level is
    # applied to every engine process started afterwards. Checkmarks show
    # the current level when the menu opens.
    $miPower=$mossOptionsMenu.Items.Add('Power saver')
    $miPower.ToolTipText='Slow image generation down on purpose so the PC keeps its speed (CPU and GPU) for other programs while images render in the background.'
    $psLevels=@(@('Off','Off (full speed)'),@('Gentle','Gentle (other programs first)'),@('Max saving','Max saving (PC fully responsive)'))
    foreach($psL in $psLevels){
        $psItem=$miPower.DropDownItems.Add([string]$psL[1])
        $psItem.ToolTipText=switch([string]$psL[0]){
            'Gentle' { 'The engine runs at below-normal priority: other programs get the CPU and GPU first. Generation is somewhat slower.' }
            'Max saving' { 'The engine runs at lowest priority: the PC stays fully responsive. Generation can take much longer.' }
            default { 'Full speed - no throttling (the default).' }
        }
        $psLvl=[string]$psL[0]
        $psItem.Add_Click({ Set-MossPowerSaver $psLvl }.GetNewClosure())
    }
    $psMenuRef=$miPower
    $mossOptionsMenu.Add_Opening({
        try {
            $cur=if($script:Settings.Contains('PowerSaver')){[string]$script:Settings.PowerSaver}else{'Off'}
            $curLabel=($psLevels | Where-Object { $_[0] -eq $cur } | Select-Object -First 1)[1]
            foreach($it in $psMenuRef.DropDownItems){ if($it -is [System.Windows.Forms.ToolStripItem]){ $it.Checked = ($curLabel -and $it.Text.StartsWith($curLabel)) } }
        } catch {}
    })
    $miSetup=$mossOptionsMenu.Items.Add('Hardware / Setup...')
    $miSetup.Add_Click({ $f.Tag='SETUP'; $f.Close() })
    $miSetup.ToolTipText='Adapter detection, backend selection (CUDA / Vulkan / ROCm / SYCL / CPU) and GPU preference.'
    $miEngine=$mossOptionsMenu.Items.Add('Update engine...')
    $miEngine.Add_Click({ Show-MossEngineUpdateDialog $f })
    $miEngine.ToolTipText='Updates the sd-cli engine core files (the renderer in the bin folder): shows release changelogs and installs the newest engine build. MOSS itself is not changed.'
    $miUpdate=$mossOptionsMenu.Items.Add('Update MOSS...')
    $miUpdate.ToolTipText="Updates the MOSS application itself (the program files). Models, outputs and the sd-cli engine are not touched. Use 'Update engine...' for the rendering engine."
    $mossOptionsMenu.Add_Opening({
        try {
            $of = Get-AbsoluteAppPath ([string]$out.Text)
            $miOut.Text = if (Test-Path -LiteralPath $of -PathType Container) { ('Output folder...  (' + (Split-Path -Leaf $of) + ')') } else { 'Output folder...  (not set)' }
            $missing = 0
            try { $missing = [int](Update-MossModelSummary) } catch { $missing = -1 }
            $miModels.Text = if ($missing -eq 0) { 'Model files...  (all found)' } elseif ($missing -gt 0) { ('Model files...  ({0} missing)' -f $missing) } else { 'Model files...' }
        } catch {}
    })
    $optBtn=New-Object System.Windows.Forms.Button; $optBtn.Text=('Options  ' + [char]0x25BE); $optBtn.Size=New-Object System.Drawing.Size(86,24); $optBtn.Location=New-Object System.Drawing.Point(950,13); $optBtn.FlatStyle='Flat'; $optBtn.BackColor=$cAccent; $optBtn.ForeColor=[System.Drawing.Color]::White; $head.Controls.Add($optBtn)
    $optBtn.Add_Click({ $mossOptionsMenu.Show($optBtn, 0, $optBtn.Height) })
    # Responsive header (v0.1.91/97): the title and subtitle on the left grow
    # with their text, while the BACKEND badge and the Options button used to
    # be anchored to the RIGHT edge - on a narrower window Windows slid them
    # LEFT until they sat on top of the version title. The whole right side
    # is placed by this handler: the button from the right edge, the badge
    # between title and button, clamped so it can never overlap the title.
    $mossHeadLayout = {
        try {
            $optBtn.Left = $head.ClientSize.Width - 25 - $optBtn.Width
            $x = $optBtn.Left - 14 - $backendBadge.Width
            $minX = $ttl.Right + 12
            if ($x -lt $minX) { $x = $minX }
            $backendBadge.Left = $x
        } catch {}
    }
    $head.Add_Resize($mossHeadLayout)
    & $mossHeadLayout
$miUpdate.Add_Click({
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

    # Compact panels (v0.1.96): start at y=58 (header 50 + 8 gap) and are
    # 496 px tall - exactly the collapsed-content height. The action row,
    # status line and progress bar flow below the content instead of being
    # pinned to a fixed bottom edge.
    $left=New-Object System.Windows.Forms.Panel; $left.Location=New-Object System.Drawing.Point(18,58); $left.Size=New-Object System.Drawing.Size(600,430); $left.Anchor='Top,Bottom,Left'; $left.BackColor=$cCard; $f.Controls.Add($left)
    $right=New-Object System.Windows.Forms.Panel; $right.Location=New-Object System.Drawing.Point(634,58); $right.Size=New-Object System.Drawing.Size(366,430); $right.Anchor='Top,Bottom,Left,Right'; $right.BackColor=$cCard; $f.Controls.Add($right)
    try { $left.SuspendLayout() } catch {}
    try { $right.SuspendLayout() } catch {}
    # v0.2.3: the frame is already on screen (early Show() above); the
    # controls now fill the visible panels.
    # v0.2.2: the label box was 22 px tall for a single 9 pt line, so it
    # overlapped the widget below it by 4-5 px. WinForms keeps the label on
    # top (it was added first), which turned that strip into a dead click
    # zone over the top of the input underneath. A 16 px box clears every
    # row: the labels sit above their fields without touching them.
    function Add-Label($parent,[string]$text,[int]$x,[int]$y,[int]$w=200) { $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,16); $l.ForeColor=$cMuted; $parent.Controls.Add($l); return $l }
    function Add-TextBox($parent,[string]$value,[int]$x,[int]$y,[int]$w,[int]$h=26) { $t=New-Object System.Windows.Forms.TextBox; $t.Text=$value; $t.Location=New-Object System.Drawing.Point($x,$y); $t.Size=New-Object System.Drawing.Size($w,$h); $t.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $t.ForeColor=$cText; $t.BorderStyle='FixedSingle'; $parent.Controls.Add($t); return $t }
    function Add-Button($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h=29) { $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location=New-Object System.Drawing.Point($x,$y); $b.Size=New-Object System.Drawing.Size($w,$h); $b.FlatStyle='Flat'; $b.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $b.ForeColor=$cText; $parent.Controls.Add($b); return $b }

    Add-Label $left 'Prompt' 18 10 180 | Out-Null
    $historyPick=New-Object System.Windows.Forms.ComboBox; $historyPick.DropDownStyle='DropDownList'; $historyPick.Location=New-Object System.Drawing.Point(255,7); $historyPick.Size=New-Object System.Drawing.Size(150,25); $historyPick.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $historyPick.ForeColor=$cText; $left.Controls.Add($historyPick); Set-MossComboTheme $historyPick $left
    $resetHistoryCode=Add-Button $left 'History code...' 411 7 90 25
    # The button used to RESET the code directly - which DELETES the saved
    # history and gives no way to enter the existing code after skipping the
    # startup prompt (user: 'i dont get an option to enter the prompt
    # history code'). It is now a small menu: unlock, set new, turn off.
    function Show-MossHistoryCodeMenu([System.Windows.Forms.Form]$Owner) {
        $menu=New-Object System.Windows.Forms.ContextMenuStrip
        if ($script:LockedHistoryEnvelope) {
            $enterItem=$menu.Items.Add('Enter code to unlock the prompt history...')
            $enterItem.Add_Click({ Unlock-MossHistoryAfterShow })
        }
        if ($script:HistoryPassphrase) {
            $infoItem=$menu.Items.Add('Code entered - the prompt history is unlocked')
            $infoItem.Enabled=$false
        }
        $newItem=$menu.Items.Add('Set a NEW code (clears the saved history!)...')
        $newItem.Add_Click({ if(Reset-MossHistoryPassword $Owner){$history=@();$historyPick.Items.Clear();[System.Windows.Forms.MessageBox]::Show('New history code saved. The old history was cleared.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
        if ($script:HistoryEnabled) {
            $offItem=$menu.Items.Add('Turn off prompt history (deletes the saved history)...')
            $offItem.Add_Click({ if(Disable-MossHistory){$historyPick.Items.Clear();[System.Windows.Forms.MessageBox]::Show('Prompt history is off. Nothing is stored anymore.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
        }
        $menu.Show($resetHistoryCode, 0, $resetHistoryCode.Height)
    }
    $resetHistoryCode.Add_Click({ Show-MossHistoryCodeMenu $f })
    $resetHistoryCode.Enabled=$true
    foreach($oldPrompt in @($history | Select-Object -First 10)){[void]$historyPick.Items.Add([string]$oldPrompt)}
    $paste=Add-Button $left 'Paste' 507 7 75 25
    $paste.Enabled=$true
    # Prompt box (v0.1.95): HALF WIDTH (331 px), same 96 px height (4 lines)
    # - the full-width editor dominated the panel. Fixed width (no Right
    # anchor) so it stays exactly this size when the window grows. (v0.1.96:
    # moved up 5 px with the tightened row spacing.)
    $prompt=New-Object System.Windows.Forms.TextBox; $prompt.Multiline=$true; $prompt.AcceptsReturn=$true; $prompt.AcceptsTab=$true; $prompt.ScrollBars='Vertical'; $prompt.Location=New-Object System.Drawing.Point(18,34); $prompt.Size=New-Object System.Drawing.Size(331,96); $prompt.Anchor='Top,Left'; $prompt.Font=New-Object System.Drawing.Font('Segoe UI',10); $prompt.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $prompt.ForeColor=$cText; $prompt.BorderStyle='FixedSingle'; $left.Controls.Add($prompt)
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
            if($choice -eq 'skip'){$script:HistoryLocked=$true;$script:Settings.PromptHistory=@();[System.Windows.Forms.MessageBox]::Show('MOSS will continue without prompt history. The encrypted history is preserved. You can enter the code later via the History code... button (top left, next to Paste).','History locked')|Out-Null;return}
            if($choice -eq 'reset'){if(Reset-MossHistoryPassword $f){$historyPick.Items.Clear();return};continue}
            if($choice -eq 'disable'){if(Disable-MossHistory){$historyPick.Items.Clear();return};continue}
        }
    }

    # (v0.1.97, user: the image-settings heading was unnecessary - the row
    # now starts directly with the Generation... button.)
    $negInitial=if([string]$script:Settings.NegativePrompt){'negative prompt: set'}else{'negative prompt: not set'}
    $negState=Add-Label $left $negInitial 108 135 240
    function Show-MossGenerationOptionsDialog {
        # Advanced generation options in one dialog so the compact main window
        # stays uncluttered: negative prompt (engine flag -n), sampler and
        # scheduler. 'Default (model)' omits the flag so the engine keeps its
        # model-specific choice (euler for Flux/SD3/Wan).
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Generation options'; $g.Size=New-Object System.Drawing.Size(560,604); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $hint=New-Object System.Windows.Forms.Label; $hint.Text='Negative prompt - what the image should NOT contain, e.g. blurry, extra fingers, watermark. Left empty = none.'; $hint.Location=New-Object System.Drawing.Point(12,10); $hint.Size=New-Object System.Drawing.Size(520,20); $hint.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($hint)
        # Negative prompt box (v0.1.97, user: 'again huge'): SAME size as the
        # main-window prompt box (331 x 96) instead of the old 520 x 120 -
        # it scrolls, so long prompts still work.
        $box=New-Object System.Windows.Forms.TextBox; $box.Multiline=$true; $box.ScrollBars='Vertical'; $box.Text=[string]$script:Settings.NegativePrompt; $box.Location=New-Object System.Drawing.Point(12,34); $box.Size=New-Object System.Drawing.Size(331,96); $box.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $box.ForeColor=$cText; $box.BorderStyle='FixedSingle'; $g.Controls.Add($box)
        Add-Label $g 'Sampler' 12 170 100 | Out-Null
        # Snug dropdowns (v0.1.97, user: 'fit the text, but only barely'):
        # each combo is just wide enough for its longest entry (the open
        # list auto-expands to the longest item regardless).
        $optSampler=New-Object System.Windows.Forms.ComboBox; $optSampler.DropDownStyle='DropDownList'; $optSampler.Location=New-Object System.Drawing.Point(12,192); $optSampler.Size=New-Object System.Drawing.Size(130,26); $optSampler.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $optSampler.ForeColor=$cText
        foreach($s in @('Default (euler)','euler','euler_a','heun','dpm2','dpm++2s_a','dpm++2m','dpm++2mv2','ipndm','ipndm_v','lcm','ddim_trailing','tcd','res_multistep','res_2s','er_sde','euler_cfg_pp','euler_a_cfg_pp','euler_ge','dpm++2m_sde','dpm++2m_sde_bt','lms')){[void]$optSampler.Items.Add($s)}
        $storedSampler=[string]$script:Settings.SamplingMethod; if($storedSampler -eq 'Default (model)'){$storedSampler='Default (euler)'}
        $optSampler.SelectedItem=$storedSampler; if($optSampler.SelectedIndex -lt 0){$optSampler.SelectedIndex=0}; $g.Controls.Add($optSampler); Set-MossComboTheme $optSampler $g
        Add-Label $g 'Scheduler' 280 170 100 | Out-Null
        $optSched=New-Object System.Windows.Forms.ComboBox; $optSched.DropDownStyle='DropDownList'; $optSched.Location=New-Object System.Drawing.Point(280,192); $optSched.Size=New-Object System.Drawing.Size(175,26); $optSched.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $optSched.ForeColor=$cText
        foreach($s in @('Default (flux schedule)','discrete','karras','exponential','ays','gits','sgm_uniform','simple','smoothstep','kl_optimal','lcm','bong_tangent','ltx2','logit_normal','flux2','flux','beta','llada_image')){[void]$optSched.Items.Add($s)}
        $storedSched=[string]$script:Settings.Scheduler; if($storedSched -eq 'Default (model)'){$storedSched='Default (flux schedule)'}
        $optSched.SelectedItem=$storedSched; if($optSched.SelectedIndex -lt 0){$optSched.SelectedIndex=0}; $g.Controls.Add($optSched); Set-MossComboTheme $optSched $g
        # Plain-language descriptions: shown inline below each dropdown and on
        # hover, updated as the user browses the lists.
        $samplerDescriptions=@{
          'Default (euler)'="Uses the engine's default for this model: euler. Recommended."
          'euler'='Simple, reliable all-rounder; good at any step count.'
          'euler_a'='Ancestral euler: adds randomness each step - more variety, but the same seed can give slightly different images.'
          'heun'='More accurate per step, but roughly twice the work per step.'
          'dpm2'='Deterministic second-order solver: crisp, sensitive to step count.'
          'dpm++2s_a'='Ancestral second-order solver: sharp detail with some randomness.'
          'dpm++2m'='Fast, converging solver; very good quality at moderate steps. Verified in-house: same detail as euler at HALF the steps (~40% less time) - the fast-sampler default for improves.'
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
          'karras'='Karras schedule: more steps on fine detail near the end; often sharper texture. Verified in-house: sharper than the default schedule at the same step count.'
          'exponential'='Exponential sigma spacing: smooth, even denoising.'
          'ays'='Align Your Steps: CAUTION - verified incompatible with second-order samplers (dpm++2m family) on this engine: the render continues WITHOUT the scheduler and can come out blank. Use with euler only.'
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
        $note=New-Object System.Windows.Forms.Label; $note.Text="'Default (euler)' and 'Default (flux schedule)' use the engine's own choice - recommended unless you want to experiment. Quick improve reuses the image's own settings; 'Improve this image' opens a dialog where you pick the target size (Same/2x/4x) with steps and CFG prefilled from here."; $note.Location=New-Object System.Drawing.Point(12,392); $note.Size=New-Object System.Drawing.Size(520,32); $note.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($note)
        # MOSS is a GUI front-end for the sd-cli command-line engine: optionally
        # log the exact command line before every run (full transparency).
        $cmdCheck=New-Object System.Windows.Forms.CheckBox; $cmdCheck.Text='Show the exact sd-cli command line in the generation log (see what MOSS runs)'; $cmdCheck.Location=New-Object System.Drawing.Point(12,364); $cmdCheck.Size=New-Object System.Drawing.Size(520,24); $cmdCheck.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($cmdCheck)
        $cmdCheck.Checked= (-not $script:Settings.Contains('ShowEngineCommandLine')) -or ([string]$script:Settings.ShowEngineCommandLine -eq '1')
        $safeCheck=New-Object System.Windows.Forms.CheckBox; $safeCheck.Text='Safe mode - block sexual and gore/violence prompts: matching prompts are refused before anything runs, and safety words are added to the negative prompt'; $safeCheck.Location=New-Object System.Drawing.Point(12,430); $safeCheck.Size=New-Object System.Drawing.Size(520,30); $safeCheck.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($safeCheck)
        $safeCheck.Checked = [bool]$script:Settings.SafeMode
        $safeHint=New-Object System.Windows.Forms.Label; $safeHint.Text='Safe mode applies to generation, improving and re-rendering alike. It is a prompt gate, not a trained image filter - creative wording can still slip past.'; $safeHint.Location=New-Object System.Drawing.Point(12,464); $safeHint.Size=New-Object System.Drawing.Size(520,32); $safeHint.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($safeHint)
        $negOk=Add-Button $g 'Save' 350 506 80 30
        $negCancel=Add-Button $g 'Cancel' 440 506 90 30
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
            $script:Settings.SafeMode=[bool]$safeCheck.Checked
            # PERSIST IMMEDIATELY (v0.1.89): Options changes used to be written
            # to disk only at the NEXT generate - deleting the negative prompt
            # and restarting MOSS brought the old text back (user report), and
            # a Safe-mode toggle would silently revert the same way.
            [void](Save-Settings)
            $negState.Text=if($script:Settings.NegativePrompt){('negative prompt: set ('+$script:Settings.NegativePrompt.Length+' chars)')}else{'negative prompt: not set'}
            $g.Close()
        })
        $negCancel.Add_Click({$g.Close()})
        [void]$g.ShowDialog($f)
    }
    # 'Generation...' (v0.1.97): was 'Options...' - the header now has its
    # own Options menu (Setup / engine / MOSS updates), so the in-panel
    # generation-settings button is named for what it opens. Width measured.
    $negBtn=Add-Button $left 'Generation...' 18 134 84 22
    $negBtn.Add_Click({ Show-MossGenerationOptionsDialog })
    Add-Label $left 'Visual style' 18 163 130 | Out-Null
    # Snug dropdown (v0.1.97): fits 'Dark fantasy / gothic', barely.
    $style=New-Object System.Windows.Forms.ComboBox; $style.DropDownStyle='DropDownList'; $style.Location=New-Object System.Drawing.Point(18,181); $style.Size=New-Object System.Drawing.Size(160,23); $style.MaxDropDownItems=7; $style.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $style.ForeColor=$cText; foreach($item in @('None (no style)','Photorealistic','Anime','Digital illustration','Oil painting','Watercolor','3D render','Comic book','Cinematic','Fantasy art','Dark fantasy / gothic','Cyberpunk / sci-fi','Studio portrait','Sketch / pencil drawing','Pixel art','Synthwave / retro 80s','Low poly 3D')){[void]$style.Items.Add($item)}; $style.SelectedItem=[string]$script:Settings.ImageStyle; if($style.SelectedIndex -lt 0){$style.SelectedIndex=0}; $left.Controls.Add($style); Set-MossComboTheme $style $left
    # Resolution sits UNDER Visual style (v0.1.99, user).
    Add-Label $left 'Resolution' 18 209 90 | Out-Null
    # Snug dropdown (v0.1.97): fits 'Landscape 16:9  |  1360 x 768', barely.
    $res=New-Object System.Windows.Forms.ComboBox; $res.DropDownStyle='DropDownList'; $res.Location=New-Object System.Drawing.Point(18,226); $res.Size=New-Object System.Drawing.Size(190,23); $res.MaxDropDownItems=7; $res.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $res.ForeColor=$cText
    $resItems=@('Landscape 16:9  |  1360 x 768','Square  |  1024 x 1024','Portrait 3:4  |  768 x 1024','Landscape 4:3  |  1280 x 960','Portrait 9:16  |  768 x 1360','2K Landscape  |  2560 x 1440','2K Square  |  2048 x 2048','2K Portrait  |  1536 x 2048','2K 4:3  |  2048 x 1536','2K 9:16  |  1440 x 2560','4K Landscape  |  3840 x 2160','4K Square  |  4096 x 4096','4K Portrait  |  3072 x 4096','4K 4:3  |  4096 x 3072','4K 9:16  |  2160 x 3840','Custom dimensions')
    foreach($ri in $resItems){[void]$res.Items.Add($ri)}; $left.Controls.Add($res); Set-MossComboTheme $res $left
    $wBox=Add-TextBox $left ([string]$script:Settings.Width) 232 226 82 23; $hBox=Add-TextBox $left ([string]$script:Settings.Height) 327 226 82 23
    Add-Label $left 'Width' 232 209 80 | Out-Null; Add-Label $left 'Height' 327 209 80 | Out-Null
    $resMap=@(@(1360,768),@(1024,1024),@(768,1024),@(1280,960),@(768,1360),@(2560,1440),@(2048,2048),@(1536,2048),@(2048,1536),@(1440,2560),@(3840,2160),@(4096,4096),@(3072,4096),@(4096,3072),@(2160,3840))
    $matched=-1; for($ri=0;$ri -lt $resMap.Count;$ri++){if([int]$script:Settings.Width -eq $resMap[$ri][0] -and [int]$script:Settings.Height -eq $resMap[$ri][1]){$matched=$ri;break}}; if($matched -ge 0){$res.SelectedIndex=$matched}else{$res.SelectedIndex=15}
    $res.Add_SelectedIndexChanged({ if($res.SelectedIndex -ge 0 -and $res.SelectedIndex -lt $resMap.Count){$wBox.Text=[string]$resMap[$res.SelectedIndex][0];$hBox.Text=[string]$resMap[$res.SelectedIndex][1]} })
    Add-Label $left 'Steps' 18 254 70 | Out-Null; $steps=Add-TextBox $left ([string]$script:Settings.Steps) 18 271 75 23
    Add-Label $left 'CFG scale' 110 254 90 | Out-Null; $cfg=Add-TextBox $left ([string]$script:Settings.CfgScale) 110 271 62 23
    $cfgHelp=Add-Button $left '?' 174 271 20 23
    $cfgHelp.Add_Click({
        [System.Windows.Forms.MessageBox]::Show("CFG scale (Classifier-Free Guidance) controls how strictly the image follows your prompt.`r`n`r`n- Low (1-4): more artistic freedom, softer prompt adherence. This model is tuned for this range - the default 3 suits it well.`r`n- Medium (5-10): stronger prompt following; colors and contrast grow.`r`n- High (15-30): forces the prompt hard - often causes burned, oversaturated or distorted images.`r`n`r`nRule of thumb: raise it only if the image ignores parts of your prompt; lower it if images look overcooked.",'What is CFG scale?',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    })
    Add-Label $left 'Images' 202 254 70 | Out-Null; $count=New-Object System.Windows.Forms.ComboBox; $count.DropDownStyle='DropDown'; $count.Location=New-Object System.Drawing.Point(202,271); $count.Size=New-Object System.Drawing.Size(75,23); foreach($n in @(1,2,4,8,16,32,64,128,256,512,1000)){[void]$count.Items.Add([string]$n)}; $count.Text=[string]$script:Settings.ImageCount; $left.Controls.Add($count); Set-MossComboTheme $count $left
    Add-Label $left 'Seed (-1 = random)' 284 254 116 | Out-Null; $seed=Add-TextBox $left ([string]$script:Settings.Seed) 284 271 90 23
    # Speed modes (v0.1.93): 8x and Fastest REMOVED from the UI - measured,
    # their drafts (35% / 128-px side) are too soft to be useful and cannot
    # be rescued by any improve (see Test-MossUltraSoftDraft). The engine
    # and all internal helpers still SUPPORT '8x'/'Fast' for old benchmark
    # data, old queue items and the OOM auto-retry ladder.
    $speedCombo=New-Object System.Windows.Forms.ComboBox; $speedCombo.DropDownStyle='DropDownList'; $speedCombo.Location=New-Object System.Drawing.Point(404,271); $speedCombo.Size=New-Object System.Drawing.Size(130,23); $speedCombo.MaxDropDownItems=3; $speedCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $speedCombo.ForeColor=$cText; foreach($si in @('Exact (full quality)','~2x faster (70%)','~4x faster (50%)')){[void]$speedCombo.Items.Add($si)}; $speedCombo.SelectedIndex=0; $left.Controls.Add($speedCombo); Set-MossComboTheme $speedCombo $left
    $speedHint=New-Object System.Windows.Forms.Label; $speedHint.Text='Faster modes render the image small and enlarge it - quick drafts. Exact = full size, full steps.'; $speedHint.Location=New-Object System.Drawing.Point(284,296); $speedHint.Size=New-Object System.Drawing.Size(250,46); $speedHint.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $left.Controls.Add($speedHint)
    # OUTPUT FOLDER (v0.1.98): MOVED INTO THE HEADER OPTIONS MENU (user).
    # The read-only textbox stays as a HIDDEN state holder - the generate
    # handler and 'Open output' read it directly.
    $out=Add-TextBox $left ([string]$script:Settings.OutputPath) 18 346 506 23; $out.ReadOnly=$true; $out.Visible=$false
    # Model files (v0.1.98): MOVED INTO THE HEADER OPTIONS MENU (user). The
    # four path textboxes remain as HIDDEN state holders - the generate
    # handler reads them directly. 'Model files...' opens a dialog that
    # edits copies of them (OK applies, Cancel discards).
    $modelRows=@(
      @('Diffusion model','DiffusionModelPath','moss_image_sft_int8_convrot.safetensors'),
      @('LLM','LlmPath','Qwen3.5-9B-Q4_K_M.gguf'),
      @('VAE','VaePath','flux2-vae.safetensors'),
      @('Tokenizer','TokenizerPath','tokenizer_qwen3.5.json')
    )
    $modelControls=@{}
    foreach($mr in $modelRows){
        $val=[string]$script:Settings[$mr[1]]; if([string]::IsNullOrWhiteSpace($val)){$val=Join-Path $script:AppRoot ('models\'+$mr[2])} else {$val=Get-AbsoluteAppPath $val}
        $tb=Add-TextBox $left $val -2000 -2000 419 23; $tb.Visible=$false
        $modelControls[$mr[1]]=$tb
    }
    function Update-MossModelSummary {
        $check=@((Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)))
        foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $check+=(Get-AbsoluteAppPath $modelControls[$k].Text) }
        return @($check | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count
    }
    function Show-MossModelFilesDialog {
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Model files'; $g.Size=New-Object System.Drawing.Size(560,296); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $hint=New-Object System.Windows.Forms.Label; $hint.Text='The engine and model files MOSS loads. Paths are resolved against the MOSS folder.'; $hint.Location=New-Object System.Drawing.Point(12,10); $hint.Size=New-Object System.Drawing.Size(520,20); $hint.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($hint)
        $dlgBoxes=@{}
        $y=38
        # ENGINE ROW (v0.2.6): the health count is 'N of 5 engine/model files'
        # - the engine file is the fifth file, but the dialog only showed the
        # four model rows, so the number never matched what was visible.
        # The engine path is read-only here (it is edited in Hardware /
        # Setup), it just makes the fifth counted file visible.
        $engL=New-Object System.Windows.Forms.Label; $engL.Text='Engine'; $engL.Location=New-Object System.Drawing.Point(12,($y+3)); $engL.Size=New-Object System.Drawing.Size(120,22); $engL.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($engL)
        $engTb=New-Object System.Windows.Forms.TextBox; $engTb.Text=[string]$script:Settings.EnginePath; $engTb.Location=New-Object System.Drawing.Point(140,$y); $engTb.Size=New-Object System.Drawing.Size(364,23); $engTb.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $engTb.ForeColor=$cText; $engTb.BorderStyle='FixedSingle'; $engTb.ReadOnly=$true; $g.Controls.Add($engTb)
        $engTb.ForeColor= if (Test-Path -LiteralPath (Get-AbsoluteAppPath $engTb.Text) -PathType Leaf) { [System.Drawing.Color]::FromArgb(230,236,245) } else { [System.Drawing.Color]::FromArgb(224,138,138) }
        $y+=30
        foreach($mr in $modelRows){
            $rl=New-Object System.Windows.Forms.Label; $rl.Text=$mr[0]; $rl.Location=New-Object System.Drawing.Point(12,($y+3)); $rl.Size=New-Object System.Drawing.Size(120,22); $rl.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($rl)
            $tb=New-Object System.Windows.Forms.TextBox; $tb.Text=[string]$modelControls[$mr[1]].Text; $tb.Location=New-Object System.Drawing.Point(140,$y); $tb.Size=New-Object System.Drawing.Size(364,23); $tb.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $tb.ForeColor=$cText; $tb.BorderStyle='FixedSingle'; $g.Controls.Add($tb)
            $dlgBoxes[$mr[1]]=$tb
            $bb=Add-Button $g '...' 508 $y 30 23
            $key=$mr[1]
            $bb.Add_Click({$dlg=New-Object System.Windows.Forms.OpenFileDialog;$dlg.Title="Select file";$dlg.Filter='Model and data files|*.safetensors;*.gguf;*.json|All files (*.*)|*.*';$dlg.CheckFileExists=$true;$cur=Get-AbsoluteAppPath $dlgBoxes[$key].Text;if(Test-Path -LiteralPath $cur -PathType Leaf){$dlg.InitialDirectory=Split-Path -Parent $cur;$dlg.FileName=Split-Path -Leaf $cur}else{$modelsDir=Join-Path $script:AppRoot 'models';if(Test-Path -LiteralPath $modelsDir -PathType Container){$dlg.InitialDirectory=$modelsDir}};if($dlg.ShowDialog($g) -eq 'OK'){$dlgBoxes[$key].Text=$dlg.FileName};[void](Update-MossDlgSummary);$dlg.Dispose()}.GetNewClosure())
            $y+=30
        }
        $dlgSummary=New-Object System.Windows.Forms.Label; $dlgSummary.Location=New-Object System.Drawing.Point(12,194); $dlgSummary.Size=New-Object System.Drawing.Size(520,20); $g.Controls.Add($dlgSummary)
        function Update-MossDlgSummary {
            $check=@((Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)))
            foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $check+=(Get-AbsoluteAppPath $dlgBoxes[$k].Text) }
            $missing=@($check | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
            if($missing.Count -eq 0){ $dlgSummary.Text='All 5 engine/model files found.'; $dlgSummary.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164) }
            else { $dlgSummary.Text=('{0} of 5 engine/model file(s) not found.' -f $missing.Count); $dlgSummary.ForeColor=[System.Drawing.Color]::FromArgb(224,138,138) }
        }
        [void](Update-MossDlgSummary)
        $ok=Add-Button $g 'OK' 386 226 80 26
        $cancel=Add-Button $g 'Cancel' 474 226 80 26
        $ok.Add_Click({
            foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $modelControls[$k].Text=[string]$dlgBoxes[$k].Text }
            $g.Close()
        })
        $cancel.Add_Click({$g.Close()})
        $g.AcceptButton=$ok
        [void]$g.ShowDialog($f)
    }

    # Compact action row (v0.1.96/98): half-size buttons (24 px tall). The
    # row is placed by Update-MossLeftActionLayout right below the speed
    # hint; with Output folder / Model files / Error report / Benchmarks in
    # the header Options menu, only the four generation actions remain.
    try { $f.Refresh() } catch {}
    $generate=Add-Button $left 'Generate' 18 348 96 24; $generate.BackColor=$cAccent; $generate.ForeColor=[System.Drawing.Color]::White; $generate.Font=New-Object System.Drawing.Font('Segoe UI Semibold',9,[System.Drawing.FontStyle]::Bold)
    $cancel=Add-Button $left 'Cancel' 120 348 56 24; $cancel.Enabled=$false
    # Pause/Resume (v0.1.91): freezes the RUNNING engine process for real
    # (ntdll NtSuspendProcess) and continues it on Resume - a large batch
    # can be put on hold without losing the run.
    $btnPause=Add-Button $left 'Pause' 182 348 60 24; $btnPause.Enabled=$false
    $btnPause.Add_Click({
        $st=$script:GenState
        if (-not $st.IsRunning -or $null -eq $st.Process -or $st.Process.HasExited) { return }
        if (-not $st.Paused) {
            if (Suspend-MossProcess $st.Process) {
                $st.Paused=$true; $st.PausedAt=Get-Date
                $btnPause.Text='Resume'
                $status.Text=("PAUSED - image {0} of {1} frozen (VRAM stays allocated). Click Resume to continue." -f [int]$st.CurrentImageIndex,[int]$st.Job.Count)
                $log.AppendText("`r`nPaused: the engine process is frozen mid-batch. Images already saved are kept; nothing renders until you click Resume.")
            } else {
                $log.AppendText("`r`nPause failed: the engine process could not be suspended (it keeps running).")
            }
        } else {
            if (Resume-MossProcess $st.Process) {
                # Shift the time anchors by the paused span so elapsed
                # times, the ETA and the power meter exclude the pause.
                $pauseSpan=((Get-Date)-$st.PausedAt).TotalSeconds
                if ($st.JobStartedAt) { $st.JobStartedAt=$st.JobStartedAt.AddSeconds($pauseSpan) }
                if ($st.ImageStartedAt) { $st.ImageStartedAt=$st.ImageStartedAt.AddSeconds($pauseSpan) }
                if ($script:RefineStartedAt) { $script:RefineStartedAt=$script:RefineStartedAt.AddSeconds($pauseSpan) }
                $st.PausedTotalSec=[double]$st.PausedTotalSec+$pauseSpan
                $st.Paused=$false; $st.PausedAt=$null
                $st.PowerLastSample=Get-Date
                $btnPause.Text='Pause'
                $status.Text='Rendering...'
                $log.AppendText(("`r`nResumed after {0} paused. Rendering continues." -f (Format-MossDuration $pauseSpan)))
            } else {
                $log.AppendText("`r`nResume failed: the engine process could not be resumed.")
            }
        }
    })
    $openOut=Add-Button $left 'Open output' 248 348 92 24
    function Show-MossBenchmarkDialog {
        # Shows every recorded resolution/steps/speed-mode combination with its
        # real measured seconds per image, an estimate for the CURRENT main
        # window settings, and a quick benchmark runner for gaps in the table.
        # The bigger-job estimator at the bottom extrapolates the recorded
        # measurements to ANY size / steps / speed mode / image count.
        $g = New-Object System.Windows.Forms.Form
        $g.Text = 'Performance benchmarks'; $g.Size = New-Object System.Drawing.Size(780, 760); $g.StartPosition = 'CenterParent'; $g.FormBorderStyle = 'FixedDialog'; $g.MaximizeBox = $false
        $g.BackColor = $cPanel; $g.ForeColor = $cText; $g.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $hint = New-Object System.Windows.Forms.Label; $hint.Text = 'Measured seconds per image for every size / speed mode / step combination that ran on this PC. Times are engine render time per image (image-to-image runs are listed separately).'; $hint.Location = New-Object System.Drawing.Point(14, 10); $hint.Size = New-Object System.Drawing.Size(730, 30); $hint.ForeColor = $cMuted; $g.Controls.Add($hint)

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false
        $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BorderStyle = 'None'
        $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(16, 21, 30); $grid.GridColor = [System.Drawing.Color]::FromArgb(40, 50, 66)
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(25, 32, 45); $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(200, 210, 225)
        $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(16, 21, 30); $grid.DefaultCellStyle.ForeColor = $cText
        $grid.Location = New-Object System.Drawing.Point(14, 44); $grid.Size = New-Object System.Drawing.Size(734, 300); $g.Controls.Add($grid)
        foreach ($n in @('Resolution', 'Mode', 'Type', 'Engine steps', 'Avg / image', 'Runs', 'Last recorded')) {
            $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c.Name = $n; $c.HeaderText = $n; $c.ReadOnly = $true
            if ($n -eq 'Resolution' -or $n -eq 'Avg / image' -or $n -eq 'Last recorded') { $c.FillWeight = 22 } else { $c.FillWeight = 10 }
            [void]$grid.Columns.Add($c)
        }

        $estLabel = New-Object System.Windows.Forms.Label; $estLabel.Location = New-Object System.Drawing.Point(14, 352); $estLabel.Size = New-Object System.Drawing.Size(734, 44); $estLabel.ForeColor = [System.Drawing.Color]::FromArgb(125, 205, 164); $g.Controls.Add($estLabel)

        $fillGrid = {
            $grid.Rows.Clear()
            $list = Load-MossBenchmarks
            $groups = @{}
            foreach ($e in $list) {
                # Detail-regeneration runs get their OWN row: their measured
                # time includes the enlarged second pass and is not comparable
                # with a plain run at the same size/steps.
                $hr = 0.0; if ($e.PSObject.Properties['HiresScale']) { $hr = [double]$e.HiresScale }
                $k = ('{0}x{1}|{2}|{3}|{4}|{5}' -f $e.W, $e.H, $e.SpeedMode, $e.Steps, [bool]$e.Img2Img, $hr)
                if (-not $groups.Contains($k)) { $groups[$k] = @{ Sum = 0.0; Runs = 0; Last = '' ; W = $e.W; H = $e.H; Mode = $e.SpeedMode; Steps = $e.Steps; I2I = [bool]$e.Img2Img; Hr = $hr } }
                $groups[$k].Sum += ([double]$e.SecondsPerImage * [int]$e.Images)
                $groups[$k].Runs += [int]$e.Images
                if ([string]$e.Date -gt $groups[$k].Last) { $groups[$k].Last = [string]$e.Date }
            }
            $rows = @($groups.Values | Sort-Object { -([double]$_.W * $_.H) }, { -[int]$_.Steps })
            foreach ($r0 in $rows) {
                $avg = if ($r0.Runs -gt 0) { $r0.Sum / $r0.Runs } else { 0 }
                [void]$grid.Rows.Add(@(
                    ('{0} x {1}' -f $r0.W, $r0.H),
                    $r0.Mode,
                    $(if ($r0.Hr -ge 1.5) { ('img2img + highres {0}x' -f ([string]$r0.Hr).Replace(',', '.')) } elseif ($r0.I2I) { 'img2img' } else { 'fresh' }),
                    ([string]$r0.Steps),
                    (Format-MossFixedTime $avg),
                    ([string]$r0.Runs),
                    $r0.Last
                ))
            }
            if ($rows.Count -eq 0) { [void]$grid.Rows.Add(@('No data yet - generate images or run the quick benchmark', '', '', '', '', '', '')) }
        }

        $refreshEstimate = {
            try {
                $wi = [int]$wBox.Text; $he = [int]$hBox.Text; $stn = [int]$steps.Text
                $mode = switch ([string]$speedCombo.SelectedItem) { '~2x faster (70%)' { '2x' } '~4x faster (50%)' { '4x' } default { 'Exact' } }
                $bm = Get-MossBenchmarkEstimate $wi $he $mode $stn $false
                if ($bm) {
                    $estLabel.Text = ('Estimated for your current settings ({0} x {1}, {2}, {3} steps): ~{4} per image  -  ~{5} for a batch of 16.{6}Based on the measured run: {7}.' -f $wi, $he, $mode, $stn, (Format-MossFixedTime $bm.Sec), (Format-MossFixedTime ($bm.Sec * 16)), [Environment]::NewLine, $bm.Based)
                } else {
                    $estLabel.Text = 'No benchmark data yet for an estimate - generate a few images (or run the quick benchmark below) and this fills in automatically.'
                }
            } catch { $estLabel.Text = 'Estimate unavailable.' }
        }
        & $fillGrid
        & $refreshEstimate

        $runBtn = Add-Button $g 'Run quick benchmark...' 14 406 200 32
        $runBtn.Add_Click({
            if ($script:GenState.IsRunning) { [System.Windows.Forms.MessageBox]::Show($g, 'A generation is running. Wait for it to finish first.', 'Benchmarks') | Out-Null; return }
            $quickAnswer = [System.Windows.Forms.MessageBox]::Show($g, "The quick benchmark renders 3 small test images (512 x 512, 1024 x 1024, 2048 x 2048) at 8 steps each with your current sampler settings.`r`n`r`nThey run one after another in a 'benchmarks' folder (not in your output list) and their measured times fill the table above.`r`n`r`nStart now? (Roughly a few minutes on most GPUs.)", 'Quick benchmark', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($quickAnswer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $script:RefineQueue.Clear()
            # 'Default (model)' is the DISPLAY label in the options dialog, not an
            # engine value: like every other queue path (Get-MossImproveDefaults,
            # the generate button), an empty value makes the engine flag be OMITTED
            # so the model keeps its own default. Passing the label verbatim made
            # sd-cli reject the command ('unknown argument: (model)').
            $benchSampler = [string]$script:Settings.SamplingMethod; if ($benchSampler -eq 'Default (model)') { $benchSampler = '' }
            $benchSched = [string]$script:Settings.Scheduler; if ($benchSched -eq 'Default (model)') { $benchSched = '' }
            foreach ($sz in @(@(512, 512), @(1024, 1024), @(2048, 2048))) {
                [void]$script:RefineQueue.Add([pscustomobject]@{ File = ''; W = [int]$sz[0]; H = [int]$sz[1]; Seed = 42; Prompt = 'benchmark speed test'; NegativePrompt = ''; SamplingMethod = $benchSampler; Scheduler = $benchSched; Strength = 0.6; Steps = 8; Cfg = [double]$script:Settings.CfgScale; Tag = 'bench'; FreshRender = $true })
            }
            $script:RefineTotal = $script:RefineQueue.Count
            $script:RefineStartedAt = Get-Date
            $g.Close()
            Start-MossNextRefine
        })
        $clearBtn = Add-Button $g 'Clear recorded data...' 226 406 180 32
        $clearBtn.Add_Click({
            $a = [System.Windows.Forms.MessageBox]::Show($g, 'Delete ALL recorded benchmark data? Times are re-learned as you keep generating.', 'Clear benchmark data', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Save-MossBenchmarks (New-Object System.Collections.ArrayList)
            & $fillGrid
            & $refreshEstimate
        })
        $closeBtn = Add-Button $g 'Close' 660 406 88 32
        $closeBtn.Add_Click({ $g.Close() })

        # --- Bigger-job estimator -------------------------------------------
        # Type ANY size, steps, speed mode and image count: the expected per
        # image and total render time is extrapolated from the benchmark store
        # (scaled by render megapixels x engine steps, same rule as the live
        # ETA). Answering 'what would a bigger job take' without rendering it.
        $calcHead = New-Object System.Windows.Forms.Label; $calcHead.Text = 'Bigger jobs - what would it take? (extrapolated from the measured data above)'; $calcHead.Location = New-Object System.Drawing.Point(14, 446); $calcHead.Size = New-Object System.Drawing.Size(734, 20); $calcHead.ForeColor = $cMuted; $g.Controls.Add($calcHead)
        function New-BenchCalcField([int]$lx, [string]$cap, [int]$capW, [int]$bx, [int]$bw) {
            $l = New-Object System.Windows.Forms.Label; $l.Text = $cap; $l.Location = New-Object System.Drawing.Point($lx, 474); $l.Size = New-Object System.Drawing.Size($capW, 18); $l.ForeColor = $cMuted; $g.Controls.Add($l)
            $b = New-Object System.Windows.Forms.TextBox; $b.Location = New-Object System.Drawing.Point($bx, 470); $b.Size = New-Object System.Drawing.Size($bw, 23); $g.Controls.Add($b); return $b
        }
        $cbW = New-BenchCalcField 14 'Width' 46 62 52
        $cbH = New-BenchCalcField 126 'Height' 48 176 52
        $cbS = New-BenchCalcField 242 'Steps' 42 286 46
        $cbN = New-BenchCalcField 346 'Images' 46 394 50
        $cbW.Text = [string]$wBox.Text; $cbH.Text = [string]$hBox.Text; $cbS.Text = [string]$steps.Text
        try { $cbN.Text = [string]([int]$count.Text) } catch { $cbN.Text = '16' }
        $cbMLbl = New-Object System.Windows.Forms.Label; $cbMLbl.Text = 'Mode'; $cbMLbl.Location = New-Object System.Drawing.Point(458, 474); $cbMLbl.Size = New-Object System.Drawing.Size(36, 18); $cbMLbl.ForeColor = $cMuted; $g.Controls.Add($cbMLbl)
        $cbM = New-Object System.Windows.Forms.ComboBox; $cbM.DropDownStyle = 'DropDownList'; [void]$cbM.Items.AddRange(@('Exact', '2x', '4x')); $cbM.SelectedIndex = 0; $cbM.Location = New-Object System.Drawing.Point(496, 470); $cbM.Size = New-Object System.Drawing.Size(86, 23); $g.Controls.Add($cbM); Set-MossComboTheme $cbM $g
        $calcBtn = Add-Button $g 'Estimate time...' 594 468 154 28
        $calcOut = New-Object System.Windows.Forms.Label; $calcOut.Location = New-Object System.Drawing.Point(14, 506); $calcOut.Size = New-Object System.Drawing.Size(734, 88); $calcOut.ForeColor = [System.Drawing.Color]::FromArgb(125, 205, 164); $g.Controls.Add($calcOut)
        $calcBtn.Add_Click({
            try {
                $wi = [int]$cbW.Text; $he = [int]$cbH.Text; $stn = [int]$cbS.Text; $n = [int]$cbN.Text
                $gpuName = ''; try { $g0 = @($script:Inventory | Where-Object { -not $_.IsVirtual } | Select-Object -First 1); if ($g0) { $gpuName = [string]$g0.Name } } catch {}
                $tdp = Get-MossGpuTdp $gpuName
                # Power / energy: rated GPU watts x render time. The rest of the
                # PC (CPU, board, fans, monitor) adds roughly 50-150 W on top.
                $gpuLine = $(if ($tdp) { ('GPU power: your {0} is rated {1} W - rendering for 1 hour uses about {2:N2} kWh, an 8-hour overnight run about {3:N2} kWh (GPU only; the rest of the PC adds roughly 50-150 W).' -f $gpuName, $tdp, ($tdp / 1000.0), (8 * $tdp / 1000.0)) } elseif ($gpuName) { ('GPU power: no rated wattage known for {0} - typical modern GPUs draw 150-350 W while rendering.' -f $gpuName) } else { 'GPU power: no GPU detected for a wattage estimate.' })
                if ($wi -lt 64 -or $he -lt 64) { $calcOut.Text = 'Sizes below 64 x 64 cannot be rendered.'; return }
                if ($n -lt 1) { $calcOut.Text = 'Image count must be 1 or more.'; return }
                $mode = [string]$cbM.SelectedItem
                $bm = Get-MossBenchmarkEstimate $wi $he $mode $stn $false
                if (-not $bm) { $calcOut.Text = 'No benchmark data yet to extrapolate from - generate a few images or run the quick benchmark first.' + [Environment]::NewLine + $gpuLine; return }
                $tot = [double]$bm.Sec * $n
                $energy = $(if ($tdp) { ('  ->  about {0:N2} kWh of GPU power for the job.' -f ($tot / 3600.0 * $tdp / 1000.0)) } else { '' })
                $calcOut.Text = ('{0} x {1} at {2} steps, {3} speed: ~{4} per image  ->  ~{5} for all {6} images (one engine run; the model loads once).{7}Extrapolated from the measured run: {8}.{9}{10}{11}' -f $wi, $he, $stn, $mode, (Format-MossFixedTime $bm.Sec), (Format-MossDuration $tot), $n, [Environment]::NewLine, $bm.Based, [Environment]::NewLine, $gpuLine, $energy)
            } catch { $calcOut.Text = 'Enter whole numbers in every field (e.g. 1360, 768, 25, 16).' }
        })
        $tip = New-Object System.Windows.Forms.ToolTip; $tip.InitialDelay = 300
        $tip.SetToolTip($runBtn, 'Renders 3 tiny test images to fill the table quickly. Full-size times still come from your real generations.')
        $tip.SetToolTip($clearBtn, 'Deletes benchmarks.json - all measured times are forgotten.')
        $tip.SetToolTip($calcBtn, 'Estimates the total render time AND GPU power for any size, steps, speed mode and image count, extrapolated from the measured data in the table (fresh renders, one engine run).')
        # --- POWER METER (v0.1.87) ------------------------------------------
        # Cumulative GPU energy: the SESSION since this app start (memory),
        # TODAY and ALL TIME (config\energy.json). Recorded draw is measured
        # via nvidia-smi when present, otherwise estimated from the rated
        # GPU power - each bucket says how much of it was measured.
        $powerHead = New-Object System.Windows.Forms.Label; $powerHead.Text = 'Power meter - GPU energy while rendering'; $powerHead.Location = New-Object System.Drawing.Point(14, 600); $powerHead.Size = New-Object System.Drawing.Size(734, 20); $powerHead.ForeColor = $cMuted; $g.Controls.Add($powerHead)
        $powerOut = New-Object System.Windows.Forms.Label; $powerOut.Location = New-Object System.Drawing.Point(14, 624); $powerOut.Size = New-Object System.Drawing.Size(734, 52); $powerOut.ForeColor = $cText; $g.Controls.Add($powerOut)
        $powerBtn = Add-Button $g 'Refresh power' 14 680 120 28
        $powerClear = Add-Button $g 'Reset all-time...' 142 680 130 28
        $updatePower = {
            $sum = Get-MossEnergySummary
            $fmt = { param($b) ('{0:N3} kWh over {1} across {2} run(s), {3} image(s)' -f ([double]$b.Wh / 1000.0), (Format-MossDuration ([double]$b.Seconds)), [int]$b.Runs, [int]$b.Images) }
            $sessLine = ('Session (since this app start):  {0}' -f (& $fmt $script:SessionEnergy))
            $dayLine = ('Today ({0}):  {1}' -f $sum.Date, (& $fmt $sum.Day))
            # All time with its start: the tracking start date, how long ago
            # that was, and the average watts over the whole history.
            $allLine = $(if ($sum.Started) {
                $age = $(if ([string]$sum.Started -eq [string]$sum.Date) { 'started today' } else {
                    $sd = [datetime]::ParseExact($sum.Started, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                    $dAgo = [int]([datetime]::Today - $sd.Date).TotalDays
                    if ($dAgo -le 1) { '1 day ago' } else { ('{0} days ago' -f $dAgo) }
                })
                $avgW = ''
                if ([double]$sum.AllTime.Seconds -gt 0) {
                    $avgW = (' - ~{0} W average' -f [int][Math]::Round(([double]$sum.AllTime.Wh * 3600.0) / [double]$sum.AllTime.Seconds, 0))
                }
                ('All time (since {0} - {1}):  {2}{3}' -f ([string]$sum.Started), ([string]$age), (& $fmt $sum.AllTime), ([string]$avgW))
            } else { ('All time:  {0}' -f (& $fmt $sum.AllTime)) })
            $methLine = $(if ($sum.AllTime.Wh -gt 0) { ('of which {0:N3} kWh measured directly (nvidia-smi); the rest is estimated from the GPU rating.' -f ([double]$sum.AllTime.MeasuredWh / 1000.0)) } else { 'No energy recorded yet - it fills in automatically as you render.' })
            $liveLine = ''
            $st = $script:GenState
            if ($st.IsRunning -and $null -ne $st.Process -and -not $st.Process.HasExited -and $null -ne $st.PowerLastW -and [double]$st.PowerLastW -gt 0) {
                $liveLine = ('Right now: ~{0} W {1}.' -f [int][Math]::Round([double]$st.PowerLastW, 0), $(if ([bool]$st.PowerLastMeasured) { '(measured)' } else { '(estimate)' }))
            }
            $powerOut.Text = (($sessLine, $dayLine, $allLine, $methLine, $liveLine) -join [Environment]::NewLine)
        }
        & $updatePower
        $powerBtn.Add_Click({ & $updatePower })
        $powerClear.Add_Click({
            $a = [System.Windows.Forms.MessageBox]::Show($g, 'Reset the recorded POWER usage (day and all-time totals in config\energy.json)? The benchmark time table is NOT touched.', 'Reset power totals', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $ledger = [pscustomobject]@{ Days = New-Object System.Collections.ArrayList; AllTime = (New-MossEnergyBucket) }
            Save-MossEnergy $ledger
            & $updatePower
        })
        $tip.SetToolTip($powerBtn, 'Reloads the session / today / all-time energy numbers.')
        $tip.SetToolTip($powerClear, 'Zeroes the cumulative power totals (day + all time). The per-run benchmark time data is not touched.')
        $g.AcceptButton = $closeBtn
        [void]$g.ShowDialog($f)
        $g.Dispose()
    }

    # (v0.1.98: Benchmarks and Error report live in the header Options menu.)
    # Compact flow layout (v0.1.98): the action row, the two-line status and
    # the progress bar sit directly below the generation controls. Since
    # Output folder / Model files / Error report / Benchmarks moved into the
    # header Options menu, the layout is STATIC: row at y=348, status at
    # 376, progress at 418.
    function Update-MossLeftActionLayout {
        $rowY = 348
        foreach ($c in @($generate,$cancel,$btnPause,$openOut)) {
            $c.Location = New-Object System.Drawing.Point($c.Left, $rowY)
        }
        $status.Location = New-Object System.Drawing.Point(18, ($rowY + 28))
        $prog.Location = New-Object System.Drawing.Point(18, ($rowY + 64))
    }
    # (First placement happens after the status line and progress bar are
    # created - see the call directly below $prog.)
    # Hover explanations for every control, so nothing is guesswork.
    $tip=New-Object System.Windows.Forms.ToolTip; $tip.InitialDelay=300; $tip.ReshowDelay=300
    $tip.SetToolTip($generate,'Renders your prompt. Quality follows the selector above: Exact (full quality) renders at full size and full steps; faster modes render small and enlarge - quick drafts, never distorted.')
    $tip.SetToolTip($cancel,'Stops the current generation and its engine processes.')
    $tip.SetToolTip($openOut,'Opens the output folder in Explorer.')
    $tip.SetToolTip($speedCombo,'How new images are rendered: Exact (full quality), or a faster draft mode that renders small and enlarges (70% or 50% of the size).')
    $tip.SetToolTip($negBtn,'Generation settings: negative prompt, sampler and scheduler.')
    $tip.SetToolTip($prompt,'Describe the image you want. Pasted multi-line text is flattened to one line automatically.')
    $tip.SetToolTip($historyPick,'Recent prompts (needs the history code to have been entered).')
    $tip.SetToolTip($resetHistoryCode,'Enter the history code to unlock the saved prompt history, set a new code (clears the history), or turn history off.')
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
    $tip.SetToolTip($out,'Where finished images are saved (Options > Output folder).')
    # Two-line status (v0.1.91, kept): progress %, step N/M, ETA, watts and
    # notes wrap over TWO lines. v0.1.96: the y position is set by
    # Update-MossLeftActionLayout (flows below the action row); the anchor
    # is now Top so the flow layout owns the position.
    $status=New-Object System.Windows.Forms.Label; $status.Text='Ready'; $status.Location=New-Object System.Drawing.Point(18,376); $status.Size=New-Object System.Drawing.Size(564,34); $status.Anchor='Top,Left,Right'; $status.ForeColor=$cMuted; $status.Font=New-Object System.Drawing.Font('Consolas',9); $left.Controls.Add($status)
    # Progress bar (v0.1.96): flows below the status line, full panel width.
    # (It used to be pinned to the very bottom edge with a Bottom anchor;
    # the flow layout replaces that.) All the numbers (% overall, step N/M,
    # ETA) live in the status line directly above; the old right-side
    # numeric readout was removed (it duplicated them).
    $prog=New-Object System.Windows.Forms.ProgressBar; $prog.Location=New-Object System.Drawing.Point(18,412); $prog.Size=New-Object System.Drawing.Size(564,14); $prog.Anchor='Top,Left,Right'; $prog.Style='Blocks'; $prog.Visible=$false; $left.Controls.Add($prog)
    Update-MossLeftActionLayout

    Add-Label $right 'Output preview' 16 14 200 | Out-Null
    $preview=New-Object System.Windows.Forms.PictureBox; $preview.Location=New-Object System.Drawing.Point(16,42); $preview.Size=New-Object System.Drawing.Size(383,285); $preview.Anchor='Top,Left,Right'; $preview.SizeMode='Zoom'; $preview.BackColor=[System.Drawing.Color]::FromArgb(13,17,24); $right.Controls.Add($preview)
    $filesTitle=Add-Label $right 'Generated files  (right-click: improve or delete)' 16 342 340
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

    $fileList=New-Object System.Windows.Forms.ListBox; $fileList.Location=New-Object System.Drawing.Point(16,368); $fileList.Size=New-Object System.Drawing.Size(383,150); $fileList.Anchor='Top,Left,Right'; $fileList.SelectionMode='MultiExtended'; $fileList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $fileList.ForeColor=$cText; $right.Controls.Add($fileList)
    $fileList.Add_SelectedIndexChanged({
        if($fileList.SelectedItem){
            $p=[string]$fileList.SelectedItem
            $script:SelectedFile=$p
            if(-not (Test-Path -LiteralPath $p)){
                # The file was deleted, renamed or moved OUTSIDE MOSS (by
                # hand, OneDrive, a backup tool...). Prune every dead entry
                # so the list matches the disk again - otherwise improve,
                # re-render and info would keep failing on dead paths.
                $fileList.ClearSelected()
                $removed=0
                for($i=$fileList.Items.Count-1;$i -ge 0;$i--){
                    $ip=[string]$fileList.Items[$i]
                    if(-not (Test-Path -LiteralPath $ip)){ $fileList.Items.RemoveAt($i); [void]$script:GeneratedFiles.Remove($ip); $removed++ }
                }
                $script:SelectedFile=$null
                # Same rule as a MOSS delete: the preview goes blank, no
                # other image is auto-shown. Click a file to view it again.
                try { $old=$preview.Image; $preview.Image=$null; if($old){ $old.Dispose() } } catch {}
                $fileList.ClearSelected()
                $status.Text=('Removed {0} list entr(ies): their file(s) no longer exist on disk (deleted, renamed or moved outside MOSS).' -f $removed)
                return
            }
            try{$newImg=Copy-MossImageUnlocked $p;if($newImg){$old=$preview.Image;$preview.Image=$newImg;if($old){$old.Dispose()}}}catch{}
        }
    })
    # A plain right-click does not change the ListBox selection - select the
    # file under the cursor first, so Improve always acts on that file. With
    # multi-select, right-clicking a file that is ALREADY part of the current
    # selection keeps the whole selection (so Delete can act on it).
    $fileList.Add_MouseClick({ param($sender,$e) if($e.Button -eq [System.Windows.Forms.MouseButtons]::Right){ $idx=$fileList.IndexFromPoint($e.Location); if($idx -ge 0 -and -not $fileList.SelectedIndices.Contains($idx)){ $fileList.SelectedIndex=$idx } } })
    # Right-click a generated file to re-render exactly that picture at full
    # quality: same seed and prompt (read from its sidecar), full steps,
    # image-to-image at the chosen size. Grain stays, distortion does not come back.
    $refineMenu=New-Object System.Windows.Forms.ContextMenuStrip
    # IMPROVE FIRST: it is the action users expect when they right-click an
    # image. The fresh re-render item previously sat first with a description
    # that sounded like 'make this image in full quality' - users picked it,
    # their main-window settings were intentionally ignored (it re-renders
    # with the image's OWN seed/size), and fast drafts came out as completely
    # different pictures (the user's 2026-11-20 report, byte-identical outputs
    # across 'different settings'). Now it is renamed, demoted and guarded.
    $miCustom=$refineMenu.Items.Add('Improve this image (same seed and composition)...')
    $miAll=$refineMenu.Items.Add('Improve ALL files that can be improved...')
    $miFresh=$refineMenu.Items.Add('Re-render with this image''s OWN seed and size (ignores the main window settings)...')
    $miInfo=$refineMenu.Items.Add('Show image info (prompt, seed, settings)...')
    $miDelete=$refineMenu.Items.Add('Delete selected file(s)...')
    $miDeleteAll=$refineMenu.Items.Add('Delete ALL files...')
    $fileList.ContextMenuStrip=$refineMenu
    $miFresh.Add_Click({ Start-MossRefineFresh })
    $miCustom.Add_Click({ Start-MossRefineWithCurrentSettings })
    $miAll.Add_Click({ Start-MossRefineAll })
    $miInfo.Add_Click({ Show-MossImageInfo })
    $miDelete.Add_Click({ Remove-MossSelectedFiles $false })
    $miDeleteAll.Add_Click({ Remove-MossSelectedFiles $true })
    $refineMenu.ShowItemToolTips=$true
    $miFresh.ToolTipText='Brand-new full-quality render using this image''s seed, prompt and settings - like a new generation with the same seed. Related look, but the composition can differ from the draft. Use Improve instead to keep the exact composition.'
    $miCustom.ToolTipText='Improve this image: same seed and composition, pick the target size (Same/2x/4x) and quality in the dialog. Fast previews get a higher strength automatically.'
    $miAll.ToolTipText='Queue every generated image that still has quality headroom (soft previews, fewer steps, smaller than the current size).'
    $miDelete.ToolTipText='Delete the selected image(s) and their sidecars from disk (asks first). Ctrl+click or Shift+click to select several.'
    $miDeleteAll.ToolTipText='Delete every image in the list and its sidecar from disk (asks first, shows the total size freed).'
    $miInfo.ToolTipText='Shows what is stored for this image: prompt, negative prompt, seed, size, steps, CFG, speed mode, sampler and scheduler. The prompt is decrypted only if the history code was entered. Copy the prompt with one click.'
    # Show ALL previously generated images at startup, not just this session's:
    # scan the output folder and list everything (oldest first, newest selected).
    try {
        $outFolder=Get-AbsoluteAppPath ([string]$script:Settings.OutputPath)
        if(Test-Path -LiteralPath $outFolder){
            # One-time sidecar migration: versions up to 0.1.76 wrote the
            # per-image .json sidecars NEXT to the images; since 0.1.77 they
            # live in the 'metadata' subfolder so the output folder only shows
            # pictures. Move every MOSS_* sidecar that is still sitting in the
            # output root (never overwrite - if the same name already exists
            # in metadata, that newer copy wins and the old one stays).
            try {
                $legacySides=@(Get-ChildItem -LiteralPath $outFolder -Filter 'MOSS_*.json' -File -ErrorAction SilentlyContinue)
                if($legacySides.Count -gt 0){
                    $metaDir=Join-Path $outFolder 'metadata'
                    if(-not (Test-Path -LiteralPath $metaDir -PathType Container)){ New-Item -ItemType Directory -Path $metaDir -Force | Out-Null }
                    foreach($js in $legacySides){
                        $target=Join-Path $metaDir $js.Name
                        if(-not (Test-Path -LiteralPath $target -PathType Leaf)){ Move-Item -LiteralPath $js.FullName -Destination $target -Force -ErrorAction SilentlyContinue }
                    }
                }
            } catch {}
            $existing=Get-ChildItem -LiteralPath $outFolder -Filter 'MOSS_*.png' -File | Sort-Object LastWriteTime
            foreach($fi in $existing){ [void]$fileList.Items.Add($fi.FullName); [void]$script:GeneratedFiles.Add($fi.FullName) }
            if($fileList.Items.Count -gt 0 -and -not $script:SelectedFile){ $fileList.SelectedIndex=$fileList.Items.Count-1 }
        }
    } catch {}
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
        # One layout for all window states. The old maximized special case
        # HID the Generated Files box, its title and the log when the window
        # was maximized - the user lost the file list exactly when more space
        # made it most useful (user report: 'when i maximize moss, the
        # generated files box disappears'). The normal formula scales with
        # the panel size, so it works for maximized too: the preview grows,
        # the file list and the log stay usable.
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
        $logTop = $logTitleTop + 27
        $preview.Location = New-Object System.Drawing.Point(16,42)
        $preview.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),$previewHeight)
        $filesTitle.Location = New-Object System.Drawing.Point(16,$filesTop)
        $fileList.Location = New-Object System.Drawing.Point(16,$listTop)
        $fileList.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),$fileHeight)
        # The toggle button IS the header in both states - clicking it
        # again collapses the log. (The old layout hid the toggle while
        # expanded and showed only the static title label, which had no
        # click handler - the log could not be minimized again.)
        $logToggle.Location = New-Object System.Drawing.Point(16,$logTitleTop)
        $logToggle.Visible = $true
        $log.Visible = $script:LogVisible
        if ($script:LogVisible) {
            $log.Location = New-Object System.Drawing.Point(16,$logTop)
            $log.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),[Math]::Max(70,$panelHeight - $logTop - 20))
        }
    }
    $script:LogVisible = $false
    Update-MossRightLayout
    try { $f.Refresh() } catch {}
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
        Capture = $null
        CaptureRunner = $null
        CaptureAsync = $null
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
        StepNum = 0
        StepDen = 0
        JobStartedAt = $null
        # Power meter state (v0.1.87): sampling cadence, integrated joules
        # for the CURRENT job, and the last reading for the display.
        PowerSmi = $null
        PowerEstimateW = 250.0
        PowerLastSample = $null
        PowerLastW = 250.0
        PowerLastMeasured = $false
        PowerJoules = 0.0
        PowerMeasuredJoules = 0.0
        PowerSeconds = 0.0
        # Pause/Resume (v0.1.91): the engine process is frozen mid-batch with
        # ntdll NtSuspendProcess. PausedAt anchors the paused span so elapsed
        # times, the ETA and the power meter exclude it on resume.
        Paused = $false
        PausedAt = $null
        PausedTotalSec = 0.0
    }
    # Session energy totals (v0.1.87): in-memory, reset at every app start.
    $script:SessionEnergy = New-MossEnergyBucket

    # Pause/Resume (v0.1.91): freeze the engine process mid-batch with ntdll's
    # NtSuspendProcess and continue later with NtResumeProcess. In-flight GPU
    # work finishes before the freeze takes effect; no new work starts until
    # the process is resumed. VRAM stays allocated while paused.
    if (-not ('Moss.ProcCtl' -as [type])) {
        try {
            Add-Type -Namespace Moss -Name ProcCtl -MemberDefinition '[DllImport("ntdll.dll")] public static extern uint NtSuspendProcess(IntPtr handle);[DllImport("ntdll.dll")] public static extern uint NtResumeProcess(IntPtr handle);' | Out-Null
        } catch {}
    }
    function Suspend-MossProcess {
        param($Process)
        if ($null -eq $Process) { return $false }
        try { if ($Process.HasExited) { return $false } } catch { return $false }
        if (-not ('Moss.ProcCtl' -as [type])) { return $false }
        try {
            $rc = [Moss.ProcCtl]::NtSuspendProcess($Process.Handle)
            return ($rc -eq 0)
        } catch { return $false }
    }
    function Resume-MossProcess {
        param($Process)
        if ($null -eq $Process) { return $false }
        try { if ($Process.HasExited) { return $false } } catch { return $false }
        if (-not ('Moss.ProcCtl' -as [type])) { return $false }
        try {
            $rc = [Moss.ProcCtl]::NtResumeProcess($Process.Handle)
            return ($rc -eq 0)
        } catch { return $false }
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
        if ($script:GenState.CaptureRunner) {
            # The capture thread ends on its own once the pipes close (engine
            # exit or kill); Stop() just cuts it loose if it is stuck.
            try { $script:GenState.CaptureRunner.Stop() } catch {}
            $script:GenState.CaptureRunner = $null
            $script:GenState.CaptureAsync = $null
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

    # Fixed-width time for the status line (h:mm:ss ALWAYS): the numbers stay
    # in place while they grow (user: the line changing length is hard to read).
    function Format-MossFixedTime([double]$Seconds) {
        if ($Seconds -lt 0) { $Seconds = 0 }
        $span = [TimeSpan]::FromSeconds([Math]::Min([int]::MaxValue, [Math]::Ceiling($Seconds)))
        return $span.ToString('h\:mm\:ss')
    }

    function Update-MossPowerSampling {
        # Samples the GPU power draw while the engine runs and integrates it
        # over time (joules) - the basis for the watt display and the
        # cumulative energy ledger (session / day / all time). MEASURED via
        # nvidia-smi when present; otherwise the TDP-based estimate. Called
        # every 400 ms tick; samples at most ~1x per second (nvidia-smi
        # costs tens of milliseconds per call, a 400 ms cadence would eat
        # real CPU). The interval BETWEEN samples is integrated with the
        # previous reading, so no wall time is lost between samples.
        $st = $script:GenState
        if ($null -eq $st.Process -or $st.Process.HasExited) { return }
        $now = Get-Date
        $dt = 0.0
        if ($null -ne $st.PowerLastSample) { $dt = ($now - $st.PowerLastSample).TotalSeconds }
        if ($dt -lt 0.8) { return }
        # Integration for the interval since the LAST sample uses that
        # sample's reading (constant-draw assumption between samples).
        if ($dt -gt 60.0) { $dt = 60.0 }   # stall / resume / hibernate protection
        $st.PowerSeconds = [double]$st.PowerSeconds + $dt
        $st.PowerJoules = [double]$st.PowerJoules + ([double]$st.PowerLastW * $dt)
        if ([bool]$st.PowerLastMeasured) { $st.PowerMeasuredJoules = [double]$st.PowerMeasuredJoules + ([double]$st.PowerLastW * $dt) }
        # New reading for the NEXT interval + the live display.
        $w = $null; $measured = $false
        if ($st.PowerSmi) {
            try {
                $outLines = & $st.PowerSmi '--query-gpu=power.draw' '--format=csv,noheader,nounits' 2>$null
                foreach ($ol in @($outLines)) { $w = Parse-MossPowerCsvLine ([string]$ol); if ($null -ne $w) { break } }
                if ($null -ne $w) { $measured = $true }
            } catch { $w = $null }
        }
        if ($null -eq $w) { $w = [double]$st.PowerEstimateW; $measured = $false }
        $st.PowerLastSample = $now
        $st.PowerLastW = $w
        $st.PowerLastMeasured = $measured
    }

    function Update-MossLiveProgress {
        $st = $script:GenState
        if (-not $st.IsRunning -or $null -eq $st.Process -or $st.Process.HasExited) { return }
        Update-MossPowerSampling
        if ($null -eq $st.Capture) { return }
        $elapsed = 0.0
        if ($st.JobStartedAt) { $elapsed = [Math]::Max(0, ((Get-Date) - $st.JobStartedAt).TotalSeconds) }
        $combined = ([string]$st.Capture.Out) + "`n" + ([string]$st.Capture.Err)
        # Detail-regeneration (hires) job? Checked once per tick - the phase
        # logic below applies only to these two-pass runs.
        $hiresActive = $false
        if ($st.Job -and $st.Job.PSObject.Properties['HiresScale'] -and [double]$st.Job.HiresScale -ge 1.5) { $hiresActive = $true }
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
        $st.StepNum = 0; $st.StepDen = 0
        # Only look at output of the image that is rendering right now: older
        # lines of a batch keep their final 'N/N' bar and would fake 100%.
        $progressWindow = $combined
        $lastImgIdx = $combined.LastIndexOf('generating image:')
        if ($lastImgIdx -ge 0) { $progressWindow = $combined.Substring($lastImgIdx) }
        # LIVE COMPLETION OVERLAP (user: the resizer waited for the whole
        # batch - resizing is CPU work, generation is GPU work, so they can
        # run at the same time): an image counts as fully written when the
        # engine logs 'generating image: k/N' for a LATER image, or when
        # 'save result image' follows the current image's own line. Each such
        # image is upscaled + registered NOW while the engine keeps rendering.
        $lastGen = 0
        foreach ($bm in $batchMatches) { if ([int]$bm.Groups[1].Value -gt $lastGen) { $lastGen = [int]$bm.Groups[1].Value } }
        $maxDone = if ($progressWindow -match 'save result image') { $lastGen } else { [Math]::Max(0, $lastGen - 1) }
        try {
        if ($maxDone -gt 0) {
            for ($ci = 1; $ci -le $maxDone; $ci++) {
                if ($st.LiveCompletedImages -contains $ci) { continue }
                $liveSeed = $null
                foreach ($bm in $batchMatches) { if ([int]$bm.Groups[1].Value -eq $ci) { $liveSeed = [long]$bm.Groups[3].Value; break } }
                if ($null -eq $liveSeed) { $liveSeed = $st.CurrentImageSeed }
                if (Complete-MossBatchImage -st $st -job $st.Job -i $ci -thisSeed $liveSeed -up $st.UpscaleTarget) { [void]$st.LiveCompletedImages.Add($ci) }
            }
        }
        } catch {}
        # A failure in the live path must never kill the progress tick - the
        # batch-end pass processes whatever is left anyway.
        # PRIMARY: the engine's sampling progress is a console bar, printed
        # carriage-return separated: '  |====>  | 1/4 - 1.37s/it'. It shows NO
        # percent sign and NO word 'steps' - the old regexes could never match
        # it, so the bar walked as marquee, % stayed 0 and ETA never computed.
        # Only bars ending in it/s or s/it are sampling steps - model-load and
        # VAE-decode bars use the same N/M shape but GB/s / MB/s units.
        $matches = [regex]::Matches($progressWindow, '(?im)\|\s*(\d{1,5})\s*/\s*(\d{1,5})\s*-\s*[^|\r\n]*?(it/s|s/it)')
        if ($matches.Count -gt 0) {
            $last = $matches[$matches.Count - 1]
            $numerator = [double]$last.Groups[1].Value; $denominator = [double]$last.Groups[2].Value
            if ($denominator -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int](($numerator * 100) / $denominator))) }
            # Keep the raw step counter for the status line ('step 17/50').
            $st.StepNum = [int]$numerator; $st.StepDen = [int]$denominator
            if ($hiresActive) {
                # The tiled VAE decode also prints an N/M it/s bar (tiles per
                # second) AFTER both sampling passes - positioned after the
                # 'decoding' lines. Never mistake it for a sampling pass.
                $barAfterDecode = $false
                $decIdx = $progressWindow.LastIndexOf('decoding')
                $saveIdx = $progressWindow.LastIndexOf('save result image')
                if (($decIdx -ge 0 -and $last.Index -gt $decIdx) -or ($saveIdx -ge 0 -and $last.Index -gt $saveIdx)) { $barAfterDecode = $true }
                if (-not $barAfterDecode) {
                    $wasPhase1 = ([int]$st['HiresPhase'] -eq 1)
                    Update-MossHiresPhases $st $numerator $denominator
                    if ($wasPhase1 -and [int]$st['HiresPhase'] -eq 2 -and -not $st['HiresLoggedPhase2']) {
                        $st['HiresLoggedPhase2'] = $true
                        $hOutW = [int]$st.Job.Width; $hOutH = [int]$st.Job.Height
                        if ($st.Job.PSObject.Properties['SrcW'] -and [int]$st.Job.SrcW -ge 64) {
                            $hOutW = [int][Math]::Round([int]$st.Job.SrcW * [double]$st.Job.HiresScale)
                            $hOutH = [int][Math]::Round([int]$st.Job.SrcH * [double]$st.Job.HiresScale)
                        }
                        $log.AppendText(("`r`nBase pass finished (composition kept) - the highres pass now re-synthesizes sharp detail at {0} x {1}. This second pass is the slower part of a detail-regeneration run." -f $hOutW, $hOutH))
                    }
                    # Overall progress counts BOTH passes: pass 1 steps + pass
                    # 2 steps over the observed totals - monotonic, never
                    # restarting at ~0% when the second bar begins.
                    $hiresDone = [int]$numerator
                    if ([int]$st['HiresPhase'] -eq 2) { $hiresDone = [int]$st['HiresPhase1Steps'] + [int]$numerator }
                    $hiresTotal = [int]$st['HiresPhase1Steps'] + [int]$st['HiresPhase2Den']
                    if ($hiresTotal -le 0) {
                        $p1Steps = $(if ([int]$st['HiresPhase1Steps'] -gt 0) { [int]$st['HiresPhase1Steps'] } elseif ($st.Job.PSObject.Properties['ChosenSteps']) { [int]$st.Job.ChosenSteps } else { [int]$st.Job.Steps })
                        $hiresTotal = $p1Steps + [int]$st.Job.Steps
                    }
                    $hiresTotal = [Math]::Max($hiresDone + 1, $hiresTotal)
                    $engineProgress = [Math]::Max(0, [Math]::Min(100, [int](($hiresDone * 100) / $hiresTotal)))
                }
            }
        }
        if ($null -eq $engineProgress) {
            # Textual step counters ('step 17/50', '17/50 steps') from other
            # engine builds that print them.
            $matches = [regex]::Matches($progressWindow, '(?im)(?:\bstep\s*[:#]?\s*(\d+)\s*/\s*(\d+)\b|\b(\d+)\s*/\s*(\d+)\s*steps?\b)')
            if ($matches.Count -gt 0) {
                $last = $matches[$matches.Count - 1]
                if ($last.Groups[1].Success) { $numerator = [double]$last.Groups[1].Value; $denominator = [double]$last.Groups[2].Value }
                else { $numerator = [double]$last.Groups[3].Value; $denominator = [double]$last.Groups[4].Value }
                if ($denominator -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int](($numerator * 100) / $denominator))) }
                $st.StepNum = [int]$numerator; $st.StepDen = [int]$denominator
            }
        }
        if ($null -eq $engineProgress) {
            # Percent readouts as the last resort.
            $matches = [regex]::Matches($progressWindow, '(?im)\b(\d{1,3})\s*%')
            if ($matches.Count -gt 0) { $engineProgress = [Math]::Max(0, [Math]::Min(100, [int]$matches[$matches.Count - 1].Groups[1].Value)) }
        }
        if ($null -ne $engineProgress) { $st.ImageProgress = [int]$engineProgress }
        $job = $st.Job
        $currentImage = [Math]::Max(1, [int]$st.CurrentImageIndex)
        $overall = [int][Math]::Floor(((($currentImage - 1) * 100) + [int]$st.ImageProgress) / [Math]::Max(1, [int]$job.Count))
        $overall = [Math]::Max(0, [Math]::Min(99, $overall))
        # ETA is ALWAYS for the WHOLE batch (user: 'if i select to make 64
        # images, the eta should be when all pictures is done'): the rest of
        # the current image + every remaining image. The per-image total is
        # estimated from the live step progress, and blended with the average
        # time of the images already finished once they exist - history is
        # the steadier signal, the live estimate catches drift.
        $etaText = 'ETA calculating'
        $remaining = $null
        $imageEstimate = $null
        if ($hiresActive) {
            # Two-pass run: the remaining time = the base pass's unfinished
            # part + the highres pass, weighted with the benchmark-store
            # parts. The naive elapsed/progress extrapolation explodes at
            # every pass change (the step bar restarts) and must not be used.
            $baseSec = 0.0; if ($null -ne $st['HiresBaseSec']) { $baseSec = [double]$st['HiresBaseSec'] }
            $secondSec = 0.0; if ($null -ne $st['HiresSecondSec']) { $secondSec = [double]$st['HiresSecondSec'] }
            $predTotal = 0.0; if ($null -ne $st['PredictedPerImage']) { $predTotal = [double]$st['PredictedPerImage'] }
            if ($baseSec -le 0 -and $secondSec -gt 0) { $baseSec = [Math]::Max(0.0, $predTotal - $secondSec) }
            if ($secondSec -le 0 -and $baseSec -gt 0) { $secondSec = [Math]::Max(0.0, $predTotal - $baseSec) }
            if ($baseSec -le 0 -and $secondSec -le 0 -and $predTotal -gt 0) {
                # No benchmark parts at all: split the upfront prediction by
                # predicted steps (pass 1 samples ChosenSteps, pass 2 the full
                # engine count).
                $p1Steps = [double]$(if ([int]$st['HiresPhase1Steps'] -gt 0) { [int]$st['HiresPhase1Steps'] } elseif ($st.Job.PSObject.Properties['ChosenSteps']) { [int]$st.Job.ChosenSteps } else { [int]$st.Job.Steps })
                $baseSec = $predTotal * ($p1Steps / [Math]::Max(1.0, ($p1Steps + [double]$st.Job.Steps)))
                $secondSec = [Math]::Max(0.0, $predTotal - $baseSec)
            }
            if ($baseSec -gt 0 -or $secondSec -gt 0) {
                if ([int]$st['HiresPhase'] -eq 2) {
                    $p2Den = [double][Math]::Max(1, $(if ([int]$st['HiresPhase2Den'] -gt 0) { [int]$st['HiresPhase2Den'] } else { [int]$st.Job.Steps }))
                    $remaining = [Math]::Max(0.0, $secondSec * (1.0 - ([Math]::Min([double]$st.StepNum, $p2Den) / $p2Den)))
                } else {
                    $p1Den = [double][Math]::Max(1, $(if ([int]$st['HiresPhase1Steps'] -gt 0) { [int]$st['HiresPhase1Steps'] } elseif ($st.Job.PSObject.Properties['ChosenSteps']) { [int]$st.Job.ChosenSteps } else { [int]$st.Job.Steps }))
                    $remaining = [Math]::Max(0.0, $baseSec * (1.0 - ([Math]::Min([double]$st.StepNum, $p1Den) / $p1Den))) + $secondSec
                }
            }
        } else {
            $avgDone = $null
            if ($st.ImageDurations.Count -gt 0) { $avgDone = (($st.ImageDurations | Measure-Object -Average).Average) }
            if ($null -ne $engineProgress -and $engineProgress -gt 0) {
                $imageEstimate = $imageElapsed * 100.0 / $engineProgress
                if ($null -ne $avgDone) { $imageEstimate = ($imageEstimate + $avgDone) / 2.0 }
            } elseif ($null -ne $avgDone) {
                $imageEstimate = $avgDone
            } elseif ($null -ne $st['PredictedPerImage']) {
                # Benchmark-store prediction: no live data yet (batch just started).
                $imageEstimate = [double]$st['PredictedPerImage']
            }
            if ($null -ne $imageEstimate) {
                $remaining = [Math]::Max(0, $imageEstimate - $imageElapsed) + ([Math]::Max(0, $job.Count - $currentImage) * $imageEstimate)
            }
        }
        if ($null -ne $remaining) { $etaText = if ([int]$job.Count -gt 1) { "ETA ~$(Format-MossFixedTime $remaining) (all $($job.Count))" } else { "ETA ~$(Format-MossFixedTime $remaining)" } }
        # Refresh the ETA at most once per second (user: the constant jumping
        # on every 400 ms tick is distracting). The rest of the line keeps
        # updating on every tick; the held value keeps its fixed width.
        if ($etaText -ne 'ETA calculating') {
            $nowEta = Get-Date
            if ($null -eq $st.EtaShown -or $null -eq $st.EtaUpdatedAt -or (($nowEta - $st.EtaUpdatedAt).TotalSeconds -ge 1.0)) {
                $st.EtaShown = $etaText
                $st.EtaUpdatedAt = $nowEta
            }
            $etaText = $st.EtaShown
        }
        # After the last sampling step the engine still has to decode the
        # latent into pixels and save the file (several seconds at bigger
        # sizes, with no progress output of its own). Say so instead of
        # showing a frozen 99% - the user read that as a hang.
        $decIdx = $progressWindow.LastIndexOf('decoding')
        $decDoneIdx = $progressWindow.LastIndexOf('decoded')
        $saveIdx = $progressWindow.LastIndexOf('save result image')
        $decIdx = $progressWindow.LastIndexOf('decoding')
        $decDoneIdx = $progressWindow.LastIndexOf('decoded')
        $saveIdx = $progressWindow.LastIndexOf('save result image')
        $decodingNow = $false
        $savingNow = $false
        if ($saveIdx -ge 0) { $savingNow = $true }
        elseif ($decIdx -ge 0 -and ($decDoneIdx -lt 0 -or $decIdx -gt $decDoneIdx)) { $decodingNow = $true }
        elseif ($decDoneIdx -ge 0) { $savingNow = $true }
        # Fixed-width status line (user: keep the line length constant so
        # the numbers stay in place and it is easier to read): every number
        # is padded to a fixed width, the time is always h:mm:ss, the phase
        # text is padded to a fixed width and the font is monospace.
        $phase = if ($decodingNow) { 'decoding/saving...' }
                 elseif ($savingNow) { 'saving...' }
                 elseif ($hiresActive -and $st.StepDen -gt 0) { ('pass {0}/2 step {1,3}/{2,3}' -f [int]$st['HiresPhase'], [int]$st.StepNum, [int]$st.StepDen) }
                 elseif ($st.StepDen -gt 0) { ('step {0,3}/{1,3}' -f [int]$st.StepNum, [int]$st.StepDen) }
                 elseif ($null -ne $engineProgress) { ('image {0,3}%' -f [int]$st.ImageProgress) }
                 else { 'warming up...' }
        # Live power draw: measured (nvidia-smi) or estimated (TDP) - shown
        # in the fixed-width status line while the engine runs.
        $powerText = ''
        if ($null -ne $st.PowerLastW -and [double]$st.PowerLastW -gt 0) {
            $powerText = ('| ~{0,3} W {1} ' -f [int][Math]::Round([double]$st.PowerLastW, 0), $(if ([bool]$st.PowerLastMeasured) { '(measured)' } else { '(estimate)' }))
        }
        $status.Text = ('Image {0,3}/{1,3} | {2,3}% | {3} | elapsed {4} | {5}{6}' -f $currentImage, [int]$job.Count, $overall, $phase.PadRight(17), (Format-MossFixedTime $elapsed), $etaText, $powerText)
        # Drive the progress bar from the step counter (same numbers as the
        # status text above; the old right-side numeric readout duplicated it
        # and is gone).
        $prog.Visible = $true
        if ($null -ne $engineProgress) {
            if ($prog.Style -ne 'Blocks') { $prog.Style = 'Blocks' }
            $prog.Value = [Math]::Max($prog.Minimum,[Math]::Min($prog.Maximum,$overall))
        }
    }


    function Complete-MossGen {
        param([string]$FinalStatus)
        Stop-MossGen
        $generate.Enabled = $true
        $cancel.Enabled = $false
        $btnPause.Enabled = $false; $btnPause.Text = 'Pause'
        $script:GenState.Paused = $false; $script:GenState.PausedAt = $null
        if ($FinalStatus) { $status.Text = $FinalStatus }
        if ($script:GenState.JobStartedAt) { $status.Text += " | total elapsed $(Format-MossDuration ((Get-Date) - $script:GenState.JobStartedAt).TotalSeconds)" }
        # Progress bar: full on success, hidden on failures (a full bar next
        # to a failure message would be misleading).
        if ($FinalStatus -like 'Completed*') {
            $prog.Style = 'Blocks'
            $prog.Value = $prog.Maximum
            $prog.Visible = $true
        } else {
            $prog.Visible = $false
        }
    }

    function Start-MossBatchEngine {
        # One engine process renders the whole batch: the model is loaded once and
        # the prompt conditioning is reused (--batch-count + --conditioning-cache-size).
        # Weight placement (GPU, RAM, disk) is decided by the engine's built-in
        # auto-fit, which works the same way for CUDA, Vulkan, SYCL and CPU builds.
        $st = $script:GenState
        $job = $st.Job

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        # Refined (image-to-image) outputs carry an easy-to-spot tag in the
        # name: ..._hq_01.png - every improve mode uses it; the sidecar
        # records the actual output size and which mode made it.
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
        # DETAIL REGENERATION (highres fix) for improve jobs: the job carries
        # HiresScale (from the improve dialog). The base img2img pass runs at
        # the image's OWN size (composition, all chosen steps), then the
        # engine's highres fix upscales the latent and re-synthesizes sharp
        # detail at HiresScale x - verified: 1360 x 768 draft -> sharp
        # 2720 x 1536, composition kept. VAE tiling is always on for the
        # enlarged second pass (the base 4.18 MP render needed it on 12 GB).
        $jobProps = $job.PSObject.Properties
        $hiresScale = 0.0
        if ($jobProps['HiresScale']) { $hiresScale = [double]$job.HiresScale }
        $hiresActive = $false
        $renderW = [int]$job.Width; $renderH = [int]$job.Height
        if ($hiresScale -ge 1.5) {
            $srcW = 0; $srcH = 0
            if ($jobProps['SrcW']) { $srcW = [int]$job.SrcW }
            if ($jobProps['SrcH']) { $srcH = [int]$job.SrcH }
            if ($srcW -ge 64 -and $srcH -ge 64) {
                $argsList.Add('-H'); $argsList.Add([string]$srcH)
                $argsList.Add('-W'); $argsList.Add([string]$srcW)
                $argsList.Add('--hires'); $argsList.Add('--hires-scale'); $argsList.Add(([string]$hiresScale).Replace(',', '.'))
                $renderW = $srcW; $renderH = $srcH
                $hiresActive = $true
            }
        }
        if (-not $hiresActive) {
            $argsList.Add('-H'); $argsList.Add([string]$job.Height)
            $argsList.Add('-W'); $argsList.Add([string]$job.Width)
        }
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
        # VAE tiling for large renders: at big sizes the VAE encode/decode needs
# more GPU memory than the card has (live case: 18 GB requested for the
# VAE graph at 2720 x 1536 on a 12 GB card - the whole run died there,
# before a single sampling step). --vae-tiling processes encode and
# decode in spatial tiles with overlap, which cuts the VAE peak memory
# drastically with no visible effect on the image. Applied whenever the
# RENDER size exceeds about 3 megapixels (sizes up to ~2 MP are verified
# to work un-tiled); it only changes HOW the VAE runs, not the result.
$speedScale = 0.0
if (-not $hiresActive) { $renderW = [int]$job.Width; $renderH = [int]$job.Height }
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
                $renderW = $smallW; $renderH = $smallH
                $st.UpscaleTarget = @{ W = [int]$job.Width; H = [int]$job.Height; FromW = $smallW; FromH = $smallH }
            }
        }
        if (([double]$renderW * [double]$renderH) / 1000000.0 -gt 3.0) {
            $argsList.Add('--vae-tiling')
            $log.AppendText(("`r`nNote: {0} x {1} render - VAE tiling is on, so the encode/decode runs in memory-safe tiles instead of asking the GPU for one huge buffer." -f $renderW, $renderH))
        }
        if ($hiresActive) {
            # The highres second pass runs at HiresScale x the base size -
            # that enlarged render needs VAE tiling regardless of the base
            # size (verified: 1360x768 base -> 2720x1536 second pass).
            $argsList.Add('--vae-tiling')
            $log.AppendText(("`r`nNote: detail regeneration is ON - the composition pass renders at {0} x {1}, then the highres second pass re-synthesizes sharp detail at {2} x {3} (scale {4}x). This takes about 3-4x the normal improve time." -f $renderW, $renderH, [int]($renderW*$hiresScale), [int]($renderH*$hiresScale), $hiresScale))
        }
        # FAST SHARPEN: after the render, the ESRGAN upscaler model THE USER
        # PICKED sharpens/enlarges the finished image in pixel space - a
        # single sampling pass (at HALF the source size) plus seconds of
        # upscaling, instead of the hires second pass. The model choice is
        # never overridden; the output size follows the model (the default
        # x4 model sharpens the half-size render back to 2x the source).
        $upscaleModel = ''
        if ($jobProps['UpscaleModel']) { $upscaleModel = [string]$job.UpscaleModel }
        if ($upscaleModel -and -not (Test-Path -LiteralPath $upscaleModel -PathType Leaf)) {
            # Last-resort safety: render without the upscaler rather than
            # failing the whole run (the queue already falls back to detail
            # regeneration when it can).
            $log.AppendText(("`r`nNote: the selected upscaler model file was not found ({0}) - rendering WITHOUT it (the copy keeps its native render size)." -f $upscaleModel))
            $upscaleModel = ''
        }
        if ($upscaleModel) {
            $argsList.Add('--upscale-model'); $argsList.Add((Quote-ProcessArgument $upscaleModel))
            $log.AppendText(("`r`nNote: fast sharpen is ON - the render runs at {0} x {1}, then the upscaler model {2} sharpens/enlarges the result in pixel space (output size follows the model; no second sampling pass)." -f $renderW, $renderH, (Split-Path -Leaf $upscaleModel)))
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
        # so the engine keeps its model-specific choice. Choke-point guard (v0.2.0):
        # OLD sidecars can still carry the DISPLAY label 'Default (model)' — it
        # must never reach the engine as --sampling-method 'Default (model)'
        # (overnight error: unknown argument: (model)).
        $argSampler=[string]$job.SamplingMethod; if($argSampler -match '^Default \('){ $argSampler=$null }
        $argSched=[string]$job.Scheduler; if($argSched -match '^Default \('){ $argSched=$null }
        if ($argSampler) { $argsList.Add('--sampling-method'); $argsList.Add((Quote-ProcessArgument $argSampler)) }
        if ($argSched) { $argsList.Add('--scheduler'); $argsList.Add((Quote-ProcessArgument $argSched)) }
        # Negative prompt (engine flag -n), flattened to a single line like
        # the positive prompt.
        $effectiveNegative = [string]$job.NegativePrompt
        if ([bool]$script:Settings.SafeMode) {
            # Safe mode: also steer the SAMPLING away from sexual content with
            # concept words, in case a clean prompt still drifts that way.
            # Concept words only - a negative prompt cannot censor or follow
            # instructions (the real block is the prompt gate above).
            if ($effectiveNegative -notmatch '(?i)\b(nsfw|nude|naked)\b') {
                $effectiveNegative = ($effectiveNegative.Trim(', ') + ', nsfw, nude, naked, explicit, gore').Trim(', ')
                $log.AppendText("`r`nSafe mode: safety terms (nsfw, nude, naked, explicit, gore) added to the negative prompt.")
            }
        }
        if ($effectiveNegative) { $argsList.Add('-n'); $argsList.Add((Quote-ProcessArgument $effectiveNegative)) }

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
        # Every vendor gets its own selection mechanism: CUDA_VISIBLE_DEVICES
        # (NVIDIA), HIP_VISIBLE_DEVICES (AMD ROCm), GGML_VK_VISIBLE_DEVICES
        # (Vulkan, any GPU) and ONEAPI_DEVICE_SELECTOR (Intel SYCL builds,
        # which take a 'backend:index' value rather than a bare index - it
        # was silently ignored before, so the selected card never applied).
        if ($job.GpuIndex -ge 0) {
            $deviceEnv = switch -Regex ([string]$job.Backend) { '^CUDA' { 'CUDA_VISIBLE_DEVICES'; break } '^HIP' { 'HIP_VISIBLE_DEVICES'; break } 'Vulkan' { 'GGML_VK_VISIBLE_DEVICES'; break } '^SYCL' { 'ONEAPI_DEVICE_SELECTOR'; break } default { $null } }
            if ($deviceEnv) {
                $deviceValue = [string]$job.GpuIndex
                if ($deviceEnv -eq 'ONEAPI_DEVICE_SELECTOR') { $deviceValue = 'level_zero:' + $deviceValue }
                $psi.EnvironmentVariables[$deviceEnv] = $deviceValue
            }
        }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.EnableRaisingEvents = $false

        # Engine output capture on a BACKGROUND RUNSPACE THREAD: PowerShell's
        # Register-ObjectEvent actions NEVER fire while the WinForms message
        # loop is running (the PS event queue is not pumped), so the old
        # event-based capture delivered NOTHING - live progress, %, ETA and
        # even the finished-run log all saw empty output for the whole life of
        # this feature. A dedicated thread blocks in ReadLine() and appends
        # every line to a synchronized hashtable that the timer tick reads.
        $st.Capture = [hashtable]::Synchronized(@{ Out = ''; Err = '' })
        $captureScript = {
            param($p, $c)
            try {
                while ($true) {
                    $line = $p.StandardOutput.ReadLine()
                    if ($null -eq $line) { break }
                    $c.Out = $c.Out + $line + "`n"
                }
            } catch {}
            try {
                while ($true) {
                    $line = $p.StandardError.ReadLine()
                    if ($null -eq $line) { break }
                    $c.Err = $c.Err + $line + "`n"
                }
            } catch {}
        }
        $st.CaptureRunner = $null
        $st.CaptureAsync = $null

        try {
            [void]$proc.Start()
            # POWER SAVER (v0.2.5): when the user needs the PC for something
            # else, the engine process runs at a lower priority so Windows
            # gives the CPU first (and the GPU scheduler follows process
            # priority on WDDM) to whatever the user is actually using.
            # The job still finishes - just slower. 'Off' changes nothing.
            $psMode = if ($script:Settings.Contains('PowerSaver')) { [string]$script:Settings.PowerSaver } else { 'Off' }
            switch ($psMode) {
                'Gentle' {
                    try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal; $log.AppendText("`r`nPower saver (Gentle): the engine runs at below-normal priority - other programs get the CPU and GPU first. Generation is slower but still finishes.") } catch {}
                }
                'Max saving' {
                    try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle; $log.AppendText("`r`nPower saver (Max saving): the engine runs at lowest priority - the PC stays fully responsive for everything else. Generation can take much longer.") } catch {}
                }
                default { }
            }
            # Start the capture thread AFTER the process exists (ReadLine
            # needs live stream readers); output already buffered by the pipe
            # is picked up by the thread, nothing is lost.
            $st.CaptureRunner = [powershell]::Create()
            [void]$st.CaptureRunner.AddScript($captureScript).AddArgument($proc).AddArgument($st.Capture)
            $st.CaptureAsync = $st.CaptureRunner.BeginInvoke()
            $st.Process = $proc
            $script:ActiveProcess = $proc
            $st.ImageStartedAt = Get-Date
            $st.ImageProgress = 0
            $st.StepNum = 0; $st.StepDen = 0
            $st.CurrentImageIndex = 0
            $st.Paused = $false; $st.PausedAt = $null
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

    function Complete-MossBatchImage {
        # Processes ONE finished batch image: upscale (speed modes), sidecar,
        # results and the generated-files list. Used BOTH live (while the
        # engine renders the next images - the resize is CPU work and
        # generation is GPU work, so they overlap; user request) and at batch
        # end for whatever is left. Returns $true when the file was there.
        param($st,$job,$i,$thisSeed,$up)
        $patternBase = ([string]$st.CurrentFile) -replace '%02d','{0:D2}'
        $file = $patternBase -f $i
        if (-not (Test-Path -LiteralPath $file)) { return $false }
        if (-not (Test-MossPngValid $file)) {
            # File exists but is not a decodable PNG (truncated write: disk
            # full, power loss, antivirus interference). Never list it.
            [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = 0; Seed = $thisSeed; Output = 'Image file is corrupt or incomplete (write interrupted?) - not added to the list; the file stays on disk' })
            return $false
        }
        $upscaledNote = $null
        if ($up) {
            try {
                Resize-MossImageTo $file ([int]$up.W) ([int]$up.H)
                $upscaledNote = ('upscaled from {0} x {1}' -f $up.FromW, $up.FromH)
            } catch {
                $upscaledNote = ('kept at engine size {0} x {1} (resize failed: {2})' -f $up.FromW, $up.FromH, $_.Exception.Message)
            }
        } elseif ($job.PSObject.Properties['UpscaleModel'] -and [string]$job.UpscaleModel) {
            # Fast-sharpen run: the engine upscaled the result with the
            # user-selected ESRGAN model - record it (the sidecar is the
            # only record of how the image was made).
            $upscaledNote = ('fast sharpen ({0})' -f (Split-Path -Leaf ([string]$job.UpscaleModel)))
        }
        try {
            # The sidecar must record the ACTUAL saved size: for a speed-mode
            # run the pixel upscaler resizes the file first, and a detail-
            # regeneration (hires) run saves at 2x the base size - the job's
            # own W/H would then be wrong (live case: the sidecar said
            # 1360 x 768 for a 2720 x 1536 hires output, which would mislead
            # a later improve/info of that image).
            $realW = [int]$job.Width; $realH = [int]$job.Height
            try {
                $imgDim = [System.Drawing.Image]::FromFile($file)
                $realW = $imgDim.Width; $realH = $imgDim.Height
                $imgDim.Dispose()
            } catch {}
            $meta = [ordered]@{
                Width = $realW; Height = $realH
                Steps = $job.Steps; CfgScale = $job.Cfg; Seed = $thisSeed
                Backend = $job.Backend
                SpeedMode = [string]$job.SpeedMode
                UpscaledFrom = $upscaledNote
                HiresScale = $(if ($job.PSObject.Properties['HiresScale'] -and [double]$job.HiresScale -ge 1.5) { [double]$job.HiresScale } else { $null })
                InitImage = $(if($job.InitImage){ [System.IO.Path]::GetFileName([string]$job.InitImage) }else{ $null })
                InitStrength = $(if($job.InitImage){ [double]$job.InitStrength }else{ $null })
                Sampler = $(if($job.SamplingMethod){ [string]$job.SamplingMethod }else{ $null })
                Scheduler = $(if($job.Scheduler){ [string]$job.Scheduler }else{ $null })
                GeneratedAt = (Get-Date).ToString('o'); Engine = $job.Engine
            }
            if ($script:HistoryPassphrase) {
                $meta.PromptProtected = Protect-MossPayload ([string]$job.Prompt) $script:HistoryPassphrase
                if ($job.NegativePrompt) { $meta.NegativePromptProtected = Protect-MossPayload ([string]$job.NegativePrompt) $script:HistoryPassphrase }
            } else {
                $meta.Prompt = [string]$job.Prompt
                if ($job.NegativePrompt) { $meta.NegativePrompt = [string]$job.NegativePrompt }
            }
            # Sidecar goes into the 'metadata' subfolder (see Get-MossSidecarPath)
            $sidePath = Get-MossSidecarPath $file
            $sideDir = [System.IO.Path]::GetDirectoryName($sidePath)
            if (-not (Test-Path -LiteralPath $sideDir)) { New-Item -ItemType Directory -Path $sideDir -Force | Out-Null }
            $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sidePath -Encoding UTF8
        } catch {}
        [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = 0; Seed = $thisSeed; Output = 'OK' })
        [void]$fileList.Items.Add($file)
        [void]$script:GeneratedFiles.Add($file)
        $fileList.SelectedIndex = $fileList.Items.Count - 1
        return $true
    }

    function On-MossGenTimerTick {
        $st = $script:GenState
        if ($null -eq $st.Process) { return }
        # Paused: the engine process is frozen, so no new output appears and
        # progress/ETA/power updates would only lie - skip them entirely. If
        # the process died while paused, fall through to normal handling.
        if ($st.Paused) {
            if (-not $st.Process.HasExited) { return }
            $st.Paused = $false; $st.PausedAt = $null
        }
        if (-not $st.Process.HasExited) { Update-MossLiveProgress; return }

        # The whole batch has finished (one process rendered every image).
        $exitCode = $st.Process.ExitCode
        $st.LastExitCode = $exitCode
        $job = $st.Job
        if ($st.ImageStartedAt -and [int]$st.CurrentImageIndex -gt 0) { [void]$st.ImageDurations.Add([Math]::Max(0.1, ((Get-Date) - $st.ImageStartedAt).TotalSeconds)) }

        # Let the capture thread finish draining (pipes close at exit, so
        # ReadLine returns $null immediately) before reading the final output.
        try { if ($st.CaptureAsync -and -not $st.CaptureAsync.IsCompleted) { [void]$st.CaptureRunner.EndInvoke($st.CaptureAsync) } } catch {}
        $stdout = [string]$st.Capture.Out
        $stderr = [string]$st.Capture.Err
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
        if ($st.CaptureRunner) {
            try { $st.CaptureRunner.Stop() } catch {}
            $st.CaptureRunner = $null
            $st.CaptureAsync = $null
        }
        $st.Capture = $null

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
        $corrupt = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -le $job.Count; $i++) {
            # Already upscaled + registered live while the engine was still
            # rendering the rest (CPU/GPU overlap) - just count it.
            if ($st.LiveCompletedImages -contains $i) { $ok++; continue }
            $file = $patternBase -f $i
            $thisSeed = if ($seedMap.ContainsKey($i)) { $seedMap[$i] } else { $job.Seed + ($i - 1) }
            if ($exitCode -eq 0 -and (Test-Path -LiteralPath $file) -and (Test-MossPngValid $file)) {
                $ok++
                $upscaledNote = $null
                if ($up) {
                    try {
                        Resize-MossImageTo $file ([int]$up.W) ([int]$up.H)
                        $upscaledNote = ('upscaled from {0} x {1}' -f $up.FromW, $up.FromH)
                    } catch {
                        $upscaledNote = ('kept at engine size {0} x {1} (resize failed: {2})' -f $up.FromW, $up.FromH, $_.Exception.Message)
                    }
                } elseif ($job.PSObject.Properties['UpscaleModel'] -and [string]$job.UpscaleModel) {
                    # Fast-sharpen run (same record as the live path): the
                    # engine upscaled the result with the user-selected ESRGAN
                    # model. Improves are single-image jobs and end up HERE
                    # (the engine has usually already exited when the image is
                    # processed), so this is the branch that normally runs.
                    $upscaledNote = ('fast sharpen ({0})' -f (Split-Path -Leaf ([string]$job.UpscaleModel)))
                }
                # The sidecar must record the ACTUAL saved size (same rule as
                # the live path): a fast-sharpen output is the engine's ESRGAN
                # result (~2x the job's own W/H) and a hires run saves at 2x
                # the base size. Regression note: this readback existed in
                # v0.1.84 but was lost from THIS path in a later edit round -
                # every single-image improve then recorded its render size
                # (real case: a sidecar said 1280 x 720 for a 5120 x 2880 file).
                $realW = [int]$job.Width; $realH = [int]$job.Height
                try {
                    $imgDim = [System.Drawing.Image]::FromFile($file)
                    $realW = $imgDim.Width; $realH = $imgDim.Height
                    $imgDim.Dispose()
                } catch {}
                try {
                    $meta = [ordered]@{
                        Width = $realW; Height = $realH
                        Steps = $job.Steps; CfgScale = $job.Cfg; Seed = $thisSeed
                        Backend = $job.Backend
                        SpeedMode = [string]$job.SpeedMode
                        UpscaledFrom = $upscaledNote
                        HiresScale = $(if ($job.PSObject.Properties['HiresScale'] -and [double]$job.HiresScale -ge 1.5) { [double]$job.HiresScale } else { $null })
                        InitImage = $(if($job.InitImage){ [System.IO.Path]::GetFileName([string]$job.InitImage) }else{ $null })
                        InitStrength = $(if($job.InitImage){ [double]$job.InitStrength }else{ $null })
                        Sampler = $(if($job.SamplingMethod){ [string]$job.SamplingMethod }else{ $null })
                        Scheduler = $(if($job.Scheduler){ [string]$job.Scheduler }else{ $null })
                        GeneratedAt = (Get-Date).ToString('o'); Engine = $job.Engine
                    }
                    if ($script:HistoryPassphrase) {
                        # A code is set and entered: prompts stay encrypted in the
                        # sidecar (the guard refuses improves when not unlocked).
                        $meta.PromptProtected = Protect-MossPayload ([string]$job.Prompt) $script:HistoryPassphrase
                        if ($job.NegativePrompt) { $meta.NegativePromptProtected = Protect-MossPayload ([string]$job.NegativePrompt) $script:HistoryPassphrase }
                    } else {
                        # No code entered - either none in use, or the user
                        # chose to continue WITHOUT the password at startup:
                        # store prompts PLAIN so improving always works. The
                        # user asked for exactly this: saving the prompt anyway,
                        # unencrypted, when continuing without the password.
                        # (The encrypted history envelope in settings.json is
                        # untouched - only the sidecar next to the image.)
                        $meta.Prompt = [string]$job.Prompt
                        if ($job.NegativePrompt) { $meta.NegativePrompt = [string]$job.NegativePrompt }
                    }
                    # Sidecar goes into the 'metadata' subfolder (see Get-MossSidecarPath)
                    $sidePath = Get-MossSidecarPath $file
                    $sideDir = [System.IO.Path]::GetDirectoryName($sidePath)
                    if (-not (Test-Path -LiteralPath $sideDir)) { New-Item -ItemType Directory -Path $sideDir -Force | Out-Null }
                    $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sidePath -Encoding UTF8
                } catch {}
                [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = 'OK' })
                [void]$fileList.Items.Add($file)
                [void]$script:GeneratedFiles.Add($file)
                $fileList.SelectedIndex = $fileList.Items.Count - 1
            } elseif (Test-Path -LiteralPath $file) {
                $corrupt.Add($file)
                [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = 'Image file is corrupt or incomplete (write interrupted?) - not added to the list; the file stays on disk' })
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
        } elseif ($corrupt.Count -gt 0) {
            $outputText = ("ERROR: {0} expected image file(s) exist but are CORRUPT or incomplete (the write was interrupted - often a full disk, power loss or antivirus interference). They are NOT in the list; the broken files stay on disk so you can look at them:`r`n" -f $corrupt.Count) + (($corrupt | ForEach-Object { '  ' + $_ }) -join "`r`n") + "`r`n" + $outputText
            [void](Write-MossErrorLog ("MOSS generation error - {0} of {1} image(s) corrupt/incomplete" -f $corrupt.Count, $job.Count) $outputText)
            $finalMsg = "Partially completed - $ok of $($job.Count) image(s) generated; $($corrupt.Count) corrupt file(s) not listed"
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
            # Output is now REALLY captured (background-thread reader). A
            # memory crash is not silent any more - it leaves the whole load
            # log behind. 'Silent death' now means: no [E] error line anywhere
            # in the output (the engine prints [E] for every diagnosed
            # failure), or the last [E] line itself points at memory.
            $engineErrorText = ''
            $errMatches = [regex]::Matches(($stdout + "`n" + $stderr), '(?m)^\[E\][^\r\n]*')
            $hasExplicitError = $errMatches.Count -gt 0
            if ($hasExplicitError) { $engineErrorText = $errMatches[$errMatches.Count - 1].Value.Trim() }
            # Real OOM evidence can sit in a [W] line, not the last [E] one
            # (live case: 'execution engine cannot make enough memory available
            # on CUDA0' followed by [E] 'generate failed'). Match the specific
            # phrases - the generic word 'memory' appears in EVERY run's
            # model-manager log line and would mark everything as OOM.
            $allOutputText = $stdout + "`n" + $stderr
            $memoryDeath = -not $hasExplicitError
            if ($hasExplicitError -and ($engineErrorText -match 'memory|allocat|out of mem|OOM' -or $allOutputText -match 'enough memory available|out of memory|failed to allocate|allocation failed|failed during weight preparation')) { $memoryDeath = $true }
            if ($exitCode -ne 0 -and $memoryDeath) {
                $mp = [Math]::Round(([double]$job.Width * [double]$job.Height / 1000000.0), 1)
                $oomHint = "`r`nHint: the engine stopped without finishing"
                if ($engineErrorText) { $oomHint += (" - its last error: {0}" -f $engineErrorText) } else { $oomHint += ' without any error message' }
                $oomHint += (". At {0} x {1} ({2} MP, {3} steps) the most common cause is running out of GPU or system memory. Try a smaller size, fewer steps, or a fast speed mode (which renders small and enlarges)." -f $job.Width, $job.Height, $mp, $job.Steps)
                # AUTO-RETRY for improves: an img2img job that dies instantly
                # with EMPTY output is almost always out of GPU/system memory
                # at the render size. Retry the SAME improvement with the
                # next smaller speed mode: Exact -> 4x (50%) -> 8x (25%) ->
                # Fast (smallest). Each retry renders at a smaller size with
                # ALL steps and enlarges to the full target afterwards.
                $retryMode = $null
                if ($job.InitImage -and $mp -gt 2.0 -and -not $st.CancelRequested) {
                    switch ([string]$job.SpeedMode) {
                        'Exact' { $retryMode = '4x' }
                        '4x'    { $retryMode = '8x' }
                        '8x'    { $retryMode = 'Fast' }
                    }
                }
                if ($retryMode) {
                    [void]$script:RefineQueue.Insert(0,[pscustomobject]@{ File=[string]$job.InitImage; W=[int]$job.Width; H=[int]$job.Height; Seed=[long]$job.Seed; Prompt=[string]$job.Prompt; NegativePrompt=[string]$job.NegativePrompt; SamplingMethod=$job.SamplingMethod; Scheduler=$job.Scheduler; Strength=[double]$job.InitStrength; Steps=[int]$job.ChosenSteps; Cfg=[double]$job.Cfg; Tag='hq'; SrcW=[int]$job.SrcW; SrcH=[int]$job.SrcH; ForcedSpeed=$retryMode; UpscaleModel=$(if($job.PSObject.Properties['UpscaleModel']){[string]$job.UpscaleModel}else{$null}) })
                    $oomHint += "`r`n`r`nMOSS will now AUTOMATICALLY RETRY this improvement with a SMALLER render size ($retryMode speed mode: rendered small with all steps, then enlarged to the full target) - the composition still comes from your image."
                    $jobHires = 0.0; if ($job.PSObject.Properties['HiresScale']) { $jobHires = [double]$job.HiresScale }
                    if ($jobHires -ge 1.5) {
                        # The retry deliberately DROPS detail regeneration:
                        # the enlarged second pass is exactly what ran out of
                        # memory, so retrying with it would fail the same way.
                        # Say so - the retried copy can stay soft.
                        $oomHint += "`r`n`r`nThe retry runs WITHOUT detail regeneration (retrying the enlarged second pass would run out of memory the same way), so this copy can stay soft. Right-click it afterwards and use 'Improve this image' with detail regeneration for a sharp version."
                    }
                }
                $log.AppendText($oomHint)
            }
        }
        # Scheduler rejected by the engine (v0.1.86): the engine logs
        # '[E] ... not compatible with X scheduler' and CONTINUES - the
        # saved image can be blank white (verified: ays + dpm++2m). Exit
        # code and file count look normal, so this must be checked on its
        # own - otherwise the user silently gets a blank picture.
        $rejectedSched = Get-MossSchedulerReject ($stdout + "`n" + $stderr)
        if ($rejectedSched) {
            $log.AppendText(("`r`nWARNING: the engine REJECTED the scheduler '{0}' and rendered WITHOUT it - the saved image(s) can be BLANK or wrong. Pick a different scheduler in Generation options (verified working on this model with all samplers: karras, discrete, exponential, sgm_uniform, simple, smoothstep, kl_optimal, logit_normal, beta, flux, bong_tangent, ltx2, flux2; note: 'ays' fails with second-order samplers like dpm++2m)." -f $rejectedSched))
            [void](Write-MossErrorLog ('MOSS scheduler rejected by engine - ' + $rejectedSched) ($stdout + "`n" + $stderr))
            $finalMsg = ($finalMsg -replace ' - scheduler was REJECTED.*$', '') + ' - scheduler was REJECTED by the engine (see the log above)'
        }
        # Record the measured speed for the benchmark system (actual seconds
        # per image, from the live per-image durations) AND the integrated
        # energy for the power ledger (v0.1.87: session / day / all time).
        try {
            $bmAvg = $null
            if ($st.ImageDurations.Count -gt 0) { $bmAvg = (($st.ImageDurations | Measure-Object -Average).Average) }
            if ($ok -gt 0 -and $bmAvg) { Add-MossBenchmarkEntry -Job $job -SecondsPerImage ([double]$bmAvg) -Images ([int]$ok) }
        } catch {}
        try {
            # Energy ledger: the integrated draw of THIS engine run (measured
            # via nvidia-smi where available, TDP estimate otherwise). The
            # run counts once even when 0 images landed - the GPU still drew
            # the power.
            $pSec = [double]$st.PowerSeconds; $pJ = [double]$st.PowerJoules; $pMJ = [double]$st.PowerMeasuredJoules
            if ($pSec -gt 0.5 -and $pJ -gt 0) {
                Add-MossEnergyUsage -Joules $pJ -MeasuredJoules $pMJ -Seconds $pSec -Images ([int]$ok)
                $pMethod = if ($st.PowerSmi -and $pMJ -gt 0) { 'measured (nvidia-smi)' } else { 'estimated from the GPU rating' }
                $log.AppendText(("`r`nPower: this run used about {0:N2} kWh of GPU power over {1} ({2}; day and all-time totals in the Benchmarks dialog)." -f ($pJ / 3600000.0), (Format-MossDuration $pSec), $pMethod))
            }
        } catch {}
        $batchTimeText = ''
        if ($st.JobStartedAt) { $batchTimeText = ' | total time ' + (Format-MossDuration ((Get-Date) - $st.JobStartedAt).TotalSeconds) }
        # The log is a persistent record: the total time stays here after the
        # status line moves on (user: the time taken was lost when done).
        $log.AppendText("`r`n--- Batch finished | exit $exitCode | $ok of $($job.Count) image(s)$batchTimeText ---`r`n$outputText`r`n")
        # Failed refine jobs are counted so the queue summary can say FAILED
        # instead of claiming success (user saw 'Improvement finished' right
        # under a failed-run error report). A successful batch DECREMENTS the
        # count: the auto-retry re-queues the SAME item, so when the retry
        # succeeds the earlier failure of that item is resolved (user saw
        # 'Improvement FAILED - 1 of 1' right after the retry had SAVED the
        # image with exit 0).
        if ($exitCode -ne 0 -or $ok -lt $job.Count) { $script:RefineFailCount += [Math]::Max(1, $job.Count - $ok) }
        elseif ($script:RefineFailCount -gt 0) { $script:RefineFailCount-- }
        # Continue any pending native refinement queue unless the user cancelled.
        if (-not $st.CancelRequested) { Start-MossNextRefine } else { $script:RefineQueue.Clear(); $script:RefineTotal = 0; $script:RefineFailCount = 0; $script:RefineStartedAt = $null }
    }

    function Start-MossGeneration {
        param($Job,[switch]$ForRefine)
        if ($script:GenState.IsRunning) { return }
        # Safe mode: one central gate for EVERY generation path - the main
        # Generate button, improve dialogs, re-render and the automatic OOM
        # retry. A blocked refine item is counted as failed and the queue
        # continues with the next image, so an 'Improve ALL' batch never
        # stalls on a blocked prompt.
        if (-not (Test-MossPromptSafe ([string]$Job.Prompt))) {
            $log.AppendText("`r`nSafe mode: this prompt was BLOCKED - it contains sexual or gore/violence terms. Nothing was generated.`r`nIf you meant to run this prompt: open Options... (next to the image settings) and UNTICK 'Safe mode', then Save and try again.")
            $status.Text = 'Blocked by Safe mode - untick Safe mode in Options... to allow this prompt'
            $generate.Enabled = $true
            $cancel.Enabled = $false
            if ($ForRefine) { $script:RefineFailCount += 1; Start-MossNextRefine }
            return
        }
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
        # Images already processed live (upscaled + registered) while the
        # engine kept rendering; the batch-end pass skips these.
        $script:GenState.LiveCompletedImages = New-Object System.Collections.ArrayList
        $script:GenState.EtaShown = $null
        $script:GenState.EtaUpdatedAt = $null
        # Seed the ETA from the benchmark store so it is meaningful from the
        # first second (falls back to 'ETA calculating' when no data exists).
        $script:GenState['PredictedPerImage'] = $null
        # Detail-regeneration state: reset for EVERY run (stale phase data
        # from a previous hires run would corrupt the next one). Power meter
        # state: reset per job too, and resolve the measurement tool once
        # per run (nvidia-smi when present, TDP estimate otherwise).
        foreach ($hk in @('HiresPhase','HiresLastNum','HiresLastDen','HiresPhase1Steps','HiresPhase2Den','HiresLoggedPhase2','HiresBaseSec','HiresSecondSec')) { $script:GenState[$hk] = $null }
        $script:GenState.PowerJoules = 0.0; $script:GenState.PowerMeasuredJoules = 0.0; $script:GenState.PowerSeconds = 0.0
        $script:GenState.PowerLastSample = Get-Date; $script:GenState.PowerLastW = 250.0; $script:GenState.PowerLastMeasured = $false
        $script:GenState.PowerSmi = Get-MossNvidiaSmiPath
        $gpuNameEst = ''; try { $g0est = @($script:Inventory | Where-Object { -not $_.IsVirtual } | Select-Object -First 1); if ($g0est) { $gpuNameEst = [string]$g0est.Name } } catch {}
        $script:GenState.PowerEstimateW = Get-MossPowerEstimateWatts (Get-MossGpuTdp $gpuNameEst)
        try {
            # Detail-regeneration jobs: estimate base pass + highres second
            # pass from the SOURCE size - a plain estimate at the job's own
            # W/H would predict only the base pass and undershoot badly.
            $seedHires = 0.0; $seedSrcW = 0; $seedSrcH = 0
            if ($Job.PSObject.Properties['HiresScale']) { $seedHires = [double]$Job.HiresScale }
            if ($Job.PSObject.Properties['SrcW']) { $seedSrcW = [int]$Job.SrcW }
            if ($Job.PSObject.Properties['SrcH']) { $seedSrcH = [int]$Job.SrcH }
            $bmEst = Get-MossBenchmarkEstimate ([int]$Job.Width) ([int]$Job.Height) ([string]$Job.SpeedMode) ([int]$Job.Steps) ($null -ne $Job.InitImage) -HiresScale $seedHires -SrcW $seedSrcW -SrcH $seedSrcH
            if ($bmEst) {
                $script:GenState['PredictedPerImage'] = [double]$bmEst.Sec
                # The two-pass parts power the phase-aware live ETA.
                if ($seedHires -ge 1.5) {
                    $script:GenState['HiresBaseSec'] = $(if ($bmEst.BaseSec) { [double]$bmEst.BaseSec } else { 0.0 })
                    $script:GenState['HiresSecondSec'] = $(if ($bmEst.SecondSec) { [double]$bmEst.SecondSec } else { 0.0 })
                }
            }
        } catch {}

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
        # Progress bar: marquee until the engine reports the first step.
        $prog.Value = 0
        $prog.Style = 'Marquee'
        $prog.Visible = $true

        Start-MossBatchEngine
    }

    function Test-MossFastPreview([string]$file) {
        # A fast-mode preview is saved at its TARGET size after an in-place
        # bicubic upscale (sidecar notes UpscaledFrom). The soft look is baked
        # into the pixels, so image-to-image from this file inherits the blur.
        # True when the file should be re-rendered from scratch instead.
        $side=Get-MossSidecarReadPath $file
        if (Test-Path -LiteralPath $side -PathType Leaf) {
            try { $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json; if ($sc.UpscaledFrom) { return $true }; if ($sc.SpeedMode -and [string]$sc.SpeedMode -ne 'Exact') { return $true } } catch {}
        }
        return $false
    }

    function Test-MossUltraSoftDraft([string]$file) {
        # TRUE for the weakest class of fast drafts: rendered at a tiny size
        # (Fastest = 128-px side, 8x = 35%) and pixel-enlarged. Measured limit:
        # NO improve mode can create first-run detail from these - fast
        # sharpen keeps the composition's softness at 50 AND at 100 chosen
        # steps (controlled A/B on the user's own draft: both runs landed at
        # the draft's softness), because a plain img2img inherits the blur
        # baked into the pixels. Used to warn honestly in the improve dialog
        # instead of letting the user expect a sharp copy.
        $side=Get-MossSidecarReadPath $file
        if (Test-Path -LiteralPath $side -PathType Leaf) {
            try {
                $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json
                if ($sc.SpeedMode -and ([string]$sc.SpeedMode -eq '8x' -or [string]$sc.SpeedMode -eq 'Fast')) { return $true }
                if ($sc.UpscaledFrom -and ([string]$sc.UpscaledFrom) -match 'upscaled from (\d+) x (\d+)') {
                    $fromMax = [Math]::Max([int]$Matches[1],[int]$Matches[2])
                    if ($fromMax -gt 0 -and $fromMax -le 320) { return $true }
                }
            } catch {}
        }
        return $false
    }

    function Get-MossPreviewUpscaleFactor([string]$file) {
        # How many times the stored image was enlarged from its original small
        # render (sidecar note 'upscaled from W x H'). Returns 1.0 when the
        # file is not a fast preview.
        $side=Get-MossSidecarReadPath $file
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
        $sidecar = Get-MossSidecarReadPath $selFile
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
                if ($sc.Sampler -and ([string]$sc.Sampler -notmatch '^Default \(')) { $d.SamplingMethod = [string]$sc.Sampler }
                if ($sc.Scheduler) { $d.Scheduler = [string]$sc.Scheduler }
                if (-not $script:HistoryLocked -and $script:HistoryPassphrase -and $sc.PromptProtected) {
                    try { $p = Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase; if ($p) { $d.Prompt = [string]$p } } catch {}
                    if ($sc.NegativePromptProtected) { try { $np = Unprotect-MossPayload ([string]$sc.NegativePromptProtected) $script:HistoryPassphrase; if ($null -ne $np) { $d.NegativePrompt = [string]$np } } catch {} }
                }
                # Plain sidecar prompt (no code in use, or the user continues
                # without the password): readable without any code.
                if (-not ([string]$d.Prompt).Trim() -and $sc.Prompt) { $d.Prompt = [string]$sc.Prompt }
                if (-not [string]$d.NegativePrompt -and $sc.NegativePrompt) { $d.NegativePrompt = [string]$sc.NegativePrompt }
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
        Approve-MossSidecarAdoption $selFile | Out-Null
        $d = Get-MossImproveDefaults $selFile 1
        if ($d.Error -eq 'size') { [System.Windows.Forms.MessageBox]::Show('Could not determine the image size.','Re-render from seed')|Out-Null;return }
        # Without the image's original prompt a fresh re-render from its seed
        # would create a COMPLETELY different picture (user: do not even try).
        # The prompt is unreadable when the image was saved by an older MOSS
        # version with a history code and no code has been entered.
        if (-not ([string]$d.Prompt).Trim()) {
            [System.Windows.Forms.MessageBox]::Show(("The prompt of this image cannot be read: it is stored ENCRYPTED (a history code was active when the image was generated), and no code is currently entered in MOSS. A re-render without the prompt would create a completely different picture, so it was not started.`r`n`r`nYou can re-render it either way:`r`n`r`n1. Click 'History code...' in the header, enter your code, then right-click the image again - MOSS will read the stored prompt.`r`n`r`n2. Or type a NEW prompt in the main window and use Generate with the seed from Image info - that new prompt will be used instead.`r`n`r`nNothing was generated and the image was not changed."),'Prompt is encrypted - code required',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return
        }
        if ($d.Seed -lt 0) { $d.Seed = Get-Random -Minimum 1 -Maximum 2147483000 }
        # A fresh re-render gives the image's OWN look only when it was
        # rendered natively at (or near) its stored size. For an upscaled fast
        # draft the seed was sampled on a tiny canvas (e.g. 128 x 170), so the
        # same seed at full size is DIFFERENT NOISE and the picture comes out
        # completely different (live-confirmed by the user's report). Warn
        # loudly and point at the improve action instead.
        if (Test-MossFastPreview $selFile) {
            $upNote=''
            try { $scP = Get-Content -LiteralPath (Get-MossSidecarReadPath $selFile) -Raw | ConvertFrom-Json; if ($scP.UpscaledFrom) { $upNote=('It was upscaled from a small render ({0}). ' -f ([string]$scP.UpscaledFrom -replace '^upscaled from ','')) } } catch {}
            $warnAnswer=[System.Windows.Forms.MessageBox]::Show(("This image is an upscaled fast DRAFT. {0}A fresh re-render at {1} x {2} with the same seed will NOT look like this picture - the seed does not preserve the composition across render sizes (the small draft and the full-size canvas are different noise patterns).`r`n`r`nIf you want a FULL-QUALITY VERSION OF THIS PICTURE, choose 'No' and use 'Improve this image' instead - it keeps the composition.`r`n`r`nContinue with the fresh re-render anyway?" -f $upNote,$d.TW,$d.TH),'Fresh re-render of a fast draft',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if($warnAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        }
        [void]$script:RefineQueue.Add([pscustomobject]@{ File=$d.File; W=$d.TW; H=$d.TH; Seed=$d.Seed; Prompt=[string]$d.Prompt; NegativePrompt=[string]$d.NegativePrompt; SamplingMethod=$d.SamplingMethod; Scheduler=$d.Scheduler; Strength=0.0; Steps=$null; Cfg=$null; Tag='hq'; FreshRender=$true })
        $script:RefineTotal = $script:RefineQueue.Count
        Start-MossNextRefine
    }


    function Start-MossRefineWithCurrentSettings {
        # Improves the selected image: THE COMPOSITION AND SEED COME FROM THE
        # IMAGE ITSELF (img2img + the image's own seed by default), while the
        # user picks the quality in a dialog: target size (default = the
        # image's own size, with Same/2x/4x shortcuts), steps and CFG
        # (prefilled from the main window). The result is a separate NEW file
        # - the original is never modified.
        if ($script:GenState.IsRunning) { $status.Text='Busy - wait for the current run to finish, then right-click again.'; return }
        $selFile = [string]$script:SelectedFile
        if (-not $selFile -or -not (Test-Path -LiteralPath $selFile -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first (left-click it), then right-click to improve it.','Improve image')|Out-Null;return
        }
        $script:GenState.CancelRequested = $false
        Approve-MossSidecarAdoption $selFile | Out-Null
        $cPrompt=($prompt.Text -replace "(\r?\n)+",' ').Trim()
        if(-not $cPrompt){
            # The prompt box is empty: fall back to the image's own prompt from
            # its sidecar (decrypted only when the history code was entered),
            # and prefill the box so the user can see what will be used.
            $side=Get-MossSidecarReadPath $selFile
            if (Test-Path -LiteralPath $side -PathType Leaf) {
                try {
                    $sc = Get-Content -LiteralPath $side -Raw | ConvertFrom-Json
                    if (-not $script:HistoryLocked -and $script:HistoryPassphrase -and $sc.PromptProtected) {
                        try { $dp = Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase; if ($dp) { $cPrompt = ([string]$dp -replace "(\r?\n)+",' ').Trim(); $prompt.Text=[string]$dp } } catch {}
                    }
                    # Plain sidecar prompt (no code entered): use it directly.
                    if(-not $cPrompt -and $sc.Prompt){ $cPrompt = ([string]$sc.Prompt -replace "(\r?\n)+",' ').Trim(); $prompt.Text=[string]$sc.Prompt }
                } catch {}
            }
        }
        if(-not $cPrompt){
            # Distinguish WHY no prompt is available: the most common case is
            # an ENCRYPTED sidecar prompt with no history code entered. Give
            # a specific, actionable error instead of a generic one.
            $sideNow=Get-MossSidecarReadPath $selFile
            $encryptedNoCode=$false
            if (Test-Path -LiteralPath $sideNow -PathType Leaf) {
                try { $scN = Get-Content -LiteralPath $sideNow -Raw | ConvertFrom-Json; if ($scN.PromptProtected) { $encryptedNoCode=$true } } catch {}
            }
            if($encryptedNoCode){
                [System.Windows.Forms.MessageBox]::Show(("The prompt of this image cannot be read: it is stored ENCRYPTED (a history code was active when the image was generated), and no code is currently entered in MOSS.`r`n`r`nYou can improve it either way:`r`n`r`n1. Click 'History code...' in the header, enter your code, then right-click the image again - MOSS will read the stored prompt and prefill it.`r`n`r`n2. Or type a NEW prompt in the main window and try again - that new prompt will be used instead (the picture will follow the new prompt, not the original one).`r`n`r`nNothing was generated and the image was not changed."),'Prompt is encrypted - code required',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return
            }
            [System.Windows.Forms.MessageBox]::Show('No prompt was found for this image: the prompt box is empty and the image has no stored (or readable) prompt. Type a prompt in the main window and try again.','Prompt required')|Out-Null;return
        }
        $cStrength=0.6; $t=0.0; if (ConvertTo-MossDouble ([string]$script:Settings.ImproveStrength) ([ref]$t)) { if($t -ge 0.05 -and $t -le 0.95){ $cStrength=$t } }
        $cStrength=Get-MossImproveStrength $selFile $cStrength
        # Seed: the image's OWN seed by default - same-seed improves keep the
        # noise pattern aligned (same-seed improves are sharp, random-seed
        # improves are muddy - verified with real runs).
        $imgSeed=[long]-1
        $sideForSeed=Get-MossSidecarReadPath $selFile
        if (Test-Path -LiteralPath $sideForSeed -PathType Leaf) {
            try { $scS = Get-Content -LiteralPath $sideForSeed -Raw | ConvertFrom-Json; if ($scS.Seed) { $imgSeed=[long]$scS.Seed } } catch {}
        }
        # Source size (the dialog defaults to it).
        $csW=0; $csH=0
        try { $img=[System.Drawing.Image]::FromFile($selFile); $csW=$img.Width; $csH=$img.Height; $img.Dispose() } catch {}
        if($csW -le 0 -or $csH -le 0){[System.Windows.Forms.MessageBox]::Show('Could not read the image size.','Improve image')|Out-Null;return}
        $isPreview=Test-MossFastPreview $selFile
        # PICK-YOUR-QUALITY DIALOG: the composition and seed come from the
        # image; the user picks the target size (default = the image's own
        # size, with Same/2x/4x shortcuts), steps/CFG prefilled from the main
        # window and editable. The result is a NEW file - the original is
        # never touched.
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Improve this image'; $g.Size=New-Object System.Drawing.Size(600,614); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $ttl=New-Object System.Windows.Forms.Label; $ttl.Text=('Improve  ' + [System.IO.Path]::GetFileName($selFile)); $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',11,[System.Drawing.FontStyle]::Bold); $ttl.Location=New-Object System.Drawing.Point(14,10); $ttl.AutoSize=$true; $g.Controls.Add($ttl)
        $sub=New-Object System.Windows.Forms.Label; $sub.Text=('Same picture, your chosen quality. Composition and seed come from this image (source {0} x {1}). The result is saved as a NEW file - the original is never modified.' -f $csW,$csH); $sub.Location=New-Object System.Drawing.Point(14,42); $sub.Size=New-Object System.Drawing.Size(556,46); $sub.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($sub)
        $szLab=New-Object System.Windows.Forms.Label; $szLab.Text='Target size'; $szLab.Location=New-Object System.Drawing.Point(14,100); $szLab.AutoSize=$true; $g.Controls.Add($szLab)
        $wIn=New-Object System.Windows.Forms.TextBox; $wIn.Text=[string]$csW; $wIn.Location=New-Object System.Drawing.Point(110,96); $wIn.Size=New-Object System.Drawing.Size(70,26); $g.Controls.Add($wIn)
        $xLab=New-Object System.Windows.Forms.Label; $xLab.Text='x'; $xLab.Location=New-Object System.Drawing.Point(188,100); $xLab.AutoSize=$true; $g.Controls.Add($xLab)
        $hIn=New-Object System.Windows.Forms.TextBox; $hIn.Text=[string]$csH; $hIn.Location=New-Object System.Drawing.Point(205,96); $hIn.Size=New-Object System.Drawing.Size(70,26); $g.Controls.Add($hIn)
        $sameBtn=New-Object System.Windows.Forms.Button; $sameBtn.Text='Same'; $sameBtn.Location=New-Object System.Drawing.Point(300,92); $sameBtn.Size=New-Object System.Drawing.Size(70,30); $g.Controls.Add($sameBtn)
        $twoBtn=New-Object System.Windows.Forms.Button; $twoBtn.Text='2x'; $twoBtn.Location=New-Object System.Drawing.Point(378,92); $twoBtn.Size=New-Object System.Drawing.Size(56,30); $g.Controls.Add($twoBtn)
        $fourBtn=New-Object System.Windows.Forms.Button; $fourBtn.Text='4x'; $fourBtn.Location=New-Object System.Drawing.Point(442,92); $fourBtn.Size=New-Object System.Drawing.Size(56,30); $g.Controls.Add($fourBtn)
        $szNote=New-Object System.Windows.Forms.Label; $szNote.Text="Default: the image's own size. 2x/4x enlarge it. Above ~4.5 MP the render runs at HALF SIZE with all steps and is enlarged automatically - never distorted. If the native render runs out of memory, MOSS retries at half size automatically."; $szNote.Location=New-Object System.Drawing.Point(14,132); $szNote.Size=New-Object System.Drawing.Size(556,48); $szNote.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($szNote)
        # QUALITY MODE (three choices, replaces the old detail-regeneration
        # checkbox): plain same-size improve, FAST SHARPEN (single sampling
        # pass + the ESRGAN upscaler model - much faster than detail
        # regeneration), or DETAIL REGENERATION (the engine's highres fix:
        # base pass + a full second sampling pass at 2x - slowest, best
        # composition fidelity). Verified: a plain img2img from an upscaled
        # draft cannot sharpen it - a sharp mode is needed for drafts.
        # The USER picks the upscaler model (any .pth in models\upscalers) -
        # MOSS never overrides that choice. FALLBACK: without an upscaler
        # model file the fast option is disabled and drafts default to
        # detail regeneration - the path that worked before - so MOSS keeps
        # working offline or when the download is unavailable.
        $upscaleModels = Get-MossUpscalerModels
        $upscalePath = Get-MossDefaultUpscaleModel
        $rSame=New-Object System.Windows.Forms.RadioButton; $rSame.Text='Same size (fastest) - plain improve'; $rSame.Location=New-Object System.Drawing.Point(14,184); $rSame.Size=New-Object System.Drawing.Size(556,22); $rSame.ForeColor=$g.ForeColor; $g.Controls.Add($rSame)
        $rFast=New-Object System.Windows.Forms.RadioButton; $rFast.Text='Sharp - fast upscaler (recommended for drafts: renders at half size in ONE pass, then the upscaler sharpens to 2x)'; $rFast.Location=New-Object System.Drawing.Point(14,206); $rFast.Size=New-Object System.Drawing.Size(556,22); $rFast.ForeColor=$g.ForeColor; $rFast.Enabled=($null -ne $upscalePath); $g.Controls.Add($rFast)
        $umLab=New-Object System.Windows.Forms.Label; $umLab.Text='Upscaler model (yours to pick):'; $umLab.Location=New-Object System.Drawing.Point(14,232); $umLab.Size=New-Object System.Drawing.Size(180,20); $umLab.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($umLab)
        $umCombo=New-Object System.Windows.Forms.ComboBox; $umCombo.DropDownStyle='DropDownList'; $umCombo.Location=New-Object System.Drawing.Point(200,228); $umCombo.Size=New-Object System.Drawing.Size(370,24); foreach($m in $upscaleModels){ [void]$umCombo.Items.Add((Split-Path -Leaf $m)) }; if($upscalePath){ $umCombo.SelectedIndex=[Math]::Max(0,@($upscaleModels).IndexOf($upscalePath)) }; $umCombo.ForeColor=$g.ForeColor; $umCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $g.Controls.Add($umCombo); Set-MossComboTheme $umCombo $g
        $rHires=New-Object System.Windows.Forms.RadioButton; $rHires.Text='Sharp - detail regeneration (slowest: about 3-4x the plain render time)'; $rHires.Location=New-Object System.Drawing.Point(14,258); $rHires.Size=New-Object System.Drawing.Size(556,22); $rHires.ForeColor=$g.ForeColor; $g.Controls.Add($rHires)
        if(-not $rFast.Enabled){ $rFast.Text='Sharp - fast upscaler (unavailable: no upscaler model file in models\upscalers - restart MOSS to download it)' }
        # Drafts default to fast sharpen (user request: make improves faster);
        # falls back to detail regeneration when the upscaler is not installed.
        if($isPreview){ if($rFast.Enabled){ $rFast.Checked=$true } else { $rHires.Checked=$true } } else { $rSame.Checked=$true }
        # The current quality mode, used by the steps note and the estimate
        # (defined EARLY: the steps-note scriptblock below reads it at
        # construction time, dynamic scoping only helps inside handlers).
        $currentMode={ if($rFast.Checked){2}elseif($rHires.Checked){1}else{0} }
        # FAST SAMPLER DEFAULT (v0.1.86, verified on the real engine):
        # dpm++2m + karras needs about HALF the euler steps for the same
        # detail (euler 67 steps 40.9 s vs dpm++2m+karras 34 steps 24.3 s at
        # 1360 x 768, same seed, detail equal or better). Default ON unless
        # the user picked a sampler or scheduler in Generation options -
        # that explicit choice is then used verbatim.
        $fastChk=New-Object System.Windows.Forms.CheckBox; $fastChk.Text='Fast sampler (recommended): dpm++2m + karras - half the steps for plain improves, FULL steps for sharp modes'; $fastChk.Location=New-Object System.Drawing.Point(14,282); $fastChk.Size=New-Object System.Drawing.Size(556,22); $fastChk.ForeColor=$g.ForeColor; $g.Controls.Add($fastChk)
        $fastChk.Checked=$true
        if(([string]$script:Settings.SamplingMethod -ne 'Default (model)') -or ([string]$script:Settings.Scheduler -ne 'Default (model)')){
            $fastChk.Checked=$false; $fastChk.Enabled=$false
            $fastChk.Text='Fast sampler off: you picked a sampler/scheduler in Generation options - it is used exactly as chosen'
        }
        $stLab=New-Object System.Windows.Forms.Label; $stLab.Text='Steps'; $stLab.Location=New-Object System.Drawing.Point(14,322); $stLab.AutoSize=$true; $g.Controls.Add($stLab)
        $stIn=New-Object System.Windows.Forms.TextBox; $stIn.Text=([string]$script:Settings.Steps); $stIn.Location=New-Object System.Drawing.Point(110,318); $stIn.Size=New-Object System.Drawing.Size(70,26); $g.Controls.Add($stIn)
        $cfLab=New-Object System.Windows.Forms.Label; $cfLab.Text='CFG scale'; $cfLab.Location=New-Object System.Drawing.Point(210,322); $cfLab.AutoSize=$true; $g.Controls.Add($cfLab)
        $cfIn=New-Object System.Windows.Forms.TextBox; $cfIn.Text=([string]$script:Settings.CfgScale); $cfIn.Location=New-Object System.Drawing.Point(290,318); $cfIn.Size=New-Object System.Drawing.Size(70,26); $g.Controls.Add($cfIn)
        $cfTip=New-Object System.Windows.Forms.Label; $cfTip.Text='(from the main window - editable)'; $cfTip.Location=New-Object System.Drawing.Point(376,322); $cfTip.AutoSize=$true; $cfTip.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($cfTip)
        $sdLab=New-Object System.Windows.Forms.Label; $sdLab.Text='Seed'; $sdLab.Location=New-Object System.Drawing.Point(14,360); $sdLab.AutoSize=$true; $g.Controls.Add($sdLab)
        $sdIn=New-Object System.Windows.Forms.TextBox; $sdIn.Text=([string]$imgSeed); $sdIn.Location=New-Object System.Drawing.Point(110,356); $sdIn.Size=New-Object System.Drawing.Size(130,26); $g.Controls.Add($sdIn)
        $sdNote=New-Object System.Windows.Forms.Label; if($imgSeed -ge 0){ $sdNote.Text=" (the image's own seed - keeps the result aligned; -1 = random)" } else { $sdNote.Text=' (no stored seed - a random seed will be used)' }; $sdNote.Location=New-Object System.Drawing.Point(256,360); $sdNote.Size=New-Object System.Drawing.Size(300,32); $sdNote.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($sdNote)
        $stNoteBase=('Strength {0} (from Options). Image-to-image: the composition comes from the image - low strength = very faithful, high = more changes.{1}' -f $cStrength,($(if($isPreview){' This is an upscaled fast draft, so a raised strength is used automatically: detail is regenerated instead of the blurry enlargement.'}else{''})))
        # ALL chosen steps always run: img2img would skip early steps (about
        # steps x strength), so MOSS raises the ENGINE step count to
        # ceil((chosen-1)/strength) - verified with the real engine: 80 engine
        # steps at strength 0,6148 -> t_enc 49 -> exactly 50 sampling steps.
        $stepsEffText={
            $n=0
            if(-not [int]::TryParse($stIn.Text,[ref]$n)){ return '' }
            if($fastChk.Checked -and $n -ge 2){
                if((& $currentMode) -eq 0){
                    $half=Get-MossFastImproveSteps $n
                    $engHalf=[Math]::Ceiling(($half - 1) / $cStrength)
                    return (' Fast sampler ON (plain mode): dpm++2m + karras runs {0} of your {1} steps (verified equal detail at ~40% less time) - the engine step count is {2} so all of them run at this strength.' -f $half,$n,$engHalf)
                }
                $engFull=[Math]::Ceiling(($n - 1) / $cStrength)
                return (' Fast sampler ON (sharp mode): dpm++2m + karras runs ALL {0} steps at FULL count (verified: sharp-mode detail scales with the step count) - the engine step count is {1}.' -f $n,$engFull)
            }
            if($cStrength -gt 0.01 -and $cStrength -lt 1){ (' All {0} denoising steps run at this strength (MOSS raises the engine step count to {1} for that, since the strength alone would skip the early ones).' -f $n, [Math]::Ceiling(($n - 1) / $cStrength)) } else { '' }
        }
        $stNote=New-Object System.Windows.Forms.Label; $stNote.Text=($stNoteBase + (& $stepsEffText)); $stNote.Location=New-Object System.Drawing.Point(14,394); $stNote.Size=New-Object System.Drawing.Size(556,62); $stNote.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($stNote)
        $stIn.Add_TextChanged({ $stNote.Text = ($stNoteBase + (& $stepsEffText)) })
        $fastChk.Add_CheckedChanged({ $stNote.Text = ($stNoteBase + (& $stepsEffText)) })
        # LIVE TIME ESTIMATE for the CURRENT dialog values (quality mode,
        # target size, steps), extrapolated from the benchmark store - the
        # popup texts below reuse the same numbers instead of a hardcoded
        # 'about 15 minutes' claim that ignored the image size and steps.
        $estLbl=New-Object System.Windows.Forms.Label; $estLbl.Location=New-Object System.Drawing.Point(14,460); $estLbl.Size=New-Object System.Drawing.Size(556,28); $estLbl.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164); $g.Controls.Add($estLbl)
        $updateEst={
            try {
                $ew=0; $eh=0; $es=0
                $okW=[int]::TryParse($wIn.Text,[ref]$ew); $okH=[int]::TryParse($hIn.Text,[ref]$eh); $okS=[int]::TryParse($stIn.Text,[ref]$es)
                if(-not ($okW -and $okH -and $okS)){ $estLbl.Text='Enter valid sizes and steps to see a time estimate.'; return }
                if($fastChk.Checked -and (& $currentMode) -eq 0){ $es=Get-MossFastImproveSteps $es }   # halving is plain-mode only; sharp modes run FULL steps
                $est=Get-MossImproveTimeEstimate $csW $csH $ew $eh $cStrength $es (& $currentMode)
                if($est.Known){
                    $m = & $currentMode
                    if($m -eq 1){ $estLbl.Text=('Estimated: ~{0} total (base pass + highres second pass, from your measured runs).' -f (Format-MossDuration ([double]$est.Sec))) }
                    elseif($m -eq 2){ $estLbl.Text=('Estimated: ~{0} + a few seconds of upscaling (single pass, from your measured runs).' -f (Format-MossDuration ([double]$est.Sec))) }
                    else { $estLbl.Text=('Estimated: ~{0} (from your measured runs).' -f (Format-MossDuration ([double]$est.Sec))) }
                } else { $estLbl.Text='No benchmark data yet for a time estimate - measured runs fill this in automatically.' }
            } catch { $estLbl.Text='' }
        }
        & $updateEst
        $wIn.Add_TextChanged({ & $updateEst }); $hIn.Add_TextChanged({ & $updateEst })
        $stIn.Add_TextChanged({ & $updateEst })
        $fastChk.Add_CheckedChanged({ & $updateEst })
        $rSame.Add_CheckedChanged({ & $updateEst }); $rFast.Add_CheckedChanged({ & $updateEst }); $rHires.Add_CheckedChanged({ & $updateEst })
        $pNote=New-Object System.Windows.Forms.Label; $pNote.Text='Prompt: the text in the main window prompt box (change it there first).'; $pNote.Location=New-Object System.Drawing.Point(14,492); $pNote.Size=New-Object System.Drawing.Size(556,32); $pNote.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($pNote)
        $impBtn=New-Object System.Windows.Forms.Button; $impBtn.Text='Improve'; $impBtn.Location=New-Object System.Drawing.Point(320,530); $impBtn.Size=New-Object System.Drawing.Size(120,32); $g.Controls.Add($impBtn)
        $cnBtn=New-Object System.Windows.Forms.Button; $cnBtn.Text='Cancel'; $cnBtn.Location=New-Object System.Drawing.Point(452,530); $cnBtn.Size=New-Object System.Drawing.Size(100,32); $g.Controls.Add($cnBtn)
        $g.AcceptButton=$impBtn; $g.CancelButton=$cnBtn
        $sameBtn.Add_Click({ $wIn.Text=[string]$csW; $hIn.Text=[string]$csH })
        $twoBtn.Add_Click({ $wIn.Text=[string][Math]::Min(8192,([int]$csW*2)); $hIn.Text=[string][Math]::Min(8192,([int]$csH*2)) })
        $fourBtn.Add_Click({ $wIn.Text=[string][Math]::Min(8192,([int]$csW*4)); $hIn.Text=[string][Math]::Min(8192,([int]$csH*4)) })
        $impBtn.Add_Click({
            $cw=0; $chh=0
            if(-not [int]::TryParse($wIn.Text,[ref]$cw) -or -not [int]::TryParse($hIn.Text,[ref]$chh) -or $cw -lt 64 -or $chh -lt 64 -or $cw -gt 8192 -or $chh -gt 8192){[System.Windows.Forms.MessageBox]::Show($g,'Width and height must be between 64 and 8192 pixels.','Invalid dimensions')|Out-Null;return}
            $cst=0; $ccf=0.0; $csd=0
            if(-not [int]::TryParse($stIn.Text,[ref]$cst) -or $cst -lt 1 -or $cst -gt 200){[System.Windows.Forms.MessageBox]::Show($g,'Steps must be between 1 and 200.','Invalid steps')|Out-Null;return}
            if(-not (ConvertTo-MossDouble $cfIn.Text ([ref]$ccf)) -or $ccf -le 0 -or $ccf -gt 30){[System.Windows.Forms.MessageBox]::Show($g,'CFG scale must be greater than 0 and no more than 30 (dot or comma both work, e.g. 3.5 or 3,5).','Invalid CFG')|Out-Null;return}
            if(-not [int]::TryParse($sdIn.Text,[ref]$csd) -or $csd -lt -1){[System.Windows.Forms.MessageBox]::Show($g,'Seed must be -1 (random) or a non-negative integer.','Invalid seed')|Out-Null;return}
            $mode = & $currentMode
            # Fast sampler (v0.1.90, mode-aware): the step HALVING applies to
            # PLAIN improves only - verified equal detail at half the steps.
            # For the SHARP modes the steps stay FULL: detail scales strongly
            # with the step count (real draft, matched scale: fast sharpen
            # 58 engine steps = laplacian 387, 134 steps = 1308; the hires
            # second pass 58 steps = 30, 165 steps = 387). dpm++2m+karras
            # still applies as the sampler (its speed advantage is real).
            if($fastChk.Checked -and $mode -eq 0){ $cst=Get-MossFastImproveSteps $cst }
            if($mode -eq 0){
                # Plain improve at the chosen size: the size warnings apply.
                $finalMP=[Math]::Round((([double]$cw*[double]$chh)/1000000.0),1)
                $bigNote=''; $aspectNote=''
                if($finalMP -gt 4.5){ $bigNote=("`r`n`r`nNote: {0} MP is above what most GPUs render natively - it will be rendered at HALF SIZE with all {1} steps and enlarged automatically. If the native render runs out of memory, MOSS automatically retries at half size." -f $finalMP,$cst) }
                if($csW -gt 0 -and $csH -gt 0){ $srcA=[double]$csW/[double]$csH; $tgtA=[double]$cw/[double]$chh; if($tgtA -gt 0 -and [Math]::Abs($srcA/$tgtA-1) -gt 0.02){ $aspectNote=("`r`n`r`nNote: the target size has a different aspect ratio than the image ({0} x {1} -> {2} x {3}) - the composition will be squashed or stretched and the result can look worse. Use matching proportions for the best quality." -f $csW,$csH,$cw,$chh) } }
                if($bigNote -or $aspectNote){
                    $bEst=Get-MossImproveTimeEstimate $csW $csH $cw $chh $cStrength $cst 0
                    $estLine=$(if($bEst.Known){("`r`n`r`nEstimated render time: ~{0}." -f (Format-MossDuration ([double]$bEst.Sec)))}else{''})
                    $ans=[System.Windows.Forms.MessageBox]::Show($g,("Start the improve with {0} x {1} ({2} MP)?{3}{4}{5}" -f $cw,$chh,$finalMP,$bigNote,$aspectNote,$estLine),'Improve this image',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question); if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
                }
            }
            $useSampler=$null; if([string]$script:Settings.SamplingMethod -ne 'Default (model)'){ $useSampler=[string]$script:Settings.SamplingMethod }
            $useSched=$null; if([string]$script:Settings.Scheduler -ne 'Default (model)'){ $useSched=[string]$script:Settings.Scheduler }
            if($fastChk.Checked){ $useSampler='dpm++2m'; $useSched='karras' }   # verified fast+equal-detail default; explicit user choices above win
            $hiresScale=0; $upModel=$null
            if($mode -eq 1){
                # Detail regeneration: the size inputs are IGNORED - the base
                # pass runs at the image's OWN size and the highres second
                # pass doubles it (verified sharp: 1360x768 draft -> 2720x1536).
                $hiresScale=2
                $hEst=Get-MossImproveTimeEstimate $csW $csH $cw $chh $cStrength $cst 1
                $hTimeLine=$(if($hEst.Known){('Estimated from your measured runs: about {0} total (the highres second pass is the slow part).' -f (Format-MossDuration ([double]$hEst.Sec)))}else{'This takes roughly 3-4x the normal improve time.'})
                $hrAnswer=[System.Windows.Forms.MessageBox]::Show($g,("Detail regeneration ON: the render first keeps the composition at {0} x {1}, then re-synthesizes sharp detail at {2} x {3}.`r`n`r`n{4}`r`n`r`nStart now?" -f $csW,$csH,(2*$csW),(2*$csH),$hTimeLine),'Improve this image',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information); if($hrAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
            } elseif($mode -eq 2){
                # Fast sharpen: single sampling pass at the image's own size,
                # then the ESRGAN upscaler model THE USER PICKED sharpens it
                # in pixel space - no second sampling pass, much faster than
                # detail regeneration. The model choice is never overridden.
                # FALLBACK: if the upscaler model file vanished (download
                # unavailable?), MOSS falls back to detail regeneration -
                # the path that always worked.
                $upModel=$null; $umName=''
                if($umCombo.SelectedIndex -ge 0){ $umName=[string]$umCombo.SelectedItem; $upModel=[string]$upscaleModels[$umCombo.SelectedIndex] }
                if(-not $upModel -or -not (Test-Path -LiteralPath $upModel -PathType Leaf)){
                    $fbAnswer=[System.Windows.Forms.MessageBox]::Show($g,"The fast upscaler model file is missing (it may not have been downloaded yet).`r`n`r`nMOSS can use the slower DETAIL REGENERATION instead (about 3-4x the render time, output also 2x). Use it now?",'Upscaler unavailable',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
                    if($fbAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
                    $hiresScale=2
                } else {
                    $fEst=Get-MossImproveTimeEstimate $csW $csH $csW $csH $cStrength $cst 2
                    $fTimeLine=$(if($fEst.Known){('Estimated from your measured runs: about {0} plus a few seconds of upscaling.' -f (Format-MossDuration ([double]$fEst.Sec)))}else{'This takes about the plain improve time plus a few seconds of upscaling.'})
                    # Ultra-soft drafts (v0.1.92): fast sharpen cannot rescue
                    # the smallest fast drafts - measured, no step count
                    # helps. Say so BEFORE the run instead of delivering a
                    # predictable disappointment (the user's own A/B proved
                    # it: 50 and 100 chosen steps, same softness).
                    $softLine=''
                    if (Test-MossUltraSoftDraft $selFile) { $softLine="`r`n`r`nNOTE: this image is an ULTRA-soft draft (its original render was tiny, then enlarged - see the image info). Fast sharpen keeps that composition and the copy will stay soft: NO improve mode can create first-run detail from it (measured: 50 and 100 chosen steps land at the same softness). For a sharp image, render fresh at full quality instead." }
                    $fAnswer=[System.Windows.Forms.MessageBox]::Show($g,("Fast sharpen ON with upscaler model '{0}': the render runs at {1} x {2} (half the image's size) in ONE pass, then the upscaler sharpens/enlarges it in pixel space to about {3} x {4} - much faster than detail regeneration.`r`n`r`n{5}{6}`r`n`r`nStart now?" -f $umName,$qW,$qH,(2*$csW),(2*$csH),$fTimeLine,$softLine),'Improve this image',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information); if($fAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
                }
            } else {
                # A plain img2img cannot make an upscaled draft sharp (verified);
                # if the source is a soft draft and the user picked the plain
                # mode, say so once rather than delivering a predictably soft copy.
                if($isPreview){
                    $pEst=Get-MossImproveTimeEstimate $csW $csH $cw $chh $cStrength $cst 0
                    $pTimeLine=$(if($pEst.Known){('`r`n`r`nEstimated from your measured runs: about {0}.' -f (Format-MossDuration ([double]$pEst.Sec)))}else{''})
                    $softAnswer=[System.Windows.Forms.MessageBox]::Show($g,("This image is an upscaled fast draft. Without a sharp mode the improved copy will keep the draft's softness (the composition cannot gain detail it was never given).`r`n`r`nPick 'Sharp 2x' for a much sharper result (slower), or continue with the soft copy anyway?{0}" -f $pTimeLine),'Improve this image',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question); if($softAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
                }
            }
            # Sharp modes render at fixed sizes and save scaled: detail
            # regeneration runs the base pass at the image's OWN size; fast
            # sharpen renders at HALF the image's size and the x4 upscaler
            # sharpens it back to 2x. The size inputs above are IGNORED for
            # those modes.
            $qW=$cw; $qH=$chh
            if($mode -eq 1){ $qW=$csW; $qH=$csH }
            elseif($mode -eq 2){ $qW=[Math]::Max(128,[int][Math]::Floor($csW/2)); $qH=[Math]::Max(128,[int][Math]::Floor($csH/2)) }
            [void]$script:RefineQueue.Add([pscustomobject]@{ File=$selFile; W=$qW; H=$qH; Seed=$csd; Prompt=$cPrompt; NegativePrompt=[string]$script:Settings.NegativePrompt; SamplingMethod=$useSampler; Scheduler=$useSched; Strength=$cStrength; Steps=$cst; Cfg=$ccf; Tag='hq'; SrcW=$csW; SrcH=$csH; HiresScale=$hiresScale; UpscaleModel=$upModel })
            $script:RefineTotal = $script:RefineQueue.Count
            $g.Close()
            Start-MossNextRefine
        })
        [void]$g.ShowDialog($f)
        $g.Dispose()
    }

    function Get-MossFastImproveSteps([int]$ChosenSteps) {
        # Fast-sampler default for improves: dpm++2m + karras converges in
        # about HALF the euler steps (verified on the real engine, same seed
        # and settings: euler 67 steps 40.9 s vs dpm++2m+karras 34 steps
        # 24.3 s at 1360 x 768, detail equal or better - laplacian variance
        # 30.1 vs 26.9). Pure helper so the dialogs, the bulk plan and the
        # queue all agree on one rule. Minimum 2 steps.
        if ($ChosenSteps -lt 2) { return $ChosenSteps }
        return [Math]::Max(2, [Math]::Ceiling($ChosenSteps / 2.0))
    }

    function Get-MossSchedulerReject([string]$EngineOutput) {
        # The engine REJECTS an unsupported scheduler with an [E] line and
        # then CONTINUES RENDERING - the result can be a blank white image
        # (verified: --scheduler ays + --sampling-method dpm++2m rendered a
        # fully white 480 x 270 file, exit code 0). Detect the line so the
        # user is told instead of silently getting garbage. Returns the
        # rejected scheduler name, or $null when the output is clean.
        if (-not $EngineOutput) { return $null }
        $m = [regex]::Match($EngineOutput, '(?m)^\[E\][^\r\n]*not compatible with ([A-Za-z0-9_]+) scheduler')
        if ($m.Success) { return $m.Groups[1].Value }
        return $null
    }

    function Get-MossImproveTimeEstimate([int]$SrcW,[int]$SrcH,[int]$TargetW,[int]$TargetH,[double]$Strength,[int]$ChosenSteps,[int]$Mode = 0) {
        # Rough render time for ONE improve job, extrapolated from the
        # benchmark store. Mode 0 = plain img2img at the target size;
        # Mode 1 = detail regeneration (base pass at the source size + the
        # highres second pass at 2x); Mode 2 = fast sharpen (base pass at
        # the source size + ESRGAN upscaler to 2x - single sampling pass,
        # the upscaling itself adds only seconds). Engine steps follow the
        # same rule the queue applies (ceil((chosen-1)/strength)) so ALL
        # chosen steps are counted.
        # Returns Sec/Known/BaseSec/SecondSec/Based - Known $false without data.
        if ($SrcW -lt 64 -or $SrcH -lt 64) { return [pscustomobject]@{ Sec=$null; Known=$false; BaseSec=$null; SecondSec=$null; Based='' } }
        $engSteps = $ChosenSteps
        if ($Strength -gt 0.01 -and $Strength -lt 1 -and $ChosenSteps -gt 1) { $engSteps = [Math]::Min(1000, [Math]::Ceiling(($ChosenSteps - 1) / $Strength)) }
        try {
            if ($Mode -eq 1) {
                $est = Get-MossBenchmarkEstimate $TargetW $TargetH 'Exact' $engSteps $true -HiresScale 2.0 -SrcW $SrcW -SrcH $SrcH
                if ($est) { return [pscustomobject]@{ Sec=[double]$est.Sec; Known=$true; BaseSec=$(if($est.BaseSec){[double]$est.BaseSec}else{0.0}); SecondSec=$(if($est.SecondSec){[double]$est.SecondSec}else{0.0}); Based=[string]$est.Based } }
            } elseif ($Mode -eq 2) {
                # Fast sharpen renders at HALF the source size (the x4 upscaler
                # then sharpens it back to 2x the source) - the estimate is
                # the plain base pass at that size; the upscaling adds only
                # seconds.
                $estW = [Math]::Max(128, [int][Math]::Floor($SrcW / 2)); $estH = [Math]::Max(128, [int][Math]::Floor($SrcH / 2))
                $est = Get-MossBenchmarkEstimate $estW $estH 'Exact' $engSteps $true
                if ($est) { return [pscustomobject]@{ Sec=[double]$est.Sec; Known=$true; BaseSec=$null; SecondSec=$null; Based=[string]$est.Based } }
            } else {
                $est = Get-MossBenchmarkEstimate $TargetW $TargetH 'Exact' $engSteps $true
                if ($est) { return [pscustomobject]@{ Sec=[double]$est.Sec; Known=$true; BaseSec=$null; SecondSec=$null; Based=[string]$est.Based } }
            }
        } catch {}
        return [pscustomobject]@{ Sec=$null; Known=$false; BaseSec=$null; SecondSec=$null; Based='' }
    }

    function Update-MossHiresPhases($st, [double]$Numerator, [double]$Denominator) {
        # Phase tracker for detail-regeneration (hires) runs. The engine
        # samples TWICE in one process; the second pass's step bar RESTARTS
        # at 1/N, which previously made the progress bar fall back to ~0% and
        # the naive ETA extrapolation explode (user saw 'ETA ~30 min' right
        # after the base pass had finished). Called ONLY for hires jobs with
        # a live SAMPLING bar - never for the tiled VAE decode bar (the
        # caller filters that by text position).
        if ($null -eq $st['HiresPhase']) {
            $st['HiresPhase'] = 1
            $st['HiresLastNum'] = 0.0
            $st['HiresLastDen'] = 0
            $st['HiresPhase1Steps'] = 0
            $st['HiresPhase2Den'] = 0
        }
        if ([int]$st['HiresPhase'] -eq 1 -and $Numerator + 3 -lt [double]$st['HiresLastNum']) {
            # The step bar restarted: pass 1 is done, the highres pass began.
            $st['HiresPhase'] = 2
            # Pass 1's step TOTAL = the denominator of its last bar.
            $st['HiresPhase1Steps'] = [int][Math]::Max([double]$st['HiresPhase1Steps'], [double]$st['HiresLastDen'])
        }
        if ([int]$st['HiresPhase'] -eq 2 -and [int]$st['HiresPhase2Den'] -le 0 -and $Denominator -gt 0) {
            # Pass 2's step total, locked at its FIRST bar (a later tiled-VAE
            # decode bar must not corrupt it).
            $st['HiresPhase2Den'] = [int]$Denominator
        }
        $st['HiresLastNum'] = $Numerator
        $st['HiresLastDen'] = [int]$Denominator
    }

    function Get-MossBulkImprovePlan([object[]]$Items, [int]$SharpMode, [int]$ChosenSteps, [string]$UpscaleModel = $null, [bool]$FastSampler = $false) {
        # Pure decision logic for the bulk-improve confirm dialog: which
        # quality mode each item gets - SharpMode is applied ONLY to soft
        # fast-mode drafts (an img2img from an upscaled draft cannot sharpen
        # it, v0.1.81; native renders with fewer steps or a smaller size are
        # not soft and stay plain) - plus a rough total-time estimate from
        # the benchmark store. SharpMode: 0 = plain, 1 = detail
        # regeneration (highres 2x), 2 = fast sharpen (ESRGAN upscaler,
        # $UpscaleModel = the model path THE USER selected). Kept
        # free of any UI so it can be tested.
        # FastSampler (v0.1.86, step rule v0.1.90): items WITHOUT an explicit
        # sampler AND scheduler get dpm++2m + karras. The step HALVING applies
        # to PLAIN mode only (verified equal detail at half the steps); the
        # SHARP modes keep the FULL chosen steps - sharp-mode detail scales
        # with the step count (fast sharpen 58 engine steps = laplacian 387,
        # 134 steps = 1308 on a real draft, matched measurement scale).
        # Items with an explicit choice are never touched.
        $out = New-Object System.Collections.ArrayList
        $sharpCount = 0
        $estTotal = 0.0; $estKnown = $true
        foreach ($e in $Items) {
            $mode = 0
            if ($SharpMode -gt 0 -and [string]$e.Reason -eq 'soft preview (fast mode)') { $mode = [int]$SharpMode; $sharpCount++ }
            $useSampler=$null; if($e.SamplingMethod -and ([string]$e.SamplingMethod -notmatch '^Default \(')){ $useSampler=[string]$e.SamplingMethod }
            $useSched=$null; if($e.Scheduler -and ([string]$e.Scheduler -notmatch '^Default \(')){ $useSched=[string]$e.Scheduler }; $chosen = [int]$ChosenSteps
            $stepsOnItem = $null
            if ($FastSampler -and (-not $useSampler -or [string]$useSampler -eq 'Default (model)') -and (-not $useSched -or [string]$useSched -eq 'Default (model)')) {
                $useSampler = 'dpm++2m'; $useSched = 'karras'
                if ($mode -eq 0) { $chosen = Get-MossFastImproveSteps $chosen; $stepsOnItem = $chosen }
            }
            # The queue runs ALL chosen steps by raising the ENGINE step count
            # (ceil((chosen-1)/strength)) - estimate with the engine count, the
            # same rule Start-MossNextRefine applies.
            $est = Get-MossImproveTimeEstimate ([int]$e.SrcW) ([int]$e.SrcH) ([int]$e.W) ([int]$e.H) ([double]$e.Strength) $chosen $mode
            if ($est.Known -and [double]$est.Sec -gt 0) { $estTotal += [double]$est.Sec } else { $estKnown = $false }
            [void]$out.Add([pscustomobject]@{ File=[string]$e.File; W=$(if($mode -eq 2){[Math]::Max(128,[int][Math]::Floor([int]$e.SrcW/2))}else{$e.W}); H=$(if($mode -eq 2){[Math]::Max(128,[int][Math]::Floor([int]$e.SrcH/2))}else{$e.H}); Seed=$e.Seed; Prompt=[string]$e.Prompt; NegativePrompt=[string]$e.NegativePrompt; SamplingMethod=$useSampler; Scheduler=$useSched; Strength=[double]$e.Strength; Steps=$stepsOnItem; Cfg=$null; Tag='hq'; Reason=[string]$e.Reason; SrcW=[int]$e.SrcW; SrcH=[int]$e.SrcH; HiresScale=$(if($mode -eq 1){2.0}else{0.0}); UpscaleModel=$(if($mode -eq 2){ [string]$UpscaleModel }else{ $null }); Mode=$mode })
        }
        return [pscustomobject]@{ Queue=$out; SharpCount=$sharpCount; EstimateSec=$(if($estKnown){[Math]::Round($estTotal,0)}else{$null}) }
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
            $j=Get-MossSidecarReadPath ([string]$f)
            if(Test-Path -LiteralPath $j){ try { $sc=Get-Content -LiteralPath $j -Raw|ConvertFrom-Json; if($sc.InitImage){ $improvedSources.Add([string]$sc.InitImage) } } catch {} }
        }
        $eligible=New-Object System.Collections.ArrayList
        $skippedQuality=0; $skippedImproved=0; $skippedBroken=0; $skippedLocked=0
        foreach($f in @($script:GeneratedFiles)){
            $name=[System.IO.Path]::GetFileName([string]$f)
            if($improvedSources -contains $name){ $skippedImproved++; continue }
            $d = Get-MossImproveDefaults ([string]$f) 1
            if($d.Error -ne ''){ $skippedBroken++; continue }
            $speedMode='Exact'; $upscaled=$false; $oldSteps=0
            $sidecar=Get-MossSidecarReadPath ([string]$f)
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
            # A file whose prompt cannot be read (encrypted by an older version
            # and no history code entered) is SKIPPED - improving it would
            # create a completely different picture (user request).
            if(-not ([string]$d.Prompt).Trim() -and -not $prompt.Text.Trim()){ $skippedLocked++; continue }
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
        if($skippedLocked -gt 0){ $skipNote+=("`r`n{0} have an unreadable (encrypted) prompt and will be skipped - enter your history code in MOSS to include them." -f $skippedLocked) }
        # Sharp modes for soft drafts: an img2img from an upscaled draft
        # CANNOT sharpen it (v0.1.81, verified). The bulk dialog offers the
        # same three modes as the single-image dialog (plain / fast upscaler /
        # detail regeneration) - the sharp mode applies ONLY to the soft
        # drafts in the batch, and the USER picks the upscaler model (never
        # overridden). Fast sharpen is default (much faster); it falls back
        # to detail regeneration when no upscaler model is installed.
        $draftCount = @($eligible | Where-Object { [string]$_.Reason -eq 'soft preview (fast mode)' }).Count
        $upscaleModels = Get-MossUpscalerModels
        $upscalePath = Get-MossDefaultUpscaleModel
        # Fast sampler (v0.1.86): OFF when the user picked a sampler or
        # scheduler in Generation options (that explicit choice wins),
        # otherwise the checkbox below decides. Plans are recomputed when
        # the checkbox changes so the estimate always matches the run.
        $bulkFastAllowed = (([string]$script:Settings.SamplingMethod -eq 'Default (model)') -and ([string]$script:Settings.Scheduler -eq 'Default (model)'))
        $bulkFastChk=New-Object System.Windows.Forms.CheckBox; $bulkFastChk.Text='Fast sampler: dpm++2m + karras at HALF the steps - verified equal detail, ~40% faster'; $bulkFastChk.Location=New-Object System.Drawing.Point(14,296); $bulkFastChk.Size=New-Object System.Drawing.Size(596,22); $bulkFastChk.ForeColor=$g.ForeColor; $g.Controls.Add($bulkFastChk)
        if($bulkFastAllowed){ $bulkFastChk.Checked=$true } else { $bulkFastChk.Checked=$false; $bulkFastChk.Enabled=$false; $bulkFastChk.Text='Fast sampler off: you picked a sampler/scheduler in Generation options - it is used exactly as chosen' }
        $replan={
            $fastFlag = $false; if($bulkFastAllowed -and $bulkFastChk.Checked){ $fastFlag = $true }
            $script:bulkPlan0 = Get-MossBulkImprovePlan $eligible 0 $curSteps $upscalePath $fastFlag
            $script:bulkPlan1 = Get-MossBulkImprovePlan $eligible 1 $curSteps $upscalePath $fastFlag
            $script:bulkPlan2 = Get-MossBulkImprovePlan $eligible 2 $curSteps $upscalePath $fastFlag
        }
        & $replan
        $plan0 = $script:bulkPlan0; $plan1 = $script:bulkPlan1; $plan2 = $script:bulkPlan2
        $summary = ("{0} of {1} file(s) qualify for improvement ({2}).{3}`r`n`r`nThey are improved one after another with the current settings (steps {4}), each using its own seed, prompt and strength - fast previews automatically get a higher strength so detail is regenerated instead of the blurry enlargement." -f $eligible.Count,$script:GeneratedFiles.Count,(($eligible | ForEach-Object { $_.Reason } | Select-Object -Unique) -join ', '),$skipNote,$curSteps)
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Improve all'; $g.Size=New-Object System.Drawing.Size(640,500); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $sum=New-Object System.Windows.Forms.Label; $sum.Text=$summary; $sum.Location=New-Object System.Drawing.Point(14,10); $sum.Size=New-Object System.Drawing.Size(596,140); $g.Controls.Add($sum)
        $est=New-Object System.Windows.Forms.Label; $est.Location=New-Object System.Drawing.Point(14,158); $est.Size=New-Object System.Drawing.Size(596,32); $est.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164); $g.Controls.Add($est)
        $rPlain=New-Object System.Windows.Forms.RadioButton; $rPlain.Text='Plain improve (drafts stay soft)'; $rPlain.Location=New-Object System.Drawing.Point(14,196); $rPlain.Size=New-Object System.Drawing.Size(596,22); $rPlain.ForeColor=$g.ForeColor; $g.Controls.Add($rPlain)
        $rFast=New-Object System.Windows.Forms.RadioButton; $rFast.Text=('Sharp - fast upscaler for the {0} soft draft(s) (recommended)' -f $draftCount); $rFast.Location=New-Object System.Drawing.Point(14,218); $rFast.Size=New-Object System.Drawing.Size(596,22); $rFast.ForeColor=$g.ForeColor; $rFast.Enabled=($draftCount -gt 0 -and $null -ne $upscalePath); $g.Controls.Add($rFast)
        $umLab=New-Object System.Windows.Forms.Label; $umLab.Text='Upscaler model (yours to pick):'; $umLab.Location=New-Object System.Drawing.Point(14,244); $umLab.Size=New-Object System.Drawing.Size(180,20); $umLab.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($umLab)
        $umCombo=New-Object System.Windows.Forms.ComboBox; $umCombo.DropDownStyle='DropDownList'; $umCombo.Location=New-Object System.Drawing.Point(200,240); $umCombo.Size=New-Object System.Drawing.Size(410,24); foreach($m in $upscaleModels){ [void]$umCombo.Items.Add((Split-Path -Leaf $m)) }; if($upscalePath){ $umCombo.SelectedIndex=[Math]::Max(0,@($upscaleModels).IndexOf($upscalePath)) }; $umCombo.ForeColor=$g.ForeColor; $umCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $g.Controls.Add($umCombo); Set-MossComboTheme $umCombo $g
        $rHires=New-Object System.Windows.Forms.RadioButton; $rHires.Text=('Sharp - detail regeneration for the {0} soft draft(s) (slowest, about 3-4x the render time)' -f $draftCount); $rHires.Location=New-Object System.Drawing.Point(14,272); $rHires.Size=New-Object System.Drawing.Size(596,22); $rHires.ForeColor=$g.ForeColor; $rHires.Enabled=($draftCount -gt 0); $g.Controls.Add($rHires)
        if(-not $rFast.Enabled){ $rFast.Text='Sharp - fast upscaler (unavailable: no upscaler model file in models\upscalers - restart MOSS to download it)' }
        if($rFast.Enabled){ $rFast.Checked=$true } elseif($rHires.Enabled){ $rHires.Checked=$true } else { $rPlain.Checked=$true }
        $note=New-Object System.Windows.Forms.Label; $note.Location=New-Object System.Drawing.Point(14,324); $note.Size=New-Object System.Drawing.Size(596,64); $note.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $g.Controls.Add($note)
        $currentPlan={ if($rHires.Checked){$script:bulkPlan1}elseif($rFast.Checked){$script:bulkPlan2}else{$script:bulkPlan0} }
        $updateEst={
            $plan = & $currentPlan
            $est.Text = $(if($null -ne $plan.EstimateSec){('Roughly {0} total for all {1} image(s) at the current settings{2}.' -f (Format-MossDuration ([double]$plan.EstimateSec)),$plan.Queue.Count,$(if($plan.SharpCount -gt 0){(', ' + $plan.SharpCount + ' sharpened')}else{''}))}else{'No benchmark data yet for a time estimate - a few measured runs fill this in automatically.'})
            if($rHires.Checked){
                $note.Text='Detail regeneration: each draft keeps its composition at its own size, then a second pass re-synthesizes sharp detail at 2x (verified). Large batches can run for many hours - Cancel stops the queue at any time.'
            } elseif($rFast.Checked){
                $note.Text='Fast sharpen: each draft renders in ONE pass at its own size, then the selected upscaler model sharpens it in pixel space - much faster than detail regeneration.'
            } else {
                $note.Text=$(if($draftCount -gt 0){'Without a sharp mode the soft drafts STAY SOFT: an img2img from an upscaled draft cannot add the detail it was never given (verified).'}else{''})
            }
        }
        & $updateEst
        $rPlain.Add_CheckedChanged({ & $updateEst }); $rFast.Add_CheckedChanged({ & $updateEst }); $rHires.Add_CheckedChanged({ & $updateEst })
        $bulkFastChk.Add_CheckedChanged({ & $replan; & $updateEst })
        $goBtn=New-Object System.Windows.Forms.Button; $goBtn.Text='Start all'; $goBtn.Location=New-Object System.Drawing.Point(330,400); $goBtn.Size=New-Object System.Drawing.Size(120,32); $g.Controls.Add($goBtn)
        $cnBtn=New-Object System.Windows.Forms.Button; $cnBtn.Text='Cancel'; $cnBtn.Location=New-Object System.Drawing.Point(462,400); $cnBtn.Size=New-Object System.Drawing.Size(100,32); $g.Controls.Add($cnBtn)
        $g.AcceptButton=$goBtn; $g.CancelButton=$cnBtn
        $goBtn.Add_Click({
            $plan = & $currentPlan
            # The USER's upscaler model choice wins: re-apply the currently
            # selected model to every fast-sharpen item (the plans were
            # precomputed before the selection could change).
            $bulkModel=$null
            if($umCombo.SelectedIndex -ge 0){ $bulkModel=[string]$upscaleModels[$umCombo.SelectedIndex] }
            if(-not ($rHires.Checked -or $rFast.Checked) -and $draftCount -gt 0){
                $softAnswer=[System.Windows.Forms.MessageBox]::Show($g,("Start anyway? The {0} soft draft(s) in this batch will keep their softness - pick a 'Sharp' mode for much sharper copies (slower)." -f $draftCount),'Improve all',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
                if($softAnswer -ne [System.Windows.Forms.DialogResult]::Yes){return}
            }
            foreach($e0 in $plan.Queue){ if($e0.Mode -eq 2){ $e0.UpscaleModel = $bulkModel }; [void]$script:RefineQueue.Add($e0) }
            $script:RefineTotal = $script:RefineQueue.Count
            $modeText=$(if($rHires.Checked){'detail regeneration (highres fix)'}elseif($rFast.Checked){'fast sharpen (upscaler model)'}else{'plain'})
            $log.AppendText(("`r`nBulk improvement: {0} file(s) queued ({1}){2}." -f $plan.Queue.Count,$modeText,$(if($plan.SharpCount -gt 0){(', ' + $plan.SharpCount + ' sharpened')}else{''})))
            $g.Close()
            Start-MossNextRefine
        })
        $cnBtn.Add_Click({ $g.Close() })
        [void]$g.ShowDialog($f)
        $g.Dispose()
    }

    function Remove-MossSelectedFiles([bool]$All) {
        # Deletes images (and their sidecars) from disk and the list: either
        # the multi-selection (Ctrl+click / Shift+click) or ALL files at once.
        # One confirmation for the whole batch - no per-file prompts.
        $files=@()
        if($All){ foreach($it in @($fileList.Items)){ $files+=[string]$it } }
        else {
            foreach($idx in @($fileList.SelectedIndices)){ $files+=[string]$fileList.Items[$idx] }
            if($files.Count -eq 0 -and [string]$script:SelectedFile){ $files=@([string]$script:SelectedFile) }
        }
        $files=@($files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
        if($files.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show('Select a file in Generated Files first (Ctrl+click or Shift+click for several).','Delete files')|Out-Null;return }
        $totalBytes=0
        foreach($f in $files){ try { $totalBytes+=(Get-Item -LiteralPath $f).Length; $side=Get-MossSidecarReadPath $f; if(Test-Path -LiteralPath $side){ $totalBytes+=(Get-Item -LiteralPath $side).Length } } catch {} }
        $nameLine=if($files.Count -eq 1){$files[0]}else{($files[0]+'  ... and '+($files.Count-1)+' more')}
        $answer=[System.Windows.Forms.MessageBox]::Show(("Delete {0} image(s) permanently?`r`n{1}`r`n`r`nAbout {2} MB will be freed (images + sidecars).`r`nThis cannot be undone." -f $files.Count,$nameLine,[Math]::Round($totalBytes/1MB,1)),'Delete files',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        # Release the preview first so no file is held open while deleting.
        try { $old=$preview.Image; $preview.Image=$null; if($old){ $old.Dispose() } } catch {}
        $deleted=0; $failed=0
        foreach($f in $files){
            try {
                Remove-Item -LiteralPath $f -Force
                # The sidecar may sit in the metadata subfolder (new) or next
                # to the image (older versions) - clean up both locations.
                foreach($side in @((Get-MossSidecarPath $f),([System.IO.Path]::ChangeExtension($f,'.json')))){
                    if(Test-Path -LiteralPath $side){ try { Remove-Item -LiteralPath $side -Force } catch {} }
                }
                $idx=-1; for($i=0;$i -lt $fileList.Items.Count;$i++){ if([string]$fileList.Items[$i] -eq $f){ $idx=$i; break } }
                if($idx -ge 0){ $fileList.Items.RemoveAt($idx) }
                [void]$script:GeneratedFiles.Remove($f)
                $deleted++
            } catch { $failed++ }
        }
        $script:SelectedFile=$null
        # User request: after a delete the preview goes BLANK - the deleted
        # picture must not stay on screen, and no other image is auto-shown.
        try { $old=$preview.Image; $preview.Image=$null; if($old){ $old.Dispose() } } catch {}
        $fileList.ClearSelected()
        $status.Text=('Deleted {0} file(s).{1}' -f $deleted,$(if($failed){' '+$failed+' could not be deleted.'}else{''}))
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
        $side=Get-MossSidecarReadPath $selFile
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
                } elseif ($sc.Prompt) {
                    # Plain sidecar prompt (no code entered when the image was made).
                    $prompt=[string]$sc.Prompt
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
            $lines.Add('No info file (.json) was found for this image (MOSS stores them in the metadata subfolder of the output folder).')
        }
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Image info'; $g.Size=New-Object System.Drawing.Size(660,540); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $lp=New-Object System.Windows.Forms.Label; $lp.Text='Prompt used for this image'; $lp.Location=New-Object System.Drawing.Point(12,10); $lp.Size=New-Object System.Drawing.Size(400,18); $lp.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($lp)
        $pBox=New-Object System.Windows.Forms.TextBox; $pBox.Multiline=$true; $pBox.ReadOnly=$true; $pBox.ScrollBars='Vertical'; $pBox.WordWrap=$true; $pBox.Text=$(if($prompt){$prompt}else{$promptLockedNote}); $pBox.Location=New-Object System.Drawing.Point(12,30); $pBox.Size=New-Object System.Drawing.Size(620,120); $pBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $pBox.ForeColor=$cText; $pBox.BorderStyle='FixedSingle'; $g.Controls.Add($pBox)
        $ln=New-Object System.Windows.Forms.Label; $ln.Text='Negative prompt'; $ln.Location=New-Object System.Drawing.Point(12,158); $ln.Size=New-Object System.Drawing.Size(400,18); $ln.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($ln)
        $nBox=New-Object System.Windows.Forms.TextBox; $nBox.Multiline=$true; $nBox.ReadOnly=$true; $nBox.ScrollBars='Vertical'; $nBox.WordWrap=$true; $nBox.Text=$(if($neg){$neg}else{'(none)'}); $nBox.Location=New-Object System.Drawing.Point(12,178); $nBox.Size=New-Object System.Drawing.Size(620,48); $nBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $nBox.ForeColor=$cText; $nBox.BorderStyle='FixedSingle'; $g.Controls.Add($nBox)
        $ls=New-Object System.Windows.Forms.Label; $ls.Text='Settings and origin (also stored in the metadata subfolder of the output folder)'; $ls.Location=New-Object System.Drawing.Point(12,234); $ls.Size=New-Object System.Drawing.Size(560,18); $ls.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($ls)
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
        if ($script:GenState.CancelRequested) { if($script:RefineQueue.Count -gt 0){ $log.AppendText("`r`nImprovement queue cancelled.") }; $script:RefineQueue.Clear(); $script:RefineTotal = 0; $script:RefineStartedAt = $null; return }
        if ($script:RefineQueue.Count -eq 0) {
            if ($script:RefineTotal -gt 0) {
                # Keep the time taken: the total elapsed survives completion
                # (it was previously overwritten by this very message).
                $queueElapsed = ''
                if ($script:RefineStartedAt) { $queueElapsed = ' | total elapsed ' + (Format-MossDuration ((Get-Date) - $script:RefineStartedAt).TotalSeconds) }
                if ($script:RefineFailCount -gt 0) {
                    $status.Text = "Improvement FAILED - $($script:RefineFailCount) of $($script:RefineTotal) image(s) did not process$queueElapsed - see the log above"
                    $log.AppendText("`r`nImprovement FAILED - $($script:RefineFailCount) of $($script:RefineTotal) image(s) did not process$(if($queueElapsed){' | total time ' + $queueElapsed.Replace(' | total elapsed ','')}).")
                } else {
                    $status.Text = "Improvement finished - $script:RefineTotal image(s) processed$queueElapsed"
                    $log.AppendText("`r`nImprovement finished - $script:RefineTotal image(s) processed$(if($queueElapsed){' | total time ' + $queueElapsed.Replace(' | total elapsed ','')}).")
                }
                $script:RefineStartedAt = $null
                $script:RefineTotal = 0
                $script:RefineFailCount = 0
            }
            return
        }
        $item = $script:RefineQueue[0]
        $script:RefineQueue.RemoveAt(0)
        # Queue total wall time: stamped when the FIRST item starts.
        if (-not $script:RefineStartedAt) { $script:RefineStartedAt = Get-Date }
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
            $script:RefineFailCount = 0
            return
        }
        $gpuIdx=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $gpuIdx=[int]$script:Settings.PreferredGpuIndex } catch { $gpuIdx=-1 } }
        # Very large improve targets cannot be rendered natively on most GPUs
        # (the engine then dies silently, usually out of memory). Above ~4.5
        # megapixels the improve is rendered at HALF SIZE with the full step
        # count and enlarged to the full target afterwards - the same faithful
        # pipeline as the fast generation speed modes (no second sampling pass).
        $isFresh = $false; if ($item.PSObject.Properties['FreshRender']) { $isFresh = [bool]$item.FreshRender }
        # An automatic retry after an out-of-memory failure: force the
        # given smaller speed mode regardless of the MP threshold.
        $forcedSpeed = $null; if ($item.PSObject.Properties['ForcedSpeed']) { $forcedSpeed = [string]$item.ForcedSpeed }
        $refineSpeed = 'Exact'
        $targetMP = ([double]$item.W * [double]$item.H) / 1000000.0
        $hiresScale = 0.0
        if ($item.PSObject.Properties['HiresScale']) { $hiresScale = [double]$item.HiresScale }
        # The 4.5 MP half-size demotion must not touch detail-regeneration
        # jobs: their base pass runs at the image's own (small) size already.
        if ($targetMP -gt 4.5 -and -not $forcedSpeed -and $hiresScale -lt 1.5) {
            $refineSpeed = '4x'
            $log.AppendText(("`r`nNote: {0} x {1} is too large for a native render on most GPUs - rendering at half size with all {2} steps and enlarging to full size (fast-mode pipeline, never distorted)." -f $item.W, $item.H, $(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps})))
        }
        if ($forcedSpeed) {
            $refineSpeed = $forcedSpeed
            $log.AppendText(("`r`nRetrying the improvement with a SMALLER render size ({0} speed mode) after the previous render ran out of memory: target {1} x {2}, all {3} steps, enlarged to full size (composition kept from the image)." -f $forcedSpeed, $item.W, $item.H, $(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps})))
        }
        $refineSteps = $(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps})
        $refineStrength = $(if($item.PSObject.Properties['Strength']){[double]$item.Strength}else{0.6})
        # For detail-regeneration jobs the job's own W/H is IGNORED by the args
        # builder (the base pass runs at the source size): log the size the
        # finished file will actually have.
        $finalW = [int]$item.W; $finalH = [int]$item.H
        if ($hiresScale -ge 1.5 -and $item.PSObject.Properties['SrcW'] -and [int]$item.SrcW -ge 64) {
            $finalW = [int][Math]::Round([int]$item.SrcW * $hiresScale); $finalH = [int][Math]::Round([int]$item.SrcH * $hiresScale)
        }
        # ALL CHOSEN STEPS ALWAYS RUN (user: 'if i want the quality at 50 it
        # should do the 50'). Img2img would skip early steps (about steps x
        # strength), so MOSS raises the ENGINE step count to
        # ceil((chosen-1)/strength) - verified with the real engine: 80
        # engine steps at strength 0,6148 -> t_enc 49 -> exactly 50 sampled.
        # ChosenSteps keeps the user's count so an OOM auto-retry cannot
        # compensate twice.
        $engineSteps = $refineSteps
        if (-not $isFresh -and $refineStrength -gt 0.01 -and $refineStrength -lt 1 -and $refineSteps -gt 1) {
            $engineSteps = [Math]::Min(1000, [Math]::Ceiling(($refineSteps - 1) / $refineStrength))
            $log.AppendText(("`r`nNote: running ALL {0} denoising steps at strength {1} - the engine step count is raised to {2} (the strength alone would run only about {3})." -f $refineSteps, $refineStrength, $engineSteps, ([Math]::Floor($refineSteps*$refineStrength)+1)))
        }
        $job=[pscustomobject]@{Engine=$refinePaths[0];Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$refinePaths[1];Llm=$refinePaths[2];Vae=$refinePaths[3];Tokenizer=$refinePaths[4];OutputPath=(Get-AbsoluteAppPath ([string]$script:Settings.OutputPath));Steps=$engineSteps;ChosenSteps=$refineSteps;Cfg=$(if($null -ne $item.Cfg){[double]$item.Cfg}else{[double]$script:Settings.CfgScale});Width=[int]$item.W;Height=[int]$item.H;Count=1;Seed=[long]$item.Seed;Prompt=[string]$item.Prompt;GpuIndex=$gpuIdx;SpeedMode=$refineSpeed;InitImage=$(if($isFresh){$null}else{[string]$item.File});InitStrength=$(if($isFresh){0.0}else{[double]$item.Strength});RefineTag=[string]$item.Tag;NegativePrompt=$item.NegativePrompt;SamplingMethod=$item.SamplingMethod;Scheduler=$item.Scheduler;SrcW=$(if($item.PSObject.Properties['SrcW']){[int]$item.SrcW}else{0});SrcH=$(if($item.PSObject.Properties['SrcH']){[int]$item.SrcH}else{0});HiresScale=$hiresScale;UpscaleModel=$(if($item.PSObject.Properties['UpscaleModel']){[string]$item.UpscaleModel}else{$null})}
        # Quick benchmark runs (Tag 'bench') write into the benchmarks folder
        # instead of outputs, so test renders never pollute the file list.
        if ($item.PSObject.Properties['Tag'] -and [string]$item.Tag -eq 'bench') {
            $benchDir = Join-Path $script:AppRoot 'benchmarks'
            if (-not (Test-Path -LiteralPath $benchDir)) { New-Item -ItemType Directory -Path $benchDir -Force | Out-Null }
            $job = $job.PSObject.Copy(); $job.OutputPath = $benchDir
            $log.AppendText(("`r`nQuick benchmark run {0} of {1}: {2} x {3} at {4} engine steps..." -f ($script:RefineTotal - $script:RefineQueue.Count), $script:RefineTotal, $item.W, $item.H, $job.Steps))
        }
        $status.Text = ("Improving image {0} of {1} at {2} x {3}..." -f ($script:RefineTotal - $script:RefineQueue.Count), $script:RefineTotal, $item.W, $item.H)
        # The log notes below reference the upscaler model; it is carried on
        # the item (and now on the job itself - the v0.1.85-89 bug: the job
        # builder DROPPED UpscaleModel, so fast sharpen silently ran as a
        # HALF-SIZE plain improve with no sharpening at all).
        $upscaleModel = $null
        if ($item.PSObject.Properties['UpscaleModel']) { $upscaleModel = [string]$item.UpscaleModel }
        if ($isFresh) {
            $status.Text = ("Re-rendering image {0} of {1} at {2} x {3}..." -f ($script:RefineTotal - $script:RefineQueue.Count), $script:RefineTotal, $item.W, $item.H)
            $log.AppendText(("`r`nRe-rendering from the same seed: {0}, same prompt, fresh full-quality sampling at {1} x {2} (no image-to-image - like a new generation; the composition can differ from the draft)" -f $item.Seed, $item.W, $item.H))
        } elseif (Test-MossFastPreview ([string]$item.File)) {
            $log.AppendText(("`r`nImproving: seed {0}, image-to-image from {1} ({2} x {3}) -> final {4} x {5} (strength {6} - fast preview, detail regenerated over the enlarged draft, composition kept from the image; ALL {7} denoising steps run at this strength - the engine step count was raised to {8} to get them){9}" -f $item.Seed, [System.IO.Path]::GetFileName([string]$item.File), $(if($item.SrcW){[int]$item.SrcW}else{0}), $(if($item.SrcH){[int]$item.SrcH}else{0}), $finalW, $finalH, $item.Strength, $refineSteps, $engineSteps, $(if($hiresScale -ge 1.5){(" - detail regeneration ON: base pass at {0} x {1}, highres second pass re-synthesizes sharp detail at {2} x {3}" -f [int]$item.SrcW,[int]$item.SrcH,$finalW,$finalH)}elseif($upscaleModel){(" - fast sharpen ON: single render pass at {0} x {1} (half size), then the upscaler model {2} sharpens/enlarges it to about {3} x {4} (an x4 model; output size follows the model)" -f $finalW,$finalH,(Split-Path -Leaf $upscaleModel),[int]($item.SrcW*2),[int]($item.SrcH*2))}else{''})))
        } else {
            $log.AppendText(("`r`nImproving: same seed {0}, same prompt, image-to-image from {1} ({2} x {3}) -> final {4} x {5} (strength {6}; ALL {7} denoising steps run at this strength - the engine step count was raised to {8} to get them){9}" -f $item.Seed, [System.IO.Path]::GetFileName([string]$item.File), $(if($item.SrcW){[int]$item.SrcW}else{0}), $(if($item.SrcH){[int]$item.SrcH}else{0}), $finalW, $finalH, $item.Strength, $refineSteps, $engineSteps, $(if($hiresScale -ge 1.5){(" - detail regeneration ON: base pass at {0} x {1}, highres second pass re-synthesizes sharp detail at {2} x {3}" -f [int]$item.SrcW,[int]$item.SrcH,$finalW,$finalH)}elseif($upscaleModel){(" - fast sharpen ON: single render pass at {0} x {1} (half size), then the upscaler model {2} sharpens/enlarges it to about {3} x {4} (an x4 model; output size follows the model)" -f $finalW,$finalH,(Split-Path -Leaf $upscaleModel),[int]($item.SrcW*2),[int]($item.SrcH*2))}else{''})))
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
            $bigAnswer=[System.Windows.Forms.MessageBox]::Show(("You are about to render {0} images in one batch. This can run for many hours (rough estimate: {1} h) and needs disk space for {0} images. Cancel stops it at any time, Pause freezes it and Resume continues later. Start now?" -f $n,$hours),'Large batch',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
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
        # Do not double the style prefix: a prompt picked from the history
        # dropdown already carries it (user saw 'photorealistic, lifelike...'
        # twice in the engine command line).
        $generationPrompt=if($stylePrefix -and -not $p.ToLowerInvariant().StartsWith($stylePrefix.ToLowerInvariant())){"$stylePrefix, $p"}else{$p}
        # Safe mode: friendly immediate message on the main path (the central
        # gate in Start-MossGeneration covers every other path).
        if ([bool]$script:Settings.SafeMode -and -not (Test-MossPromptSafe $generationPrompt)) {
            [System.Windows.Forms.MessageBox]::Show("Safe mode is ON: this prompt contains sexual or gore/violence terms, so nothing was generated.`r`n`r`nIf you meant to run this prompt: open Options... and UNTICK 'Safe mode', click Save, then generate again.","Blocked by Safe mode",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return
        }
        $gpuIndex=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $gpuIndex=[int]$script:Settings.PreferredGpuIndex } catch { $gpuIndex=-1 } }
        $speedMode=switch([string]$speedCombo.SelectedItem){'~2x faster (70%)'{'2x'}'~4x faster (50%)'{'4x'}default{'Exact'}}
        $negPrompt=[string]$script:Settings.NegativePrompt
        $samplingMethod=$null; if([string]$script:Settings.SamplingMethod -and [string]$script:Settings.SamplingMethod -ne 'Default (model)'){ $samplingMethod=[string]$script:Settings.SamplingMethod }
        $scheduler=$null; if([string]$script:Settings.Scheduler -and [string]$script:Settings.Scheduler -ne 'Default (model)'){ $scheduler=[string]$script:Settings.Scheduler }
        $job=[pscustomobject]@{Engine=$enginePath;Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$paths[1];Llm=$paths[2];Vae=$paths[3];Tokenizer=$paths[4];OutputPath=$outPath;Steps=$st;Cfg=$cf;Width=$wi;Height=$he;Count=$n;Seed=$baseSeed;Prompt=$generationPrompt;GpuIndex=$gpuIndex;SpeedMode=$speedMode;InitImage=$null;InitStrength=0.45;NegativePrompt=$negPrompt;SamplingMethod=$samplingMethod;Scheduler=$scheduler}
        $generate.Enabled=$false;$cancel.Enabled=$true;$btnPause.Enabled=$true;$btnPause.Text='Pause';$log.Clear();$status.Text='Starting engine...';Start-MossGeneration -Job $job
    })
    $cancel.Add_Click({
        if ($script:GenState.IsRunning) {
            $script:GenState.CancelRequested = $true
            $cancel.Enabled = $false
            $generate.Enabled = $false
            $btnPause.Enabled = $false
            $status.Text = 'Cancelling generation...'
            $log.AppendText("`r`nCancellation requested. Stopping the engine and any child processes...")
            $f.Refresh()
            Stop-MossGen
            $generate.Enabled = $true
            $cancel.Enabled = $false
            $elapsedText = if ($script:GenState.JobStartedAt) { Format-MossDuration ((Get-Date) - $script:GenState.JobStartedAt).TotalSeconds } else { '0:00' }
            $status.Text = "Generation cancelled | total elapsed $elapsedText"
            $prog.Visible = $false
            $log.AppendText("`r`nGeneration cancelled. No further images will be started.")
        }
    })
    $openOut.Add_Click({$folder=Get-AbsoluteAppPath $out.Text;if(Test-Path -LiteralPath $folder){Start-Process explorer.exe -ArgumentList (Quote-ProcessArgument $folder)}})
    $f.Add_FormClosing({if($script:GenState.IsRunning){$script:GenState.CancelRequested=$true;Stop-MossGen}})
    # v0.2.3: the window was already shown (frame + panels) before the
    # controls were added, so the Shown event has long passed by now: the
    # startup work is started explicitly instead of from the Shown event.
    $script:StartWindowWork={
        Hide-MossConsoleWindow
        # v0.2.4: the adapter scan runs on a BACKGROUND runspace - the UI
        # thread stays free while it works.
        try { Start-MossGpuScan } catch {}
        $script:GpuPollTimer=New-Object System.Windows.Forms.Timer
        $script:GpuPollTimer.Interval=120
        # The tick is a PLAIN scriptblock on purpose: $script: inside a
        # GetNewClosure can point at the closure's own module scope, which
        # made the refresh a no-op in an earlier attempt.
        $script:GpuPollTimer.Add_Tick({
            try {
                $null = & $script:RefreshGpuSubtitle
                if ([bool]$script:GpuScanDone) { try { $script:GpuPollTimer.Stop() } catch {} }
            } catch {}
        })
        $script:GpuPollTimer.Start()
        # The history prompt and the startup download offer are opened from a
        # short one-shot timer, NOT directly: a modal opened while the main
        # window is still in its first activation sequence gets buried once
        # the owner finishes activating. 40 ms later the window is fully
        # activated, so the owned modal sits on a stable foreground owner.
        # The timer lives on $script: because plain scriptblocks do NOT capture
        # enclosing locals: the handler's scope is gone by tick time and a
        # function-local timer was $null inside the tick (live-reproduced:
        # Stop() threw 'method on a null-valued expression' and nothing
        # after it ran).
        $script:StartupDialogTimer=New-Object System.Windows.Forms.Timer
        # The history prompt and the startup download offer are opened from a
        # short one-shot timer, NOT directly inside Shown: a modal opened
        # while the main window is still in its first activation sequence
        # gets buried once the owner finishes activating (the prompt was not
        # staying on top after opening MOSS). 200 ms later the window is
        # fully activated, so the owned modal sits on a stable foreground
        # owner - on top of MOSS and focused, without pinning above other apps.
        # The timer lives on $script: because plain scriptblocks do NOT capture
        # enclosing locals: the Shown handler's scope is gone by tick time and
        # a function-local timer was $null inside the tick (live-reproduced:
        # Stop() threw 'method on a null-valued expression' every 200 ms and
        # nothing after it ran).
        $script:StartupDialogTimer=New-Object System.Windows.Forms.Timer
        # v0.2.3: 200 ms -> 40 ms. The pause only existed so the owned dialog
        # would land on a stable foreground owner; the window is activated
        # explicitly right before the dialog is shown, so the long wait is not
        # needed any more.
        $script:StartupDialogTimer.Interval=40
        $script:StartupDialogTimer.Add_Tick({
            try {
                $script:StartupDialogTimer.Stop()
                try { $f.Activate() } catch {}
                Unlock-MossHistoryAfterShow
                Test-MossOfferStartupDownload $f
                try { & $script:RefreshGpuSubtitle } catch {
                    # v0.2.3: log instead of silently ignoring - the header then
                    # stays on 'GPU: detecting...' and the cause is invisible.
                    try { [void](Write-MossErrorLog 'GPU subtitle refresh failed' ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+"`r`n"+$_.Exception.GetType().FullName+': '+$_.Exception.Message+"`r`n"+$_.ScriptStackTrace)) } catch {}
                }
            } catch {
                # A failure here must never crash MOSS with the WinForms error
                # dialog - it is logged instead and startup continues.
                try { [void](Write-MossErrorLog 'Startup dialog error' ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+"`r`n"+$_.Exception.GetType().FullName+': '+$_.Exception.Message+"`r`n"+$_.ScriptStackTrace)) } catch {}
            }
        })
        $script:StartupDialogTimer.Start()
    }
    # v0.2.4: one layout pass for the whole window instead of one per added
    # control (the layout was suspended while the UI was built).
    try { $f.ResumeLayout($true) } catch {}
    try { $left.ResumeLayout($true) } catch {}
    try { $right.ResumeLayout($true) } catch {}
    # v0.2.3: run the window's message loop instead of ShowDialog - the form
    # is already visible from the early Show() above.
    try { Update-MossLeftActionLayout } catch {}
    # v0.2.3: start the startup dialogs (history prompt / download offer) and
    # the post-paint GPU name refresh. This must run BEFORE the message loop:
    # the winforms timer that drives it only ticks while the loop runs.
    try { & $script:StartWindowWork } catch { try { [void](Write-MossErrorLog 'Startup work failed' ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+"`r`n"+$_.Exception.GetType().FullName+': '+$_.Exception.Message+"`r`n"+$_.ScriptStackTrace)) } catch {} }
    [System.Windows.Forms.Application]::Run($f)
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
        Show-MossSetupDialog
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



















