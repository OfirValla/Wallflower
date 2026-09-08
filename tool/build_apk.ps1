<#
.SYNOPSIS
    Builds the Aura Display Android APK.

.DESCRIPTION
    Wraps `flutter build apk` with the bootstrap this repo needs:

      * locates the Flutter SDK, a JDK and the Android SDK, whether they are on
        PATH or installed side-by-side under a toolchain root (see -ToolchainRoot);
      * writes android/local.properties, which is git-ignored and therefore
        absent on a fresh clone -- android/settings.gradle.kts reads flutter.sdk
        from it during pluginManagement and hard-fails without it;
      * lets the Flutter tool inject the Gradle wrapper (also git-ignored) on
        first run;
      * runs `flutter pub get`, then the build, then reports the artifacts.

.PARAMETER Mode
    release (default), profile or debug. Note that debug builds stutter badly
    with a full-screen WebView -- use release on real kiosk hardware.

.PARAMETER SplitPerAbi
    Emit one APK per ABI instead of a single universal APK. Roughly halves the
    per-device download, but you must side-load the matching ABI.

.PARAMETER Clean
    Run `flutter clean` first. Use after changing Gradle or toolchain versions.

.PARAMETER Install
    adb-install the built APK onto the single attached device when done.

.PARAMETER BuildName
    Overrides the version name (pubspec `version:` before the `+`).

.PARAMETER BuildNumber
    Overrides the version code (pubspec `version:` after the `+`).

.PARAMETER ToolchainRoot
    Where to look for a side-by-side flutter\, jdk*\ and android-sdk\ install.
    Defaults to $env:AURA_TOOLCHAIN_ROOT, then %USERPROFILE%\dev.

.EXAMPLE
    .\tool\build_apk.ps1
    .\tool\build_apk.ps1 -Mode release -SplitPerAbi -Clean
    .\tool\build_apk.ps1 -Install
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'profile', 'debug')]
    [string] $Mode = 'release',

    [switch] $SplitPerAbi,
    [switch] $Clean,
    [switch] $Install,

    [string] $BuildName,
    [string] $BuildNumber,

    [string] $ToolchainRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string] $Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Ok   { param([string] $Message) Write-Host "    $Message" -ForegroundColor Green }
function Die        { param([string] $Message) Write-Host "`nERROR: $Message" -ForegroundColor Red; exit 1 }

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $RepoRoot 'pubspec.yaml'))) {
    Die "pubspec.yaml not found in $RepoRoot -- run this script from inside the repo."
}

if (-not $ToolchainRoot) {
    $ToolchainRoot = if ($env:AURA_TOOLCHAIN_ROOT) { $env:AURA_TOOLCHAIN_ROOT } else { Join-Path $env:USERPROFILE 'dev' }
}

# --------------------------------------------------------------------------
# 1. Locate the toolchain
# --------------------------------------------------------------------------
Write-Step 'Locating toolchain'

# Resolves an executable on PATH, or $null. Written the long way because
# Set-StrictMode makes `(Get-Command ... ).Source` throw when nothing matches.
function Find-OnPath {
    param([string] $Name)
    $found = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

# Flutter: PATH first, then <ToolchainRoot>\flutter.
$flutterBat = Find-OnPath 'flutter.bat'
if (-not $flutterBat) {
    $candidate = Join-Path $ToolchainRoot 'flutter\bin\flutter.bat'
    if (Test-Path $candidate) { $flutterBat = $candidate }
}
if (-not $flutterBat) {
    Die @"
Flutter SDK not found.
Looked on PATH and in $ToolchainRoot\flutter\bin\.
Install it from https://docs.flutter.dev/get-started/install/windows, or point
this script at an existing install with -ToolchainRoot <dir> (expects <dir>\flutter).
"@
}
$FlutterRoot = Split-Path -Parent (Split-Path -Parent $flutterBat)
Write-Info "flutter      $FlutterRoot"

# JDK: JAVA_HOME first, then PATH, then the newest <ToolchainRoot>\jdk*.
$javaHome = $env:JAVA_HOME
if (-not $javaHome -or -not (Test-Path (Join-Path $javaHome 'bin\java.exe'))) {
    $javaExe = Find-OnPath 'java.exe'
    if ($javaExe) {
        $javaHome = Split-Path -Parent (Split-Path -Parent $javaExe)
    } else {
        $javaHome = Get-ChildItem -Path $ToolchainRoot -Directory -Filter 'jdk*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
            Sort-Object Name -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $javaHome) {
    Die @"
No JDK found. The Android Gradle Plugin needs JDK 17 or newer.
Looked at JAVA_HOME, PATH, and $ToolchainRoot\jdk*.
Get one from https://adoptium.net/temurin/releases/?version=17.
"@
}
$env:JAVA_HOME = $javaHome

# The project compiles at source/target 17, so anything older cannot work.
$javaVersionLine = (& (Join-Path $javaHome 'bin\java.exe') -version 2>&1 | Select-Object -First 1) -as [string]
if ($javaVersionLine -match '"(\d+)') {
    $javaMajor = [int]$Matches[1]
    if ($javaMajor -lt 17) {
        Die "JDK 17+ required (android/app/build.gradle.kts compiles at 17); found $javaMajor at $javaHome."
    }
}
Write-Info "java         $javaHome  ($javaVersionLine)"

# Android SDK: env vars first, then the standard location, then the toolchain root.
$androidSdk = $env:ANDROID_SDK_ROOT
if (-not $androidSdk) { $androidSdk = $env:ANDROID_HOME }
if (-not $androidSdk -or -not (Test-Path $androidSdk)) {
    foreach ($candidate in @(
            (Join-Path $ToolchainRoot 'android-sdk'),
            (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if (Test-Path $candidate) { $androidSdk = $candidate; break }
    }
}
if (-not $androidSdk -or -not (Test-Path $androidSdk)) {
    Die @"
Android SDK not found.
Looked at ANDROID_SDK_ROOT, ANDROID_HOME, $ToolchainRoot\android-sdk and
$env:LOCALAPPDATA\Android\Sdk.
Install the command-line tools and then:
  sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
"@
}
$env:ANDROID_SDK_ROOT = $androidSdk
$env:ANDROID_HOME     = $androidSdk
Write-Info "android sdk  $androidSdk"

# Put our picks ahead of anything else on PATH for the child processes.
$env:PATH = @(
    (Join-Path $FlutterRoot 'bin'),
    (Join-Path $javaHome 'bin'),
    (Join-Path $androidSdk 'platform-tools'),
    $env:PATH
) -join ';'

# --------------------------------------------------------------------------
# 2. Bootstrap the git-ignored Gradle inputs
# --------------------------------------------------------------------------
Write-Step 'Preparing android/local.properties'

# settings.gradle.kts reads flutter.sdk out of this file during pluginManagement,
# i.e. before the Flutter Gradle plugin has a chance to create it. It is
# git-ignored, so a fresh clone has none and configuration fails outright.
# Gradle .properties files are Java-escaped: backslashes must be doubled.
$localProps = Join-Path $RepoRoot 'android\local.properties'
$escape     = { param($p) $p -replace '\\', '\\' -replace ':', '\:' }
@(
    "sdk.dir=$(& $escape $androidSdk)"
    "flutter.sdk=$(& $escape $FlutterRoot)"
) | Set-Content -Path $localProps -Encoding ASCII
Write-Ok "wrote $localProps"

# --------------------------------------------------------------------------
# 3. Build
# --------------------------------------------------------------------------
if ($Clean) {
    Write-Step 'flutter clean'
    & $flutterBat clean
    if ($LASTEXITCODE -ne 0) { Die "flutter clean failed ($LASTEXITCODE)." }
}

Write-Step 'flutter pub get'
Push-Location $RepoRoot
try {
    & $flutterBat pub get
    if ($LASTEXITCODE -ne 0) { Die "flutter pub get failed ($LASTEXITCODE)." }

    $buildArgs = @('build', 'apk', "--$Mode")
    if ($SplitPerAbi) { $buildArgs += '--split-per-abi' }
    if ($BuildName)   { $buildArgs += @('--build-name', $BuildName) }
    if ($BuildNumber) { $buildArgs += @('--build-number', $BuildNumber) }

    Write-Step "flutter $($buildArgs -join ' ')"
    Write-Info 'First run downloads the Gradle distribution and the Android dependencies; expect several minutes.'

    $started = Get-Date
    & $flutterBat @buildArgs
    if ($LASTEXITCODE -ne 0) { Die "flutter build apk failed ($LASTEXITCODE)." }
    $elapsed = (Get-Date) - $started
} finally {
    Pop-Location
}

# --------------------------------------------------------------------------
# 4. Report
# --------------------------------------------------------------------------
Write-Step 'Artifacts'
$outDir = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
$allApks = @(Get-ChildItem -Path $outDir -Filter '*.apk' -ErrorAction SilentlyContinue)
if (-not $allApks) { Die "build reported success but no APK was found in $outDir." }

# Report only what this run produced. Switching between universal and
# -SplitPerAbi leaves the other shape's APKs behind in the same directory, and
# listing those as if they were just built is how someone ends up side-loading
# a stale binary. The 5s slack absorbs clock granularity on the copy step.
$apks = @($allApks | Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-5) } | Sort-Object Name)
if (-not $apks) {
    # Gradle was fully up to date and rewrote nothing. Fall back to name matching.
    $apks = @($allApks | Where-Object { $_.Name -like "*$Mode.apk" } | Sort-Object Name)
    Write-Info 'nothing was rewritten; reporting existing artifacts for this mode'
}
if (-not $apks) { Die "build reported success but no $Mode APK was found in $outDir." }

$stale = @($allApks | Where-Object { $_.Name -notin $apks.Name })
if ($stale) {
    Write-Info "ignoring $($stale.Count) APK(s) in the same directory from an earlier build: $(($stale.Name | Sort-Object) -join ', ')"
}

foreach ($apk in $apks) {
    Write-Ok ("{0,-40} {1,8:N1} MB" -f $apk.Name, ($apk.Length / 1MB))
    Write-Info $apk.FullName
}
Write-Info ("built in {0:mm\:ss}" -f $elapsed)

# The release build type is signed with the debug key (see build.gradle.kts).
# That is fine for side-loaded kiosk units but the key rotates per machine, so
# say so rather than let it surprise someone at update time.
if ($Mode -eq 'release') {
    Write-Host ''
    Write-Host '    NOTE: release is signed with the debug keystore (android/app/build.gradle.kts).' -ForegroundColor Yellow
    Write-Host '          Updates only install over a build signed with the same key -- set up a' -ForegroundColor Yellow
    Write-Host '          real signing config before deploying to devices you cannot re-provision.' -ForegroundColor Yellow
}

if ($Install) {
    Write-Step 'adb install'
    if ($apks.Count -gt 1) { Die 'multiple APKs built; re-run without -SplitPerAbi to auto-install.' }
    & adb install -r $apks[0].FullName
    if ($LASTEXITCODE -ne 0) { Die "adb install failed ($LASTEXITCODE)." }
    Write-Ok 'installed'
    Write-Info 'Provision Device Owner (device must have no accounts):'
    Write-Info '  adb shell dpm set-device-owner com.auradisplay.kiosk/.kiosk.AuraDeviceAdminReceiver'
}
