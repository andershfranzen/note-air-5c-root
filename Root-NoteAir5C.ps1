[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Diagnose', 'Backup', 'Root', 'Resume', 'ReturnStock', 'Restore', 'Verify', 'Status', 'PrivacyAudit', 'PrivacyHome', 'PrivacyHarden', 'PrivacyRestore', 'StockPrivacyAudit', 'StockPrivacyApply', 'StockPrivacyFirewall', 'StockPrivacyVerify', 'StockPrivacyRestore', 'SelfTest')]
    [string]$Command = 'Diagnose',

    [string]$RunPath,

    [switch]$InstallHostDependencies,
    [switch]$AcceptCommunityArtifacts,
    [switch]$AcknowledgeDataWipe,
    [switch]$AcceptUntestedFirmware,
    [switch]$ForceEmergencyRestore,
    [ValidateSet('Balanced', 'Purge', 'Lockdown', 'Strict')][string]$PrivacyProfile = 'Balanced',
    [switch]$AcknowledgePrivacyChanges,
    [switch]$AcknowledgePrivacyRestore,
    [switch]$AcknowledgeStockPrivacy,
    [switch]$AcknowledgeStockPrivacyRestore,
    [switch]$InstallStockPrivacyFirewall,
    [switch]$RebootDevice,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/NoteAir5C.Root.psm1'
Import-Module $modulePath -Force
$privacyModulePath = Join-Path $PSScriptRoot 'src/NoteAir5C.Privacy.psm1'
Import-Module $privacyModulePath -Force
$stockPrivacyModulePath = Join-Path $PSScriptRoot 'src/NoteAir5C.StockPrivacy.psm1'
Import-Module $stockPrivacyModulePath -Force

$common = @{
    ProjectRoot = $PSScriptRoot
    NonInteractive = [bool]$NonInteractive
}

function Invoke-NoteAir5CReturnStock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [switch]$AcknowledgeDataWipe,
        [switch]$AcknowledgePrivacyRestore,
        [switch]$ForceEmergencyRestore,
        [switch]$NonInteractive
    )
    $privacyStatus = $null
    try {
        $privacyStatus = Get-NoteAir5CPrivacyStatus -ProjectRoot $PSScriptRoot -NonInteractive:$NonInteractive
    } catch {
        if (-not $ForceEmergencyRestore) { throw }
        Write-Warning "Privacy state could not be inspected because Android/root is unavailable. The mandatory factory reset after relocking removes userdata Magisk modules. $($_.Exception.Message)"
    }

    if ($privacyStatus -and $privacyStatus.RequiresRestore) {
        if (-not $privacyStatus.RecordAvailable) {
            throw 'The BOOX privacy Magisk module is present, but no matching applied recovery record exists. Refusing to remove root until the privacy state can be recovered safely.'
        }
        if ([string]$privacyStatus.RunPath -ne [string](Resolve-Path -LiteralPath $RunPath).Path) {
            throw "Privacy recovery belongs to '$($privacyStatus.RunPath)', but stock return was given '$RunPath'. Use the same rooted run for both operations."
        }
        Write-Host 'Restoring recorded privacy, package, settings, and launcher state before removing root...' -ForegroundColor Yellow
        Invoke-NoteAir5CPrivacyRestore -ProjectRoot $PSScriptRoot `
            -AcknowledgePrivacyRestore:$AcknowledgePrivacyRestore `
            -RebootDevice `
            -NonInteractive:$NonInteractive | Out-Host
    } else {
        Write-Host 'No active BOOX privacy hardening record or module needs restoration.' -ForegroundColor Green
    }

    Invoke-NoteAir5CRestore -ProjectRoot $PSScriptRoot `
        -RunPath $RunPath `
        -AcknowledgeDataWipe:$AcknowledgeDataWipe `
        -ForceEmergencyRestore:$ForceEmergencyRestore `
        -NonInteractive:$NonInteractive
}

switch ($Command) {
    'Setup' {
        Install-NoteAir5CToolchain @common `
            -InstallHostDependencies:$InstallHostDependencies `
            -AcceptCommunityArtifacts:$AcceptCommunityArtifacts
    }
    'Diagnose' {
        Invoke-NoteAir5CDiagnose @common
    }
    'Backup' {
        Invoke-NoteAir5CBackup @common `
            -RunPath $RunPath `
            -AcceptUntestedFirmware:$AcceptUntestedFirmware
    }
    'Root' {
        Invoke-NoteAir5CRoot @common `
            -RunPath $RunPath `
            -AcceptCommunityArtifacts:$AcceptCommunityArtifacts `
            -AcknowledgeDataWipe:$AcknowledgeDataWipe `
            -AcceptUntestedFirmware:$AcceptUntestedFirmware
    }
    'Resume' {
        if ([string]::IsNullOrWhiteSpace($RunPath)) {
            throw 'Resume requires -RunPath pointing to a run directory or state.json.'
        }
        Invoke-NoteAir5CRoot @common `
            -RunPath $RunPath `
            -AcceptCommunityArtifacts:$AcceptCommunityArtifacts `
            -AcknowledgeDataWipe:$AcknowledgeDataWipe `
            -AcceptUntestedFirmware:$AcceptUntestedFirmware
    }
    'Restore' {
        if ([string]::IsNullOrWhiteSpace($RunPath)) {
            throw 'Restore requires -RunPath pointing to the run whose backups should be restored.'
        }
        Invoke-NoteAir5CRestore @common `
            -RunPath $RunPath `
            -AcknowledgeDataWipe:$AcknowledgeDataWipe `
            -ForceEmergencyRestore:$ForceEmergencyRestore
    }
    'ReturnStock' {
        if ([string]::IsNullOrWhiteSpace($RunPath)) {
            throw 'ReturnStock requires -RunPath pointing to the run that created this root.'
        }
        Invoke-NoteAir5CReturnStock `
            -RunPath $RunPath `
            -AcknowledgePrivacyRestore:$AcknowledgePrivacyRestore `
            -AcknowledgeDataWipe:$AcknowledgeDataWipe `
            -ForceEmergencyRestore:$ForceEmergencyRestore `
            -NonInteractive:$NonInteractive
    }
    'Verify' {
        Invoke-NoteAir5CVerify @common -RunPath $RunPath
    }
    'Status' {
        Get-NoteAir5CStatus @common -RunPath $RunPath
    }
    'PrivacyAudit' {
        Invoke-NoteAir5CPrivacyAudit @common
    }
    'PrivacyHome' {
        Invoke-NoteAir5CPrivacyHome @common `
            -AcknowledgePrivacyChanges:$AcknowledgePrivacyChanges
    }
    'PrivacyHarden' {
        Invoke-NoteAir5CPrivacyHarden @common `
            -Profile $PrivacyProfile `
            -AcknowledgePrivacyChanges:$AcknowledgePrivacyChanges `
            -RebootDevice:$RebootDevice
    }
    'PrivacyRestore' {
        Invoke-NoteAir5CPrivacyRestore @common `
            -AcknowledgePrivacyRestore:$AcknowledgePrivacyRestore `
            -RebootDevice:$RebootDevice
    }
    'StockPrivacyAudit' {
        Invoke-NoteAir5CStockPrivacyAudit @common
    }
    'StockPrivacyApply' {
        Invoke-NoteAir5CStockPrivacyApply @common `
            -AcknowledgeStockPrivacy:$AcknowledgeStockPrivacy
    }
    'StockPrivacyFirewall' {
        Invoke-NoteAir5CStockPrivacyFirewall @common `
            -InstallFirewall:$InstallStockPrivacyFirewall
    }
    'StockPrivacyVerify' {
        Invoke-NoteAir5CStockPrivacyVerify @common
    }
    'StockPrivacyRestore' {
        Invoke-NoteAir5CStockPrivacyRestore @common `
            -AcknowledgeStockPrivacyRestore:$AcknowledgeStockPrivacyRestore
    }
    'SelfTest' {
        & (Join-Path $PSScriptRoot 'tests/Run-Tests.ps1')
    }
}
