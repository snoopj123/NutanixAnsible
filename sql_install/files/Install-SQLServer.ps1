#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Silent SQL Server installation script, designed for AAP execution.

.DESCRIPTION
    Handles UNC share mapping, ISO mounting, silent setup.exe execution,
    exit code parsing, post-install service validation, and cleanup.
    Credentials are injected via AAP custom credential environment variables.

.PARAMETER IsoPath
    Path to the SQL Server ISO or extracted setup.exe. Supports UNC paths.
.PARAMETER ShareUser
    Domain account for UNC share access (DOMAIN\user). Leave empty if the
    WinRM service account already has share access.
.PARAMETER SharePassword
    Password for the share account. Leave empty for passthrough auth.
.PARAMETER InstanceName
    SQL instance name. Use MSSQLSERVER for default instance.
.PARAMETER Features
    Comma-separated feature list (e.g. SQLENGINE,FULLTEXT,REPLICATION).
.PARAMETER SqlSysAdminAccounts
    Space-separated list of accounts to grant sysadmin role.
.PARAMETER SqlSvcAccount
    Service account for the SQL Server engine.
.PARAMETER AgtSvcAccount
    Service account for SQL Server Agent.
.PARAMETER SecurityMode
    Windows (default) or SQL (mixed mode). SQL requires SaPwd.
.PARAMETER SaPwd
    SA password. Required when SecurityMode=SQL.
.PARAMETER SqlCollation
    SQL Server collation setting.
.PARAMETER TcpEnabled
    Enable TCP/IP protocol (1=yes, 0=no).
.PARAMETER NpEnabled
    Enable Named Pipes protocol (1=yes, 0=no). Default disabled.
.PARAMETER InstallDataDir
    Directory for SQL data files.
.PARAMETER InstallLogDir
    Directory for SQL log files.
.PARAMETER InstallBackupDir
    Directory for SQL backup files.
.PARAMETER LogPath
    Path for this script's own log file.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [string] $ShareUser             = "",
    [string] $SharePassword         = "",
    [string] $InstanceName          = "MSSQLSERVER",
    [string] $Features              = "SQLENGINE",
    [string] $SqlSysAdminAccounts   = "BUILTIN\Administrators",
    [string] $SqlSvcAccount         = "NT AUTHORITY\NETWORK SERVICE",
    [string] $AgtSvcAccount         = "NT AUTHORITY\NETWORK SERVICE",
    [string] $SecurityMode          = "Windows",
    [string] $SaPwd                 = "",
    [string] $SqlCollation          = "SQL_Latin1_General_CP1_CI_AS",
    [int]    $TcpEnabled            = 1,
    [int]    $NpEnabled             = 0,
    [string] $InstallDataDir        = "D:\SQLData",
    [string] $InstallUserDBDir      = "",
    [string] $InstallUserDBLogDir   = "",
    [string] $InstallTempDBDir      = "",
    [string] $InstallTempDBLogDir   = "",
    [string] $InstallLogDir         = "",
    [string] $InstallBackupDir      = "",
    [string] $LogPath               = "C:\Logs\SQLInstall.log"
)

# ── Logging ───────────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string] $Message,
        [string] $Level = "INFO"
    )
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    Write-Output $entry
    Add-Content -Path $LogPath -Value $entry -Force
}

# ── Ensure log directory exists ───────────────────────────────────────────────
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null

Write-Log "===== SQL Server Silent Install Started ====="
Write-Log "Target Instance : $InstanceName"
Write-Log "Features        : $Features"
Write-Log "Security Mode   : $SecurityMode"
Write-Log "ISO/Source Path : $IsoPath"

# ── Validate source path exists ───────────────────────────────────────────────
if (-not (Test-Path $IsoPath -ErrorAction SilentlyContinue)) {

    # If UNC, attempt to map share first before failing
    if ($IsoPath -notlike "\\*") {
        Write-Log "ERROR: IsoPath '$IsoPath' not found." "ERROR"
        exit 1
    }
}

# ── Map network drive for UNC paths ──────────────────────────────────────────
$MappedDriveLetter = $null

if ($IsoPath -like "\\*") {
    # Extract \\server\share from full UNC path
    $uncParts    = $IsoPath -split '\\' | Where-Object { $_ -ne '' }
    $shareRoot   = "\\$($uncParts[0])\$($uncParts[1])"
    $driveLetter = "Z:"

    Write-Log "UNC path detected. Share root: $shareRoot"

    # Remove any existing Z: mapping
    if (Test-Path "$driveLetter\") {
        net use $driveLetter /delete /yes | Out-Null
        Write-Log "Removed existing $driveLetter mapping."
    }

    if ($ShareUser -ne "" -and $SharePassword -ne "") {
        Write-Log "Mapping $driveLetter to $shareRoot with provided credentials (user: $ShareUser)"
        $mapResult = net use $driveLetter $shareRoot $SharePassword /user:$ShareUser /persistent:no 2>&1
    } else {
        Write-Log "Mapping $driveLetter to $shareRoot using current session credentials"
        $mapResult = net use $driveLetter $shareRoot /persistent:no 2>&1
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Failed to map network drive. $mapResult" "ERROR"
        exit 1
    }

    Write-Log "Network drive mapped: $driveLetter -> $shareRoot"
    $MappedDriveLetter = $driveLetter

    # Rewrite IsoPath to use the mapped drive letter
    $relativePath = $IsoPath -replace [regex]::Escape($shareRoot), ''
    $IsoPath      = "$driveLetter$relativePath"
    Write-Log "Resolved IsoPath: $IsoPath"
}

# ── Validate resolved path ────────────────────────────────────────────────────
if (-not (Test-Path $IsoPath)) {
    Write-Log "ERROR: IsoPath '$IsoPath' not found after share mapping." "ERROR"
    if ($MappedDriveLetter) { net use $MappedDriveLetter /delete /yes | Out-Null }
    exit 1
}

# ── Mount ISO or locate setup.exe directly ────────────────────────────────────
$SetupExe    = $null
$MountedDisk = $null

if ($IsoPath -match "\.iso$") {
    Write-Log "Mounting ISO: $IsoPath"
    $mount       = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $MountedDisk = $IsoPath
    $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
    $SetupExe    = "$driveLetter\setup.exe"
    Write-Log "ISO mounted at $driveLetter"
} elseif ($IsoPath -match "setup\.exe$") {
    $SetupExe = $IsoPath
} else {
    # Assume it's a directory containing setup.exe
    $SetupExe = Join-Path $IsoPath "setup.exe"
}

if (-not (Test-Path $SetupExe)) {
    Write-Log "ERROR: setup.exe not found at '$SetupExe'" "ERROR"
    if ($MountedDisk)      { Dismount-DiskImage -ImagePath $MountedDisk | Out-Null }
    if ($MappedDriveLetter) { net use $MappedDriveLetter /delete /yes | Out-Null }
    exit 1
}

Write-Log "Using setup.exe: $SetupExe"

# ── Build argument list ───────────────────────────────────────────────────────
$setupArgs = @(
    "/Q"
    "/ACTION=Install"
    "/FEATURES=$Features"
    "/INSTANCENAME=$InstanceName"
    "/SQLSVCACCOUNT=$SqlSvcAccount"
    "/AGTSVCACCOUNT=$AgtSvcAccount"
    "/SQLSYSADMINACCOUNTS=$SqlSysAdminAccounts"
    "/SQLCOLLATION=$SqlCollation"
    "/INSTALLSQLDATADIR=$InstallDataDir"
    "/SQLUSERDBDIR=$InstallUserDBDir"
    "/SQLUSERDBLOGDIR=$InstallUserDBLogDir"
    "/SQLTEMPDBDIR=$InstallTempDBDir"
    "/SQLTEMPDBLOGDIR=$InstallTempDBLogDir"
    "/TCPENABLED=$TcpEnabled"
    "/NPENABLED=$NpEnabled"
    "/IACCEPTSQLSERVERLICENSETERMS"
    "/UPDATEENABLED=False"
    "/BROWSERSVCSTARTUPTYPE=Disabled"
    "/AGTSVCSTARTUPTYPE=Automatic"
)

# Mixed mode auth — append SA credentials
if ($SecurityMode -eq "SQL") {
    if ([string]::IsNullOrWhiteSpace($SaPwd)) {
        Write-Log "ERROR: SecurityMode=SQL requires SaPwd to be set." "ERROR"
        if ($MountedDisk)       { Dismount-DiskImage -ImagePath $MountedDisk | Out-Null }
        if ($MappedDriveLetter) { net use $MappedDriveLetter /delete /yes | Out-Null }
        exit 1
    }
    $setupArgs += "/SECURITYMODE=SQL"
    $setupArgs += "/SAPWD=$SaPwd"
}

Write-Log "Launching SQL Server setup (this may take 10-20 minutes)..."

# ── Execute setup ─────────────────────────────────────────────────────────────
$proc = Start-Process -FilePath $SetupExe `
    -ArgumentList $setupArgs `
    -Wait `
    -PassThru `
    -NoNewWindow

$exitCode = $proc.ExitCode
Write-Log "Setup process exited with code: $exitCode"

# ── Dismount ISO ──────────────────────────────────────────────────────────────
if ($MountedDisk) {
    Dismount-DiskImage -ImagePath $MountedDisk | Out-Null
    Write-Log "ISO dismounted."
}

# ── Unmap network drive ───────────────────────────────────────────────────────
if ($MappedDriveLetter) {
    net use $MappedDriveLetter /delete /yes | Out-Null
    Write-Log "Network drive $MappedDriveLetter unmapped."
}

# ── Parse exit code ───────────────────────────────────────────────────────────
switch ($exitCode) {
    0    { Write-Log "SUCCESS: SQL Server installed successfully." }
    3010 { Write-Log "SUCCESS: SQL Server installed — reboot required (exit code 3010)." "WARN" }
    default {
        Write-Log "FAILURE: Setup failed with exit code $exitCode." "ERROR"
        Write-Log "Check setup logs at: C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\" "ERROR"
        exit $exitCode
    }
}

# ── Post-install service validation ──────────────────────────────────────────
Write-Log "Running post-install service validation..."

$svcName = if ($InstanceName -eq "MSSQLSERVER") {
    "MSSQLSERVER"
} else {
    "MSSQL`$$InstanceName"
}

$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue

if ($svc -and $svc.Status -eq "Running") {
    Write-Log "SQL Server service '$svcName' is Running. Install validated successfully."
} else {
    Write-Log "WARNING: Service '$svcName' not found or not running. Manual verification advised." "WARN"
}

Write-Log "===== SQL Server Silent Install Completed ====="
exit $exitCode
