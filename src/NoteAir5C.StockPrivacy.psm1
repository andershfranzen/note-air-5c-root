Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-StockPrivacyNative {
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

function Get-StockPrivacyPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = Join-Path $ProjectRoot 'config/stock-privacy-policy.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Stock privacy policy is missing: $path" }
    $policy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$policy.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$policy.id)) { throw 'Unsupported stock privacy policy schema.' }
    $ids = @($policy.packages.id)
    if ($ids.Count -ne @($ids | Sort-Object -Unique).Count) { throw 'Stock privacy package IDs must be unique.' }
    foreach ($package in @($policy.packages)) {
        if ([string]$package.id -notmatch '^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+$') { throw "Unsafe package ID in stock privacy policy: $($package.id)" }
        if ([string]$package.action -notin @('uninstall-user', 'disable-user')) { throw "Unsafe package action in stock privacy policy: $($package.action)" }
    }
    if (@($policy.protectedPackages | Where-Object { $_ -in $ids }).Count) { throw 'Stock privacy policy targets a protected package.' }
    $policy
}

function Get-StockPrivacyAdbPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $platform = Get-HostPlatform
    $suffix = if ($platform -eq 'windows') { '.exe' } else { '' }
    $adb = Join-Path (Join-Path (Get-AndroidToolsDirectory -ProjectRoot $ProjectRoot -Platform $platform) 'platform-tools') "adb$suffix"
    if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) { throw 'Android platform tools are missing. Run Setup first.' }
    $adb
}

function Get-StockPrivacyTarget {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $adb = Get-StockPrivacyAdbPath $ProjectRoot
    $devices = Invoke-StockPrivacyNative -FilePath $adb -Arguments @('devices', '-l')
    $matches = @($devices.Lines | Where-Object { $_ -match '^([^\s]+)\s+device\b' -and $_ -match '(?:product|model|device):NoteAir5C\b' })
    if ($matches.Count -ne 1) { throw "Expected exactly one authorized stock Note Air 5C; found $($matches.Count)." }
    if ($matches[0] -notmatch '^([^\s]+)\s+') { throw 'Could not parse the Note Air 5C ADB serial.' }
    [pscustomobject]@{ Adb = $adb; Serial = $Matches[1] }
}

function Invoke-StockPrivacyAdb {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    Invoke-StockPrivacyNative -FilePath $Target.Adb -Arguments (@('-s', $Target.Serial) + $Arguments) -AllowFailure:$AllowFailure -Live:$Live
}

function Invoke-StockPrivacyShell {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    Invoke-StockPrivacyAdb -Target $Target -Arguments (@('shell') + $Arguments) -AllowFailure:$AllowFailure -Live:$Live
}

function Get-StockPrivacyPackageState {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+$') { throw "Unsafe package ID: $Id" }
    $dump = Invoke-StockPrivacyShell -Target $Target -Arguments @('dumpsys', 'package', $Id) -AllowFailure
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

function Get-StockPrivacySettingState {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Name)
    if ($Namespace -notin @('global', 'secure', 'system') -or $Name -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Unsafe Android setting identifier.' }
    $result = Invoke-StockPrivacyShell -Target $Target -Arguments @('settings', 'get', $Namespace, $Name) -AllowFailure
    $value = $result.Output.Trim()
    [pscustomobject]@{ namespace = $Namespace; name = $Name; exists = ($result.ExitCode -eq 0 -and $value -ne 'null'); value = $(if ($value -eq 'null') { $null } else { $value }) }
}

function Set-StockPrivacySetting {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    if ($Namespace -notin @('global', 'secure', 'system') -or $Name -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Unsafe Android setting identifier.' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    $command = "value=`$(echo $encoded | base64 -d); settings put $Namespace $Name `"`$value`""
    $result = Invoke-StockPrivacyAdb -Target $Target -Arguments @('shell', $command) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "Failed to set Android setting $Namespace/$Name`: $($result.Output)" }
    $current = Get-StockPrivacySettingState -Target $Target -Namespace $Namespace -Name $Name
    if (-not $current.exists -or [string]$current.value -ne $Value) { throw "Android setting did not verify: $Namespace/$Name" }
}

function Remove-StockPrivacySetting {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Name)
    $result = Invoke-StockPrivacyShell -Target $Target -Arguments @('settings', 'delete', $Namespace, $Name) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "Failed to delete Android setting $Namespace/$Name`: $($result.Output)" }
}

function Test-StockPrivacyFirmware {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Fingerprint)
    $profiles = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/firmware-profiles.json') -Raw | ConvertFrom-Json
    @($profiles.profiles | Where-Object { $_.model -eq 'NoteAir5C' -and $Fingerprint -match $_.fingerprintPattern }).Count -eq 1
}

function Assert-StockPrivacyTarget {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $target = Get-StockPrivacyTarget $ProjectRoot
    $model = (Invoke-StockPrivacyShell -Target $target -Arguments @('getprop', 'ro.product.model')).Output.Trim()
    $fingerprint = (Invoke-StockPrivacyShell -Target $target -Arguments @('getprop', 'ro.vendor.build.fingerprint')).Output.Trim()
    $locked = (Invoke-StockPrivacyShell -Target $target -Arguments @('getprop', 'ro.boot.flash.locked')).Output.Trim()
    $verified = (Invoke-StockPrivacyShell -Target $target -Arguments @('getprop', 'ro.boot.verifiedbootstate')).Output.Trim()
    if ($model -ne 'NoteAir5C') { throw "Refusing non-NoteAir5C model '$model'." }
    if (-not (Test-StockPrivacyFirmware -ProjectRoot $ProjectRoot -Fingerprint $fingerprint)) { throw "Stock privacy refuses unknown firmware '$fingerprint'." }
    if ($locked -ne '1' -or $verified -ne 'green') { throw "Stock privacy requires locked/green verified boot; found locked='$locked', state='$verified'." }
    $magisk = Invoke-StockPrivacyShell -Target $target -Arguments @('magisk', '-v') -AllowFailure
    $root = Invoke-StockPrivacyShell -Target $target -Arguments @('su', '-c', 'id') -AllowFailure
    if ($magisk.ExitCode -eq 0 -or $root.Output -match 'uid=0\(root\)') { throw 'Stock privacy refuses a rooted tablet. Return fully to stock first.' }
    [pscustomobject]@{ Target = $target; Model = $model; Fingerprint = $fingerprint; FlashLocked = $locked; VerifiedBootState = $verified; RootAbsent = $true }
}

function Save-StockPrivacyJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $directory = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-StockPrivacyRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    Join-Path $ProjectRoot 'runs/stock-privacy'
}

function Get-LatestStockPrivacyRecord {
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Status = 'Applied')
    $root = Get-StockPrivacyRoot $ProjectRoot
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'change-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        try { $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ([string]$record.status -eq $Status) { return [pscustomobject]@{ Path = $file.FullName; Record = $record } }
    }
    $null
}

function Confirm-StockPrivacyChange {
    param([Parameter(Mandatory)][string]$Phrase, [Parameter(Mandatory)][string]$Description, [switch]$Acknowledged, [switch]$NonInteractive)
    if ($Acknowledged) { return }
    if ($NonInteractive) { throw "Non-interactive stock privacy changes require explicit acknowledgement for '$Phrase'." }
    Write-Warning $Description
    if ((Read-Host "Type $Phrase to continue") -cne $Phrase) { throw 'Stock privacy change cancelled; confirmation phrase did not match.' }
}

function Get-StockPrivacySnapshot {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Policy)
    [pscustomobject]@{
        packages = @($Policy.packages | ForEach-Object { Get-StockPrivacyPackageState -Target $Context.Target -Id ([string]$_.id) })
        protectedPackages = @($Policy.protectedPackages | ForEach-Object { Get-StockPrivacyPackageState -Target $Context.Target -Id ([string]$_) })
        settings = @($Policy.settings | ForEach-Object { Get-StockPrivacySettingState -Target $Context.Target -Namespace ([string]$_.namespace) -Name ([string]$_.name) })
        vpn = @(
            Get-StockPrivacySettingState -Target $Context.Target -Namespace secure -Name 'always_on_vpn_app'
            Get-StockPrivacySettingState -Target $Context.Target -Namespace secure -Name 'always_on_vpn_lockdown'
        )
    }
}

function Set-StockPrivacyPackageAction {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Package)
    $before = Get-StockPrivacyPackageState -Target $Target -Id ([string]$Package.id)
    if (-not $before.exists -or -not $before.installed) { return }
    $result = switch ([string]$Package.action) {
        'uninstall-user' { Invoke-StockPrivacyShell -Target $Target -Arguments @('pm', 'uninstall', '--user', '0', [string]$Package.id) -AllowFailure }
        'disable-user' { Invoke-StockPrivacyShell -Target $Target -Arguments @('pm', 'disable-user', '--user', '0', [string]$Package.id) -AllowFailure }
    }
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'Success|disabled-user') { throw "Package action failed for $($Package.id): $($result.Output)" }
    Write-Host "  $($Package.action): $($Package.id)" -ForegroundColor Green
}

function Restore-StockPrivacySnapshot {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Before)
    foreach ($setting in @(@($Before.settings) + @($Before.vpn))) {
        if ($setting.exists) { Set-StockPrivacySetting -Target $Context.Target -Namespace $setting.namespace -Name $setting.name -Value ([string]$setting.value) }
        else { Remove-StockPrivacySetting -Target $Context.Target -Namespace $setting.namespace -Name $setting.name }
    }
    foreach ($package in @($Before.packages)) {
        if (-not $package.exists) { continue }
        if ($package.installed) {
            $install = Invoke-StockPrivacyShell -Target $Context.Target -Arguments @('cmd', 'package', 'install-existing', '--user', '0', [string]$package.id) -AllowFailure
            if ($install.ExitCode -ne 0) { throw "Could not restore package $($package.id): $($install.Output)" }
            if ([int]$package.enabled -eq 3) {
                Invoke-StockPrivacyShell -Target $Context.Target -Arguments @('pm', 'disable-user', '--user', '0', [string]$package.id) | Out-Null
            } else {
                Invoke-StockPrivacyShell -Target $Context.Target -Arguments @('pm', 'default-state', '--user', '0', [string]$package.id) | Out-Null
            }
        } else {
            Invoke-StockPrivacyShell -Target $Context.Target -Arguments @('pm', 'uninstall', '--user', '0', [string]$package.id) -AllowFailure | Out-Null
        }
    }
}

function Assert-StockPrivacyApplied {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Policy)
    foreach ($package in @($Policy.packages)) {
        $current = Get-StockPrivacyPackageState -Target $Context.Target -Id ([string]$package.id)
        if ($package.action -eq 'uninstall-user' -and $current.installed) { throw "Package remains installed for user 0: $($package.id)" }
        if ($package.action -eq 'disable-user' -and $current.enabled -ne 3) { throw "Package did not enter disabled-user state: $($package.id)" }
    }
    foreach ($packageId in @($Policy.protectedPackages)) {
        $current = Get-StockPrivacyPackageState -Target $Context.Target -Id ([string]$packageId)
        if (-not $current.exists -or -not $current.installed -or $current.enabled -eq 3) { throw "Protected package was not preserved: $packageId" }
    }
    foreach ($setting in @($Policy.settings)) {
        $current = Get-StockPrivacySettingState -Target $Context.Target -Namespace $setting.namespace -Name $setting.name
        if (-not $current.exists -or [string]$current.value -ne [string]$setting.value) { throw "Connectivity setting did not verify: $($setting.name)" }
    }
}

function Assert-StockPrivacyRestored {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Before)
    foreach ($setting in @(@($Before.settings) + @($Before.vpn))) {
        $current = Get-StockPrivacySettingState -Target $Context.Target -Namespace $setting.namespace -Name $setting.name
        if ([bool]$current.exists -ne [bool]$setting.exists -or ($setting.exists -and [string]$current.value -ne [string]$setting.value)) { throw "Setting did not restore: $($setting.name)" }
    }
    foreach ($package in @($Before.packages)) {
        if (-not $package.exists) { continue }
        $current = Get-StockPrivacyPackageState -Target $Context.Target -Id ([string]$package.id)
        if ([bool]$current.installed -ne [bool]$package.installed -or ($package.installed -and [int]$current.enabled -ne [int]$package.enabled)) { throw "Package did not restore: $($package.id)" }
    }
}

function Write-StockPrivacyBlocklists {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Directory)
    $networkPolicy = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/privacy-policy.json') -Raw | ConvertFrom-Json
    [void](New-Item -ItemType Directory -Path $Directory -Force)
    $plainPath = Join-Path $Directory 'boox-domains.txt'
    $adblockPath = Join-Path $Directory 'boox-adblock.txt'
    $ipPath = Join-Path $Directory 'boox-ipv4.txt'
    @($networkPolicy.blockedHosts | Sort-Object -Unique) | Set-Content -LiteralPath $plainPath -Encoding utf8
    @($networkPolicy.blockedHosts | Sort-Object -Unique | ForEach-Object { "||$_^" }) | Set-Content -LiteralPath $adblockPath -Encoding utf8
    @($networkPolicy.blockedIpv4 | Sort-Object -Unique) | Set-Content -LiteralPath $ipPath -Encoding utf8
    [pscustomobject]@{ Domains = $plainPath; Adblock = $adblockPath; Ipv4 = $ipPath }
}

function Invoke-NoteAir5CStockPrivacyAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$NonInteractive)
    $context = Assert-StockPrivacyTarget $ProjectRoot
    $policy = Get-StockPrivacyPolicy $ProjectRoot
    $snapshot = Get-StockPrivacySnapshot -Context $context -Policy $policy
    $record = [pscustomobject]@{
        schemaVersion = 1
        type = 'StockPrivacyAudit'
        atUtc = [DateTime]::UtcNow.ToString('o')
        serial = $context.Target.Serial
        model = $context.Model
        fingerprint = $context.Fingerprint
        flashLocked = $context.FlashLocked
        verifiedBootState = $context.VerifiedBootState
        rootAbsent = $context.RootAbsent
        snapshot = $snapshot
    }
    $path = Join-Path (Get-StockPrivacyRoot $ProjectRoot) ("audit-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Save-StockPrivacyJson -Value $record -Path $path
    Write-Host "Stock privacy audit saved: $path" -ForegroundColor Green
    $record
}

function Invoke-NoteAir5CStockPrivacyApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$AcknowledgeStockPrivacy,
        [switch]$NonInteractive
    )
    Confirm-StockPrivacyChange -Phrase 'APPLY STOCK PRIVACY' -Description 'This reversibly removes optional BOOX packages, disables BOOX Cloud sync, and replaces vendor NTP/connectivity endpoints.' -Acknowledged:$AcknowledgeStockPrivacy -NonInteractive:$NonInteractive
    $context = Assert-StockPrivacyTarget $ProjectRoot
    $existing = Get-LatestStockPrivacyRecord -ProjectRoot $ProjectRoot
    if ($existing -and [string]$existing.Record.serial -eq $context.Target.Serial -and [string]$existing.Record.fingerprint -eq $context.Fingerprint) { throw "Stock privacy is already applied. Restore it before creating another snapshot: $($existing.Path)" }
    $policy = Get-StockPrivacyPolicy $ProjectRoot
    $before = Get-StockPrivacySnapshot -Context $context -Policy $policy
    $recordPath = Join-Path (Get-StockPrivacyRoot $ProjectRoot) ("change-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $context.Target.Serial)
    $artifactDirectory = Join-Path (Split-Path -Parent $recordPath) ([IO.Path]::GetFileNameWithoutExtension($recordPath))
    $record = [pscustomobject]@{
        schemaVersion = 1
        status = 'Applying'
        profile = $policy.id
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        completedAtUtc = $null
        restoredAtUtc = $null
        failure = $null
        rollbackError = $null
        serial = $context.Target.Serial
        fingerprint = $context.Fingerprint
        before = $before
        blocklists = $null
    }
    Save-StockPrivacyJson -Value $record -Path $recordPath
    try {
        foreach ($package in @($policy.packages)) { Set-StockPrivacyPackageAction -Target $context.Target -Package $package }
        foreach ($setting in @($policy.settings)) { Set-StockPrivacySetting -Target $context.Target -Namespace $setting.namespace -Name $setting.name -Value ([string]$setting.value) }
        Assert-StockPrivacyApplied -Context $context -Policy $policy
        $record.blocklists = Write-StockPrivacyBlocklists -ProjectRoot $ProjectRoot -Directory $artifactDirectory
        $record.status = 'Applied'
        $record.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        Save-StockPrivacyJson -Value $record -Path $recordPath
    } catch {
        $record.failure = $_.Exception.Message
        try {
            Restore-StockPrivacySnapshot -Context $context -Before $before
            Assert-StockPrivacyRestored -Context $context -Before $before
            $record.status = 'RolledBack'
        } catch {
            $record.status = 'RollbackFailed'
            $record.rollbackError = $_.Exception.Message
        }
        $record.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        Save-StockPrivacyJson -Value $record -Path $recordPath
        throw "Stock privacy apply failed; recovery status is $($record.status). $($record.failure)"
    }
    Write-Host "Stock privacy applied and verified. Recovery record: $recordPath" -ForegroundColor Green
    Write-Host "DNS/router blocklists: $artifactDirectory" -ForegroundColor Cyan
    $record
}

function Invoke-NoteAir5CStockPrivacyRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$AcknowledgeStockPrivacyRestore,
        [switch]$NonInteractive
    )
    Confirm-StockPrivacyChange -Phrase 'RESTORE STOCK PRIVACY' -Description 'This restores the exact recorded package and connectivity-setting state without changing boot integrity.' -Acknowledged:$AcknowledgeStockPrivacyRestore -NonInteractive:$NonInteractive
    $context = Assert-StockPrivacyTarget $ProjectRoot
    $latest = Get-LatestStockPrivacyRecord -ProjectRoot $ProjectRoot
    if (-not $latest) { throw 'No applied stock-privacy recovery record exists.' }
    if ([string]$latest.Record.serial -ne $context.Target.Serial -or [string]$latest.Record.fingerprint -ne $context.Fingerprint) { throw 'Stock privacy recovery record does not match this serial and firmware.' }
    Restore-StockPrivacySnapshot -Context $context -Before $latest.Record.before
    Assert-StockPrivacyRestored -Context $context -Before $latest.Record.before
    if ($latest.Record.PSObject.Properties['firewall'] -and $latest.Record.firewall.installedByAssistant) {
        $packageId = [string]$latest.Record.firewall.packageId
        $remove = Invoke-StockPrivacyShell -Target $context.Target -Arguments @('pm', 'uninstall', '--user', '0', $packageId) -AllowFailure
        if ($remove.ExitCode -ne 0 -or $remove.Output -notmatch 'Success') { throw "Could not remove the rootless firewall installed by this run: $($remove.Output)" }
    }
    $latest.Record.status = 'Restored'
    $latest.Record.restoredAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-StockPrivacyJson -Value $latest.Record -Path $latest.Path
    Write-Host "Stock privacy state restored from $($latest.Path)" -ForegroundColor Green
    $latest.Record
}

function Invoke-NoteAir5CStockPrivacyFirewall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$InstallFirewall,
        [switch]$NonInteractive
    )
    $context = Assert-StockPrivacyTarget $ProjectRoot
    $policy = Get-StockPrivacyPolicy $ProjectRoot
    $packageId = [string]$policy.firewall.packageId
    $state = Get-StockPrivacyPackageState -Target $context.Target -Id $packageId
    $installedByAssistant = $false
    if (-not $state.installed -and $InstallFirewall) {
        if ((Invoke-StockPrivacyShell -Target $context.Target -Arguments @('getprop', 'ro.product.cpu.abi')).Output.Trim() -ne 'arm64-v8a') { throw 'The pinned firewall APK is only approved for the Note Air 5C arm64-v8a ABI.' }
        $cache = Join-Path $ProjectRoot '.cache/stock-privacy'
        [void](New-Item -ItemType Directory -Path $cache -Force)
        $apk = Join-Path $cache "rethink-$($policy.firewall.release)-arm64-v8a.apk"
        $expectedBytes = [long]$policy.firewall.assetBytes
        $expectedHash = ([string]$policy.firewall.assetSha256).ToLowerInvariant()
        $valid = $false
        if (Test-Path -LiteralPath $apk -PathType Leaf) {
            $item = Get-Item -LiteralPath $apk
            $valid = $item.Length -eq $expectedBytes -and (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedHash
        }
        if (-not $valid) {
            $partial = "$apk.partial"
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            Invoke-WebRequest -Uri ([string]$policy.firewall.assetUrl) -OutFile $partial -UseBasicParsing
            $item = Get-Item -LiteralPath $partial
            $actualHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($item.Length -ne $expectedBytes -or $actualHash -ne $expectedHash) {
                Remove-Item -LiteralPath $partial -Force
                throw "Pinned Rethink APK verification failed. Expected $expectedBytes bytes/$expectedHash; received $($item.Length) bytes/$actualHash."
            }
            Move-Item -LiteralPath $partial -Destination $apk -Force
        }
        $install = Invoke-StockPrivacyAdb -Target $context.Target -Arguments @('install', '-r', $apk) -AllowFailure -Live
        if ($install.ExitCode -ne 0 -or $install.Output -notmatch 'Success') { throw "Verified Rethink APK installation failed: $($install.Output)" }
        $state = Get-StockPrivacyPackageState -Target $context.Target -Id $packageId
        if (-not $state.installed) { throw 'Rethink installation returned success but the package is not installed for user 0.' }
        $installedByAssistant = $true
        Write-Host "Installed verified Rethink $($policy.firewall.release) from the official GitHub release ($expectedHash)." -ForegroundColor Green
    }
    if (-not $state.installed) {
        Invoke-StockPrivacyShell -Target $context.Target -Arguments @('am', 'start', '-a', 'android.intent.action.VIEW', '-d', [string]$policy.firewall.playStoreUri, '-p', 'com.android.vending') | Out-Null
        Write-Host 'Rethink DNS + Firewall is open in Google Play. Android requires you to approve installation and the VPN consent dialog on the tablet.' -ForegroundColor Yellow
    } else {
        Invoke-StockPrivacyShell -Target $context.Target -Arguments @('monkey', '-p', $packageId, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
        Write-Host 'Rethink DNS + Firewall opened on the tablet.' -ForegroundColor Green
    }
    $latest = Get-LatestStockPrivacyRecord -ProjectRoot $ProjectRoot
    if ($latest -and $installedByAssistant) {
        $firewallRecord = [pscustomobject]@{ packageId = $packageId; installedByAssistant = $true; release = [string]$policy.firewall.release; assetSha256 = [string]$policy.firewall.assetSha256 }
        $latest.Record | Add-Member -NotePropertyName firewall -NotePropertyValue $firewallRecord -Force
        Save-StockPrivacyJson -Value $latest.Record -Path $latest.Path
    }
    [pscustomobject]@{
        PackageId = $packageId
        Installed = [bool]$state.installed
        VpnConsentRequired = $true
        BlocklistDirectory = $(if ($latest) { Split-Path -Parent ([string]$latest.Record.blocklists.Domains) } else { $null })
        BlockedPackages = @($policy.firewall.blockedPackages)
        OnDeviceDomainExclusions = @($policy.firewall.onDeviceDomainExclusions)
        Warning = 'Do not block com.onyx or any shared UID 1000 group. Allow Google Play, Play Services, Company Portal, Authenticator, Outlook, and any employer VPN.'
    }
}

function Invoke-NoteAir5CStockPrivacyVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$NonInteractive
    )
    $context = Assert-StockPrivacyTarget $ProjectRoot
    $policy = Get-StockPrivacyPolicy $ProjectRoot
    $latest = Get-LatestStockPrivacyRecord -ProjectRoot $ProjectRoot
    if (-not $latest) { throw 'No applied stock-privacy recovery record exists.' }
    if ([string]$latest.Record.serial -ne $context.Target.Serial -or [string]$latest.Record.fingerprint -ne $context.Fingerprint) { throw 'Stock privacy recovery record does not match this serial and firmware.' }

    Assert-StockPrivacyApplied -Context $context -Policy $policy
    $packageId = [string]$policy.firewall.packageId
    $firewall = Get-StockPrivacyPackageState -Target $context.Target -Id $packageId
    if (-not $firewall.installed) { throw "Rootless firewall is not installed: $packageId" }
    if ([string]$firewall.version -ne [string]$policy.firewall.release) { throw "Unexpected Rethink version '$($firewall.version)'; expected '$($policy.firewall.release)'." }

    $alwaysOn = Get-StockPrivacySettingState -Target $context.Target -Namespace secure -Name 'always_on_vpn_app'
    $lockdown = Get-StockPrivacySettingState -Target $context.Target -Namespace secure -Name 'always_on_vpn_lockdown'
    if (-not $alwaysOn.exists -or [string]$alwaysOn.value -ne $packageId) { throw 'Rethink is not configured as Android Always-on VPN.' }
    if (-not $lockdown.exists -or [string]$lockdown.value -ne '1') { throw 'Android Block connections without VPN is not enabled.' }

    $connectivity = Invoke-StockPrivacyShell -Target $context.Target -Arguments @('dumpsys', 'connectivity')
    $vpnLine = @($connectivity.Lines | Where-Object { $_ -match "VPN CONNECTED extra: VPN:$([regex]::Escape($packageId))" } | Select-Object -First 1)
    if ($vpnLine.Count -ne 1) { throw 'Rethink VPN is not connected.' }
    if ($vpnLine[0] -notmatch 'IS_VALIDATED' -or $vpnLine[0] -notmatch 'bypassable=false') { throw 'Rethink VPN is connected but is not both validated and non-bypassable.' }

    $networkPolicy = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/privacy-policy.json') -Raw | ConvertFrom-Json
    $excludedHosts = @($policy.firewall.onDeviceDomainExclusions.host)
    $expectedDomains = @($networkPolicy.blockedHosts | Where-Object { $_ -notin $excludedHosts } | Sort-Object -Unique)
    $expectedIpv4 = @($networkPolicy.blockedIpv4 | Sort-Object -Unique)
    $result = [pscustomobject]@{
        VerifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        Serial = $context.Target.Serial
        Fingerprint = $context.Fingerprint
        FlashLocked = $context.FlashLocked
        VerifiedBootState = $context.VerifiedBootState
        RootAbsent = $context.RootAbsent
        PolicyApplied = $true
        FirewallPackage = $packageId
        FirewallVersion = $firewall.version
        AlwaysOnVpn = $true
        Lockdown = $true
        VpnConnected = $true
        VpnValidated = $true
        VpnBypassable = $false
        ExpectedOnDeviceDomainRules = $expectedDomains.Count
        ExpectedIpv4Rules = $expectedIpv4.Count
        ExpectedBlockedPackages = @($policy.firewall.blockedPackages).Count
        PrivateRuleAudit = 'Android app sandboxing prevents ADB from reading Rethink private rules. Confirm these three counts in Rethink after imports or edits.'
    }
    $latest.Record | Add-Member -NotePropertyName verification -NotePropertyValue $result -Force
    Save-StockPrivacyJson -Value $latest.Record -Path $latest.Path
    Write-Host 'Stock privacy verification passed: locked/green/no root, policy applied, and validated non-bypassable VPN.' -ForegroundColor Green
    Write-Host "Rethink UI target counts: $($result.ExpectedOnDeviceDomainRules) domains, $($result.ExpectedIpv4Rules) IPv4 rule, $($result.ExpectedBlockedPackages) BOOX apps." -ForegroundColor Cyan
    $result
}

Export-ModuleMember -Function @(
    'Get-StockPrivacyPolicy',
    'Get-StockPrivacyPackageState',
    'Test-StockPrivacyFirmware',
    'Invoke-NoteAir5CStockPrivacyAudit',
    'Invoke-NoteAir5CStockPrivacyApply',
    'Invoke-NoteAir5CStockPrivacyRestore',
    'Invoke-NoteAir5CStockPrivacyFirewall',
    'Invoke-NoteAir5CStockPrivacyVerify'
)
