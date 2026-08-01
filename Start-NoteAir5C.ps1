[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Root', 'Verify', 'Status', 'Setup', 'Restore', 'Privacy', 'Demo')]
    [string]$Action = 'Menu',

    [switch]$AcceptUntestedFirmware,
    [switch]$NoClear,
    [switch]$Plain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = $PSScriptRoot
$script:Engine = Join-Path $PSScriptRoot 'Root-NoteAir5C.ps1'
$script:RunsRoot = Join-Path $PSScriptRoot 'runs'
$script:Module = Join-Path $PSScriptRoot 'src/NoteAir5C.Root.psm1'
if (-not (Test-Path -LiteralPath $script:Module -PathType Leaf)) { throw "Root module is missing: $script:Module" }
Import-Module $script:Module -Force
$script:Platform = Get-HostPlatform
$script:PlatformLabel = switch ($script:Platform) { 'windows' { 'WINDOWS' }; 'linux' { 'LINUX' }; 'darwin' { 'macOS' } }
$script:ExecutableSuffix = if ($script:Platform -eq 'windows') { '.exe' } else { '' }
$script:AndroidRoot = Join-Path (Get-AndroidToolsDirectory -ProjectRoot $script:ProjectRoot -Platform $script:Platform) 'platform-tools'
$script:Adb = Join-Path $script:AndroidRoot "adb$script:ExecutableSuffix"
$script:EdlVenv = Get-EdlVenvDirectory -ProjectRoot $script:ProjectRoot -Platform $script:Platform
$script:UseGlyphs = -not $Plain -and $PSVersionTable.PSVersion.Major -ge 7 -and $env:NOTEAIR5C_ASCII -ne '1'
$script:UseColor = -not $Plain -and [string]::IsNullOrEmpty($env:NO_COLOR)
$script:Width = 76
$script:Glyph = if ($script:UseGlyphs) {
    @{ H = '─'; TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'; V = '│'; Ok = '✓'; Warn = '!'; Fail = '×'; Active = '●'; Pending = '○'; Done = '◆'; Dot = '•'; Arrow = '❯' }
} else {
    @{ H = '-'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; V = '|'; Ok = 'OK'; Warn = '!'; Fail = 'X'; Active = '*'; Pending = 'o'; Done = '#'; Dot = '*'; Arrow = '>' }
}

function Write-Styled {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = 'Gray',
        [Nullable[ConsoleColor]]$BackgroundColor,
        [switch]$NoNewline
    )
    if ($script:UseColor -and $null -ne $BackgroundColor) {
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $BackgroundColor -NoNewline:$NoNewline
    } elseif ($script:UseColor) { Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
}

function Write-Rule {
    param([ConsoleColor]$Color = 'DarkGray')
    Write-Styled (('  ' + $script:Glyph.H * ($script:Width - 2))) $Color
}

function Write-BoxLine {
    param(
        [string]$Text = '',
        [ConsoleColor]$Color = 'Gray',
        [ConsoleColor]$BorderColor = 'DarkCyan'
    )
    $contentWidth = $script:Width - 6
    $segments = @()
    $remaining = $Text.TrimEnd()
    if (-not $remaining) { $segments = @('') }
    while ($remaining) {
        if ($remaining.Length -le $contentWidth) {
            $segments += $remaining
            break
        }
        $cut = $remaining.LastIndexOf(' ', $contentWidth)
        if ($cut -lt 1) { $cut = $contentWidth }
        $segments += $remaining.Substring(0, $cut).TrimEnd()
        $remaining = $remaining.Substring($cut).TrimStart()
    }
    foreach ($segment in $segments) {
        Write-Styled "  $($script:Glyph.V) " $BorderColor -NoNewline
        Write-Styled $segment $Color -NoNewline
        Write-Styled ((' ' * ($contentWidth - $segment.Length)) + " $($script:Glyph.V)") $BorderColor
    }
}

function Write-BoxRule {
    param([switch]$Top, [ConsoleColor]$Color = 'DarkCyan')
    $left = if ($Top) { $script:Glyph.TL } else { $script:Glyph.BL }
    $right = if ($Top) { $script:Glyph.TR } else { $script:Glyph.BR }
    Write-Styled ("  $left" + ($script:Glyph.H * ($script:Width - 4)) + $right) $Color
}

function Get-StepTrack {
    param([int]$Current, [int]$Total = 6)
    $parts = for ($step = 1; $step -le $Total; $step++) {
        if ($step -lt $Current) { $script:Glyph.Done }
        elseif ($step -eq $Current) { $script:Glyph.Active }
        else { $script:Glyph.Pending }
    }
    $parts -join (" $($script:Glyph.H)$($script:Glyph.H)$($script:Glyph.H) ")
}

function Write-Banner {
    param([string]$Subtitle = 'Guided root and recovery console')
    if (-not $NoClear) { Clear-Host }
    try { $Host.UI.RawUI.WindowTitle = 'BOOX Note Air 5C Root Assistant' } catch { }
    Write-Host ''
    Write-BoxRule -Top
    Write-BoxLine 'BOOX  /  NOTE AIR 5C' Cyan
    Write-BoxLine 'ROOT + RECOVERY ASSISTANT' White
    Write-BoxLine ''
    Write-BoxLine $Subtitle DarkCyan
    Write-BoxLine "$script:PlatformLabel  $($script:Glyph.Dot)  PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)  $($script:Glyph.Dot)  resumable + verified" DarkGray
    Write-BoxRule
}

function Write-Stage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Lines,
        [ConsoleColor]$Color = 'Cyan'
    )
    Write-Host ''
    Write-Styled ("  STEP {0:D2} / 06   {1}" -f $Number, $Title.ToUpperInvariant()) $Color
    Write-Styled ("  " + (Get-StepTrack -Current $Number)) DarkGray
    Write-BoxRule -Top -Color $Color
    foreach ($line in $Lines) { Write-BoxLine $line Gray $Color }
    Write-BoxRule -Color $Color
    Write-Host ''
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Styled "  [$($script:Glyph.Ok)]  $Message" Green
}

function Write-Notice {
    param([Parameter(Mandatory)][string]$Message)
    Write-Styled "  [$($script:Glyph.Warn)]  $Message" Yellow
}

function Write-Failure {
    param([Parameter(Mandatory)][string]$Message)
    Write-Styled "  [$($script:Glyph.Fail)]  $Message" Red
}

function Wait-ForEnter {
    param([string]$Prompt = 'Press Enter to continue')
    [void](Read-Host "  $Prompt")
}

function Confirm-ExactPhrase {
    param(
        [Parameter(Mandatory)][string]$Phrase,
        [Parameter(Mandatory)][string]$Prompt
    )
    Write-Notice $Prompt
    $answer = Read-Host "  Type $Phrase"
    if ($answer -cne $Phrase) { throw 'Confirmation did not match; nothing was changed.' }
}

function Test-Toolchain {
    $required = @(
        $script:Engine,
        $script:Adb,
        (Get-VenvPythonPath -VenvRoot $script:EdlVenv -Platform $script:Platform),
        (Join-Path $script:ProjectRoot '.tools/edl-src/edl.py'),
        (Join-Path $script:ProjectRoot '.cache/artifacts/Magisk-v30.7.apk'),
        (Join-Path $script:ProjectRoot '.cache/artifacts/0000000000000000_bdaf51b59ba21d8a_fhprg.bin')
    )
    -not (@($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count)
}

function Get-RunStates {
    if (-not (Test-Path -LiteralPath $script:RunsRoot -PathType Container)) { return @() }
    @(
        Get-ChildItem -LiteralPath $script:RunsRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                $statePath = Join-Path $_.FullName 'state.json'
                if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                    try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { }
                }
            }
    )
}

function Get-LatestRunState {
    @(Get-RunStates) | Select-Object -First 1
}

function Get-StageMeaning {
    param([string]$Stage)
    switch ($Stage) {
        'Diagnosed'           { 'diagnostic saved; backup not complete' }
        'BackupComplete'      { 'verified stock backup ready' }
        'BootPatched'         { 'Magisk image ready; no material write yet' }
        'RestoreGatePassed'   { 'EDL write path proven; unlock not yet applied' }
        'BootloaderUnlocked'  { 'unlock flags written and verified' }
        'PatchedBootFlashed'  { 'patched active boot written and verified' }
        'AwaitingAndroid'     { 'waiting for factory reset, Android setup, or Magisk setup' }
        'RootVerified'        { 'root completed and verified' }
        'StockRestored'       { 'stock boot and lock flags restored' }
        default               { 'unknown checkpoint' }
    }
}

function Get-AdbLine {
    param([string]$Serial)
    if (-not (Test-Path -LiteralPath $script:Adb -PathType Leaf)) { return $null }
    $lines = @(& $script:Adb devices -l 2>$null)
    if ($Serial) {
        return @($lines | Where-Object { $_ -match ('^' + [regex]::Escape($Serial) + '\s+') }) | Select-Object -First 1
    }
    @($lines | Where-Object { $_ -match '\b(product|model|device):NoteAir5C\b' }) | Select-Object -First 1
}

function Test-AdbAuthorized {
    param([string]$Serial)
    $line = Get-AdbLine -Serial $Serial
    [bool]($line -and $line -match '^\S+\s+device\b')
}

function Wait-AdbAuthorized {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Serial,
        [int]$TimeoutMinutes = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastStatus = $null
    do {
        $line = Get-AdbLine -Serial $Serial
        $status = if (-not $line) { 'waiting for USB device' } elseif ($line -match '\bunauthorized\b') { 'waiting for USB debugging approval' } elseif ($line -match '^\S+\s+device\b') { 'authorized' } else { $line.Trim() }
        if ($status -ne $lastStatus) {
            if ($status -eq 'authorized') { Write-Ok 'BOOX is visible and authorized through ADB.' } else { Write-Notice $status }
            $lastStatus = $status
        }
        if ($status -eq 'authorized') { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Timed out after $TimeoutMinutes minutes waiting for authorized ADB. Reconnect USB, enable BOOX USB Debug Mode, and approve this computer."
}

function Test-MagiskManagerInstalled {
    param([Parameter(Mandatory)][string]$Serial)
    if (-not (Test-AdbAuthorized -Serial $Serial)) { return $false }
    $result = (& $script:Adb -s $Serial shell pm path com.topjohnwu.magisk 2>$null | Out-String).Trim()
    $result -match '^package:'
}

function Invoke-Engine {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$RunPath,
        [switch]$AcknowledgeDataWipe,
        [switch]$NonInteractive,
        [switch]$InstallHostDependencies,
        [switch]$ForceEmergencyRestore,
        [ValidateSet('Balanced', 'Purge', 'Lockdown', 'Strict')][string]$PrivacyProfile = 'Balanced',
        [switch]$AcknowledgePrivacyChanges,
        [switch]$AcknowledgePrivacyRestore,
        [switch]$RebootDevice
    )
    $parameters = @{ Command = $Command }
    if ($RunPath) { $parameters.RunPath = $RunPath }
    if ($AcknowledgeDataWipe) { $parameters.AcknowledgeDataWipe = $true }
    if ($NonInteractive) { $parameters.NonInteractive = $true }
    if ($InstallHostDependencies) { $parameters.InstallHostDependencies = $true }
    if ($ForceEmergencyRestore) { $parameters.ForceEmergencyRestore = $true }
    if ($Command -eq 'PrivacyHarden') { $parameters.PrivacyProfile = $PrivacyProfile }
    if ($AcknowledgePrivacyChanges) { $parameters.AcknowledgePrivacyChanges = $true }
    if ($AcknowledgePrivacyRestore) { $parameters.AcknowledgePrivacyRestore = $true }
    if ($RebootDevice) { $parameters.RebootDevice = $true }
    if ($AcceptUntestedFirmware -and $Command -in @('Root', 'Resume', 'Backup')) { $parameters.AcceptUntestedFirmware = $true }
    & $script:Engine @parameters | Out-Host
}

function Invoke-SetupGuide {
    Write-Banner 'Toolchain setup'
    Write-Stage 1 'Install verified tools' @(
        "This installs pinned $script:PlatformLabel Android platform tools, EDL dependencies,",
        'Magisk 30.7, and the matching Qualcomm firehose loader.',
        $(if ($script:Platform -eq 'windows') { 'Internet access is required. Windows may request administrator approval.' }
          elseif ($script:Platform -eq 'linux') { 'Internet access is required. sudo may ask to install packages and the scoped USB rule.' }
          else { 'Internet access is required. Homebrew may ask to install Python, Git, libusb, and xz.' })
    )
    Invoke-Engine -Command Setup -InstallHostDependencies
    Write-Ok 'Toolchain setup finished.'
    if ($script:Platform -eq 'windows') {
        Write-Notice 'The first EDL connection may still require a one-time Zadig WinUSB binding.'
    } elseif ($script:Platform -eq 'linux') {
        Write-Notice 'Reconnect the USB cable so the new udev rule applies before the first EDL probe.'
    } else {
        Write-Notice 'Reconnect the USB cable if macOS does not expose Qualcomm 9008 on the first probe.'
    }
}

function Show-CurrentStatus {
    Write-Banner 'Current status'
    $toolState = if (Test-Toolchain) { 'ready' } else { 'setup required' }
    $state = Get-LatestRunState
    if ($state) {
        $line = Get-AdbLine -Serial ([string]$state.device.adbSerial)
    } else {
        $line = Get-AdbLine
    }
    Write-BoxRule -Top
    Write-BoxLine ("HOST       {0}" -f $script:PlatformLabel) DarkGray
    Write-BoxLine ("TOOLCHAIN  {0}" -f $toolState) $(if ($toolState -eq 'ready') { 'Green' } else { 'Yellow' })
    Write-BoxLine ("USB / ADB  {0}" -f $(if ($line) { $line.Trim() } else { 'Note Air 5C not visible' })) $(if ($line) { 'Green' } else { 'Yellow' })
    Write-BoxLine ''
    Write-BoxLine ("RUN        {0}" -f $(if ($state) { $state.id } else { 'none' }))
    if ($state) {
        Write-BoxLine ("CHECKPOINT {0}" -f $state.stage) Cyan
        Write-BoxLine ("MEANING    {0}" -f (Get-StageMeaning $state.stage)) DarkGray
        Write-BoxLine ("SLOT       {0}" -f $state.device.slot)
        Write-BoxLine ("FIRMWARE   {0}" -f $state.device.fingerprint) DarkGray
    }
    Write-BoxRule
}

function Show-FactoryResetGuide {
    Write-Stage 4 'Factory reset and initial setup' @(
        'The lock-state transition makes the old encrypted userdata unreadable.',
        'On the BOOX recovery screen choose: Factory data reset / Wipe data.',
        'Confirm Erase all user data, then choose Reboot system now if prompted.',
        'Complete only the minimum BOOX setup and DO NOT install a firmware update.',
        'At the desktop enable: Apps > menu > App Management > USB Debug Mode.',
        'Approve this computer and select Always allow.'
    ) -Color Yellow
}

function Show-MagiskSetupGuide {
    Write-Stage 5 'Finish Magisk setup' @(
        'Magisk Manager has been installed and opened.',
        'Tap OK on "Requires additional setup" and let the BOOX reboot.',
        'After the desktop returns, approve USB debugging again if requested.'
    ) -Color Yellow
}

function Invoke-LiveVerificationGuide {
    param([Parameter(Mandatory)][string]$RunPath)
    Write-Stage 6 'Verify real root' @(
        'The assistant will verify the exact fingerprint and slot, unlocked/orange',
        'boot state, Magisk 30.7, and an actual uid=0 root shell.'
    )
    try {
        Invoke-Engine -Command Verify -RunPath $RunPath -NonInteractive
    } catch {
        if ($_.Exception.Message -notmatch 'SharedUID|root-shell proof|Permission denied') { throw }
        Write-Notice 'Magisk has not granted superuser permission to ADB Shell yet.'
        Write-Host '    On the BOOX: Magisk > Superuser > enable [SharedUID] Shell.'
        Wait-ForEnter 'Press Enter after enabling the Shell entry'
        Invoke-Engine -Command Verify -RunPath $RunPath -NonInteractive
    }
    Write-Ok 'The BOOX reports a live uid=0 root shell.'
}

function Invoke-GuidedRoot {
    Write-Banner 'Guided root workflow'
    if (-not (Test-Toolchain)) {
        Write-Notice 'The pinned toolchain is not installed yet.'
        $install = Read-Host '  Install it now? [Y/n]'
        if ($install -match '^(n|no)$') { throw 'Toolchain setup was declined.' }
        Invoke-SetupGuide
        Write-Banner 'Guided root workflow'
    }

    $state = Get-LatestRunState
    if ($state -and $state.stage -eq 'RootVerified') {
        Write-Ok "The newest run is already RootVerified: $($state.id)"
        Invoke-LiveVerificationGuide -RunPath ([string]$state.runPath)
        return
    }
    if ($state -and $state.stage -eq 'StockRestored') {
        Write-Notice "The newest run is already StockRestored: $($state.id)"
        Write-Host '    A new root attempt will create a fresh run and backup.'
        $state = $null
    }

    Write-Stage 1 'Prepare the tablet' @(
        'Charge to at least 50% and keep the USB cable connected.',
        'Copy any local files you care about; rooting requires a factory reset.',
        'Enable BOOX USB Debug Mode and approve this computer.',
        'Do not begin or accept a BOOX firmware update during this workflow.'
    )

    if ($state) {
        Write-Notice "Resumable run found: $($state.id)"
        Write-Host "    Stage: $($state.stage) - $(Get-StageMeaning $state.stage)"
        $resume = Read-Host '  Continue this run? [Y/n]'
        if ($resume -match '^(n|no)$') { throw 'Existing run was not selected. Move it out of runs/ before deliberately starting a new run.' }
    } else {
        Wait-AdbAuthorized -Serial ''
        Write-Stage 2 'Read-only diagnostic' @(
            'The exact Note Air 5C model, firmware fingerprint, active slot,',
            'battery level, and verified-boot state will be collected first.'
        )
        Invoke-Engine -Command Diagnose -NonInteractive
    }

    $preWriteStages = @('Diagnosed', 'BackupComplete', 'BootPatched', 'RestoreGatePassed')
    if (-not $state -or $state.stage -in $preWriteStages) {
        Write-Stage 3 'Backup, patch, and verified flash' @(
            "The script will take a private EDL backup, patch this device's own",
            'active boot image, prove EDL write/readback, unlock two validated',
            'devinfo bytes, and flash only the recorded active boot partition.',
            'Every write is read back and hashed before reboot.'
        ) -Color Yellow
        Confirm-ExactPhrase -Phrase 'ERASE NOTEAIR5C' -Prompt 'The next phase will invalidate userdata and require a factory reset.'
    }

    if (-not $state) {
        Invoke-Engine -Command Root -AcknowledgeDataWipe -NonInteractive
    } elseif ($state.stage -ne 'AwaitingAndroid') {
        Invoke-Engine -Command Resume -RunPath ([string]$state.runPath) -AcknowledgeDataWipe -NonInteractive
    }
    $state = Get-LatestRunState
    if (-not $state) { throw 'The root engine returned without creating a run state.' }

    if ($state.stage -eq 'AwaitingAndroid') {
        $serial = [string]$state.device.adbSerial
        if (-not (Test-AdbAuthorized -Serial $serial)) {
            Show-FactoryResetGuide
            Wait-ForEnter 'Press Enter after the BOOX desktop is visible and USB debugging is approved'
            Wait-AdbAuthorized -Serial $serial
        }

        $managerInstalled = Test-MagiskManagerInstalled -Serial $serial
        if (-not $managerInstalled) {
            Invoke-Engine -Command Resume -RunPath ([string]$state.runPath) -AcknowledgeDataWipe -NonInteractive
            $state = Get-LatestRunState
        }
        if ($state.stage -eq 'AwaitingAndroid') {
            Show-MagiskSetupGuide
            Wait-ForEnter 'Press Enter after Magisk has rebooted and the BOOX desktop is back'
            Wait-AdbAuthorized -Serial $serial
            Invoke-Engine -Command Resume -RunPath ([string]$state.runPath) -AcknowledgeDataWipe -NonInteractive
            $state = Get-LatestRunState
        }
    }

    if ($state.stage -ne 'RootVerified') {
        throw "The run stopped safely at '$($state.stage)'. Read the message above, correct the condition, then choose Start / continue root again."
    }
    Invoke-LiveVerificationGuide -RunPath ([string]$state.runPath)
    Write-Rule Green
    Write-Styled '  ROOT COMPLETE' Green
    Write-Styled "  Recovery material: $($state.runPath)" Gray
    Write-Styled '  Restore stock before accepting a BOOX firmware update.' Yellow
    Write-Rule Green
}

function Invoke-GuidedRestore {
    Write-Banner 'Return fully to stock'
    $state = Get-LatestRunState
    if (-not $state) { throw 'No run state is available for restore.' }
    Write-Stage 1 'Review recovery target' @(
        "Run: $($state.id)",
        "Firmware: $($state.device.fingerprint)",
        "Recorded active slot: $($state.device.slot)",
        'Any active privacy firewall, debloat, and home-layout changes are restored first.',
        'The original stock boot is then written and the verified-boot flags are relocked.',
        'Relocking invalidates userdata encryption and requires another factory reset.'
    ) -Color Yellow
    Confirm-ExactPhrase -Phrase 'RETURN FULLY STOCK' -Prompt 'This restores recorded privacy state, writes verified stock boot, relocks the tablet, and erases userdata.'
    $serial = [string]$state.device.adbSerial
    $adbLine = Get-AdbLine -Serial $serial
    if ($adbLine -and $adbLine -match '\bunauthorized\b') {
        Write-Notice 'The BOOX is connected but this computer is not authorized.'
        Write-Host '    Unlock the tablet and approve the USB debugging dialog.'
        Wait-AdbAuthorized -Serial $serial
    }
    $emergency = -not (Test-AdbAuthorized -Serial $serial)
    if ($emergency) {
        Confirm-ExactPhrase -Phrase 'EMERGENCY RESTORE' -Prompt 'Android is unavailable, so firmware and active slot cannot be checked. Use this only when the tablet is already in EDL and this is the matching run.'
    }
    Invoke-Engine -Command ReturnStock -RunPath ([string]$state.runPath) -AcknowledgePrivacyRestore -AcknowledgeDataWipe -NonInteractive -ForceEmergencyRestore:$emergency
    Write-Ok 'Privacy recovery, stock boot restore, and relock completed successfully.'
    Write-Notice 'If Android Recovery says it cannot load Android, choose Factory data reset. This is expected after relocking.'
}

function Show-Demo {
    Write-Banner 'Interface preview - no commands will run'
    Write-Stage 1 'Prepare the tablet' @(
        'Charge to at least 50% and connect a USB data cable.',
        'Back up personal files and enable BOOX USB Debug Mode.'
    )
    Write-Ok 'BOOX Note Air 5C detected and authorized.'
    Write-Stage 2 'Read-only diagnostic' @('Firmware and active slot are checked against the allow-list.')
    Write-Stage 3 'Backup, patch, and verified flash' @(
        'A full private EDL backup is hashed before any material write.',
        'Each partition write is immediately read back and compared.'
    ) -Color Yellow
    Show-FactoryResetGuide
    Show-MagiskSetupGuide
    Write-Stage 6 'Verify real root' @('Expected result: uid=0(root), Magisk 30.7, verified state orange.')
    Write-Rule Green
    Write-Styled '  DEMO COMPLETE - the device was not accessed.' Green
    Write-Rule Green
}

function Get-PrivacyMenuItems {
    @(
        [pscustomobject]@{ Choice = '1'; Title = 'READ-ONLY PRIVACY AUDIT'; Description = 'Inventory packages, UIDs, settings, Magisk, hosts, and firewall state.'; Color = [ConsoleColor]::Cyan }
        [pscustomobject]@{ Choice = '2'; Title = 'APPLY BALANCED  (RECOMMENDED)'; Description = 'Block BOOX endpoints and remove cloud/commercial extras; keep core apps and LAN transfer.'; Color = [ConsoleColor]::Green }
        [pscustomobject]@{ Choice = '3'; Title = 'SYSTEMLESS PURGE'; Description = 'Balanced plus fully hide five optional system APKs; reversible and OTA-safe.'; Color = [ConsoleColor]::Magenta }
        [pscustomobject]@{ Choice = '4'; Title = 'VENDOR LOCKDOWN  (COMPATIBLE)'; Description = 'Purge cloud sync and deny dedicated BOOX app UIDs without blocking Android services.'; Color = [ConsoleColor]::Red }
        [pscustomobject]@{ Choice = '5'; Title = 'APPLY STRICT'; Description = 'Balanced plus cloud sync, transfer, mail, and replaceable stock utilities.'; Color = [ConsoleColor]::Yellow }
        [pscustomobject]@{ Choice = '6'; Title = 'APPLY CLEAN HOME LAYOUT'; Description = 'Tools folder; only Play Store + Magisk on desktop; Storage + Settings in dock.'; Color = [ConsoleColor]::Blue }
        [pscustomobject]@{ Choice = '7'; Title = 'RESTORE PREVIOUS STATE'; Description = 'Remove the firewall and restore recorded package, settings, and launcher layout.'; Color = [ConsoleColor]::Cyan }
        [pscustomobject]@{ Choice = 'b'; Title = 'BACK'; Description = 'Return to the main assistant menu.'; Color = [ConsoleColor]::DarkGray }
    )
}

function Show-PrivacyMenuPage {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [int]$SelectedIndex = 0,
        [switch]$TypedFallback
    )
    Write-Banner 'Privacy firewall + reversible debloat'
    Write-BoxRule -Top -Color Magenta
    Write-BoxLine 'SYSTEMLESS  Known BOOX hosts + bootstrap IP; IPv4 and IPv6 app rules.' Magenta Magenta
    Write-BoxLine 'REVERSIBLE  Every setting and package state is recorded before changes.' Green Magenta
    Write-BoxLine 'PROTECTED   Reader, notes, keyboards, OTA, launcher, and calibration.' Cyan Magenta
    Write-BoxLine 'REBOOT      Apply and restore reboot once to switch the Magisk hosts overlay.' DarkGray Magenta
    Write-BoxRule -Color Magenta
    Write-Host ''
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $item = $Items[$index]
        $selected = $index -eq $SelectedIndex
        $marker = if ($selected) { $script:Glyph.Arrow } else { ' ' }
        $title = ("  {0}  [{1}]  {2}" -f $marker, $item.Choice.ToUpperInvariant(), $item.Title).PadRight($script:Width)
        if ($selected) {
            Write-Styled $title White -BackgroundColor DarkMagenta
            Write-Styled ("       $($item.Description)") Magenta
        } else {
            Write-Styled $title $item.Color
            Write-Styled ("       $($item.Description)") DarkGray
        }
    }
    Write-Rule
    if ($TypedFallback) {
        Write-Styled '  Type 1-7 or B, then press Enter.' DarkGray
    } else {
        Write-Styled "  $([char]0x2191) $([char]0x2193) move   $($script:Glyph.Dot)   Enter select   $($script:Glyph.Dot)   1-7 shortcut   $($script:Glyph.Dot)   Esc back" DarkGray
    }
    Write-Host ''
}

function Read-PrivacyMenuChoice {
    $items = @(Get-PrivacyMenuItems)
    if ($script:PrivacyMenuIndex -ge $items.Count) { $script:PrivacyMenuIndex = 0 }
    if (-not (Test-ArrowMenuAvailable)) {
        Show-PrivacyMenuPage -Items $items -SelectedIndex $script:PrivacyMenuIndex -TypedFallback
        $answer = Read-Host '  Choose a privacy action'
        if ($null -eq $answer) { return 'b' }
        return $answer.Trim().ToLowerInvariant()
    }
    while ($true) {
        Show-PrivacyMenuPage -Items $items -SelectedIndex $script:PrivacyMenuIndex
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            { $_ -in @([ConsoleKey]::UpArrow, [ConsoleKey]::LeftArrow) } { $script:PrivacyMenuIndex = ($script:PrivacyMenuIndex - 1 + $items.Count) % $items.Count; continue }
            { $_ -in @([ConsoleKey]::DownArrow, [ConsoleKey]::RightArrow, [ConsoleKey]::Tab) } { $script:PrivacyMenuIndex = ($script:PrivacyMenuIndex + 1) % $items.Count; continue }
            ([ConsoleKey]::Home) { $script:PrivacyMenuIndex = 0; continue }
            ([ConsoleKey]::End) { $script:PrivacyMenuIndex = $items.Count - 1; continue }
            ([ConsoleKey]::Enter) { return [string]$items[$script:PrivacyMenuIndex].Choice }
            ([ConsoleKey]::Escape) { return 'b' }
        }
        $shortcut = ([string]$key.KeyChar).ToLowerInvariant()
        if ($shortcut -match '^[1-7b]$') { return $shortcut }
    }
}

function Invoke-PrivacyGuide {
    $script:PrivacyMenuIndex = 0
    while ($true) {
        $choice = Read-PrivacyMenuChoice
        try {
            switch ($choice) {
                '1' {
                    Write-Banner 'Read-only BOOX privacy audit'
                    Invoke-Engine -Command PrivacyAudit -NonInteractive
                }
                '2' {
                    Write-Banner 'Apply balanced privacy profile'
                    Write-Stage 1 'Review balanced changes' @(
                        'Block documented BOOX/Onyx endpoints and the cleartext bootstrap IP.',
                        'Use a Magisk hosts overlay plus scoped IPv4/IPv6 application rules.',
                        'User-uninstall iGet Shop, cloud AI, BOOX App Market, factory test,',
                        'and the vendor Chromium 111 browser. EasyTransfer remains LAN-only.',
                        'Reader, notes, keyboards, OTA, launcher, and calibration are kept.'
                    ) -Color Magenta
                    Confirm-ExactPhrase -Phrase 'HARDEN NOTEAIR5C' -Prompt 'The exact current package/settings state will be recorded, then the BOOX will reboot once.'
                    Invoke-Engine -Command PrivacyHarden -PrivacyProfile Balanced -AcknowledgePrivacyChanges -RebootDevice -NonInteractive
                }
                '3' {
                    Write-Banner 'Apply systemless privacy purge'
                    Write-Stage 1 'Review reversible purge' @(
                        'Includes every balanced firewall and package change.',
                        'Magisk hides the APK directories for iGet Shop, cloud AI,',
                        'BOOX App Market, factory production test, and Chromium 111.',
                        'The stock files remain underneath for recovery and OTA safety.',
                        'Reader, notes, keyboards, OTA, launcher, and calibration stay.',
                        'The current launcher is backed up and the clean home layout applied.'
                    ) -Color Magenta
                    Confirm-ExactPhrase -Phrase 'HARDEN NOTEAIR5C' -Prompt 'Purge mode records exact state and reboots once; restore also requires one reboot.'
                    Invoke-Engine -Command PrivacyHarden -PrivacyProfile Purge -AcknowledgePrivacyChanges -RebootDevice -NonInteractive
                }
                '4' {
                    Write-Banner 'Apply BOOX vendor lockdown'
                    Write-Stage 1 'Review compatible lockdown changes' @(
                        'Includes Purge and also systemlessly removes BOOX cloud sync.',
                        'Kernel firewall denies WAN to dedicated com.onyx application UIDs.',
                        'Shared Android/system UIDs are excluded so core networking works.',
                        'Google sign-in, DNS, and third-party apps retain normal internet.',
                        'BOOX Cloud, sync, online OTA, and BOOX-app internet will not work.',
                        'The current launcher is backed up and the clean home layout applied.'
                    ) -Color Red
                    Confirm-ExactPhrase -Phrase 'HARDEN NOTEAIR5C' -Prompt 'Vendor Lockdown records exact state and requires Restore before a BOOX OTA.'
                    Invoke-Engine -Command PrivacyHarden -PrivacyProfile Lockdown -AcknowledgePrivacyChanges -RebootDevice -NonInteractive
                }
                '5' {
                    Write-Banner 'Apply strict privacy profile'
                    Write-Stage 1 'Review strict changes' @(
                        'Includes every balanced firewall and package change.',
                        'Also disables BOOX cloud sync and removes EasyTransfer, mail,',
                        'voice recorder, music, gallery, calculator, clock, and dictionary.',
                        'Install preferred replacement applications before choosing strict.',
                        'Core reader, notes, both keyboards, OTA, and launcher remain.'
                    ) -Color Yellow
                    Confirm-ExactPhrase -Phrase 'HARDEN NOTEAIR5C' -Prompt 'Strict mode removes more user-facing apps, records their state, and reboots once.'
                    Invoke-Engine -Command PrivacyHarden -PrivacyProfile Strict -AcknowledgePrivacyChanges -RebootDevice -NonInteractive
                }
                '6' {
                    Write-Banner 'Apply clean BOOX home layout'
                    Write-Stage 1 'Normalize launcher layout' @(
                        'Back up the exact current BOOX launcher database and verify it.',
                        'Collect all BOOX app shortcuts into a single Tools folder.',
                        'Keep only Play Store and Magisk as desktop app icons.',
                        'Keep only Storage and Settings in the bottom dock.',
                        'Preserve the Library and Notes widgets.'
                    ) -Color Blue
                    Confirm-ExactPhrase -Phrase 'CLEAN HOME NOTEAIR5C' -Prompt 'Unknown launcher versions or database schemas are refused automatically.'
                    Invoke-Engine -Command PrivacyHome -AcknowledgePrivacyChanges -NonInteractive
                }
                '7' {
                    Write-Banner 'Restore privacy hardening'
                    Write-Stage 1 'Restore recorded state' @(
                        'Remove the BOOX Privacy Magisk module and live firewall chain.',
                        'Reinstall or re-enable packages exactly as recorded before apply.',
                        'Restore the previous NTP and captive-portal settings, then reboot.'
                    ) -Color Magenta
                    Confirm-ExactPhrase -Phrase 'RESTORE PRIVACY' -Prompt 'Only the newest applied privacy record matching this serial and firmware will be used.'
                    Invoke-Engine -Command PrivacyRestore -AcknowledgePrivacyRestore -RebootDevice -NonInteractive
                }
                { $_ -in @('b', 'back', 'q') } { return }
                default { Write-Notice 'Choose 1-7 or B.'; Start-Sleep -Seconds 1; continue }
            }
        } catch {
            Write-Host ''
            Write-Failure $_.Exception.Message
        }
        Wait-ForEnter 'Press Enter to return to Privacy Hardening'
    }
}

function Get-MenuItems {
    @(
        [pscustomobject]@{ Choice = '1'; Title = 'START / CONTINUE ROOT'; Description = 'Guided backup, patch, unlock, flash, reset, and verification.'; Color = [ConsoleColor]::Cyan }
        [pscustomobject]@{ Choice = '2'; Title = 'VERIFY ROOT'; Description = 'Prove fingerprint, slot, boot state, Magisk, and uid=0.'; Color = [ConsoleColor]::White }
        [pscustomobject]@{ Choice = '3'; Title = 'STATUS'; Description = 'Inspect USB, tools, latest run, and resumable checkpoint.'; Color = [ConsoleColor]::White }
        [pscustomobject]@{ Choice = '4'; Title = 'SETUP / REPAIR TOOLS'; Description = "Install verified downloads and $script:PlatformLabel host dependencies."; Color = [ConsoleColor]::White }
        [pscustomobject]@{ Choice = '5'; Title = 'RETURN FULLY TO STOCK'; Description = 'Undo privacy changes, restore stock boot, relock, and reset userdata.'; Color = [ConsoleColor]::Yellow }
        [pscustomobject]@{ Choice = '6'; Title = 'SAFE UI PREVIEW'; Description = 'Walk every screen without touching the tablet.'; Color = [ConsoleColor]::White }
        [pscustomobject]@{ Choice = '7'; Title = 'PRIVACY HARDENING'; Description = 'Audit, firewall, debloat, or restore BOOX network privacy.'; Color = [ConsoleColor]::Magenta }
        [pscustomobject]@{ Choice = 'q'; Title = 'QUIT'; Description = 'Close the assistant without changing the tablet.'; Color = [ConsoleColor]::DarkGray }
    )
}

function Test-ArrowMenuAvailable {
    if ($NoClear) { return $false }
    try {
        -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    } catch {
        $false
    }
}

function Show-MenuPage {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [int]$SelectedIndex = 0,
        [switch]$TypedFallback
    )
    Write-Banner 'Use the arrow keys to choose an action'
    $state = Get-LatestRunState
    $ready = Test-Toolchain
    Write-BoxRule -Top -Color DarkGray
    Write-BoxLine ("TOOLCHAIN  {0}" -f $(if ($ready) { "$($script:Glyph.Ok) READY" } else { "$($script:Glyph.Warn) SETUP REQUIRED" })) $(if ($ready) { 'Green' } else { 'Yellow' }) DarkGray
    Write-BoxLine ("LATEST RUN {0}" -f $(if ($state) { $state.id } else { 'none yet' })) Gray DarkGray
    Write-BoxLine ("CHECKPOINT {0}" -f $(if ($state) { "$($state.stage)  $($script:Glyph.Dot)  $(Get-StageMeaning $state.stage)" } else { 'ready for a new diagnostic' })) Cyan DarkGray
    Write-BoxRule -Color DarkGray
    Write-Host ''

    for ($index = 0; $index -lt $Items.Count; $index++) {
        $item = $Items[$index]
        $selected = $index -eq $SelectedIndex
        $marker = if ($selected) { $script:Glyph.Arrow } else { ' ' }
        $title = ("  {0}  [{1}]  {2}" -f $marker, $item.Choice.ToUpperInvariant(), $item.Title).PadRight($script:Width)
        if ($selected) {
            Write-Styled $title White -BackgroundColor DarkCyan
            Write-Styled ("       $($item.Description)") Cyan
        } else {
            Write-Styled $title $item.Color
            Write-Styled ("       $($item.Description)") DarkGray
        }
    }

    Write-Rule
    if ($TypedFallback) {
        Write-Styled '  Type 1-7 or Q, then press Enter.' DarkGray
    } else {
        Write-Styled "  $([char]0x2191) $([char]0x2193) move   $($script:Glyph.Dot)   Enter select   $($script:Glyph.Dot)   1-7 shortcut   $($script:Glyph.Dot)   Esc quit" DarkGray
    }
    Write-Host ''
}

function Read-MenuChoice {
    $items = @(Get-MenuItems)
    if ($script:MenuIndex -ge $items.Count) { $script:MenuIndex = 0 }
    if (-not (Test-ArrowMenuAvailable)) {
        Show-MenuPage -Items $items -SelectedIndex $script:MenuIndex -TypedFallback
        $answer = Read-Host '  Choose an action'
        if ($null -eq $answer) { return 'q' }
        return $answer.Trim().ToLowerInvariant()
    }

    while ($true) {
        Show-MenuPage -Items $items -SelectedIndex $script:MenuIndex
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            { $_ -in @([ConsoleKey]::UpArrow, [ConsoleKey]::LeftArrow) } {
                $script:MenuIndex = ($script:MenuIndex - 1 + $items.Count) % $items.Count
                continue
            }
            { $_ -in @([ConsoleKey]::DownArrow, [ConsoleKey]::RightArrow, [ConsoleKey]::Tab) } {
                $script:MenuIndex = ($script:MenuIndex + 1) % $items.Count
                continue
            }
            ([ConsoleKey]::Home) { $script:MenuIndex = 0; continue }
            ([ConsoleKey]::End) { $script:MenuIndex = $items.Count - 1; continue }
            ([ConsoleKey]::Enter) { return [string]$items[$script:MenuIndex].Choice }
            ([ConsoleKey]::Escape) { return 'q' }
        }
        $shortcut = ([string]$key.KeyChar).ToLowerInvariant()
        if ($shortcut -match '^[1-7q]$') { return $shortcut }
    }
}

function Show-Menu {
    $script:MenuIndex = 0
    while ($true) {
        $choice = Read-MenuChoice
        try {
            switch ($choice) {
                '1' { Invoke-GuidedRoot }
                '2' {
                    $run = Get-LatestRunState
                    if (-not $run) { throw 'No run exists to verify.' }
                    Write-Banner 'Live root verification'
                    Invoke-LiveVerificationGuide -RunPath ([string]$run.runPath)
                }
                '3' { Show-CurrentStatus }
                '4' { Invoke-SetupGuide }
                '5' { Invoke-GuidedRestore }
                '6' { Show-Demo }
                '7' { Invoke-PrivacyGuide }
                { $_ -in @('q', 'quit', 'exit') } { return }
                default { Write-Notice 'Choose 1-7 or Q.'; Start-Sleep -Seconds 1; continue }
            }
        } catch {
            Write-Host ''
            Write-Failure $_.Exception.Message
        }
        Wait-ForEnter 'Press Enter to return to the menu'
    }
}

if (-not (Test-Path -LiteralPath $script:Engine -PathType Leaf)) {
    throw "Root engine is missing: $script:Engine"
}

switch ($Action) {
    'Menu'    { Show-Menu }
    'Root'    { Invoke-GuidedRoot }
    'Verify'  {
        $run = Get-LatestRunState
        if (-not $run) { throw 'No run exists to verify.' }
        Write-Banner 'Live root verification'
        Invoke-LiveVerificationGuide -RunPath ([string]$run.runPath)
    }
    'Status'  { Show-CurrentStatus }
    'Setup'   { Invoke-SetupGuide }
    'Restore' { Invoke-GuidedRestore }
    'Privacy' { Invoke-PrivacyGuide }
    'Demo'    { Show-Demo }
}
