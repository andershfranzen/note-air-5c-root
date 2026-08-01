Set-StrictMode -Version Latest
$script:EdlCommit = '51e11022455d26bcf0b8305b930c474e9b3c81ad'
$script:EdlRepository = 'https://github.com/bkerler/edl.git'
$script:MinimumBatteryPercent = 50
$script:SupportedModel = 'NoteAir5C'
$script:CriticalPartitions = @(
    'abl_a', 'abl_b', 'boot_a', 'boot_b', 'vbmeta_a', 'vbmeta_b',
    'devinfo', 'frp', 'dtbo_a', 'dtbo_b', 'xbl_a', 'xbl_b',
    'modemst1', 'modemst2', 'fsg', 'persist'
)

function Get-HostPlatform {
    if ($env:NOTEAIR5C_PLATFORM_OVERRIDE) {
        $override = $env:NOTEAIR5C_PLATFORM_OVERRIDE.ToLowerInvariant()
        if ($override -notin @('windows', 'linux', 'darwin')) { throw "Invalid NOTEAIR5C_PLATFORM_OVERRIDE '$override'." }
        return $override
    }
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    $isMac = Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue
    if ($isMac) { return 'darwin' }
    $isLinuxHost = Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue
    if ($isLinuxHost) { return 'linux' }
    throw 'Unsupported host operating system. Expected Windows, Linux, or macOS.'
}

function Get-AndroidArtifactId {
    param([string]$Platform = (Get-HostPlatform))
    switch ($Platform) {
        'windows' { 'android-platform-tools' }
        'linux'   { 'android-platform-tools-linux' }
        'darwin'  { 'android-platform-tools-darwin' }
        default   { throw "Unsupported Android tools platform '$Platform'." }
    }
}

function Get-AndroidToolsDirectory {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$Platform = (Get-HostPlatform)
    )
    $paths = Get-ProjectPaths $ProjectRoot
    $folder = if ($Platform -eq 'windows') { 'android-37.0.1' } else { "android-37.0.1-$Platform" }
    Join-Path $paths.Tools $folder
}

function Get-VenvPythonPath {
    param(
        [Parameter(Mandatory)][string]$VenvRoot,
        [string]$Platform = (Get-HostPlatform)
    )
    if ($Platform -eq 'windows') { Join-Path $VenvRoot 'Scripts/python.exe' } else { Join-Path $VenvRoot 'bin/python' }
}

function Get-EdlVenvDirectory {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$Platform = (Get-HostPlatform)
    )
    $paths = Get-ProjectPaths $ProjectRoot
    $folder = if ($Platform -eq 'windows') { 'edl-venv' } else { "edl-venv-$Platform" }
    Join-Path $paths.Tools $folder
}

function ConvertFrom-PortablePath {
    param([Parameter(Mandatory)][string]$Path)
    $Path.Replace('/', [string][IO.Path]::DirectorySeparatorChar)
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ">>> PASS: $Message" -ForegroundColor Green
}

function Get-ProjectPaths {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $root = [IO.Path]::GetFullPath($ProjectRoot)
    [pscustomobject]@{
        Root = $root
        Cache = Join-Path $root '.cache/artifacts'
        Tools = Join-Path $root '.tools'
        Runs = Join-Path $root 'runs'
        ArtifactConfig = Join-Path $root 'config/artifacts.json'
        FirmwareConfig = Join-Path $root 'config/firmware-profiles.json'
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-ArtifactDefinition {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Id
    )
    $paths = Get-ProjectPaths $ProjectRoot
    $config = Read-JsonFile $paths.ArtifactConfig
    $matches = @($config.artifacts | Where-Object { $_.id -eq $Id })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one artifact named '$Id'; found $($matches.Count)."
    }
    $matches[0]
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FileMatchesDefinition {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Definition,
        [switch]$Extracted
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($Extracted) {
        $expectedBytes = [int64]$Definition.extractedBytes
        $expectedHash = [string]$Definition.extractedSha256
    } else {
        $expectedBytes = [int64]$Definition.bytes
        $expectedHash = [string]$Definition.sha256
    }
    if ($item.Length -ne $expectedBytes) {
        throw "Size mismatch for $Path. Expected $expectedBytes bytes; got $($item.Length)."
    }
    $actualHash = Get-FileSha256 $Path
    if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Path. Expected $expectedHash; got $actualHash."
    }
}

function Get-VerifiedArtifact {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Id,
        [switch]$AcceptCommunityArtifacts
    )

    $paths = Get-ProjectPaths $ProjectRoot
    $definition = Get-ArtifactDefinition -ProjectRoot $ProjectRoot -Id $Id
    if ($definition.trust -eq 'community' -and -not $AcceptCommunityArtifacts) {
        throw "Artifact '$Id' is community supplied. Re-run with -AcceptCommunityArtifacts after reviewing $($definition.source)."
    }

    New-Item -ItemType Directory -Force -Path $paths.Cache | Out-Null
    $destination = Join-Path $paths.Cache $definition.fileName
    $needsDownload = $true
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        try {
            Assert-FileMatchesDefinition -Path $destination -Definition $definition
            $needsDownload = $false
        } catch {
            throw "A cached artifact failed verification and was not overwritten: $destination`n$($_.Exception.Message)`nRemove that one cache file manually and retry."
        }
    }

    if ($needsDownload) {
        Write-Step "Downloading $($definition.id) $($definition.version)"
        Invoke-WebRequest -Uri $definition.url -OutFile $destination -UseBasicParsing
        Assert-FileMatchesDefinition -Path $destination -Definition $definition
        Write-Pass "$($definition.fileName) matches its pinned size and SHA-256"
    }
    $destination
}

function Invoke-NativeTool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Live,
        [string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf) -and -not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "Executable not found: $FilePath"
    }

    $oldLocation = Get-Location
    if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($Live) { Write-Host $line }
            $line
        })
        $exitCode = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) { Set-Location -LiteralPath $oldLocation }
    }
    $text = $lines -join [Environment]::NewLine
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')`n$text"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $text; Lines = $lines }
}

function Find-Python {
    $platform = Get-HostPlatform
    $candidates = @()
    if ($platform -eq 'windows') {
        if ($env:LocalAppData) {
            $candidates += Join-Path $env:LocalAppData 'Programs/Python/Python312/python.exe'
            $candidates += Join-Path $env:LocalAppData 'Programs/Python/Python311/python.exe'
        }
        if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Python312/python.exe' }
        $candidates += 'python.exe'
    } else {
        $candidates += @('python3', 'python')
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        } else {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($command -and $command.Source -notlike '*WindowsApps*') { return $command.Source }
        }
    }
    $null
}

function Find-Git {
    $platform = Get-HostPlatform
    $candidates = @()
    if ($platform -eq 'windows') {
        if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Git/cmd/git.exe' }
        if ($env:LocalAppData) { $candidates += Join-Path $env:LocalAppData 'Programs/Git/cmd/git.exe' }
        $candidates += 'git.exe'
    } else {
        $candidates += 'git'
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        } else {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($command) { return $command.Source }
        }
    }
    $null
}

function Install-WingetPackage {
    param([Parameter(Mandatory)][string]$Id)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget is not installed. Install or update Microsoft's App Installer, then retry Setup."
    }
    Invoke-NativeTool -FilePath $winget.Source -Arguments @(
        'install', '--id', $Id, '--exact', '--scope', 'user',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    ) -Live | Out-Null
}

function Invoke-UnixElevated {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $id = Get-Command id -ErrorAction SilentlyContinue
    $uid = if ($id) { (& $id.Source -u 2>$null | Out-String).Trim() } else { '' }
    if ($uid -eq '0') {
        Invoke-NativeTool -FilePath $FilePath -Arguments $Arguments -Live | Out-Null
        return
    }
    $sudo = Get-Command sudo -ErrorAction SilentlyContinue
    if (-not $sudo) { throw "Installing host dependencies requires root. Run the documented package-manager command manually, then retry Setup." }
    Invoke-NativeTool -FilePath $sudo.Source -Arguments (@($FilePath) + $Arguments) -Live | Out-Null
}

function Install-UnixHostDependencies {
    param([Parameter(Mandatory)][string]$Platform)
    if ($Platform -eq 'darwin') {
        $brew = Get-Command brew -ErrorAction SilentlyContinue
        if (-not $brew) { throw 'Homebrew is required for automatic macOS dependency setup. Install it from https://brew.sh, then retry.' }
        Invoke-NativeTool -FilePath $brew.Source -Arguments @('install', 'python', 'git', 'libusb', 'xz') -Live | Out-Null
        return
    }

    $apt = Get-Command apt-get -ErrorAction SilentlyContinue
    if ($apt) {
        Invoke-UnixElevated -FilePath $apt.Source -Arguments @('update')
        Invoke-UnixElevated -FilePath $apt.Source -Arguments @('install', '-y', 'python3', 'python3-venv', 'python3-dev', 'git', 'libusb-1.0-0', 'liblzma-dev')
        return
    }
    $dnf = Get-Command dnf -ErrorAction SilentlyContinue
    if ($dnf) {
        Invoke-UnixElevated -FilePath $dnf.Source -Arguments @('install', '-y', 'python3', 'python3-devel', 'git', 'libusb1', 'xz-devel')
        return
    }
    $pacman = Get-Command pacman -ErrorAction SilentlyContinue
    if ($pacman) {
        Invoke-UnixElevated -FilePath $pacman.Source -Arguments @('-S', '--needed', '--noconfirm', 'python', 'git', 'libusb', 'xz')
        return
    }
    throw 'Unsupported Linux package manager. Install Python 3 + venv/dev headers, Git, libusb 1.0, and xz/lzma development headers manually.'
}

function Install-LinuxUsbRules {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $rule = Join-Path $ProjectRoot 'config/51-noteair5c.rules'
    if (-not (Test-Path -LiteralPath $rule -PathType Leaf)) { throw "Linux USB rule is missing: $rule" }
    $install = Get-Command install -ErrorAction Stop
    Invoke-UnixElevated -FilePath $install.Source -Arguments @('-m', '0644', $rule, '/etc/udev/rules.d/51-noteair5c.rules')
    $udevadm = Get-Command udevadm -ErrorAction SilentlyContinue
    if ($udevadm) {
        Invoke-UnixElevated -FilePath $udevadm.Source -Arguments @('control', '--reload-rules')
        Invoke-UnixElevated -FilePath $udevadm.Source -Arguments @('trigger')
    } else {
        Write-Warning 'udevadm was not found. Reboot Linux before connecting the BOOX.'
    }
}

function Install-AndroidPlatformTools {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $platform = Get-HostPlatform
    $target = Get-AndroidToolsDirectory -ProjectRoot $ProjectRoot -Platform $platform
    $executableSuffix = if ($platform -eq 'windows') { '.exe' } else { '' }
    $adb = Join-Path $target "platform-tools/adb$executableSuffix"
    $fastboot = Join-Path $target "platform-tools/fastboot$executableSuffix"
    if (-not (Test-Path -LiteralPath $adb) -or -not (Test-Path -LiteralPath $fastboot)) {
        $archive = Get-VerifiedArtifact -ProjectRoot $ProjectRoot -Id (Get-AndroidArtifactId -Platform $platform)
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
    }
    if ($platform -ne 'windows') {
        $chmod = Get-Command chmod -ErrorAction Stop
        Invoke-NativeTool -FilePath $chmod.Source -Arguments @('+x', $adb, $fastboot) | Out-Null
    }
    [pscustomobject]@{ Adb = $adb; Fastboot = $fastboot }
}

function Install-EdlClient {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$InstallHostDependencies
    )
    $paths = Get-ProjectPaths $ProjectRoot
    $platform = Get-HostPlatform
    $python = Find-Python
    $git = Find-Git
    if ($InstallHostDependencies) {
        if ($platform -eq 'windows') {
            if (-not $python) { Install-WingetPackage -Id 'Python.Python.3.12'; $python = Find-Python }
            if (-not $git) { Install-WingetPackage -Id 'Git.Git'; $git = Find-Git }
            if (-not (Get-Command zadig.exe -ErrorAction SilentlyContinue)) {
                try { Install-WingetPackage -Id 'akeo.ie.Zadig' } catch { Write-Warning $_.Exception.Message }
            }
        } else {
            Install-UnixHostDependencies -Platform $platform
            $python = Find-Python
            $git = Find-Git
        }
    }
    if (-not $python -or -not $git) {
        throw 'EDL setup needs Python 3.9+ and Git. Re-run Setup with -InstallHostDependencies, or install them first.'
    }

    $source = Join-Path $paths.Tools 'edl-src'
    $venv = Get-EdlVenvDirectory -ProjectRoot $ProjectRoot -Platform $platform
    $venvPython = Get-VenvPythonPath -VenvRoot $venv -Platform $platform
    $edlScript = Join-Path $source 'edl.py'
    New-Item -ItemType Directory -Force -Path $paths.Tools | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
        if (Test-Path -LiteralPath $source) {
            throw "Incomplete EDL source directory exists: $source. Move it aside manually, then retry."
        }
        Write-Step 'Cloning the pinned bkerler/edl source'
        Invoke-NativeTool -FilePath $git -Arguments @('clone', '--filter=blob:none', $script:EdlRepository, $source) -Live | Out-Null
    }
    Invoke-NativeTool -FilePath $git -Arguments @('-C', $source, 'fetch', '--depth', '1', 'origin', $script:EdlCommit) -Live | Out-Null
    Invoke-NativeTool -FilePath $git -Arguments @('-C', $source, 'checkout', '--detach', $script:EdlCommit) -Live | Out-Null
    Invoke-NativeTool -FilePath $git -Arguments @('-C', $source, 'submodule', 'update', '--init', '--depth', '1') -Live | Out-Null

    if (-not (Test-Path -LiteralPath $venvPython)) {
        Write-Step 'Creating the isolated EDL Python environment'
        Invoke-NativeTool -FilePath $python -Arguments @('-m', 'venv', $venv) -Live | Out-Null
    }
    Invoke-NativeTool -FilePath $venvPython -Arguments @(
        '-m', 'pip', 'install', '--disable-pip-version-check', '-r', (Join-Path $source 'requirements.txt')
    ) -Live | Out-Null
    if (-not (Test-Path -LiteralPath $edlScript)) { throw "EDL entry point is missing: $edlScript" }
    [pscustomobject]@{ Python = $venvPython; Script = $edlScript }
}

function Get-ToolContext {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $paths = Get-ProjectPaths $ProjectRoot
    $platform = Get-HostPlatform
    $androidRoot = Join-Path (Get-AndroidToolsDirectory -ProjectRoot $ProjectRoot -Platform $platform) 'platform-tools'
    $executableSuffix = if ($platform -eq 'windows') { '.exe' } else { '' }
    $venv = Get-EdlVenvDirectory -ProjectRoot $ProjectRoot -Platform $platform
    $context = [pscustomobject]@{
        Adb = Join-Path $androidRoot "adb$executableSuffix"
        AdbSerial = $null
        Fastboot = Join-Path $androidRoot "fastboot$executableSuffix"
        EdlPython = Get-VenvPythonPath -VenvRoot $venv -Platform $platform
        EdlScript = Join-Path $paths.Tools 'edl-src/edl.py'
        MagiskApk = Join-Path $paths.Cache 'Magisk-v30.7.apk'
        Loader = Join-Path $paths.Cache '0000000000000000_bdaf51b59ba21d8a_fhprg.bin'
    }
    foreach ($property in @('Adb', 'Fastboot', 'EdlPython', 'EdlScript', 'MagiskApk', 'Loader')) {
        $value = [string]$context.$property
        if (-not (Test-Path -LiteralPath $value -PathType Leaf)) {
            throw "Toolchain is incomplete ($property is missing). Run Root-NoteAir5C.ps1 -Command Setup from PowerShell 7."
        }
    }
    $context
}

function Install-NoteAir5CToolchain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$InstallHostDependencies,
        [switch]$AcceptCommunityArtifacts,
        [switch]$NonInteractive
    )
    $platform = Get-HostPlatform
    Write-Step 'Installing pinned Android platform tools'
    Install-AndroidPlatformTools -ProjectRoot $ProjectRoot | Out-Null
    Write-Step 'Installing the pinned EDL client in an isolated environment'
    Install-EdlClient -ProjectRoot $ProjectRoot -InstallHostDependencies:$InstallHostDependencies | Out-Null
    Get-VerifiedArtifact -ProjectRoot $ProjectRoot -Id 'magisk' | Out-Null
    Get-VerifiedArtifact -ProjectRoot $ProjectRoot -Id 'sm-bitra-firehose' | Out-Null
    if ($AcceptCommunityArtifacts) {
        Get-VerifiedArtifact -ProjectRoot $ProjectRoot -Id 'frp-oemunlock' -AcceptCommunityArtifacts | Out-Null
        Get-VerifiedArtifact -ProjectRoot $ProjectRoot -Id 'noteair5c-ablmod' -AcceptCommunityArtifacts | Out-Null
    }
    if ($platform -eq 'linux' -and $InstallHostDependencies) {
        Write-Step 'Installing the scoped BOOX / Qualcomm USB access rule'
        Install-LinuxUsbRules -ProjectRoot $ProjectRoot
    }
    Write-Pass 'Toolchain is installed and pinned artifacts verify'
    switch ($platform) {
        'windows' {
            Write-Host "`nWindows USB note:`n  When the BOOX is in EDL, Device Manager must show Qualcomm 9008 without an`n  error. If connection fails, bind WinUSB to QHSUSB_BULK / Qualcomm 9008 once`n  with Zadig, then retry."
        }
        'linux' {
            Write-Host "`nLinux USB note:`n  The scoped udev rule covers BOOX ADB (2d95) and Qualcomm EDL (05c6:9008).`n  Reconnect the cable after setup. If ModemManager was already holding the EDL`n  interface, disconnect/reconnect it or reboot once."
        }
        'darwin' {
            Write-Host "`nmacOS USB note:`n  libusb was installed through Homebrew. Reconnect the BOOX if the first EDL`n  probe does not see Qualcomm 9008."
        }
    }
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory)]$Tools,
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    $all = @()
    $serialProperty = $Tools.PSObject.Properties['AdbSerial']
    if ($serialProperty -and -not [string]::IsNullOrWhiteSpace([string]$serialProperty.Value)) {
        $all += @('-s', [string]$serialProperty.Value)
    }
    $all += $Arguments
    Invoke-NativeTool -FilePath $Tools.Adb -Arguments $all -AllowFailure:$AllowFailure -Live:$Live
}

function Invoke-Fastboot {
    param(
        [Parameter(Mandatory)]$Tools,
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Live
    )
    Invoke-NativeTool -FilePath $Tools.Fastboot -Arguments $Arguments -AllowFailure:$AllowFailure -Live:$Live
}

function Invoke-Edl {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$ControlCommand,
        [switch]$AllowFailure,
        [switch]$Live
    )
    $all = @($Tools.EdlScript) + $Arguments + @("--loader=$($Tools.Loader)")
    if (-not $ControlCommand) { $all += '--memory=ufs' }
    $hadPythonIoEncoding = Test-Path Env:PYTHONIOENCODING
    $oldPythonIoEncoding = $env:PYTHONIOENCODING
    $hadPythonUtf8 = Test-Path Env:PYTHONUTF8
    $oldPythonUtf8 = $env:PYTHONUTF8
    try {
        # edlclient's progress meter contains Unicode block characters. Force the
        # child process to UTF-8 so Windows legacy console code pages cannot abort
        # an otherwise valid partition read.
        $env:PYTHONIOENCODING = 'utf-8'
        $env:PYTHONUTF8 = '1'
        Invoke-NativeTool -FilePath $Tools.EdlPython -Arguments $all -AllowFailure:$AllowFailure -Live:$Live
    } finally {
        if ($hadPythonIoEncoding) { $env:PYTHONIOENCODING = $oldPythonIoEncoding } else { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue }
        if ($hadPythonUtf8) { $env:PYTHONUTF8 = $oldPythonUtf8 } else { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue }
    }
}

function Get-AdbProperty {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)][string]$Name
    )
    (Invoke-Adb -Tools $Tools -Arguments @('shell', 'getprop', $Name)).Output.Trim()
}

function Wait-AdbDevice {
    param(
        [Parameter(Mandatory)]$Tools,
        [int]$TimeoutSeconds = 300
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $result = Invoke-Adb -Tools $Tools -Arguments @('get-state') -AllowFailure
        if ($result.ExitCode -eq 0 -and $result.Output.Trim() -eq 'device') { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for an authorized ADB device after $TimeoutSeconds seconds. Enable USB debugging and approve this computer on the BOOX."
}

function Wait-FastbootDevice {
    param(
        [Parameter(Mandatory)]$Tools,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $result = Invoke-Fastboot -Tools $Tools -Arguments @('devices') -AllowFailure
        if ($result.Output -match '\bfastboot\b') { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for a fastboot device after $TimeoutSeconds seconds."
}

function Test-NoteAir5CModel {
    param([string]$Model, [string]$Device)
    $accepted = @('NoteAir5C', 'Note Air5 C', 'Note Air 5C')
    ($accepted -contains $Model.Trim()) -or ($Device.Trim() -eq 'NoteAir5C')
}

function ConvertTo-SafeSlot {
    param([Parameter(Mandatory)][string]$Value)
    $slot = $Value.Trim().TrimStart('_').ToLowerInvariant()
    if ($slot -notin @('a', 'b')) { throw "Unexpected active slot '$Value'; expected a or b." }
    $slot
}

function Find-FirmwareProfile {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Fingerprint
    )
    $paths = Get-ProjectPaths $ProjectRoot
    $config = Read-JsonFile $paths.FirmwareConfig
    $matches = @($config.profiles | Where-Object {
        $_.model -eq $Model -and $Fingerprint -match $_.fingerprintPattern
    })
    if ($matches.Count -gt 1) { throw "Firmware fingerprint matched multiple profiles: $($matches.id -join ', ')" }
    if ($matches.Count -eq 1) { return $matches[0] }
    $null
}

function Get-DeviceDiagnostic {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Tools
    )
    Invoke-NativeTool -FilePath $Tools.Adb -Arguments @('start-server') | Out-Null
    $devices = Invoke-NativeTool -FilePath $Tools.Adb -Arguments @('devices', '-l')
    $noteAirLines = @($devices.Lines | Where-Object {
        $_ -match '^([^\s]+)\s+device\b' -and ($_ -match 'product:NoteAir5C\b' -or $_ -match 'model:NoteAir5C\b' -or $_ -match 'device:NoteAir5C\b')
    })
    if ($noteAirLines.Count -eq 0 -and $devices.Output -match '\bunauthorized\b') {
        throw 'A device is connected but unauthorized. Unlock the BOOX and approve the USB debugging RSA dialog.'
    }
    if ($noteAirLines.Count -ne 1) {
        throw "Expected exactly one authorized physical NoteAir5C in ADB; found $($noteAirLines.Count).`n$($devices.Output)"
    }
    if ($noteAirLines[0] -notmatch '^([^\s]+)\s+device\b') { throw 'Could not parse the Note Air 5C ADB serial.' }
    $Tools.AdbSerial = $Matches[1]
    Wait-AdbDevice -Tools $Tools

    $model = Get-AdbProperty $Tools 'ro.product.model'
    $device = Get-AdbProperty $Tools 'ro.product.device'
    if (-not (Test-NoteAir5CModel -Model $model -Device $device)) {
        throw "Wrong device. Expected NoteAir5C, but ADB reports model='$model' device='$device'."
    }

    $systemFingerprint = Get-AdbProperty $Tools 'ro.build.fingerprint'
    $fingerprint = Get-AdbProperty $Tools 'ro.vendor.build.onyxfp'
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { $fingerprint = Get-AdbProperty $Tools 'ro.bootimage.build.fingerprint' }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { $fingerprint = $systemFingerprint }
    $slotRaw = Get-AdbProperty $Tools 'ro.boot.slot_suffix'
    if ([string]::IsNullOrWhiteSpace($slotRaw)) { $slotRaw = Get-AdbProperty $Tools 'ro.boot.slot' }
    $batteryText = (Invoke-Adb -Tools $Tools -Arguments @('shell', 'cat', '/sys/class/power_supply/battery/capacity') -AllowFailure).Output.Trim()
    $battery = 0
    [void][int]::TryParse($batteryText, [ref]$battery)
    if ($battery -le 0) {
        $batteryDump = (Invoke-Adb -Tools $Tools -Arguments @('shell', 'dumpsys', 'battery') -AllowFailure).Output
        if ($batteryDump -match '(?m)^\s*level:\s*(\d+)\s*$') { $battery = [int]$Matches[1] }
    }

    $diagnostic = [ordered]@{
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        adbSerial = [string]$Tools.AdbSerial
        model = $model
        device = $device
        board = Get-AdbProperty $Tools 'ro.product.board'
        serial = Get-AdbProperty $Tools 'ro.serialno'
        fingerprint = $fingerprint
        systemFingerprint = $systemFingerprint
        incremental = Get-AdbProperty $Tools 'ro.build.version.incremental'
        androidRelease = Get-AdbProperty $Tools 'ro.build.version.release'
        slot = ConvertTo-SafeSlot $slotRaw
        batteryPercent = $battery
        flashLocked = Get-AdbProperty $Tools 'ro.boot.flash.locked'
        verifiedBootState = Get-AdbProperty $Tools 'ro.boot.verifiedbootstate'
        verityMode = Get-AdbProperty $Tools 'ro.boot.veritymode'
        oemUnlockAllowed = Get-AdbProperty $Tools 'sys.oem_unlock_allowed'
        snapshotState = (Invoke-Adb -Tools $Tools -Arguments @('shell', 'snapshotctl', 'dump') -AllowFailure).Output
        snapshotDirectory = (Invoke-Adb -Tools $Tools -Arguments @('shell', 'ls', '-A', '/metadata/ota/snapshots') -AllowFailure).Output
    }
    $profile = Find-FirmwareProfile -ProjectRoot $ProjectRoot -Model $script:SupportedModel -Fingerprint $fingerprint
    $diagnostic.profileId = if ($profile) { $profile.id } else { $null }
    $diagnostic.profileStatus = if ($profile) { $profile.status } else { 'unknown' }
    $diagnostic.rootEnabled = if ($profile) { [bool]$profile.rootEnabled } else { $false }
    [pscustomobject]$diagnostic
}

function Assert-DevicePreflight {
    param(
        [Parameter(Mandatory)]$Diagnostic,
        [switch]$AcceptUntestedFirmware
    )
    if ([int]$Diagnostic.batteryPercent -lt $script:MinimumBatteryPercent) {
        throw "Battery is $($Diagnostic.batteryPercent)%. Charge to at least $script:MinimumBatteryPercent% before continuing."
    }
    if ([string]$Diagnostic.board -ne 'lito') {
        throw "Unexpected SoC board '$($Diagnostic.board)'; expected lito for this Note Air 5C workflow."
    }
    if (-not $Diagnostic.rootEnabled -and -not $AcceptUntestedFirmware) {
        throw "Firmware is '$($Diagnostic.profileStatus)' and is not enabled for automatic root. Fingerprint:`n$($Diagnostic.fingerprint)`nRun Diagnose first and review its report. If you deliberately accept this exact, untested build, add -AcceptUntestedFirmware."
    }
    if ($Diagnostic.snapshotState -match 'Update state:\s*(?!none\b)') {
        throw "An OTA snapshot operation may be pending. Wait for it to finish before partition access.`n$($Diagnostic.snapshotState)"
    }
    if ($Diagnostic.snapshotDirectory -and
        $Diagnostic.snapshotDirectory -notmatch 'No such file|Permission denied|not found' -and
        $Diagnostic.snapshotDirectory.Trim().Length -gt 0) {
        throw "The OTA snapshot directory is not empty. Wait for the OTA/merge to finish before partition access.`n$($Diagnostic.snapshotDirectory)"
    }
}

function New-RunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Diagnostic
    )
    $paths = Get-ProjectPaths $ProjectRoot
    New-Item -ItemType Directory -Force -Path $paths.Runs | Out-Null
    $safeSerial = ([string]$Diagnostic.serial -replace '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeSerial)) { $safeSerial = 'unknown-serial' }
    $id = ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')) + '-' + $safeSerial
    $run = Join-Path $paths.Runs $id
    New-Item -ItemType Directory -Path $run | Out-Null
    foreach ($folder in @('backup', 'work', 'patched', 'logs', 'verify')) {
        New-Item -ItemType Directory -Path (Join-Path $run $folder) | Out-Null
    }
    $state = [ordered]@{
        schemaVersion = 1
        id = $id
        projectRoot = [IO.Path]::GetFullPath($ProjectRoot)
        runPath = $run
        stage = 'Diagnosed'
        device = $Diagnostic
        touchedPartitions = @()
        journal = @([ordered]@{ atUtc = [DateTime]::UtcNow.ToString('o'); stage = 'Diagnosed'; message = 'Run created' })
    }
    Save-RunState -State $state
    [pscustomobject]$state
}

function Resolve-StatePath {
    param([Parameter(Mandatory)][string]$RunPath)
    $full = [IO.Path]::GetFullPath($RunPath)
    if (Test-Path -LiteralPath $full -PathType Container) { $full = Join-Path $full 'state.json' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Run state not found: $full" }
    $full
}

function Load-RunState {
    param([Parameter(Mandatory)][string]$RunPath)
    Read-JsonFile (Resolve-StatePath $RunPath)
}

function Save-RunState {
    param([Parameter(Mandatory)]$State)
    $statePath = Join-Path ([string]$State.runPath) 'state.json'
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Set-RunStage {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Message
    )
    $State.stage = $Stage
    $entries = @($State.journal)
    $entries += [pscustomobject]@{ atUtc = [DateTime]::UtcNow.ToString('o'); stage = $Stage; message = $Message }
    $State.journal = $entries
    Save-RunState -State $State
}

function Invoke-NoteAir5CDiagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$NonInteractive
    )
    $tools = Get-ToolContext $ProjectRoot
    Write-Step 'Collecting the read-only device diagnostic'
    $diagnostic = Get-DeviceDiagnostic -ProjectRoot $ProjectRoot -Tools $tools
    $paths = Get-ProjectPaths $ProjectRoot
    New-Item -ItemType Directory -Force -Path $paths.Runs | Out-Null
    $report = Join-Path $paths.Runs 'latest-diagnostic.json'
    $diagnostic | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8
    $diagnostic | Format-List model, device, fingerprint, slot, batteryPercent, flashLocked, verifiedBootState, oemUnlockAllowed, profileId, profileStatus
    Write-Pass "Read-only diagnostic saved to $report"
    $diagnostic
}

function Test-GptPartitions {
    param(
        [Parameter(Mandatory)][string]$GptText,
        [Parameter(Mandatory)][string[]]$Partitions
    )
    $missing = @()
    foreach ($partition in $Partitions) {
        $escaped = [regex]::Escape($partition)
        if ($GptText -notmatch "(?<![A-Za-z0-9_])$escaped(?![A-Za-z0-9_])") { $missing += $partition }
    }
    [pscustomobject]@{ Passed = ($missing.Count -eq 0); Missing = $missing }
}

function Wait-EdlReady {
    param(
        [Parameter(Mandatory)]$Tools,
        [int]$TimeoutSeconds = 90
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $probe = Invoke-Edl -Tools $Tools -Arguments @('printgpt') -AllowFailure
        if ($probe.ExitCode -eq 0 -and $probe.Output -match '\bboot_a\b') { return $probe.Output }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    $platform = Get-HostPlatform
    $hint = switch ($platform) {
        'windows' { 'check the Qualcomm 9008/WinUSB driver' }
        'linux'   { 'check the 51-noteair5c udev rule and that ModemManager is not holding 05c6:9008' }
        'darwin'  { 'check that Homebrew libusb is installed' }
    }
    throw "Timed out waiting for Qualcomm EDL after $TimeoutSeconds seconds; $hint, then reconnect the USB data cable."
}

function Enter-EdlFromAdb {
    param([Parameter(Mandatory)]$Tools)
    Wait-AdbDevice -Tools $Tools
    Write-Step 'Rebooting the BOOX into Qualcomm EDL mode'
    Invoke-Adb -Tools $Tools -Arguments @('reboot', 'edl') | Out-Null
    Wait-EdlReady -Tools $Tools
}

function Reset-FromEdl {
    param([Parameter(Mandatory)]$Tools)
    Write-Step 'Resetting from EDL (normal boot)'
    Invoke-Edl -Tools $Tools -Arguments @('reset') -ControlCommand -Live | Out-Null
}

function New-BackupManifest {
    param([Parameter(Mandatory)][string]$BackupRoot)
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($BackupRoot).TrimEnd($separators)
    $entries = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -notin @('manifest.json', 'partitions.idx') }) {
        $relative = $file.FullName.Substring($root.Length).TrimStart($separators).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $entries += [pscustomobject]@{
            path = $relative
            bytes = $file.Length
            sha256 = Get-FileSha256 $file.FullName
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        skipped = @('super', 'userdata')
        warning = 'Contains device identity, DRM/attestation material, and calibration data. Never publish this directory.'
        files = $entries
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding UTF8

    $indexLines = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.bin') {
        $relative = $file.FullName.Substring($root.Length).TrimStart($separators).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $indexLines += "$name`t$relative"
    }
    $indexLines | Sort-Object | Set-Content -LiteralPath (Join-Path $root 'partitions.idx') -Encoding UTF8
    $manifest
}

function Test-BackupManifest {
    param([Parameter(Mandatory)][string]$BackupRoot)
    $manifestPath = Join-Path $BackupRoot 'manifest.json'
    $manifest = Read-JsonFile $manifestPath
    foreach ($entry in @($manifest.files)) {
        $file = Join-Path $BackupRoot (ConvertFrom-PortablePath ([string]$entry.path))
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Backup file is missing: $file" }
        $item = Get-Item -LiteralPath $file
        if ($item.Length -ne [int64]$entry.bytes) { throw "Backup size mismatch: $file" }
        if ((Get-FileSha256 $file) -ne [string]$entry.sha256) { throw "Backup checksum mismatch: $file" }
    }
    $indexPath = Join-Path $BackupRoot 'partitions.idx'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "Backup partition index is missing: $indexPath" }
    foreach ($partition in $script:CriticalPartitions) {
        if ((Get-BackupEntry -BackupRoot $BackupRoot -Partition $partition -AllowMissing) -eq $null) {
            throw "Backup is missing critical partition '$partition'. Refusing all writes."
        }
    }
    Write-Pass 'Backup manifest, checksums, and critical partition set verify'
    $true
}

function Get-BackupEntry {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Partition,
        [switch]$AllowMissing
    )
    if ($Partition -notmatch '^[a-z0-9_]+$') { throw "Unsafe partition name: $Partition" }
    $index = Join-Path $BackupRoot 'partitions.idx'
    if (-not (Test-Path -LiteralPath $index)) {
        if ($AllowMissing) { return $null }
        throw "Partition index not found: $index"
    }
    $hits = @()
    foreach ($line in Get-Content -LiteralPath $index) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[0] -eq $Partition) { $hits += $parts[1] }
    }
    if ($hits.Count -eq 0 -and $AllowMissing) { return $null }
    if ($hits.Count -ne 1) { throw "Expected one backup entry for '$Partition'; found $($hits.Count)." }
    $resolved = Join-Path $BackupRoot (ConvertFrom-PortablePath $hits[0])
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Indexed partition file is missing: $resolved" }
    $resolved
}

function Get-PrefixSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Bytes
    )
    $item = Get-Item -LiteralPath $Path
    if ($Bytes -le 0 -or $item.Length -lt $Bytes) {
        throw "Cannot hash $Bytes bytes from $Path (file length $($item.Length))."
    }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] 1048576
        $remaining = $Bytes
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min($buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $wanted)
            if ($read -le 0) { throw "Unexpected EOF while hashing $Path" }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $remaining -= $read
        }
        [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
        ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Test-KnownRestoreBootHash {
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][string]$Stock,
        [string]$Patched
    )
    $allowed = @($Stock.ToLowerInvariant())
    if (-not [string]::IsNullOrWhiteSpace($Patched)) { $allowed += $Patched.ToLowerInvariant() }
    $Current.ToLowerInvariant() -in $allowed
}

function Write-VerifiedPartition {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)][string]$Partition,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$VerifyDirectory
    )
    if ($Partition -notmatch '^[a-z0-9_]+$') { throw "Unsafe partition name: $Partition" }
    $source = Get-Item -LiteralPath $Image -ErrorAction Stop
    if ($source.Length -le 0) { throw "Refusing to write an empty image: $Image" }
    New-Item -ItemType Directory -Force -Path $VerifyDirectory | Out-Null
    Write-Step "Writing $Partition ($($source.Length) bytes)"
    Invoke-Edl -Tools $Tools -Arguments @('w', $Partition, $source.FullName) -Live | Out-Null
    $readback = Join-Path $VerifyDirectory "$Partition-readback.bin"
    Write-Step "Reading $Partition back before reboot"
    Invoke-Edl -Tools $Tools -Arguments @('r', $Partition, $readback) -Live | Out-Null
    $expected = Get-PrefixSha256 -Path $source.FullName -Bytes $source.Length
    $actual = Get-PrefixSha256 -Path $readback -Bytes $source.Length
    if ($expected -ne $actual) {
        throw "Read-back verification FAILED for $Partition. Expected $expected; got $actual. The script will not reboot."
    }
    Write-Pass "$Partition read-back matches the written image ($expected)"
}

function Invoke-FullEdlBackup {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$InitialGpt
    )
    $backup = Join-Path $State.runPath 'backup'
    $gptPath = Join-Path $backup 'gpt.txt'
    $InitialGpt | Set-Content -LiteralPath $gptPath -Encoding UTF8
    $gptGate = Test-GptPartitions -GptText $InitialGpt -Partitions @('abl_a', 'abl_b', 'boot_a', 'boot_b', 'devinfo', 'dtbo_a', 'dtbo_b')
    if (-not $gptGate.Passed) { throw "Device GPT is missing required Note Air 5C partitions: $($gptGate.Missing -join ', ')" }

    Write-Step 'Backing up every EDL partition except reconstructible super and wipe-bound userdata'
    Invoke-Edl -Tools $Tools -Arguments @('rl', $backup, '--skip=super,userdata', '--genxml') -Live | Out-Null
    New-BackupManifest -BackupRoot $backup | Out-Null
    Test-BackupManifest -BackupRoot $backup | Out-Null
    @'
This backup contains device identity, DRM/attestation keys, and calibration data.
Do not publish it or commit it. Copy the whole run directory to offline storage.
The backup intentionally skips super (recoverable from firmware) and userdata
(encrypted and invalidated by a lock-state transition).
'@ | Set-Content -LiteralPath (Join-Path $backup 'README-PRIVATE.txt') -Encoding UTF8
    Set-RunStage -State $State -Stage 'BackupComplete' -Message 'Full EDL backup completed and manifest verified'
}

function Invoke-NoteAir5CBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RunPath,
        [switch]$AcceptUntestedFirmware,
        [switch]$NonInteractive
    )
    $tools = Get-ToolContext $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($RunPath)) {
        $diagnostic = Get-DeviceDiagnostic -ProjectRoot $ProjectRoot -Tools $tools
        if ([int]$diagnostic.batteryPercent -lt $script:MinimumBatteryPercent) {
            throw "Battery is $($diagnostic.batteryPercent)%. Charge to at least $script:MinimumBatteryPercent%."
        }
        $state = New-RunState -ProjectRoot $ProjectRoot -Diagnostic $diagnostic
        $tools.AdbSerial = [string]$diagnostic.adbSerial
    } else {
        $state = Load-RunState $RunPath
        if ($state.stage -eq 'BackupComplete') {
            Test-BackupManifest -BackupRoot (Join-Path $state.runPath 'backup') | Out-Null
            Write-Pass "Backup is already complete and verified: $($state.runPath)"
            return $state
        }
        if ($state.stage -ne 'Diagnosed') {
            throw "Backup can only resume a Diagnosed run; '$($state.runPath)' is at stage '$($state.stage)'."
        }
        $diagnostic = $state.device
        if ([int]$diagnostic.batteryPercent -lt $script:MinimumBatteryPercent) {
            throw "Recorded battery level is $($diagnostic.batteryPercent)%. Reset to Android and charge to at least $script:MinimumBatteryPercent% before backing up."
        }
        $tools.AdbSerial = [string]$diagnostic.adbSerial
    }
    try {
        $gpt = Ensure-EdlMode -Tools $tools
        Invoke-FullEdlBackup -Tools $tools -State $state -InitialGpt $gpt
        Reset-FromEdl -Tools $tools
        Write-Pass "Backup complete: $($state.runPath)"
        Write-Warning 'Copy this run directory to separate/offline storage before running Root.'
        $state
    } catch {
        Write-Warning "Backup stopped. The device may still be in EDL. No partition write was attempted.`n$($_.Exception.Message)"
        throw
    }
}

function Expand-MagiskPatchPayload {
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $mapping = [ordered]@{
        'assets/boot_patch.sh' = 'boot_patch.sh'
        'assets/util_functions.sh' = 'util_functions.sh'
        'assets/stub.apk' = 'stub.apk'
        'lib/arm64-v8a/libbusybox.so' = 'busybox'
        'lib/arm64-v8a/libinit-ld.so' = 'init-ld'
        'lib/arm64-v8a/libmagisk.so' = 'magisk'
        'lib/arm64-v8a/libmagiskboot.so' = 'magiskboot'
        'lib/arm64-v8a/libmagiskinit.so' = 'magiskinit'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        foreach ($entryName in $mapping.Keys) {
            $entry = $archive.Entries | Where-Object { $_.FullName -eq $entryName } | Select-Object -First 1
            if (-not $entry) { throw "Magisk APK does not contain required entry '$entryName'." }
            $target = Join-Path $Destination $mapping[$entryName]
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
}

function Invoke-MagiskBootPatch {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State
    )
    $slot = ConvertTo-SafeSlot ([string]$State.device.slot)
    $backup = Join-Path $State.runPath 'backup'
    $stockBoot = Get-BackupEntry -BackupRoot $backup -Partition "boot_$slot"
    $payload = Join-Path $State.runPath 'work/magisk-payload'
    Expand-MagiskPatchPayload -ApkPath $Tools.MagiskApk -Destination $payload

    $remote = "/data/local/tmp/noteair5c-root-$($State.id -replace '[^A-Za-z0-9_.-]', '_')"
    Write-Step 'Preparing Magisk boot patcher on the device'
    Invoke-Adb -Tools $Tools -Arguments @('shell', "rm -rf $remote && mkdir -p $remote") | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $payload -File) {
        Invoke-Adb -Tools $Tools -Arguments @('push', $file.FullName, "$remote/$($file.Name)") -Live | Out-Null
    }
    # Magisk's script creates its own file named stock_boot.img. Giving the
    # input that same basename would make `cat input > stock_boot.img` truncate
    # the source in place during its stock-image backup step.
    Invoke-Adb -Tools $Tools -Arguments @('push', $stockBoot, "$remote/input-boot.img") -Live | Out-Null
    Invoke-Adb -Tools $Tools -Arguments @('shell', 'chmod', '755',
        "$remote/busybox", "$remote/magisk", "$remote/magiskboot", "$remote/magiskinit", "$remote/init-ld",
        "$remote/boot_patch.sh", "$remote/util_functions.sh") | Out-Null

    Write-Step "Patching the device's own stock boot_$slot image with Magisk 30.7"
    $patchCommand = "cd $remote && mkdir -p tmp && BOOTMODE=true TMPDIR=$remote/tmp MAGISKBIN=$remote KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false ./busybox sh ./boot_patch.sh ./input-boot.img"
    $result = Invoke-Adb -Tools $Tools -Arguments @('shell', $patchCommand) -Live
    if ($result.Output -notmatch 'Repacking boot image') {
        throw "Magisk patch output did not contain its expected completion phase.`n$($result.Output)"
    }

    $patched = Join-Path $State.runPath "patched/magisk-patched-boot_$slot.img"
    Invoke-Adb -Tools $Tools -Arguments @('pull', "$remote/new-boot.img", $patched) -Live | Out-Null
    $patchedItem = Get-Item -LiteralPath $patched -ErrorAction Stop
    $stockItem = Get-Item -LiteralPath $stockBoot
    if ($patchedItem.Length -lt 1048576 -or $patchedItem.Length -gt $stockItem.Length) {
        throw "Patched boot image has an implausible size: $($patchedItem.Length) bytes (stock partition dump: $($stockItem.Length))."
    }
    $stockPrefix = Get-PrefixSha256 -Path $stockBoot -Bytes $patchedItem.Length
    $patchedHash = Get-FileSha256 $patched
    if ($stockPrefix -eq $patchedHash) { throw 'Magisk output is byte-identical to stock; refusing to continue.' }

    Write-Step 'Structurally verifying the patched boot image with MagiskBoot'
    $verifyCommand = "cd $remote && rm -rf verify && mkdir verify && cp new-boot.img verify/patched.img && cd verify && ../magiskboot unpack patched.img >/dev/null 2>&1; unpack=`$?; ../magiskboot cpio ramdisk.cpio test >/dev/null 2>&1; cpio=`$?; printf 'UNPACK=%s CPIO=%s\n' `"`$unpack`" `"`$cpio`""
    $verify = (Invoke-Adb -Tools $Tools -Arguments @('shell', $verifyCommand)).Output.Trim()
    if ($verify -ne 'UNPACK=0 CPIO=1') {
        throw "Patched boot structure did not verify as a Magisk-patched image: $verify"
    }
    Write-Pass 'Patched boot unpacks cleanly and its ramdisk reports Magisk-patched status'
    Invoke-Adb -Tools $Tools -Arguments @('shell', 'rm', '-rf', $remote) -AllowFailure | Out-Null
    $State | Add-Member -NotePropertyName patchedBoot -NotePropertyValue ([pscustomobject]@{
        partition = "boot_$slot"
        path = $patched
        bytes = $patchedItem.Length
        sha256 = $patchedHash
        magiskVersion = '30.7'
    }) -Force
    Set-RunStage -State $State -Stage 'BootPatched' -Message "Stock boot_$slot patched with pinned Magisk 30.7"
    Write-Pass "Patched boot image saved as $patched"
}

function Confirm-DestructiveRoot {
    param(
        [switch]$AcceptCommunityArtifacts,
        [switch]$AcknowledgeDataWipe,
        [switch]$NonInteractive
    )
    if ($AcknowledgeDataWipe) { return }
    if ($NonInteractive) {
        throw 'Root requires -AcknowledgeDataWipe in non-interactive mode.'
    }
    Write-Host @'

Root changes the verified-boot lock state. Android will make existing userdata
unreadable and may enter recovery for a factory reset. The EDL backup excludes
encrypted userdata and cannot preserve apps or local files.

The default path does not use the downloaded community ABL/FRP images. It sets
two validated Qualcomm devinfo flags and verifies every write by reading it back.
'@ -ForegroundColor Yellow
    $answer = Read-Host 'Type ERASE NOTEAIR5C to continue'
    if ($answer -cne 'ERASE NOTEAIR5C') { throw 'Root cancelled; consent phrase did not match.' }
}

function Invoke-RestoreWriteGate {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State
    )
    $backup = Join-Path $State.runPath 'backup'
    Test-BackupManifest -BackupRoot $backup | Out-Null
    $slot = ConvertTo-SafeSlot ([string]$State.device.slot)
    $inactive = if ($slot -eq 'a') { 'b' } else { 'a' }
    $partition = "dtbo_$inactive"
    $source = Get-BackupEntry -BackupRoot $backup -Partition $partition
    Write-Step "Proving the EDL restore path with a byte-identical $partition rewrite"
    Write-VerifiedPartition -Tools $Tools -Partition $partition -Image $source -VerifyDirectory (Join-Path $State.runPath 'verify/restore-gate')
    @"
EDL write path verified
when: $([DateTime]::UtcNow.ToString('o'))
partition: $partition (inactive slot; active was $slot)
source: $source
sha256: $(Get-FileSha256 $source)
"@ | Set-Content -LiteralPath (Join-Path $backup 'GATE3-PASS.txt') -Encoding UTF8
    Set-RunStage -State $State -Stage 'RestoreGatePassed' -Message "Byte-identical $partition write/read gate passed"
}

function Test-DevinfoRuntimeCompatibility {
    param(
        [Parameter(Mandatory)][string]$Backup,
        [Parameter(Mandatory)][string]$Current,
        [switch]$AllowUnlockFlagDifferences
    )
    $backupBytes = [IO.File]::ReadAllBytes($Backup)
    $currentBytes = [IO.File]::ReadAllBytes($Current)
    if ($backupBytes.Length -ne $currentBytes.Length -or $backupBytes.Length -lt 2220) {
        throw "Unexpected devinfo sizes: backup=$($backupBytes.Length), current=$($currentBytes.Length)."
    }
    foreach ($candidate in @($backupBytes, $currentBytes)) {
        if ([Text.Encoding]::ASCII.GetString($candidate, 0, 13) -ne 'ANDROID-BOOT!') {
            throw 'Unexpected devinfo magic while comparing runtime state.'
        }
        if ($candidate[15] -ne 1) { throw 'Unexpected devinfo charger-screen sanity byte while comparing runtime state.' }
    }

    # This Note Air 5C firmware maintains a little-endian, month-aligned AVB
    # rollback/security date at 0x8A8 after a completed OTA boot. Preserve the
    # current value and only accept a monotonic change in that exact field.
    $runtimeOffsets = @(0x8A8, 0x8A9, 0x8AA, 0x8AB)
    $allowedOffsets = @($runtimeOffsets)
    if ($AllowUnlockFlagDifferences) { $allowedOffsets += @(13, 14) }
    $differences = @()
    for ($i = 0; $i -lt $backupBytes.Length; $i++) {
        if ($backupBytes[$i] -ne $currentBytes[$i]) { $differences += $i }
    }
    $unexpected = @($differences | Where-Object { $_ -notin $allowedOffsets })
    if ($unexpected.Count) {
        throw "Current devinfo differs from backup at unexpected offsets: $((@($unexpected | Select-Object -First 16 | ForEach-Object { '0x{0:X}' -f $_ })) -join ', ')."
    }

    $backupDateValue = [BitConverter]::ToUInt32($backupBytes, 0x8A8)
    $currentDateValue = [BitConverter]::ToUInt32($currentBytes, 0x8A8)
    if ($currentDateValue -lt $backupDateValue) {
        throw "devinfo rollback/security date moved backwards: $backupDateValue -> $currentDateValue."
    }
    $dates = foreach ($value in @($backupDateValue, $currentDateValue)) {
        try { [DateTimeOffset]::FromUnixTimeSeconds([int64]$value).UtcDateTime } catch { throw "Invalid devinfo rollback/security date value: $value" }
    }
    foreach ($date in $dates) {
        if ($date.Year -lt 2020 -or $date.Day -ne 1 -or $date.TimeOfDay -ne [TimeSpan]::Zero) {
            throw "devinfo offset 0x8A8 is not a plausible month-aligned rollback/security date: $($date.ToString('o'))."
        }
    }
    [pscustomobject]@{
        DifferenceCount = $differences.Count
        RuntimeFieldChanged = ($backupDateValue -ne $currentDateValue)
        BackupRuntimeDateUtc = $dates[0].ToString('yyyy-MM-dd')
        CurrentRuntimeDateUtc = $dates[1].ToString('yyyy-MM-dd')
    }
}

function New-PatchedDevinfo {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $bytes = [IO.File]::ReadAllBytes($Source)
    if ($bytes.Length -lt 16) { throw "devinfo is too short ($($bytes.Length) bytes)." }
    $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 13)
    if ($magic -ne 'ANDROID-BOOT!') {
        throw "Unexpected devinfo magic '$magic'. Refusing to assume a Qualcomm device_info layout."
    }
    if ($bytes[13] -notin @(0, 1) -or $bytes[14] -notin @(0, 1)) {
        throw "Unexpected devinfo unlock bytes: offset13=$($bytes[13]) offset14=$($bytes[14])."
    }
    if ($bytes[15] -ne 1) {
        throw "devinfo charger-screen sanity byte is $($bytes[15]), not 1. The struct layout may differ; refusing to write."
    }
    $before = [byte[]]$bytes.Clone()
    $bytes[13] = 1
    $bytes[14] = 1
    $differenceCount = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ne $before[$i]) { $differenceCount++ } }
    if ($differenceCount -gt 2) { throw "Internal error: devinfo patch changed $differenceCount bytes, expected at most 2." }
    [IO.File]::WriteAllBytes($Destination, $bytes)
    [pscustomobject]@{
        AlreadyUnlocked = ($differenceCount -eq 0)
        DifferenceCount = $differenceCount
        Magic = $magic
        UnlockOffset = 13
        CriticalUnlockOffset = 14
        ChargerScreenOffset = 15
    }
}

function New-LockedDevinfo {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $bytes = [IO.File]::ReadAllBytes($Source)
    if ($bytes.Length -lt 16) { throw "devinfo is too short ($($bytes.Length) bytes)." }
    $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 13)
    if ($magic -ne 'ANDROID-BOOT!') { throw "Unexpected devinfo magic '$magic'." }
    if ($bytes[13] -notin @(0, 1) -or $bytes[14] -notin @(0, 1) -or $bytes[15] -ne 1) {
        throw "Unexpected devinfo lock/sanity bytes: offset13=$($bytes[13]) offset14=$($bytes[14]) offset15=$($bytes[15])."
    }
    $before = [byte[]]$bytes.Clone()
    $bytes[13] = 0
    $bytes[14] = 0
    $differenceCount = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ne $before[$i]) { $differenceCount++ } }
    if ($differenceCount -notin @(0, 2)) {
        throw "Expected both devinfo unlock flags to change together; got $differenceCount byte change(s)."
    }
    [IO.File]::WriteAllBytes($Destination, $bytes)
    [pscustomobject]@{ AlreadyLocked = ($differenceCount -eq 0); DifferenceCount = $differenceCount }
}

function Invoke-DirectDevinfoUnlock {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State
    )
    $work = Join-Path $State.runPath 'work'
    $current = Join-Path $work 'devinfo-current.bin'
    $patched = Join-Path $work 'devinfo-unlocked.bin'
    Write-Step 'Reading current devinfo for a runtime-validated two-byte unlock patch'
    Invoke-Edl -Tools $Tools -Arguments @('r', 'devinfo', $current) -Live | Out-Null
    $backupDevinfo = Get-BackupEntry -BackupRoot (Join-Path $State.runPath 'backup') -Partition 'devinfo'
    $compatibility = Test-DevinfoRuntimeCompatibility -Backup $backupDevinfo -Current $current
    Write-Pass "devinfo differs only in its monotonic runtime date field ($($compatibility.BackupRuntimeDateUtc) -> $($compatibility.CurrentRuntimeDateUtc)); current value will be preserved"
    $patch = New-PatchedDevinfo -Source $current -Destination $patched
    if ($patch.AlreadyUnlocked) {
        Write-Pass 'devinfo already reports normal and critical unlock flags set'
    } else {
        if ($patch.DifferenceCount -ne 2) {
            throw "Expected exactly two locked-to-unlocked byte changes; got $($patch.DifferenceCount)."
        }
        Write-Host 'devinfo validated: magic ANDROID-BOOT!, offsets 13/14 0->1, offset 15 charger sanity=1'
        Write-VerifiedPartition -Tools $Tools -Partition 'devinfo' -Image $patched -VerifyDirectory (Join-Path $State.runPath 'verify/devinfo')
        $State.touchedPartitions = @($State.touchedPartitions) + @('devinfo') | Select-Object -Unique
    }
    Set-RunStage -State $State -Stage 'BootloaderUnlocked' -Message 'devinfo normal and critical unlock flags are set and read-back verified'
}

function Install-And-VerifyMagisk {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State,
        [switch]$NonInteractive
    )
    Wait-AdbDevice -Tools $Tools -TimeoutSeconds 60
    Write-Step 'Installing the pinned Magisk manager APK'
    Invoke-Adb -Tools $Tools -Arguments @('install', '-r', $Tools.MagiskApk) -Live | Out-Null
    Invoke-Adb -Tools $Tools -Arguments @('shell', 'monkey', '-p', 'com.topjohnwu.magisk', '1') -AllowFailure | Out-Null
    if (-not $NonInteractive) {
        Write-Host @'

If Magisk asks for additional setup, accept it and let the tablet reboot. Then
re-enable/approve USB debugging if Android asks. Return here when Android is up.
'@ -ForegroundColor Yellow
        [void](Read-Host 'Press Enter to verify root')
        Wait-AdbDevice -Tools $Tools -TimeoutSeconds 600
    }
    $locked = Get-AdbProperty $Tools 'ro.boot.flash.locked'
    $verified = Get-AdbProperty $Tools 'ro.boot.verifiedbootstate'
    $magisk = (Invoke-Adb -Tools $Tools -Arguments @('shell', 'magisk', '-v') -AllowFailure).Output.Trim()
    if (-not $magisk) {
        $magisk = (Invoke-Adb -Tools $Tools -Arguments @('shell', '/sbin/magisk', '-v') -AllowFailure).Output.Trim()
    }
    if ($locked -ne '0') { throw "Android booted, but ro.boot.flash.locked='$locked' instead of 0." }
    if ($verified -ne 'orange') { throw "Android booted, but verified boot state is '$verified' instead of orange." }
    if ($magisk -notmatch '30\.7|30700') {
        if ($NonInteractive) {
            Write-Warning "Unlocked/orange boot is verified and Magisk Manager was launched, but the root daemon is not active yet. Accept Magisk's additional setup/reboot prompt, re-authorize ADB if asked, then Resume this run."
            return $false
        }
        throw "Magisk root binary was not confirmed. Reported: '$magisk'. Open Magisk and finish its setup, then Resume."
    }
    $State | Add-Member -NotePropertyName verification -NotePropertyValue ([pscustomobject]@{
        atUtc = [DateTime]::UtcNow.ToString('o')
        flashLocked = $locked
        verifiedBootState = $verified
        magisk = $magisk
    }) -Force
    Set-RunStage -State $State -Stage 'RootVerified' -Message "Root verified: flash.locked=0, verifiedbootstate=orange, Magisk=$magisk"
    Write-Pass "Root verified with Magisk $magisk"
}

function Ensure-EdlMode {
    param([Parameter(Mandatory)]$Tools)
    # edlclient waits indefinitely when no 9008 device is present, so do not use
    # it as the first mode probe. ADB fails quickly while in EDL and gives us a
    # deterministic choice between rebooting Android or waiting for 9008.
    $adbState = Invoke-Adb -Tools $Tools -Arguments @('get-state') -AllowFailure
    if ($adbState.ExitCode -eq 0 -and $adbState.Output.Trim() -eq 'device') {
        return Enter-EdlFromAdb -Tools $Tools
    }
    Wait-EdlReady -Tools $Tools
}

function Assert-PartitionMatchesBackup {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Partition
    )
    $source = Get-BackupEntry -BackupRoot (Join-Path $State.runPath 'backup') -Partition $Partition
    $current = Join-Path $State.runPath "verify/prewrite-$Partition.bin"
    Invoke-Edl -Tools $Tools -Arguments @('r', $Partition, $current) -Live | Out-Null
    if ((Get-FileSha256 $source) -ne (Get-FileSha256 $current)) {
        throw "Current $Partition does not match the verified backup. An OTA or external write may have occurred; refusing to overwrite it."
    }
    Write-Pass "$Partition still matches the verified backup immediately before writing"
}

function Wait-ForPostUnlockAndroid {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State,
        [switch]$NonInteractive
    )
    if ($NonInteractive) {
        $adbState = Invoke-Adb -Tools $Tools -Arguments @('get-state') -AllowFailure
        if ($adbState.ExitCode -eq 0 -and $adbState.Output.Trim() -eq 'device') { return $true }
        Write-Warning "The device was rebooted after its lock-state change. Complete the factory reset/setup, enable USB debugging, then run:`npwsh ./Root-NoteAir5C.ps1 -Command Resume -RunPath `"$($State.runPath)`" -AcknowledgeDataWipe -NonInteractive"
        return $false
    }
    Write-Host @'

The BOOX is rebooting with an unlocked verified-boot state. Existing userdata
will no longer decrypt. If Android Recovery appears, perform the factory reset.
Then complete Android setup, enable Developer options + USB debugging, and
approve this computer again. Do not start an OTA update.
'@ -ForegroundColor Yellow
    [void](Read-Host 'Press Enter after Android is running and USB debugging is enabled')
    Wait-AdbDevice -Tools $Tools -TimeoutSeconds 900
    $true
}

function Invoke-NoteAir5CRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RunPath,
        [switch]$AcceptCommunityArtifacts,
        [switch]$AcknowledgeDataWipe,
        [switch]$AcceptUntestedFirmware,
        [switch]$NonInteractive
    )
    $tools = Get-ToolContext $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($RunPath)) {
        Write-Step 'No prior run supplied; taking the mandatory full EDL backup first'
        $state = Invoke-NoteAir5CBackup -ProjectRoot $ProjectRoot -AcceptUntestedFirmware:$AcceptUntestedFirmware -NonInteractive:$NonInteractive
    } else {
        $state = Load-RunState $RunPath
    }
    $tools.AdbSerial = [string]$state.device.adbSerial

    if ($state.stage -eq 'RootVerified') {
        $rootShell = Invoke-Adb -Tools $tools -Arguments @('shell', 'su', '-c', 'id') -AllowFailure
        if ($rootShell.ExitCode -eq 0 -and $rootShell.Output -match 'uid=0\(root\)') {
            $state.verification | Add-Member -NotePropertyName rootShell -NotePropertyValue $rootShell.Output.Trim() -Force
            Save-RunState -State $state
            Write-Pass "Live root shell verified: $($rootShell.Output.Trim())"
        } else {
            Write-Warning 'The run is RootVerified, but live su proof was denied by Magisk policy or ADB is unavailable.'
        }
        Write-Pass "Run is already at terminal stage '$($state.stage)': $($state.runPath)"
        return $state
    }
    if ($state.stage -eq 'StockRestored') {
        Write-Pass "Run is already at terminal stage '$($state.stage)': $($state.runPath)"
        return $state
    }

    Assert-DevicePreflight -Diagnostic $state.device -AcceptUntestedFirmware:$AcceptUntestedFirmware
    Confirm-DestructiveRoot -AcceptCommunityArtifacts:$AcceptCommunityArtifacts -AcknowledgeDataWipe:$AcknowledgeDataWipe -NonInteractive:$NonInteractive
    $backup = Join-Path $state.runPath 'backup'

    if ($state.stage -eq 'Diagnosed') {
        $gpt = Ensure-EdlMode -Tools $tools
        Invoke-FullEdlBackup -Tools $tools -State $state -InitialGpt $gpt
        Reset-FromEdl -Tools $tools
    }

    Test-BackupManifest -BackupRoot $backup | Out-Null

    if ($state.stage -eq 'BackupComplete') {
        Wait-AdbDevice -Tools $tools -TimeoutSeconds 600
        $current = Get-DeviceDiagnostic -ProjectRoot $ProjectRoot -Tools $tools
        if ($current.fingerprint -ne $state.device.fingerprint) {
            throw "Firmware changed since backup. Backed up '$($state.device.fingerprint)', now running '$($current.fingerprint)'. Start a new Backup; never patch across an OTA."
        }
        if ($current.slot -ne $state.device.slot) {
            throw "Active slot changed since backup ($($state.device.slot) -> $($current.slot)). Start a new Backup."
        }
        Assert-DevicePreflight -Diagnostic $current -AcceptUntestedFirmware:$AcceptUntestedFirmware
        Invoke-MagiskBootPatch -Tools $tools -State $state
    }

    if ($state.stage -eq 'BootPatched') {
        [void](Ensure-EdlMode -Tools $tools)
        Invoke-RestoreWriteGate -Tools $tools -State $state
    }

    if ($state.stage -eq 'RestoreGatePassed') {
        [void](Ensure-EdlMode -Tools $tools)
        Invoke-DirectDevinfoUnlock -Tools $tools -State $state
    }

    if ($state.stage -eq 'BootloaderUnlocked') {
        [void](Ensure-EdlMode -Tools $tools)
        $partition = [string]$state.patchedBoot.partition
        $patched = [string]$state.patchedBoot.path
        Assert-PartitionMatchesBackup -Tools $tools -State $state -Partition $partition
        Write-VerifiedPartition -Tools $tools -Partition $partition -Image $patched -VerifyDirectory (Join-Path $state.runPath 'verify/boot')
        $state.touchedPartitions = @($state.touchedPartitions) + @($partition) | Select-Object -Unique
        Set-RunStage -State $state -Stage 'PatchedBootFlashed' -Message "$partition flashed and read-back verified"
    }

    if ($state.stage -eq 'PatchedBootFlashed') {
        Reset-FromEdl -Tools $tools
        Set-RunStage -State $state -Stage 'AwaitingAndroid' -Message 'Device reset; factory reset/setup and renewed ADB authorization may be required'
    }

    if ($state.stage -eq 'AwaitingAndroid') {
        $ready = Wait-ForPostUnlockAndroid -Tools $tools -State $state -NonInteractive:$NonInteractive
        if (-not $ready) { return $state }
        Install-And-VerifyMagisk -Tools $tools -State $state -NonInteractive:$NonInteractive
    }

    if ($state.stage -eq 'RootVerified') {
        @"
Root verified at $([DateTime]::UtcNow.ToString('o')).

Recovery command (from the project root):
  pwsh ./Root-NoteAir5C.ps1 -Command Restore -RunPath `"$($state.runPath)`"

Keep the entire run directory private and offline. It contains device-unique
identity and calibration partitions. Restore stock before accepting a BOOX OTA.
"@ | Set-Content -LiteralPath (Join-Path $state.runPath 'RECOVERY.txt') -Encoding UTF8
        Write-Pass "Note Air 5C root workflow complete. Recovery material: $($state.runPath)"
    }
    $state
}

function Confirm-RestoreConsent {
    param([switch]$AcknowledgeDataWipe, [switch]$NonInteractive)
    if ($AcknowledgeDataWipe) { return }
    if ($NonInteractive) { throw 'Restore requires -AcknowledgeDataWipe in non-interactive mode.' }
    Write-Warning 'Restoring the original locked devinfo changes verified-boot state again and can require another factory reset.'
    $answer = Read-Host 'Type RESTORE STOCK to continue'
    if ($answer -cne 'RESTORE STOCK') { throw 'Restore cancelled; consent phrase did not match.' }
}

function Assert-RestoreTargetPreflight {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)]$State,
        [switch]$ForceEmergencyRestore
    )
    $adbState = Invoke-Adb -Tools $Tools -Arguments @('get-state') -AllowFailure
    if ($adbState.ExitCode -eq 0 -and $adbState.Output.Trim() -eq 'device') {
        $current = Get-DeviceDiagnostic -ProjectRoot $ProjectRoot -Tools $Tools
        if ($current.fingerprint -ne $State.device.fingerprint) {
            throw "Restore target firmware differs from this run. Run='$($State.device.fingerprint)' current='$($current.fingerprint)'. Restore stock before an OTA; do not cross-flash old boot data."
        }
        if ($current.slot -ne $State.device.slot) {
            throw "Restore target active slot differs from this run ($($State.device.slot) -> $($current.slot)). Refusing to restore the wrong slot."
        }
        Write-Pass "Restore target matches the run fingerprint and active slot $($current.slot)"
        return
    }
    if (-not $ForceEmergencyRestore) {
        throw 'Android/ADB is unavailable, so firmware and active slot cannot be revalidated. For a genuinely non-booting tablet already in EDL, rerun Restore with -ForceEmergencyRestore after confirming this is the matching run.'
    }
    Write-Warning 'Emergency restore override accepted: Android is unavailable, so the exact fingerprint and active slot cannot be revalidated. EDL partition/hash gates still apply.'
}

function Invoke-NoteAir5CRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunPath,
        [switch]$AcknowledgeDataWipe,
        [switch]$ForceEmergencyRestore,
        [switch]$NonInteractive
    )
    $tools = Get-ToolContext $ProjectRoot
    $state = Load-RunState $RunPath
    $tools.AdbSerial = [string]$state.device.adbSerial
    Confirm-RestoreConsent -AcknowledgeDataWipe:$AcknowledgeDataWipe -NonInteractive:$NonInteractive
    $backup = Join-Path $state.runPath 'backup'
    Test-BackupManifest -BackupRoot $backup | Out-Null
    Assert-RestoreTargetPreflight -ProjectRoot $ProjectRoot -Tools $tools -State $state -ForceEmergencyRestore:$ForceEmergencyRestore
    [void](Ensure-EdlMode -Tools $tools)

    $slot = ConvertTo-SafeSlot ([string]$state.device.slot)
    $bootPartition = "boot_$slot"
    $stockBoot = Get-BackupEntry -BackupRoot $backup -Partition $bootPartition
    $work = Join-Path $state.runPath 'work'
    $currentBoot = Join-Path $state.runPath "verify/restore-preflight-$bootPartition.bin"
    Invoke-Edl -Tools $tools -Arguments @('r', $bootPartition, $currentBoot) -Live | Out-Null
    $currentBootHash = Get-FileSha256 $currentBoot
    $allowedBootHashes = @((Get-FileSha256 $stockBoot))
    if ($state.PSObject.Properties.Name -contains 'patchedBoot' -and $state.patchedBoot.sha256) {
        $allowedBootHashes += ([string]$state.patchedBoot.sha256).ToLowerInvariant()
    }
    $patchedBootHash = if ($allowedBootHashes.Count -gt 1) { $allowedBootHashes[1] } else { $null }
    if (-not (Test-KnownRestoreBootHash -Current $currentBootHash -Stock $allowedBootHashes[0] -Patched $patchedBootHash)) {
        if (-not $ForceEmergencyRestore) {
            throw "Current $bootPartition hash is not stock or the patched image recorded by this run: $currentBootHash. Refusing an unexpected overwrite."
        }
        Write-Warning "Emergency override accepted for unexpected $bootPartition hash $currentBootHash."
    } else {
        Write-Pass "$bootPartition matches a boot image recorded by this run"
    }

    # Validate and prepare every source before the first restore write. Preserve
    # boot-maintained rollback/security state while returning only the two
    # verified-boot flags to locked.
    $currentDevinfo = Join-Path $work 'devinfo-restore-current.bin'
    $lockedDevinfo = Join-Path $work 'devinfo-restored-locked.bin'
    Invoke-Edl -Tools $tools -Arguments @('r', 'devinfo', $currentDevinfo) -Live | Out-Null
    $backupDevinfo = Get-BackupEntry -BackupRoot $backup -Partition 'devinfo'
    $compatibility = Test-DevinfoRuntimeCompatibility -Backup $backupDevinfo -Current $currentDevinfo -AllowUnlockFlagDifferences
    $lockPatch = New-LockedDevinfo -Source $currentDevinfo -Destination $lockedDevinfo

    Write-VerifiedPartition -Tools $tools -Partition $bootPartition -Image $stockBoot -VerifyDirectory (Join-Path $state.runPath 'verify/restore-stock')
    Write-VerifiedPartition -Tools $tools -Partition 'devinfo' -Image $lockedDevinfo -VerifyDirectory (Join-Path $state.runPath 'verify/restore-stock')
    Set-RunStage -State $state -Stage 'StockRestored' -Message "Original $bootPartition restored; devinfo lock flags restored while preserving runtime date $($compatibility.CurrentRuntimeDateUtc)"
    Reset-FromEdl -Tools $tools
    Write-Pass 'Original boot and lock-state partition restored. A factory reset may be required on next boot.'
    $state
}

function Invoke-NoteAir5CVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RunPath,
        [switch]$NonInteractive
    )
    $paths = Get-ProjectPaths $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($RunPath)) {
        $candidate = Get-ChildItem -LiteralPath $paths.Runs -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'state.json') } |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $candidate) { throw 'Verify requires an existing run.' }
        $RunPath = $candidate.FullName
    }

    $state = Load-RunState $RunPath
    $tools = Get-ToolContext $ProjectRoot
    $tools.AdbSerial = [string]$state.device.adbSerial
    Wait-AdbDevice -Tools $tools -TimeoutSeconds 60
    $current = Get-DeviceDiagnostic -ProjectRoot $ProjectRoot -Tools $tools
    if ($current.fingerprint -ne $state.device.fingerprint) {
        throw "Live firmware differs from the run: '$($state.device.fingerprint)' -> '$($current.fingerprint)'."
    }
    if ($current.slot -ne $state.device.slot) {
        throw "Live active slot differs from the run: '$($state.device.slot)' -> '$($current.slot)'."
    }

    $magisk = (Invoke-Adb -Tools $tools -Arguments @('shell', 'magisk', '-v') -AllowFailure).Output.Trim()
    $rootShell = Invoke-Adb -Tools $tools -Arguments @('shell', 'su', '-c', 'id') -AllowFailure
    if ($current.flashLocked -ne '0') { throw "Live flash lock property is '$($current.flashLocked)', expected 0." }
    if ($current.verifiedBootState -ne 'orange') { throw "Live verified-boot state is '$($current.verifiedBootState)', expected orange." }
    if ($magisk -notmatch '30\.7|30700') { throw "Pinned Magisk 30.7 is not active: '$magisk'." }
    if ($rootShell.ExitCode -ne 0 -or $rootShell.Output -notmatch 'uid=0\(root\)') {
        throw "Live root-shell proof failed. Enable [SharedUID] Shell in Magisk > Superuser, then retry. Output: '$($rootShell.Output.Trim())'"
    }

    $proof = [pscustomobject]@{
        atUtc = [DateTime]::UtcNow.ToString('o')
        run = [string]$state.runPath
        fingerprint = [string]$current.fingerprint
        slot = [string]$current.slot
        flashLocked = [string]$current.flashLocked
        verifiedBootState = [string]$current.verifiedBootState
        magisk = $magisk
        rootShell = $rootShell.Output.Trim()
    }
    $state | Add-Member -NotePropertyName verification -NotePropertyValue $proof -Force
    Save-RunState -State $state
    Write-Pass "Live root verified: Magisk $magisk; $($proof.rootShell)"
    $proof
}

function Get-NoteAir5CStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RunPath,
        [switch]$NonInteractive
    )
    if ([string]::IsNullOrWhiteSpace($RunPath)) {
        $paths = Get-ProjectPaths $ProjectRoot
        $candidate = Get-ChildItem -LiteralPath $paths.Runs -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'state.json') } |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $candidate) { throw 'No run state exists yet.' }
        $RunPath = $candidate.FullName
    }
    $state = Load-RunState $RunPath
    [pscustomobject]@{
        Run = $state.runPath
        Stage = $state.stage
        Model = $state.device.model
        Fingerprint = $state.device.fingerprint
        Slot = $state.device.slot
        Profile = $state.device.profileId
        TouchedPartitions = @($state.touchedPartitions) -join ', '
        LastJournalEntry = @($state.journal)[-1].message
    } | Format-List
    $state
}

Export-ModuleMember -Function @(
    'Get-HostPlatform',
    'Get-AndroidArtifactId',
    'Get-AndroidToolsDirectory',
    'Get-EdlVenvDirectory',
    'Get-VenvPythonPath',
    'ConvertFrom-PortablePath',
    'Install-NoteAir5CToolchain',
    'Invoke-NoteAir5CDiagnose',
    'Invoke-NoteAir5CBackup',
    'Invoke-NoteAir5CRoot',
    'Invoke-NoteAir5CRestore',
    'Invoke-NoteAir5CVerify',
    'Get-NoteAir5CStatus',
    'Test-NoteAir5CModel',
    'ConvertTo-SafeSlot',
    'Find-FirmwareProfile',
    'Test-GptPartitions',
    'Get-PrefixSha256',
    'Test-KnownRestoreBootHash',
    'Test-DevinfoRuntimeCompatibility',
    'New-PatchedDevinfo',
    'New-LockedDevinfo'
)
