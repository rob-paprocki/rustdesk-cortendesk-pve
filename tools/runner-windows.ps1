<#
.SYNOPSIS
  Make this Windows machine a self-hosted GitHub Actions runner for rdgen's Windows builds (rustdesk-server-pve).

.DESCRIPTION
  Copy this file to the Windows VM and run it in an elevated Windows PowerShell:

      powershell -ExecutionPolicy Bypass -File runner-windows.ps1 -Repo owner/name

  It installs what GitHub's windows-2022 image brings along and the rdgen Windows workflows use:
  Chocolatey, Git for Windows (bash on PATH), PowerShell 7, Python 3.12, NuGet, the .NET 8 SDK, ImageMagick, 7-Zip,
  jq and unzip (flutter-action needs them), and Visual Studio 2022 Build Tools with the C++ workload (MSVC v143
  and v142, Windows SDK, CMake, ATL, NuGet build tasks). It enables long paths, creates the local administrator
  account rdgen-runner for the runner service,
  downloads the GitHub Actions runner (its SHA-256 checked against GitHub's release digest) and registers it with
  the label rdgen-windows. Jobs get the tool cache at C:\hostedtoolcache\windows, the same place as on GitHub.

  The registration token comes from GitHub: Settings -> Actions -> Runners -> New self-hosted runner -> Windows, x64
  (copy only the token after --token; it is valid for an hour). It is read without echo and reaches the runner
  through an environment variable: never on a command line, never on disk. The rdgen-runner password is random,
  never shown or stored by this script (Windows keeps it in the service configuration).

  Re-running is safe: installed parts are skipped, and a registered runner stays as it is unless -Reconfigure.
  Then set the repository variable RDGEN_RUNNER_WINDOWS to the label, and Windows builds run here.

  Use a VM that does nothing else: builds run upstream code as a local administrator. Plan for about 60 GB free.
  Not on a domain controller (it has no local accounts).

.PARAMETER Repo
  The private build repository, owner/name (asked if missing).
.PARAMETER Label
  Runner label the workflows target through RDGEN_RUNNER_WINDOWS (default rdgen-windows).
.PARAMETER Reconfigure
  Register again (a new token), e.g. after the runner was removed on GitHub.
.PARAMETER NoRegister
  Only install and update the tools.
.PARAMETER NoDefenderExclusions
  Leave Microsoft Defender scanning the build folders (builds get much slower).
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Label = 'rdgen-windows',
    [string]$Name = "rdgen-windows-$env:COMPUTERNAME",
    [string]$InstallDir = 'C:\actions-runner',
    [string]$WorkDir = 'C:\a',
    [switch]$Reconfigure,
    [switch]$NoRegister,
    [switch]$NoDefenderExclusions
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell downloads crawl with the progress bar on

$RunnerAccount = 'rdgen-runner'
$ToolCache = 'C:\hostedtoolcache\windows'   # GitHub's location; the workflows follow RUNNER_TOOL_CACHE
$script:RebootNeeded = $false

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Stop-Setup([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($user) { $env:Path = "$machine;$user" } else { $env:Path = $machine }
}

function Invoke-Native([scriptblock]$Command) {
    # Windows PowerShell turns a native program's stderr into terminating errors under 'Stop'
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>$null } finally { $ErrorActionPreference = $saved }
}

function Install-ChocoPackage {
    param([string]$Package, [string[]]$Extra = @())
    Write-Host "    $Package"
    & choco install $Package -y --no-progress @Extra
    $code = $LASTEXITCODE
    if ($code -eq 1641 -or $code -eq 3010) { $script:RebootNeeded = $true }
    elseif ($code -ne 0) { Stop-Setup "choco install $Package failed (exit $code)" }
}

function New-RandomPassword {
    # 40 characters with every character class; no quotes, %, ^, &, |, <, > or ! (nothing a shell could reinterpret)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_=+*#@~.,:;?')
    $all = -join $sets
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $bytes = New-Object byte[] 128
        $rng.GetBytes($bytes)
        $chars = New-Object System.Collections.Generic.List[char]
        for ($i = 0; $i -lt $sets.Count; $i++) { $chars.Add($sets[$i][$bytes[$i] % $sets[$i].Length]) }
        for ($i = $sets.Count; $i -lt 40; $i++) { $chars.Add($all[$bytes[$i] % $all.Length]) }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {   # shuffle, so the four fixed classes are not always first
            $j = $bytes[40 + $i] % ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    } finally {
        $rng.Dispose()
    }
}

function Read-RegistrationToken {
    Write-Host ''
    Write-Host "Registration token: on GitHub open https://github.com/$Repo/settings/actions/runners/new"
    Write-Host '(Windows, x64) and copy only the value after --token. It is valid for one hour.'
    $secure = Read-Host -AsSecureString 'Token (not shown)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $plain = $plain.Trim()
    if ($plain -notmatch '^[A-Za-z0-9]{20,}$') { Stop-Setup 'that does not look like a runner registration token' }
    return $plain
}

function Set-RunnerAccount([string]$Password) {
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $user = Get-LocalUser -Name $RunnerAccount -ErrorAction SilentlyContinue
    if ($user) {
        Set-LocalUser -Name $RunnerAccount -Password $secure -PasswordNeverExpires $true
        Enable-LocalUser -Name $RunnerAccount
    } else {
        New-LocalUser -Name $RunnerAccount -Password $secure -PasswordNeverExpires -AccountNeverExpires `
            -Description 'GitHub Actions runner for rdgen builds' | Out-Null
    }
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'   # Administrators, whatever the system language calls it
    try { Add-LocalGroupMember -Group $admins -Member $RunnerAccount -ErrorAction Stop }
    catch { if ($_.Exception.GetType().Name -ne 'MemberExistsException') { throw } }
}

function Get-RunnerService {
    $dir = $InstallDir.TrimEnd('\').ToLowerInvariant()
    Get-CimInstance -ClassName Win32_Service | Where-Object {
        $_.PathName -and $_.PathName.ToLowerInvariant().Contains($dir) -and $_.PathName -match 'RunnerService\.exe'
    } | Select-Object -First 1
}

function Remove-LocalRunnerConfig {
    # the runner refuses to configure over an old configuration; --replace then takes over the old name on GitHub
    $svc = Get-RunnerService
    if ($svc) {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc.Name | Out-Null
    }
    foreach ($file in @('.runner', '.credentials', '.credentials_rsaparams', '.service')) {
        Remove-Item -LiteralPath (Join-Path $InstallDir $file) -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------- checks
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-Setup 'run this in an elevated PowerShell (Run as administrator)'
}
if (-not [Environment]::Is64BitOperatingSystem) { Stop-Setup 'a 64-bit Windows is required' }
if ((Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4) {
    Stop-Setup 'this is a domain controller: it has no local accounts, and builds should not run on it'
}
if (-not $Repo) { $Repo = (Read-Host 'Build repository (owner/name)').Trim() }
if ($Repo -notmatch '^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$') {
    Stop-Setup "repository must look like owner/name, not '$Repo'"
}
if ($Label -notmatch '^[A-Za-z0-9._-]{1,64}$') { Stop-Setup "invalid label '$Label'" }
if ($Name -notmatch '^[A-Za-z0-9._-]{1,64}$') { Stop-Setup "invalid runner name '$Name'" }
$free = (Get-PSDrive -Name C).Free / 1GB
if ($free -lt 60) {
    Write-Host ("WARNING: C: has {0:N0} GB free; a build needs about 60 GB." -f $free) -ForegroundColor Yellow
}
$tls12 = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12

# ---------------------------------------------------------------------------------------------- tools
Update-SessionPath
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing Chocolatey'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    # Chocolatey's official installer, run from a file rather than piped into Invoke-Expression
    $chocoInstaller = Join-Path $env:TEMP 'chocolatey-install.ps1'
    Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $chocoInstaller -UseBasicParsing
    try { & $chocoInstaller } finally { Remove-Item -LiteralPath $chocoInstaller -Force -ErrorAction SilentlyContinue }
    Update-SessionPath
    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) { Stop-Setup 'Chocolatey did not install' }
}

Write-Step 'Installing build tools with Chocolatey (Visual Studio Build Tools alone can take 30 minutes)'
# like GitHub's image: Git's bin (bash) on PATH and symlinks on; installer-default line endings
Install-ChocoPackage 'git' @('--params', "'/GitAndUnixToolsOnPath /Symlinks /NoShellIntegration'")
Install-ChocoPackage 'powershell-core'
Install-ChocoPackage 'python312'
Install-ChocoPackage 'nuget.commandline'
Install-ChocoPackage 'dotnet-8.0-sdk'
Install-ChocoPackage 'imagemagick.app'
Install-ChocoPackage '7zip'
Install-ChocoPackage 'jq'      # flutter-action stops without it
Install-ChocoPackage 'unzip'
Install-ChocoPackage 'visualstudio2022buildtools'
# the C++ workload with its recommended set: MSVC v143 x64/x86, Windows 11 SDK, CMake tools
Install-ChocoPackage 'visualstudio2022-workload-vctools'
Update-SessionPath

# the workflows call python3, as on GitHub's image; python.org's Windows layout only has python.exe
$pyExe = Join-Path $env:SystemDrive 'Python312\python.exe'
if (-not (Test-Path -LiteralPath $pyExe)) { Stop-Setup "Python 3.12 is not where Chocolatey puts it ($pyExe)" }
$py3 = Join-Path (Split-Path $pyExe -Parent) 'python3.exe'
if (Test-Path -LiteralPath $py3) { Remove-Item -LiteralPath $py3 -Force }   # a hard link would keep an older python.exe
New-Item -ItemType HardLink -Path $py3 -Target $pyExe | Out-Null

# components beyond the workload's recommended set: v142 (RustDeskTempTopMostWindow builds Release|x64 with it),
# ATL, NuGet build tasks (the WiX 4 SDK-style MSI project) and the .NET Framework 4.8 SDK
$vsComponents = @(
    'Microsoft.VisualStudio.ComponentGroup.VC.Tools.142.x86.x64',
    'Microsoft.VisualStudio.Component.VC.ATL',
    'Microsoft.VisualStudio.Component.NuGet.BuildTools',
    'Microsoft.Net.Component.4.8.SDK'
)
$installerDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vswhere = Join-Path $installerDir 'vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    Stop-Setup 'vswhere.exe not found: the Visual Studio Build Tools did not install'
}
$vsPath = & $vswhere -products '*' -requires Microsoft.VisualStudio.Workload.VCTools -latest -property installationPath
if (-not $vsPath) { Stop-Setup 'no Visual Studio 2022 Build Tools with the C++ workload found' }
$complete = & $vswhere -products '*' -requires $vsComponents -latest -property installationPath
if (-not $complete) {
    Write-Step 'Adding Visual Studio components (MSVC v142, ATL, NuGet build tasks, .NET Framework 4.8 SDK)'
    # Start-Process joins its arguments without quoting them, and the install path has spaces
    $vsArgs = @('modify', '--installPath', ('"' + $vsPath + '"'), '--quiet', '--norestart')
    foreach ($component in $vsComponents) { $vsArgs += @('--add', $component) }
    # the installer may not be started from its own directory
    Push-Location $env:TEMP
    try { $proc = Start-Process -FilePath (Join-Path $installerDir 'setup.exe') -ArgumentList $vsArgs -Wait -PassThru }
    finally { Pop-Location }
    if ($proc.ExitCode -eq 1641 -or $proc.ExitCode -eq 3010) { $script:RebootNeeded = $true }
    elseif ($proc.ExitCode -ne 0) {
        Stop-Setup "Visual Studio installer modify failed (exit $($proc.ExitCode)); logs: $env:TEMP\dd_*.log"
    }
}

Write-Step 'System settings'
$fsKey = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem'
[Microsoft.Win32.Registry]::SetValue($fsKey, 'LongPathsEnabled', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
$git = (Get-Command git.exe -ErrorAction Stop).Source
& $git config --system core.longpaths true
$safe = @(Invoke-Native { & $git config --system --get-all safe.directory })
if ($safe -notcontains '*') { & $git config --system --add safe.directory '*' }
foreach ($dir in @($ToolCache, 'C:\vcpkg', $WorkDir, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
if (-not $NoDefenderExclusions -and (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    try {
        $excluded = @($WorkDir, 'C:\vcpkg', 'C:\hostedtoolcache', $InstallDir, "C:\Users\$RunnerAccount")
        Add-MpPreference -ExclusionPath $excluded
    } catch {
        Write-Host 'WARNING: no Microsoft Defender exclusions added; builds will be slower.' -ForegroundColor Yellow
    }
}
if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\bash.exe')) {
    Write-Host "NOTE: WSL's bash.exe is installed; the runner's PATH puts Git's bash first." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------------------------- runner
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'config.cmd'))) {
    Write-Step 'Downloading the GitHub Actions runner'
    $headers = @{ 'User-Agent' = 'rdgen-runner-setup'; 'Accept' = 'application/vnd.github+json' }
    $releaseUrl = 'https://api.github.com/repos/actions/runner/releases/latest'
    $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match '^actions-runner-win-x64-[0-9.]+\.zip$' } |
        Select-Object -First 1
    if (-not $asset) { Stop-Setup 'no win-x64 runner in the latest actions/runner release' }
    $digest = ''
    if ($asset.PSObject.Properties['digest']) { $digest = [string]$asset.digest }
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { $want = $Matches[1].ToLowerInvariant() }
    else { Stop-Setup 'GitHub gave no SHA-256 digest for the runner download; not installing it unchecked' }
    $zip = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($got -ne $want) {
        Remove-Item -LiteralPath $zip -Force
        Stop-Setup "the runner download does not match GitHub's digest (got $got, want $want)"
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force
    Remove-Item -LiteralPath $zip -Force
    Write-Host "    $($asset.name), SHA-256 verified"
}

$configured = Test-Path -LiteralPath (Join-Path $InstallDir '.runner')
if ($NoRegister) {
    Write-Step 'Not registering (-NoRegister)'
} elseif ($configured -and -not $Reconfigure) {
    Write-Step 'The runner is already registered (use -Reconfigure to register it again)'
} else {
    if ($configured) { Remove-LocalRunnerConfig }
    $token = Read-RegistrationToken
    $password = New-RandomPassword
    Write-Step "Registering runner '$Name' (label $Label) as the service account $RunnerAccount"
    Set-RunnerAccount $password
    $rc = 1
    Push-Location $InstallDir
    try {
        # both secrets travel as ACTIONS_RUNNER_INPUT_<arg> variables, which the runner reads like its arguments
        $env:ACTIONS_RUNNER_INPUT_TOKEN = $token
        $env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD = $password
        & .\config.cmd --unattended --replace --url "https://github.com/$Repo" --labels $Label --name $Name `
            --work $WorkDir --runasservice --windowslogonaccount "$env:COMPUTERNAME\$RunnerAccount"
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
        Remove-Item -Path Env:\ACTIONS_RUNNER_INPUT_TOKEN -ErrorAction SilentlyContinue
        Remove-Item -Path Env:\ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
        $token = $null
        $password = $null
    }
    if ($rc -ne 0) {
        Stop-Setup "registration failed (exit $rc). An expired token? Get a new one and run again with -Reconfigure."
    }
}

# What jobs see: the tool cache where the workflows expect it, and today's PATH (services keep the PATH they started
# with until a reboot). Git's bin goes first, so `shell: bash` is Git's bash and never WSL's.
Write-Step 'Runner environment (.env)'
$envFile = Join-Path $InstallDir '.env'
$lines = @()
if (Test-Path -LiteralPath $envFile) {
    $ours = '^(RUNNER_TOOL_CACHE|AGENT_TOOLSDIRECTORY|PATH)='
    $lines = @(Get-Content -LiteralPath $envFile | Where-Object { $_ -and $_ -notmatch $ours })
}
# Git's own bin\bash.exe (git.exe may resolve from cmd\ or mingw64\bin, depending on the PATH option)
$gitBin = $null
$dir = Split-Path $git -Parent
while ($dir) {
    if (Test-Path -LiteralPath (Join-Path $dir 'bin\bash.exe')) { $gitBin = Join-Path $dir 'bin'; break }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir) { break }
    $dir = $parent
}
if (-not $gitBin) { Stop-Setup "Git's bin\bash.exe not found above $git" }
$lines += "RUNNER_TOOL_CACHE=$ToolCache"
$lines += "AGENT_TOOLSDIRECTORY=$ToolCache"
$lines += "PATH=$gitBin;$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
[IO.File]::WriteAllLines($envFile, [string[]]$lines)   # UTF-8 without BOM

$svc = Get-RunnerService
if ($svc) {
    Restart-Service -Name $svc.Name -Force
    Write-Host "    service $($svc.Name) restarted"
}

# ---------------------------------------------------------------------------------------------- done
Write-Host ''
Write-Step 'Done'
if ($svc) {
    Write-Host "Check that '$Name' shows as Idle: https://github.com/$Repo/settings/actions/runners"
}
Write-Host "Then set the repository variable RDGEN_RUNNER_WINDOWS = $Label"
Write-Host "  (https://github.com/$Repo/settings/variables/actions), and Windows builds run on this machine."
if ($script:RebootNeeded) {
    Write-Host 'An installer asked for a reboot: restart this VM before the first build.' -ForegroundColor Yellow
}
