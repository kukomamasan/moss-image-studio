# Sootglass Studio - portable hardware setup foundation
# Windows PowerShell 5.1 | All paths are resolved relative to this script.
[CmdletBinding()]
param([switch]$SetupOnly,[switch]$ReturnToGenerator)

$ErrorActionPreference = 'Stop'
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# The launcher console is hidden at the end of the definitions (just before
# any UI appears), so the password prompt and every window run without a
# visible console. Startup problems still surface: a top-level try/catch
# shows a message box and writes a log file.
$script:AppVersion = '0.3.44'
$script:ConfigDir = Join-Path $script:AppRoot 'config'
$script:ConfigFile = Join-Path $script:ConfigDir 'settings.json'
$script:Settings = [ordered]@{ Backend = 'Auto'; BackendSelectionSaved = $false; EnginePath = (Join-Path $script:AppRoot 'bin\sd-cli.exe'); HardwareSetupComplete = $false; ImageStyle = 'Photorealistic'; PreferredGpuIndex = -1; PreferredGpuName = ''; ShowEngineCommandLine = '1'; SafeMode = $false; PowerSaver = 'Off' }
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
$script:HistoryPlaintextEnabled = $false
# Cache of derived key material (PBKDF2, 250000 iterations): one full
# derivation takes a noticeable moment on the UI thread, and it used to run
# AGAIN for every single encrypt/decrypt - saving settings, writing each
# image sidecar, every wrong code attempt. Each new envelope also has its own
# random salt for HKDF key derivation, plus a random IV.
$script:MossKdfCache = @{}
$script:HistoryEnabled = $true
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- v0.2.2: dark theme for the native dropdowns --------------------------------
# WinForms draws a ComboBox with the WINDOWS theme whenever visual styles are
# enabled, so BackColor/ForeColor are IGNORED: every dropdown showed up as a
# bright white box inside the dark Sootglass window (Visual style, Resolution,
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


# SINGLE INSTANCE: launching the .bat twice would run two complete Sootglass apps
# against the SAME settings.json and output folder - the instances overwrite
# each other's settings and compete for the same GPU memory (renders fail
# out-of-memory). A named mutex makes the second launch refuse politely.
# Windows releases the mutex automatically when the process exits, even
# after a crash, so a stuck Sootglass can never lock the folder permanently.
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Sootglass-Studio-Instance')
$instanceAcquired = $false
try { $instanceAcquired = $script:InstanceMutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $instanceAcquired = $true }
if (-not $instanceAcquired) {
    [System.Windows.Forms.MessageBox]::Show('Sootglass is already running. Only one instance may use this folder at a time - two instances would overwrite each other''s settings and compete for the same GPU memory.','Sootglass Studio',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 0
}

function Hide-MossConsoleWindow {
    if(-not ('Moss.MossNativeWindow' -as [type])) {
        # v0.2.3: -MemberDefinition instead of -TypeDefinition. -TypeDefinition
        # launches the C# compiler as a separate process: ~310 ms on EVERY
        # Sootglass start. -MemberDefinition compiles the same three P/Invoke
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
    $dialog.ClientSize = New-Object System.Drawing.Size(440,220); $dialog.Font=New-Object System.Drawing.Font('Segoe UI',9); $dialog.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $dialog.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $label = New-Object System.Windows.Forms.Label; $label.Text = if ($Create) { "Choose a 4 to 16 character $Purpose code. Letters, numbers and symbols are allowed." } else { "Enter the $Purpose code." }; $label.Location=New-Object System.Drawing.Point(16,14); $label.Size=New-Object System.Drawing.Size(404,42); $dialog.Controls.Add($label)
    $first = New-Object System.Windows.Forms.TextBox; $first.Location=New-Object System.Drawing.Point(18,62); $first.Size=New-Object System.Drawing.Size(404,25); $first.AccessibleName="$Purpose code"; $first.TabIndex=0; $first.BackColor=[System.Drawing.Color]::FromArgb(24,30,42); $first.ForeColor=$dialog.ForeColor; $first.BorderStyle='FixedSingle'; $first.UseSystemPasswordChar=$true; $dialog.Controls.Add($first)
    $confirm = $null
    if ($Create) { $confirmLabel=New-Object System.Windows.Forms.Label; $confirmLabel.Text='Confirm code'; $confirmLabel.Location=New-Object System.Drawing.Point(18,91); $confirmLabel.Size=New-Object System.Drawing.Size(150,18); $dialog.Controls.Add($confirmLabel); $confirm = New-Object System.Windows.Forms.TextBox; $confirm.Location=New-Object System.Drawing.Point(18,111); $confirm.Size=New-Object System.Drawing.Size(404,25); $confirm.AccessibleName="Confirm $Purpose code"; $confirm.TabIndex=1; $confirm.BackColor=$first.BackColor; $confirm.ForeColor=$first.ForeColor; $confirm.BorderStyle='FixedSingle'; $confirm.UseSystemPasswordChar=$true; $dialog.Controls.Add($confirm) }
    $ok=New-Object System.Windows.Forms.Button; $ok.Text='Continue'; $ok.Location=New-Object System.Drawing.Point(186,166); $ok.Size=New-Object System.Drawing.Size(112,34); $ok.TabIndex=2; $ok.FlatStyle='Flat'; $ok.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $ok.ForeColor=[System.Drawing.Color]::White; $ok.DialogResult=[System.Windows.Forms.DialogResult]::OK; $dialog.Controls.Add($ok)
    $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Cancel'; $cancel.Location=New-Object System.Drawing.Point(310,166); $cancel.Size=New-Object System.Drawing.Size(112,34); $cancel.TabIndex=3; $cancel.FlatStyle='Flat'; $cancel.BackColor=[System.Drawing.Color]::FromArgb(38,48,65); $cancel.ForeColor=$dialog.ForeColor; $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $dialog.Controls.Add($cancel); $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
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
    $f=New-Object System.Windows.Forms.Form; $f.Text='Prompt history options'; $f.ClientSize=New-Object System.Drawing.Size(520,270); $f.Font=New-Object System.Drawing.Font('Segoe UI',9); $f.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $f.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $f.StartPosition='CenterScreen'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false
    $label=New-Object System.Windows.Forms.Label; $label.Text='The code was not accepted. Choose how Sootglass should continue. Turning off the code discards the locked history; future history will be saved unencrypted.'; $label.Location=New-Object System.Drawing.Point(18,12); $label.Size=New-Object System.Drawing.Size(484,52); $f.Controls.Add($label)
    $items=@(@('Try again','retry'),@('Continue without history','skip'),@('Turn off password for prompt history','plaintext'),@('Set a new code','reset'),@('Turn off prompt history','disable'))
    $positions=@(@(18,72),@(266,72),@(18,122),@(266,122),@(18,172))
    for($i=0;$i -lt $items.Count;$i++) { $b=New-Object System.Windows.Forms.Button; $b.Text=$items[$i][0]; $b.Location=New-Object System.Drawing.Point($positions[$i][0],$positions[$i][1]); $b.Size=New-Object System.Drawing.Size(236,40); $b.TabIndex=$i; $b.AccessibleName=[string]$items[$i][0]; $b.FlatStyle='Flat'; $b.BackColor=[System.Drawing.Color]::FromArgb(38,48,65); $b.ForeColor=$f.ForeColor; $choiceTag=[string]$items[$i][1]; $b.Add_Click({$f.Tag=$choiceTag;$f.Close()}.GetNewClosure()); $f.Controls.Add($b) }
    try { [void]$f.ShowDialog(); if($f.Tag){return [string]$f.Tag}; return 'skip' } finally { $f.Dispose() }
}

function Get-MossPayloadV2Keys([byte[]]$MasterKey,[byte[]]$Salt) {
    # HKDF-SHA512: give each envelope independent encryption and MAC keys
    # without repeating the expensive password derivation for every sidecar.
    $extract=[System.Security.Cryptography.HMACSHA512]::new($Salt)
    try { $prk=$extract.ComputeHash($MasterKey) } finally { $extract.Dispose() }
    $expand=[System.Security.Cryptography.HMACSHA512]::new([byte[]]$prk)
    try {
        $info=[System.Text.Encoding]::UTF8.GetBytes('Sootglass-PAYLOAD-V2')
        $input=New-Object byte[] ($info.Length+1)
        [System.Buffer]::BlockCopy($info,0,$input,0,$info.Length)
        $input[$input.Length-1]=1
        return $expand.ComputeHash($input)
    } finally { $expand.Dispose() }
}

function Protect-MossPayload([string]$Text,[string]$Password) {
    $iterations=250000
    # Cache only the expensive password-derived master key. The distinct
    # per-envelope salt feeds HKDF, so separate payloads never reuse keys.
    $cacheKey='protect-v2|'+[string]$Password
    $cached=$script:MossKdfCache[$cacheKey]
    if ($null -eq $cached) {
        $masterSalt=New-Object byte[] 16
        $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($masterSalt) } finally { $rng.Dispose() }
        $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$masterSalt,$iterations)
        try { $masterKey=$derive.GetBytes(64) } finally { $derive.Dispose() }
        $cached=@{ Salt=$masterSalt; Keys=$masterKey }
        $script:MossKdfCache[$cacheKey]=$cached
    }
    $masterSalt=[byte[]]$cached.Salt
    $masterKey=[byte[]]$cached.Keys
    $salt=New-Object byte[] 16
    $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $keys=Get-MossPayloadV2Keys $masterKey $salt
    $iv=New-Object byte[] 16; $rngIv=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $rngIv.GetBytes($iv); $rngIv.Dispose()
    $aes=[System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Mode=[System.Security.Cryptography.CipherMode]::CBC; $aes.Padding=[System.Security.Cryptography.PaddingMode]::PKCS7; $aes.Key=$keys[0..31]; $aes.IV=$iv
    try { $enc=$aes.CreateEncryptor(); try { $cipher=$enc.TransformFinalBlock([System.Text.Encoding]::UTF8.GetBytes($Text),0,[System.Text.Encoding]::UTF8.GetByteCount($Text)) } finally { $enc.Dispose() } } finally { $aes.Dispose() }
    $authData=New-Object byte[] ($salt.Length+$iv.Length+$cipher.Length); [System.Buffer]::BlockCopy($salt,0,$authData,0,$salt.Length); [System.Buffer]::BlockCopy($iv,0,$authData,$salt.Length,$iv.Length); [System.Buffer]::BlockCopy($cipher,0,$authData,$salt.Length+$iv.Length,$cipher.Length)
    $hmac=[System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys[32..63]); try { $mac=$hmac.ComputeHash($authData) } finally { $hmac.Dispose() }
    return ([ordered]@{ Version=2; Iterations=$iterations; KdfSalt=[Convert]::ToBase64String($masterSalt); Salt=[Convert]::ToBase64String($salt); IV=[Convert]::ToBase64String($iv); Ciphertext=[Convert]::ToBase64String($cipher); MAC=[Convert]::ToBase64String($mac) } | ConvertTo-Json -Compress)
}

function Unprotect-MossPayload([string]$EnvelopeText,[string]$Password) {
    $envelope=$EnvelopeText | ConvertFrom-Json
    $version=[int]$envelope.Version
    if ($version -notin @(1,2) -or [int]$envelope.Iterations -lt 100000 -or [int]$envelope.Iterations -gt 1000000) { throw 'Unsupported encrypted history format.' }
    $salt=[Convert]::FromBase64String([string]$envelope.Salt); $iv=[Convert]::FromBase64String([string]$envelope.IV); $cipher=[Convert]::FromBase64String([string]$envelope.Ciphertext); $expected=[Convert]::FromBase64String([string]$envelope.MAC)
    if ($version -eq 1) {
        # Existing saved history and sidecars use PBKDF2 directly with Salt.
        $cacheKey='unprotect-v1|'+[string]$Password+'|'+[string]$envelope.Salt+'|'+[int]$envelope.Iterations
        $keys=$script:MossKdfCache[$cacheKey]
        if ($null -eq $keys) {
            $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$salt,[int]$envelope.Iterations)
            try { $keys=$derive.GetBytes(64) } finally { $derive.Dispose() }
            $script:MossKdfCache[$cacheKey]=[byte[]]$keys
        }
    } else {
        $kdfSalt=[Convert]::FromBase64String([string]$envelope.KdfSalt)
        $cacheKey='unprotect-v2|'+[string]$Password+'|'+[string]$envelope.KdfSalt+'|'+[int]$envelope.Iterations
        $masterKey=$script:MossKdfCache[$cacheKey]
        if ($null -eq $masterKey) {
            $derive=[System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password,$kdfSalt,[int]$envelope.Iterations)
            try { $masterKey=$derive.GetBytes(64) } finally { $derive.Dispose() }
            $script:MossKdfCache[$cacheKey]=[byte[]]$masterKey
        }
        $keys=Get-MossPayloadV2Keys ([byte[]]$masterKey) $salt
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
    $script:HistoryPasswordVerifier=Protect-MossPayload 'Sootglass-HISTORY-PASSWORD-CHECK-V1' $newPassword
    # The old code's cached key material is dead weight after a reset.
    $script:MossKdfCache.Clear()
    $script:HistoryLocked=$false
    $script:LockedHistoryEnvelope=$null
    $script:HistoryEnabled=$true
    $script:HistoryPlaintextEnabled=$false
    $script:Settings.PromptHistory=@()
    return (Save-Settings)
}

function Disable-MossHistoryPassword {
    $answer=[System.Windows.Forms.MessageBox]::Show('The existing encrypted history cannot be unlocked without its code and will be deleted. Future recent prompts will be saved in plain text in settings.json. Turn off the code and continue?','Turn off history code',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $script:HistoryPassphrase=$null
    $script:HistoryPasswordVerifier=$null
    $script:HistoryLocked=$false
    $script:LockedHistoryEnvelope=$null
    $script:HistoryEnabled=$true
    $script:HistoryPlaintextEnabled=$true
    $script:MossKdfCache.Clear()
    $script:Settings.PromptHistory=@()
    return (Save-Settings)
}

function Disable-MossHistory {
    $answer=[System.Windows.Forms.MessageBox]::Show('This permanently deletes saved prompt history and stops Sootglass from storing future prompts. Continue?','Turn off prompt history',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $script:HistoryEnabled=$false
    $script:HistoryLocked=$false
    $script:LockedHistoryEnvelope=$null
    $script:HistoryPassphrase=$null
    $script:HistoryPasswordVerifier=$null
    $script:HistoryPlaintextEnabled=$false
    $script:MossKdfCache.Clear()
    $script:Settings.PromptHistory=@()
    return (Save-Settings)
}

function Load-Settings([switch]$UnlockHistory) {
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
            # Old settings files can still carry keys of removed features (e.g. the
            # improve subsystem). Unknown keys are simply ignored - they are not
            # copied into the live settings and not written back on save.
            $ignoredKeys = @('PromptHistory','PromptHistoryProtected','HistoryPasswordVerifier','PromptHistoryEnabled','PromptHistoryPlaintextEnabled','AdultAccessVerifier','AdultCodeSetup','ChildProfiles','SharpenFinish','EnhanceVarySeed','HideRenderCopies','ImproveStrength')
            foreach ($p in $saved.PSObject.Properties) {
                if ($p.Name -notin $ignoredKeys) { $script:Settings[$p.Name] = $p.Value }
            }
            if ($saved.HistoryPasswordVerifier) { $script:HistoryPasswordVerifier=[string]$saved.HistoryPasswordVerifier }
            if ($saved.PSObject.Properties.Name -contains 'PromptHistoryEnabled') { $script:HistoryEnabled=[bool]$saved.PromptHistoryEnabled }
            if ($saved.PSObject.Properties.Name -contains 'PromptHistoryPlaintextEnabled') { $script:HistoryPlaintextEnabled=[bool]$saved.PromptHistoryPlaintextEnabled }
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
                    if($choice -eq 'plaintext'){if(Disable-MossHistoryPassword){return};continue}
                }
            } elseif ($script:HistoryEnabled -and $script:HistoryPlaintextEnabled -and $saved.PSObject.Properties.Name -contains 'PromptHistory') {
                $script:Settings.PromptHistory = @($saved.PromptHistory)
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
    $persist.PromptHistoryPlaintextEnabled=[bool]($script:HistoryEnabled -and $script:HistoryPlaintextEnabled -and -not $script:HistoryLocked)
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
    } elseif ($script:HistoryPlaintextEnabled) {
        $persist.PromptHistory = $history
    } else {
        # Without a configured history code, recent prompts stay in memory
        # for this session only and are never written to settings.json.
    }
    $persist | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    return $true
}

function Reset-MossSettings([System.Windows.Forms.Form]$Owner) {
    $answer=[System.Windows.Forms.MessageBox]::Show('Reset all Sootglass settings to their defaults? Sootglass will close so the defaults can be applied on the next launch. Model files, generated images, and saved prompt history/password will be preserved. Any active generation must finish first.','Reset all settings',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    if($script:GenState -and $script:GenState.IsRunning){
        [System.Windows.Forms.MessageBox]::Show('Wait until the current generation finishes before resetting settings.','Generation in progress',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        return $false
    }
    try {
        $preserved=[ordered]@{}
        if(Test-Path -LiteralPath $script:ConfigFile){
            $saved=Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            # Preserve encrypted history only; legacy plaintext prompts are
            # intentionally discarded when settings are reset.
            $historyKeys=@('PromptHistoryEnabled','PromptHistoryProtected','HistoryPasswordVerifier')
            foreach($key in $historyKeys){
                if($saved.PSObject.Properties.Name -contains $key){$preserved[$key]=$saved.$key}
            }
            if($saved.PromptHistoryPlaintextEnabled){
                $preserved.PromptHistoryPlaintextEnabled=$true
                if($saved.PSObject.Properties.Name -contains 'PromptHistory'){$preserved.PromptHistory=@($saved.PromptHistory)}
            }
        }
        if(-not(Test-Path -LiteralPath $script:ConfigDir)){New-Item -ItemType Directory -Path $script:ConfigDir -Force -ErrorAction Stop|Out-Null}
        $json=ConvertTo-Json -InputObject $preserved -Depth 5
        Set-Content -LiteralPath $script:ConfigFile -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show(("Settings could not be reset. Your current settings were not intentionally changed.`r`n`r`n"+$_.Exception.Message),'Reset failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        return $false
    }
    [System.Windows.Forms.MessageBox]::Show('Settings are reset. Sootglass will now close; launch it again to use the defaults.','Settings reset',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    $Owner.Tag='RESETSETTINGS'
    $Owner.Close()
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
# right after the window appeared, so Sootglass froze for a moment exactly when
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
$form.Text = "Sootglass Studio v$($script:AppVersion) | Hardware Setup"
$form.ClientSize = New-Object System.Drawing.Size(884,680)
# Keep the four footer actions and selection rows clear at the minimum size.
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(18,22,31)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230,236,245)
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)

$header = New-Object System.Windows.Forms.Panel
$header.Dock='Top'; $header.Height=76; $header.BackColor=[System.Drawing.Color]::FromArgb(25,32,45)
$form.Controls.Add($header)
$title = New-Object System.Windows.Forms.Label
$title.Text="Sootglass  /  IMAGE STUDIO  v$($script:AppVersion)"; $title.Font=New-Object System.Drawing.Font('Segoe UI Semibold',17,[System.Drawing.FontStyle]::Bold)
$title.AutoSize=$true; $title.Location=New-Object System.Drawing.Point(22,12); $header.Controls.Add($title)
$sub = New-Object System.Windows.Forms.Label
$sub.Text='PORTABLE HARDWARE CONFIGURATION'; $sub.ForeColor=[System.Drawing.Color]::FromArgb(142,158,181)
$sub.AutoSize=$true; $sub.Location=New-Object System.Drawing.Point(25,([Math]::Max(47,$title.Bottom+4))); $header.Controls.Add($sub)
$header.Height=[Math]::Max(76,$sub.Bottom+14)

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
$recommend.Location=New-Object System.Drawing.Point(24,410); $recommend.Size=New-Object System.Drawing.Size(836,36); $recommend.Anchor='Top,Left,Right'
$recommend.Font=New-Object System.Drawing.Font('Segoe UI Semibold',10,[System.Drawing.FontStyle]::Bold)
$recommend.Text="Recommended starting backend: $($script:RecommendedBackend)  (based on non-virtual adapter vendor only)"
$form.Controls.Add($recommend)

$backendLabel=New-Object System.Windows.Forms.Label; $backendLabel.Text='Generation backend:'; $backendLabel.Location=New-Object System.Drawing.Point(24,452); $backendLabel.AutoSize=$true; $form.Controls.Add($backendLabel)
$backend=New-Object System.Windows.Forms.ComboBox
$backend.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList
$backend.Location=New-Object System.Drawing.Point(365,448)
$backend.Size=New-Object System.Drawing.Size(495,30)
$backend.Anchor='Top,Left,Right'; $backend.AccessibleName='Generation backend'; $backend.AccessibleDescription='Override the recommended backend to match your engine build.'; $backend.TabIndex=1
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
$gpuLabel=New-Object System.Windows.Forms.Label; $gpuLabel.Text='Generation GPU:'; $gpuLabel.Location=New-Object System.Drawing.Point(24,496); $gpuLabel.AutoSize=$true; $form.Controls.Add($gpuLabel)
$gpu=New-Object System.Windows.Forms.ComboBox
$gpu.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList
$gpu.Location=New-Object System.Drawing.Point(365,492)
$gpu.Size=New-Object System.Drawing.Size(495,30)
$gpu.Anchor='Top,Left,Right'; $gpu.AccessibleName='Generation GPU'; $gpu.TabIndex=2
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
    $d.Filter = 'Sootglass engine (sd-cli.exe)|sd-cli.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*'
    $d.Title = 'Select the Sootglass engine executable'
    $d.CheckFileExists = $true
    $d.CheckPathExists = $true
    $d.RestoreDirectory = $true

    # Start browsing beside the currently suggested/selected engine path.
    # If that folder is unavailable, fall back to this portable install's bin folder.
    # Relative stored paths are anchored to the Sootglass folder, not to wherever
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

$note=New-Object System.Windows.Forms.Label; $note.Location=New-Object System.Drawing.Point(24,572); $note.Size=New-Object System.Drawing.Size(836,40); $note.Anchor='Top,Left,Right'; $note.ForeColor=[System.Drawing.Color]::FromArgb(150,166,190)
$note.Text='Note: display enumeration cannot prove CUDA / ROCm / SYCL support. The selected sd-cli.exe must be compiled for the chosen backend.'; $form.Controls.Add($note)

$refresh=New-Object System.Windows.Forms.Button; $refresh.Text='Rescan hardware'; $refresh.Location=New-Object System.Drawing.Point(24,612); $refresh.Size=New-Object System.Drawing.Size(130,32); $refresh.Anchor='Bottom,Left'; $form.Controls.Add($refresh)
$setupHistoryCode=New-Object System.Windows.Forms.Button; $setupHistoryCode.Text='Set / reset history code'; $setupHistoryCode.Location=New-Object System.Drawing.Point(350,612); $setupHistoryCode.Size=New-Object System.Drawing.Size(190,32); $setupHistoryCode.Anchor='Bottom,Left'; $form.Controls.Add($setupHistoryCode)
$setupHistoryCode.Add_Click({ if(Reset-MossHistoryPassword $form){[System.Windows.Forms.MessageBox]::Show('New history code saved. No prompt history is stored yet.','History code',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null} })
$test=New-Object System.Windows.Forms.Button; $test.Text='Check backend support'; $test.Location=New-Object System.Drawing.Point(166,612); $test.Size=New-Object System.Drawing.Size(170,32); $test.Anchor='Bottom,Left'; $form.Controls.Add($test)
$save=New-Object System.Windows.Forms.Button; $save.Text='Save setup'; $save.Location=New-Object System.Drawing.Point(720,612); $save.Size=New-Object System.Drawing.Size(140,32); $save.Anchor='Bottom,Right'; $save.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $save.ForeColor=[System.Drawing.Color]::White; $save.FlatStyle='Flat'; $form.Controls.Add($save)
$refresh.Add_Click({ [System.Windows.Forms.MessageBox]::Show('Close and reopen Sootglass Studio to perform a fresh hardware scan.','Hardware scan',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null; $form.Close() })
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
    # Relative engine paths must be anchored to the Sootglass folder, NOT to the
    # process working directory: Sootglass can be started with any working
    # directory (launcher chain, terminal, shortcut) - the generation paths
    # are already anchored this way, and this check used to fail with
    # 'engine executable was not found' purely because of WHERE Sootglass was
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
    # Anchor relative paths to the Sootglass folder before checking/storage (same
    # reason as the backend check above - the working directory must not
    # matter), and store the engine path relative when it lives inside the
    # Sootglass folder so the install stays movable.
    $engineAbs = Get-AbsoluteAppPath ($engine.Text.Trim())
    $script:Settings.EnginePath=Get-RelativeAppPath $engineAbs
    $script:Settings.HardwareSetupComplete=$true
    Save-Settings
    $savedBackend = [string]$script:Settings.Backend
    $gpuSavedText = if([int]$script:Settings.PreferredGpuIndex -ge 0){ "  |  GPU: $($script:Settings.PreferredGpuName)" } else { '  |  GPU: automatic' }
    $backendDisplay = "Backend: $savedBackend$gpuSavedText"
    $msg="Settings saved to:`r`n$script:ConfigFile`r`n`r`n$backendDisplay`r`nEngine: $($script:Settings.EnginePath)"
    if (-not (Test-Path -LiteralPath $engineAbs -PathType Leaf)) { $msg += "`r`n`r`nWARNING: Engine executable not found at this path ($engineAbs). You can browse to it later." }
    [System.Windows.Forms.MessageBox]::Show($msg,'Sootglass setup saved',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $form.Close()
})

# Explicit keyboard order follows the form from adapter list to saved setup.
$grid.AccessibleName='Detected display adapters'; $grid.TabIndex=0
$grid.AllowUserToResizeRows=$false
$grid.DefaultCellStyle.WrapMode=[System.Windows.Forms.DataGridViewTriState]::True
$grid.AutoSizeRowsMode='AllCells'; $grid.ColumnHeadersHeightSizeMode='AutoSize'
$grid.Columns['Name'].FillWeight=27; $grid.Columns['Vendor'].FillWeight=12
$grid.Columns['Type'].FillWeight=35; $grid.Columns['SuggestedBackend'].FillWeight=26
$intro.Anchor='Top,Left,Right'
$engine.AccessibleName='Engine executable path'; $engine.TabIndex=3
$engine.BackColor=[System.Drawing.Color]::FromArgb(24,30,42); $engine.ForeColor=$form.ForeColor; $engine.BorderStyle='FixedSingle'
$browse.AccessibleName='Browse for engine executable'; $browse.TabIndex=4
$refresh.TabIndex=5; $test.TabIndex=6; $setupHistoryCode.TabIndex=7; $save.TabIndex=8
foreach($action in @($browse,$refresh,$test,$setupHistoryCode,$save)) {
    $action.FlatStyle='Flat'; $action.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(65,80,101)
    if($action -ne $save){ $action.BackColor=[System.Drawing.Color]::FromArgb(38,48,65); $action.ForeColor=$form.ForeColor }
}
foreach($action in @($refresh,$test,$setupHistoryCode,$save)) { $action.Top=628; $action.Height=34 }

$form.Add_Shown({ if (-not $script:Settings.HardwareSetupComplete) { [System.Windows.Forms.MessageBox]::Show('Welcome to Sootglass Studio. Review the detected adapters and choose the backend that matches your engine build.','First-run setup',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null } })
[void]$form.ShowDialog()
}

# ---------------- IMAGE GENERATOR ----------------
function Test-MossPromptHardSafety([string]$Prompt) {
    # Non-optional safeguard: never generate prompts that sexualize minors.
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $true }
    $sexualTerms = @('nsfw','nude','nudes','nudity','naked','porn','pornographic','xxx','erotic','sex','sexual','sexually','sexy','fuck','fucking','cum','cumming','penis','vagina','pussy','cock','tits','titties','boobs','breasts','nipples','areola','topless','bottomless','undressed','undressing','anal','blowjob','handjob','gangbang','bdsm','bondage','fetish','hentai','masturbat','orgasm','horny','aroused','explicit','lewd','suggestive','lingerie','seductive','striptease','stripping','g-string','buttocks','thong')
    $sexualPattern = '(?i)\b(' + (($sexualTerms | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
    $explicitPattern = '(?i)\b(nudes?|nudity|naked|sex(?:ual|ually)?|porn(?:ographic)?|xxx|explicit|erotic|hentai|lewd|topless|bottomless|undressed|undressing)\b'
    $strictMinorPattern = '(?i)\b(child|children|kid|kids|preteen|tween|schoolgirl|schoolboy|underage|loli|lolicon|shota|shotacon)\b'
    $teenPattern = '(?i)\b(teen|teens|teenage|teenager)\b'
    $adultAgePattern = '(?i)\b(?:18\s*\+|18\s+(?:and\s+above|or\s+older)|(?:18|19|[2-9]\d)\s*(?:years?\s*old|yo)\b|adult(?:s)?\s*(?:18\s*\+|only|aged?\s*18\s*\+))'
    if ($Prompt -match $strictMinorPattern -and $Prompt -match $sexualPattern) { return $false }
    if ($Prompt -match $teenPattern -and $Prompt -match $explicitPattern -and $Prompt -notmatch $adultAgePattern) { return $false }
    if ($Prompt -match '(?i)\b(loli|lolicon|shota|shotacon|jailbait)\b') { return $false }
    return $true
}

function Test-MossPromptSafe([string]$Prompt) {
    # Optional content filter: general sexual, graphic violence/gore, and
    # self-harm terms are checked only when its checkbox is enabled. Minor
    # safety is handled independently by Test-MossPromptHardSafety.
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
    # Non-optional age-safety floor is separate from this optional filter.
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
        SecondsPerImage = [Math]::Round([double]$SecondsPerImage, 2); Images = [int]$Images
    }
    [void]$list.Add($entry)
    while ($list.Count -gt 400) { $list.RemoveAt(0) }
    Save-MossBenchmarks $list
}

function Get-MossBenchmarkEstimate {
    # Seconds-per-image extrapolated from the benchmark store.
    param([int]$W, [int]$H, [string]$SpeedMode, [int]$Steps, [bool]$IsImg2Img)
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

function Get-MossSidecarPath([string]$ImagePath) {
    # Where a NEW per-image sidecar is written: '<image folder>\metadata\
    # <name>.json'. The output folder therefore only shows the pictures;
    # the JSON sidecars (seed/prompt/settings that power re-render info and
    # the Info dialog) live in their own subfolder. Returns
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
    # picture is RENAMED or MOVED outside Sootglass (the sidecar is named after
    # the picture), or when a picture was deleted by hand. Only Sootglass's own
    # sidecars are considered; the sidecar matching THIS image is skipped.
    $result = New-Object System.Collections.ArrayList
    $dir = [System.IO.Path]::GetDirectoryName([string]$ImagePath)
    if ([string]::IsNullOrEmpty($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $result.ToArray() }
    $imgName = [System.IO.Path]::GetFileNameWithoutExtension([string]$ImagePath)
    $seen = @{}
    foreach ($loc in @((Join-Path $dir 'metadata'), $dir)) {
        if (-not (Test-Path -LiteralPath $loc -PathType Container)) { continue }
        foreach ($js in @(Get-ChildItem -LiteralPath $loc -Filter 'MOSS_*.json' -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $loc -Filter 'Sootglass_*.json' -File -ErrorAction SilentlyContinue)) {
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
    # the adoption offer on every sidecar adoption even for images WITH a sidecar.
    return $result.ToArray()
}

# v0.3.1: orphaned-sidecar adoption offer was REMOVED. The function
# Approve-MossSidecarAdoption had zero callers (dead code since v0.2.13).
# Get-MossOrphanSidecars stays: it is still used for diagnostics.

# v0.3.1: script-scoped summary updater for the Model files dialog.
# The old nested function was invisible to the browse-button closures
# (GetNewClosure) - cancelling the file picker crashed the app.
function Update-MossDlgSummaryBoxes($Boxes,$SummaryLabel) {
    $check=@((Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)))
    foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $check+=(Get-AbsoluteAppPath ([string]$Boxes[$k].Text)) }
    $missing=@($check | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if($missing.Count -eq 0){ $SummaryLabel.Text='All 5 engine/model files found.'; $SummaryLabel.ForeColor=[System.Drawing.Color]::FromArgb(125,205,164) }
    else { $SummaryLabel.Text=('{0} of 5 engine/model file(s) not found.' -f $missing.Count); $SummaryLabel.ForeColor=[System.Drawing.Color]::FromArgb(224,138,138) }
}

# v0.3.1: remember the generator window position. Before this, closing the
# generator for the Hardware / Setup round-trip (Options -> Hardware / Setup
# closes the generator and a new setup process opens) restarted the window
# CenterScreen on the PRIMARY monitor - the window 'teleported' away from
# where the user had it (e.g. a secondary portrait monitor).
function Save-MossWindowBounds($form) {
    try {
        $max = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
        $b = if ($max) { $form.RestoreBounds } else { $form.Bounds }
        $script:Settings.WindowBounds = ('{0},{1},{2},{3}' -f [int]$b.X,[int]$b.Y,[int]$b.Width,[int]$b.Height)
        $script:Settings.WindowMaximized = [bool]$max
        Save-Settings | Out-Null
    } catch { try { [void](Write-MossErrorLog 'Save window bounds failed' ($_.Exception.Message)) } catch {} }
}
function Restore-MossWindowBounds($form) {
    $raw = [string]$script:Settings.WindowBounds
    if (-not $raw) {
        # v0.3.12: fresh install (no saved window yet) starts at the SMALLEST
        # size the UI supports - the same size users get by shrinking to the
        # minimum - instead of the large design size.
        try { $form.Size = $form.MinimumSize } catch {}
        return
    }
    $p = $raw -split ','
    if ($p.Count -ne 4) { return }
    $x=0;$y=0;$w=0;$h=0
    if (-not ([int]::TryParse($p[0],[ref]$x))) { return }
    if (-not ([int]::TryParse($p[1],[ref]$y))) { return }
    if (-not ([int]::TryParse($p[2],[ref]$w))) { return }
    if (-not ([int]::TryParse($p[3],[ref]$h))) { return }
    if ($w -lt 400 -or $h -lt 300) { return }
    # Restore only onto the working area (taskbars/docked bars excluded) and
    # clamp both size and position so a stale saved rectangle cannot spill
    # onto another monitor.
    $targetScreen=$null; $bestArea=0
    foreach($s in [System.Windows.Forms.Screen]::AllScreens){
        $r=$s.WorkingArea
        $iw=[Math]::Max(0,[Math]::Min($x+$w,$r.Right)-[Math]::Max($x,$r.Left))
        $ih=[Math]::Max(0,[Math]::Min($y+$h,$r.Bottom)-[Math]::Max($y,$r.Top))
        $area=$iw*$ih
        if($area -gt $bestArea){$bestArea=$area;$targetScreen=$s}
    }
    if(-not $targetScreen){return}
    $wa=$targetScreen.WorkingArea
    $w=[Math]::Min($w,[Math]::Max(400,$wa.Width))
    $h=[Math]::Min($h,[Math]::Max(300,$wa.Height))
    $x=[Math]::Max($wa.Left,[Math]::Min($x,$wa.Right-$w))
    $y=[Math]::Max($wa.Top,[Math]::Min($y,$wa.Bottom-$h))
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point($x,$y)
    $form.Size = New-Object System.Drawing.Size($w,$h)
    if ([bool]$script:Settings.WindowMaximized) {
        # Maximize AFTER the first show: the Location above decides which
        # screen the maximized state lands on.
        $form.Add_Shown({ try { $this.WindowState = [System.Windows.Forms.FormWindowState]::Maximized } catch {} })
    }
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

# v0.3.44: every generation's raw engine output is kept in logs\run-*.txt
# (successes and failures alike). The pre-flight VRAM check mines these for
# the engine's own 'tracked weights' figure - how much VRAM the SAME model
# pair actually occupied in a past run - which is far more accurate than the
# on-disk file-size estimate (convrot/int8 conversion, skipped tensors and
# LoRA patches change what really lands in VRAM). Oldest run logs are pruned
# to keep the folder bounded.
function Write-MossRunLog([string]$Stdout,[string]$Stderr) {
    try {
        $logDir = Join-Path $script:AppRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $file = Join-Path $logDir ('run-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
        ("--- STDOUT ---`r`n$Stdout`r`n--- STDERR ---`r`n$Stderr") | Set-Content -LiteralPath $file -Encoding UTF8
        $old = Get-ChildItem -LiteralPath $logDir -Filter 'run-*.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Skip 20
        foreach ($stale in $old) { Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue }
        return $file
    } catch { return $null }
}

function Get-MossTrackedWeightsMB([string[]]$ModelLeafNames) {
    # Returns the highest 'tracked weights' value (MB) from the most recent
    # past run log that loaded ALL of the given model files, or 0 when no
    # matching log exists. Scans run-*.txt first (newest to oldest, capped),
    # then error-*.txt so existing failure history still contributes.
    try {
        $logDir = Join-Path $script:AppRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { return 0 }
        $candidates = @()
        $candidates += @(Get-ChildItem -LiteralPath $logDir -Filter 'run-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 12)
        $candidates += @(Get-ChildItem -LiteralPath $logDir -Filter 'error-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 12)
        foreach ($lg in $candidates) {
            try {
                if ($lg.Length -gt 4MB) { continue }
                $text = [System.IO.File]::ReadAllText($lg.FullName)
                $allLoaded = $true
                foreach ($leaf in $ModelLeafNames) {
                    if ([string]::IsNullOrWhiteSpace($leaf) -or -not $text.Contains($leaf)) { $allLoaded = $false; break }
                }
                if (-not $allLoaded) { continue }
                $m = [regex]::Matches($text, 'tracked weights\s+([0-9.]+)\s*MB')
                if ($m.Count -gt 0) {
                    $v = 0.0
                    if ([double]::TryParse($m[$m.Count - 1].Groups[1].Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
                        return [Math]::Round($v)
                    }
                }
            } catch { continue }
        }
    } catch {}
    return 0
}

function Get-AbsoluteAppPath([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    if ([System.IO.Path]::IsPathRooted($value)) { return [System.IO.Path]::GetFullPath($value) }
    return [System.IO.Path]::GetFullPath((Join-Path $script:AppRoot $value))
}
function Format-MossModelSize([object]$Value,[int]$Digits=2) {
    $bytes=[int64]0
    if ($null -eq $Value -or -not [int64]::TryParse([string]$Value,[System.Globalization.NumberStyles]::Integer,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$bytes) -or $bytes -lt 0) {
        return 'size unavailable'
    }
    $gigabytes=$bytes/1073741824.0
    return ([Math]::Round($gigabytes,$Digits).ToString([System.Globalization.CultureInfo]::InvariantCulture)+' GB')
}
# v0.3.8: the LoRA folder is optional - create it at startup so the user has
# somewhere obvious to drop .safetensors files (never filled automatically).
function Ensure-MossLoraDir {
    $dir = Get-AbsoluteAppPath ([string]$script:Settings.LoraDir)
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    if (-not (Test-Path -LiteralPath $dir)) { try { [void][System.IO.Directory]::CreateDirectory($dir) } catch { return '' } }
    return $dir
}
# List LoRA stems usable in <lora:stem:strength> prompt tags: *.safetensors
# under the LoRA dir, stems must match [^:>]+ (the engine's tag regex would
# break otherwise). Returns stem|path pairs.
function Get-MossLoraFiles {
    $dir = Ensure-MossLoraDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
    try {
        return @(Get-ChildItem -LiteralPath $dir -Filter '*.safetensors' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^[^:>]+$' } |
            ForEach-Object { [pscustomobject]@{ Stem = $_.BaseName; Path = $_.FullName } })
    } catch { return @() }
}
# v0.3.10: catalog of OPTIONAL LoRA downloads published by Comfy-Org for
# Sootglass (repo Comfy-Org/MOSS-Image, folder loras/). The list is read from the
# Hugging Face API, so newly published LoRAs show up without a Sootglass update.
# Metadata only - no file is downloaded here.
function Get-MossLoraCatalog {
    $repo='Comfy-Org/MOSS-Image'
    $items=@()
    try {
        $treeRaw=Invoke-RestMethod -Uri ('https://huggingface.co/api/models/'+$repo+'/tree/main?recursive=true') -Headers @{Accept='application/json';'User-Agent'='Sootglass-Studio'} -TimeoutSec 20
        $tree=@($treeRaw)
        # PS 5.1 can deliver the JSON array as one nested array object
        # (nondeterministic, seen live); unwrap it so matching works.
        if($tree.Count -ge 1 -and $tree[0] -isnot [pscustomobject] -and $tree[0] -is [System.Collections.IEnumerable]){
            $tree=@($tree[0] | ForEach-Object { $_ })
        }
        foreach($f in $tree){
            $p=[string]$f.path
            if($p -match '^loras/(.+\.safetensors)$'){
                $name=$Matches[1]
                $size=0
                if($f.lfs -and $f.lfs.size){ $size=[int64]$f.lfs.size } elseif($f.size){ $size=[int64]$f.size }
                $items += [pscustomobject]@{ Name=$name; Size=$size; Url=('https://huggingface.co/'+$repo+'/resolve/main/'+$p) }
            }
        }
    } catch { }
    if(-not $items){
        # Offline fallback: the two LoRAs published for Sootglass (sizes in bytes).
        $items=@(
            [pscustomobject]@{ Name='moss_image_color_depth_control.safetensors'; Size=313063368; Url='https://huggingface.co/Comfy-Org/MOSS-Image/resolve/main/loras/moss_image_color_depth_control.safetensors' },
            [pscustomobject]@{ Name='moss_image_edit_lora_rank_64_bf16.safetensors'; Size=297382216; Url='https://huggingface.co/Comfy-Org/MOSS-Image/resolve/main/loras/moss_image_edit_lora_rank_64_bf16.safetensors' }
        )
    }
    return $items
}
# v0.3.10: optional LoRA downloader window. Nothing is downloaded until the
# user ticks a LoRA and presses Download (the app never fetches them on its
# own). A downloaded file lands in models\loras and is immediately usable:
# the Generation dialog picks it up on its next refresh and the strength
# slider applies it as a <lora:name:strength> prompt tag.
function Show-MossLoraDownloadDialog([System.Windows.Forms.Form]$Owner=$null) {
    $loraDirAbs=Ensure-MossLoraDir
    if(-not $loraDirAbs){
        [System.Windows.Forms.MessageBox]::Show($Owner,'The LoRA folder could not be created. Check the Sootglass folder permissions.','LoRA models',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        return
    }
    $g=New-Object System.Windows.Forms.Form
    $g.Text='LoRA models (optional downloads)'; $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
    # v0.3.13 DPI FIX: the fixed outer Size(620,392) did not account for the
    # 150% DPI window frame, so the bottom buttons ('Download selected',
    # 'Close') were half cut off, and the intro text (fixed 58 px height)
    # lost its last line mid-sentence. The content is now flowed from the
    # hint's real rendered height and the dialog is sized via ClientSize,
    # which is frame-independent - correct at any DPI.
    $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $hint=New-Object System.Windows.Forms.Label; $hint.Text='Optional LoRA add-ons published for Sootglass by Comfy-Org on Hugging Face. Nothing is downloaded until you tick a LoRA and press Download. Downloaded files are placed in:'+"`r`n"+$loraDirAbs+"`r`n"+'They become usable right away - check them in Generation... > LoRA and set a strength.'; $hint.Location=New-Object System.Drawing.Point(12,10); $hint.Size=New-Object System.Drawing.Size(584,96); $hint.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($hint)
    $catalog=@(Get-MossLoraCatalog)
    # v0.3.13: real CheckBox per LoRA instead of a CheckedListBox - checking
    # an entry no longer paints the whole row with the selection highlight,
    # only the checkbox itself toggles. Entries are stacked in a themed panel.
    $loraPanel=New-Object System.Windows.Forms.Panel; $loraPanel.Location=New-Object System.Drawing.Point(12,($hint.Bottom+8)); $loraPanel.Size=New-Object System.Drawing.Size(584,196); $loraPanel.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $loraPanel.BorderStyle='FixedSingle'; $loraPanel.AutoScroll=$true; $g.Controls.Add($loraPanel)
    $loraChecks=New-Object System.Collections.ArrayList
    $installed=@{}
    foreach($lf in (Get-MossLoraFiles)){ $installed[[string]$lf.Stem]=$true }
    $entryInfo=@()
    foreach($cat in $catalog){
        $stem=[System.IO.Path]::GetFileNameWithoutExtension([string]$cat.Name)
        $isInstalled=($installed.ContainsKey($stem))
        $sizeText=if([int64]$cat.Size -gt 0){ [math]::Round(([int64]$cat.Size)/1MB,0).ToString([System.Globalization.CultureInfo]::InvariantCulture)+' MB' } else { 'size unknown' }
        $state=if($isInstalled){ 'installed' } else { 'not installed' }
        $label=[string]$cat.Name+'  ('+$sizeText+', '+$state+')'
        $cb=New-Object System.Windows.Forms.CheckBox; $cb.Text=$label; $cb.AutoSize=$true; $cb.Location=New-Object System.Drawing.Point(8,(6+$loraChecks.Count*24)); $cb.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $loraPanel.Controls.Add($cb); [void]$loraChecks.Add($cb)
        $entryInfo += [pscustomobject]@{ Item=$cat; Stem=$stem; Installed=$isInstalled }
    }
    if($catalog.Count -eq 0){
        [void]$loraChecks.Add($null); $loraChecks[$loraChecks.Count-1]=New-Object System.Windows.Forms.Label; $cb0=$loraChecks[$loraChecks.Count-1]; $cb0.Text='(no LoRAs published - check the internet connection)'; $cb0.AutoSize=$true; $cb0.Location=New-Object System.Drawing.Point(8,6); $cb0.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $loraPanel.Controls.Add($cb0)
    }
    $status=New-Object System.Windows.Forms.Label; $status.Text='Tick the LoRAs you want and press Download. Sootglass stays responsive while the file downloads.'; $status.Location=New-Object System.Drawing.Point(12,($loraPanel.Bottom+10)); $status.Size=New-Object System.Drawing.Size(584,36); $status.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($status)
    $progress=New-Object System.Windows.Forms.ProgressBar; $progress.Location=New-Object System.Drawing.Point(12,($status.Bottom+2)); $progress.Size=New-Object System.Drawing.Size(584,18); $progress.Style='Continuous'; $progress.Visible=$false; $g.Controls.Add($progress)
    $dlBtn=New-Object System.Windows.Forms.Button; $dlBtn.Text='Download selected'; $dlBtn.Location=New-Object System.Drawing.Point(344,($status.Bottom+46)); $dlBtn.Size=New-Object System.Drawing.Size(160,30); $dlBtn.FlatStyle='Flat'; $dlBtn.BackColor=[System.Drawing.Color]::FromArgb(39,90,61); $dlBtn.ForeColor=[System.Drawing.Color]::White; $g.Controls.Add($dlBtn)
    $closeBtn=New-Object System.Windows.Forms.Button; $closeBtn.Text='Close'; $closeBtn.Location=New-Object System.Drawing.Point(512,($status.Bottom+46)); $closeBtn.Size=New-Object System.Drawing.Size(96,30); $closeBtn.FlatStyle='Flat'; $closeBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $closeBtn.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Controls.Add($closeBtn)
    $g.ClientSize=New-Object System.Drawing.Size(620,([Math]::Max(($dlBtn.Bottom+14),($closeBtn.Bottom+14))))
    $logDir=Join-Path $script:AppRoot 'logs'
    # v0.3.11 HOTFIX: the download used to run ON the UI thread, so a 300 MB
    # transfer froze the whole app ('not responding') until it finished.
    # The transfer now runs in a BACKGROUND RUNSPACE and the UI only polls a
    # shared state table on a timer - Sootglass stays fully responsive, shows the
    # byte progress and can be cancelled at any time.
    #
    # v0.3.11 CRITICAL (verified live on this machine): the shared state
    # lives in a SCRIPT-scoped hashtable, NOT in the click handler's local
    # variables. The timer tick fires later, from the message loop, long
    # after the click handler that started it has returned - and a plain
    # scriptblock does NOT see that handler's local variables ($state came
    # through as $null: the transfer would run in the background, but Sootglass
    # would never notice it finished, the .part file would never be moved
    # into models\loras and the progress bar would stay at 0%). The script
    # scope IS reachable from the tick handler, so everything shared lives
    # there. (GetNewClosure() would also capture the variables, but it runs
    # the handler in a module scope that cannot see the app's own functions
    # - the v0.1.19 crash - so the script scope is the safer choice.)
    $script:MossLoraDownload=@{}
    # The worker that runs in the background runspace. It only touches its
    # arguments and the shared hashtable, so it stays self-contained.
    $dlCode=@'
param($Url,$OutFile,$State)
$ErrorActionPreference='Stop'
try {
    [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
    $req=[System.Net.HttpWebRequest]::Create($Url)
    $req.Method='GET'; $req.Timeout=60000; $req.ReadWriteTimeout=120000; $req.UserAgent='Sootglass-Studio'
    $resp=$req.GetResponse()
    $total=$resp.ContentLength
    if($total -gt 0){ $State['Total']=[long]$total }
    $in=$resp.GetResponseStream(); $out=[System.IO.File]::Create($OutFile)
    try {
        $buf=New-Object byte[] 65536
        while(($read=$in.Read($buf,0,$buf.Length)) -gt 0){
            $out.Write($buf,0,$read)
            $State['Bytes']=[long]$State['Bytes']+$read
        }
    } finally { $out.Close(); $in.Close(); $resp.Close() }
    $State['Ok']=$true
} catch {
    $firstErr=$_.Exception.Message
    # Fallback: curl.exe gets through the old .NET HTTP stack when it fails.
    try {
        $curlExe=(Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if($curlExe){
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            & $curlExe -sL --max-time 7200 -o $OutFile $Url
            if($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)){
                $State['Bytes']=(Get-Item -LiteralPath $OutFile).Length
                $State['Ok']=$true
            } else { $State['Error']=$firstErr }
        } else { $State['Error']=$firstErr }
    } catch { $State['Error']=$firstErr }
}
$State['Done']=$true
'@
    $dlBtn.Add_Click({
        $picked=@()
        for($i=0;$i -lt $loraChecks.Count;$i++){ if($null -ne $loraChecks[$i] -and $loraChecks[$i].Checked -and $i -lt $entryInfo.Count){ $picked += $entryInfo[$i] } }
        if(-not $picked.Count){ $status.Text='Tick at least one LoRA first.'; return }
        # Only the files that are actually missing are transferred.
        $todo=@($picked | Where-Object { -not $_.Installed })
        $logLines=@('LoRA download '+ (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        foreach($ep in $picked){
            $destPath=Join-Path $loraDirAbs ([string]$ep.Item.Name)
            if($ep.Installed){ $logLines += ('SKIP '+$ep.Item.Name+': already installed at '+$destPath) }
            else { $logLines += ('QUEUED '+$ep.Item.Name+' -> '+$destPath) }
        }
        if(-not $todo.Count){
            $status.Text='Nothing to download - the selected LoRAs are already installed.'
            try { if(-not(Test-Path -LiteralPath $logDir)){ New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
            $stamp0=Get-Date -Format 'yyyyMMdd-HHmmss'
            try { $logLines | Set-Content -LiteralPath (Join-Path $logDir ('lora-download-'+$stamp0+'.txt')) -Encoding UTF8 } catch {}
            return
        }
        try { if(-not(Test-Path -LiteralPath $logDir)){ New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        $dl=$script:MossLoraDownload
        $dl['Queue']=@($todo); $dl['Index']=0; $dl['Log']=$logLines
        $dl['LogFile']=(Join-Path $logDir ('lora-download-'+$stamp+'.txt'))
        $dl['Status']=$status; $dl['Progress']=$progress; $dl['Btn']=$dlBtn; $dl['Close']=$closeBtn; $dl['Form']=$g
        $dl['Dir']=$loraDirAbs; $dl['Code']=$dlCode; $dl['Active']=$true
        $dl['State']=$null; $dl['Runner']=$null; $dl['Job']=$null; $dl['Part']=''
        try { $dl['Log'] | Set-Content -LiteralPath $dl['LogFile'] -Encoding UTF8 } catch {}
        $dlBtn.Enabled=$false
        $closeBtn.Text='Cancel'
        # Enter must not cancel a running transfer by accident.
        $g.AcceptButton=$null
        $progress.Visible=$true; $progress.Style='Continuous'; $progress.Value=0
        # --- start the FIRST transfer ---
        $cur=$dl['Queue'][0]
        $dest=Join-Path $dl['Dir'] ([string]$cur.Item.Name)
        $part=[string]$dest+'.part'
        $state=[System.Collections.Hashtable]::Synchronized((New-Object System.Collections.Hashtable))
        $state['Done']=$false; $state['Ok']=$false; $state['Error']=''; $state['Bytes']=0; $state['Total']=[int64]$cur.Item.Size
        $dl['State']=$state; $dl['Dest']=$dest; $dl['Part']=$part; $dl['Name']=[string]$cur.Item.Name
        $runner=[powershell]::Create()
        [void]$runner.AddScript($dlCode).AddArgument([string]$cur.Item.Url).AddArgument($part).AddArgument($state)
        $dl['Runner']=$runner; $dl['Job']=$runner.BeginInvoke()
        $status.Text=('Downloading '+$dl['Name']+' ('+[math]::Round(([int64]$cur.Item.Size)/1MB,0).ToString([System.Globalization.CultureInfo]::InvariantCulture)+' MB)...')
        $timer=New-Object System.Windows.Forms.Timer; $timer.Interval=250
        $dl['Timer']=$timer
        # The tick handler reads EVERYTHING it needs from the script-scoped
        # hashtable, so it never depends on the click handler's locals.
        $timer.Add_Tick({
            $dl=$script:MossLoraDownload
            if(-not $dl -or -not $dl['Active']){ return }
            $st=$dl['State']
            if($null -eq $st){ return }
            if(-not $st['Done']){
                # still transferring - update the progress read-out
                $b=[long]$st['Bytes']; $t=[long]$st['Total']
                $dl['Progress'].Maximum=100
                if($t -gt 0){ $dl['Progress'].Value=[Math]::Min(100,[int](($b*100)/$t)) }
                $mb=[math]::Round($b/1MB,1).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                if($t -gt 0){ $dl['Status'].Text=('Downloading '+$dl['Name']+': '+$mb+' MB of '+[math]::Round($t/1MB,0).ToString([System.Globalization.CultureInfo]::InvariantCulture)+' MB ('+$dl['Progress'].Value+'%)') }
                else { $dl['Status'].Text=('Downloading '+$dl['Name']+': '+$mb+' MB') }
                return
            }
            # --- this file finished ---
            $dl['Timer'].Stop()
            try { [void]$dl['Runner'].EndInvoke($dl['Job']) } catch {}
            try { $dl['Runner'].Dispose() } catch {}
            $dl['Runner']=$null; $dl['Job']=$null
            $item=$dl['Queue'][$dl['Index']]
            if($st['Ok']){
                try {
                    $got=(Get-Item -LiteralPath $dl['Part']).Length
                    if([int64]$item.Item.Size -gt 0 -and $got -ne [int64]$item.Item.Size){
                        throw ('size mismatch (got '+[math]::Round($got/1MB,0)+' MB, expected '+[math]::Round(([int64]$item.Item.Size)/1MB,0)+' MB)')
                    }
                    Move-Item -LiteralPath $dl['Part'] -Destination $dl['Dest'] -Force
                    $dl['Status'].Text=([string]$item.Stem+': downloaded ('+[math]::Round($got/1MB,0)+' MB). It is now usable in the LoRA list.')
                    $dl['Log']=@($dl['Log']) + ('OK '+$dl['Name']+' ('+[math]::Round($got/1MB,0)+' MB) -> '+$dl['Dest'])
                } catch {
                    $dl['Status'].Text=([string]$item.Stem+': download failed - '+$_.Exception.Message)
                    $dl['Log']=@($dl['Log']) + ('FAILED '+$dl['Name']+': '+$_.Exception.Message)
                    Remove-Item -LiteralPath $dl['Part'] -Force -ErrorAction SilentlyContinue
                }
            } else {
                $dl['Status'].Text=([string]$item.Stem+': download failed - '+[string]$st['Error'])
                $dl['Log']=@($dl['Log']) + ('FAILED '+$dl['Name']+': '+[string]$st['Error'])
                Remove-Item -LiteralPath $dl['Part'] -Force -ErrorAction SilentlyContinue
            }
            try { $dl['Log'] | Set-Content -LiteralPath $dl['LogFile'] -Encoding UTF8 } catch {}
            # --- next file, or all done ---
            $dl['Index']=[int]$dl['Index']+1
            if([int]$dl['Index'] -lt @($dl['Queue']).Count){
                $next=$dl['Queue'][[int]$dl['Index']]
                $dest2=Join-Path $dl['Dir'] ([string]$next.Item.Name)
                $part2=[string]$dest2+'.part'
                $state2=[System.Collections.Hashtable]::Synchronized((New-Object System.Collections.Hashtable))
                $state2['Done']=$false; $state2['Ok']=$false; $state2['Error']=''; $state2['Bytes']=0; $state2['Total']=[int64]$next.Item.Size
                $dl['State']=$state2; $dl['Dest']=$dest2; $dl['Part']=$part2; $dl['Name']=[string]$next.Item.Name
                $runner2=[powershell]::Create()
                [void]$runner2.AddScript($dl['Code']).AddArgument([string]$next.Item.Url).AddArgument($part2).AddArgument($state2)
                $dl['Runner']=$runner2; $dl['Job']=$runner2.BeginInvoke()
                $dl['Progress'].Value=0
                $dl['Status'].Text=('Downloading '+$dl['Name']+' ('+[math]::Round(([int64]$next.Item.Size)/1MB,0).ToString([System.Globalization.CultureInfo]::InvariantCulture)+' MB)...')
                $dl['Timer'].Start()
                return
            }
            # everything is done
            $dl['Active']=$false
            $dl['Timer'].Stop(); $dl['Timer'].Dispose()
            $dl['Progress'].Visible=$false
            $dl['Btn'].Enabled=$true
            $dl['Close'].Text='Close'
            $g.AcceptButton=$closeBtn
            $okCount=0; $failCount=0
            foreach($ln in @($dl['Log'])){ if([string]$ln -like 'OK *'){$okCount++} elseif([string]$ln -like 'FAILED *'){$failCount++} }
            $dl['Status'].Text=('Finished: '+$okCount+' downloaded, '+$failCount+' failed. The new LoRAs are ready in Generation options > LoRA.')
            try { $dl['Log'] | Set-Content -LiteralPath $dl['LogFile'] -Encoding UTF8 } catch {}
        })
        $timer.Start()
    })
    # Close / Cancel button. While a transfer runs it cancels the transfer
    # and keeps the window open; otherwise it closes the window.
    $closeBtn.Add_Click({
        $dl=$script:MossLoraDownload
        if($dl -and $dl['Active']){
            try { $dl['Timer'].Stop(); $dl['Timer'].Dispose() } catch {}
            try { if($dl['Runner']){ $dl['Runner'].Stop() } } catch {}
            try { if($dl['Runner']){ $dl['Runner'].Dispose() } } catch {}
            $dl['Runner']=$null; $dl['Job']=$null
            try { if($dl['Part']){ Remove-Item -LiteralPath $dl['Part'] -Force -ErrorAction SilentlyContinue } } catch {}
            $dl['Active']=$false
            $dl['Log']=@($dl['Log']) + ('CANCELLED '+$dl['Name']+': user cancelled; partial file removed from '+$dl['Dir'])
            try { $dl['Log'] | Set-Content -LiteralPath $dl['LogFile'] -Encoding UTF8 } catch {}
            $dl['Progress'].Visible=$false
            $dl['Btn'].Enabled=$true
            $dl['Close'].Text='Close'
            $g.AcceptButton=$closeBtn
            $dl['Status'].Text='Download cancelled.'
            try { $dl['Log'] | Set-Content -LiteralPath $dl['LogFile'] -Encoding UTF8 } catch {}
            return
        }
        $g.Close()
    })
    # Closing the window (the X button) while a transfer runs must stop the
    # timer as well, or it would keep firing into a disposed form.
    $g.Add_FormClosing({
        $dl=$script:MossLoraDownload
        if($dl -and $dl['Active']){
            try { $dl['Timer'].Stop(); $dl['Timer'].Dispose() } catch {}
            try { if($dl['Runner']){ $dl['Runner'].Stop(); $dl['Runner'].Dispose() } } catch {}
            $dl['Runner']=$null; $dl['Job']=$null
            try { if($dl['Part']){ Remove-Item -LiteralPath $dl['Part'] -Force -ErrorAction SilentlyContinue } } catch {}
            $dl['Active']=$false
            $dl['Log']=@($dl['Log']) + ('CANCELLED '+$dl['Name']+': download window closed; partial file removed from '+$dl['Dir'])
            try { $dl['Log'] | Set-Content -LiteralPath $dl['LogFile'] -Encoding UTF8 } catch {}
        }
    })
    $g.AcceptButton=$closeBtn
    [void]$g.ShowDialog($Owner)
    $g.Dispose()
}
function Get-RelativeAppPath([string]$value) {
    # Anchor relative paths to the app root FIRST: [IO.Path]::GetFullPath on a
    # bare relative path resolves against the PROCESS working directory (which
    # is NOT necessarily the app folder - a launcher or terminal can start
    # Sootglass from anywhere), so 'outputs' once became '<cwd>\outputs' and got
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
function Test-MossImageDimension([int]$Dimension) {
    return ($Dimension -ge 64 -and $Dimension -le 8192 -and ($Dimension % 16 -eq 0))
}
function Get-MossScaledDimension([int]$Dimension,[double]$Scale) {
    return [int][Math]::Max(128,[Math]::Floor(($Dimension * $Scale) / 16.0) * 16)
}
function Test-MossLayoutPrompt([string]$Prompt) {
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.TrimStart().Substring(0,1) -ne '{') { return $false }
    try {
        $layout=ConvertFrom-Json -InputObject $Prompt -ErrorAction Stop
        return ($layout -is [pscustomobject] -and
            $null -ne $layout.PSObject.Properties['summary'] -and
            $null -ne $layout.PSObject.Properties['items'] -and
            $null -ne $layout.PSObject.Properties['bbox_coord_space'] -and
            $null -ne $layout.PSObject.Properties['bbox_format'])
    } catch {
        return $false
    }
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
function Test-MossZipDigest([string]$zipPath,$asset,[switch]$RequireDigest) {
    # GitHub publishes a sha256 digest for release assets when available; a
    # mismatch means the download is corrupt and must not be installed.
    $digest=[string]$asset.digest
    if([string]::IsNullOrWhiteSpace($digest)){
        if($RequireDigest){ throw 'GitHub did not provide a SHA-256 digest for this Sootglass release. The update was not installed.' }
        return
    }
    if($digest -notmatch '^sha256:([0-9a-fA-F]{64})$'){ throw 'GitHub provided an invalid SHA-256 digest for this release. The update was not installed.' }
    $expected=$Matches[1].ToLowerInvariant()
    $hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -ne $expected){ throw ('The downloaded file is corrupt (sha256 mismatch: expected '+$expected+', got '+$hash+').') }
}
function Get-MossEngineCacheInfo([string]$engineBin) {
    # v0.3.3: per-commit cache of the installed engine files, stored as ONE
    # compressed zip: engines\cache-<commit>.zip (with a manifest.txt entry).
    # If exactly one (or a few) engine files are lost later, ONLY those entries
    # are extracted from the zip back into bin - no 437 MB release download.
    # Returns $null or @{ ZipPath; Commit; Missing=@(names missing in bin) }.
    if([string]::IsNullOrWhiteSpace($engineBin)){ return $null }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $root=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) 'engines'
    $zips=@(Get-ChildItem -LiteralPath $root -File -Filter 'cache-*.zip' -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)
    foreach($z in $zips){
        try {
            $archive=[System.IO.Compression.ZipFile]::OpenRead($z.FullName)
            try {
                $mf=@($archive.Entries | Where-Object { [string]$_.FullName -eq 'manifest.txt' } | Select-Object -First 1)
                if($mf){
                    $sr=New-Object System.IO.StreamReader($mf.Open())
                    try { $lines=@($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim() }) } finally { $sr.Dispose() }
                    $missing=@()
                    foreach($line in $lines){
                        $n=($line -split "`t")[0]
                        if($n -and -not (Test-Path -LiteralPath (Join-Path $engineBin $n) -PathType Leaf)){
                            # only count files the zip actually contains
                            if(@($archive.Entries | Where-Object { [System.IO.Path]::GetFileName([string]$_.FullName) -eq $n }).Count -gt 0){ $missing+=$n }
                        }
                    }
                    if($missing.Count -gt 0){ return @{ ZipPath=$z.FullName; Commit=($z.BaseName -replace '^cache-',''); Missing=$missing } }
                }
            } finally { $archive.Dispose() }
        } catch { }
    }
    return $null
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
                $restoreStage=Join-Path ([System.IO.Path]::GetTempPath()) ('Sootglass-Backup-Restore-'+[guid]::NewGuid().ToString('N'))
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
function Test-MossModelTargetName([string]$LocalPath,[string]$ExpectedName) {
    if([string]::IsNullOrWhiteSpace($LocalPath) -or [string]::IsNullOrWhiteSpace($ExpectedName)){ return $false }
    return ([System.IO.Path]::GetFileName($LocalPath).Equals($ExpectedName,[System.StringComparison]::OrdinalIgnoreCase))
}
function Test-MossModelSourceIdentity([string]$LocalPath,[string]$ExpectedName,[int64]$ExpectedSize) {
    if(-not (Test-MossModelTargetName $LocalPath $ExpectedName)){ return $false }
    if(-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)){ return $false }
    if($ExpectedSize -le 0){ return $true }
    return ((Get-Item -LiteralPath $LocalPath).Length -eq $ExpectedSize)
}
function Get-MossModelBackupPath([string]$LocalPath,[string]$Stamp) {
    if([string]::IsNullOrWhiteSpace($LocalPath) -or [string]::IsNullOrWhiteSpace($Stamp)){ return '' }
    $destDir=[System.IO.Path]::GetDirectoryName($LocalPath)
    $oldName=([System.IO.Path]::GetFileNameWithoutExtension($LocalPath))+'.old-'+$Stamp+([System.IO.Path]::GetExtension($LocalPath))
    return (Join-Path $destDir $oldName)
}
function Get-MossModelUpdateInfo {
    # Checks the known model sources on Hugging Face against the local files:
    # remote LFS size vs local file size (metadata only - no multi-GB
    # downloads). Sizes of multi-GB LFS files are a reliable version signal.
    # v0.3.4: $Variant selects the PRECISION variant of the diffusion model and
    # the text encoder LLM - 'quantized' (int8 + Q4 GGUF, the default),
    # 'q8' (near-lossless 8-bit LLM) or 'bf16' (full 16-bit, best quality).
    param([string]$Variant = 'quantized')
    $diffusion = @{ Name='moss_image_sft_int8_convrot.safetensors'; Setting='DiffusionModelPath'; Repo='Comfy-Org/MOSS-Image'; RepoPath='diffusion_models/moss_image_sft_int8_convrot.safetensors' }
    $llm = @{ Name='Qwen3.5-9B-Q4_K_M.gguf'; Setting='LlmPath'; Repo='unsloth/Qwen3.5-9B-GGUF'; RepoPath='Qwen3.5-9B-Q4_K_M.gguf' }
    if($Variant -eq 'q8'){
        $llm = @{ Name='Qwen3.5-9B-Q8_0.gguf'; Setting='LlmPath'; Repo='unsloth/Qwen3.5-9B-GGUF'; RepoPath='Qwen3.5-9B-Q8_0.gguf' }
    } elseif($Variant -eq 'bf16'){
        $diffusion = @{ Name='moss_image_sft_bf16.safetensors'; Setting='DiffusionModelPath'; Repo='Comfy-Org/MOSS-Image'; RepoPath='diffusion_models/moss_image_sft_bf16.safetensors' }
        $llm = @{ Name='Qwen3.5-9B-BF16.gguf'; Setting='LlmPath'; Repo='unsloth/Qwen3.5-9B-GGUF'; RepoPath='Qwen3.5-9B-BF16.gguf' }
    }
    $known=@(
        $diffusion,
        @{ Name='flux2-vae.safetensors'; Setting='VaePath'; Repo='Comfy-Org/MOSS-Image'; RepoPath='vae/flux2-vae.safetensors' },
        $llm,
        @{ Name='tokenizer_qwen3.5.json'; Setting='TokenizerPath'; Repo='OpenMOSS-Team/MOSS-Image-Base'; RepoPath='tokenizer/tokenizer.json' }
    )
    $out=@()
    $treeCache=@{}
    foreach($m in $known){
        $localPath=''
        if($script:Settings.Contains($m.Setting)){
            $candidate=Get-AbsoluteAppPath ([string]$script:Settings[$m.Setting])
            if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-MossModelTargetName $candidate $m.Name)){ $localPath=$candidate }
        }
        if(-not $localPath){
            $modelsDir=Join-Path $script:AppRoot 'models'
            $p=Join-Path $modelsDir $m.Name
            if(Test-Path -LiteralPath $p -PathType Leaf){ $localPath=$p }
        }
        $info=@{ Name=$m.Name; Setting=$m.Setting; Repo=$m.Repo; RepoPath=$m.RepoPath; RemoteUrl=('https://huggingface.co/'+$m.Repo+'/resolve/main/'+$m.RepoPath); LocalPath=$localPath; LocalSize=0; RemoteSize=0; RemoteDate=''; Status='check failed' }
        if($localPath){ $info.LocalSize=(Get-Item -LiteralPath $localPath).Length }
        try {
            if(-not $treeCache.ContainsKey($m.Repo)){
                $treeRaw=Invoke-RestMethod -Uri ('https://huggingface.co/api/models/'+$m.Repo+'/tree/main?recursive=true') -Headers @{Accept='application/json';'User-Agent'='Sootglass-Studio'} -TimeoutSec 20
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
            $sourceName=[System.IO.Path]::GetFileName([string]$m.RepoPath)
            $info.SourceName=$sourceName
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
        $req.Method='GET'; $req.AddRange(0,2097151); $req.Timeout=2500; $req.ReadWriteTimeout=5000; $req.UserAgent='Sootglass-Studio'
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
    # start. Everywhere else (startup, opening a dialog) Sootglass uses this
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
    # Returns the fixed local drive (other than Sootglass's current one) with the
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
    # Copies the Sootglass application files to a roomier location and creates a
    # desktop shortcut there. Models/bin are NOT copied - the startup offer
    # in the new location downloads them fresh.
    try {
        New-Item -ItemType Directory -Path $newRoot -Force | Out-Null
        foreach($sub in @('models','bin','config','logs')){ New-Item -ItemType Directory -Path (Join-Path $newRoot $sub) -Force | Out-Null }
        $copied=@()
        foreach($f in (@(Get-ChildItem -LiteralPath $script:AppRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Sootglass-Studio.*' }) + @(Get-ChildItem -LiteralPath $script:AppRoot -File -Filter 'README.txt' -ErrorAction SilentlyContinue))){
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $newRoot $f.Name) -Force
            $copied+=$f.Name
        }
        $oldConfig=Join-Path $script:AppRoot 'config\settings.json'
        if(Test-Path -LiteralPath $oldConfig){ Copy-Item -LiteralPath $oldConfig -Destination (Join-Path $newRoot 'config\settings.json') -Force }
        if($copied.Count -eq 0){ return $null }
        # Desktop shortcut pointing at the new copy.
        $desktop=[Environment]::GetFolderPath('Desktop')
        $target=$null
        foreach($cand in @('Sootglass-Studio.vbs','Sootglass-Studio.bat')){ if(Test-Path -LiteralPath (Join-Path $newRoot $cand) -PathType Leaf){ $target=(Join-Path $newRoot $cand); break } }
        if(-not $target){ return $null }
        $ws=New-Object -ComObject WScript.Shell
        $sc=$ws.CreateShortcut((Join-Path $desktop 'Sootglass Studio.lnk'))
        $sc.TargetPath=$target
        $sc.WorkingDirectory=$newRoot
        $sc.Description='Sootglass Studio'
        $sc.Save()
        return $newRoot
    } catch {
        return $null
    }
}
function Test-MossOfferStartupDownload([System.Windows.Forms.Form]$Owner) {
    # Startup completeness check: if the engine or the known model files are
    # missing, offer to download them right away so Sootglass works as intended.
    # Updates for already-installed files are NOT prompted here - they live in
    # the 'Update engine...' dialog.
    try {
        $enginePath=Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
        $engineOk=Test-Path -LiteralPath $enginePath -PathType Leaf
        # v0.2.3: LOCAL FIRST. When the engine and every known model file are
        # present on disk, NOTHING can be 'not installed', so the remote size
        # lookup (4 network calls to huggingface.co, ~0.9 s) is not needed at
        # all - that was the last slow thing left in Sootglass's startup.
        $knownLocal=@(
            @{ Name='moss_image_sft_int8_convrot.safetensors'; Setting='DiffusionModelPath' },
            @{ Name='flux2-vae.safetensors'; Setting='VaePath' },
            @{ Name='Qwen3.5-9B-Q4_K_M.gguf'; Setting='LlmPath' },
            @{ Name='tokenizer_qwen3.5.json'; Setting='TokenizerPath' }
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
                $missing+=($i.Name+'  ('+(Format-MossModelSize $i.RemoteSize)+')')
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
            # Not enough room on Sootglass's current drive? Suggest a better place
            # first - a fresh install with models needs roughly 12 GB plus
            # the engine package and headroom.
            $needTotal=$modelsTotal+[int64](600MB)
            $driveRoot=[System.IO.Path]::GetPathRoot((Get-AbsoluteAppPath '.')).TrimEnd('\')
            try { $freeHere=(New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace } catch { $freeHere=[int64]::MaxValue }
            if($freeHere -lt $needTotal){
                $better=Find-MossRelocationDrive ($needTotal*2)
                if($better){
                    $suggested=Join-Path $better.Root 'Sootglass Studio'
                    $msg=("Sootglass is in a tight spot:`r`n`r`n`"{0}`" only has {1} free, but the missing files need about {2}.`r`n`r`nDrive {3} has {4} free. Move Sootglass there?`r`n`r`nMOSS will be copied to `"{5}`" and a desktop shortcut will be created - then the downloads run from the new place (this copy can be deleted afterwards)." -f $driveRoot,(Format-MossModelSize $freeHere 1),(Format-MossModelSize $needTotal 1),$better.Root.TrimEnd('\'),(Format-MossModelSize $better.Free 1),$suggested)
                    $answer=[System.Windows.Forms.MessageBox]::Show($Owner,$msg,'Better place for Sootglass',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
                    if($answer -eq [System.Windows.Forms.DialogResult]::Yes){
                        $newRoot=Move-MossToNewLocation $suggested
                        if($newRoot){
                            try { [void](Write-MossErrorLog 'Relocated Sootglass' ('New location: '+$newRoot)) } catch {}
                            $startAnswer=[System.Windows.Forms.MessageBox]::Show($Owner,("Sootglass was copied to `""+$newRoot+"`" and a desktop shortcut (Sootglass Studio) now points there.`r`n`r`nStart the new copy now? The downloads then run from the new place - you can close this old window and delete this old copy afterwards."),'Better place for Sootglass',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information)
                            if($startAnswer -eq [System.Windows.Forms.DialogResult]::Yes){
                                $starter=Join-Path $newRoot 'Sootglass-Studio.vbs'
                                if(Test-Path -LiteralPath $starter -PathType Leaf){ Start-Process -FilePath 'wscript.exe' -ArgumentList ('"'+$starter+'"') } else { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+$newRoot+'"') }
                                $Owner.Close()
                            }
                            return
                        }
                    }
                } else {
                    [System.Windows.Forms.MessageBox]::Show($Owner,("Sootglass is in a tight spot:`r`n`r`n`""+$driveRoot+"`" only has "+(Format-MossModelSize $freeHere 1)+" free, but the missing files need about "+(Format-MossModelSize $needTotal 1)+", and no other fixed drive has room either.`r`n`r`nFree up space (or plug in a larger drive) and start Sootglass again.`r`nYou can also continue now and install only what fits."),'Better place for Sootglass',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
                    return
                }
            }
            $msg=("Sootglass is not fully installed yet:`r`n`r`n"+(($lines) -join "`r`n")+"`r`n`r`nWithout the engine and model files Sootglass cannot generate images.`r`n`r`nDownload them now?"+$est+"`r`n(You can also do this later via 'Update engine...' in the header.)")
            $answer=[System.Windows.Forms.MessageBox]::Show($Owner,$msg,'Sootglass setup',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if($answer -eq [System.Windows.Forms.DialogResult]::Yes){ Show-MossEngineUpdateDialog $Owner }
        }
    } catch {}
}
# v0.3.5: quick precision switch. All model variants share the VAE, the
# tokenizer and the engine - switching needs ZERO downloads when the files
# are already in models\ (only the diffusion model and the LLM differ per
# precision). This dialog shows what is installed and switches instantly.
function Get-MossPrecisionInfo {
    # Returns one entry per precision: label, the diffusion + LLM file names,
    # and which of them are actually present on disk (settings path or
    # models\<name>).
    $defs=@(
        @{ Key='quantized'; Label='Quantized (default) - int8 diffusion + 4-bit Q4 LLM'; Diffusion='moss_image_sft_int8_convrot.safetensors'; Llm='Qwen3.5-9B-Q4_K_M.gguf' },
        @{ Key='q8';        Label='High quality - Q8 LLM (near-lossless)';               Diffusion='moss_image_sft_int8_convrot.safetensors'; Llm='Qwen3.5-9B-Q8_0.gguf' },
        @{ Key='bf16';      Label='Full 16-bit BF16 (best quality, ~28 GB)';             Diffusion='moss_image_sft_bf16.safetensors';         Llm='Qwen3.5-9B-BF16.gguf' }
    )
    $out=@()
    foreach($d in $defs){
        $modelsDir=Join-Path $script:AppRoot 'models'
        $diffPath=Join-Path $modelsDir $d.Diffusion; $llmPath=Join-Path $modelsDir $d.Llm
        $diffOk=Test-Path -LiteralPath $diffPath -PathType Leaf
        $llmOk=Test-Path -LiteralPath $llmPath -PathType Leaf
        if(-not $diffOk -and $script:Settings.Contains('DiffusionModelPath')){ $p=Get-AbsoluteAppPath ([string]$script:Settings['DiffusionModelPath']); if($p -and (Test-MossModelTargetName $p $d.Diffusion)){ $diffOk=$true; $diffPath=$p } }
        if(-not $llmOk -and $script:Settings.Contains('LlmPath')){ $p=Get-AbsoluteAppPath ([string]$script:Settings['LlmPath']); if($p -and (Test-MossModelTargetName $p $d.Llm)){ $llmOk=$true; $llmPath=$p } }
        $missing=@(); if(-not $diffOk){ $missing+=$d.Diffusion }; if(-not $llmOk){ $missing+=$d.Llm }
        $current=($script:Settings.Contains('LlmPath') -and ((Split-Path -Leaf (Get-AbsoluteAppPath ([string]$script:Settings['LlmPath']))) -eq $d.Llm))
        $out+=[pscustomobject]@{ Key=$d.Key; Label=$d.Label; Diffusion=$d.Diffusion; Llm=$d.Llm; Ready=($missing.Count -eq 0); Missing=$missing; Current=$current; DiffPath=$diffPath; LlmPath=$llmPath }
    }
    return ,$out
}
function Install-MossModelFiles([object[]]$ModelPlan,[string]$TempRoot,[string]$Stamp,[scriptblock]$OnProgress=$null,[object[]]$SettingsPlan=$null) {
    $installed=@()
    $settingsBefore=@{}
    try {
        $index=0
        foreach($mi in $ModelPlan){
            $index++
            if($OnProgress){ & $OnProgress $mi $index $ModelPlan.Count }
            $mTemp=[string]$mi.DownloadPath
            $downloadedInPlace=[bool]$mTemp
            if(-not $downloadedInPlace){
                $mTemp=Join-Path $TempRoot ('model-'+$mi.Name+'.part')
                [void](Save-MossWebFile ([string]$mi.RemoteUrl) $mTemp 7200)
            }
            if(-not (Test-Path -LiteralPath $mTemp -PathType Leaf)){ throw ('The '+$mi.Name+' download did not produce a file.') }
            $got=(Get-Item -LiteralPath $mTemp).Length
            if($mi.RemoteSize -gt 0 -and $got -ne $mi.RemoteSize){ throw ('download size mismatch for '+$mi.Name+' (got '+(Format-MossModelSize $got)+', expected '+(Format-MossModelSize $mi.RemoteSize)+')') }
            $destModel=[string]$mi.LocalPath
            if(-not $destModel){ $destModel=Join-Path $script:AppRoot ('models\'+$mi.Name) }
            if(-not (Test-MossModelTargetName $destModel ([string]$mi.Name))){
                throw ('Model download target filename mismatch: '+[string]$mi.Name+' must not overwrite '+[System.IO.Path]::GetFileName($destModel))
            }
            $destDir=[System.IO.Path]::GetDirectoryName($destModel)
            if(-not (Test-Path -LiteralPath $destDir -PathType Container)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $backupPath=''
            if(Test-Path -LiteralPath $destModel -PathType Leaf){
                $backupPath=Get-MossModelBackupPath $destModel $Stamp
                Move-Item -LiteralPath $destModel -Destination $backupPath -ErrorAction Stop
            }
            try {
                if($downloadedInPlace){ Move-Item -LiteralPath $mTemp -Destination $destModel -Force -ErrorAction Stop }
                else { Copy-Item -LiteralPath $mTemp -Destination $destModel -Force -ErrorAction Stop }
                if((Get-Item -LiteralPath $destModel).Length -ne $got){ throw ('installed file size mismatch for '+$mi.Name) }
            } catch {
                $copyError=$_.Exception.Message
                $restoreErrors=@()
                try { if(Test-Path -LiteralPath $destModel -PathType Leaf){ Remove-Item -LiteralPath $destModel -Force -ErrorAction Stop } } catch { $restoreErrors+=('could not remove incomplete '+$destModel+': '+$_.Exception.Message) }
                try { if($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)){ Move-Item -LiteralPath $backupPath -Destination $destModel -Force -ErrorAction Stop } } catch { $restoreErrors+=('could not restore '+$destModel+': '+$_.Exception.Message) }
                if($restoreErrors.Count -gt 0){ throw ($copyError+'; '+($restoreErrors -join '; ')) }
                throw $copyError
            }
            $installed+= [pscustomobject]@{ Name=[string]$mi.Name; Path=$destModel; Backup=$backupPath }
            Remove-Item -LiteralPath $mTemp -Force -ErrorAction SilentlyContinue
        }
        $settingsPlanToApply=$ModelPlan
        if($SettingsPlan){ $settingsPlanToApply=$SettingsPlan }
        foreach($mi in $settingsPlanToApply){
            if([string]$mi.Setting -notin @('DiffusionModelPath','LlmPath')){ continue }
            $modelPath=[string]$mi.LocalPath
            if(-not $modelPath){
                $newFile=@($installed | Where-Object { $_.Name -eq [string]$mi.Name } | Select-Object -First 1)
                if($newFile.Count -gt 0){ $modelPath=[string]$newFile[0].Path }
                else { $modelPath=Join-Path $script:AppRoot ('models\'+$mi.Name) }
            }
            if(-not (Test-Path -LiteralPath $modelPath -PathType Leaf)){ throw ('The selected precision is incomplete: '+$mi.Name+' is not installed.') }
            if(-not $settingsBefore.ContainsKey([string]$mi.Setting)){
                $settingsBefore[[string]$mi.Setting]=[pscustomobject]@{ Exists=$script:Settings.Contains([string]$mi.Setting); Value=$script:Settings[[string]$mi.Setting] }
            }
            $script:Settings[[string]$mi.Setting]=Get-RelativeAppPath $modelPath
        }
        if($installed.Count -gt 0 -and -not (Save-Settings)){ throw 'The model files were installed, but Sootglass could not save the updated model paths.' }
        foreach($item in $installed){
            if($item.Backup){
                $oldSiblings=@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($item.Path)) -File -Filter (([System.IO.Path]::GetFileNameWithoutExtension($item.Path))+'.old-*') -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)
                for($bi=3; $bi -lt $oldSiblings.Count; $bi++){
                    try { Remove-Item -LiteralPath $oldSiblings[$bi].FullName -Force -ErrorAction Stop } catch { [void](Write-MossErrorLog 'Model backup cleanup failed' ($oldSiblings[$bi].FullName+': '+$_.Exception.Message)) }
                }
            }
        }
        return ,$installed
    } catch {
        $installError=$_.Exception.Message
        $rollbackErrors=@()
        for($ii=$installed.Count-1; $ii -ge 0; $ii--){
            $item=$installed[$ii]
            try {
                if(Test-Path -LiteralPath $item.Path -PathType Leaf){ Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop }
                if($item.Backup -and (Test-Path -LiteralPath $item.Backup -PathType Leaf)){ Move-Item -LiteralPath $item.Backup -Destination $item.Path -Force -ErrorAction Stop }
            } catch { $rollbackErrors+=($item.Path+': '+$_.Exception.Message) }
        }
        foreach($key in $settingsBefore.Keys){
            if($settingsBefore[$key].Exists){ $script:Settings[$key]=$settingsBefore[$key].Value }
            else { [void]$script:Settings.Remove($key) }
        }
        if($rollbackErrors.Count -gt 0){ throw ($installError+'; rollback incomplete for '+($rollbackErrors -join '; ')) }
        throw $installError
    }
}
function Show-MossModelVariantDownload([System.Windows.Forms.Form]$Owner,[string]$Variant,[object[]]$RequestedModels=$null) {
    if(@('quantized','q8','bf16') -notcontains $Variant){ throw ('Unsupported model precision: '+$Variant) }
    if($null -ne $script:GenState -and $script:GenState.IsRunning){
        [System.Windows.Forms.MessageBox]::Show($Owner,'A generation is running. Wait for it to finish (or cancel it) before downloading model files.','Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        return
    }
    $infos=@(Get-MossModelUpdateInfo $Variant)
    $modelPlan=@($infos | Where-Object { $_.Status -eq 'update available' -or $_.Status -eq 'not installed' })
    $requiredModels=@($infos | Where-Object { [string]$_.Setting -in @('DiffusionModelPath','LlmPath') })
    $unverified=@($requiredModels | Where-Object { $_.Status -notin @('update available','not installed','up to date') })
    if($unverified.Count -gt 0){
        $names=($unverified | ForEach-Object { $_.Name+': '+$_.Status }) -join "`r`n  "
        [System.Windows.Forms.MessageBox]::Show($Owner,("Sootglass could not verify every required model for this precision:`r`n`r`n  {0}`r`n`r`nCheck your connection and try again. No files were downloaded." -f $names),'Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        return
    }
    if($null -ne $RequestedModels){
        $selectedNames=@($RequestedModels | ForEach-Object { [string]$_.Name })
        $requiredPending=@($modelPlan | Where-Object { [string]$_.Setting -in @('DiffusionModelPath','LlmPath') })
        $notSelected=@($requiredPending | Where-Object { $selectedNames -notcontains [string]$_.Name })
        if($notSelected.Count -gt 0){
            $names=($notSelected | ForEach-Object { $_.Name }) -join "`r`n  "
            [System.Windows.Forms.MessageBox]::Show($Owner,("To switch precision safely, include every missing/updated diffusion and LLM file. Also select:`r`n`r`n  {0}`r`n`r`nNo files were downloaded." -f $names),'Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
            return
        }
        $modelPlan=@($modelPlan | Where-Object { $selectedNames -contains [string]$_.Name })
        if($modelPlan.Count -eq 0){
            [System.Windows.Forms.MessageBox]::Show($Owner,'No model files are selected for download.','Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
            return
        }
    }
    if($modelPlan.Count -eq 0){
        $failed=@($infos | Where-Object { $_.Status -eq 'check failed' -or $_.Status -eq 'no matching file at the source' })
        $message=$(if($failed.Count -gt 0){'Sootglass could not verify the model files with their sources. Check your connection and try again.'}else{'All model files for this precision are already installed. No download is needed.'})
        [System.Windows.Forms.MessageBox]::Show($Owner,$message,'Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        return
    }
    $modelsTotal=[int64]0
    foreach($mi in $modelPlan){ if($mi.RemoteSize -gt 0){ $modelsTotal += [int64]$mi.RemoteSize } }
    $spaceByRoot=@{}; $spaceCheckError=''
    foreach($mi in $modelPlan){
        if([int64]$mi.RemoteSize -le 0){ $spaceCheckError=('Sootglass could not determine the download size for '+$mi.Name+'.'); break }
        $destModel=[string]$mi.LocalPath
        if(-not $destModel){ $destModel=Join-Path $script:AppRoot ('models\'+$mi.Name) }
        if(-not (Test-MossModelTargetName $destModel ([string]$mi.Name))){
            $destModel=Join-Path $script:AppRoot ('models\'+$mi.Name)
            $mi.LocalPath=$destModel
        }
        $driveRoot=[System.IO.Path]::GetPathRoot($destModel)
        if(-not $driveRoot){ $spaceCheckError=('Sootglass could not identify the destination drive for '+$mi.Name+'.'); break }
        try {
            $rootKey=$driveRoot.TrimEnd('\').ToUpperInvariant()
            if(-not $spaceByRoot.ContainsKey($rootKey)){
                $driveInfo=New-Object System.IO.DriveInfo($driveRoot)
                if(-not $driveInfo.IsReady){ throw ('The destination drive '+$driveRoot+' is not ready.') }
                $spaceByRoot[$rootKey]=@{ Root=$driveRoot.TrimEnd('\'); Available=[int64]$driveInfo.AvailableFreeSpace; Needed=[int64]0 }
            }
            $spaceEntry=$spaceByRoot[$rootKey]
            $spaceEntry.Needed=[int64]$spaceEntry.Needed+[int64]$mi.RemoteSize
        } catch { $spaceCheckError=$_.Exception.Message; break }
    }
    if($spaceCheckError){
        [System.Windows.Forms.MessageBox]::Show($Owner,("Sootglass could not verify the required free disk space:`r`n`r`n"+$spaceCheckError+"`r`n`r`nNo files were downloaded."),'Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        return
    }
    $spaceLines=@(); $spaceShortages=@(); $spaceMargin=[int64](512MB)
    foreach($spaceEntry in $spaceByRoot.Values){
        $needed=[int64]$spaceEntry.Needed+$spaceMargin
        $line=($spaceEntry.Root+': need '+(Format-MossModelSize $needed)+' (including 512 MB safety margin), available '+(Format-MossModelSize $spaceEntry.Available))
        $spaceLines+=$line
        if([int64]$spaceEntry.Available -lt $needed){ $spaceShortages+=$line }
    }
    if($spaceShortages.Count -gt 0){
        [System.Windows.Forms.MessageBox]::Show($Owner,("There is not enough free disk space for these model files:`r`n`r`n  "+($spaceShortages -join "`r`n  ")+"`r`n`r`nFree up space and try again. No files were downloaded."),'Not enough disk space',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        return
    }
    $downloadLines=($modelPlan | ForEach-Object { '  '+$_.Name+'  ('+(Format-MossModelSize $_.RemoteSize)+')' }) -join "`r`n"
    $confirmText="Download and install these model files only?`r`n`r`n{0}`r`n`r`nTotal download: {1}`r`nAvailable disk space:`r`n  {2}`r`n`r`nThe installed engine and graphics runtime (NVIDIA/CUDA, AMD/ROCm, Intel/SYCL, or other backend) will be left unchanged and will not be downloaded again. Existing model files will be kept as backups." -f $downloadLines,(Format-MossModelSize $modelsTotal),($spaceLines -join "`r`n  ")
    $answer=[System.Windows.Forms.MessageBox]::Show($Owner,$confirmText,'Download model files',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){ return }
    $busy=@(Get-Process -Name 'sd-cli','sd-server' -ErrorAction SilentlyContinue)
    if($busy.Count -gt 0){
        [System.Windows.Forms.MessageBox]::Show($Owner,'sd-cli or sd-server is currently running. Wait for it to finish and try again.','Model download',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        return
    }
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    try {
        foreach($mi in $modelPlan){
            $destModel=[string]$mi.LocalPath
            if(-not $destModel){ $destModel=Join-Path $script:AppRoot ('models\'+$mi.Name); $mi.LocalPath=$destModel }
            $destDir=[System.IO.Path]::GetDirectoryName($destModel)
            if(-not (Test-Path -LiteralPath $destDir -PathType Container)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $mi | Add-Member -NotePropertyName DownloadPath -NotePropertyValue ($destModel+'.download-'+[guid]::NewGuid().ToString('N')+'.part') -Force
        }
    } catch {
        foreach($mi in $modelPlan){ if([string]$mi.DownloadPath){ Remove-Item -LiteralPath ([string]$mi.DownloadPath) -Force -ErrorAction SilentlyContinue } }
        [System.Windows.Forms.MessageBox]::Show($Owner,("The model destination could not be prepared:`r`n`r`n"+$_.Exception.Message),'Model download failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        return
    }
    $downloadCode=@'
param($ModelPlan,$State)
$ErrorActionPreference='Stop'
try {
    [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
    for($index=0;$index -lt $ModelPlan.Count;$index++){
        if($State['CancelRequested']){ throw 'Download cancelled by user.' }
        $mi=$ModelPlan[$index]
        $outFile=[string]$mi.DownloadPath
        $State['Index']=$index+1; $State['Count']=$ModelPlan.Count
        $State['Name']=[string]$mi.Name; $State['Bytes']=[long]0
        $State['Total']=[long]$mi.RemoteSize; $State['Phase']='Connecting'
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        $downloaded=$false; $lastError=''
        for($attempt=1;$attempt -le 2 -and -not $downloaded;$attempt++){
            $request=$null; $response=$null; $inputStream=$null; $outputStream=$null
            try {
                if($State['CancelRequested']){ throw 'Download cancelled by user.' }
                $request=[System.Net.HttpWebRequest]::Create([string]$mi.RemoteUrl)
                $request.Method='GET'; $request.Timeout=60000; $request.ReadWriteTimeout=120000; $request.UserAgent='Sootglass-Studio'
                $State['CurrentRequest']=$request
                if($State['CancelRequested']){ $request.Abort(); throw 'Download cancelled by user.' }
                $State['Phase']='Downloading'
                $response=$request.GetResponse()
                if($response.ContentLength -gt 0){ $State['Total']=[long]$response.ContentLength }
                $inputStream=$response.GetResponseStream()
                $outputStream=[System.IO.File]::Create($outFile)
                $buffer=New-Object byte[] 1048576
                while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
                    if($State['CancelRequested']){ throw 'Download cancelled by user.' }
                    $outputStream.Write($buffer,0,$read)
                    $State['Bytes']=[long]$State['Bytes']+$read
                }
                $outputStream.Flush()
                $downloaded=$true
            } catch {
                if($State['CancelRequested']){ throw }
                $lastError=$_.Exception.Message
                if($attempt -lt 2){ Start-Sleep -Milliseconds 800 }
            } finally {
                if($outputStream){ $outputStream.Dispose() }
                if($inputStream){ $inputStream.Dispose() }
                if($response){ $response.Dispose() }
                $State['CurrentRequest']=$null
            }
            if(-not $downloaded){ Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
        }
        if(-not $downloaded){
            $State['Phase']='Retrying with curl'
            $curlExe=(Get-Command curl.exe -ErrorAction SilentlyContinue).Source
            if(-not $curlExe){ throw ('Download failed: '+$lastError) }
            $psi=New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName=$curlExe; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
            $psi.RedirectStandardError=$true
            $quotedOut='"'+$outFile.Replace('"','\"')+'"'
            $quotedUrl='"'+([string]$mi.RemoteUrl).Replace('"','\"')+'"'
            $psi.Arguments='-sL --fail --show-error --max-time 7200 -o '+$quotedOut+' '+$quotedUrl
            $curl=New-Object System.Diagnostics.Process
            $curl.StartInfo=$psi
            if(-not $curl.Start()){ throw ('Download failed: '+$lastError) }
            $State['CurrentProcess']=$curl
            while(-not $curl.WaitForExit(250)){
                if($State['CancelRequested']){
                    try { $curl.Kill() } catch {}
                    try { $curl.WaitForExit() } catch {}
                    throw 'Download cancelled by user.'
                }
            }
            $curlError=$curl.StandardError.ReadToEnd()
            $curlExit=$curl.ExitCode
            $State['CurrentProcess']=$null
            $curl.Dispose()
            if($State['CancelRequested']){ throw 'Download cancelled by user.' }
            if($curlExit -ne 0){ throw ('Download failed: '+$curlError.Trim()) }
            if(Test-Path -LiteralPath $outFile -PathType Leaf){ $State['Bytes']=[long](Get-Item -LiteralPath $outFile).Length }
            $downloaded=$true
        }
        if(-not (Test-Path -LiteralPath $outFile -PathType Leaf)){ throw ('The '+$mi.Name+' download did not produce a file.') }
        $got=[long](Get-Item -LiteralPath $outFile).Length
        if($got -le 0){ throw ('The '+$mi.Name+' download was empty.') }
        if([long]$mi.RemoteSize -gt 0 -and $got -ne [long]$mi.RemoteSize){ throw ('download size mismatch for '+$mi.Name) }
        $State['Bytes']=$got; $State['Phase']='File ready'
    }
    if($State['CancelRequested']){ throw 'Download cancelled by user.' }
    $State['Ok']=$true
} catch {
    $State['Ok']=$false
    $State['Cancelled']=[bool]$State['CancelRequested']
    if($State['Cancelled']){ $State['Error']='Download cancelled by user.' }
    else { $State['Error']=$_.Exception.Message }
} finally {
    $State['CurrentRequest']=$null
    $State['CurrentProcess']=$null
    $State['Done']=$true
}
'@
    $progress=New-Object System.Windows.Forms.Form
    $progress.Text='Downloading model files'; $progress.ClientSize=New-Object System.Drawing.Size(420,116); $progress.StartPosition='CenterParent'; $progress.FormBorderStyle='FixedDialog'; $progress.ControlBox=$false; $progress.ShowInTaskbar=$false
    $progressLabel=New-Object System.Windows.Forms.Label; $progressLabel.Location=New-Object System.Drawing.Point(12,10); $progressLabel.Size=New-Object System.Drawing.Size(396,30); $progressLabel.AutoEllipsis=$true; $progress.Controls.Add($progressLabel)
    $progressBar=New-Object System.Windows.Forms.ProgressBar; $progressBar.Location=New-Object System.Drawing.Point(12,44); $progressBar.Size=New-Object System.Drawing.Size(396,20); $progressBar.Style='Continuous'; $progress.Controls.Add($progressBar)
    $cancelBtn=Add-Button $progress 'Cancel download' 292 76 116 28; $cancelBtn.AccessibleName='Cancel model download'
    $state=[System.Collections.Hashtable]::Synchronized((New-Object System.Collections.Hashtable))
    $state['Done']=$false; $state['Ok']=$false; $state['Cancelled']=$false; $state['CancelRequested']=$false
    $state['Error']=''; $state['Bytes']=[long]0; $state['Total']=[long]0; $state['Index']=0; $state['Count']=$modelPlan.Count
    $state['Name']=''; $state['Phase']='Starting'; $state['CurrentRequest']=$null; $state['CurrentProcess']=$null
    $runner=$null; $job=$null; $timer=$null
    $script:MossModelDownload=@{
        Active=$true; State=$state; ModelPlan=$modelPlan; SettingsPlan=$requiredModels
        Stamp=$stamp; Runner=$null; Job=$null; Timer=$null; Form=$progress; Label=$progressLabel
        Progress=$progressBar; CancelButton=$cancelBtn; Owner=$Owner
    }
    try {
        $runner=[powershell]::Create()
        [void]$runner.AddScript($downloadCode).AddArgument($modelPlan).AddArgument($state)
        $job=$runner.BeginInvoke()
        $script:MossModelDownload['Runner']=$runner; $script:MossModelDownload['Job']=$job
        $timer=New-Object System.Windows.Forms.Timer; $timer.Interval=250
        $script:MossModelDownload['Timer']=$timer
        $timer.Add_Tick({
            $dl=$script:MossModelDownload
            if(-not $dl -or -not $dl['Active']){ return }
            $st=$dl['State']
            if(-not $st['Done']){
                $dl['Label'].Text=('Downloading '+$st['Index']+' of '+$st['Count']+': '+$st['Name']+' - '+(Format-MossModelSize $st['Bytes'])+' of '+(Format-MossModelSize $st['Total']))
                if([string]$st['Phase'] -eq 'Retrying with curl'){
                    $dl['Progress'].Style='Marquee'; $dl['Progress'].MarqueeAnimationSpeed=25
                } else {
                    if($dl['Progress'].Style -ne 'Continuous'){ $dl['Progress'].Style='Continuous' }
                    if([long]$st['Total'] -gt 0){ $dl['Progress'].Value=[Math]::Min(100,[int](([long]$st['Bytes']*100)/[long]$st['Total'])) }
                }
                return
            }
            $dl['Timer'].Stop()
            try { [void]$dl['Runner'].EndInvoke($dl['Job']) } catch {
                if(-not $st['Error']){ $st['Error']=$_.Exception.Message; $st['Ok']=$false }
            }
            try { $dl['Runner'].Dispose() } catch {}
            $dl['Runner']=$null; $dl['Job']=$null
            if($st['Cancelled']){
                foreach($mi in $dl['ModelPlan']){ try { Remove-Item -LiteralPath ([string]$mi.DownloadPath) -Force -ErrorAction SilentlyContinue } catch {} }
                $dl['Active']=$false; $dl['Progress'].Visible=$false
                $dl['Label'].Text='Download cancelled. No model files were installed.'
                $dl['CancelButton'].Text='Close'; $dl['CancelButton'].Enabled=$true
                $dl['Form'].AcceptButton=$dl['CancelButton']
                return
            }
            if(-not $st['Ok']){
                foreach($mi in $dl['ModelPlan']){ try { Remove-Item -LiteralPath ([string]$mi.DownloadPath) -Force -ErrorAction SilentlyContinue } catch {} }
                $dl['Active']=$false
                [System.Windows.Forms.MessageBox]::Show($dl['Owner'],("The model download failed:`r`n`r`n"+[string]$st['Error']+"`r`n`r`nNo model files were installed. The engine and graphics runtime were not changed."),'Model download failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
                $dl['Form'].Close()
                return
            }
            $dl['CancelButton'].Enabled=$false; $dl['CancelButton'].Text='Installing...'
            $dl['Label'].Text='Download complete. Installing model files and updating settings...'
            $dl['Progress'].Style='Marquee'; $dl['Progress'].MarqueeAnimationSpeed=25
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $installed=Install-MossModelFiles -ModelPlan $dl['ModelPlan'] -TempRoot $script:AppRoot -Stamp $dl['Stamp'] -SettingsPlan $dl['SettingsPlan'] -OnProgress {
                    param($mi,$index,$count)
                    $dl=$script:MossModelDownload
                    $dl['Label'].Text=('Installing model '+$index+' of '+$count+': '+$mi.Name)
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $done=($installed | ForEach-Object { $_.Name }) -join "`r`n  "
                $dl['Active']=$false
                [System.Windows.Forms.MessageBox]::Show($dl['Owner'],("Model files installed successfully:`r`n`r`n  {0}`r`n`r`nThe engine and graphics runtime were not downloaded or changed. The new precision takes effect on the next generation." -f $done),'Models installed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
                $dl['Form'].Close()
            } catch {
                foreach($mi in $dl['ModelPlan']){ try { Remove-Item -LiteralPath ([string]$mi.DownloadPath) -Force -ErrorAction SilentlyContinue } catch {} }
                $dl['Active']=$false
                [System.Windows.Forms.MessageBox]::Show($dl['Owner'],("The model install failed:`r`n`r`n"+$_.Exception.Message+"`r`n`r`nThe engine and graphics runtime were not changed."),'Model download failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
                $dl['Form'].Close()
            }
        })
        $cancelBtn.Add_Click({
            $dl=$script:MossModelDownload
            if($dl -and $dl['Active']){
                $st=$dl['State']; $st['CancelRequested']=$true
                try { if($st['CurrentRequest']){ $st['CurrentRequest'].Abort() } } catch {}
                try { if($st['CurrentProcess'] -and -not $st['CurrentProcess'].HasExited){ $st['CurrentProcess'].Kill() } } catch {}
                $dl['Label'].Text='Cancelling download...'
                $dl['CancelButton'].Text='Cancelling...'; $dl['CancelButton'].Enabled=$false
                $dl['Progress'].Style='Marquee'; $dl['Progress'].MarqueeAnimationSpeed=25
                return
            }
            $dl['Form'].Close()
        })
        $progress.Add_FormClosing({
            $dl=$script:MossModelDownload
            if($dl -and $dl['Active']){
                $_.Cancel=$true
                $dl['CancelButton'].PerformClick()
            }
        })
        $timer.Start()
        if($Owner){ [void]$progress.ShowDialog($Owner) } else { [void]$progress.ShowDialog() }
    } catch {
        if($state){ $state['CancelRequested']=$true; try { if($state['CurrentRequest']){ $state['CurrentRequest'].Abort() } } catch {}; try { if($state['CurrentProcess'] -and -not $state['CurrentProcess'].HasExited){ $state['CurrentProcess'].Kill() } } catch {} }
        if($runner){ try { $runner.Stop() } catch {}; try { $runner.Dispose() } catch {} }
        foreach($mi in $modelPlan){ try { Remove-Item -LiteralPath ([string]$mi.DownloadPath) -Force -ErrorAction SilentlyContinue } catch {} }
        [System.Windows.Forms.MessageBox]::Show($Owner,("The model download could not be started:`r`n`r`n"+$_.Exception.Message),'Model download failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
    } finally {
        if($timer){ try { $timer.Stop(); $timer.Dispose() } catch {} }
        if($runner){ try { $runner.Dispose() } catch {} }
        if($progress -and -not $progress.IsDisposed){ $progress.Dispose() }
        $script:MossModelDownload=$null
    }
}
function Show-MossSwitchModels([System.Windows.Forms.Form]$Owner=$null) {
    $g=New-Object System.Windows.Forms.Form
    $g.Text='Switch models (precision)'
    $g.ClientSize=New-Object System.Drawing.Size(760,420); $g.MinimumSize=New-Object System.Drawing.Size(776,459); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
    $g.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185); $cGreen=[System.Drawing.Color]::FromArgb(125,205,164); $cRed=[System.Drawing.Color]::FromArgb(224,138,138)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text='SWITCH MODELS  -  pick the precision to use'; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(12,10); $g.Controls.Add($ttl)
    $sub=New-Object System.Windows.Forms.Label; $sub.Text='All precisions share the VAE, the tokenizer and the engine - only the diffusion model and the LLM differ. Switching to an installed precision is INSTANT (no download). Missing files can be fetched from here.'
    $sub.Location=New-Object System.Drawing.Point(12,40); $sub.Size=New-Object System.Drawing.Size(720,36); $sub.ForeColor=$cMuted; $g.Controls.Add($sub)
    $infos=Get-MossPrecisionInfo
    if($infos.Count -eq 1 -and $infos[0] -is [array]){ $infos=$infos[0] }
    $radios=@(); $row=0
    foreach($inf in $infos){
        $displayLabel=[string]$inf.Label
        if([string]$inf.Key -eq 'quantized') { $displayLabel='Quantized (default) - int8 diffusion + 4-bit Q4 LLM' }
        elseif([string]$inf.Key -eq 'q8') { $displayLabel='High quality - Q8 LLM (near-lossless)' }
        elseif([string]$inf.Key -eq 'bf16') { $displayLabel='Full 16-bit BF16 - best quality, about 28 GB' }
        $rb=New-Object System.Windows.Forms.RadioButton; $rb.Text=$displayLabel
        $rb.Location=New-Object System.Drawing.Point(14,(90+$row*68)); $rb.Size=New-Object System.Drawing.Size(700,34); $rb.ForeColor=$cText; $rb.Checked=$inf.Current; $rb.AccessibleName=('Select model precision: '+$inf.Label); $rb.TabIndex=$row; $rb.AutoEllipsis=$true; $g.Controls.Add($rb); $radios+=$rb
        $stat=New-Object System.Windows.Forms.Label
        $stat.Text=$(if($inf.Current){ $(if($inf.Ready){'IN USE - ready'}else{'IN USE - FILES MISSING!'}) } elseif($inf.Ready){'Installed - click Use selected to switch instantly'} else {'Not installed - use Download missing... to install'})
        $stat.Location=New-Object System.Drawing.Point(34,(124+$row*68)); $stat.Size=New-Object System.Drawing.Size(680,22); $stat.ForeColor=$(if($inf.Ready){$cGreen}else{$cRed}); $g.Controls.Add($stat)
        $row++
    }
    $status=New-Object System.Windows.Forms.Label; $status.Location=New-Object System.Drawing.Point(12,300); $status.Size=New-Object System.Drawing.Size(720,40); $status.ForeColor=$cMuted; $g.Controls.Add($status)
    $useBtn=Add-Button $g 'Use selected' 12 348 140 34; $useBtn.AccessibleName='Use selected model precision'; $useBtn.TabIndex=3; $useBtn.FlatStyle='Flat'; $useBtn.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $useBtn.ForeColor=[System.Drawing.Color]::White
    $getBtn=Add-Button $g 'Download missing...' 164 348 180 34; $getBtn.FlatStyle='Flat'; $getBtn.AccessibleName='Download missing model files'; $getBtn.TabIndex=4
    $closeBtn=Add-Button $g 'Close' 356 348 88 34; $closeBtn.FlatStyle='Flat'; $closeBtn.AccessibleName='Close model precision dialog'; $closeBtn.TabIndex=5
    $useBtn.Add_Click({
        $sel=$null
        for($i=0;$i -lt $radios.Count;$i++){ if($radios[$i].Checked){ $sel=@($infos)[$i] } }
        if(-not $sel){ return }
        if(-not $sel.Ready){
            $status.Text=('This precision is not downloaded yet. Use Download missing... to fetch only its model files - or pick an installed one.')
            return
        }
        try {
            $script:Settings['DiffusionModelPath']=Get-RelativeAppPath $sel.DiffPath
            $script:Settings['LlmPath']=Get-RelativeAppPath $sel.LlmPath
            if(Save-Settings){
                $status.Text=('Switched to: '+$sel.Label+'. Takes effect on the next generation.')
            }
        } catch { $status.Text=('Switch failed: '+$_.Exception.Message) }
    })
    $getBtn.Add_Click({
        $sel=$null
        for($i=0;$i -lt $radios.Count;$i++){ if($radios[$i].Checked){ $sel=@($infos)[$i] } }
        if(-not $sel){ return }
        $g.Close()
        Show-MossModelVariantDownload $Owner $sel.Key
    })
    $closeBtn.Add_Click({$g.Close()})
    [void]$g.ShowDialog($Owner)
    $g.Dispose()
}

# v0.3.5: resilient download helper - Invoke-RestMethod/WebRequest on the
# legacy .NET stack intermittently gets HTTP 504 from GitHub; curl.exe
# (bundled with Windows) gets through. Two IWR attempts, then curl fallback.
function Save-MossWebFile([string]$Url,[string]$OutFile,[int]$TimeoutSec) {
    for($att=1;$att -le 2;$att++){
        try {
            [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
            if((Test-Path -LiteralPath $OutFile -PathType Leaf) -and (Get-Item -LiteralPath $OutFile).Length -gt 0){ return 'iwr' }
        } catch { Start-Sleep -Milliseconds 800 }
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }
    $curlExe=(Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if($curlExe){
        & $curlExe -sL --max-time $TimeoutSec -o $OutFile $Url
        if((Test-Path -LiteralPath $OutFile -PathType Leaf) -and (Get-Item -LiteralPath $OutFile).Length -gt 0){ return 'curl' }
    }
    throw ('Download failed after retries: '+$Url)
}

function Show-MossEngineUpdateDialog([System.Windows.Forms.Form]$Owner=$null,[string]$Preselect='') {
    # UPDATING THE ENGINE (sd-cli core files) - deliberately separate from the
    # 'Update Sootglass...' header button: Sootglass is only the GUI, while sd-cli.exe
    # and its libraries in the bin folder are the engine that renders images.
    # This dialog updates those engine files from the official
    # stable-diffusion.cpp releases and shows the published changelogs.
    # Models, outputs, config and the Sootglass application files are never touched.
    if ($null -ne $script:GenState -and $script:GenState.IsRunning) {
        [System.Windows.Forms.MessageBox]::Show($Owner,'A generation is running. Wait for it to finish (or cancel it) before updating the engine files.','Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        return
    }
    $enginePath=Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)
    if(-not (Test-Path -LiteralPath $enginePath -PathType Leaf)){
        # v0.3.2: a missing engine must NOT block the update dialog - that is
        # exactly when the user needs it (chicken-and-egg: the dialog used to
        # demand sd-cli.exe before it would download one). Fall back to the
        # default bin folder so the fresh engine installs there.
        $enginePath=Join-Path $script:AppRoot 'bin\sd-cli.exe'
    }
    $engineBin=[System.IO.Path]::GetDirectoryName($enginePath)
    $installedCommit=Get-MossEngineCommit $enginePath
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
    $log=New-Object System.Collections.ArrayList
    [void]$log.Add(('Engine update started '+(Get-Date -Format 'u')))
    [void]$log.Add(('Engine path: '+$enginePath))
    [void]$log.Add(('Installed commit: '+$(if($installedCommit){$installedCommit}else{'unknown'})))
    # v0.3.5 BUGFIX: PowerShell 5.1's .NET HTTP stack intermittently receives
    # HTTP 504 from the GitHub API (legacy TLS/HTTP2 negotiation), while the
    # bundled curl.exe gets through. Try Invoke-RestMethod twice, then fall
    # back to curl.exe before declaring the feed unreadable.
    $rawReleases=$null
    foreach($att in @(1,2)){
        try {
            [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
            $rawReleases=Invoke-RestMethod -Uri 'https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=10' -Method Get -Headers @{Accept='application/vnd.github+json';'User-Agent'='Sootglass-Studio'} -TimeoutSec 15
            [void]$log.Add(('Release feed read via Invoke-RestMethod (attempt '+$att+')'))
            break
        } catch {
            [void]$log.Add(('Release feed attempt '+$att+' failed: '+$_.Exception.Message))
            $rawReleases=$null
            Start-Sleep -Milliseconds 500
        }
    }
    if($null -eq $rawReleases){
        try {
            $curlExe=(Get-Command curl.exe -ErrorAction SilentlyContinue).Source
            if($curlExe){
                $curlOut=& $curlExe -s --max-time 25 -H 'Accept: application/vnd.github+json' -H 'User-Agent: Sootglass-Studio' 'https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=10'
                if($curlOut){
                    $rawReleases=($curlOut -join "`n") | ConvertFrom-Json
                    [void]$log.Add('Release feed read via curl.exe fallback')
                }
            }
        } catch { [void]$log.Add(('curl.exe fallback failed: '+$_.Exception.Message)) }
    }
    $releases=@($rawReleases)
    # Windows PowerShell 5.1 can deliver a JSON array as one nested array
    # object; unwrap it so $releases holds one PSCustomObject per release.
    if($releases.Count -ge 1 -and $releases[0] -isnot [pscustomobject] -and $releases[0] -is [System.Collections.IEnumerable]){
        $releases=@($releases[0] | ForEach-Object { $_ })
    }
    $releases=@($releases | Where-Object { $_.PSObject.Properties['tag_name'] })
    if($releases.Count -eq 0){
        [void]$log.Add('ERROR: the release feed could not be read (offline or blocked)')
        try { $logDir=Join-Path $script:AppRoot 'logs'; if(-not(Test-Path -LiteralPath $logDir)){New-Item -ItemType Directory -Path $logDir -Force|Out-Null}; ($log -join "`r`n") | Set-Content -LiteralPath (Join-Path $logDir ('engine-update-'+$stamp+'.txt')) -Encoding UTF8 } catch {}
        $answer=[System.Windows.Forms.MessageBox]::Show($Owner,"Sootglass could not read the engine release feed (offline or blocked?).`r`n`r`nOpen the releases page to check and download manually?`r`nChoose No to open the backup-restore dialog instead (works offline).",'Engine update',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
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
    # v0.3.13: widened 730 -> 800 - at 150% DPI the extra-variant checkbox row
    # ('CUDA 12 (NVIDIA)', 'Vulkan (any GPU)', 'CPU only') overflowed the old
    # client width and the last box was cut off at the right edge.
    $g.Size=New-Object System.Drawing.Size(800,768); $g.MinimumSize=New-Object System.Drawing.Size(770,748); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false
    $g.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text='UPDATE ENGINE  -  sd-cli core files'; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(12,10); $g.Controls.Add($ttl)
    $sub=New-Object System.Windows.Forms.Label; $sub.Text="Sootglass is the GUI - sd-cli.exe and its libraries are the engine that renders the images. This dialog updates only those engine files; the Sootglass app, models, prompts, outputs and settings are never touched."; $sub.Location=New-Object System.Drawing.Point(12,40); $sub.Size=New-Object System.Drawing.Size(690,44); $sub.ForeColor=$cMuted; $g.Controls.Add($sub)
    $installedText=$(if($installedCommit){'commit '+$installedCommit}else{'version could not be read'})
    $verPanel=New-Object System.Windows.Forms.Panel; $verPanel.Location=New-Object System.Drawing.Point(12,88); $verPanel.Size=New-Object System.Drawing.Size(690,46); $verPanel.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $g.Controls.Add($verPanel)
    $vin=New-Object System.Windows.Forms.Label; $vin.Text='INSTALLED'; $vin.Location=New-Object System.Drawing.Point(10,4); $vin.Size=New-Object System.Drawing.Size(340,15); $vin.Font=New-Object System.Drawing.Font('Segoe UI',8); $vin.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $verPanel.Controls.Add($vin)
    $vinv=New-Object System.Windows.Forms.Label; $vinv.Text=$installedText; $vinv.Location=New-Object System.Drawing.Point(10,20); $vinv.Size=New-Object System.Drawing.Size(340,20); $vinv.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $verPanel.Controls.Add($vinv)
    $vla=New-Object System.Windows.Forms.Label; $vla.Text='LATEST RELEASE'; $vla.Location=New-Object System.Drawing.Point(370,4); $vla.Size=New-Object System.Drawing.Size(310,15); $vla.Font=New-Object System.Drawing.Font('Segoe UI',8); $vla.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $verPanel.Controls.Add($vla)
    $vlav=New-Object System.Windows.Forms.Label; $vlav.Text=($(if($upToDate){$latestTag+'   -  UP TO DATE'}else{$latestTag})); $vlav.Location=New-Object System.Drawing.Point(370,20); $vlav.Size=New-Object System.Drawing.Size(310,20); $vlav.ForeColor=($(if($upToDate){[System.Drawing.Color]::FromArgb(125,205,164)}else{[System.Drawing.Color]::FromArgb(125,205,164)})); if(-not $upToDate){$vlav.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245)}; $verPanel.Controls.Add($vlav)
    $listLabel=New-Object System.Windows.Forms.Label; $listLabel.Text='RECENT RELEASES (select one to read its changelog)'; $listLabel.Location=New-Object System.Drawing.Point(12,140); $listLabel.Size=New-Object System.Drawing.Size(330,20); $listLabel.ForeColor=$cMuted; $g.Controls.Add($listLabel)
    $releaseList=New-Object System.Windows.Forms.ListBox; $releaseList.Location=New-Object System.Drawing.Point(12,162); $releaseList.Size=New-Object System.Drawing.Size(330,176); $releaseList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $releaseList.ForeColor=$cText; $releaseList.BorderStyle='FixedSingle'; $g.Controls.Add($releaseList)
    $notesLabel=New-Object System.Windows.Forms.Label; $notesLabel.Text='RELEASE NOTES / CHANGELOG'; $notesLabel.Location=New-Object System.Drawing.Point(356,140); $notesLabel.Size=New-Object System.Drawing.Size(330,20); $notesLabel.ForeColor=$cMuted; $g.Controls.Add($notesLabel)
    $notes=New-Object System.Windows.Forms.TextBox; $notes.Multiline=$true; $notes.ReadOnly=$true; $notes.ScrollBars='Vertical'; $notes.WordWrap=$true; $notes.Location=New-Object System.Drawing.Point(356,162); $notes.Size=New-Object System.Drawing.Size(346,176); $notes.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $notes.ForeColor=$cText; $notes.BorderStyle='FixedSingle'; $notes.Font=New-Object System.Drawing.Font('Consolas',8); $g.Controls.Add($notes)
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
    $variant=[System.Windows.Forms.ComboBox]::new();; $variant.DropDownStyle='DropDownList';; $variant.Location=New-Object System.Drawing.Point(12,364); $variant.Size=New-Object System.Drawing.Size(280,26); $variant.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $variant.ForeColor=$cText; $g.Controls.Add($variant); Set-MossComboTheme $variant $g
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
    $extraFlow=New-Object System.Windows.Forms.FlowLayoutPanel; $extraFlow.Location=New-Object System.Drawing.Point(12,432); $extraFlow.Size=New-Object System.Drawing.Size([Math]::Max(200, $g.ClientSize.Width - 24),30); $extraFlow.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $extraFlow.WrapContents=$false; $g.Controls.Add($extraFlow)
    $variantLabelOf={
        param($key)
        if($key -like 'cuda*'){ return ('CUDA '+$key.Substring(4)+' (NVIDIA)  ') }
        switch($key){ 'vulkan' { return 'Vulkan (any GPU)  ' } 'rocm' { return 'AMD ROCm  ' } 'sycl' { return 'Intel SYCL  ' } 'cpu' { return 'CPU only  ' } }  # trailing spaces: CheckBox.AutoSize under-measures at 150% DPI and clips the last glyph
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
    # v0.3.5: NVIDIA-only defaults. An NVIDIA card never runs AMD ROCm
    # engine files, so default to filtering them out when NVIDIA is detected.
    $script:MossHasNvidia=$false
    try { $script:MossHasNvidia=(@(Get-GpuInventory | Where-Object { -not $_.IsVirtual -and $_.Vendor -eq 'NVIDIA' }).Count -gt 0) } catch {}
    $script:MossNvidiaOnly=[bool]$script:MossHasNvidia
    $syncVariantCombo={
        if($releaseList.SelectedIndex -lt 0 -or $releaseList.SelectedIndex -ge $releases.Count){ return }
        $rel=$releases[$releaseList.SelectedIndex]
        $cudaVers=@()
        foreach($a in @($rel.assets)){ $an=[string]$a.name; if($an -match 'bin-win-cuda([0-9]+(?:\.[0-9]+)?)-x64\.zip'){ $cudaVers+=$Matches[1] } }
        $cudaVers=@($cudaVers | Sort-Object -Unique | Sort-Object -Property { $v=[string]$_; if($v -notmatch '\.'){ $v=$v+'.0' }; [version]$v } -Descending)
        $concrete=@()
        foreach($cv in $cudaVers){ $concrete+=('cuda'+$cv) }
        if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-vulkan-x64.zip' }).Count -gt 0){ $concrete+='vulkan' }
        # v0.3.5: with NVIDIA-only on, the AMD ROCm packages are filtered out
        # entirely (an ROCm engine can never run on an NVIDIA card).
        if(-not $script:MossNvidiaOnly){
            if(@($rel.assets | Where-Object { [string]$_.name -like '*bin-win-rocm*' }).Count -gt 0){ $concrete+='rocm' }
        } else {
            [void]$log.Add('NVIDIA-only mode: AMD ROCm engine packages are not offered or downloaded.')
        }
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
        # v0.3.5: NVIDIA-only option - an AMD ROCm engine can never run on an
        # NVIDIA card, so with this on the AMD packages are not even offered
        # (nothing downloads that the user has no reason to want). Default ON
        # when an NVIDIA GPU was detected.
        if($script:MossHasNvidia){
            $nvCb=New-Object System.Windows.Forms.CheckBox; $nvCb.Text='NVIDIA only - skip AMD (ROCm) packages (not needed for NVIDIA)'; $nvCb.AutoSize=$true; $nvCb.Checked=$script:MossNvidiaOnly; $nvCb.ForeColor=$cMuted
            $tip.SetToolTip($nvCb,'AMD ROCm engine files only run on AMD GPUs. On your NVIDIA card they would never be used, so with this checked they are never downloaded, shown or installed. Vulkan (any GPU) and Intel SYCL stay available.')
            $nvCb.Add_CheckedChanged({
                if($script:MossNvidiaOnly -ne $nvCb.Checked){ $script:MossNvidiaOnly=$nvCb.Checked; & $syncVariantCombo }
            })
            [void]$extraFlow.Controls.Add($nvCb)
        }
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
    $modelsList=New-Object System.Windows.Forms.CheckedListBox; $modelsList.Location=New-Object System.Drawing.Point(12,488); $modelsList.Size=New-Object System.Drawing.Size(690,64); $modelsList.CheckOnClick=$true; $modelsList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $modelsList.ForeColor=$cText; $modelsList.BorderStyle='FixedSingle'
    foreach($mi in $script:MossDlgModels){
        [void]$modelsList.Items.Add(($mi.Name+'   ('+(Format-MossModelSize $mi.RemoteSize)+' download'+$(if($mi.Status -eq 'update available'){', update'}else{', new install'})+')'))
        $modelsList.SetItemChecked($modelsList.Items.Count-1,$true)
    }
    $modelsList.Visible=($script:MossDlgModels.Count -gt 0)
    $g.Controls.Add($modelsList)
    $modelBackupCheck=New-Object System.Windows.Forms.CheckBox; $modelBackupCheck.Text='Back up the old model files first (renamed to <name>.old-<time> - instant; the newest 3 backups are kept)'; $modelBackupCheck.Location=New-Object System.Drawing.Point(12,590); $modelBackupCheck.Size=New-Object System.Drawing.Size(690,22); $modelBackupCheck.ForeColor=$cMuted; $modelBackupCheck.Visible=($script:MossDlgModels.Count -gt 0); $modelBackupCheck.Checked=$true; $g.Controls.Add($modelBackupCheck)
    # v0.3.4: MODEL PRECISION - choose how the diffusion model and the text
    # encoder LLM are quantized. Changing it repopulates the MODELS list
    # above; the existing download/install machinery fetches exactly the
    # files that differ from the local ones and repoints the settings.
    $script:MossDlgVariant='quantized'
    if(@('quantized','q8','bf16') -contains $Preselect){ $script:MossDlgVariant=$Preselect }
    else {
        try {
            $llmName=[System.IO.Path]::GetFileName([string]$script:Settings['LlmPath'])
            if($llmName -like '*BF16*'){ $script:MossDlgVariant='bf16' } elseif($llmName -like '*Q8_0*'){ $script:MossDlgVariant='q8' }
        } catch {}
    }
    $precLabel=New-Object System.Windows.Forms.Label; $precLabel.Text='MODEL PRECISION:'; $precLabel.Location=New-Object System.Drawing.Point(12,564); $precLabel.Size=New-Object System.Drawing.Size(110,20); $precLabel.ForeColor=$cMuted; $g.Controls.Add($precLabel)
    $precCombo=New-Object System.Windows.Forms.ComboBox;; $precCombo.DropDownStyle='DropDownList'; $precCombo.Location=New-Object System.Drawing.Point(126,560); $precCombo.Size=New-Object System.Drawing.Size(240,26); $precCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $precCombo.ForeColor=$cText; $g.Controls.Add($precCombo); Set-MossComboTheme $precCombo $g
    [void]$precCombo.Items.Add('Quantized  (default, ~11 GB)')
    [void]$precCombo.Items.Add('High quality - Q8 LLM  (~15 GB)')
    [void]$precCombo.Items.Add('Full 16-bit BF16  (~28 GB)')
    $precCombo.SelectedIndex = $(switch($script:MossDlgVariant){ 'bf16' {2} 'q8' {1} default {0} })
    $precHelp=Add-Button $g 'Precision?' 380 556 100 28
    $modelsOnlyBtn=Add-Button $g 'Download models only...' 492 556 210 28; $modelsOnlyBtn.AccessibleName='Download only the selected precision model files'; $modelsOnlyBtn.Enabled=($script:MossDlgModels.Count -gt 0)
    $tip.SetToolTip($modelsOnlyBtn,'Downloads only checked missing/updated model files. Keep both required model files checked to switch precision. The installed NVIDIA/CUDA, AMD/ROCm, Intel/SYCL or other engine runtime is not downloaded or changed.')
    $modelsOnlyBtn.Add_Click({
        $selectedVariant=[string]$script:MossDlgVariant
        $selectedModels=@()
        foreach($idx in $modelsList.CheckedIndices){
            if($idx -ge 0 -and $idx -lt $script:MossDlgModels.Count){ $selectedModels+=,$script:MossDlgModels[$idx] }
        }
        $g.Hide()
        try { Show-MossModelVariantDownload $Owner $selectedVariant $selectedModels } finally { $g.Close() }
    })
    $tip.SetToolTip($precCombo,'How the diffusion model and text encoder are stored: quantized (small, fast) or full 16-bit BF16 (best quality, ~28 GB, needs model offloading on a 12 GB GPU).')
    $precHelp.Add_Click({
        [System.Windows.Forms.MessageBox]::Show($g,(@"
MODEL PRECISION - what the options mean

The two big models behind every image are the DIFFUSION model (paints the image) and the TEXT ENCODER LLM (reads your prompt). Each exists in several precisions - how many bytes store each number of the network:

- Quantized (default, ~11 GB total): diffusion as int8 (5.4 GB) + LLM as 4-bit Q4 GGUF (5.7 GB). ~8x smaller than 16-bit with a barely visible quality loss. Fastest load, smallest VRAM use. Recommended.

- High quality - Q8 LLM (~15 GB total): diffusion stays int8, the LLM becomes near-lossless 8-bit Q8 (9.5 GB). Slightly better prompt understanding.

- Full 16-bit BF16 (~28 GB total): the reference quality build - BF16 IS the 16-bit build (there is no separate FP16 file). Diffusion 10.2 GB + LLM 17.9 GB. Downloads are twice as big and load slower, and the pair does not fit in a 12 GB GPU at once - the engine automatically offloads parts to system RAM, so each image renders slower.

Switching downloads only the files that are not already on disk and updates the settings. You can switch back any time - the old files are kept as backups and disk space is only used by the variants you actually download.
"@
),'What is model precision?',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    })
    $precCombo.Add_SelectedIndexChanged({
        $newVar = $(switch($precCombo.SelectedIndex){ 2 {'bf16'} 1 {'q8'} default {'quantized'} })
        if($newVar -eq $script:MossDlgVariant){ return }
        $precCombo.Enabled=$false
        try {
            $g.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
            $script:MossDlgVariant=$newVar
            $allInfos=@(Get-MossModelUpdateInfo $newVar)
            $script:MossDlgModels=@($allInfos | Where-Object { $_.Status -eq 'update available' -or $_.Status -eq 'not installed' })
            $modelsList.Items.Clear()
            foreach($mi in $script:MossDlgModels){
                [void]$modelsList.Items.Add(($mi.Name+'   ('+(Format-MossModelSize $mi.RemoteSize)+' download'+$(if($mi.Status -eq 'update available'){', update'}else{', new install'})+')'))
                $modelsList.SetItemChecked($modelsList.Items.Count-1,$true)
            }
            $modelsList.Visible=($script:MossDlgModels.Count -gt 0)
            $modelBackupCheck.Visible=($script:MossDlgModels.Count -gt 0)
            $modelsLabel.Text=$(if($script:MossDlgModels.Count -gt 0){'MODELS - '+$script:MossDlgModels.Count+' file(s) of the selected precision are missing (checked = download and install):'}else{'MODELS - all files of the selected precision are already on disk.'})
            $modelsOnlyBtn.Enabled=($script:MossDlgModels.Count -gt 0)
        } catch { $modelsOnlyBtn.Enabled=$false; $modelsLabel.Text=('The precision check failed: '+$_.Exception.Message) }
        finally { $g.Cursor=[System.Windows.Forms.Cursors]::Default; $precCombo.Enabled=$true }
    })
    $installBtn=New-Object System.Windows.Forms.Button; $installBtn.Text='Download and install...'; $installBtn.Location=New-Object System.Drawing.Point(12,618); $installBtn.Size=New-Object System.Drawing.Size(180,32); $installBtn.FlatStyle='Flat'; $installBtn.BackColor=[System.Drawing.Color]::FromArgb(45,112,173); $installBtn.ForeColor=[System.Drawing.Color]::White; $g.Controls.Add($installBtn)
    $restoreBtn=New-Object System.Windows.Forms.Button; $restoreBtn.Text='Restore a backup...'; $restoreBtn.Location=New-Object System.Drawing.Point(202,618); $restoreBtn.Size=New-Object System.Drawing.Size(150,32); $restoreBtn.FlatStyle='Flat'; $restoreBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $restoreBtn.ForeColor=$cText; $g.Controls.Add($restoreBtn)
    $pageBtn=New-Object System.Windows.Forms.Button; $pageBtn.Text='Open releases page'; $pageBtn.Location=New-Object System.Drawing.Point(362,618); $pageBtn.Size=New-Object System.Drawing.Size(150,32); $pageBtn.FlatStyle='Flat'; $pageBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $pageBtn.ForeColor=$cText; $g.Controls.Add($pageBtn)
    # v0.3.3: when only SOME engine files are lost, offer an instant local
    # repair from the per-commit cache zip instead of a full 437 MB download.
    $script:MossDlgRepair=$null
    try { $script:MossDlgRepair=Get-MossEngineCacheInfo $engineBin } catch { $script:MossDlgRepair=$null }
    $repairBtn=New-Object System.Windows.Forms.Button; $repairBtn.Text='Repair files...'; $repairBtn.Location=New-Object System.Drawing.Point(522,618); $repairBtn.Size=New-Object System.Drawing.Size(100,32); $repairBtn.FlatStyle='Flat'; $repairBtn.BackColor=[System.Drawing.Color]::FromArgb(39,90,61); $repairBtn.ForeColor=[System.Drawing.Color]::White; $repairBtn.Visible=($null -ne $script:MossDlgRepair); $g.Controls.Add($repairBtn)
    if($script:MossDlgRepair){
        $repInfo=$script:MossDlgRepair
        $status.Text=('SMART REPAIR AVAILABLE: '+$repInfo.Missing.Count+' engine file(s) missing ('+(($repInfo.Missing | Select-Object -First 3) -join ', ')+$(if($repInfo.Missing.Count -gt 3){', ...'}else{''})+') and the local cache zip for commit '+$repInfo.Commit+' has them. Use Repair files... - no download needed.')
    }
    $closeBtn=New-Object System.Windows.Forms.Button; $closeBtn.Text='Close'; $closeBtn.Location=New-Object System.Drawing.Point(630,618); $closeBtn.Size=New-Object System.Drawing.Size(80,32); $closeBtn.FlatStyle='Flat'; $closeBtn.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $closeBtn.ForeColor=$cText; $g.Controls.Add($closeBtn)
    $status=New-Object System.Windows.Forms.Label; $status.Location=New-Object System.Drawing.Point(12,658); $status.Size=New-Object System.Drawing.Size(690,50); $status.ForeColor=$cMuted; $status.Text='Pick a release above to read its changelog. Engine files and models are checked at the same time; the current engine files are backed up before anything changes; models are only touched when you select a model update. Use Restore a backup... to roll back the engine.'; $g.Controls.Add($status)
    $pageBtn.Add_Click({ try { Start-Process 'https://github.com/leejet/stable-diffusion.cpp/releases' } catch { [System.Windows.Forms.MessageBox]::Show($g,'The releases page could not be opened. Visit github.com/leejet/stable-diffusion.cpp and open Releases.','Engine update')|Out-Null } })
    $closeBtn.Add_Click({$g.Close()})
    $restoreBtn.Add_Click({ Show-MossEngineBackupRestore $g $enginePath $engineBin $log $stamp })
    $repairBtn.Add_Click({
        $rep=$script:MossDlgRepair
        if(-not $rep){ return }
        try {
            $fixed=@()
            $archiveR=[System.IO.Compression.ZipFile]::OpenRead([string]$rep.ZipPath)
            try {
                foreach($nR in $rep.Missing){
                    $entryR=@($archiveR.Entries | Where-Object { [System.IO.Path]::GetFileName([string]$_.FullName) -eq $nR } | Select-Object -First 1)
                    if(-not $entryR){ throw ('The cache zip does not contain '+$nR+'.') }
                    $esR=$entryR.Open()
                    try { $fsR=[System.IO.File]::Create((Join-Path $engineBin $nR)); try { $esR.CopyTo($fsR) } finally { $fsR.Dispose() } } finally { $esR.Dispose() }
                    $fixed+=$nR
                }
            } finally { $archiveR.Dispose() }
            $vOut=Get-MossEngineVersionOutput $enginePath
            if([string]::IsNullOrWhiteSpace($vOut)){ throw 'The missing files were restored, but sd-cli.exe still does not start (no version output). The engine may need a different variant - use Download and install... instead.' }
            [void]$log.Add(('Smart repair: restored '+$fixed.Count+' file(s) from local cache zip '+$rep.ZipPath+': '+(($fixed | Sort-Object) -join ', ')))
            $repairBtn.Visible=$false
            $script:MossDlgRepair=$null
            [System.Windows.Forms.MessageBox]::Show($g,("Repair complete - no download was needed.`r`n`r`nRestored from the local cache (commit "+$rep.Commit+"):`r`n  "+(($fixed | Sort-Object) -join "`r`n  ")+"`r`n`r`nEngine check: "+$vOut),'Engine repaired',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        } catch {
            [void]$log.Add(('ERROR in smart repair: '+$_.Exception.Message))
            [System.Windows.Forms.MessageBox]::Show($g,("The repair from the local cache failed:`r`n`r`n"+$_.Exception.Message+"`r`n`r`nUse Download and install... for a full fresh download."),'Engine repair failed',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
        }
    })
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
        if($modelPlan.Count -gt 0){ [void]$log.Add(('Models to update: '+(($modelPlan | ForEach-Object { $_.Name }) -join ', ')+' ('+(Format-MossModelSize $modelsTotal)+' total)')) }
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
            [void]$log.Add(('ERROR: insufficient disk space (temp free '+(Format-MossModelSize $freeTemp 1)+', engine-drive free '+(Format-MossModelSize $freeBin 1)+', need ~'+(Format-MossModelSize $needTemp 1)+' and ~'+(Format-MossModelSize $needBin 1)+')'))
            [System.Windows.Forms.MessageBox]::Show($g,("Not enough free disk space for the engine update.`r`n`r`nNeeded: about {0} on the temp drive ({1}) and {2} on {3}`r`nAvailable: {4} and {5}`r`n`r`nFree up some space (or install fewer variants) and try again." -f (Format-MossModelSize $needTemp 1),[System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath()).TrimEnd('\'),(Format-MossModelSize $needBin 1),[System.IO.Path]::GetPathRoot($engineBin).TrimEnd('\'),(Format-MossModelSize $freeTemp 1),(Format-MossModelSize $freeBin 1)),'Engine update',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
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
        $modelText=if($modelPlan.Count -gt 0){ ((($modelPlan | ForEach-Object { $localBytes=[int64]0; $localAvailable=[int64]::TryParse([string]$_.LocalSize,[System.Globalization.NumberStyles]::Integer,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$localBytes) -and $localBytes -gt 0; '  '+$_.Name+'  ('+(Format-MossModelSize $_.RemoteSize)+' download, current file: '+$(if($localAvailable){Format-MossModelSize $localBytes}else{'not installed'})+')' }) -join "`r`n")+"`r`n  Old model files: "+$(if($modelBackupCheck.Checked){'kept as <name>.old-<time> (renamed, instant - older backups beyond the newest 3 are deleted automatically)'}else{'overwritten WITHOUT a backup'})) } else { '  (no model updates selected)' }
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
        foreach($mi in $modelPlan){ $dlText+=(('  '+$mi.Name+'  ('+(Format-MossModelSize $mi.RemoteSize)+')')+"`r`n") }
        $backupZip=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) ('engine-backup-'+$stamp+'.zip')
        # Legacy (pre-compression) folder name, only checked when no zip exists.
        $backupDir=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) ('engine-backup-'+$stamp)
        $answer=[System.Windows.Forms.MessageBox]::Show($g,("Ready to install the update:`r`n`r`nRelease: {0}`r`nInstall plan:`r`n{1}Models to update:`r`n{2}Download:`r`n{3}Engine backup (compressed zip): {4}`r`nDisk space needed: about {5} on the temp drive and {6} on the engine+models drive`r`nEstimated model download time: {7}`r`n`r`nMOSS will be unresponsive during the download (several minutes on slower connections; GB-sized models take longer).`r`n`r`nInstall now?" -f $relTag,$planText,$modelText,$dlText,$backupZip,(Format-MossModelSize $needTemp 1),(Format-MossModelSize $needBin 1),$timeText),'Install engine & model update',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){ return }
        $oldProgress=$ProgressPreference; $ProgressPreference='SilentlyContinue'
        $tempRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('Sootglass-Engine-Update-'+[guid]::NewGuid().ToString('N'))
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
                [void](Save-MossWebFile ([string]$a.browser_download_url) $zipPath 3600)
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
                [void](Save-MossWebFile ([string]$ca.browser_download_url) $cudartZip 3600)
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
            # v0.3.3: keep a per-commit copy of the installed engine files as ONE
            # zip (engines\cache-<commit>.zip) so a LOST FILE can later be
            # repaired locally with zero download (a GitHub release only offers
            # the whole ~437 MB zip per variant). Machine-code DLLs compress
            # poorly: files > 8 MB are stored with Fastest, small files Optimal.
            if($newCommit){
                try {
                    $cacheRoot=Join-Path ([System.IO.Path]::GetDirectoryName($engineBin)) 'engines'
                    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
                    $cacheZip=Join-Path $cacheRoot ('cache-'+$newCommit+'.zip')
                    $cacheFiles=@($engineFiles[$primaryPlan.Key])
                    if($primaryPlan.Key -like 'cuda*'){
                        $mjC=$primaryPlan.Key.Substring(4).Split('.')[0]
                        if($cudartFilesByMaj.ContainsKey($mjC)){ $cacheFiles=@($cacheFiles)+@($cudartFilesByMaj[$mjC]) }
                    }
                    if(Test-Path -LiteralPath $cacheZip -PathType Leaf){ Remove-Item -LiteralPath $cacheZip -Force }
                    $cacheArchive=[System.IO.Compression.ZipFile]::Open($cacheZip,[System.IO.Compression.ZipArchiveMode]::Create)
                    try {
                        foreach($srcC in $cacheFiles){
                            $lvlC=[System.IO.Compression.CompressionLevel]::Optimal
                            if((Get-Item -LiteralPath $srcC).Length -gt 8MB){ $lvlC=[System.IO.Compression.CompressionLevel]::Fastest }
                            $nameC=[System.IO.Path]::GetFileName($srcC)
                            $entryC=$cacheArchive.CreateEntry($nameC,$lvlC)
                            $esC=$entryC.Open()
                            try { $fsC=[System.IO.File]::OpenRead($srcC); try { $fsC.CopyTo($esC) } finally { $fsC.Dispose() } } finally { $esC.Dispose() }
                        }
                        $mfC=$cacheArchive.CreateEntry('manifest.txt',[System.IO.Compression.CompressionLevel]::Optimal)
                        $esM=$mfC.Open()
                        try {
                            $swM=New-Object System.IO.StreamWriter($esM)
                            try {
                                foreach($srcC in $cacheFiles){ $swM.WriteLine(('{0}`t{1}' -f [System.IO.Path]::GetFileName($srcC),(Get-Item -LiteralPath $srcC).Length)) }
                            } finally { $swM.Dispose() }
                        } finally { $esM.Dispose() }
                    } finally { $cacheArchive.Dispose() }
                    [void]$log.Add(('Engine file cache saved: '+$cacheZip+' ('+$cacheFiles.Count+' files, '+[math]::Round((Get-Item -LiteralPath $cacheZip).Length/1MB)+' MB) - lost engine files can now be repaired locally without any download'))
                    # Keep at most 2 caches: delete the oldest beyond that.
                    $oldCaches=@(Get-ChildItem -LiteralPath $cacheRoot -File -Filter 'cache-*.zip' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $cacheZip } | Sort-Object -Property Name -Descending)
                    for($ci=2; $ci -lt $oldCaches.Count; $ci++){ try { Remove-Item -LiteralPath $oldCaches[$ci].FullName -Force -ErrorAction Stop; [void]$log.Add(('Deleted old engine file cache beyond the limit of 2: '+$oldCaches[$ci].Name)) } catch {} }
                } catch { [void]$log.Add(('WARNING: the engine file cache could not be saved: '+$_.Exception.Message)) }
            }
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
                    $status.Text=('Downloading model '+$mi.Name+' ('+(Format-MossModelSize $mi.RemoteSize)+')...')
                    [System.Windows.Forms.Application]::DoEvents()
                    [void]$log.Add(('Downloading model '+$mi.RemoteUrl))
                    $mTemp=Join-Path $tempRoot ('model-'+$mi.Name+'.part')
                    $dlSw=[System.Diagnostics.Stopwatch]::StartNew()
                    [void](Save-MossWebFile ([string]$mi.RemoteUrl) $mTemp 7200)
                    $dlSw.Stop()
                    $got=(Get-Item -LiteralPath $mTemp).Length
                    if($mi.RemoteSize -gt 0 -and $got -ne $mi.RemoteSize){ throw ('download size mismatch (got '+(Format-MossModelSize $got)+', expected '+(Format-MossModelSize $mi.RemoteSize)+')') }
                    # Record the REAL download speed (v0.1.88): the most honest
                    # signal for future 'about X minutes' estimates - blended
                    # with fresh probes when the cache is stale.
                    $dlMBps=0.0
                    if($dlSw.Elapsed.TotalSeconds -gt 1 -and $got -gt 1MB){ $dlMBps=($got/1MB)/$dlSw.Elapsed.TotalSeconds; Save-MossRealDownloadSpeed $dlMBps $got }
                    [void]$log.Add(('Model download ok ('+(Format-MossModelSize $got)+$(if($dlMBps -gt 0){(' at '+[math]::Round($dlMBps,1)+' MB/s')}else{''})+'))'))
                    $destModel=$mi.LocalPath; if(-not $destModel){ $destModel=Join-Path $script:AppRoot ('models\'+$mi.Name) }
                    if(-not (Test-MossModelTargetName $destModel ([string]$mi.Name))){ throw ('Model target mismatch: refusing to rename or overwrite '+[System.IO.Path]::GetFileName($destModel)+' as '+[string]$mi.Name) }
                    if((Test-Path -LiteralPath $destModel -PathType Leaf) -and $modelBackupCheck.Checked){
                        $oldName=Get-MossModelBackupPath $destModel $stamp
                        Rename-Item -LiteralPath $destModel -Destination $oldName -Force
                        [void]$log.Add(('Old model kept as '+(Split-Path -Leaf $oldName)))
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
                    # v0.3.4: a PRECISION SWITCH installs a file with a NEW name
                    # (e.g. moss_image_sft_bf16 instead of ..._int8_convrot) -
                    # repoint the settings key so the generator loads it.
                    if($mi.Setting){
                        try {
                            $newRel=Get-RelativeAppPath $destModel
                            if([string]$script:Settings[$mi.Setting] -ne $newRel){
                                $script:Settings[$mi.Setting]=$newRel
                                if(Save-Settings){ [void]$log.Add(('Settings updated: '+$mi.Setting+' -> '+$newRel)) }
                            }
                        } catch { [void]$log.Add(('WARNING: could not update settings key '+$mi.Setting+': '+$_.Exception.Message)) }
                    }
                    $modelOk++
                    $modelLines+=("`r`nModel updated: "+$mi.Name+" ("+(Format-MossModelSize $mi.RemoteSize)+")")
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
                    $restoreStage=Join-Path ([System.IO.Path]::GetTempPath()) ('Sootglass-Backup-Restore-'+[guid]::NewGuid().ToString('N'))
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
function Start-MossCaptureReaders($Process,$Capture) {
    $readerScript = {
        param($stream,$capture,$key)
        try {
            while ($true) {
                $line = $stream.ReadLine()
                if ($null -eq $line) { break }
                $capture[$key] = [string]$capture[$key] + $line + "`n"
            }
        } catch {}
    }
    $runners=@()
    $asyncResults=@()
    try {
        foreach($key in @('Out','Err')) {
            $stream=if($key -eq 'Out'){$Process.StandardOutput}else{$Process.StandardError}
            $runner=[powershell]::Create()
            [void]$runner.AddScript($readerScript).AddArgument($stream).AddArgument($Capture).AddArgument($key)
            $async=$runner.BeginInvoke()
            $runners+=,$runner
            $asyncResults+=,$async
        }
    } catch {
        foreach($runner in $runners) {
            try { $runner.Stop() } catch {}
            try { $runner.Dispose() } catch {}
        }
        throw
    }
    return [pscustomobject]@{ Runners=$runners; Async=$asyncResults }
}

function Show-MossAboutDialog([System.Windows.Forms.Form]$Owner=$null) {
    $d=New-Object System.Windows.Forms.Form
    $d.Text='About Sootglass Studio'
    $d.ClientSize=New-Object System.Drawing.Size(520,252)
    $d.StartPosition='CenterParent'; $d.FormBorderStyle='FixedDialog'; $d.MaximizeBox=$false; $d.MinimizeBox=$false; $d.ShowInTaskbar=$false
    $d.BackColor=[System.Drawing.Color]::FromArgb(25,32,45); $d.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $d.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $title=New-Object System.Windows.Forms.Label; $title.Text='Sootglass Studio'; $title.Location=New-Object System.Drawing.Point(18,14); $title.Size=New-Object System.Drawing.Size(480,30); $title.Font=New-Object System.Drawing.Font('Segoe UI Semibold',15,[System.Drawing.FontStyle]::Bold); $d.Controls.Add($title)
    $description=New-Object System.Windows.Forms.Label; $description.Text='Independent GUI for stable-diffusion.cpp, configured for OpenMOSS MOSS-Image.'; $description.Location=New-Object System.Drawing.Point(18,52); $description.Size=New-Object System.Drawing.Size(480,38); $description.ForeColor=[System.Drawing.Color]::FromArgb(170,184,204); $d.Controls.Add($description)
    $version=New-Object System.Windows.Forms.Label; $version.Text=("Sootglass Studio v{0}  |  Model weights: Apache-2.0" -f $script:AppVersion); $version.Location=New-Object System.Drawing.Point(18,96); $version.Size=New-Object System.Drawing.Size(480,22); $version.ForeColor=[System.Drawing.Color]::FromArgb(170,184,204); $d.Controls.Add($version)
    $website=New-Object System.Windows.Forms.LinkLabel;     $website.Text='OpenMOSS MOSS-Image webpage'; $website.Location=New-Object System.Drawing.Point(18,132); $website.Size=New-Object System.Drawing.Size(450,22); $website.LinkColor=[System.Drawing.Color]::FromArgb(120,180,245); $d.Controls.Add($website)
    $website.Add_LinkClicked({ try { Start-Process -FilePath 'https://openmoss.ai/MOSS-Image/' } catch { [System.Windows.Forms.MessageBox]::Show('The MOSS-Image webpage could not be opened.','About Sootglass Studio')|Out-Null } })
    $github=New-Object System.Windows.Forms.LinkLabel; $github.Text='OpenMOSS/MOSS-Image on GitHub'; $github.Location=New-Object System.Drawing.Point(18,162); $github.Size=New-Object System.Drawing.Size(450,22); $github.LinkColor=[System.Drawing.Color]::FromArgb(120,180,245); $d.Controls.Add($github)
    $github.Add_LinkClicked({ try { Start-Process -FilePath 'https://github.com/OpenMOSS/MOSS-Image' } catch { [System.Windows.Forms.MessageBox]::Show('The MOSS-Image GitHub repository could not be opened.','About Sootglass Studio')|Out-Null } })
    $close=New-Object System.Windows.Forms.Button; $close.Text='Close'; $close.Location=New-Object System.Drawing.Point(414,204); $close.Size=New-Object System.Drawing.Size(88,30); $close.FlatStyle='Flat'; $close.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $close.ForeColor=$d.ForeColor; $d.Controls.Add($close)
    $close.Add_Click({$d.Close()}.GetNewClosure()); $d.AcceptButton=$close; $d.CancelButton=$close
    [void]$d.ShowDialog($Owner)
    $d.Dispose()
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
        Steps = 50; CfgScale = 3.0; Width = 1360; Height = 768; ImageCount = 1; Seed = -1
        NegativePrompt = ''; SamplingMethod = 'Default (model)'; Scheduler = 'Default (model)'
        # v0.3.6 engine features (all optional, engine 3b12781+):
        # LivePreview - engine writes step preview PNGs to a temp folder and
        # the Output preview pane shows the newest one while rendering.
        # SageAttention - native CUDA attention speedup. OffloadToCpu - keep
        # weights in RAM, load to VRAM on demand (VRAM relief, slower).
        # CacheMode - 'EasyCache' skips redundant DiT compute between steps.
        LivePreview = '1'; SageAttention = '0'; OffloadToCpu = '0'; CacheMode = 'Off'
        # v0.3.7 Advanced tuning (all optional; blank/off = flag omitted):
        # Guidance = distilled guidance scale (engine default 3.5).
        # Circular = tileable output padding. SamplerRng = sampler RNG mode.
        # MaxVram = per-device VRAM budget in GiB. EagerLoad / DisablePrefetch
        # = loading behaviour experiments.
        Guidance = ''; Circular = 'off'; SamplerRng = ''; MaxVram = ''; EagerLoad = '0'; DisablePrefetch = '0'
        # v0.3.8 LoRA support (engine 3b12781): LoRAs are selected by PROMPT
        # tags <lora:file_stem:multiplier> resolved against --lora-model-dir;
        # there are no per-LoRA CLI flags. LoraSelection stores checked stems
        # and their strengths ('stem:0.8|stem2:1.0', pipe-separated).
        # LoraApplyMode is persisted but not exposed (engine default 'auto').
        LoraDir = 'models\loras'; LoraSelection = ''; LoraApplyMode = 'auto'
        # v0.3.9 preview choices (Generation dialog): which decoder the engine
        # uses for step previews and how often a preview is written.
        # vae default (user: proj preview was unreadable until the last steps;
        # vae decodes with the real VAE so the preview looks like the result).
        PreviewMethod = 'vae'; PreviewInterval = '4'
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
    # One-off queued runs (currently only the quick benchmark uses this).
    $script:BenchQueue = New-Object System.Collections.ArrayList
    $script:BenchTotal = 0
    $script:BenchStartedAt = $null

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
    # and got much shorter. The action row follows the controls on taller resizes.
    $f.Text = "Sootglass Studio v$($script:AppVersion) | stable-diffusion.cpp GUI"; $f.ClientSize=New-Object System.Drawing.Size(1000,500); $f.MinimumSize=New-Object System.Drawing.Size(880,539); $f.StartPosition='CenterScreen'
    # Restore position and size before the first show so the window opens
    # directly at its saved bounds instead of visibly resizing after startup.
    # Update-MossWorkspaceLayout sizes the panels once all controls exist.
    try { Restore-MossWindowBounds $f } catch {}
    # v0.2.3: the window is shown EARLY (frame + header + the two card
    # panels) and the controls are added while the user already looks at it.
    # The old code built every control first and only then showed the
    # window, so Sootglass stayed invisible for ~0.8 s. The screen-fit code that
    # used to run in the Shown event now runs explicitly after the build
    # (see below) - the Shown event fires far too early for it.
    # v0.2.3: this lives in a SCRIPT variable, not on the Form: assigning an
    # unknown property to a .NET object ('$f.ScreenFit = {...}') throws in
    # PowerShell (the same trap as ComboBox.FlatAppearance).
    $script:MossScreenFit={
        $sc=[System.Windows.Forms.Screen]::FromControl($f)
        $wa = $sc.WorkingArea
        $mw = [Math]::Min(880, $wa.Width - 16)
        $mh = [Math]::Min(539, $wa.Height - 16)
        $f.MinimumSize = New-Object System.Drawing.Size([Math]::Max(600,$mw), [Math]::Max(500,$mh))
        $nw = [Math]::Min($f.Width, $wa.Width - 16)
        $nh = [Math]::Min($f.Height, $wa.Height - 16)
        if ($nw -ne $f.Width -or $nh -ne $f.Height) {
            $f.Size = New-Object System.Drawing.Size($nw, $nh)
            $f.Location = New-Object System.Drawing.Point(($wa.Left+[int](($wa.Width - $nw) / 2)), ($wa.Top+[int](($wa.Height - $nh) / 2)))
        }
    }
    # v0.3.13: the page background used to be a distinct darker tone
    # (18,22,31), which read as stray 'stripes' at the sides and bottom
    # wherever the card panels left a margin. The main window background is
    # now the same tone as the cards (27,34,47) so the margins blend away,
    # and the cards carry a subtle 1 px border so they still read as panels.
    $f.BackColor=[System.Drawing.Color]::FromArgb(27,34,47); $f.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $f.Font=New-Object System.Drawing.Font('Segoe UI',9)
    # Keep the form hidden while its controls are created and positioned.
    # Application.Run shows it only after the saved-size layout is ready.
    try { $f.Refresh() } catch {}
    $cPanel=[System.Drawing.Color]::FromArgb(25,32,45); $cCard=[System.Drawing.Color]::FromArgb(27,34,47); $cText=[System.Drawing.Color]::FromArgb(230,236,245); $cMuted=[System.Drawing.Color]::FromArgb(145,161,185); $cAccent=[System.Drawing.Color]::FromArgb(45,112,173)

    # Compact header (v0.1.96): 68 -> 50 px, title 17 pt -> 13 pt, buttons
    # 30 px -> 24 px tall. Same responsive placement logic as before.
    $head=New-Object System.Windows.Forms.Panel; $head.Dock='Top'; $head.Height=50; $head.BackColor=$cPanel; $f.Controls.Add($head)
    $ttl=New-Object System.Windows.Forms.Label; $ttl.Text="Sootglass  /  IMAGE STUDIO  v$($script:AppVersion)"; $ttl.Font=New-Object System.Drawing.Font('Segoe UI Semibold',13,[System.Drawing.FontStyle]::Bold); $ttl.AutoSize=$true; $ttl.Location=New-Object System.Drawing.Point(20,5); $head.Controls.Add($ttl)
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
    $subt=New-Object System.Windows.Forms.Label; $subt.Text="LOCAL IMAGE GENERATION  -  $gpuSubtitle"; $subt.ForeColor=$cMuted; $subt.AutoSize=$true; $head.Controls.Add($subt)
    # DPI-SAFE HEADER STACK (artifact fix): the old fixed offsets (title y=5,
    # subtitle y=29 in a 50 px header) overlapped at 150% DPI - the title
    # label's bottom edge cut a horizontal line through the subtitle's glyphs
    # (visible as a strike through 'TION'). The subtitle now sits BELOW the
    # title's actual rendered height and the header grows to fit, so it is
    # correct at any DPI.
    $ttl.Location=New-Object System.Drawing.Point(20,4)
    $subt.Location=New-Object System.Drawing.Point(23, ($ttl.Bottom + 2))
    $neededHead = $subt.Bottom + 6
    if ($head.Height -lt $neededHead) { $head.Height = $neededHead }
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
    # Sootglass) fold into ONE 'Options' dropdown button - the header stays
    # uncluttered and narrower windows keep room for the BACKEND badge.
    # Header OPTIONS MENU (v0.1.97/98): app-level entries live here instead
    # of cluttering the main window - Output folder..., Model files...,
    # Benchmarks..., Error report plus Hardware / Setup and the updaters.
    # Item labels show live status (folder name, model-file health) on open.
    $mossOptionsMenu=New-Object System.Windows.Forms.ContextMenuStrip
    $mossOptionsMenu.ShowItemToolTips=$true
    $miHistoryCode=$mossOptionsMenu.Items.Add('Prompt history code...')
    $miHistoryCode.AccessibleName='Manage encrypted prompt history code'
    $miHistoryCode.ToolTipText='Unlock saved prompts, set a new history code, or turn prompt history off.'
    $miHistoryCode.Add_Click({ Show-MossHistoryCodeMenu $f })
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
    $miLora=$mossOptionsMenu.Items.Add('LoRA models...')
    $miLora.ToolTipText='Optional LoRA add-ons for Sootglass: see which are published for Sootglass and download the ones you want. Nothing is fetched without your confirmation.'
    $miLora.Add_Click({ Show-MossLoraDownloadDialog $f })
    [void]$mossOptionsMenu.Items.Add('-')
    $miBench=$mossOptionsMenu.Items.Add('Benchmarks...')
    $miBench.ToolTipText='Measured render times per size/steps, time estimates for your settings and bigger jobs, and the quick benchmark.'
    $miBench.Add_Click({ Show-MossBenchmarkDialog })
    $miReport=$mossOptionsMenu.Items.Add('Error report')
    $miReport.ToolTipText='Copies an anonymised technical error report to the clipboard and saves it under logs. Nothing is sent over the internet.'
    $miReport.Add_Click({ Copy-MossErrorReport })
    [void]$mossOptionsMenu.Items.Add('-')
    $miAbout=$mossOptionsMenu.Items.Add('About Sootglass Studio...')
    $miAbout.ToolTipText='About this GUI for stable-diffusion.cpp, with links to the OpenMOSS MOSS-Image project.'
    $miAbout.Add_Click({ Show-MossAboutDialog $f })
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
    $miEngine.ToolTipText='Updates the sd-cli engine core files (the renderer in the bin folder): shows release changelogs and installs the newest engine build. Sootglass itself is not changed.'
    $miSwitch=$mossOptionsMenu.Items.Add('Switch models...')
    $miSwitch.Add_Click({ Show-MossSwitchModels $f })
    $miSwitch.ToolTipText='Switch between installed model precisions instantly (Quantized / Q8 / BF16) - or jump to the Update dialog to download a missing variant. Shares VAE, tokenizer and engine; only the diffusion model and the LLM differ.'
    $miUpdate=$mossOptionsMenu.Items.Add('Update Sootglass...')
    $miUpdate.ToolTipText="Updates the Sootglass application itself (the program files). Models, outputs and the sd-cli engine are not touched. Use 'Update engine...' for the rendering engine."
    [void]$mossOptionsMenu.Items.Add('-')
    $miReset=$mossOptionsMenu.Items.Add('Reset all settings to defaults...')
    $miReset.ToolTipText='Clear saved preferences and use Sootglass defaults on the next launch. Models, outputs, and encrypted prompt history are preserved.'
    $miReset.Add_Click({ [void](Reset-MossSettings $f) })
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
        $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/kukomamasan/sootglass-studio/releases/latest' -Method Get -Headers @{Accept='application/vnd.github+json';'User-Agent'='Sootglass-Studio'} -TimeoutSec 8
    } catch { $release=$null }
    if($release -and $release.tag_name){
        $latestVersion=$null; $currentVersion=$null; $tagText=([string]$release.tag_name).TrimStart('v','V')
        if([version]::TryParse($tagText,[ref]$latestVersion) -and [version]::TryParse([string]$script:AppVersion,[ref]$currentVersion)){
            if($latestVersion -eq $currentVersion){[System.Windows.Forms.MessageBox]::Show("Sootglass is up to date (v$($script:AppVersion)).",'Sootglass updates',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return}
            if($latestVersion -lt $currentVersion){[System.Windows.Forms.MessageBox]::Show("This Sootglass build (v$($script:AppVersion)) is newer than the latest published release (v$tagText).",'Sootglass updates',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return}
            $answer=[System.Windows.Forms.MessageBox]::Show("A new Sootglass version is available: v$tagText (you have v$($script:AppVersion)). Download and install it now? Sootglass will close, replace the app files, keep config/models/outputs, and restart.",'Sootglass update available',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information)
            if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
            $asset=@($release.assets | Where-Object { $_.name -eq 'Sootglass-Studio.zip' } | Select-Object -First 1)
            if(-not $asset){ $asset=@($release.assets | Where-Object { [string]$_.name -like 'Sootglass-Studio*.zip' } | Select-Object -First 1) }
            if(-not $asset -or -not $asset[0].browser_download_url){[System.Windows.Forms.MessageBox]::Show('This release does not include Sootglass-Studio.zip, so Sootglass cannot install it automatically.','Sootglass updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return}
            try {
                $tempRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('Sootglass-Update-'+[guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
                $zipPath=Join-Path $tempRoot 'Sootglass-Studio.zip'
                [void](Save-MossWebFile ([string]$asset[0].browser_download_url) $zipPath 180)
                Test-MossZipDigest $zipPath $asset[0] -RequireDigest
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive=[System.IO.Compression.ZipFile]::OpenRead($zipPath)
                try {
                    $archiveNames=@($archive.Entries | ForEach-Object { $_.FullName })
                    $allowedNames=@('Sootglass-Studio.ps1','Sootglass-Studio.bat','Sootglass-Studio.vbs','README.txt')
                    if($archiveNames -notcontains 'Sootglass-Studio.ps1' -or @($archiveNames | Where-Object { $_ -notin $allowedNames }).Count -gt 0){throw 'The release ZIP contains unexpected files.'}
                } finally { $archive.Dispose() }
                $helperPath=Join-Path $tempRoot 'Install-Sootglass-Update.ps1'
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
    $allowed=@('Sootglass-Studio.ps1','Sootglass-Studio.bat','Sootglass-Studio.vbs','README.txt')
    $backup=Join-Path $TempRoot 'backup'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach($name in $allowed){$current=Join-Path $AppRoot $name;if(Test-Path -LiteralPath $current -PathType Leaf){Copy-Item -LiteralPath $current -Destination (Join-Path $backup $name) -Force}}
    try {foreach($name in $allowed){$source=Join-Path $stage $name;if(Test-Path -LiteralPath $source -PathType Leaf){Copy-Item -LiteralPath $source -Destination (Join-Path $AppRoot $name) -Force}}}
    catch {foreach($name in $allowed){$saved=Join-Path $backup $name;if(Test-Path -LiteralPath $saved -PathType Leaf){Copy-Item -LiteralPath $saved -Destination (Join-Path $AppRoot $name) -Force}};throw}
    $launcher=Join-Path $AppRoot 'Sootglass-Studio.vbs'
    if(Test-Path -LiteralPath $launcher){Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"'+$launcher+'"')}
} catch {
    [System.Windows.Forms.MessageBox]::Show(('Sootglass update failed: '+$_.Exception.Message),'Sootglass updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
} finally {Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue}
'@
                Set-Content -LiteralPath $helperPath -Value $helperBody -Encoding UTF8
                $helperArgs='-NoProfile -ExecutionPolicy Bypass -File "'+$helperPath+'" -ProcessId '+[string]$PID+' -AppRoot "'+$script:AppRoot+'" -ZipPath "'+$zipPath+'" -TempRoot "'+$tempRoot+'"'
                $powershellExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Start-Process -FilePath $powershellExe -ArgumentList $helperArgs -WindowStyle Hidden | Out-Null
                [System.Windows.Forms.MessageBox]::Show("Sootglass v$tagText is downloaded. This window will close while the app files are replaced; Sootglass will restart when the update is complete.",'Sootglass updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
                $f.Close()
                return
            } catch {
                [System.Windows.Forms.MessageBox]::Show(('Sootglass could not download or prepare the update: '+$_.Exception.Message),'Sootglass updater',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
                if($tempRoot -and (Test-Path -LiteralPath $tempRoot)){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
                return
            }
        } else {[System.Windows.Forms.MessageBox]::Show("Sootglass found release '$($release.tag_name)' but could not compare its version automatically.",'Sootglass updates',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null}
    } else {
        $answer=[System.Windows.Forms.MessageBox]::Show("Sootglass could not read the GitHub release feed. Open the releases page to check manually? The automatic updater needs publicly readable releases.",'Sootglass update check',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
    }
    try { Start-Process 'https://github.com/kukomamasan/sootglass-studio/releases/latest' } catch { [System.Windows.Forms.MessageBox]::Show('The releases page could not be opened. Go to the Sootglass repository on GitHub and open Releases.','Sootglass updates')|Out-Null }
})

    # Compact panels (v0.1.96): start at y=58 (header 50 + 8 gap) and are
    # 496 px tall - exactly the collapsed-content height. The action row,
    # status line and progress bar flow below the content instead of being
    # pinned to a fixed bottom edge.
    $left=New-Object System.Windows.Forms.Panel; $left.Location=New-Object System.Drawing.Point(18,58); $left.Size=New-Object System.Drawing.Size(600,430); $left.Anchor='Top,Bottom,Left'; $left.BackColor=$cCard; $f.Controls.Add($left)
    $right=New-Object System.Windows.Forms.Panel; $right.Location=New-Object System.Drawing.Point(634,58); $right.Size=New-Object System.Drawing.Size(366,430); $right.Anchor='Top,Bottom,Left,Right'; $right.BackColor=$cCard; $f.Controls.Add($right)
    # v0.3.13: subtle 1 px card outline (blends the old background stripes away
    # while keeping the two panels visually separated at any window size)
    $cCardBorder=[System.Drawing.Color]::FromArgb(45,52,66)
    $f.Add_Paint({ param($s,$e)
        try {
            $pen=New-Object System.Drawing.Pen($cCardBorder)
            $g=$e.Graphics
            [void]$g.DrawRectangle($pen,(($left.Left)-1),(($left.Top)-1),(($left.Width)+1),(($left.Height)+1))
            [void]$g.DrawRectangle($pen,(($right.Left)-1),(($right.Top)-1),(($right.Width)+1),(($right.Height)+1))
            $pen.Dispose()
        } catch {}
    }.GetNewClosure())
    $f.Add_Resize({ try { $this.Invalidate() } catch {} })
    try { $left.SuspendLayout() } catch {}
    try { $right.SuspendLayout() } catch {}
    # Controls are built before the form's first paint to avoid showing an
    # intermediate layout while the panels are being populated.
    # v0.2.2: the label box was 22 px tall for a single 9 pt line, so it
    # overlapped the widget below it by 4-5 px. WinForms keeps the label on
    # top (it was added first), which turned that strip into a dead click
    # zone over the top of the input underneath. A 16 px box clears every
    # row: the labels sit above their fields without touching them.
    # v0.3.11: AutoSize so a caption is NEVER clipped. A fixed-width label
    # cuts its text off at the box edge (the user saw 'missing text'); the
    # width argument is now only a minimum, the label grows to fit the text.
    function Add-Label($parent,[string]$text,[int]$x,[int]$y,[int]$w=200) { $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,16); $l.AutoSize=$true; $l.ForeColor=$cMuted; $parent.Controls.Add($l); return $l }
    function Add-TextBox($parent,[string]$value,[int]$x,[int]$y,[int]$w,[int]$h=26) { $t=New-Object System.Windows.Forms.TextBox; $t.Text=$value; $t.Location=New-Object System.Drawing.Point($x,$y); $t.Size=New-Object System.Drawing.Size($w,$h); $t.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $t.ForeColor=$cText; $t.BorderStyle='FixedSingle'; $parent.Controls.Add($t); return $t }
    function Add-Button($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h=29) { $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location=New-Object System.Drawing.Point($x,$y); $b.Size=New-Object System.Drawing.Size($w,$h); $b.FlatStyle='Flat'; $b.BackColor=[System.Drawing.Color]::FromArgb(39,51,69); $b.ForeColor=$cText; $parent.Controls.Add($b); return $b }

    Add-Label $left 'Prompt' 18 10 180 | Out-Null
    $historyLabel=Add-Label $left 'Recent' 255 12 48
    $historyPick=New-Object System.Windows.Forms.ComboBox; $historyPick.DropDownStyle='DropDownList'; $historyPick.Location=New-Object System.Drawing.Point(300,7); $historyPick.Size=New-Object System.Drawing.Size(150,25); $historyPick.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $historyPick.ForeColor=$cText; $left.Controls.Add($historyPick); Set-MossComboTheme $historyPick $left
    $resetHistoryCode=Add-Button $left 'History code...' 411 7 100 25
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
    $paste=Add-Button $left 'Paste' 517 7 75 25
    $paste.Enabled=$true
    # Prompt box (v0.1.95): HALF WIDTH (331 px), same 96 px height (4 lines)
    # - the full-width editor dominated the panel. Fixed width (no Right
    # anchor) so it stays exactly this size when the window grows. (v0.1.96:
    # moved up 5 px with the tightened row spacing.)
    $prompt=New-Object System.Windows.Forms.TextBox; $prompt.Multiline=$true; $prompt.AcceptsReturn=$true; $prompt.AcceptsTab=$false; $prompt.ScrollBars='Vertical'; $prompt.Location=New-Object System.Drawing.Point(18,34); $prompt.Size=New-Object System.Drawing.Size(331,96); $prompt.Anchor='Top,Left'; $prompt.Font=New-Object System.Drawing.Font('Segoe UI',10); $prompt.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $prompt.ForeColor=$cText; $prompt.BorderStyle='FixedSingle'; $left.Controls.Add($prompt)
    $prompt.ReadOnly=$false
    $paste.Add_Click({ try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $clipText=[System.Windows.Forms.Clipboard]::GetText(); $prompt.Text=$clipText; $status.Text=('Pasted {0} characters from clipboard.' -f $clipText.Length) } else { $status.Text='The clipboard does not contain any text.' } } catch { [System.Windows.Forms.MessageBox]::Show('Clipboard text could not be read.','Clipboard') | Out-Null } })
    $historyPick.Add_SelectedIndexChanged({if($historyPick.SelectedIndex -ge 0){$prompt.Text=[string]$historyPick.SelectedItem}})
    function Unlock-MossHistoryAfterShow {
        # The history code prompt appears after the main window is visible, so
        # it opens in context over Sootglass instead of floating alone at startup.
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
            if($choice -eq 'skip'){$script:HistoryLocked=$true;$script:Settings.PromptHistory=@();[System.Windows.Forms.MessageBox]::Show('Sootglass will continue without prompt history. The encrypted history is preserved. You can enter the code later via the History code... button (top left, next to Paste).','History locked')|Out-Null;return}
            if($choice -eq 'reset'){if(Reset-MossHistoryPassword $f){$historyPick.Items.Clear();return};continue}
            if($choice -eq 'disable'){if(Disable-MossHistory){$historyPick.Items.Clear();return};continue}
            if($choice -eq 'plaintext'){if(Disable-MossHistoryPassword){$historyPick.Items.Clear();[System.Windows.Forms.MessageBox]::Show('The locked history was deleted. New recent prompts will be saved without encryption.','History code off',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return};continue}
        }
    }

    # (v0.1.97, user: the image-settings heading was unnecessary - the row
    # now starts directly with the Generation... button.)
    $negInitial=if([string]$script:Settings.NegativePrompt){'negative prompt: set'}else{'negative prompt: not set'}
    $negState=Add-Label $left $negInitial 108 163 240
    function Get-MossEnabledOptionsSummary {
        $enabledOptions=New-Object 'System.Collections.Generic.List[string]'
        if([bool]$script:Settings.SafeMode){$enabledOptions.Add('Safe mode')}
        if([string]$script:Settings.SageAttention -eq '1'){$enabledOptions.Add('SageAttention')}
        if([string]$script:Settings.OffloadToCpu -eq '1'){$enabledOptions.Add('CPU offload (may be slower)')}
        if([string]$script:Settings.CacheMode -eq 'easycache'){$enabledOptions.Add('EasyCache step cache')}
        if([string]$script:Settings.LivePreview -eq '1' -and [string]$script:Settings.PreviewMethod -ne 'none'){
            $previewMethod=[string]$script:Settings.PreviewMethod
            $previewInterval=[string]$script:Settings.PreviewInterval
            $enabledOptions.Add("Live preview ($previewMethod, every $previewInterval steps)")
        }
        $guidanceValue=0.0
        if([double]::TryParse(([string]$script:Settings.Guidance).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$guidanceValue)){
            $enabledOptions.Add("Custom guidance ($($script:Settings.Guidance))")
        }
        switch([string]$script:Settings.Circular){
            'xy' {$enabledOptions.Add('Tileable output (both axes)')}
            'x' {$enabledOptions.Add('Tileable output (width)')}
            'y' {$enabledOptions.Add('Tileable output (height)')}
        }
        $samplerRng=[string]$script:Settings.SamplerRng
        if($samplerRng -in @('std_default','cuda','cpu')){$enabledOptions.Add("Sampler RNG ($samplerRng)")}
        $maxVram=0.0
        if([double]::TryParse(([string]$script:Settings.MaxVram).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$maxVram) -and $maxVram -ge 0){
            if($maxVram -eq 0){$enabledOptions.Add('Max VRAM: live free VRAM (0 GiB)')}
            else {$enabledOptions.Add("Max VRAM: $($script:Settings.MaxVram) GiB")}
        }
        if([string]$script:Settings.EagerLoad -eq '1'){$enabledOptions.Add('Eager load')}
        if([string]$script:Settings.DisablePrefetch -eq '1'){$enabledOptions.Add('Disable weight prefetch')}
        $selectedLoras=@([string]$script:Settings.LoraSelection -split '\|' | Where-Object { $_ -match '^[^:]+:' })
        if($selectedLoras.Count -gt 0){$enabledOptions.Add('LoRAs: '+($selectedLoras -join ', '))}
        if($enabledOptions.Count -eq 0){return 'No optional features are currently enabled.'}
        return "Enabled options:`r`n`r`n- "+($enabledOptions -join "`r`n- ")
    }
    function Show-MossGenerationOptionsDialog {
        # v0.3.11 LAYOUT REWRITE: this dialog used to be ONE 560x1136 px
        # column - taller than most screens (1080p included) - with every
        # section stacked end to end. It also had real defects: the
        # 'Distilled guidance' caption sat 160 px above its own text box and
        # overlapped the 'Step cache' row, several long checkbox captions were
        # clipped (the text ran past the control width), and the main window
        # had no caption at all above the speed-mode dropdown.
        # NOW: a TABBED dialog (Image & sampler / LoRA / Speed & memory /
        # Advanced tuning) that fits on any screen, every caption next to its
        # own control, and every long caption auto-sized so nothing is cut.
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Generation options'; $g.ClientSize=New-Object System.Drawing.Size(640,560); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false; $g.ShowInTaskbar=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        # Auto-size helper: a caption that is too short for its text is
        # CLIPPED (the user sees 'missing text'); AutoSize makes the control
        # exactly as wide as the text, so it can never be cut.
        function Add-AutoLabel($parent,[string]$text,[int]$x,[int]$y) {
            $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.AutoSize=$true; $l.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $parent.Controls.Add($l); return $l
        }
        function Add-WrapLabel($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h) {
            $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,$h); $l.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $parent.Controls.Add($l); return $l
        }
        function Add-Check($parent,[string]$text,[int]$x,[int]$y,[int]$w) {
            $c=New-Object System.Windows.Forms.CheckBox; $c.Text=$text; $c.Location=New-Object System.Drawing.Point($x,$y); $c.AutoSize=$true; $c.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $parent.Controls.Add($c); return $c
        }
        $dlgTip=New-Object System.Windows.Forms.ToolTip; $dlgTip.InitialDelay=200
        # TABS: one section per tab, so the dialog is short and each section
        # is readable instead of one endless scroll of controls.
        $tabs=New-Object System.Windows.Forms.TabControl; $tabs.Location=New-Object System.Drawing.Point(10,8); $tabs.Size=New-Object System.Drawing.Size(620,496); $tabs.Font=New-Object System.Drawing.Font('Segoe UI',9); $tabs.TabIndex=0; $tabs.AccessibleName='Generation option categories'; $g.Controls.Add($tabs)
        $tabMain=New-Object System.Windows.Forms.TabPage; $tabMain.Text='Image & sampler'; $tabMain.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $tabMain.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $tabMain.AutoScroll=$true; $tabs.TabPages.Add($tabMain)
        $tabLora=New-Object System.Windows.Forms.TabPage; $tabLora.Text='LoRA'; $tabLora.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $tabLora.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $tabLora.AutoScroll=$true; $tabs.TabPages.Add($tabLora)
        $tabSpeed=New-Object System.Windows.Forms.TabPage; $tabSpeed.Text='Speed & memory'; $tabSpeed.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $tabSpeed.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $tabSpeed.AutoScroll=$true; $tabs.TabPages.Add($tabSpeed)
        $tabTune=New-Object System.Windows.Forms.TabPage; $tabTune.Text='Advanced tuning'; $tabTune.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $tabTune.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $tabTune.AutoScroll=$true; $tabs.TabPages.Add($tabTune)
        # ---------------- TAB 1: negative prompt + sampler/scheduler -------
        Add-AutoLabel $tabMain 'Negative prompt' 12 8 | Out-Null
        Add-WrapLabel $tabMain 'What the image should NOT contain - e.g. blurry, extra fingers, watermark. Leave it empty for none.' 12 26 576 32 | Out-Null
        $box=New-Object System.Windows.Forms.TextBox; $box.AccessibleName='Negative prompt'; $box.TabIndex=1; $box.Multiline=$true; $box.ScrollBars='Vertical'; $box.Text=[string]$script:Settings.NegativePrompt; $box.Location=New-Object System.Drawing.Point(12,62); $box.Size=New-Object System.Drawing.Size(320,92); $box.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $box.ForeColor=$cText; $box.BorderStyle='FixedSingle'; $tabMain.Controls.Add($box)
        Add-AutoLabel $tabMain 'Sampler' 12 164 | Out-Null
        $optSampler=New-Object System.Windows.Forms.ComboBox; $optSampler.AccessibleName='Sampler'; $optSampler.TabIndex=2; $optSampler.DropDownStyle='DropDownList'; $optSampler.Location=New-Object System.Drawing.Point(12,184); $optSampler.Size=New-Object System.Drawing.Size(200,26); $optSampler.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $optSampler.ForeColor=$cText
        foreach($s in @('Default (euler)','euler','euler_a','heun','dpm2','dpm++2s_a','dpm++2m','dpm++2mv2','ipndm','ipndm_v','lcm','ddim_trailing','tcd','res_multistep','res_2s','er_sde','euler_cfg_pp','euler_a_cfg_pp','euler_ge','dpm++2m_sde','dpm++2m_sde_bt','lms')){[void]$optSampler.Items.Add($s)}
        $storedSampler=[string]$script:Settings.SamplingMethod; if($storedSampler -eq 'Default (model)'){$storedSampler='Default (euler)'}
        $optSampler.SelectedItem=$storedSampler; if($optSampler.SelectedIndex -lt 0){$optSampler.SelectedIndex=0}; $tabMain.Controls.Add($optSampler); Set-MossComboTheme $optSampler $tabMain
        Add-AutoLabel $tabMain 'Scheduler' 300 164 | Out-Null
        $optSched=New-Object System.Windows.Forms.ComboBox; $optSched.AccessibleName='Scheduler'; $optSched.TabIndex=3; $optSched.DropDownStyle='DropDownList'; $optSched.Location=New-Object System.Drawing.Point(300,184); $optSched.Size=New-Object System.Drawing.Size(280,26); $optSched.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $optSched.ForeColor=$cText
        foreach($s in @('Default (Euler/discrete, shift 5)','discrete','karras','exponential','ays','gits','sgm_uniform','simple','smoothstep','kl_optimal','lcm','bong_tangent','ltx2','logit_normal','flux2','flux','beta','llada_image')){[void]$optSched.Items.Add($s)}
        $storedSched=[string]$script:Settings.Scheduler; if($storedSched -eq 'Default (model)'){$storedSched='Default (Euler/discrete, shift 5)'}
        $optSched.SelectedItem=$storedSched; if($optSched.SelectedIndex -lt 0){$optSched.SelectedIndex=0}; $tabMain.Controls.Add($optSched); Set-MossComboTheme $optSched $tabMain
        # Plain-language descriptions: shown inline below each dropdown and on
        # hover, updated as the user browses the lists.
        $samplerDescriptions=@{
          'Default (euler)'="Uses the engine's default for this model: euler. Recommended."
          'euler'='Simple, reliable all-rounder; good at any step count.'
          'euler_a'='Ancestral euler: adds randomness each step - more variety, but the same seed can give slightly different images.'
          'heun'='More accurate per step, but roughly twice the work per step.'
          'dpm2'='Deterministic second-order solver: crisp, sensitive to step count.'
          'dpm++2s_a'='Ancestral second-order solver: sharp detail with some randomness.'
          'dpm++2m'='Fast, converging solver; very good quality at moderate steps. Verified in-house: same detail as euler at HALF the steps (~40% less time).'
          'dpm++2mv2'='Improved variant of dpm++2m, often a little more detail.'
          'ipndm'='Improved pseudo-numerical method: smooth and conservative.'
          'ipndm_v'='Variant of ipndm with a different update schedule.'
          'lcm'='Latent Consistency sampling: tuned for very few steps (4-8) on distilled models.'
          'ddim_trailing'='DDIM with trailing steps: stable, predictable output.'
          'tcd'='Trailing consistency distillation: very fast at low step counts.'
          'res_multistep'='Resolution multistep solver: detailed but slower.'
          'res_2s'='Two-step variant of the resolution multistep solver.'
          'er_sde'='Exponential reverse-time SDE: often softer, painterly detail.'
          'euler_cfg_pp'='Euler with CFG++ guidance handling; can reduce burning at high CFG.'
          'euler_a_cfg_pp'='Ancestral euler with CFG++ guidance handling.'
          'euler_ge'='Euler with geometric extrapolation.'
          'dpm++2m_sde'='DPM++ 2M SDE: often softer, painterly texture.'
          'dpm++2m_sde_bt'='DPM++ 2M SDE backtrack: fewer artefacts, slightly slower.'
          'lms'='Linear multistep solver: classic, conservative.'
        }
        $schedulerDescriptions=@{
          'Default (Euler/discrete, shift 5)'="Uses the Sootglass engine default: Euler sampling with the discrete flow scheduler and shift 5. Recommended."
          'discrete'='Classic discrete sigma schedule (the traditional default).'
          'karras'='Karras schedule: sharper texture on fine detail near the end; often sharper texture at the same step count. Verified in-house: sharper than the default schedule at the same step count.'
          'exponential'='Exponential sigma spacing: smooth, even denoising.'
          'ays'='Align Your Steps: CAUTION - verified incompatible with second-order samplers (dpm++2m family) on this engine: the render continues WITHOUT the scheduler and can come out blank. Use with euler only.'
          'gits'='GITS: trained step distribution, good quality at low step counts.'
          'sgm_uniform'='Uniform schedule from the SGM paper: even coverage of the range.'
          'simple'='Plain uniform sigma spacing.'
          'smoothstep'='Smoothstep spacing: gentler start and finish.'
          'kl_optimal'='Schedule from KL-divergence optimization research.'
          'lcm'='LCM schedule: matches the latent-consistency samplers.'
          'bong_tangent'='Tangent spacing: fewer jumps between step sizes.'
          'ltx2'='LTX-2 schedule, tuned for video-style models.'
          'logit_normal'='Logit-normal spacing: even weight to the middle steps.'
          'flux2'='Schedule tuned for the newer Flux models; a good fit for this engine.'
          'flux'='Original Flux schedule.'
          'beta'='Beta-distribution spacing: modern alternative, often good detail.'
          'llada_image'='Schedule tuned for the LLaDA image model.'
        }
        $samplerDesc=New-Object System.Windows.Forms.Label; $samplerDesc.Location=New-Object System.Drawing.Point(12,214); $samplerDesc.Size=New-Object System.Drawing.Size(280,92); $samplerDesc.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $tabMain.Controls.Add($samplerDesc)
        $schedDesc=New-Object System.Windows.Forms.Label; $schedDesc.Location=New-Object System.Drawing.Point(300,214); $schedDesc.Size=New-Object System.Drawing.Size(280,92); $schedDesc.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $tabMain.Controls.Add($schedDesc)
        $samplerDesc.Text=[string]$samplerDescriptions[[string]$optSampler.SelectedItem]
        $schedDesc.Text=[string]$schedulerDescriptions[[string]$optSched.SelectedItem]
        $dlgTip.SetToolTip($optSampler,$samplerDesc.Text); $dlgTip.SetToolTip($optSched,$schedDesc.Text)
        $optSampler.Add_SelectedIndexChanged({ $samplerDesc.Text=[string]$samplerDescriptions[[string]$optSampler.SelectedItem]; $dlgTip.SetToolTip($optSampler,$samplerDesc.Text) })
        $optSched.Add_SelectedIndexChanged({ $schedDesc.Text=[string]$schedulerDescriptions[[string]$optSched.SelectedItem]; $dlgTip.SetToolTip($optSched,$schedDesc.Text) })
        Add-WrapLabel $tabMain "'Default (euler)' and 'Default (Euler/discrete, shift 5)' use the engine's MOSS-Image defaults - recommended unless you want to experiment." 12 314 576 32 | Out-Null
        # Sootglass is a GUI front-end for the sd-cli command-line engine: optionally
        # log the exact command line before every run (full transparency).
        $cmdCheck=Add-Check $tabMain 'Show the exact sd-cli command line in the log' 12 352 576
        $cmdCheck.AccessibleName='Show exact engine command line in log'; $cmdCheck.TabIndex=4
        $cmdCheck.Checked= (-not $script:Settings.Contains('ShowEngineCommandLine')) -or ([string]$script:Settings.ShowEngineCommandLine -eq '1')
        $safeCheck=Add-Check $tabMain 'Enable content filter (sexual, gore/violence, self-harm)' 12 380 576
        $safeCheck.AccessibleName='Optional content filter'; $safeCheck.TabIndex=5
        $safeCheck.Checked = [bool]$script:Settings.SafeMode
        $safeNote=Add-WrapLabel $tabMain 'Optional filter: blocks common sexual, graphic violence/gore and self-harm terms when selected. A separate safety check always blocks sexualized minors. If a subject described as a teen is an adult, specify 18+.' 12 404 576 44
        $wrapFlags=[System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
        $safeNoteHeight=[System.Windows.Forms.TextRenderer]::MeasureText($safeNote.Text,$safeNote.Font,(New-Object System.Drawing.Size(576,1000)),$wrapFlags).Height
        $safeNote.Height=[Math]::Max(44,$safeNoteHeight+2)
        $dlgTip.SetToolTip($cmdCheck,'Log the exact sd-cli command line Sootglass runs for every image, so you can see every setting.')
        $dlgTip.SetToolTip($safeCheck,'Optional filter for general adult sexual content, graphic violence/gore and self-harm. Minor safety remains active when this is off.')
        # ---------------- TAB 2: LoRA ----------------------------------------
        # v0.3.8 LoRA group: files come from models\loras (stems must be
        # usable inside the engine's <lora:stem:strength> prompt tag).
        Add-AutoLabel $tabLora 'LoRA models (optional trained add-ons)' 12 8 | Out-Null
        $loraFiles=Get-MossLoraFiles
        $loraStems=@(); foreach($lf in $loraFiles){ $loraStems += [string]$lf.Stem }
        $loraDirAbs=Ensure-MossLoraDir
        $loraList=New-Object System.Windows.Forms.CheckedListBox; $loraList.AccessibleName='Available LoRA models'; $loraList.TabIndex=0; $loraList.CheckOnClick=$true; $loraList.Location=New-Object System.Drawing.Point(12,32); $loraList.Size=New-Object System.Drawing.Size(320,170); $loraList.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $loraList.ForeColor=$cText; $loraList.BorderStyle='FixedSingle'
        foreach($ls in $loraStems){ [void]$loraList.Items.Add($ls,$false) }
        # Restore saved selections/strengths; files deleted since are dropped.
        $loraStrengths=@{}
        foreach($entry in ([string]$script:Settings.LoraSelection -split '\|')) {
            if($entry -match '^([^:]+):(.+)$'){
                $ls2=$Matches[1]; $lv=0.0
                if($loraStems -contains $ls2 -and [double]::TryParse(([string]$Matches[2]).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$lv)){ $loraStrengths[$ls2]=[Math]::Max(0.0,[Math]::Min(1.5,$lv)) }
            }
        }
        for($li=0;$li -lt $loraList.Items.Count;$li++){ $liS=[string]$loraList.Items[$li]; if($loraStrengths.Contains($liS)){ $loraList.SetItemChecked($li,$true) } }
        $tabLora.Controls.Add($loraList); $dlgTip.SetToolTip($loraList,'Checked LoRAs are applied to every generation. Files come from ' + $loraDirAbs)
        Add-AutoLabel $tabLora 'Strength (selected)' 344 32 | Out-Null
        $loraNum=New-Object System.Windows.Forms.NumericUpDown; $loraNum.Location=New-Object System.Drawing.Point(344,54); $loraNum.Size=New-Object System.Drawing.Size(90,23); $loraNum.Minimum=0; $loraNum.Maximum=1.5; $loraNum.Increment=0.05; $loraNum.DecimalPlaces=2; $loraNum.Value=1.0; $tabLora.Controls.Add($loraNum); $dlgTip.SetToolTip($loraNum,'Strength of the LoRA highlighted in the list. 1.0 = full effect, 0.5 = subtle. Saved per LoRA.')
        $loraNum.Add_ValueChanged({ $selS=[string]$loraList.SelectedItem; if($selS){ $loraStrengths[$selS]=[double]$loraNum.Value } })
        $loraList.Add_SelectedIndexChanged({ $selS=[string]$loraList.SelectedItem; if($selS -and $loraStrengths.Contains($selS)){ $loraNum.Value=[decimal]$loraStrengths[$selS] } })
        $loraRescan=Add-Button $tabLora 'Rescan folder' 344 88 100 25
        $loraRescan.Add_Click({
            $loraList.Items.Clear(); $loraStrengths.Clear()
            $any=$false
            $found=@(Get-MossLoraFiles)
            foreach($lf2 in $found){ [void]$loraList.Items.Add([string]$lf2.Stem,$false); $any=$true }
            if(-not $any){ [void]$loraList.Items.Add('(no .safetensors files found)'); $loraList.Enabled=$false; $loraHint.Text=('No LoRA files found in: '+$loraDirAbs) } else { $loraList.Enabled=$true; $loraHint.Text=('Found '+$found.Count+' LoRA file(s) in: '+$loraDirAbs) }
        })
        # v0.3.10: optional LoRA downloader - opens a picker with the LoRAs
        # published for Sootglass (Comfy-Org/Hugging Face). Nothing is fetched until
        # the user ticks one and presses Download there.
        $loraGet=Add-Button $tabLora 'Get LoRAs...' 452 88 100 25
        $loraGet.Add_Click({
            $before=@(); foreach($lb in (Get-MossLoraFiles)){ $before += [string]$lb.Stem }
            Show-MossLoraDownloadDialog $g
            # A LoRA downloaded in the picker must be USABLE right away:
            # refresh the list, keep the existing checked state and check the
            # newly downloaded ones with the default strength 1.0 so the next
            # generation really uses them.
            $loraList.Items.Clear()
            $have=@()
            foreach($lf4 in (Get-MossLoraFiles)){ $have += [string]$lf4.Stem }
            $newOnes=@()
            foreach($hs in $have){ if($before -notcontains $hs){ $newOnes += $hs } }
            foreach($hs in $have){
                $isNew=($newOnes -contains $hs)
                if($isNew -and -not $loraStrengths.Contains($hs)){ $loraStrengths[$hs]=1.0 }
                [void]$loraList.Items.Add($hs, ($loraStrengths.Contains($hs)))
            }
            if($have.Count -gt 0){ $loraList.Enabled=$true } else { [void]$loraList.Items.Add('(no .safetensors files found)'); $loraList.Enabled=$false }
            if($newOnes.Count -gt 0){
                $loraHint.Text=('Downloaded and ready: '+($newOnes -join ', ')+"`r`nFolder: "+$loraDirAbs)
                foreach($hs in $newOnes){ for($li9=0;$li9 -lt $loraList.Items.Count;$li9++){ if([string]$loraList.Items[$li9] -eq $hs){ $loraList.SetItemChecked($li9,$true); break } } }
            }
        })
        $loraOpen=Add-Button $tabLora 'Open folder' 344 122 208 25
        $loraOpen.Add_Click({
            $openPath=Ensure-MossLoraDir
            if(-not $openPath){ $loraHint.Text='The LoRA folder could not be opened.'; return }
            try { Start-Process -FilePath $openPath -ErrorAction Stop } catch { $loraHint.Text=('Could not open LoRA folder: '+$_.Exception.Message) }
        })
        $dlgTip.SetToolTip($loraOpen,'Open the exact folder scanned for LoRA .safetensors files: '+$loraDirAbs)
        $loraHint=New-Object System.Windows.Forms.Label; $loraHint.Text=('LoRA folder: '+$loraDirAbs+"`r`n"+'Copy .safetensors files here and press Rescan, or use Get LoRAs to download.'); $loraHint.Location=New-Object System.Drawing.Point(12,212); $loraHint.Size=New-Object System.Drawing.Size(576,60); $loraHint.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $tabLora.Controls.Add($loraHint)
        if(-not $loraStems){ [void]$loraList.Items.Add('(no .safetensors files found)'); $loraList.Enabled=$false }
        # ---------------- TAB 3: speed & memory ------------------------------
        # v0.3.6: engine speed/memory features (sd-cli 3b12781+). Each one adds
        # exactly one optional engine flag when enabled, so a rollback is just
        # unticking the box.
        Add-AutoLabel $tabSpeed 'Speed & memory (engine options)' 12 8 | Out-Null
        $sageCheck=Add-Check $tabSpeed 'SageAttention - faster attention on NVIDIA GPUs' 12 32 576
        $sageCheck.Checked = ([string]$script:Settings.SageAttention -eq '1')
        $offCheck=Add-Check $tabSpeed 'CPU offload - keep model weights in RAM' 12 62 576
        $offCheck.Checked = ([string]$script:Settings.OffloadToCpu -eq '1')
        Add-WrapLabel $tabSpeed 'CPU offload saves VRAM but can slow generation. Turn it off again here when you no longer need the extra VRAM.' 12 88 576 38 | Out-Null
        Add-AutoLabel $tabSpeed 'Step cache' 12 134 | Out-Null
        $cacheCombo=New-Object System.Windows.Forms.ComboBox; $cacheCombo.DropDownStyle='DropDownList'; $cacheCombo.Location=New-Object System.Drawing.Point(12,154); $cacheCombo.Size=New-Object System.Drawing.Size(240,26); $cacheCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $cacheCombo.ForeColor=$cText; foreach($ci in @('Off (full quality)','EasyCache (~1.3-1.6x faster, tiny quality loss)')){[void]$cacheCombo.Items.Add($ci)}; $cacheCombo.SelectedIndex= if([string]$script:Settings.CacheMode -eq 'easycache'){1}else{0}; $tabSpeed.Controls.Add($cacheCombo); Set-MossComboTheme $cacheCombo $tabSpeed
        $prevCheck=Add-Check $tabSpeed 'Live preview - show the image while it renders' 12 192 576
        $prevCheck.Checked = ([string]$script:Settings.LivePreview -eq '1')
        Add-AutoLabel $tabSpeed 'Preview decoder' 12 226 | Out-Null
        $pvCombo=New-Object System.Windows.Forms.ComboBox; $pvCombo.DropDownStyle='DropDownList'; $pvCombo.Location=New-Object System.Drawing.Point(12,246); $pvCombo.Size=New-Object System.Drawing.Size(240,26); $pvCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $pvCombo.ForeColor=$cText; foreach($pv in @('proj (fast, default)','vae (exact, slower)','tae (needs taesd file)','Off (no live preview)')){[void]$pvCombo.Items.Add($pv)}; $pvCombo.SelectedIndex= switch([string]$script:Settings.PreviewMethod){'vae'{1}'tae'{2}'none'{3}default{0}}; $tabSpeed.Controls.Add($pvCombo); Set-MossComboTheme $pvCombo $tabSpeed; $dlgTip.SetToolTip($pvCombo,'How the engine decodes the preview while rendering. proj = fast built-in preview. vae = the real VAE, exact colors but slower updates. tae = tiny autoencoder, only used when a taesd.safetensors sits in models. Off = no live preview.')
        Add-AutoLabel $tabSpeed 'Write a preview every' 12 280 | Out-Null
        $pvNum=New-Object System.Windows.Forms.NumericUpDown; $pvNum.Location=New-Object System.Drawing.Point(12,300); $pvNum.Size=New-Object System.Drawing.Size(70,23); $pvNum.Minimum=1; $pvNum.Maximum=20; $pvPv=0; if([int]::TryParse([string]$script:Settings.PreviewInterval,[ref]$pvPv)){ $pvNum.Value=[Math]::Max(1,[Math]::Min(20,$pvPv)) }else{ $pvNum.Value=4 }; $tabSpeed.Controls.Add($pvNum); $dlgTip.SetToolTip($pvNum,'Write a preview every N denoiser steps. 1 = smoothest but costs a little speed; 4 is a good middle ground.')
        Add-AutoLabel $tabSpeed 'steps (1-20)' 88 300 | Out-Null
        Add-WrapLabel $tabSpeed 'These only change HOW the engine runs, never what the prompt asks for. Step cache and SageAttention can slightly change fine detail - benchmark before/after in Benchmarks.' 12 336 576 44 | Out-Null
        $dlgTip.SetToolTip($sageCheck,'Engine flag --sage-attn (NVIDIA CUDA only).')
        $dlgTip.SetToolTip($offCheck,'Engine flag --offload-to-cpu: model weights stay in RAM and are loaded into VRAM on demand (fits bigger models in low VRAM, but slower). Turn it off here when you no longer need the extra VRAM.')
        # ---------------- TAB 4: advanced tuning -----------------------------
        # v0.3.7 Advanced tuning - experiments for the user who likes tuning.
        # Everything here is optional: blank text or 'Default' means the flag
        # is omitted and the engine keeps its own choice.
        Add-AutoLabel $tabTune 'Advanced tuning (experimental)' 12 8 | Out-Null
        Add-AutoLabel $tabTune 'Distilled guidance' 12 38 | Out-Null
        $guidBox=Add-TextBox $tabTune ([string]$script:Settings.Guidance) 140 34 90 23; $dlgTip.SetToolTip($guidBox,'Distilled guidance scale (engine default 3.5). Blank = engine default. Only affects models with a guidance input.')
        Add-AutoLabel $tabTune 'Tileable output' 12 70 | Out-Null
        $tuneCircular=New-Object System.Windows.Forms.ComboBox; $tuneCircular.DropDownStyle='DropDownList'; $tuneCircular.Location=New-Object System.Drawing.Point(140,66); $tuneCircular.Size=New-Object System.Drawing.Size(240,26); $tuneCircular.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $tuneCircular.ForeColor=$cText; foreach($ti in @('Off (normal edges)','Both axes (seamless)','Width only','Height only')){[void]$tuneCircular.Items.Add($ti)}; $tuneCircular.SelectedIndex= switch([string]$script:Settings.Circular){'xy'{1}'x'{2}'y'{3}default{0}}; $tabTune.Controls.Add($tuneCircular); Set-MossComboTheme $tuneCircular $tabTune; $dlgTip.SetToolTip($tuneCircular,'Circular padding for tileable textures (e.g. for tiling backdrops).')
        Add-AutoLabel $tabTune 'Sampler RNG' 12 102 | Out-Null
        $tuneRng=New-Object System.Windows.Forms.ComboBox; $tuneRng.DropDownStyle='DropDownList'; $tuneRng.Location=New-Object System.Drawing.Point(140,98); $tuneRng.Size=New-Object System.Drawing.Size(240,26); $tuneRng.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $tuneRng.ForeColor=$cText; foreach($ti in @('Default (cuda)','std_default','cuda','cpu')){[void]$tuneRng.Items.Add($ti)}; $tuneRng.SelectedIndex= switch([string]$script:Settings.SamplerRng){'std_default'{1}'cuda'{2}'cpu'{3}default{0}}; $tabTune.Controls.Add($tuneRng); Set-MossComboTheme $tuneRng $tabTune; $dlgTip.SetToolTip($tuneRng,'Noise generator used by the sampler. Changing it makes seeds non-reproducible against old images.')
        Add-AutoLabel $tabTune 'Max VRAM (GiB)' 12 134 | Out-Null
        $vramBox=Add-TextBox $tabTune ([string]$script:Settings.MaxVram) 140 130 90 23; $dlgTip.SetToolTip($vramBox,'Per-device VRAM budget in GiB for automatic graph cutting, e.g. 6. Blank = engine decides. 0 = use live free VRAM.')
        $eagerCheck=Add-Check $tabTune 'Eager load - load all model weights at start' 12 166 576
        $eagerCheck.Checked = ([string]$script:Settings.EagerLoad -eq '1')
        $prefCheck=Add-Check $tabTune 'Disable weight prefetch (troubleshooting)' 12 196 576
        $prefCheck.Checked = ([string]$script:Settings.DisablePrefetch -eq '1')
        Add-WrapLabel $tabTune 'These are experiments: benchmark before/after in Benchmarks to see what each change is worth on this computer. Invalid numbers are ignored (the flag is simply omitted).' 12 226 576 44 | Out-Null
        $dlgTip.SetToolTip($eagerCheck,'Engine flag --eager-load: faster first image, slower start.')
        $dlgTip.SetToolTip($prefCheck,'Engine flag --disable-prefetch.')
        # ---------------- buttons --------------------------------------------
        $negOk=Add-Button $g 'Save' 424 518 96 32
        $negOk.AccessibleName='Save generation options'; $negOk.TabIndex=1
        $negCancel=Add-Button $g 'Cancel' 528 518 96 32
        $negCancel.AccessibleName='Cancel without saving generation options'; $negCancel.TabIndex=2
        $negOk.Add_Click({
            $script:Settings.NegativePrompt=($box.Text -replace "(\r?\n)+",' ').Trim()
            $saveSampler=[string]$optSampler.SelectedItem; if($saveSampler -eq 'Default (euler)'){$saveSampler='Default (model)'}
            $saveSched=[string]$optSched.SelectedItem; if($saveSched -eq 'Default (Euler/discrete, shift 5)'){$saveSched='Default (model)'}
            $script:Settings.SamplingMethod=$saveSampler
            $script:Settings.Scheduler=$saveSched
            $script:Settings.ShowEngineCommandLine= if($cmdCheck.Checked){'1'}else{'0'}
            $script:Settings.SafeMode=[bool]$safeCheck.Checked
            $script:Settings.SageAttention= if($sageCheck.Checked){'1'}else{'0'}
            $script:Settings.OffloadToCpu= if($offCheck.Checked){'1'}else{'0'}
            $script:Settings.CacheMode= if($cacheCombo.SelectedIndex -eq 1){'easycache'}else{'Off'}
            $script:Settings.LivePreview= if($prevCheck.Checked){'1'}else{'0'}
            $script:Settings.PreviewMethod= switch($pvCombo.SelectedIndex){1{'vae'}2{'tae'}3{'none'}default{'proj'}}
            $script:Settings.PreviewInterval= [string]$pvNum.Value
            $loraSelParts=@()
            for($li2=0;$li2 -lt $loraList.Items.Count;$li2++){
                if($loraList.GetItemChecked($li2)){
                    $liS2=[string]$loraList.Items[$li2]
                    if($loraStrengths.Contains($liS2)){ $loraSelParts += ($liS2 + ':' + [string]$loraStrengths[$liS2].ToString([System.Globalization.CultureInfo]::InvariantCulture)) }else{ $loraSelParts += ($liS2 + ':1') }
                }
            }
            $script:Settings.LoraSelection=($loraSelParts -join '|')
            $gi=0.0
            if([double]::TryParse(([string]$guidBox.Text).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$gi)){ $script:Settings.Guidance=('{0}' -f $gi) }else{ $script:Settings.Guidance='' }
            $script:Settings.Circular= switch($tuneCircular.SelectedIndex){1{'xy'}2{'x'}3{'y'}default{'off'}}
            $script:Settings.SamplerRng= switch($tuneRng.SelectedIndex){1{'std_default'}2{'cuda'}3{'cpu'}default{''}}
            $vi=0.0
            if([double]::TryParse(([string]$vramBox.Text).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$vi) -and $vi -ge 0){ $script:Settings.MaxVram=('{0}' -f $vi) }else{ $script:Settings.MaxVram='' }
            $script:Settings.EagerLoad= if($eagerCheck.Checked){'1'}else{'0'}
            $script:Settings.DisablePrefetch= if($prefCheck.Checked){'1'}else{'0'}
            # PERSIST IMMEDIATELY (v0.1.89): Options changes used to be written
            # to disk only at the NEXT generate - deleting the negative prompt
            # and restarting Sootglass brought the old text back (user report), and
            # a Safe-mode toggle would silently revert the same way.
            [void](Save-Settings)
            $negState.Text=if($script:Settings.NegativePrompt){('negative prompt: set ('+$script:Settings.NegativePrompt.Length+' chars)')}else{'negative prompt: not set'}
            $g.Close()
        })
        $negCancel.Add_Click({$g.Close()})
        # v0.3.11: never open taller than the screen - on a small/laptop
        # display the old 1136 px dialog simply did not fit. The tab pages
        # scroll, so a shorter window still shows every control.
        try {
            $wa=[System.Windows.Forms.Screen]::FromControl($g).WorkingArea
            $maxClientH=$wa.Height-90
            if($g.ClientSize.Height -gt $maxClientH){
                $g.ClientSize=New-Object System.Drawing.Size(640,[Math]::Max(320,$maxClientH))
                $tabs.Height=[Math]::Max(200,$g.ClientSize.Height-64)
                $negOk.Location=New-Object System.Drawing.Point(424,($g.ClientSize.Height-42))
                $negCancel.Location=New-Object System.Drawing.Point(528,($g.ClientSize.Height-42))
            }
        } catch {}
        [void]$g.ShowDialog($f)
    }
    # 'Generation...' (v0.1.97): was 'Options...' - the header now has its
    # own Options menu (Setup / engine / Sootglass updates), so the in-panel
    # generation-settings button is named for what it opens. Width measured.
    $negBtn=Add-Button $left 'Generation...' 18 134 90 22
    $negBtn.Add_Click({ Show-MossGenerationOptionsDialog })
    $enabledOptionsBtn=Add-Button $left 'Active options...' 114 134 110 22
    $enabledOptionsBtn.Add_Click({
        $activeOptions=Get-MossEnabledOptionsSummary
        [System.Windows.Forms.MessageBox]::Show($f,$activeOptions,'Enabled options',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    })
    $styleLabel=Add-Label $left 'Visual style' 18 163 130
    # Snug dropdown (v0.1.97): fits 'Dark fantasy / gothic', barely.
    $style=New-Object System.Windows.Forms.ComboBox; $style.DropDownStyle='DropDownList'; $style.Location=New-Object System.Drawing.Point(18,181); $style.Size=New-Object System.Drawing.Size(160,23); $style.MaxDropDownItems=7; $style.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $style.ForeColor=$cText; foreach($item in @('None (no style)','Photorealistic','Anime','Digital illustration','Oil painting','Watercolor','3D render','Comic book','Cinematic','Fantasy art','Dark fantasy / gothic','Cyberpunk / sci-fi','Studio portrait','Sketch / pencil drawing','Pixel art','Synthwave / retro 80s','Low poly 3D')){[void]$style.Items.Add($item)}; $style.SelectedItem=[string]$script:Settings.ImageStyle; if($style.SelectedIndex -lt 0){$style.SelectedIndex=0}; $left.Controls.Add($style); Set-MossComboTheme $style $left
    # Resolution sits UNDER Visual style (v0.1.99, user).
    $resLabel=Add-Label $left 'Resolution' 18 209 90
    # Snug dropdown (v0.1.97): fits 'Landscape 16:9  |  1360 x 768', barely.
    $res=New-Object System.Windows.Forms.ComboBox; $res.DropDownStyle='DropDownList'; $res.Location=New-Object System.Drawing.Point(18,226); $res.Size=New-Object System.Drawing.Size(190,23); $res.MaxDropDownItems=7; $res.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $res.ForeColor=$cText
    $resItems=@('Landscape 16:9  |  1360 x 768','Square  |  1024 x 1024','Portrait 3:4  |  768 x 1024','Landscape 4:3  |  1280 x 960','Portrait 9:16  |  768 x 1360','2K Landscape  |  2560 x 1440','2K Square  |  2048 x 2048','2K Portrait  |  1536 x 2048','2K 4:3  |  2048 x 1536','2K 9:16  |  1440 x 2560','4K Landscape  |  3840 x 2160','4K Square  |  4096 x 4096','4K Portrait  |  3072 x 4096','4K 4:3  |  4096 x 3072','4K 9:16  |  2160 x 3840','Custom dimensions')
    foreach($ri in $resItems){[void]$res.Items.Add($ri)}; $left.Controls.Add($res); Set-MossComboTheme $res $left
    $wBox=Add-TextBox $left ([string]$script:Settings.Width) 232 226 82 23; $hBox=Add-TextBox $left ([string]$script:Settings.Height) 327 226 82 23
    $widthLabel=Add-Label $left 'Width' 232 209 80; $heightLabel=Add-Label $left 'Height' 327 209 80
    $resMap=@(@(1360,768),@(1024,1024),@(768,1024),@(1280,960),@(768,1360),@(2560,1440),@(2048,2048),@(1536,2048),@(2048,1536),@(1440,2560),@(3840,2160),@(4096,4096),@(3072,4096),@(4096,3072),@(2160,3840))
    $matched=-1; for($ri=0;$ri -lt $resMap.Count;$ri++){if([int]$script:Settings.Width -eq $resMap[$ri][0] -and [int]$script:Settings.Height -eq $resMap[$ri][1]){$matched=$ri;break}}; if($matched -ge 0){$res.SelectedIndex=$matched}else{$res.SelectedIndex=15}
    $res.Add_SelectedIndexChanged({ if($res.SelectedIndex -ge 0 -and $res.SelectedIndex -lt $resMap.Count){$wBox.Text=[string]$resMap[$res.SelectedIndex][0];$hBox.Text=[string]$resMap[$res.SelectedIndex][1]} })
    $stepsLabel=Add-Label $left 'Steps' 18 254 70; $steps=Add-TextBox $left ([string]$script:Settings.Steps) 18 271 75 23
    $cfgLabel=Add-Label $left 'CFG scale' 110 254 90; $cfg=Add-TextBox $left ([string]$script:Settings.CfgScale) 110 271 62 23
    $cfgHelp=Add-Button $left '?' 174 271 20 23
    $cfgHelp.AccessibleName='Explain CFG scale'
    $cfgHelp.Add_Click({
        [System.Windows.Forms.MessageBox]::Show("CFG scale (Classifier-Free Guidance) controls how strictly the image follows your prompt.`r`n`r`n- Low (1-4): more artistic freedom, softer prompt adherence. This model is tuned for this range - the default 3 suits it well.`r`n- Medium (5-10): stronger prompt following; colors and contrast grow.`r`n- High (15-30): forces the prompt hard - often causes burned, oversaturated or distorted images.`r`n`r`nRule of thumb: raise it only if the image ignores parts of your prompt; lower it if images look overcooked.",'What is CFG scale?',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    })
    $countLabel=Add-Label $left 'Images' 202 254 70; $count=New-Object System.Windows.Forms.ComboBox; $count.DropDownStyle='DropDown'; $count.Location=New-Object System.Drawing.Point(202,271); $count.Size=New-Object System.Drawing.Size(75,23); foreach($n in @(1,2,4,8,16,32,64,128,256,512,1000)){[void]$count.Items.Add([string]$n)}; $count.Text=[string]$script:Settings.ImageCount; $left.Controls.Add($count); Set-MossComboTheme $count $left
    $seedLabel=Add-Label $left 'Seed (-1 = random)' 284 254 116; $seed=Add-TextBox $left ([string]$script:Settings.Seed) 284 271 90 23
    # Speed modes (v0.1.93): 8x and Fastest REMOVED from the UI - measured,
    # their drafts (35% / 128-px side) are too soft to be useful. The engine
    # and all internal helpers still SUPPORT '8x'/'Fast' for old benchmark
    # data and old settings.
    # v0.3.11: the speed dropdown had NO caption at all (the user saw a
    # combo box with nothing above it) - it now has one.
    $speedLabel=Add-Label $left 'Render speed' 18 301 100
    $speedCombo=New-Object System.Windows.Forms.ComboBox; $speedCombo.DropDownStyle='DropDownList'; $speedCombo.Location=New-Object System.Drawing.Point(18,318); $speedCombo.Size=New-Object System.Drawing.Size(220,23); $speedCombo.MaxDropDownItems=3; $speedCombo.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $speedCombo.ForeColor=$cText; foreach($si in @('Exact (full quality)','~2x faster (70%)','~4x faster (50%)')){[void]$speedCombo.Items.Add($si)}; $speedCombo.SelectedIndex=0; $left.Controls.Add($speedCombo); Set-MossComboTheme $speedCombo $left
    $speedHint=New-Object System.Windows.Forms.Label; $speedHint.Text='Faster modes make smaller drafts, then enlarge.'; $speedHint.Location=New-Object System.Drawing.Point(252,320); $speedHint.Size=New-Object System.Drawing.Size(282,34); $speedHint.ForeColor=[System.Drawing.Color]::FromArgb(110,124,148); $speedHint.TextAlign='MiddleLeft'; $left.Controls.Add($speedHint)
    # OUTPUT FOLDER (v0.1.98): MOVED INTO THE HEADER OPTIONS MENU (user).
    # The read-only textbox stays as a HIDDEN state holder - the generate
    # handler and 'Open output' read it directly.
    $out=Add-TextBox $left ([string]$script:Settings.OutputPath) 0 0 506 23; $out.ReadOnly=$true; $out.Visible=$false
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
        $tb=Add-TextBox $left $val 0 0 419 23; $tb.Visible=$false
        $modelControls[$mr[1]]=$tb
    }
    function Update-MossModelSummary {
        $check=@((Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)))
        foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $check+=(Get-AbsoluteAppPath $modelControls[$k].Text) }
        return @($check | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count
    }
    function Show-MossModelFilesDialog {
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Model files'; $g.ClientSize=New-Object System.Drawing.Size(600,296); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false; $g.ShowInTaskbar=$false
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $hint=New-Object System.Windows.Forms.Label; $hint.Text='The engine and model files Sootglass loads. Paths are resolved against the Sootglass folder.'; $hint.Location=New-Object System.Drawing.Point(12,10); $hint.Size=New-Object System.Drawing.Size(576,20); $hint.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($hint)
        $dlgBoxes=@{}
        # v0.3.1: the summary label is created BEFORE the browse-button loop:
        # GetNewClosure() captures the variables that exist at closure-creation
        # time, so a label defined after the loop arrives as \$null inside the
        # click handler.
        $dlgSummary=New-Object System.Windows.Forms.Label; $dlgSummary.Location=New-Object System.Drawing.Point(12,194); $dlgSummary.Size=New-Object System.Drawing.Size(576,20); $g.Controls.Add($dlgSummary)
        $y=38
        # ENGINE ROW (v0.2.6): the health count is 'N of 5 engine/model files'
        # - the engine file is the fifth file, but the dialog only showed the
        # four model rows, so the number never matched what was visible.
        # The engine path is read-only here (it is edited in Hardware /
        # Setup), it just makes the fifth counted file visible.
        $engL=New-Object System.Windows.Forms.Label; $engL.Text='Engine'; $engL.Location=New-Object System.Drawing.Point(12,($y+3)); $engL.Size=New-Object System.Drawing.Size(120,22); $engL.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($engL)
        $engTb=New-Object System.Windows.Forms.TextBox; $engTb.AccessibleName='Engine file path (read only)'; $engTb.TabStop=$false; $engTb.Text=[string]$script:Settings.EnginePath; $engTb.Location=New-Object System.Drawing.Point(140,$y); $engTb.Size=New-Object System.Drawing.Size(364,23); $engTb.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $engTb.ForeColor=$cText; $engTb.BorderStyle='FixedSingle'; $engTb.ReadOnly=$true; $g.Controls.Add($engTb)
        $engTb.ForeColor= if (Test-Path -LiteralPath (Get-AbsoluteAppPath $engTb.Text) -PathType Leaf) { [System.Drawing.Color]::FromArgb(230,236,245) } else { [System.Drawing.Color]::FromArgb(224,138,138) }
        $y+=30
        foreach($mr in $modelRows){
            $rl=New-Object System.Windows.Forms.Label; $rl.Text=$mr[0]; $rl.Location=New-Object System.Drawing.Point(12,($y+3)); $rl.Size=New-Object System.Drawing.Size(120,22); $rl.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($rl)
            $tb=New-Object System.Windows.Forms.TextBox; $tb.AccessibleName=([string]$mr[0]+' file path'); $tb.TabIndex=($dlgBoxes.Count); $tb.Text=[string]$modelControls[$mr[1]].Text; $tb.Location=New-Object System.Drawing.Point(140,$y); $tb.Size=New-Object System.Drawing.Size(354,23); $tb.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $tb.ForeColor=$cText; $tb.BorderStyle='FixedSingle'; $g.Controls.Add($tb)
            $dlgBoxes[$mr[1]]=$tb
            $bb=Add-Button $g 'Browse...' 502 $y 86 27
            $bb.AccessibleName=('Browse for '+[string]$mr[0]+' file'); $bb.TabIndex=($dlgBoxes.Count+3)
            $key=$mr[1]
            $bb.Add_Click({$dlg=New-Object System.Windows.Forms.OpenFileDialog;$dlg.Title="Select file";$dlg.Filter='Model and data files|*.safetensors;*.gguf;*.json|All files (*.*)|*.*';$dlg.CheckFileExists=$true;$cur=Get-AbsoluteAppPath $dlgBoxes[$key].Text;if(Test-Path -LiteralPath $cur -PathType Leaf){$dlg.InitialDirectory=Split-Path -Parent $cur;$dlg.FileName=Split-Path -Leaf $cur}else{$modelsDir=Join-Path $script:AppRoot 'models';if(Test-Path -LiteralPath $modelsDir -PathType Container){$dlg.InitialDirectory=$modelsDir}};if($dlg.ShowDialog($g) -eq 'OK'){$dlgBoxes[$key].Text=$dlg.FileName};[void](Update-MossDlgSummaryBoxes $dlgBoxes $dlgSummary);$dlg.Dispose()}.GetNewClosure())
            $y+=30
        }
        # v0.3.1: the updater is SCRIPT-scoped (with explicit parameters). The old
        # nested function could not be called from the browse-button closure
        # built with GetNewClosure() - cancelling the file picker threw
        # "The term 'Update-MossDlgSummary' is not recognized" as an unhandled
        # exception dialog.
        Update-MossDlgSummaryBoxes $dlgBoxes $dlgSummary
        $ok=Add-Button $g 'OK' 412 226 76 30
        $ok.AccessibleName='Apply model file paths'; $ok.TabIndex=8
        $cancel=Add-Button $g 'Cancel' 496 226 76 30
        $cancel.AccessibleName='Cancel without applying model file paths'; $cancel.TabIndex=9
        $ok.Add_Click({
            foreach($k in @('DiffusionModelPath','LlmPath','VaePath','TokenizerPath')){ $modelControls[$k].Text=[string]$dlgBoxes[$k].Text }
            $g.Close()
        })
        $cancel.Add_Click({$g.Close()})
        $g.AcceptButton=$ok
        $g.CancelButton=$cancel
        [void]$g.ShowDialog($f)
    }

    # Compact action row (v0.1.96/98): half-size buttons (24 px tall). The
    # row is placed by Update-MossLeftActionLayout right below the speed
    # hint; with Output folder / Model files / Error report / Benchmarks in
    # the header Options menu, only the four generation actions remain.
    try { $f.Refresh() } catch {}
    $generate=Add-Button $left 'Generate' 18 356 96 24; $generate.BackColor=$cAccent; $generate.ForeColor=[System.Drawing.Color]::White; $generate.Font=New-Object System.Drawing.Font('Segoe UI Semibold',9,[System.Drawing.FontStyle]::Bold)
    $cancel=Add-Button $left 'Cancel' 120 348 60 24; $cancel.Enabled=$false
    # Pause/Resume (v0.1.91): freezes the RUNNING engine process for real
    # (ntdll NtSuspendProcess) and continues it on Resume - a large batch
    # can be put on hold without losing the run.
    $btnPause=Add-Button $left 'Pause' 186 348 60 24; $btnPause.Enabled=$false
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
                if ($script:BenchStartedAt) { $script:BenchStartedAt=$script:BenchStartedAt.AddSeconds($pauseSpan) }
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
    $openOut=Add-Button $left 'Open output' 308 348 92 24
    # Skip (v0.3.9): abandons the image currently being rendered and moves
    # on to the next one of the batch. Works because Sootglass runs ONE engine
    # process per image: every image is saved the moment it is done, so a
    # skipped image loses nothing that is already on disk.
    $btnSkip=Add-Button $left 'Skip' 252 348 50 24; $btnSkip.Enabled=$false
    $btnSkip.Add_Click({
        $st=$script:GenState
        if (-not $st.IsRunning -or $null -eq $st.Process -or $st.Process.HasExited) { return }
        $st.SkipRequested=$true
        $status.Text=("Skipping image {0} of {1}..." -f [int]$st.BatchIndex,[int]$st.Job.Count)
        $log.AppendText(("`r`nSkip requested: stopping the current image ({0} of {1}). Images already saved are kept." -f [int]$st.BatchIndex,[int]$st.Job.Count))
        try {
            $skipPid=$st.Process.Id
            $taskkill=Join-Path $env:WINDIR 'System32\taskkill.exe'
            Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$skipPid,'/T','/F') -WindowStyle Hidden -Wait | Out-Null
        } catch { try { $st.Process.Kill() } catch {} }
    })
    function Show-MossBenchmarkDialog {
        # Shows every recorded resolution/steps/speed-mode combination with its
        # real measured seconds per image, an estimate for the CURRENT main
        # window settings, and a quick benchmark runner for gaps in the table.
        # The bigger-job estimator at the bottom extrapolates the recorded
        # measurements to ANY size / steps / speed mode / image count.
        $g = New-Object System.Windows.Forms.Form
        $g.Text = 'Performance benchmarks'; $g.Size = New-Object System.Drawing.Size(780, 800); $g.StartPosition = 'CenterParent'; $g.FormBorderStyle = 'FixedDialog'; $g.MaximizeBox = $false
        $g.BackColor = $cPanel; $g.ForeColor = $cText; $g.Font = New-Object System.Drawing.Font('Segoe UI', 9); $g.KeyPreview = $true
        $hint = New-Object System.Windows.Forms.Label; $hint.Text = 'Measured seconds per image for every size / speed mode / step combination that ran on this PC. Times are engine render time per image (image-to-image runs are listed separately).'; $hint.Location = New-Object System.Drawing.Point(14, 10); $hint.Size = New-Object System.Drawing.Size(730, 30); $hint.ForeColor = $cMuted; $g.Controls.Add($hint)

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.AccessibleName = 'Recorded performance measurements'; $grid.TabIndex = 0; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false
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
                # Old benchmark files can still carry a HiresScale field from
                # the removed detail-regeneration runs; those entries simply
                # group by their recorded scale value (0 = plain run).
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

        $runBtn = Add-Button $g 'Run quick benchmark...' 14 406 200 32; $runBtn.AccessibleName = 'Run quick benchmark'; $runBtn.TabIndex = 1
        $runBtn.Add_Click({
            if ($script:GenState.IsRunning) { [System.Windows.Forms.MessageBox]::Show($g, 'A generation is running. Wait for it to finish first.', 'Benchmarks') | Out-Null; return }
            $quickAnswer = [System.Windows.Forms.MessageBox]::Show($g, "The quick benchmark renders 3 small test images (512 x 512, 1024 x 1024, 2048 x 2048) at 8 steps each with your current sampler settings.`r`n`r`nThey run one after another in a 'benchmarks' folder (not in your output list) and their measured times fill the table above.`r`n`r`nStart now? (Roughly a few minutes on most GPUs.)", 'Quick benchmark', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($quickAnswer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $script:BenchQueue.Clear()
            # 'Default (model)' is the DISPLAY label in the options dialog, not an
            # engine value: like every other queue path (the generate button), an
            # empty value makes the engine flag be OMITTED so the model keeps its
            # own default. Passing the label verbatim made sd-cli reject the
            # command ('unknown argument: (model)').
            $benchSampler = [string]$script:Settings.SamplingMethod; if ($benchSampler -eq 'Default (model)') { $benchSampler = '' }
            $benchSched = [string]$script:Settings.Scheduler; if ($benchSched -eq 'Default (model)') { $benchSched = '' }
            foreach ($sz in @(@(512, 512), @(1024, 1024), @(2048, 2048))) {
                [void]$script:BenchQueue.Add([pscustomobject]@{ File = ''; W = [int]$sz[0]; H = [int]$sz[1]; Seed = 42; Prompt = 'benchmark speed test'; NegativePrompt = ''; SamplingMethod = $benchSampler; Scheduler = $benchSched; Strength = 0.6; Steps = 8; Cfg = [double]$script:Settings.CfgScale; Tag = 'bench'; FreshRender = $true })
            }
            $script:BenchTotal = $script:BenchQueue.Count
            $script:BenchStartedAt = Get-Date
            $g.Close()
            Start-MossNextBench
        })
        $clearBtn = Add-Button $g 'Clear recorded data...' 226 406 180 32; $clearBtn.AccessibleName = 'Clear recorded benchmark data'; $clearBtn.TabIndex = 2
        $clearBtn.Add_Click({
            $a = [System.Windows.Forms.MessageBox]::Show($g, 'Delete ALL recorded benchmark data? Times are re-learned as you keep generating.', 'Clear benchmark data', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Save-MossBenchmarks (New-Object System.Collections.ArrayList)
            & $fillGrid
            & $refreshEstimate
        })
        $closeBtn = Add-Button $g 'Close' 660 406 88 32; $closeBtn.TabIndex = 3
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
        $cbMLbl = New-Object System.Windows.Forms.Label; $cbMLbl.Text = 'Mode'; $cbMLbl.Location = New-Object System.Drawing.Point(450, 474); $cbMLbl.Size = New-Object System.Drawing.Size(42, 18); $cbMLbl.ForeColor = $cMuted; $g.Controls.Add($cbMLbl)
        $cbM = New-Object System.Windows.Forms.ComboBox; $cbM.DropDownStyle = 'DropDownList'; [void]$cbM.Items.AddRange(@('Exact', '2x', '4x')); $cbM.SelectedIndex = 0; $cbM.Location = New-Object System.Drawing.Point(494, 470); $cbM.Size = New-Object System.Drawing.Size(82, 23); $g.Controls.Add($cbM); Set-MossComboTheme $cbM $g
        $calcBtn = Add-Button $g 'Estimate time...' 594 468 154 28; $calcBtn.AccessibleName = 'Estimate render time and GPU energy'; $calcBtn.TabIndex = 8
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
        $powerOut = New-Object System.Windows.Forms.Label; $powerOut.Location = New-Object System.Drawing.Point(14, 624); $powerOut.Size = New-Object System.Drawing.Size(734, 82); $powerOut.ForeColor = $cText; $g.Controls.Add($powerOut)
        $powerBtn = Add-Button $g 'Refresh power' 14 714 120 28; $powerBtn.AccessibleName = 'Refresh GPU power totals'; $powerBtn.TabIndex = 9
        $powerClear = Add-Button $g 'Reset all-time...' 142 714 130 28; $powerClear.AccessibleName = 'Reset GPU power totals'; $powerClear.TabIndex = 10
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
    # header Options menu, the layout follows prompt growth on taller resizes.
    # The base row starts at y=356; status and progress flow below it.
    function Update-MossLeftActionLayout([int]$PromptExtra=0) {
        $rowY = 356 + $PromptExtra
        foreach ($c in @($generate,$cancel,$btnPause,$btnSkip,$openOut)) {
            $c.Location = New-Object System.Drawing.Point($c.Left, $rowY)
        }
        $status.Location = New-Object System.Drawing.Point(18, ($rowY + 38))
        $prog.Location = New-Object System.Drawing.Point(18, ($rowY + 72))
    }
    # (First placement happens after the status line and progress bar are
    # created - see the call directly below $prog.)
    # Hover explanations for every control, so nothing is guesswork.
    $tip=New-Object System.Windows.Forms.ToolTip; $tip.InitialDelay=300; $tip.ReshowDelay=300
    $tip.SetToolTip($generate,'Renders your prompt. Quality follows the selector above: Exact (full quality) renders at full size and full steps; faster modes render small and enlarge - quick drafts, never distorted.')
    $tip.SetToolTip($cancel,'Stops the current generation and its engine processes.')
    $tip.SetToolTip($openOut,'Opens the output folder in Explorer.')
    $tip.SetToolTip($btnSkip,'Stops the image currently being rendered and moves on to the next one of the batch. Images already saved are kept.')
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
    $filesTitle=Add-Label $right 'Generated files  (right-click: info or delete)' 16 342 340
    # v0.3.12: at the smallest window size this label ran past the panel edge
    # and was clipped ('...or delet'). It is now width-bound to the right
    # panel (anchored Left,Right) with AutoEllipsis, so it degrades to
    # '...' instead of hard clipping at any window width, and a tooltip
    # always shows the full text.
    $filesTitle.AutoSize=$false; $filesTitle.AutoEllipsis=$true; $filesTitle.TextAlign='MiddleLeft'
    $filesTitle.Width=[Math]::Max(80,$right.ClientSize.Width-32); $filesTitle.Anchor='Top,Left,Right'
    $filesTip=New-Object System.Windows.Forms.ToolTip; $filesTip.InitialDelay=300
    $filesTip.SetToolTip($filesTitle,'Generated files (right-click: info or delete)')
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
                # The file was deleted, renamed or moved OUTSIDE Sootglass (by
                # hand, OneDrive, a backup tool...). Prune every dead entry
                # so the list matches the disk again - otherwise deleted files
                # re-render and info would keep failing on dead paths.
                $fileList.ClearSelected()
                $removed=0
                for($i=$fileList.Items.Count-1;$i -ge 0;$i--){
                    $ip=[string]$fileList.Items[$i]
                    if(-not (Test-Path -LiteralPath $ip)){ $fileList.Items.RemoveAt($i); [void]$script:GeneratedFiles.Remove($ip); $removed++ }
                }
                $script:SelectedFile=$null
                # Same rule as a Sootglass delete: the preview goes blank, no
                # other image is auto-shown. Click a file to view it again.
                try { $old=$preview.Image; $preview.Image=$null; if($old){ $old.Dispose() } } catch {}
                $fileList.ClearSelected()
                $status.Text=('Removed {0} list entr(ies): their file(s) no longer exist on disk (deleted, renamed or moved outside Sootglass).' -f $removed)
                return
            }
            try{$newImg=Copy-MossImageUnlocked $p;if($newImg){$old=$preview.Image;$preview.Image=$newImg;if($old){$old.Dispose()}}}catch{}
        }
    })
    function Restore-MossGeneratedPreview {
        if($fileList.Items.Count -gt 0){
            $fileList.ClearSelected()
            $fileList.SelectedIndex=0
        } else {
            $script:SelectedFile=$null
            try { $old=$preview.Image; $preview.Image=$null; if($old){$old.Dispose()} } catch {}
        }
    }
    # A plain right-click does not change the ListBox selection - select the
    # file under the cursor first, so Info and Delete always act on that file.
    # With multi-select, right-clicking a file that is ALREADY part of the
    # current selection keeps the whole selection (so Delete can act on it).
    $fileList.Add_MouseClick({ param($sender,$e) if($e.Button -eq [System.Windows.Forms.MouseButtons]::Right){ $idx=$fileList.IndexFromPoint($e.Location); if($idx -ge 0 -and -not $fileList.SelectedIndices.Contains($idx)){ $fileList.SelectedIndex=$idx } } })
    $fileMenu=New-Object System.Windows.Forms.ContextMenuStrip
    $miInfo=$fileMenu.Items.Add('Show image info (prompt, seed, settings)...')
    $miDelete=$fileMenu.Items.Add('Delete selected file(s)...')
    $miDeleteAll=$fileMenu.Items.Add('Delete ALL files...')
    $fileList.ContextMenuStrip=$fileMenu
    $miInfo.Add_Click({ Show-MossImageInfo })
    $miDelete.Add_Click({ Remove-MossSelectedFiles $false })
    $miDeleteAll.Add_Click({ Remove-MossSelectedFiles $true })
    $fileMenu.ShowItemToolTips=$true
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
                $legacySides=@((Get-ChildItem -LiteralPath $outFolder -Filter 'MOSS_*.json' -File -ErrorAction SilentlyContinue) + (Get-ChildItem -LiteralPath $outFolder -Filter 'Sootglass_*.json' -File -ErrorAction SilentlyContinue))
                if($legacySides.Count -gt 0){
                    $metaDir=Join-Path $outFolder 'metadata'
                    if(-not (Test-Path -LiteralPath $metaDir -PathType Container)){ New-Item -ItemType Directory -Path $metaDir -Force | Out-Null }
                    foreach($js in $legacySides){
                        $target=Join-Path $metaDir $js.Name
                        if(-not (Test-Path -LiteralPath $target -PathType Leaf)){ Move-Item -LiteralPath $js.FullName -Destination $target -Force -ErrorAction SilentlyContinue }
                    }
                }
            } catch {}
            $existing=@(Get-ChildItem -LiteralPath $outFolder -Filter 'MOSS_*.png' -File) + @(Get-ChildItem -LiteralPath $outFolder -Filter 'Sootglass_*.png' -File) | Sort-Object LastWriteTime
            # ONE list builder used at startup and after deletions.
function Update-MossFileList {
                $fileList.Items.Clear()
                try { $script:GeneratedFiles.Clear() } catch {}
                $existing = @(Get-ChildItem -LiteralPath $outFolder -Filter 'MOSS_*.png' -File) + @(Get-ChildItem -LiteralPath $outFolder -Filter 'Sootglass_*.png' -File) | Sort-Object LastWriteTime -Descending
                # Newest FIRST (user: the last generated file should be on
                # top and highlighted, not the first ever made).
                foreach ($fi in $existing) {
                    [void]$fileList.Items.Add($fi.FullName); [void]$script:GeneratedFiles.Add($fi.FullName)
                }
                if ($fileList.Items.Count -gt 0 -and -not $script:SelectedFile) { $fileList.SelectedIndex = 0 }
            }
            [void](Update-MossFileList)
            if($fileList.Items.Count -gt 0 -and -not $script:SelectedFile){ $fileList.SelectedIndex=0 }
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
        $fileHeight = [Math]::Min(150,[Math]::Max(56,[int][Math]::Round($panelHeight * 0.22)))
        $logTitleTop = 0
        $logTop = 0
        $logTargetHeight = 0
        if($script:LogVisible){
            $logTargetHeight=[Math]::Max(52,[Math]::Min(130,[int]($panelHeight*0.20)))
            $logTop=$panelHeight-16-$logTargetHeight
            $logTitleTop=$logTop-27
            $listTop=$logTitleTop-17-$fileHeight
            $filesTop=$listTop-26
            $previewHeight=[Math]::Max(80,$filesTop-57)
        } else {
            $previewHeight=[Math]::Max(80,$panelHeight-42-15-26-$fileHeight-17-27-16)
            $filesTop=42+$previewHeight+15
            $listTop=$filesTop+26
            $logTitleTop=$listTop+$fileHeight+17
            $logTop=$logTitleTop+27
        }
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
            $log.Size = New-Object System.Drawing.Size([Math]::Max(100,$right.ClientSize.Width - 32),$logTargetHeight)
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
    $tip.SetToolTip($fileList,'Images you generated. Left-click to preview; right-click for info and delete options.')

    # Main workspace: a readable editor column and a preview that receives
    # spare width, instead of a fixed 600 px column and a squeezed preview.
    $res.DropDownWidth=310
    $style.DropDownWidth=240
    $speedCombo.DropDownWidth=230
    $speedHint.Text='Exact keeps full size and quality. Faster modes make smaller drafts and enlarge them.'
    $filesTitle.Text='Generated images'
    $fileList.HorizontalScrollbar=$true
    $fileList.IntegralHeight=$false
    $fileList.BorderStyle='FixedSingle'
    $negBtn.Text='Settings...'
    foreach($button in @($generate,$cancel,$btnPause,$btnSkip,$openOut)) { $button.Height=32 }
    $generate.Width=110
    $cancel.Left=134; $btnPause.Left=196; $btnSkip.Left=262; $openOut.Left=318
    $generate.FlatAppearance.BorderSize=0
    $tip.SetToolTip($btnPause,'Pause the current render without losing progress; resume when ready.')
    $resetHistoryCode.Visible=$false
    $tabOrder=@($prompt,$historyPick,$paste,$negBtn,$style,$res,$wBox,$hBox,$steps,$cfg,$cfgHelp,$count,$seed,$speedCombo,$generate,$cancel,$btnPause,$btnSkip,$openOut)
    for($i=0;$i -lt $tabOrder.Count;$i++){ $tabOrder[$i].TabIndex=$i }
    foreach($entry in @(@($prompt,'Image prompt'),@($historyPick,'Recent prompts'),@($style,'Visual style'),@($res,'Resolution preset'),@($wBox,'Width in pixels'),@($hBox,'Height in pixels'),@($steps,'Steps'),@($cfg,'CFG scale'),@($count,'Number of images'),@($seed,'Seed'),@($speedCombo,'Render quality'))) {
        $entry[0].AccessibleName=$entry[1]
    }
    $preview.Add_Paint({ param($sender,$e)
        if($null -eq $sender.Image){
            $brush=New-Object System.Drawing.SolidBrush($cMuted)
            $fmt=New-Object System.Drawing.StringFormat
            $fmt.Alignment='Center'; $fmt.LineAlignment='Center'
            $bounds=New-Object System.Drawing.RectangleF(16,16,([Math]::Max(1,$sender.Width-32)),([Math]::Max(1,$sender.Height-32)))
            $e.Graphics.DrawString('Select a generated image to preview',$sender.Font,$brush,$bounds,$fmt)
            $fmt.Dispose(); $brush.Dispose()
        }
    }.GetNewClosure())
    # The form is intentionally hidden until its first layout is ready;
    # Visible therefore reflects parent visibility here, not each control's
    # configured state. Hidden state-holder controls stay at the origin.
    $elasticLeftControls=@($left.Controls | Where-Object { $_.Top -ge 134 } | ForEach-Object { [pscustomobject]@{Control=$_;Top=$_.Top} })
    function Get-MossPromptExtra([int]$PanelHeight) {
        return [Math]::Max(-16, ($PanelHeight - 442))
    }
    function Update-MossWorkspaceLayout {
        if($f.ClientSize.Width -le 0){return}
        $gap=14; $margin=16
        $head.BringToFront()
        $top=$head.Bottom+10
        if($f.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized -and $f.ClientSize.Height -gt 1000){$top=68}
        $usableWidth=[Math]::Max(798,$f.ClientSize.Width-(2*$margin)-$gap)
        $columnWidth=[Math]::Max(552,[Math]::Min(660,[int]($usableWidth*0.58)))
        $columnWidth=[Math]::Min($columnWidth,$usableWidth-232)
        $panelHeight=[Math]::Max(320,$f.ClientSize.Height-$top-12)
        $left.SetBounds($margin,$top,$columnWidth,$panelHeight)
        $rightX=$left.Right+$gap
        $right.SetBounds($rightX,$top,[Math]::Max(220,($f.ClientSize.Width-$rightX-$margin)),$panelHeight)
        # The main workspace is laid out explicitly below. AutoScroll on the
        # left panel created a distracting blank scrollbar at minimum size,
        # because hidden state-holder controls extend beyond the visible form.
        $left.AutoScroll=$false
        $right.AutoScroll=$false
        $innerWidth=$left.ClientSize.Width-36
        $prompt.Width = $innerWidth
        # Use extra height for the prompt, or compact it slightly at minimum
        # size so the progress bar stays inside the panel.
        $promptExtra=Get-MossPromptExtra ([int]$left.ClientSize.Height)
        $prompt.Height=96+$promptExtra
        foreach($entry in $elasticLeftControls){$entry.Control.Top=$entry.Top+$promptExtra}
        $paste.Left=$left.ClientSize.Width-18-$paste.Width
        $historyLabel.Left=255
        $historyPick.Left=$historyLabel.Right+8
        $historyPick.Width=[Math]::Max(110,($paste.Left-8-$historyPick.Left))
        $style.Width=230
        $speedCombo.Width=[Math]::Min(260,$innerWidth-270)
        $speedHint.Left=$speedCombo.Right+14
        $speedHint.Width=[Math]::Max(100,$left.ClientSize.Width-$speedHint.Left-18)
        $historyLabel.Left=$historyPick.Left-($historyLabel.Width+8)
        $status.Width=$innerWidth; $prog.Width=$innerWidth
        Update-MossLeftActionLayout $promptExtra
        Update-MossRightLayout
    }
    $f.Add_Resize({ Update-MossWorkspaceLayout })
    $f.Add_Shown({ Update-MossWorkspaceLayout })

    # --- Timer + Process generation worker (no BackgroundWorker) ---
    $script:GenState = @{
        IsRunning = $false
        Process = $null
        Timer = $null
        Job = $null
        Results = $null
        Capture = $null
        CaptureRunners = @()
        CaptureAsync = @()
        CancelRequested = $false
        VramHintShown = $false
        CurrentFile = $null
        CurrentImageIndex = 0
        CurrentImageSeed = 0
        LastErrorSummary = ''
        LastStdout = ''
        LastStderr = ''
        LastExitCode = $null
        LastReport = ''
        # v0.3.6 live preview: temp folder the engine writes step previews
        # into, the newest file already shown, and the preview PictureBox.
        PreviewDir = $null
        PreviewLast = $null
        PreviewBox = $null
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
    # v0.3.6: the live preview replaces the picture in the existing Output
    # preview pane while a batch runs; keep a reference for the progress tick.
    $script:GenState.PreviewBox = $preview
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
        # continue a queued run (benchmark).
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
        foreach($runner in @($script:GenState.CaptureRunners)) {
            # Each stream reader ends once its pipe closes; Stop() cuts it
            # loose if the engine was killed before the reader could finish.
            try { $runner.Stop() } catch {}
            try { $runner.Dispose() } catch {}
        }
        $script:GenState.CaptureRunners = @()
        $script:GenState.CaptureAsync = @()
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
        $lines.Add('Sootglass Studio - Error / Diagnostic Report')
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
            # anywhere (Sootglass has no report server, and nothing leaves this PC).
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

    # v0.3.6: show the engine's newest step preview in the Output preview
    # pane. Called from Update-MossLiveProgress on every 400 ms tick. The
    # engine (moss_image proj previews) rewrites one small PNG every 4 steps;
    # we copy it unlocked so the engine never sees a file lock.
    function Update-MossLivePreview {
        $st = $script:GenState
        if ([string]$script:Settings.LivePreview -ne '1') { return }
        if (-not $st.PreviewDir -or -not (Test-Path -LiteralPath $st.PreviewDir)) { return }
        $pb = $st.PreviewBox
        if ($null -eq $pb -or $pb.IsDisposed) { return }
        $newest = $null
        try {
            $newest = Get-ChildItem -LiteralPath $st.PreviewDir -Filter '*.png' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        } catch {}
        if ($null -eq $newest) { return }
        $full = $newest.FullName
        if ($full -eq [string]$st.PreviewLast) { return }
        $img = Copy-MossImageUnlocked $full
        if ($null -eq $img) { return }
        $st.PreviewLast = $full
        try { $old = $pb.Image; $pb.Image = $img; if ($old) { $old.Dispose() } } catch {}
    }

    function Update-MossLiveProgress {
        $st = $script:GenState
        if (-not $st.IsRunning -or $null -eq $st.Process -or $st.Process.HasExited) { return }
        Update-MossLivePreview
        Update-MossPowerSampling
        if ($null -eq $st.Capture) { return }
        $elapsed = 0.0
        if ($st.JobStartedAt) { $elapsed = [Math]::Max(0, ((Get-Date) - $st.JobStartedAt).TotalSeconds) }
        $combined = ([string]$st.Capture.Out) + "`n" + ([string]$st.Capture.Err)
        # Per-image runs (v0.3.9): each run renders ONE image and saves it
        # immediately. Older comment kept for history: the engine defers all
        # saves to the end of a MULTI-image batch, which is why Sootglass now
        # runs one process per image.
        $saveMatches = [regex]::Matches($combined, '(?i)save result image\s+(\d+)')
        $completedCount = 0
        foreach ($sm in $saveMatches) { $completedCount = [Math]::Max($completedCount, ([int]$sm.Groups[1].Value + 1)) }
        # BUG (user report, batch stuck at '1 of 2'): this engine commit DEFERS
        # all file saves to the END of the batch - the 'save result image N'
        # lines arrive together when everything is done, so save lines can
        # never drive mid-batch progress. The engine DOES stream one sampling
        # bar line per image sequentially (each line ends in it/s or s/it),
        # so count COMPLETED PASSES: a bar line whose last bar reached its
        # denominator = one finished image. The image rendering right now is
        # the next one. Take whichever signal knows more (older engines also
        # printed per-image save lines as they went).
        $passCount = 0
        $passCompleted = 0
        $lastBarStart = -1
        $scanOff = 0
        foreach ($pline in ($combined -split "`n")) {
            $pBars = [regex]::Matches($pline, '(?i)\|\s*(\d{1,5})\s*/\s*(\d{1,5})\s*-\s*[^|\r\n]*?(it/s|s/it)')
            if ($pBars.Count -gt 0) {
                $passCount++
                $lastBarStart = $scanOff
                $pLast = $pBars[$pBars.Count - 1]
                if (([int]$pLast.Groups[2].Value -gt 0) -and ([int]$pLast.Groups[1].Value -ge [int]$pLast.Groups[2].Value)) { $passCompleted++ }
            }
            $scanOff += $pline.Length + 1
        }
        if ($passCompleted -gt $completedCount) { $completedCount = $passCompleted }
        # v0.3.9: one engine run per image - the run's stdout only knows about
        # the CURRENT image (this run's pass), so the batch-wide index is
        # $st.BatchIndex and the seed is the run's own sequential seed.
        $thisImage = [int]$st.BatchIndex
        $st.CurrentImageIndex = $thisImage
        $st.CurrentImageSeed = [long]$st.Job.Seed + ($thisImage - 1)
        $imageElapsed = 0.0
        if ($st.ImageStartedAt) { $imageElapsed = [Math]::Max(0, ((Get-Date) - $st.ImageStartedAt).TotalSeconds) }
        $engineProgress = $null
        $st.StepNum = 0; $st.StepDen = 0
        # Only look at output of the image that is rendering right now: older
        # lines of a batch keep their final 'N/N' bar and would fake 100%, and
        # their 'decoded' lines would fake 'saving...'. Window = from the start
        # of the LAST sampling bar line (the current pass) to the end - that
        # keeps this pass's own bars, decoding and save line, and excludes
        # every earlier pass of the batch.
        $progressWindow = $combined
        if ($lastBarStart -ge 0) { $progressWindow = $combined.Substring($lastBarStart) }
        # LIVE COMPLETION OVERLAP (user: the resizer waited for the whole
        # batch - resizing is CPU work, generation is GPU work, so they can
        # run at the same time): an image counts as fully written when the
        # engine has logged its 'save result image N' line (N 0-based). Each
        # such image is upscaled + registered NOW while the engine keeps
        # rendering the rest.
        $maxDone = $completedCount
        try {
        if ($maxDone -gt 0) {
            for ($ci = 1; $ci -le $maxDone; $ci++) {
                if ($st.LiveCompletedImages -contains $ci) { continue }
                $liveSeed = [long]$st.Job.Seed + ($ci - 1)
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
        $btnSkip.Enabled = $false
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
        # v0.3.9: ONE engine process per IMAGE (called again for each image of
        # a batch). Every image is saved the moment it is done, Skip is
        # possible, and Cancel keeps everything already saved. Weight
        # placement (GPU, RAM, disk) is decided by the engine's built-in
        # auto-fit, which works the same way for CUDA, Vulkan, SYCL and CPU builds.
        $st = $script:GenState
        $job = $st.Job
        $keepBatchPaused = [bool]$st.Paused

        # v0.3.9: ONE engine process per image (the engine defers all saves
        # to the end of a multi-image batch, so per-image runs are what make
        # each file appear immediately and make Skip possible). The model is
        # reloaded per image; seeds stay sequential (base + index - 1).
        $st.BatchIndex++
        $st.CurrentFile = [string]$st.OutputPattern

        $argsList = New-Object System.Collections.Generic.List[string]
        $argsList.Add('--diffusion-model'); $argsList.Add((Quote-ProcessArgument $job.Diffusion))
        $argsList.Add('--llm'); $argsList.Add((Quote-ProcessArgument $job.Llm))
        $argsList.Add('--vae'); $argsList.Add((Quote-ProcessArgument $job.Vae))
        $argsList.Add('--tokenizer'); $argsList.Add((Quote-ProcessArgument $job.Tokenizer))
        $argsList.Add('--cfg-scale'); $argsList.Add((ConvertFrom-MossDouble ([double]$job.Cfg)))
        $argsList.Add('--steps'); $argsList.Add([string]$job.Steps)
        $renderW = [int]$job.Width; $renderH = [int]$job.Height
        $argsList.Add('-H'); $argsList.Add([string]$job.Height)
        $argsList.Add('-W'); $argsList.Add([string]$job.Width)
        if ([long]$job.Seed -lt 0 -and $st.BatchIndex -eq 1) {
            # Seed -1 (random) must be resolved ONCE per job so the batch stays
            # sequential like a single-process batch was.
            try { $job.Seed = Get-Random -Minimum 0 -Maximum 2147483647 } catch { $job.Seed = 42 }
            $log.AppendText(("`r`nRandom seed: this batch uses base seed {0} (images follow as seed+1, seed+2, ...)." -f $job.Seed))
        }
        $argsList.Add('-s'); $argsList.Add([string]([long]$job.Seed + $st.BatchIndex - 1))
        $argsList.Add('--batch-count'); $argsList.Add('1')
        $argsList.Add('--output-begin-idx'); $argsList.Add([string]$st.BatchIndex)
        $argsList.Add('--conditioning-cache-size'); $argsList.Add('1')
        # Speed modes (generation): render at a reduced size with the FULL step
        # count and then
        # Sootglass upscales the finished image in pixel space. No second sampling
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
        switch ([string]$job.SpeedMode) {
            '2x' { $speedScale = 0.7 }
            '4x' { $speedScale = 0.5 }
            '8x' { $speedScale = 0.35 }
            'Fast' { $speedScale = [Math]::Min(0.35, 128.0 / [Math]::Min($job.Width, $job.Height)) }
        }
        $st.UpscaleTarget = $null
        if ($speedScale -gt 0) {
            $smallW = Get-MossScaledDimension ([int]$job.Width) $speedScale
            $smallH = Get-MossScaledDimension ([int]$job.Height) $speedScale
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
        # (v0.3.0: the improve-only arg handling - model passes and the img2img - was removed.)
        # v0.3.9 HOTFIX (empty-prompt bug): the -p line below used
        # $effectivePrompt, which was only defined in the LoRA block AFTER
        # this point - so the engine received an EMPTY positive prompt and
        # rendered unconditioned garbage (engine metadata showed prompt =
        # ""; user: 'Sootglass won't listen to my prompt'). The prompt + LoRA
        # tags are now built RIGHT HERE, immediately before -p.
        $effectivePrompt = [string]$job.Prompt
        $loraTags = @()
        foreach($loraEntry in ([string]$script:Settings.LoraSelection -split '\|')) {
            if($loraEntry -match '^([^:]+):(.+)$'){
                $loraStem=$Matches[1].Trim(); $loraVal=0.0
                if($loraStem -and [double]::TryParse(([string]$Matches[2]).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$loraVal)){
                    if($loraVal -gt 0 -and $loraVal -le 1.5){
                        $loraPath = Join-Path (Ensure-MossLoraDir) ($loraStem + '.safetensors')
                        if(Test-Path -LiteralPath $loraPath -PathType Leaf){
                            $loraTags += ('<lora:' + $loraStem + ':' + [string]$loraVal.ToString([System.Globalization.CultureInfo]::InvariantCulture) + '>')
                        } else {
                            $log.AppendText(("`r`nLoRA skipped (file missing in {0}): {1}" -f (Ensure-MossLoraDir), $loraStem))
                        }
                    }
                }
            }
        }
        if($loraTags.Count -gt 0){
            $loraDirAbs2 = Ensure-MossLoraDir
            $argsList.Add('--lora-model-dir'); $argsList.Add((Quote-ProcessArgument $loraDirAbs2))
            $effectivePrompt = ($effectivePrompt.Trim() + ' ' + ($loraTags -join ' ')).Trim()
            $log.AppendText(("`r`nLoRA: {0}" -f ($loraTags -join ' ')))
        }
        # Empty prompt must never reach the engine (the safe-mode/history
        # paths above guarantee a non-empty job.Prompt; this guard makes the
        # failure LOUD instead of rendering unconditioned garbage).
        if([string]::IsNullOrWhiteSpace($effectivePrompt)){ throw 'Internal error: empty prompt for the engine - generation aborted (this is a Sootglass bug, not your prompt)' }
        $argsList.Add('-p'); $argsList.Add((Quote-ProcessArgument $effectivePrompt))
        $argsList.Add('-o'); $argsList.Add((Quote-ProcessArgument ([string]$st.CurrentFile)))
        # Optional sampler/scheduler: 'Default (model)' means the flag is omitted
        # so the engine keeps its model-specific choice. Choke-point guard (v0.2.0):
        # OLD sidecars can still carry the DISPLAY label 'Default (model)' â€” it
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

        # v0.3.6 optional engine features (Generation... dialog -> 'Speed &
        # memory'). Each is a single flag; disabled means the flag is omitted
        # and the engine runs exactly as before.
        if ([string]$script:Settings.SageAttention -eq '1') { $argsList.Add('--sage-attn') }
        if ([string]$script:Settings.OffloadToCpu -eq '1') { $argsList.Add('--offload-to-cpu') }
        if ([string]$script:Settings.CacheMode -eq 'easycache') { $argsList.Add('--cache-mode'); $argsList.Add('easycache') }
        # v0.3.7 advanced tuning flags (Generation... dialog -> 'Advanced
        # tuning'). Blank/off values mean the flag is omitted entirely.
        if ($script:Settings.Contains('Guidance')) {
            $tuneGuid=0.0
            if([double]::TryParse(([string]$script:Settings.Guidance).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$tuneGuid)){ $argsList.Add('--guidance'); $argsList.Add((ConvertFrom-MossDouble $tuneGuid)) }
        }
        switch ([string]$script:Settings.Circular) {
            'xy' { $argsList.Add('--circular') }
            'x'  { $argsList.Add('--circularx') }
            'y'  { $argsList.Add('--circulary') }
        }
        $tuneRng=[string]$script:Settings.SamplerRng
        if ($tuneRng -in @('std_default','cuda','cpu')) { $argsList.Add('--sampler-rng'); $argsList.Add($tuneRng) }
        if ($script:Settings.Contains('MaxVram')) {
            $tuneVram=0.0
            if([double]::TryParse(([string]$script:Settings.MaxVram).Trim(),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$tuneVram) -and $tuneVram -ge 0){ $argsList.Add('--max-vram'); $argsList.Add((ConvertFrom-MossDouble $tuneVram)) }
        }
        if ([string]$script:Settings.EagerLoad -eq '1') { $argsList.Add('--eager-load') }
        if ([string]$script:Settings.DisablePrefetch -eq '1') { $argsList.Add('--disable-prefetch') }
        # (v0.3.8 LoRA prompt-tag build MOVED above the -p line, see the
        # v0.3.9 HOTFIX comment there - it used to run too late, leaving the
        # engine with an empty prompt.)
        # Live preview: the engine writes a small PNG every N denoiser steps
        # into a private temp folder; the 400 ms progress tick shows the
        # newest one in the Output preview pane. Old preview folders are
        # swept first so the temp area never grows unbounded.
        if ([string]$script:Settings.LivePreview -eq '1' -and [string]$script:Settings.PreviewMethod -ne 'none') {
            try {
                Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'moss-preview-*' -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -ne [string]$st.PreviewDir } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            } catch {}
            $st.PreviewDir = Join-Path ([System.IO.Path]::GetTempPath()) ('moss-preview-' + [System.IO.Path]::GetRandomFileName())
            [void][System.IO.Directory]::CreateDirectory($st.PreviewDir)
            $st.PreviewLast = $null
            # v0.3.9 preview decoder + update frequency (Generation dialog).
            $pvMethod=[string]$script:Settings.PreviewMethod
            if($pvMethod -eq 'tae'){
                $taesdPath=Join-Path $script:AppRoot 'models\taesd.safetensors'
                if(Test-Path -LiteralPath $taesdPath -PathType Leaf){ $argsList.Add('--taesd'); $argsList.Add((Quote-ProcessArgument $taesdPath)) }
                else { $pvMethod='proj'; $log.AppendText("`r`nLive preview: no models\taesd.safetensors found - using the fast built-in proj preview instead.") }
            }
            if($pvMethod -in @('proj','vae','tae')){ $argsList.Add('--preview'); $argsList.Add($pvMethod) }
            $pvInt=4
            if([int]::TryParse([string]$script:Settings.PreviewInterval,[ref]$pvInt)){ $pvInt=[Math]::Max(1,[Math]::Min(20,$pvInt)) }else{ $pvInt=4 }
            $argsList.Add('--preview-interval'); $argsList.Add([string]$pvInt)
            $argsList.Add('--preview-path'); $argsList.Add((Quote-ProcessArgument (Join-Path $st.PreviewDir 'moss_preview_%03d.png')))
        } else {
            $st.PreviewDir = $null; $st.PreviewLast = $null
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $job.Engine
        $psi.Arguments = ($argsList -join ' ')
        # Sootglass is a GUI front-end for the sd-cli command-line engine. When the
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

        # Engine output capture on BACKGROUND RUNSPACE THREADS: PowerShell's
        # Register-ObjectEvent actions NEVER fire while the WinForms message
        # loop is running (the PS event queue is not pumped), so the old
        # event-based capture delivered NOTHING - live progress, %, ETA and
        # even the finished-run log all saw empty output for the whole life of
        # this feature. One reader per pipe blocks in ReadLine() and appends
        # every line to a synchronized hashtable that the timer tick reads.
        $st.Capture = [hashtable]::Synchronized(@{ Out = ''; Err = '' })
        $st.CaptureRunners = @()
        $st.CaptureAsync = @()

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
            # Start independent readers after the process exists so neither
            # redirected pipe can fill while the other is being drained.
            $captureReaders=Start-MossCaptureReaders $proc $st.Capture
            $st.CaptureRunners=$captureReaders.Runners
            $st.CaptureAsync=$captureReaders.Async
            $st.Process = $proc
            $script:ActiveProcess = $proc
            $st.ImageStartedAt = Get-Date
            $st.ImageProgress = 0
            $st.StepNum = 0; $st.StepDen = 0
            $st.CurrentImageIndex = $st.BatchIndex
            if ($keepBatchPaused) {
                if (Suspend-MossProcess $proc) {
                    $st.Paused = $true
                    $btnPause.Text = 'Resume'
                    $status.Text = ("PAUSED - image {0} of {1} frozen (VRAM stays allocated). Click Resume to continue." -f $st.BatchIndex, $job.Count)
                } else {
                    $st.Paused = $false; $st.PausedAt = $null
                    $btnPause.Text = 'Pause'
                    $status.Text = ("Rendering image {0} of {1} (seed {2})..." -f $st.BatchIndex, $job.Count, ([long]$job.Seed + $st.BatchIndex - 1))
                    $log.AppendText("`r`nPause could not be maintained after skipping; the next image is running.")
                }
            } else {
                $st.Paused = $false; $st.PausedAt = $null
                $btnPause.Text = 'Pause'
                $status.Text = ("Rendering image {0} of {1} (seed {2})..." -f $st.BatchIndex, $job.Count, ([long]$job.Seed + $st.BatchIndex - 1))
                if ($up) { $status.Text = ("Fast mode: rendering image {0} of {1} small (upscales when done)..." -f $st.BatchIndex, $job.Count) }
            }
        } catch {
            $msg = "Failed to start engine: $($_.Exception.Message)"
            $log.AppendText("`r`n$msg")
            [void](Write-MossErrorLog 'Sootglass engine start failure' $msg)
            [void]$st.Results.Add([pscustomobject]@{ Path = ([string]$st.CurrentFile); ExitCode = -1; Seed = $job.Seed; Output = $msg })
            Complete-MossGen 'Generation failed - the engine could not be started'
            Start-MossNextBench
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
        }
        try {
            # The sidecar must record the ACTUAL saved size: for a speed-mode
            # run the pixel upscaler resizes the file first - the job's
            # own W/H would then be wrong (misleading info/readouts).
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
                Sampler = $(if($job.SamplingMethod){ [string]$job.SamplingMethod }else{ $null })
                Scheduler = $(if($job.Scheduler){ [string]$job.Scheduler }else{ $null })
                GeneratedAt = (Get-Date).ToString('o'); Engine = $job.Engine
            }
            if ($script:HistoryPassphrase) {
                $meta.PromptProtected = Protect-MossPayload ([string]$job.Prompt) $script:HistoryPassphrase
                if ($job.NegativePrompt) { $meta.NegativePromptProtected = Protect-MossPayload ([string]$job.NegativePrompt) $script:HistoryPassphrase }
            } elseif (-not $script:HistoryLocked) {
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
        # Newest file goes to the TOP of the list and is selected (user
        # request: the last generated file must be the highlighted one).
        [void]$fileList.Items.Insert(0,$file)
        [void]$script:GeneratedFiles.Add($file)
        $fileList.SelectedIndex = 0
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
            if ($st.SkipRequested -and -not $st.CancelRequested) {
                # Skipping the frozen image must not unpause the rest of the batch.
                $pauseNow = Get-Date
                if ($st.PausedAt) {
                    $pauseSpan = ($pauseNow - $st.PausedAt).TotalSeconds
                    if ($st.JobStartedAt) { $st.JobStartedAt = $st.JobStartedAt.AddSeconds($pauseSpan) }
                    if ($st.ImageStartedAt) { $st.ImageStartedAt = $st.ImageStartedAt.AddSeconds($pauseSpan) }
                    $st.PausedTotalSec = [double]$st.PausedTotalSec + $pauseSpan
                }
                $st.PausedAt = $pauseNow
            } else {
                $st.Paused = $false; $st.PausedAt = $null
                $btnPause.Text = 'Pause'
            }
        }
        if (-not $st.Process.HasExited) { Update-MossLiveProgress; return }

        # This run has finished (one process = one image in v0.3.9).
        $exitCode = $st.Process.ExitCode
        $st.LastExitCode = $exitCode
        $job = $st.Job
        if ($st.ImageStartedAt -and [int]$st.CurrentImageIndex -gt 0) { [void]$st.ImageDurations.Add([Math]::Max(0.1, ((Get-Date) - $st.ImageStartedAt).TotalSeconds)) }

        # Let both readers finish draining (pipes close at exit) before
        # reading the final output.
        for($captureIndex=0;$captureIndex -lt $st.CaptureRunners.Count;$captureIndex++) {
            try {
                if($st.CaptureAsync[$captureIndex]) {
                    [void]$st.CaptureRunners[$captureIndex].EndInvoke($st.CaptureAsync[$captureIndex])
                }
            } catch {}
        }
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
        foreach($runner in @($st.CaptureRunners)) {
            try { $runner.Stop() } catch {}
            try { $runner.Dispose() } catch {}
        }
        $st.CaptureRunners = @()
        $st.CaptureAsync = @()
        $st.Capture = $null

        try { $st.Process.Dispose() } catch {}
        $st.Process = $null
        $script:ActiveProcess = $null

        # v0.3.9 per-image runs: this process rendered exactly ONE image
        # ($st.BatchIndex). Decide what happens next before the batch-end
        # bookkeeping below: Skip abandons it, an engine failure stops the
        # rest, otherwise the next image starts immediately and the file
        # just saved is upscaled + listed right now.
        $imgIndex = [int]$st.BatchIndex
        $imgFailed = ($exitCode -ne 0)
        if ($st.SkipRequested -and -not $st.CancelRequested) {
            $st.SkipRequested = $false
            [void]$st.SkippedImages.Add($imgIndex)
            # A skipped image is INTENTIONAL, not a failure: taskkill /F gives
            # the process exit code 1, which must not leak into the batch-end
            # summary (live case: skipping the last image reported 'engine
            # returned exit code 1' and wrote an error report).
            $exitCode = 0
            $st.LastExitCode = 0
            $log.AppendText(("`r`nImage {0} of {1} skipped on request - nothing was kept for it." -f $imgIndex, $job.Count))
        } elseif ($imgFailed -and -not $st.CancelRequested) {
            $log.AppendText(("`r`nEngine failed on image {0} of {1} (exit code {2}) - stopping the remaining {3} image(s)." -f $imgIndex, $job.Count, $exitCode, [Math]::Max(0, ([int]$job.Count - $imgIndex))))
            $st.CancelRequested = $true
        }
        if (-not $imgFailed -and -not ($st.SkippedImages -contains $imgIndex) -and -not ($st.LiveCompletedImages -contains $imgIndex)) {
            $thisSeedNow = [long]$job.Seed + ($imgIndex - 1)
            if (Complete-MossBatchImage -st $st -job $job -i $imgIndex -thisSeed $thisSeedNow -up $st.UpscaleTarget) { [void]$st.LiveCompletedImages.Add($imgIndex) }
        }
        if (-not $st.CancelRequested -and $imgIndex -lt [int]$job.Count) {
            Start-MossBatchEngine
            return
        }

        # Per-image seeds: the new engine (0d71f96) does not print per-image
        # seeds any more - batch seeds are sequential (job seed + index - 1),
        # the same rule the old fallback used. Old builds' logs still parse.
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
            # Skipped images (v0.3.9) were intentionally never rendered -
            # they are neither completed nor missing.
            if ($st.SkippedImages -contains $i) { continue }
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
                }
                # The sidecar must record the ACTUAL saved size (same rule as
                # the live path). Regression note: this readback existed in
                # v0.1.84 but was lost from THIS path in a later edit round.
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
                        Sampler = $(if($job.SamplingMethod){ [string]$job.SamplingMethod }else{ $null })
                        Scheduler = $(if($job.Scheduler){ [string]$job.Scheduler }else{ $null })
                        GeneratedAt = (Get-Date).ToString('o'); Engine = $job.Engine
                    }
                    if ($script:HistoryPassphrase) {
                        # A code is set and entered: prompts stay encrypted in the sidecar.
                        $meta.PromptProtected = Protect-MossPayload ([string]$job.Prompt) $script:HistoryPassphrase
                        if ($job.NegativePrompt) { $meta.NegativePromptProtected = Protect-MossPayload ([string]$job.NegativePrompt) $script:HistoryPassphrase }
                    } elseif (-not $script:HistoryLocked) {
                        # With no code configured, sidecar prompts are plain.
                        # If saved history is locked, omit prompts rather than
                        # exposing them while continuing without the code.
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
                [void]$fileList.Items.Insert(0,$file)
                [void]$script:GeneratedFiles.Add($file)
                $fileList.SelectedIndex = 0
            } elseif (Test-Path -LiteralPath $file) {
                $corrupt.Add($file)
                [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = 'Image file is corrupt or incomplete (write interrupted?) - not added to the list; the file stays on disk' })
            } else {
                $missing.Add($file)
                [void]$st.Results.Add([pscustomobject]@{ Path = $file; ExitCode = $exitCode; Seed = $thisSeed; Output = 'Image file was not created' })
            }
        }

        $outputText = "Engine: $($job.Engine)`r`nWorking directory: $($job.Root)`r`nExit code: $exitCode`r`n--- STDOUT ---`r`n$stdout`r`n--- STDERR ---`r`n$stderr"
        # v0.3.44: keep every run's raw engine output for the pre-flight VRAM
        # refinement (successes too - past tracked-weights lines are the data).
        [void](Write-MossRunLog $stdout $stderr)
        $finalMsg = $null
        if ($exitCode -ne 0) {
            $outputText = "ERROR: Engine process returned exit code $exitCode.`r`n" + $outputText
            [void](Write-MossErrorLog ("Sootglass generation error - batch of {0} image(s) (exit {1})" -f $job.Count, $exitCode) $outputText)
            $finalMsg = if ($ok -gt 0) { "Partially completed - $ok of $($job.Count) image(s) generated (engine exit $exitCode)" } else { "Generation failed - engine returned exit code $exitCode" }
        } elseif ($corrupt.Count -gt 0) {
            $outputText = ("ERROR: {0} expected image file(s) exist but are CORRUPT or incomplete (the write was interrupted - often a full disk, power loss or antivirus interference). They are NOT in the list; the broken files stay on disk so you can look at them:`r`n" -f $corrupt.Count) + (($corrupt | ForEach-Object { '  ' + $_ }) -join "`r`n") + "`r`n" + $outputText
            [void](Write-MossErrorLog ("Sootglass generation error - {0} of {1} image(s) corrupt/incomplete" -f $corrupt.Count, $job.Count) $outputText)
            $finalMsg = "Partially completed - $ok of $($job.Count) image(s) generated; $($corrupt.Count) corrupt file(s) not listed"
        } elseif ($missing.Count -gt 0) {
            $outputText = ("ERROR: Engine returned exit code 0 but {0} expected image file(s) were not created:`r`n" -f $missing.Count) + (($missing | ForEach-Object { '  ' + $_ }) -join "`r`n") + "`r`n" + $outputText
            [void](Write-MossErrorLog ("Sootglass generation error - {0} of {1} image(s) missing" -f $missing.Count, $job.Count) $outputText)
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
            $budgetFailurePattern = 'cannot make enough memory available|(?:insufficient|not enough|out of|no|lack of)\s+(?:(?:GPU|CUDA|device|video)\s+)?(?:memory|VRAM)|(?:GPU|CUDA|device|video)\s+(?:memory|VRAM)[^\r\n]{0,40}(?:insufficient|not enough|exhausted|out of)|failed to allocate|allocation failed|failed during weight preparation'
            $memoryDeath = -not $hasExplicitError
            if ($hasExplicitError -and ($engineErrorText -match 'memory|allocat|out of mem|OOM' -or $allOutputText -match $budgetFailurePattern)) { $memoryDeath = $true }
            if ($exitCode -ne 0 -and $memoryDeath) {
                $mp = [Math]::Round(([double]$job.Width * [double]$job.Height / 1000000.0), 1)
                $oomHint = "`r`nHint: the engine stopped without finishing"
                if ($engineErrorText) { $oomHint += (" - its last error: {0}" -f $engineErrorText) } else { $oomHint += ' without any error message' }
                $budgetFailure=$allOutputText -match $budgetFailurePattern
                if($budgetFailure){
                    $oomHint += '. The engine reports insufficient GPU memory; the shape error above may be a follow-on failure. With LoRAs active, try Generation... > Speed & memory > CPU offload (it saves VRAM but can be slower).'
                    if([string]$script:Settings.EagerLoad -eq '1'){ $oomHint += ' Eager load is on; turning it off under Advanced tuning may also reduce memory pressure.' }
                    $selectedLoras=@([string]$script:Settings.LoraSelection -split '\|' | Where-Object { $_ -match '^[^:]+:' })
                    if($selectedLoras.Count -gt 1){ $oomHint += ' If it still fails, test one LoRA at a time or reduce image dimensions.' }
                    else { $oomHint += ' If it still fails, reduce image dimensions or use a faster render size.' }
                } else {
                    $oomHint += (". At {0} x {1} ({2} MP, {3} steps) the most common cause is running out of GPU or system memory. Try a smaller size or a fast speed mode (which renders small and enlarges)." -f $job.Width, $job.Height, $mp, $job.Steps)
                }
                $log.AppendText($oomHint)
                if($budgetFailure -and -not $st.VramHintShown){
                    $st.VramHintShown=$true
                    $oomDialog='The engine ran out of GPU memory while preparing this image.'
                    $offloadEnabled=[string]$script:Settings.OffloadToCpu -eq '1'
                    if($offloadEnabled){ $oomDialog+="`r`n`r`nCPU offload is already enabled. It saves VRAM but may slow generation; turn it off in Generation options > Speed & memory when you no longer need it." }
                    else { $oomDialog+="`r`n`r`nWould you like to enable CPU offload for future generations? It saves VRAM but may slow generation. Turn it off in Generation options > Speed & memory when you no longer need it." }
                    if([string]$script:Settings.EagerLoad -eq '1'){ $oomDialog+="`r`n`r`nEager load is on; turning it off under Advanced tuning may also help." }
                    $selectedLoras=@([string]$script:Settings.LoraSelection -split '\|' | Where-Object { $_ -match '^[^:]+:' })
                    if($selectedLoras.Count -gt 1){ $oomDialog+="`r`n`r`nIf it still fails, try one LoRA at a time or reduce image dimensions." }
                    else { $oomDialog+="`r`n`r`nIf it still fails, reduce image dimensions or use a faster render size." }
                    $dlgOwner=$log.FindForm()
                    if($offloadEnabled){
                        [System.Windows.Forms.MessageBox]::Show($dlgOwner,$oomDialog,'Not enough GPU memory',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
                    } else {
                        $offloadChoice=[System.Windows.Forms.MessageBox]::Show($dlgOwner,$oomDialog,'Not enough GPU memory',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
                        if($offloadChoice -eq [System.Windows.Forms.DialogResult]::Yes){
                            $previousOffload=$script:Settings.OffloadToCpu
                            $script:Settings.OffloadToCpu='1'
                            try {
                                if(-not (Save-Settings)){throw 'Settings could not be saved.'}
                                $log.AppendText("`r`nCPU offload enabled and saved. Re-running the failed generation with CPU offload...")
                                # Auto-retry (v0.3.43): the user accepted CPU offload, so the same
                                # batch that just failed is relaunched right away. The rerun is
                                # deferred with BeginInvoke so it starts only after this completion
                                # handler has fully finished (avoids nesting a new engine run inside
                                # the handler for the old one). VramHintShown is already set, so a
                                # repeat failure will not pop the dialog again and loop.
                                $log.BeginInvoke([Action]{ Start-MossGeneration $job }) | Out-Null
                            } catch {
                                $script:Settings.OffloadToCpu=$previousOffload
                                $saveMessage="CPU offload could not be enabled or saved. The setting was not changed.`r`n`r`n$($_.Exception.Message)"
                                $log.AppendText("`r`n"+$saveMessage)
                                [System.Windows.Forms.MessageBox]::Show($dlgOwner,$saveMessage,'Could not save setting',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
                            }
                        }
                    }
                }
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
            [void](Write-MossErrorLog ('Sootglass scheduler rejected by engine - ' + $rejectedSched) ($stdout + "`n" + $stderr))
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
        # Continue any pending queued run (benchmark) unless the user cancelled.
        if (-not $st.CancelRequested) { Start-MossNextBench } else { $script:BenchQueue.Clear(); $script:BenchTotal = 0; $script:BenchStartedAt = $null }
    }

    function Start-MossGeneration {
        param($Job)
        if ($script:GenState.IsRunning) { return }
        # Hard minor-safety gate applies regardless of the optional filter.
        if (-not (Test-MossPromptHardSafety ([string]$Job.Prompt))) {
            $log.AppendText("`r`nBlocked: prompts sexualizing minors cannot be generated. If this refers to an adult teen, explicitly state 18+ in the prompt.")
            $status.Text = 'Blocked: identify the adult subject as 18+'
            $generate.Enabled = $true
            $cancel.Enabled = $false
            return
        }
        if ([bool]$script:Settings.SafeMode -and -not (Test-MossPromptSafe ([string]$Job.Prompt))) {
            $log.AppendText("`r`nThe optional content filter blocked this prompt. Disable it in Generation settings to allow general adult content.")
            $status.Text = 'Blocked by optional content filter'
            $generate.Enabled = $true
            $cancel.Enabled = $false
            return
        }
        # v0.3.43 PRE-FLIGHT VRAM CHECK: before the engine launches, compare
        # the real on-disk sizes of the selected diffusion model + LLM against
        # the VRAM that is actually free right now (nvidia-smi, one-shot
        # query, ~0.3 s). If the pair cannot fit plus a 512 MB margin and CPU
        # offload is OFF, offer to enable it and restart this same generation
        # right away - the failure never happens and the user loses no run.
        # BF16 is skipped: the engine automatically offloads parts of that
        # pair to system RAM on its own (documented behavior), so the raw
        # sizes would produce a false warning there.
        try {
            $smiExe = Get-MossNvidiaSmiPath
            $plannedMB = 0L; $sizesKnown = $true
            $modelLeaves = @()
            foreach ($mpf in @([string]$Job.Diffusion, [string]$Job.Llm)) {
                try {
                    $plannedMB += [Math]::Round((Get-Item -LiteralPath $mpf -ErrorAction Stop).Length / 1MB)
                    $modelLeaves += (Split-Path -Leaf $mpf)
                } catch { $sizesKnown = $false; break }
            }
            # v0.3.44 refinement: prefer the engine's own measured figure. If a
            # past run loaded this exact diffusion+LLM pair, its 'tracked
            # weights' line tells us what REALLY fit into VRAM - use that when
            # it exceeds the raw file-size estimate instead of under-warning.
            if ($sizesKnown -and $modelLeaves.Count -eq 2) {
                try {
                    $trackedMB = Get-MossTrackedWeightsMB $modelLeaves
                    if ($trackedMB -gt $plannedMB) {
                        $plannedMB = [long]$trackedMB
                        $log.AppendText(("`r`nPre-flight: a past run put about {0} GB of weights into VRAM with these exact models; using the measured figure instead of the file-size estimate." -f ([Math]::Round($trackedMB / 1024.0, 1)))) | Out-Null
                    }
                } catch {}
            }
            $llmName = try { (Split-Path -Leaf $Job.Llm) } catch { '' }
            $bf16Pair = ($llmName -like '*BF16*')
            if ($smiExe -and $sizesKnown -and -not $bf16Pair -and [string]$script:Settings.OffloadToCpu -ne '1') {
                $smiOut = & $smiExe --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
                $freeMB = 0
                $firstLine = @($smiOut | Select-Object -First 1)
                if ($firstLine -and [int]::TryParse(([string]$firstLine).Trim(), [ref]$freeMB) -and $freeMB -gt 0) {
                    $pfPlanned = [Math]::Round($plannedMB / 1024.0, 1)
                    $pfFree = [Math]::Round($freeMB / 1024.0, 1)
                    if (($plannedMB + 512) -gt $freeMB) {
                        $log.AppendText(("`r`nPre-flight: the selected models need about {0} GB but only {1} GB of VRAM is free right now." -f $pfPlanned, $pfFree))
                        $pfOwner = $log.FindForm()
                        $pfMsg = "The selected models need about {0} GB of VRAM, but only {1} GB is free right now.`r`n`r`nWithout CPU offload the engine will likely run out of GPU memory and stop before producing an image.`r`n`r`nEnable CPU offload and generate now? It keeps the model weights in system RAM (saves VRAM, may be slower). You can turn it off again in Generation options > Speed & memory." -f $pfPlanned, $pfFree
                        $pfChoice = [System.Windows.Forms.MessageBox]::Show($pfOwner, $pfMsg, 'Generation may not fit in VRAM', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                        if ($pfChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                            $script:Settings.OffloadToCpu = '1'
                            if (Save-Settings) {
                                $log.AppendText("`r`nCPU offload enabled and saved for future generations.")
                            } else {
                                $log.AppendText("`r`nNote: CPU offload was enabled for this run but could not be saved to settings.")
                            }
                            # Restart the SAME job with the new flag: recursive
                            # call is safe because OffloadToCpu is now '1', so
                            # the pre-flight passes on the second entry.
                            Start-MossGeneration $Job
                            return
                        }
                        $log.AppendText("`r`nContinuing without CPU offload as requested.")
                    }
                }
            }
        } catch {}

        $script:GenState.IsRunning = $true
        $script:GenState.CancelRequested = $false
        $script:GenState.VramHintShown = $false
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
        # v0.3.9 per-image engine runs: one process renders ONE image, the
        # file is saved the moment it is done. BatchIndex = image rendering
        # now (1-based); SkippedImages = indices abandoned via Skip;
        # OutputPattern = one filename pattern shared by the whole job.
        $script:GenState.BatchIndex = 0
        $script:GenState.SkippedImages = New-Object System.Collections.ArrayList
        $script:GenState.SkipRequested = $false
        $stamp39 = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $script:GenState.OutputPattern = Join-Path $Job.OutputPath ("Sootglass_{0}_%02d.png" -f $stamp39)
        $script:GenState.EtaShown = $null
        $script:GenState.EtaUpdatedAt = $null
        # Seed the ETA from the benchmark store so it is meaningful from the
        # first second (falls back to 'ETA calculating' when no data exists).
        $script:GenState['PredictedPerImage'] = $null
        # Power meter state: reset per job, and resolve the measurement tool
        # once per run (nvidia-smi when present, TDP estimate otherwise).
        $script:GenState.PowerJoules = 0.0; $script:GenState.PowerMeasuredJoules = 0.0; $script:GenState.PowerSeconds = 0.0
        $script:GenState.PowerLastSample = Get-Date; $script:GenState.PowerLastW = 250.0; $script:GenState.PowerLastMeasured = $false
        $script:GenState.PowerSmi = Get-MossNvidiaSmiPath
        $gpuNameEst = ''; try { $g0est = @($script:Inventory | Where-Object { -not $_.IsVirtual } | Select-Object -First 1); if ($g0est) { $gpuNameEst = [string]$g0est.Name } } catch {}
        $script:GenState.PowerEstimateW = Get-MossPowerEstimateWatts (Get-MossGpuTdp $gpuNameEst)
        try {
            $bmEst = Get-MossBenchmarkEstimate ([int]$Job.Width) ([int]$Job.Height) ([string]$Job.SpeedMode) ([int]$Job.Steps) ($null -ne $Job.InitImage)
            if ($bmEst) {
                $script:GenState['PredictedPerImage'] = [double]$bmEst.Sec
            }
        } catch {}

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 400
        $timer.Add_Tick({ On-MossGenTimerTick })
        $script:GenState.Timer = $timer
        $timer.Start()

        $generate.Enabled = $false
        $cancel.Enabled = $true
        $log.Clear()
        # Keep the existing file list: it is the full history of generated
        # files (populated at startup). New images are appended as they land.
        $status.Text = 'Starting engine...'
        # Progress bar: marquee until the engine reports the first step.
        $prog.Value = 0
        $prog.Style = 'Marquee'
        $prog.Visible = $true

        Start-MossBatchEngine
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
                        try { $p = Unprotect-MossPayload ([string]$sc.PromptProtected) $script:HistoryPassphrase; if ($p) { $prompt=[string]$p } else { $promptLockedNote='(encrypted - the history code did not unlock it)' } } catch { $promptLockedNote='(encrypted - enter your history code in Sootglass to see the prompt)' }
                    } else {
                        $promptLockedNote='(encrypted - enter your history code in Sootglass to see the prompt)'
                    }
                } elseif ($sc.Prompt) {
                    # Plain sidecar prompt (no code entered when the image was made).
                    $prompt=[string]$sc.Prompt
                } else {
                    $promptLockedNote='(not saved - history was locked or no history code was active when this image was created)'
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
            $lines.Add('No info file (.json) was found for this image (Sootglass stores them in the metadata subfolder of the output folder).')
        }
        $g=New-Object System.Windows.Forms.Form
        $g.Text='Image info'; $g.Size=New-Object System.Drawing.Size(660,540); $g.StartPosition='CenterParent'; $g.FormBorderStyle='FixedDialog'; $g.MaximizeBox=$false; $g.MinimizeBox=$false; $g.KeyPreview=$true
        $g.BackColor=[System.Drawing.Color]::FromArgb(18,22,31); $g.ForeColor=[System.Drawing.Color]::FromArgb(230,236,245); $g.Font=New-Object System.Drawing.Font('Segoe UI',9)
        $lp=New-Object System.Windows.Forms.Label; $lp.Text='Prompt used for this image'; $lp.Location=New-Object System.Drawing.Point(12,10); $lp.Size=New-Object System.Drawing.Size(400,18); $lp.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($lp)
        $pBox=New-Object System.Windows.Forms.TextBox; $pBox.AccessibleName='Prompt used for this image'; $pBox.TabIndex=0; $pBox.Multiline=$true; $pBox.ReadOnly=$true; $pBox.ScrollBars='Vertical'; $pBox.WordWrap=$true; $pBox.Text=$(if($prompt){$prompt}else{$promptLockedNote}); $pBox.Location=New-Object System.Drawing.Point(12,30); $pBox.Size=New-Object System.Drawing.Size(620,120); $pBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $pBox.ForeColor=$cText; $pBox.BorderStyle='FixedSingle'; $g.Controls.Add($pBox)
        $ln=New-Object System.Windows.Forms.Label; $ln.Text='Negative prompt'; $ln.Location=New-Object System.Drawing.Point(12,158); $ln.Size=New-Object System.Drawing.Size(400,18); $ln.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($ln)
        $nBox=New-Object System.Windows.Forms.TextBox; $nBox.AccessibleName='Negative prompt'; $nBox.TabIndex=1; $nBox.Multiline=$true; $nBox.ReadOnly=$true; $nBox.ScrollBars='Vertical'; $nBox.WordWrap=$true; $nBox.Text=$(if($neg){$neg}else{'(none)'}); $nBox.Location=New-Object System.Drawing.Point(12,178); $nBox.Size=New-Object System.Drawing.Size(620,48); $nBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $nBox.ForeColor=$cText; $nBox.BorderStyle='FixedSingle'; $g.Controls.Add($nBox)
        $ls=New-Object System.Windows.Forms.Label; $ls.Text='Settings and origin (also stored in the metadata subfolder of the output folder)'; $ls.Location=New-Object System.Drawing.Point(12,234); $ls.Size=New-Object System.Drawing.Size(560,18); $ls.ForeColor=[System.Drawing.Color]::FromArgb(145,161,185); $g.Controls.Add($ls)
        $sBox=New-Object System.Windows.Forms.TextBox; $sBox.AccessibleName='Image settings and origin'; $sBox.TabIndex=2; $sBox.Multiline=$true; $sBox.ReadOnly=$true; $sBox.ScrollBars='Vertical'; $sBox.Text=($lines -join "`r`n"); $sBox.Location=New-Object System.Drawing.Point(12,254); $sBox.Size=New-Object System.Drawing.Size(620,190); $sBox.BackColor=[System.Drawing.Color]::FromArgb(16,21,30); $sBox.ForeColor=$cText; $sBox.BorderStyle='FixedSingle'; $g.Controls.Add($sBox)
        $copyBtn=New-Object System.Windows.Forms.Button; $copyBtn.AccessibleName='Copy image prompt to clipboard'; $copyBtn.TabIndex=3; $copyBtn.Text='Copy prompt'; $copyBtn.Location=New-Object System.Drawing.Point(400,456); $copyBtn.Size=New-Object System.Drawing.Size(110,30); $copyBtn.Enabled=[bool]$prompt; $g.Controls.Add($copyBtn)
        $closeBtn=New-Object System.Windows.Forms.Button; $closeBtn.Text='Close'; $closeBtn.Location=New-Object System.Drawing.Point(522,456); $closeBtn.Size=New-Object System.Drawing.Size(110,30); $g.Controls.Add($closeBtn)
        $copyBtn.Add_Click({ if($prompt){ try { [System.Windows.Forms.Clipboard]::SetText($prompt) } catch {} } })
        $closeBtn.TabIndex=4
        $closeBtn.Add_Click({ $g.Close() })
        $g.AcceptButton=$closeBtn; $g.CancelButton=$closeBtn
        $g.ShowDialog()|Out-Null
        $g.Dispose()
    }

    function Start-MossNextBench {
        # Sequentially processes the queued one-off runs (the quick benchmark
        # is the only user of this queue since v0.3.0): one engine run per item.
        if ($script:GenState.IsRunning) { return }
        if ($script:GenState.CancelRequested) {
            if($script:BenchQueue.Count -gt 0){ $log.AppendText("`r`nQueued runs cancelled.") }
            $script:BenchQueue.Clear(); $script:BenchTotal = 0; $script:BenchStartedAt = $null; return
        }
        if ($script:BenchQueue.Count -eq 0) {
            if ($script:BenchTotal -gt 0) {
                $queueElapsed = ''
                if ($script:BenchStartedAt) { $queueElapsed = ' | total elapsed ' + (Format-MossDuration ((Get-Date) - $script:BenchStartedAt).TotalSeconds) }
                $status.Text = "Benchmark finished - $script:BenchTotal run(s) processed$queueElapsed"
                $log.AppendText("`r`nBenchmark finished - $script:BenchTotal run(s) processed.")
                $script:BenchStartedAt = $null
                $script:BenchTotal = 0
            }
            return
        }
        $item = $script:BenchQueue[0]
        $script:BenchQueue.RemoveAt(0)
        if (-not $script:BenchStartedAt) { $script:BenchStartedAt = Get-Date }
        $benchPaths = @((Get-AbsoluteAppPath ([string]$script:Settings.EnginePath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.DiffusionModelPath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.LlmPath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.VaePath)),
            (Get-AbsoluteAppPath ([string]$script:Settings.TokenizerPath)))
        $missingBench = @($benchPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if ($missingBench.Count -gt 0) {
            $log.AppendText("`r`nBenchmark stopped - required file(s) not found: $($missingBench -join ', ')")
            $script:BenchQueue.Clear(); $script:BenchTotal = 0
            $status.Text = 'Benchmark stopped - missing model files (click Model files to check the paths)'
            return
        }
        $gpuIdx=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $gpuIdx=[int]$script:Settings.PreferredGpuIndex } catch { $gpuIdx=-1 } }
        $benchSteps = $(if($null -ne $item.Steps){[int]$item.Steps}else{[int]$script:Settings.Steps})
        $job=[pscustomobject]@{Engine=$benchPaths[0];Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$benchPaths[1];Llm=$benchPaths[2];Vae=$benchPaths[3];Tokenizer=$benchPaths[4];OutputPath=(Get-AbsoluteAppPath ([string]$script:Settings.OutputPath));Steps=$benchSteps;ChosenSteps=$benchSteps;Cfg=$(if($null -ne $item.Cfg){[double]$item.Cfg}else{[double]$script:Settings.CfgScale});Width=[int]$item.W;Height=[int]$item.H;Count=1;Seed=[long]$item.Seed;Prompt=[string]$item.Prompt;GpuIndex=$gpuIdx;SpeedMode='Exact';InitImage=$null;InitStrength=0.0;NegativePrompt=$item.NegativePrompt;SamplingMethod=$item.SamplingMethod;Scheduler=$item.Scheduler}
        # Benchmark runs (Tag 'bench') write into the benchmarks folder instead
        # of outputs, so test renders never pollute the file list.
        if ($item.PSObject.Properties['Tag'] -and [string]$item.Tag -eq 'bench') {
            $benchDir = Join-Path $script:AppRoot 'benchmarks'
            if (-not (Test-Path -LiteralPath $benchDir)) { New-Item -ItemType Directory -Path $benchDir -Force | Out-Null }
            $job = $job.PSObject.Copy(); $job.OutputPath = $benchDir
            $log.AppendText(("`r`nQuick benchmark run {0} of {1}: {2} x {3} at {4} engine steps..." -f ($script:BenchTotal - $script:BenchQueue.Count), $script:BenchTotal, $item.W, $item.H, $job.Steps))
            $status.Text = ("Benchmark run {0} of {1} at {2} x {3}..." -f ($script:BenchTotal - $script:BenchQueue.Count), $script:BenchTotal, $item.W, $item.H)
        }
        Start-MossGeneration -Job $job
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
        $wi=0;$he=0;if(-not [int]::TryParse($wBox.Text,[ref]$wi) -or -not [int]::TryParse($hBox.Text,[ref]$he) -or -not (Test-MossImageDimension $wi) -or -not (Test-MossImageDimension $he)){[System.Windows.Forms.MessageBox]::Show('Width and height must be between 64 and 8192 pixels and multiples of 16.','Invalid dimensions')|Out-Null;return}
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
        $isLayoutPrompt=Test-MossLayoutPrompt $p
        $generationPrompt=if($isLayoutPrompt){$p}elseif($stylePrefix -and -not $p.ToLowerInvariant().StartsWith($stylePrefix.ToLowerInvariant())){"$stylePrefix, $p"}else{$p}
        if (-not (Test-MossPromptHardSafety $generationPrompt)) {
            [System.Windows.Forms.MessageBox]::Show("This prompt may sexualize a minor, so it was blocked. If the subject is an adult teen, explicitly state 18+.",'Minor-safety check',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return
        }
        if ([bool]$script:Settings.SafeMode -and -not (Test-MossPromptSafe $generationPrompt)) {
            [System.Windows.Forms.MessageBox]::Show("The optional content filter is enabled and matched this prompt. Disable it in Generation settings to allow general adult content.",'Optional content filter',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null;return
        }
        $gpuIndex=-1; if($script:Settings.Contains('PreferredGpuIndex')){ try { $gpuIndex=[int]$script:Settings.PreferredGpuIndex } catch { $gpuIndex=-1 } }
        $speedMode=switch([string]$speedCombo.SelectedItem){'~2x faster (70%)'{'2x'}'~4x faster (50%)'{'4x'}default{'Exact'}}
        $negPrompt=[string]$script:Settings.NegativePrompt
        $samplingMethod=$null; if([string]$script:Settings.SamplingMethod -and [string]$script:Settings.SamplingMethod -ne 'Default (model)'){ $samplingMethod=[string]$script:Settings.SamplingMethod }
        $scheduler=$null; if([string]$script:Settings.Scheduler -and [string]$script:Settings.Scheduler -ne 'Default (model)'){ $scheduler=[string]$script:Settings.Scheduler }
        $job=[pscustomobject]@{Engine=$enginePath;Root=$script:AppRoot;Backend=[string]$script:Settings.Backend;Diffusion=$paths[1];Llm=$paths[2];Vae=$paths[3];Tokenizer=$paths[4];OutputPath=$outPath;Steps=$st;Cfg=$cf;Width=$wi;Height=$he;Count=$n;Seed=$baseSeed;Prompt=$generationPrompt;GpuIndex=$gpuIndex;SpeedMode=$speedMode;InitImage=$null;InitStrength=0.45;NegativePrompt=$negPrompt;SamplingMethod=$samplingMethod;Scheduler=$scheduler}
        $generate.Enabled=$false;$cancel.Enabled=$true;$btnPause.Enabled=$true;$btnPause.Text='Pause';$btnSkip.Enabled=$true;$log.Clear();$status.Text='Starting engine...';Start-MossGeneration -Job $job
    })
    $cancel.Add_Click({
        if ($script:GenState.IsRunning) {
            $script:GenState.CancelRequested = $true
            $cancel.Enabled = $false
            $generate.Enabled = $false
            $btnPause.Enabled = $false
            $btnSkip.Enabled = $false
            $status.Text = 'Cancelling generation...'
            $log.AppendText("`r`nCancellation requested. Stopping the engine and any child processes...")
            $f.Refresh()
            Stop-MossGen
            $generate.Enabled = $true
            $cancel.Enabled = $false
            $elapsedText = if ($script:GenState.JobStartedAt) { Format-MossDuration ((Get-Date) - $script:GenState.JobStartedAt).TotalSeconds } else { '0:00' }
            $prog.Visible = $false
            Restore-MossGeneratedPreview
            $status.Text = "Generation cancelled | total elapsed $elapsedText"
            $log.AppendText("`r`nGeneration cancelled. No further images will be started.")
        }
    })
    $openOut.Add_Click({$folder=Get-AbsoluteAppPath $out.Text;if(Test-Path -LiteralPath $folder){Start-Process explorer.exe -ArgumentList (Quote-ProcessArgument $folder)}})
    $f.Add_FormClosing({if($script:GenState.IsRunning){$script:GenState.CancelRequested=$true;Stop-MossGen}; if($f.Tag -ne 'RESETSETTINGS'){try { Save-MossWindowBounds $f } catch {}}})
    # v0.2.3: the window was already shown (frame + panels) before the
    # controls were added, so the Shown event has long passed by now: the
    # startup work is started explicitly instead of from the Shown event.
    $script:StartWindowWork={
        Hide-MossConsoleWindow
        # v0.3.8: make sure the optional LoRA folder exists (empty, never
        # auto-filled) so the Generation dialog has somewhere to point.
        try { [void](Ensure-MossLoraDir) } catch {}
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
        # staying on top after opening Sootglass). 200 ms later the window is
        # fully activated, so the owned modal sits on a stable foreground
        # owner - on top of Sootglass and focused, without pinning above other apps.
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
                # A failure here must never crash Sootglass with the WinForms error
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
    Update-MossWorkspaceLayout
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
    try { [void](Write-MossErrorLog 'Sootglass startup error' $errText) } catch {}
    try { [System.Windows.Forms.MessageBox]::Show(("Sootglass Studio could not start.`r`n`r`n"+$_.Exception.Message+"`r`n`r`nA technical report was saved to the logs folder."),'Sootglass Studio',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch {}
    exit 1
}