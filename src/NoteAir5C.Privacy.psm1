Set-StrictMode -Version Latest

function Get-PrivacyPaths {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    [pscustomobject]@{
        Root = $root
        Runs = Join-Path $root 'runs'
        Policy = Join-Path $root 'config/privacy-policy.json'
        Module = Join-Path $root 'privacy/magisk-module'
    }
}

function Get-PrivacyPolicy {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = (Get-PrivacyPaths $ProjectRoot).Policy
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Privacy policy not found: $path" }
    $policy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$policy.schemaVersion -ne 1) { throw "Unsupported privacy policy schema: $($policy.schemaVersion)" }
    $policy
}

function Test-PrivacyPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $policy = Get-PrivacyPolicy $ProjectRoot
    $packagePattern = '^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+$'
    $protected = @($policy.protectedPackages)
    foreach ($profileName in @('balanced', 'purge', 'lockdown', 'strict')) {
        $profile = $policy.profiles.$profileName
        if (-not $profile) { throw "Privacy profile is missing: $profileName" }
        $ids = @($profile.packages.id)
        if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw "Duplicate package in privacy profile '$profileName'." }
        foreach ($package in @($profile.packages)) {
            if ([string]$package.id -notmatch $packagePattern) { throw "Unsafe package ID in '$profileName': $($package.id)" }
            if ([string]$package.action -notin @('uninstall-user', 'disable-user')) { throw "Unsafe package action for $($package.id)." }
            if ([string]$package.id -in $protected) { throw "Protected package appears in '$profileName': $($package.id)" }
        }
        $purgeIds = if ($profile.PSObject.Properties['systemlessPurgePackages']) { @($profile.systemlessPurgePackages) } else { @() }
        if ($profileName -in @('purge', 'lockdown') -and $purgeIds.Count -eq 0) { throw "The $profileName profile has no systemless purge packages." }
        foreach ($purgeId in $purgeIds) {
            if ([string]$purgeId -notmatch $packagePattern) { throw "Unsafe systemless purge package in '$profileName': $purgeId" }
            if ([string]$purgeId -notin $ids) { throw "Systemless purge package is not part of '$profileName': $purgeId" }
            if ([string]$purgeId -in $protected) { throw "Protected package appears in systemless purge list: $purgeId" }
        }
    }
    $hosts = @($policy.blockedHosts)
    if (($hosts | Select-Object -Unique).Count -ne $hosts.Count) { throw 'Duplicate hostname in privacy policy.' }
    foreach ($hostName in $hosts) {
        if ([string]$hostName -notmatch '^[a-z0-9.-]+$' -or [string]$hostName -notmatch '\.') { throw "Unsafe blocked hostname: $hostName" }
    }
    if ([string]$policy.vendorWanDeniedPackagePrefix -ne 'com.onyx') { throw 'Vendor lockdown package prefix must be exactly com.onyx.' }
    $true
}

function Invoke-PrivacyNative {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($Live) { Write-Host $line }
        $line
    })
    $exitCode = $LASTEXITCODE
    $output = $lines -join [Environment]::NewLine
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')`n$output"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Lines = $lines }
}

function Get-PrivacyAdbPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $platform = Get-HostPlatform
    $suffix = if ($platform -eq 'windows') { '.exe' } else { '' }
    $adb = Join-Path (Join-Path (Get-AndroidToolsDirectory -ProjectRoot $ProjectRoot -Platform $platform) 'platform-tools') "adb$suffix"
    if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) { throw 'Android platform tools are missing. Run Setup first.' }
    $adb
}

function Get-PrivacyTarget {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $adb = Get-PrivacyAdbPath $ProjectRoot
    $devices = Invoke-PrivacyNative -FilePath $adb -Arguments @('devices', '-l')
    $matches = @($devices.Lines | Where-Object { $_ -match '^([^\s]+)\s+device\b' -and $_ -match '(?:product|model|device):NoteAir5C\b' })
    if ($matches.Count -ne 1) { throw "Expected exactly one authorized Note Air 5C; found $($matches.Count)." }
    if ($matches[0] -notmatch '^([^\s]+)\s+') { throw 'Could not parse the Note Air 5C ADB serial.' }
    [pscustomobject]@{ Adb = $adb; Serial = $Matches[1] }
}

function Invoke-PrivacyAdb {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    Invoke-PrivacyNative -FilePath $Target.Adb -Arguments (@('-s', $Target.Serial) + $Arguments) -AllowFailure:$AllowFailure -Live:$Live
}

function Invoke-PrivacyShell {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    Invoke-PrivacyAdb -Target $Target -Arguments (@('shell') + $Arguments) -AllowFailure:$AllowFailure -Live:$Live
}

function Invoke-PrivacyRootShell {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Command,
        [switch]$AllowFailure,
        [switch]$Live
    )
    # adb shell joins arguments through a remote shell, so multiline commands and
    # quotes are not preserved reliably with a direct `su -c <command>` call.
    # Feeding UTF-8 through the device's base64 tool keeps the command byte-exact.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    Invoke-PrivacyShell -Target $Target -Arguments @("echo $encoded | base64 -d | su -c sh") -AllowFailure:$AllowFailure -Live:$Live
}

function Get-PrivacyRootRun {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$Fingerprint
    )
    $paths = Get-PrivacyPaths $ProjectRoot
    foreach ($directory in @(Get-ChildItem -LiteralPath $paths.Runs -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $statePath = Join-Path $directory.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { continue }
        if ($state.stage -eq 'RootVerified' -and [string]$state.device.adbSerial -eq $Serial -and [string]$state.device.fingerprint -eq $Fingerprint) {
            return $directory.FullName
        }
    }
    throw 'Privacy hardening requires a matching RootVerified run for this serial and firmware.'
}

function Get-PrivacyPackageState {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Id
    )
    if ($Id -notmatch '^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+$') { throw "Unsafe package ID: $Id" }
    $dump = Invoke-PrivacyShell -Target $Target -Arguments @('dumpsys', 'package', $Id) -AllowFailure
    $exists = $dump.ExitCode -eq 0 -and $dump.Output -notmatch 'Unable to find package' -and $dump.Output -match '(?m)^\s*Package \['
    $uid = $null
    $version = $null
    $codePath = $null
    $installed = $false
    $enabled = $null
    if ($exists) {
        if ($dump.Output -match '(?m)^\s*(?:userId|appId)=(\d+)') { $uid = [int]$Matches[1] }
        if ($dump.Output -match '(?m)^\s*versionName=(.+)$') { $version = $Matches[1].Trim() }
        if ($dump.Output -match '(?m)^\s*codePath=(.+)$') { $codePath = $Matches[1].Trim() }
        if ($dump.Output -match '(?m)^\s*User 0:.*?installed=(true|false).*?enabled=(\d+)') {
            $installed = $Matches[1] -eq 'true'
            $enabled = [int]$Matches[2]
        }
    }
    [pscustomobject]@{ id = $Id; exists = $exists; installed = $installed; enabled = $enabled; uid = $uid; version = $version; codePath = $codePath }
}

function Get-PrivacySettingState {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Namespace -notin @('global', 'secure', 'system') -or $Name -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Unsafe Android setting identifier.' }
    $result = Invoke-PrivacyShell -Target $Target -Arguments @('settings', 'get', $Namespace, $Name) -AllowFailure
    $value = $result.Output.Trim()
    [pscustomobject]@{ namespace = $Namespace; name = $Name; exists = ($result.ExitCode -eq 0 -and $value -ne 'null'); value = $(if ($value -eq 'null') { $null } else { $value }) }
}

function Assert-PrivacyTarget {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $target = Get-PrivacyTarget $ProjectRoot
    $model = (Invoke-PrivacyShell -Target $target -Arguments @('getprop', 'ro.product.model')).Output.Trim()
    if ($model -ne 'NoteAir5C') { throw "Refusing non-NoteAir5C model '$model'." }
    $fingerprint = (Invoke-PrivacyShell -Target $target -Arguments @('getprop', 'ro.vendor.build.fingerprint')).Output.Trim()
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { throw 'The BOOX vendor fingerprint is unavailable.' }
    $root = Invoke-PrivacyRootShell -Target $target -Command 'id' -AllowFailure
    if ($root.ExitCode -ne 0 -or $root.Output -notmatch 'uid=0\(root\)') { throw 'Live Magisk root proof failed. Grant ADB Shell superuser access first.' }
    $runPath = Get-PrivacyRootRun -ProjectRoot $ProjectRoot -Serial $target.Serial -Fingerprint $fingerprint
    [pscustomobject]@{
        Target = $target
        Model = $model
        Fingerprint = $fingerprint
        RunPath = $runPath
        RootProof = $root.Output.Trim()
    }
}

function Get-PrivacyAuditData {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Context
    )
    $policy = Get-PrivacyPolicy $ProjectRoot
    $packageIds = @(
        @($policy.profiles.balanced.packages.id) +
        @($policy.profiles.purge.packages.id) +
        @($policy.profiles.lockdown.packages.id) +
        @($policy.profiles.strict.packages.id) +
        @($policy.protectedPackages) +
        @($policy.networkDeniedPackages) +
        @($policy.lanOnlyPackages) | Select-Object -Unique
    )
    $packages = @($packageIds | ForEach-Object { Get-PrivacyPackageState -Target $Context.Target -Id $_ })
    $settings = @($policy.settings | ForEach-Object { Get-PrivacySettingState -Target $Context.Target -Namespace $_.namespace -Name $_.name })
    $moduleProbe = Invoke-PrivacyRootShell -Target $Context.Target -Command 'test -d /data/adb/modules/boox-privacy && echo present || echo absent' -AllowFailure
    $profileProbe = Invoke-PrivacyRootShell -Target $Context.Target -Command 'cat /data/adb/modules/boox-privacy/profile 2>/dev/null || true' -AllowFailure
    $lockdownUidProbe = Invoke-PrivacyRootShell -Target $Context.Target -Command 'cat /data/adb/modules/boox-privacy/lockdown-uids.conf 2>/dev/null || true' -AllowFailure
    $firewall = Invoke-PrivacyRootShell -Target $Context.Target -Command 'iptables-save 2>/dev/null | grep BOOX_PRIVACY; ip6tables-save 2>/dev/null | grep BOOX_PRIVACY' -AllowFailure
    $hosts = Invoke-PrivacyRootShell -Target $Context.Target -Command 'grep -c "BOOX Privacy Firewall" /system/etc/hosts 2>/dev/null || true' -AllowFailure
    [pscustomobject]@{
        schemaVersion = 1
        atUtc = [DateTime]::UtcNow.ToString('o')
        model = $Context.Model
        serial = $Context.Target.Serial
        fingerprint = $Context.Fingerprint
        root = $Context.RootProof
        runPath = $Context.RunPath
        moduleInstalled = $moduleProbe.Output.Trim() -eq 'present'
        moduleProfile = $profileProbe.Output.Trim()
        lockdownUids = @($lockdownUidProbe.Lines | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        hostsActive = $hosts.Output.Trim() -match '^[1-9]'
        firewallActive = $firewall.Output -match 'BOOX_PRIVACY'
        packages = $packages
        settings = $settings
    }
}

function Save-PrivacyJson {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-PrivacyHomeLayoutTool {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('inspect', 'apply', 'verify')][string]$Command,
        [Parameter(Mandatory)][string]$Database
    )
    $platform = Get-HostPlatform
    $venv = Get-EdlVenvDirectory -ProjectRoot $ProjectRoot -Platform $platform
    $python = Get-VenvPythonPath -VenvRoot $venv -Platform $platform
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'The verified Python environment is missing. Run Setup first.' }
    $helper = Join-Path $ProjectRoot 'src/boox_home_layout.py'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "Home-layout helper is missing: $helper" }
    $result = Invoke-PrivacyNative -FilePath $python -Arguments @($helper, $Command, $Database) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "BOOX home-layout $Command failed: $($result.Output)" }
    try { $result.Output.Trim() | ConvertFrom-Json } catch { throw "Invalid home-layout helper output: $($result.Output)" }
}

function Backup-PrivacyHomeLayout {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Context
    )
    $launcher = Get-PrivacyPackageState -Target $Context.Target -Id 'com.onyx'
    if (-not $launcher.exists -or $launcher.version -ne '57099 - 16831a34f3d') {
        throw "Refusing unknown BOOX launcher version '$($launcher.version)'."
    }
    $directory = Join-Path (Join-Path $Context.RunPath 'privacy') ("home-layout-{0}" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $snapshotPath = Join-Path $directory 'AppDatabase.before.db'
    $remoteSnapshot = '/data/local/tmp/boox-home-layout-before.db'
    $snapshotCommand = @"
set -e
rm -f '$remoteSnapshot'
am force-stop com.onyx
cp -p /data/user/0/com.onyx/databases/AppDatabase.db '$remoteSnapshot'
chmod 0644 '$remoteSnapshot'
am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
input keyevent 3
"@
    Invoke-PrivacyRootShell -Target $Context.Target -Command $snapshotCommand | Out-Null
    try {
        Invoke-PrivacyAdb -Target $Context.Target -Arguments @('pull', $remoteSnapshot, $snapshotPath) | Out-Null
    } finally {
        Invoke-PrivacyRootShell -Target $Context.Target -Command "rm -f '$remoteSnapshot'" -AllowFailure | Out-Null
    }
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw 'BOOX home-layout snapshot was not pulled.' }
    $inspection = Invoke-PrivacyHomeLayoutTool -ProjectRoot $ProjectRoot -Command inspect -Database $snapshotPath
    [pscustomobject]@{
        launcherVersion = [string]$launcher.version
        snapshotPath = $snapshotPath
        snapshotSha256 = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        snapshotAtUtc = [DateTime]::UtcNow.ToString('o')
        inspection = $inspection
    }
}

function Restore-PrivacyHomeLayout {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Backup
    )
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $Context.RunPath 'privacy')) + [IO.Path]::DirectorySeparatorChar
    $snapshotPath = [IO.Path]::GetFullPath([string]$Backup.snapshotPath)
    if (-not $snapshotPath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Home-layout restore path escaped the matching privacy run.' }
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw "Home-layout snapshot is missing: $snapshotPath" }
    $snapshotHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($snapshotHash -ne [string]$Backup.snapshotSha256) { throw 'Home-layout snapshot hash does not match its recovery record.' }
    [void](Invoke-PrivacyHomeLayoutTool -ProjectRoot $ProjectRoot -Command inspect -Database $snapshotPath)
    $currentLauncher = Get-PrivacyPackageState -Target $Context.Target -Id 'com.onyx'
    if ($currentLauncher.version -ne [string]$Backup.launcherVersion) { throw 'BOOX launcher version changed; refusing layout restore.' }

    $remoteStage = '/data/local/tmp/boox-home-layout-restore.db'
    Invoke-PrivacyAdb -Target $Context.Target -Arguments @('push', $snapshotPath, $remoteStage) | Out-Null
    $restoreCommand = @"
set -e
db=/data/user/0/com.onyx/databases/AppDatabase.db
am force-stop com.onyx
cp '$remoteStage' "`$db.new"
chown 1000:1000 "`$db.new"
chmod 0660 "`$db.new"
restorecon "`$db.new"
mv -f "`$db.new" "`$db"
rm -f /data/user/0/com.onyx/databases/AppDatabase.db-journal '$remoteStage'
am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
input keyevent 3
"@
    Invoke-PrivacyRootShell -Target $Context.Target -Command $restoreCommand | Out-Null
}

function Set-PrivacyCleanHomeLayout {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Backup
    )
    $workingPath = Join-Path (Split-Path -Parent ([string]$Backup.snapshotPath)) 'AppDatabase.cleaned.db'
    Copy-Item -LiteralPath ([string]$Backup.snapshotPath) -Destination $workingPath -Force
    $summary = Invoke-PrivacyHomeLayoutTool -ProjectRoot $ProjectRoot -Command apply -Database $workingPath
    $workingHash = (Get-FileHash -LiteralPath $workingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $remoteStage = '/data/local/tmp/boox-home-layout-cleaned.db'
    $remoteRollback = '/data/local/tmp/boox-home-layout-rollback.db'
    Invoke-PrivacyAdb -Target $Context.Target -Arguments @('push', $workingPath, $remoteStage) | Out-Null
    $remoteHash = (Invoke-PrivacyRootShell -Target $Context.Target -Command "sha256sum '$remoteStage' | cut -d' ' -f1").Output.Trim()
    if ($remoteHash -ne $workingHash) { throw 'Clean home-layout database failed device read-back hashing.' }

    $applyCommand = @"
set -e
db=/data/user/0/com.onyx/databases/AppDatabase.db
rm -f '$remoteRollback'
am force-stop com.onyx
cp -p "`$db" '$remoteRollback'
cp '$remoteStage' "`$db.new"
chown 1000:1000 "`$db.new"
chmod 0660 "`$db.new"
restorecon "`$db.new"
mv -f "`$db.new" "`$db"
rm -f /data/user/0/com.onyx/databases/AppDatabase.db-journal
am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
input keyevent 3
"@
    try {
        Invoke-PrivacyRootShell -Target $Context.Target -Command $applyCommand | Out-Null
        Start-Sleep -Seconds 3
        $verifiedPath = Join-Path (Split-Path -Parent ([string]$Backup.snapshotPath)) 'AppDatabase.verified.db'
        $verifyStage = '/data/local/tmp/boox-home-layout-verified.db'
        $verifyCommand = "cp -p /data/user/0/com.onyx/databases/AppDatabase.db '$verifyStage' && chmod 0644 '$verifyStage'"
        Invoke-PrivacyRootShell -Target $Context.Target -Command $verifyCommand | Out-Null
        Invoke-PrivacyAdb -Target $Context.Target -Arguments @('pull', $verifyStage, $verifiedPath) | Out-Null
        $verified = Invoke-PrivacyHomeLayoutTool -ProjectRoot $ProjectRoot -Command verify -Database $verifiedPath
        Invoke-PrivacyRootShell -Target $Context.Target -Command "rm -f '$remoteStage' '$remoteRollback' '$verifyStage'" -AllowFailure | Out-Null
    } catch {
        $rollbackCommand = @"
db=/data/user/0/com.onyx/databases/AppDatabase.db
if [ -f '$remoteRollback' ]; then
  am force-stop com.onyx
  cp -p '$remoteRollback' "`$db"
  chown 1000:1000 "`$db"
  chmod 0660 "`$db"
  restorecon "`$db"
  rm -f /data/user/0/com.onyx/databases/AppDatabase.db-journal
  am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  input keyevent 3
fi
rm -f '$remoteStage' '$remoteRollback' /data/local/tmp/boox-home-layout-verified.db
"@
        Invoke-PrivacyRootShell -Target $Context.Target -Command $rollbackCommand -AllowFailure | Out-Null
        throw
    }
    [pscustomobject]@{
        appliedAtUtc = [DateTime]::UtcNow.ToString('o')
        cleanedPath = $workingPath
        cleanedSha256 = $workingHash
        summary = $summary
        verified = $verified
    }
}

function Write-PrivacyAuditSummary {
    param([Parameter(Mandatory)]$Audit)
    Write-Host ''
    Write-Host 'BOOX PRIVACY AUDIT' -ForegroundColor Cyan
    Write-Host "  Model / serial  : $($Audit.model) / $($Audit.serial)"
    Write-Host "  Root proof      : $($Audit.root)" -ForegroundColor Green
    Write-Host "  Privacy module  : $(if ($Audit.moduleInstalled) { 'installed' } else { 'not installed' })"
    Write-Host "  Active profile  : $(if ($Audit.moduleProfile) { $Audit.moduleProfile } else { 'none' })"
    if (@($Audit.lockdownUids).Count) { Write-Host "  WAN-denied UIDs : $(@($Audit.lockdownUids).Count) ($(@($Audit.lockdownUids) -join ', '))" }
    Write-Host "  Hosts overlay   : $(if ($Audit.hostsActive) { 'active' } else { 'inactive' })"
    Write-Host "  Firewall chain  : $(if ($Audit.firewallActive) { 'active' } else { 'inactive' })"
    Write-Host ''
    $Audit.packages | Where-Object exists | Select-Object id, installed, enabled, uid, version | Format-Table -AutoSize
}

function Invoke-NoteAir5CPrivacyAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$NonInteractive
    )
    [void](Test-PrivacyPolicy $ProjectRoot)
    $context = Assert-PrivacyTarget $ProjectRoot
    $audit = Get-PrivacyAuditData -ProjectRoot $ProjectRoot -Context $context
    $privacyRoot = Join-Path $context.RunPath 'privacy'
    $path = Join-Path $privacyRoot ("audit-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    Save-PrivacyJson -Value $audit -Path $path
    Write-PrivacyAuditSummary $audit
    Write-Host "Read-only audit saved: $path" -ForegroundColor Green
    $audit
}

function Confirm-PrivacyChange {
    param(
        [Parameter(Mandatory)][string]$Phrase,
        [Parameter(Mandatory)][string]$Description,
        [switch]$Acknowledged,
        [switch]$NonInteractive
    )
    if ($Acknowledged) { return }
    if ($NonInteractive) { throw "Non-interactive privacy changes require the acknowledgement switch ($Phrase)." }
    Write-Host $Description -ForegroundColor Yellow
    $answer = Read-Host "Type $Phrase"
    if ($answer -cne $Phrase) { throw 'Confirmation did not match; the tablet was not changed.' }
}

function Install-PrivacyModule {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('Balanced', 'Purge', 'Lockdown', 'Strict')][string]$Profile,
        [object[]]$SystemlessPurgeStates = @()
    )
    $paths = Get-PrivacyPaths $ProjectRoot
    $moduleFiles = @('module.prop', 'service.sh', 'uninstall.sh', 'system/etc/hosts', 'balanced-packages.conf', 'purge-packages.conf', 'lockdown-packages.conf', 'strict-packages.conf')
    foreach ($file in $moduleFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $paths.Module $file) -PathType Leaf)) { throw "Privacy module file is missing: $file" }
    }
    $conflicts = Invoke-PrivacyRootShell -Target $Context.Target -Command "find /data/adb/modules -path '*/system/etc/hosts' -type f 2>/dev/null | grep -v '/boox-privacy/'" -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($conflicts.Output)) {
        throw "Another Magisk module already supplies /system/etc/hosts. Refusing an ambiguous overlay: $($conflicts.Output.Trim())"
    }
    $probe = Invoke-PrivacyRootShell -Target $Context.Target -Command 'test -e /data/adb/modules/boox-privacy/module.prop && echo present || true' -AllowFailure
    if ($probe.Output -match 'present') { throw 'BOOX Privacy Firewall is already installed. Restore it before applying a new profile.' }

    # The staging directory must belong to the ADB shell user so `adb push` can
    # populate it. Root takes ownership only after copying into Magisk's tree.
    Invoke-PrivacyShell -Target $Context.Target -Arguments @('rm', '-rf', '/data/local/tmp/boox-privacy-stage') -AllowFailure | Out-Null
    Invoke-PrivacyShell -Target $Context.Target -Arguments @('mkdir', '-p', '/data/local/tmp/boox-privacy-stage') | Out-Null
    Invoke-PrivacyAdb -Target $Context.Target -Arguments @('push', "$($paths.Module)/.", '/data/local/tmp/boox-privacy-stage/') -Live | Out-Null
    $install = @'
set -e
target=/data/adb/modules/boox-privacy
rm -rf "$target"
mkdir -p "$target"
cp -a /data/local/tmp/boox-privacy-stage/. "$target/"
chown -R 0:0 "$target"
chmod 0755 "$target/service.sh" "$target/uninstall.sh"
chmod 0644 "$target/module.prop" "$target/system/etc/hosts" "$target/balanced-packages.conf" "$target/purge-packages.conf" "$target/lockdown-packages.conf" "$target/strict-packages.conf"
rm -rf /data/local/tmp/boox-privacy-stage
'@
    Invoke-PrivacyRootShell -Target $Context.Target -Command $install | Out-Null
    Invoke-PrivacyRootShell -Target $Context.Target -Command "printf '%s\n' '$($Profile.ToLowerInvariant())' > /data/adb/modules/boox-privacy/profile && chmod 0644 /data/adb/modules/boox-privacy/profile" | Out-Null

    $remoteHashes = Invoke-PrivacyRootShell -Target $Context.Target -Command 'cd /data/adb/modules/boox-privacy && sha256sum module.prop service.sh uninstall.sh system/etc/hosts balanced-packages.conf purge-packages.conf lockdown-packages.conf strict-packages.conf'
    foreach ($file in $moduleFiles) {
        $localHash = (Get-FileHash -LiteralPath (Join-Path $paths.Module $file) -Algorithm SHA256).Hash.ToLowerInvariant()
        $escaped = [regex]::Escape($file)
        if ($remoteHashes.Output -notmatch "(?m)^$localHash\s+$escaped\r?$") { throw "Privacy module read-back hash mismatch: $file" }
    }
    $remoteProfile = (Invoke-PrivacyRootShell -Target $Context.Target -Command 'cat /data/adb/modules/boox-privacy/profile').Output.Trim()
    if ($remoteProfile -ne $Profile.ToLowerInvariant()) { throw 'Privacy module profile marker did not verify.' }

    if ($Profile -eq 'Lockdown') {
        $packageUidOutput = Invoke-PrivacyShell -Target $Context.Target -Arguments @('pm', 'list', 'packages', '-U')
        $vendorUids = @($packageUidOutput.Lines | ForEach-Object {
            if ($_ -match '^package:com\.onyx(?:\.[A-Za-z0-9_.]+)?\s+uid:(\d+)\s*$') { [int]$Matches[1] }
        } | Sort-Object -Unique)
        if ($vendorUids.Count -lt 10 -or 1000 -notin $vendorUids) {
            throw "Vendor lockdown UID inventory was incomplete; found: $($vendorUids -join ', ')"
        }
        $uidContent = ($vendorUids -join "`n") + "`n"
        $uidContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uidContent))
        $uidInstall = "echo '$uidContentBase64' | base64 -d > /data/adb/modules/boox-privacy/lockdown-uids.conf && chmod 0644 /data/adb/modules/boox-privacy/lockdown-uids.conf"
        Invoke-PrivacyRootShell -Target $Context.Target -Command $uidInstall | Out-Null
        $remoteUidContent = (Invoke-PrivacyRootShell -Target $Context.Target -Command 'cat /data/adb/modules/boox-privacy/lockdown-uids.conf').Output.Replace("`r", '')
        if ($remoteUidContent.TrimEnd("`n") -ne $uidContent.TrimEnd("`n")) { throw 'Vendor lockdown UID inventory did not verify after installation.' }
    }

    $purgedPaths = @()
    foreach ($state in @($SystemlessPurgeStates)) {
        if (-not $state.exists -or [string]::IsNullOrWhiteSpace([string]$state.codePath)) {
            throw "Cannot systemlessly purge an absent package: $($state.id)"
        }
        $pathMatch = [regex]::Match([string]$state.codePath, '^/system/(app|priv-app)/([A-Za-z0-9._-]+)$')
        if (-not $pathMatch.Success) { throw "Refusing unsafe or unsupported APK path for $($state.id): $($state.codePath)" }
        $relativePath = "$($pathMatch.Groups[1].Value)/$($pathMatch.Groups[2].Value)"
        $markerPath = "/data/adb/modules/boox-privacy/system/$relativePath/.replace"
        $markerCommand = "mkdir -p '/data/adb/modules/boox-privacy/system/$relativePath' && : > '$markerPath' && chmod 0644 '$markerPath'"
        Invoke-PrivacyRootShell -Target $Context.Target -Command $markerCommand | Out-Null
        $markerProbe = Invoke-PrivacyRootShell -Target $Context.Target -Command "test -f '$markerPath' && echo present || true"
        if ($markerProbe.Output.Trim() -ne 'present') { throw "Systemless purge marker did not verify: $markerPath" }
        $purgedPaths += [pscustomobject]@{ package = [string]$state.id; codePath = [string]$state.codePath; markerPath = $markerPath }
    }
    Invoke-PrivacyRootShell -Target $Context.Target -Command 'sh /data/adb/modules/boox-privacy/service.sh' | Out-Null
    $verify = Invoke-PrivacyRootShell -Target $Context.Target -Command 'iptables-save | grep BOOX_PRIVACY; ip6tables-save | grep BOOX_PRIVACY'
    if ($verify.Output -notmatch '119\.23\.143\.188' -or $verify.Output -notmatch 'BOOX_PRIVACY') { throw 'Privacy firewall did not verify after installation.' }
    $purgedPaths
}

function Set-PrivacyAndroidSetting {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ($Namespace -notin @('global', 'secure', 'system') -or $Name -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Unsafe Android setting identifier.' }
    $encodedValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    $command = @"
value=`$(echo $encodedValue | base64 -d)
settings put $Namespace $Name "`$value"
"@
    $result = Invoke-PrivacyRootShell -Target $Target -Command $command -AllowFailure
    if ($result.ExitCode -ne 0) { throw "Failed to set Android setting $Namespace/$Name`: $($result.Output)" }
    $verify = Get-PrivacySettingState -Target $Target -Namespace $Namespace -Name $Name
    if (-not $verify.exists -or $verify.value -ne $Value) { throw "Android setting did not verify: $Namespace/$Name" }
}

function Set-PrivacyPackageAction {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Package
    )
    $before = Get-PrivacyPackageState -Target $Target -Id $Package.id
    if (-not $before.exists -or -not $before.installed) { return }
    $result = switch ([string]$Package.action) {
        'uninstall-user' { Invoke-PrivacyShell -Target $Target -Arguments @('pm', 'uninstall', '--user', '0', [string]$Package.id) -AllowFailure }
        'disable-user'   { Invoke-PrivacyShell -Target $Target -Arguments @('pm', 'disable-user', '--user', '0', [string]$Package.id) -AllowFailure }
    }
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'Success|disabled-user') { throw "Package action failed for $($Package.id): $($result.Output)" }
    $after = Get-PrivacyPackageState -Target $Target -Id $Package.id
    if ($Package.action -eq 'uninstall-user' -and $after.installed) { throw "Package remains installed for user 0: $($Package.id)" }
    if ($Package.action -eq 'disable-user' -and $after.enabled -ne 3) { throw "Package did not enter disabled-user state: $($Package.id)" }
    Write-Host "  $($Package.action): $($Package.id)" -ForegroundColor Green
}

function Remove-PrivacyModule {
    param([Parameter(Mandatory)]$Context)
    $remove = @'
if [ -x /data/adb/modules/boox-privacy/uninstall.sh ]; then
  sh /data/adb/modules/boox-privacy/uninstall.sh
fi
rm -rf /data/adb/modules/boox-privacy
rm -rf /data/local/tmp/boox-privacy-stage
'@
    Invoke-PrivacyRootShell -Target $Context.Target -Command $remove -AllowFailure | Out-Null
}

function Restore-PrivacyAndroidState {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Before
    )
    foreach ($setting in @($Before.settings)) {
        if ($setting.exists) {
            Set-PrivacyAndroidSetting -Target $Context.Target -Namespace ([string]$setting.namespace) -Name ([string]$setting.name) -Value ([string]$setting.value)
        } else {
            Invoke-PrivacyShell -Target $Context.Target -Arguments @('settings', 'delete', [string]$setting.namespace, [string]$setting.name) -AllowFailure | Out-Null
        }
    }
    foreach ($package in @($Before.packages)) {
        if (-not $package.exists) { continue }
        if ($package.installed) {
            Invoke-PrivacyShell -Target $Context.Target -Arguments @('cmd', 'package', 'install-existing', '--user', '0', [string]$package.id) -AllowFailure | Out-Null
            if ([int]$package.enabled -eq 3) {
                Invoke-PrivacyShell -Target $Context.Target -Arguments @('pm', 'disable-user', '--user', '0', [string]$package.id) -AllowFailure | Out-Null
            } else {
                Invoke-PrivacyShell -Target $Context.Target -Arguments @('pm', 'default-state', '--user', '0', [string]$package.id) -AllowFailure | Out-Null
            }
        } else {
            Invoke-PrivacyShell -Target $Context.Target -Arguments @('pm', 'uninstall', '--user', '0', [string]$package.id) -AllowFailure | Out-Null
        }
    }
}

function Assert-PrivacySnapshotRestored {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Before
    )
    $moduleProbe = Invoke-PrivacyRootShell -Target $Context.Target -Command 'test -e /data/adb/modules/boox-privacy/module.prop && echo present || true' -AllowFailure
    $chainProbe = Invoke-PrivacyRootShell -Target $Context.Target -Command 'iptables-save 2>/dev/null | grep BOOX_PRIVACY; ip6tables-save 2>/dev/null | grep BOOX_PRIVACY' -AllowFailure
    if ($moduleProbe.Output -match 'present' -or $chainProbe.Output -match 'BOOX_PRIVACY') { throw 'Privacy module or live firewall chain remained after restore.' }
    foreach ($setting in @($Before.settings)) {
        $current = Get-PrivacySettingState -Target $Context.Target -Namespace $setting.namespace -Name $setting.name
        if ([bool]$current.exists -ne [bool]$setting.exists -or ($setting.exists -and [string]$current.value -ne [string]$setting.value)) {
            throw "Android setting did not restore exactly: $($setting.namespace)/$($setting.name)"
        }
    }
    foreach ($package in @($Before.packages)) {
        if (-not $package.exists) { continue }
        $current = Get-PrivacyPackageState -Target $Context.Target -Id $package.id
        if (-not $current.exists) { throw "Package did not return after systemless restore: $($package.id)" }
        if ([bool]$current.installed -ne [bool]$package.installed) { throw "Package install state did not restore: $($package.id)" }
        if ($package.installed -and [int]$current.enabled -ne [int]$package.enabled) { throw "Package enabled state did not restore: $($package.id)" }
    }
}

function Restore-PrivacySnapshot {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Before
    )
    Remove-PrivacyModule -Context $Context
    Restore-PrivacyAndroidState -Context $Context -Before $Before
    Assert-PrivacySnapshotRestored -Context $Context -Before $Before
}

function Invoke-NoteAir5CPrivacyHome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$AcknowledgePrivacyChanges,
        [switch]$NonInteractive
    )
    Confirm-PrivacyChange -Phrase 'CLEAN HOME NOTEAIR5C' -Description 'This backs up and normalizes the BOOX launcher home layout.' -Acknowledged:$AcknowledgePrivacyChanges -NonInteractive:$NonInteractive
    $context = Assert-PrivacyTarget $ProjectRoot
    $backup = Backup-PrivacyHomeLayout -ProjectRoot $ProjectRoot -Context $context
    $applied = Set-PrivacyCleanHomeLayout -ProjectRoot $ProjectRoot -Context $context -Backup $backup
    $moduleProbe = Invoke-PrivacyRootShell -Target $context.Target -Command 'test -e /data/adb/modules/boox-privacy/module.prop && echo present || true' -AllowFailure
    if ($moduleProbe.Output.Trim() -eq 'present') {
        $policy = Get-PrivacyPolicy $ProjectRoot
        foreach ($setting in @($policy.settings)) {
            Set-PrivacyAndroidSetting -Target $context.Target -Namespace $setting.namespace -Name $setting.name -Value $setting.value
        }
    }
    $record = [pscustomobject]@{
        schemaVersion = 1
        serial = $context.Target.Serial
        fingerprint = $context.Fingerprint
        backup = $backup
        applied = $applied
    }
    $manifestPath = Join-Path (Split-Path -Parent ([string]$backup.snapshotPath)) 'home-layout.json'
    Save-PrivacyJson -Value $record -Path $manifestPath
    Write-Host 'Clean home layout applied: Tools folder, Play Store + Magisk, Storage + Settings dock.' -ForegroundColor Green
    Write-Host "Launcher backup and manifest: $manifestPath" -ForegroundColor Green
    $record
}

function Wait-PrivacyAndroidBoot {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Serial,
        [int]$TimeoutSeconds = 300
    )
    $adb = Get-PrivacyAdbPath $ProjectRoot
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Invoke-PrivacyNative -FilePath $adb -Arguments @('-s', $Serial, 'get-state') -AllowFailure
        if ($state.ExitCode -eq 0 -and $state.Output.Trim() -eq 'device') {
            $boot = Invoke-PrivacyNative -FilePath $adb -Arguments @('-s', $Serial, 'shell', 'getprop', 'sys.boot_completed') -AllowFailure
            $packageManager = Invoke-PrivacyNative -FilePath $adb -Arguments @('-s', $Serial, 'shell', 'pm', 'path', 'com.onyx') -AllowFailure
            if ($boot.Output.Trim() -eq '1' -and $packageManager.Output -match '^package:') { return }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The Note Air 5C did not reconnect and finish Android startup within $TimeoutSeconds seconds."
}

function Invoke-NoteAir5CPrivacyHarden {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateSet('Balanced', 'Purge', 'Lockdown', 'Strict')][string]$Profile = 'Balanced',
        [switch]$AcknowledgePrivacyChanges,
        [switch]$RebootDevice,
        [switch]$NonInteractive
    )
    [void](Test-PrivacyPolicy $ProjectRoot)
    Confirm-PrivacyChange -Phrase 'HARDEN NOTEAIR5C' -Description 'This installs a Magisk firewall module, changes connectivity endpoints, and removes optional packages for user 0.' -Acknowledged:$AcknowledgePrivacyChanges -NonInteractive:$NonInteractive
    $context = Assert-PrivacyTarget $ProjectRoot
    $policy = Get-PrivacyPolicy $ProjectRoot
    $profileKey = $Profile.ToLowerInvariant()
    $selected = $policy.profiles.$profileKey
    if (-not $selected) { throw "Privacy profile not found: $Profile" }
    $homeLayoutBackup = $null
    if ($Profile -in @('Purge', 'Lockdown')) {
        $homeLayoutBackup = Backup-PrivacyHomeLayout -ProjectRoot $ProjectRoot -Context $context
    }
    $before = [pscustomobject]@{
        settings = @($policy.settings | ForEach-Object { Get-PrivacySettingState -Target $context.Target -Namespace $_.namespace -Name $_.name })
        packages = @($selected.packages | ForEach-Object { Get-PrivacyPackageState -Target $context.Target -Id $_.id })
    }
    $record = [ordered]@{
        schemaVersion = 1
        status = 'Applying'
        profile = $Profile
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        completedAtUtc = $null
        restoredAtUtc = $null
        failure = $null
        rollbackError = $null
        serial = $context.Target.Serial
        fingerprint = $context.Fingerprint
        runPath = $context.RunPath
        description = [string]$selected.description
        purgedPaths = @()
        homeLayout = $homeLayoutBackup
        before = $before
    }
    $recordPath = Join-Path (Join-Path $context.RunPath 'privacy') ("hardening-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    Save-PrivacyJson -Value $record -Path $recordPath
    try {
        $purgeIds = if ($selected.PSObject.Properties['systemlessPurgePackages']) { @($selected.systemlessPurgePackages) } else { @() }
        $purgeStates = @($before.packages | Where-Object { [string]$_.id -in $purgeIds })
        $record.purgedPaths = @(Install-PrivacyModule -ProjectRoot $ProjectRoot -Context $context -Profile $Profile -SystemlessPurgeStates $purgeStates)
        foreach ($setting in @($policy.settings)) {
            Set-PrivacyAndroidSetting -Target $context.Target -Namespace $setting.namespace -Name $setting.name -Value $setting.value
        }
        foreach ($package in @($selected.packages)) { Set-PrivacyPackageAction -Target $context.Target -Package $package }
        if ($homeLayoutBackup) {
            $homeLayoutApplied = Set-PrivacyCleanHomeLayout -ProjectRoot $ProjectRoot -Context $context -Backup $homeLayoutBackup
            $homeLayoutBackup | Add-Member -NotePropertyName applied -NotePropertyValue $homeLayoutApplied -Force
            $record.homeLayout = $homeLayoutBackup
            foreach ($setting in @($policy.settings)) {
                Set-PrivacyAndroidSetting -Target $context.Target -Namespace $setting.namespace -Name $setting.name -Value $setting.value
            }
        }
        $record.status = 'Applied'
        $record.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        Save-PrivacyJson -Value $record -Path $recordPath
    } catch {
        $failure = $_.Exception.Message
        try {
            Restore-PrivacySnapshot -Context $context -Before $before
            if ($homeLayoutBackup) { Restore-PrivacyHomeLayout -ProjectRoot $ProjectRoot -Context $context -Backup $homeLayoutBackup }
            $record.status = 'RolledBack'
        }
        catch { $record.status = 'RollbackFailed'; $record.rollbackError = $_.Exception.Message }
        $record.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        $record.failure = $failure
        Save-PrivacyJson -Value $record -Path $recordPath
        throw "Privacy hardening failed; rollback status is $($record.status). $failure"
    }
    Write-Host "Privacy profile '$Profile' applied and verified. Recovery record: $recordPath" -ForegroundColor Green
    Write-Host 'A reboot is required to activate the systemless hostname block.' -ForegroundColor Yellow
    if ($RebootDevice) {
        Invoke-PrivacyAdb -Target $context.Target -Arguments @('reboot') | Out-Null
        Write-Host 'The BOOX is rebooting with the privacy module active.' -ForegroundColor Green
    }
    [pscustomobject]$record
}

function Get-LatestPrivacyRecord {
    param([Parameter(Mandatory)][string]$PrivacyRoot)
    foreach ($file in @(Get-ChildItem -LiteralPath $PrivacyRoot -Filter 'hardening-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        try { $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($record.status -in @('Applied', 'RestorePendingReboot')) { return [pscustomobject]@{ Path = $file.FullName; Record = $record } }
    }
    $null
}

function Invoke-NoteAir5CPrivacyRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$AcknowledgePrivacyRestore,
        [switch]$RebootDevice,
        [switch]$NonInteractive
    )
    Confirm-PrivacyChange -Phrase 'RESTORE PRIVACY' -Description 'This removes the BOOX privacy firewall and restores the exact recorded package/settings state.' -Acknowledged:$AcknowledgePrivacyRestore -NonInteractive:$NonInteractive
    $context = Assert-PrivacyTarget $ProjectRoot
    $latest = Get-LatestPrivacyRecord -PrivacyRoot (Join-Path $context.RunPath 'privacy')
    if (-not $latest) { throw 'No applied privacy-hardening record is available for this rooted run.' }
    $record = $latest.Record
    if ([string]$record.serial -ne $context.Target.Serial -or [string]$record.fingerprint -ne $context.Fingerprint) {
        throw 'The privacy recovery record does not match the connected serial and firmware.'
    }
    $hasSystemlessPurge = $record.PSObject.Properties['purgedPaths'] -and @($record.purgedPaths).Count -gt 0
    if ($hasSystemlessPurge -and -not $RebootDevice) {
        throw 'Restoring a systemless purge requires -RebootDevice so Android can see the factory APKs again. Nothing was changed.'
    }
    if ($hasSystemlessPurge) {
        Remove-PrivacyModule -Context $context
        $record.status = 'RestorePendingReboot'
        Save-PrivacyJson -Value $record -Path $latest.Path
        Write-Host 'The Magisk purge overlay is removed. Rebooting to reveal the factory APKs...' -ForegroundColor Yellow
        Invoke-PrivacyAdb -Target $context.Target -Arguments @('reboot') | Out-Null
        Wait-PrivacyAndroidBoot -ProjectRoot $ProjectRoot -Serial $context.Target.Serial
        Start-Sleep -Seconds 35
        $context = Assert-PrivacyTarget $ProjectRoot
        Restore-PrivacyAndroidState -Context $context -Before $record.before
        Assert-PrivacySnapshotRestored -Context $context -Before $record.before
    } else {
        Restore-PrivacySnapshot -Context $context -Before $record.before
    }
    $hasHomeLayout = $record.PSObject.Properties['homeLayout'] -and $null -ne $record.homeLayout
    if ($hasHomeLayout) {
        Restore-PrivacyHomeLayout -ProjectRoot $ProjectRoot -Context $context -Backup $record.homeLayout
    }
    $record.status = 'Restored'
    $record.restoredAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-PrivacyJson -Value $record -Path $latest.Path
    Write-Host "Privacy hardening restored from $($latest.Path)" -ForegroundColor Green
    if (-not $hasSystemlessPurge) {
        Write-Host 'A reboot is required to remove the systemless hostname overlay.' -ForegroundColor Yellow
    }
    if ($RebootDevice -and -not $hasSystemlessPurge) {
        Invoke-PrivacyAdb -Target $context.Target -Arguments @('reboot') | Out-Null
        Write-Host 'The BOOX is rebooting with the prior privacy/package state restored.' -ForegroundColor Green
    } elseif ($hasSystemlessPurge) {
        Write-Host 'The BOOX rebooted and the exact prior package/settings state was verified.' -ForegroundColor Green
    }
    $record
}

Export-ModuleMember -Function @(
    'Get-PrivacyPolicy',
    'Test-PrivacyPolicy',
    'Invoke-NoteAir5CPrivacyAudit',
    'Invoke-NoteAir5CPrivacyHome',
    'Invoke-NoteAir5CPrivacyHarden',
    'Invoke-NoteAir5CPrivacyRestore'
)
