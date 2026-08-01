[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Diagnose', 'Backup', 'Root', 'Resume', 'Restore', 'Verify', 'Status', 'PrivacyAudit', 'PrivacyHome', 'PrivacyHarden', 'PrivacyRestore', 'SelfTest')]
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
    [switch]$RebootDevice,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/NoteAir5C.Root.psm1'
Import-Module $modulePath -Force
$privacyModulePath = Join-Path $PSScriptRoot 'src/NoteAir5C.Privacy.psm1'
Import-Module $privacyModulePath -Force

$common = @{
    ProjectRoot = $PSScriptRoot
    NonInteractive = [bool]$NonInteractive
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
    'SelfTest' {
        & (Join-Path $PSScriptRoot 'tests/Run-Tests.ps1')
    }
}
