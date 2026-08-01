# ZIO Universal Installer for Windows (PowerShell)

# --- Configuration ---
$owner = "iamraphealc"
$repo = "zio"
$baseAssetName = "zio" # Prefix for all assets
$windowsExt = ".exe"   # Extension for Windows assets
$installName = "zio"   # Name of the executable after installation

# Stop on first error
$ErrorActionPreference = "Stop"

# --- Utility Functions ---
function Get-PlatformInfo {
    # Determine architecture
    $arch = ""
    
    if ([Environment]::Is64BitOperatingSystem) {
        $arch = "x86_64"
    } else {
        $arch = "x86"
    }
    
    return @{
        OS = "windows" 
        Arch = $arch
    }
}

# --- Main Logic ---
Write-Host "--- ZIO Universal Installer (PowerShell) ---" -ForegroundColor Cyan

# Get platform info
$platformInfo = Get-PlatformInfo
$OS = $platformInfo.OS
$ARCH = $platformInfo.Arch

Write-Host "Detected OS: **$OS**"
Write-Host "Detected Architecture: **$ARCH**"

# Construct Asset Name based on architecture
if ($ARCH -eq "x86_64" -or $ARCH -eq "x86") {
    $assetName = "${baseAssetName}-${ARCH}-windows${windowsExt}"
    $installName = "${installName}${windowsExt}"
} else {
    Write-Host "Error: No Windows asset found for architecture $ARCH." -ForegroundColor Red
    exit 1
}

Write-Host "Target Asset Name: **$assetName**"
Write-Host "Target Executable Name: **$installName**"

# Fetch Latest Version
Write-Host "Fetching latest version from GitHub..." -ForegroundColor Yellow
try {
    $latestVersion = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$owner/$repo/main/version").Trim()
    Write-Host $latestVersion
    
    if (-not $latestVersion) {
        throw "Could not retrieve latest version tag."
    }
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Latest version: **$latestVersion**" -ForegroundColor Green

# Construct Download URL
$downloadUrl = "https://github.com/$owner/$repo/releases/download/$latestVersion/$assetName"

Write-Host "Downloading from: **$downloadUrl**"

# Download the Asset
$tempFile = Join-Path $env:TEMP $assetName
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing
} catch {
    Write-Host "Error downloading file: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Download complete." -ForegroundColor Green

# Determine Install Directory
# Multiple options in order of preference
$installOptions = @(
    "$env:LOCALAPPDATA\Microsoft\WindowsApps",           # Windows Apps folder (in PATH by default)
    "$env:USERPROFILE\bin",                              # User's bin folder
    "$env:USERPROFILE\AppData\Local\Programs\zio",       # Local programs folder
    "C:\ProgramData\zio"                                 # System-wide installation
)

$installDir = $null
foreach ($dir in $installOptions) {
    if ($dir -and (Test-Path (Split-Path $dir -Parent))) {
        $installDir = $dir
        break
    }
}

# Create directory if it doesn't exist
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

Write-Host "Installing to directory: **$installDir**"

# Move and Rename (Install)
$installPath = Join-Path $installDir $installName
try {
    Move-Item -Path $tempFile -Destination $installPath -Force
} catch {
    Write-Host "Error moving file: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Installation complete as: **$installPath**" -ForegroundColor Green
Write-Host ""

# Check if in PATH and provide guidance
function Test-CommandInPath($commandName) {
    $paths = $env:PATH -split ';'
    foreach ($path in $paths) {
        if (Test-Path (Join-Path $path $commandName)) {
            return $true
        }
    }
    return $false
}

# Check current PATH
if (Test-CommandInPath $installName) {
    Write-Host "Installation successful! Run: **$installName**" -ForegroundColor Green
} else {
    # Check if we installed to a directory already in PATH
    $pathInEnv = $false
    $paths = $env:PATH -split ';'
    foreach ($path in $paths) {
        if ($installDir -eq $path) {
            $pathInEnv = $true
            break
        }
    }
    
    if ($pathInEnv) {
        Write-Host "Installation successful! Run: **$installName**" -ForegroundColor Green
    } else {
        Write-Host "⚠ Installation successful, but the executable is not in your PATH." -ForegroundColor Yellow
        Write-Host "`nTo add the installation directory to your PATH:" -ForegroundColor Yellow
        Write-Host "1. Press Win + X and select 'System'" -ForegroundColor Yellow
        Write-Host "2. Click 'Advanced system settings'" -ForegroundColor Yellow
        Write-Host "3. Click 'Environment Variables'" -ForegroundColor Yellow
        Write-Host "4. In 'User variables', edit 'PATH'" -ForegroundColor Yellow
        Write-Host "5. Add this directory: $installDir" -ForegroundColor Yellow
        Write-Host "`nFor now, you can run: $installPath" -ForegroundColor Yellow
        
        # Offer to add to PATH for current session
        Write-Host "`nWould you like to add to PATH for the current PowerShell session? (Y/N)" -ForegroundColor Cyan
        $response = Read-Host
        if ($response -match '^[Yy]') {
            $env:PATH += ";$installDir"
            Write-Host "Added to current session PATH. You can now run: $installName" -ForegroundColor Green
        }
    }
}

Write-Host "`nVerifying installation..." -ForegroundColor Cyan
if (Test-Path $installPath) {
    $fileInfo = Get-Item $installPath
    Write-Host "File size: $($fileInfo.Length) bytes" -ForegroundColor Green
    
    # Simple check - just try to get version
    try {
        $versionOutput = & $installPath --version 2>&1
        Write-Host "Executable runs. Output: $versionOutput" -ForegroundColor Green
    } catch {
        Write-Host "Executable installed (but version check failed)" -ForegroundColor Green
    }
} else {
    Write-Host "Installation verification failed" -ForegroundColor Red
}