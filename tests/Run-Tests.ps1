$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src/NoteAir5C.Root.psm1') -Force
Import-Module (Join-Path $projectRoot 'src/NoteAir5C.Privacy.psm1') -Force

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "PASS $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "FAIL $Name" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    try {
        & $Action
        Assert-True $false $Name
    } catch {
        Assert-True $true $Name
    }
}

Assert-True (Test-NoteAir5CModel -Model 'NoteAir5C' -Device 'NoteAir5C') 'accept exact model'
Assert-True (-not (Test-NoteAir5CModel -Model 'Palma2_Pro_C' -Device 'Palma2_Pro_C')) 'reject adjacent BOOX model'
Assert-True ((ConvertTo-SafeSlot '_B') -eq 'b') 'normalize slot suffix'
Assert-Throws { ConvertTo-SafeSlot 'c' } 'reject unsafe slot'

$gpt = "Partition abl_a`nPartition boot_a`nPartition boot_b`nPartition devinfo"
$gate = Test-GptPartitions -GptText $gpt -Partitions @('abl_a', 'boot_a', 'boot_b', 'devinfo')
Assert-True $gate.Passed 'GPT required partition gate'
$missing = Test-GptPartitions -GptText $gpt -Partitions @('abl_a', 'vbmeta_a')
Assert-True (-not $missing.Passed -and $missing.Missing[0] -eq 'vbmeta_a') 'GPT reports missing partition'

$fingerprint = 'Onyx/NoteAir5C/NoteAir5C:11/2026-04-02_19-54_4.2-rel_0402_75ba17df0/2413:user/release-keys'
$profile = Find-FirmwareProfile -ProjectRoot $projectRoot -Model 'NoteAir5C' -Fingerprint $fingerprint
Assert-True ($profile.id -eq 'noteair5c-4.2-rel-0402' -and $profile.rootEnabled) 'match confirmed 4.2 firmware profile'
$validatedFingerprint = 'Onyx/NoteAir5C/NoteAir5C:11/2026-07-02_19-03_4.2.1-rel_0702_038ed12af/3055:user/release-keys'
$validatedProfile = Find-FirmwareProfile -ProjectRoot $projectRoot -Model 'NoteAir5C' -Fingerprint $validatedFingerprint
Assert-True ($validatedProfile.id -eq 'noteair5c-4.2.1-rel-0702' -and $validatedProfile.status -eq 'device-validated' -and $validatedProfile.rootEnabled) 'match device-validated 4.2.1 firmware profile'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('noteair5c-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $source = Join-Path $tempRoot 'devinfo.bin'
    $patched = Join-Path $tempRoot 'devinfo-patched.bin'
    $bytes = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('ANDROID-BOOT!').CopyTo($bytes, 0)
    $bytes[13] = 0
    $bytes[14] = 0
    $bytes[15] = 1
    [IO.File]::WriteAllBytes($source, $bytes)
    $result = New-PatchedDevinfo -Source $source -Destination $patched
    $actual = [IO.File]::ReadAllBytes($patched)
    Assert-True ($result.DifferenceCount -eq 2 -and $actual[13] -eq 1 -and $actual[14] -eq 1) 'devinfo changes exactly the two unlock bytes'
    Assert-True ($actual[15] -eq 1 -and $actual.Length -eq 4096) 'devinfo preserves sanity byte and size'

    $compatBackup = Join-Path $tempRoot 'devinfo-compat-backup.bin'
    $compatCurrent = Join-Path $tempRoot 'devinfo-compat-current.bin'
    $backupCompatBytes = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('ANDROID-BOOT!').CopyTo($backupCompatBytes, 0)
    $backupCompatBytes[15] = 1
    [BitConverter]::GetBytes([uint32]([DateTimeOffset]::Parse('2026-04-01T00:00:00Z').ToUnixTimeSeconds())).CopyTo($backupCompatBytes, 0x8A8)
    $currentCompatBytes = [byte[]]$backupCompatBytes.Clone()
    [BitConverter]::GetBytes([uint32]([DateTimeOffset]::Parse('2026-06-01T00:00:00Z').ToUnixTimeSeconds())).CopyTo($currentCompatBytes, 0x8A8)
    [IO.File]::WriteAllBytes($compatBackup, $backupCompatBytes)
    [IO.File]::WriteAllBytes($compatCurrent, $currentCompatBytes)
    $compatibility = Test-DevinfoRuntimeCompatibility -Backup $compatBackup -Current $compatCurrent
    Assert-True ($compatibility.RuntimeFieldChanged -and $compatibility.CurrentRuntimeDateUtc -eq '2026-06-01') 'devinfo accepts only monotonic month-aligned runtime date'

    $currentCompatBytes[13] = 1
    $currentCompatBytes[14] = 1
    [IO.File]::WriteAllBytes($compatCurrent, $currentCompatBytes)
    $unlockCompatibility = Test-DevinfoRuntimeCompatibility -Backup $compatBackup -Current $compatCurrent -AllowUnlockFlagDifferences
    $relocked = Join-Path $tempRoot 'devinfo-relocked.bin'
    $lockResult = New-LockedDevinfo -Source $compatCurrent -Destination $relocked
    $relockedBytes = [IO.File]::ReadAllBytes($relocked)
    Assert-True ($unlockCompatibility.RuntimeFieldChanged -and $lockResult.DifferenceCount -eq 2 -and $relockedBytes[13] -eq 0 -and $relockedBytes[14] -eq 0) 'stock restore relocks only both devinfo flags'
    Assert-True ([BitConverter]::ToUInt32($relockedBytes, 0x8A8) -eq [BitConverter]::ToUInt32($currentCompatBytes, 0x8A8)) 'stock restore preserves current runtime date'
    $currentCompatBytes[14] = 0
    [IO.File]::WriteAllBytes($compatCurrent, $currentCompatBytes)
    Assert-Throws { New-LockedDevinfo -Source $compatCurrent -Destination (Join-Path $tempRoot 'never-relocked.bin') } 'stock restore rejects split devinfo flags'
    $currentCompatBytes[13] = 0

    $currentCompatBytes[100] = 1
    [IO.File]::WriteAllBytes($compatCurrent, $currentCompatBytes)
    Assert-Throws { Test-DevinfoRuntimeCompatibility -Backup $compatBackup -Current $compatCurrent } 'devinfo rejects unexpected runtime byte changes'
    $currentCompatBytes[100] = 0
    [BitConverter]::GetBytes([uint32]([DateTimeOffset]::Parse('2026-03-01T00:00:00Z').ToUnixTimeSeconds())).CopyTo($currentCompatBytes, 0x8A8)
    [IO.File]::WriteAllBytes($compatCurrent, $currentCompatBytes)
    Assert-Throws { Test-DevinfoRuntimeCompatibility -Backup $compatBackup -Current $compatCurrent } 'devinfo rejects rollback date downgrade'

    $bad = Join-Path $tempRoot 'bad-devinfo.bin'
    $bytes[0] = 0
    [IO.File]::WriteAllBytes($bad, $bytes)
    Assert-Throws { New-PatchedDevinfo -Source $bad -Destination (Join-Path $tempRoot 'never.bin') } 'devinfo rejects unknown magic'

    $abc = Join-Path $tempRoot 'abc.bin'
    [IO.File]::WriteAllBytes($abc, [Text.Encoding]::ASCII.GetBytes('abcdef'))
    Assert-True ((Get-PrefixSha256 -Path $abc -Bytes 3) -eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') 'prefix SHA-256 is deterministic'

    $stockHash = 'a' * 64
    $patchedHash = 'b' * 64
    Assert-True (Test-KnownRestoreBootHash -Current $stockHash -Stock $stockHash -Patched $patchedHash) 'restore accepts recorded stock boot hash'
    Assert-True (Test-KnownRestoreBootHash -Current $patchedHash.ToUpperInvariant() -Stock $stockHash -Patched $patchedHash) 'restore accepts recorded patched boot hash case-insensitively'
    Assert-True (-not (Test-KnownRestoreBootHash -Current ('c' * 64) -Stock $stockHash -Patched $patchedHash)) 'restore rejects unknown boot hash'
} finally {
    Get-ChildItem -LiteralPath $tempRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Remove-Item -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue
}

$artifactConfig = Get-Content -LiteralPath (Join-Path $projectRoot 'config/artifacts.json') -Raw | ConvertFrom-Json
$ids = @($artifactConfig.artifacts.id)
Assert-True (($ids | Select-Object -Unique).Count -eq $ids.Count) 'artifact IDs are unique'
foreach ($artifact in $artifactConfig.artifacts) {
    Assert-True ($artifact.sha256 -match '^[0-9a-f]{64}$') "artifact hash format: $($artifact.id)"
    Assert-True ([int64]$artifact.bytes -gt 0) "artifact size present: $($artifact.id)"
}

$savedPlatformOverride = $env:NOTEAIR5C_PLATFORM_OVERRIDE
try {
    foreach ($platform in @('windows', 'linux', 'darwin')) {
        $env:NOTEAIR5C_PLATFORM_OVERRIDE = $platform
        Assert-True ((Get-HostPlatform) -eq $platform) "platform override: $platform"
    }
    $env:NOTEAIR5C_PLATFORM_OVERRIDE = 'invalid'
    Assert-Throws { Get-HostPlatform } 'reject invalid platform override'
} finally {
    $env:NOTEAIR5C_PLATFORM_OVERRIDE = $savedPlatformOverride
}
Assert-True ((Get-AndroidArtifactId -Platform windows) -eq 'android-platform-tools') 'select Windows platform tools artifact'
Assert-True ((Get-AndroidArtifactId -Platform linux) -eq 'android-platform-tools-linux') 'select Linux platform tools artifact'
Assert-True ((Get-AndroidArtifactId -Platform darwin) -eq 'android-platform-tools-darwin') 'select macOS platform tools artifact'
Assert-True ((Split-Path -Leaf (Get-AndroidToolsDirectory -ProjectRoot $projectRoot -Platform linux)) -eq 'android-37.0.1-linux') 'isolate Linux Android tools directory'
Assert-True ((Split-Path -Leaf (Get-AndroidToolsDirectory -ProjectRoot $projectRoot -Platform darwin)) -eq 'android-37.0.1-darwin') 'isolate macOS Android tools directory'
Assert-True ((Split-Path -Leaf (Get-EdlVenvDirectory -ProjectRoot $projectRoot -Platform linux)) -eq 'edl-venv-linux') 'isolate Linux EDL environment'
Assert-True ((Get-VenvPythonPath -VenvRoot '/tmp/edl' -Platform linux) -match 'bin.python$') 'select Unix venv interpreter layout'
Assert-True ((ConvertFrom-PortablePath 'backup/boot_b.bin') -eq (Join-Path 'backup' 'boot_b.bin')) 'convert portable manifest path for host'

Assert-True (Test-PrivacyPolicy -ProjectRoot $projectRoot) 'privacy policy validates protected packages and identifiers'
$privacyPolicy = Get-PrivacyPolicy -ProjectRoot $projectRoot
$privacyHosts = Get-Content -LiteralPath (Join-Path $projectRoot 'privacy/magisk-module/system/etc/hosts')
$missingIpv4Hosts = @($privacyPolicy.blockedHosts | Where-Object { $hostName = $_; @($privacyHosts | Where-Object { $_ -eq "0.0.0.0 $hostName" }).Count -ne 1 })
$missingIpv6Hosts = @($privacyPolicy.blockedHosts | Where-Object { $hostName = $_; @($privacyHosts | Where-Object { $_ -eq ":: $hostName" }).Count -ne 1 })
Assert-True ($missingIpv4Hosts.Count -eq 0) 'privacy hosts includes every policy hostname for IPv4'
Assert-True ($missingIpv6Hosts.Count -eq 0) 'privacy hosts includes every policy hostname for IPv6'
$serviceScript = Get-Content -LiteralPath (Join-Path $projectRoot 'privacy/magisk-module/service.sh') -Raw
Assert-True ($serviceScript -match 'BOOX_PRIVACY' -and $serviceScript -match '119\.23\.143\.188' -and $serviceScript -match '\-lt 10000') 'privacy firewall has isolated chain, bootstrap block, and system-UID guard'
Assert-True ($serviceScript -match '192\.168\.0\.0/16' -and $serviceScript -match 'fc00::/7' -and $serviceScript -match 'com\.onyx\.easytransfer') 'privacy firewall preserves local EasyTransfer on IPv4 and IPv6'
Assert-True ($serviceScript -match 'sys\.boot_completed' -and $serviceScript -match 'sleep 30' -and $serviceScript -match 'time\.cloudflare\.com') 'privacy service waits for BOOX startup and reapplies connectivity settings'
Assert-True ($serviceScript -match 'uid_for com\.onyx\)' -and $serviceScript -notmatch 'uid_for com\.onyx\.easytransfer\)" \]') 'privacy startup waits on a protected core package rather than an optional removed package'
Assert-True ($serviceScript -match 'deny_wan_uid' -and $serviceScript -match 'lockdown-uids\.conf' -and $serviceScript -match 'com\\\.onyx' -and $serviceScript -match 'refused shared/system WAN rule') 'vendor lockdown denies dedicated BOOX UIDs while excluding shared Android system UIDs'
Assert-True ($serviceScript -match '255\.255\.255\.255/32' -and $serviceScript -match 'ff00::/8') 'vendor lockdown preserves local broadcast and multicast discovery'
foreach ($profileName in @('balanced', 'purge', 'lockdown', 'strict')) {
    $expectedLines = @($privacyPolicy.profiles.$profileName.packages | ForEach-Object { "$($_.action) $($_.id)" })
    $actualLines = @(Get-Content -LiteralPath (Join-Path $projectRoot "privacy/magisk-module/$profileName-packages.conf") | Where-Object { $_ -and -not $_.StartsWith('#') })
    Assert-True (($expectedLines -join "`n") -eq ($actualLines -join "`n")) "Magisk $profileName package profile matches privacy policy"
}
$purgeIds = @($privacyPolicy.profiles.purge.systemlessPurgePackages)
Assert-True ($purgeIds.Count -eq 5 -and -not @($privacyPolicy.protectedPackages | Where-Object { $_ -in $purgeIds }).Count) 'systemless purge is limited to five non-protected packages'
$lockdownPurgeIds = @($privacyPolicy.profiles.lockdown.systemlessPurgePackages)
Assert-True ($lockdownPurgeIds.Count -eq 6 -and 'com.onyx.android.ksync' -in $lockdownPurgeIds) 'vendor lockdown also systemlessly removes BOOX cloud sync'
$strictIds = @($privacyPolicy.profiles.strict.packages.id)
Assert-True (-not @($privacyPolicy.protectedPackages | Where-Object { $_ -in $strictIds }).Count) 'strict privacy profile excludes protected BOOX packages'
$privacyModulePath = Join-Path $projectRoot 'src/NoteAir5C.Privacy.psm1'
$privacyTokens = $null
$privacyErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($privacyModulePath, [ref]$privacyTokens, [ref]$privacyErrors)
Assert-True ($privacyErrors.Count -eq 0) 'privacy module parses cleanly'
$privacySource = Get-Content -LiteralPath $privacyModulePath -Raw
Assert-True ($privacySource -match 'Where-Object \{ \$_ -ge 10000 \}' -and $privacySource -match '1000 -in \$vendorUids') 'Lockdown inventory persists application UIDs only and rejects accidental shared UID 1000 inclusion'
Assert-True ($privacySource -match '\.replace' -and $privacySource -match '\^/system/\(app\|priv-app\)/') 'systemless purge uses Magisk replace markers behind an exact APK-path allowlist'
Assert-True ($privacySource -match 'Backup-PrivacyHomeLayout' -and $privacySource -match 'Restore-PrivacyHomeLayout' -and $privacySource -match 'Set-PrivacyCleanHomeLayout') 'privacy recovery records and restores the BOOX launcher layout'
$homeHelperSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src/boox_home_layout.py') -Raw
Assert-True ($homeHelperSource -match 'EXPECTED_COLUMNS' -and $homeHelperSource -match 'PRAGMA integrity_check' -and $homeHelperSource -match 'Unknown launcher schema') 'home-layout helper gates the exact SQLite schema and integrity'
Assert-True ($homeHelperSource -match 'com\.android\.vending' -and $homeHelperSource -match 'com\.topjohnwu\.magisk' -and $homeHelperSource -match 'STORAGE_ACTION' -and $homeHelperSource -match 'SETTINGS_ACTION') 'home-layout helper encodes the requested desktop and dock allowlists'

$wizardPath = Join-Path $projectRoot 'Start-NoteAir5C.ps1'
$wizardSource = Get-Content -LiteralPath $wizardPath -Raw
$wizardTokens = $null
$wizardErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($wizardPath, [ref]$wizardTokens, [ref]$wizardErrors)
Assert-True ($wizardErrors.Count -eq 0) 'guided console parses cleanly'
Assert-True ($wizardSource -match '\[Console\]::ReadKey' -and $wizardSource -match 'UpArrow' -and $wizardSource -match 'DownArrow' -and $wizardSource -match 'ConsoleKey\]::Enter') 'guided console supports arrow-key selection and Enter'
Assert-True ($wizardSource -match 'PRIVACY HARDENING' -and $wizardSource -match 'PrivacyAudit' -and $wizardSource -match 'PrivacyHome' -and $wizardSource -match 'PrivacyHarden' -and $wizardSource -match 'PrivacyProfile Purge' -and $wizardSource -match 'PrivacyProfile Lockdown' -and $wizardSource -match 'PrivacyRestore') 'guided console exposes audit, home layout, harden, purge, lockdown, and restore actions'
$demoOutput = (& $wizardPath -Action Demo -NoClear 6>&1 | Out-String)
Assert-True ($demoOutput -match 'DEMO COMPLETE' -and $demoOutput -match 'FACTORY RESET' -and $demoOutput -match 'VERIFY REAL ROOT') 'guided console demo covers manual checkpoints without running the engine'
$launcher = Get-Content -LiteralPath (Join-Path $projectRoot 'Start-NoteAir5C.cmd') -Raw
Assert-True ($launcher -match 'Start-NoteAir5C\.ps1' -and $launcher -match 'ExecutionPolicy Bypass') 'double-click launcher targets the guided console'
$unixLauncher = Get-Content -LiteralPath (Join-Path $projectRoot 'Start-NoteAir5C.sh') -Raw
Assert-True ($unixLauncher -match '^#!/usr/bin/env sh' -and $unixLauncher -match 'exec "\$PWSH"' -and $unixLauncher -match '"\$@"') 'Linux/macOS launcher preserves arguments and replaces the shell process'
$usbRule = Get-Content -LiteralPath (Join-Path $projectRoot 'config/51-noteair5c.rules') -Raw
Assert-True ($usbRule -match '2d95' -and $usbRule -match '05c6' -and $usbRule -match '9008' -and $usbRule -match 'ID_MM_DEVICE_IGNORE') 'Linux USB rule scopes BOOX ADB and Qualcomm EDL'

Write-Host "`n$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
$global:LASTEXITCODE = 0
