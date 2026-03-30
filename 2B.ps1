<#
.SYNOPSIS
    Steam Manifest Fix

.DESCRIPTION
    Finds the most recently updated installed Steam game using appmanifest_*.acf,
    locates the matching stplug-in Lua file, parses depot IDs, queries SteamCMD API
    for manifest IDs, and downloads manifests from GitHub into Steam's depotcache.

.PARAMETER RetryDelaySeconds
    Delay between retry attempts for manifest downloads
#>

param(
    [int]$RetryDelaySeconds = 3
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "Steam Manifest Downloader (2B Manifes Fix)"

function Write-Header {
    Clear-Host
    Write-Host ""
    $esc = [char]27
    $manifestHubLink = "$esc]8;;https://github.com/SteamAutoCracks/ManifestHub$esc\ManifestHub$esc]8;;$esc\"
    Write-Host ""
     Write-Host "===============================" -ForegroundColor Magenta
     Write-Host "       2B MANIFEST FIX         " -ForegroundColor Magenta
     Write-Host "===============================" -ForegroundColor Magenta
     Write-Host ""
}

function Write-Status {
    param([string]$Message, [ConsoleColor]$Color = "White")
    Write-Host "  [*] $Message" -ForegroundColor $Color
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [+] $Message" -ForegroundColor Green
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "  [-] $Message" -ForegroundColor Red
}

function Write-WarningMsg {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Write-ProgressBar {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label,
        [int]$Width = 40
    )

    $percent = if ($Total -gt 0) { [math]::Round(($Current / $Total) * 100) } else { 0 }
    $filled = [math]::Floor(($Current / [math]::Max($Total, 1)) * $Width)
    $empty = $Width - $filled

    $barFilled = "#" * $filled
    $barEmpty = "-" * $empty

    Write-Host ("`r  {0} [{1}" -f $Label, $barFilled) -NoNewline
    Write-Host $barEmpty -NoNewline -ForegroundColor DarkGray
    Write-Host ("] {0}% ({1}/{2})    " -f $percent, $Current, $Total) -NoNewline
}

function Get-SteamPath {
    $registryPaths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam",
        "HKCU:\SOFTWARE\Valve\Steam"
    )

    foreach ($path in $registryPaths) {
        try {
            $steamPath = (Get-ItemProperty -Path $path -ErrorAction SilentlyContinue).InstallPath
            if (-not $steamPath) {
                $steamPath = (Get-ItemProperty -Path $path -ErrorAction SilentlyContinue).SteamPath
            }
            if ($steamPath -and (Test-Path $steamPath)) {
                return $steamPath
            }
        } catch {}
    }

    return $null
}

function Get-SteamLibraries {
    param([string]$SteamPath)

    $libraries = @()
    $libraries += (Join-Path $SteamPath "steamapps")

    $libFile = Join-Path $SteamPath "steamapps\libraryfolders.vdf"
    if (Test-Path $libFile) {
        $content = Get-Content $libFile -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match '"path"\s+"(.+)"') {
                $libPath = $matches[1].Replace('\\', '\')
                $libraries += (Join-Path $libPath "steamapps")
            }
        }
    }

    return $libraries | Select-Object -Unique
}

function Get-MostRecentGame {
    param([string[]]$Libraries)

    $games = @()

    foreach ($lib in $Libraries) {
        if (-not (Test-Path $lib)) { continue }

        $files = Get-ChildItem -Path $lib -Filter "appmanifest_*.acf" -File -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            $appId = ($file.Name -replace '^appmanifest_|\.acf$','')
            if ($appId -notmatch '^\d+$') { continue }

            $name = "Unknown"
            try {
                $content = Get-Content $file.FullName -ErrorAction Stop
                foreach ($line in $content) {
                    if ($line -match '"name"\s+"(.+)"') {
                        $name = $matches[1]
                        break
                    }
                }
            } catch {}

            $games += [PSCustomObject]@{
                AppId = $appId
                Name = $name
                LastUpdated = $file.LastWriteTime
                ManifestPath = $file.FullName
            }
        }
    }

    if ($games.Count -eq 0) {
        return $null
    }

    return $games | Sort-Object LastUpdated -Descending | Select-Object -First 1
}

function Get-DepotIdsFromLua {
    param([string]$LuaPath)

    $depots = @()
    $content = Get-Content -Path $LuaPath -ErrorAction Stop

    foreach ($line in $content) {
        if ($line -match 'addappid\s*\(\s*(\d+)\s*,\s*\d+\s*,\s*"[a-fA-F0-9]+"') {
            $depots += $matches[1]
        }
    }

    return $depots | Select-Object -Unique
}

function Get-AppInfo {
    param([string]$AppId)

    $url = "https://api.steamcmd.net/v1/info/$AppId"

    try {
        return Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
    } catch {
        return $null
    }
}

function Get-ManifestIdForDepot {
    param(
        [object]$AppInfo,
        [string]$AppId,
        [string]$DepotId
    )

    try {
        $depots = $AppInfo.data.$AppId.depots
        if ($depots.$DepotId -and $depots.$DepotId.manifests -and $depots.$DepotId.manifests.public) {
            return $depots.$DepotId.manifests.public.gid
        }
    } catch {}

    return $null
}

function Try-DownloadUrl {
    param(
        [string]$Url,
        [string]$OutputFile,
        [int]$MaxRetries,
        [string]$Label,
        [int]$RetryDelaySeconds = 3
    )

    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if (Test-Path $OutputFile) {
                Remove-Item $OutputFile -Force -ErrorAction SilentlyContinue
            }

            Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 120 -OutFile $OutputFile -ErrorAction Stop

            if (Test-Path $OutputFile) {
                $fileSize = (Get-Item $OutputFile).Length
                if ($fileSize -gt 0) {
                    return @{ Success = $true; Size = $fileSize; Attempts = $attempt }
                }
            }

            $lastError = "Empty file received"
        } catch {
            $lastError = $_.Exception.Message
        }

        if ($attempt -lt $MaxRetries) {
            Write-Host "      Attempt $attempt failed ($Label): $lastError" -ForegroundColor DarkYellow
            Write-Host "      Retrying in ${RetryDelaySeconds}s..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    return @{ Success = $false; Error = $lastError; Attempts = $MaxRetries }
}

function Download-Manifest {
    param(
        [string]$DepotId,
        [string]$ManifestId,
        [string]$OutputPath,
        [int]$RetryDelaySeconds = 3
    )

    $outputFile = Join-Path $OutputPath "${DepotId}_${ManifestId}.manifest"
    $githubUrl = "https://raw.githubusercontent.com/qwe213312/k25FCdfEOoEJ42S6/main/${DepotId}_${ManifestId}.manifest"

    $githubResult = Try-DownloadUrl -Url $githubUrl -OutputFile $outputFile -MaxRetries 2 -Label "GitHub" -RetryDelaySeconds $RetryDelaySeconds

    if ($githubResult.Success) {
        return @{
            Success = $true
            FilePath = $outputFile
            Size = $githubResult.Size
            Attempts = $githubResult.Attempts
        }
    }

    return @{
        Success = $false
        Error = $githubResult.Error
        Attempts = $githubResult.Attempts
    }
}

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    } else {
        return "$Bytes B"
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

Write-Header
Write-Host "  [MODE] fIXING..." -ForegroundColor Magenta
Write-Host ""

Write-Status "Locating Steam installation..."
$steamPath = Get-SteamPath

if (-not $steamPath) {
    Write-ErrorMsg "Could not find Steam installation!"
    exit 1
}

Write-Success "Steam found at: $steamPath"
Write-Host ""

Write-Status "Scanning Steam libraries..."
$libraries = Get-SteamLibraries -SteamPath $steamPath

if (-not $libraries -or $libraries.Count -eq 0) {
    Write-ErrorMsg "No Steam libraries found!"
    exit 1
}

Write-Success "Found $($libraries.Count) library path(s)"
Write-Host ""

Write-Status "Finding most recently updated installed game..."
$selectedGame = Get-MostRecentGame -Libraries $libraries

if (-not $selectedGame) {
    Write-ErrorMsg "No installed games found!"
    exit 1
}

Write-Success "Selected: $($selectedGame.Name) (AppID: $($selectedGame.AppId))"
Write-Status "Last updated: $($selectedGame.LastUpdated)"
Write-Host ""

$luaPath = Join-Path $steamPath "config\stplug-in\$($selectedGame.AppId).lua"
Write-Status "Looking for Lua file: $luaPath"

if (-not (Test-Path $luaPath)) {
    Write-ErrorMsg "Lua file not present for AppID $($selectedGame.AppId)"
    exit 1
}

Write-Success "Lua file found!"
Write-Host ""

Write-Status "Parsing Lua file for depot IDs..."
$depotIds = Get-DepotIdsFromLua -LuaPath $luaPath

if ($depotIds.Count -eq 0) {
    Write-ErrorMsg "No depot IDs found in Lua file!"
    exit 1
}

Write-Success "Found $($depotIds.Count) depot ID(s)"
Write-Host ""

Write-Status "Fetching app info from SteamCMD API..."
$appInfo = Get-AppInfo -AppId $selectedGame.AppId

if (-not $appInfo -or $appInfo.status -ne "success") {
    Write-ErrorMsg "Failed to fetch app info from SteamCMD API!"
    exit 1
}

Write-Success "App info retrieved successfully"
Write-Host ""

Write-Status "Matching depot IDs with manifest IDs..."
$downloadQueue = @()

foreach ($depotId in $depotIds) {
    $manifestId = Get-ManifestIdForDepot -AppInfo $appInfo -AppId $selectedGame.AppId -DepotId $depotId
    if ($manifestId) {
        $downloadQueue += @{
            DepotId = $depotId
            ManifestId = $manifestId
        }
    }
}

if ($downloadQueue.Count -eq 0) {
    Write-WarningMsg "No matching manifests found for any depot IDs!"
    exit 1
}

Write-Success "Found $($downloadQueue.Count) depot(s) with available manifests"
Write-Host ""

$depotCachePath = Join-Path $steamPath "depotcache"
if (-not (Test-Path $depotCachePath)) {
    New-Item -ItemType Directory -Path $depotCachePath -Force | Out-Null
}

Write-Status "Output directory: $depotCachePath"
Write-Host ""

# ===========================================================================
# DOWNLOAD
# ===========================================================================

Write-Host "  ================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  DOWNLOADING MANIFESTS" -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$skippedCount = 0
$failedDepots = @()
$totalSize = 0
$startTime = Get-Date

for ($i = 0; $i -lt $downloadQueue.Count; $i++) {
    $item = $downloadQueue[$i]
    $depotId = $item.DepotId
    $manifestId = $item.ManifestId

    Write-Host ""
    Write-ProgressBar -Current $i -Total $downloadQueue.Count -Label "Overall Progress"
    Write-Host ""
    Write-Host ""

    $existingFile = Join-Path $depotCachePath "${depotId}_${manifestId}.manifest"
    if (Test-Path $existingFile) {
        $existingSize = (Get-Item $existingFile).Length
        if ($existingSize -gt 0) {
            $skippedCount++
            $sizeStr = Format-FileSize -Bytes $existingSize
            Write-Host "  [=] Depot $depotId - Not Out-Of-Date ($sizeStr), skipping" -ForegroundColor DarkCyan
            continue
        }
    }

    Write-Host "  +---------------------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ("  | {0,-62}|" -f "Game: $($selectedGame.Name)") -ForegroundColor Yellow
    Write-Host ("  | {0,-62}|" -f "Depot: $depotId") -ForegroundColor White
    Write-Host ("  | {0,-62}|" -f "Manifest ID: $manifestId") -ForegroundColor White
    Write-Host "  +---------------------------------------------------------------+" -ForegroundColor DarkGray

    $result = Download-Manifest -DepotId $depotId -ManifestId $manifestId -OutputPath $depotCachePath -RetryDelaySeconds $RetryDelaySeconds

    if ($result.Success) {
        $successCount++
        $totalSize += $result.Size
        $sizeStr = Format-FileSize -Bytes $result.Size
        $retryInfo = if ($result.Attempts -gt 1) { " [Attempt $($result.Attempts)]" } else { "" }
        Write-Success "Depot $depotId - Downloaded ($sizeStr)$retryInfo"
    } else {
        $failedDepots += @{
            DepotId = $depotId
            ManifestId = $manifestId
            Error = $result.Error
        }
        Write-ErrorMsg "Depot $depotId - Failed after $($result.Attempts) attempts: $($result.Error)"
    }
}

Write-Host ""
Write-ProgressBar -Current $downloadQueue.Count -Total $downloadQueue.Count -Label "Overall Progress"
Write-Host ""

$elapsed = (Get-Date) - $startTime

# ===========================================================================
# SUMMARY
# ===========================================================================

Write-Host ""
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  DOWNLOAD COMPLETE" -ForegroundColor Cyan
Write-Host "  Fix Was Made for 2B Manifest " -ForegroundColor Magenta
Write-Host ""
Write-Host "  +---------------------------------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |                         SUMMARY                               |" -ForegroundColor DarkGray
Write-Host "  +---------------------------------------------------------------+" -ForegroundColor DarkGray

Write-Host ("  |  {0,-60}|" -f "Game:          $($selectedGame.Name)") -ForegroundColor White
Write-Host ("  |  {0,-60}|" -f "AppID:         $($selectedGame.AppId)") -ForegroundColor White
Write-Host ("  |  {0,-60}|" -f "Downloaded:    $successCount") -ForegroundColor Green
Write-Host ("  |  {0,-60}|" -f "Skipped:       $skippedCount (up-to-date)") -ForegroundColor DarkCyan

$failedText = "Failed:        $($failedDepots.Count)"
$failedColor = if ($failedDepots.Count -gt 0) { "Red" } else { "Green" }
Write-Host ("  |  {0,-60}|" -f $failedText) -ForegroundColor $failedColor

Write-Host ("  |  {0,-60}|" -f "Total:         $($downloadQueue.Count) depots") -ForegroundColor White
Write-Host ("  |  {0,-60}|" -f "Downloaded:    $(Format-FileSize -Bytes $totalSize)") -ForegroundColor White
Write-Host ("  |  {0,-60}|" -f "Time Elapsed:  $($elapsed.ToString('mm\:ss'))") -ForegroundColor White

$outputText = "Output:        $depotCachePath"
if ($outputText.Length -gt 60) {
    $outputText = $outputText.Substring(0, 57) + "..."
}
Write-Host ("  |  {0,-60}|" -f $outputText) -ForegroundColor White

Write-Host "  +---------------------------------------------------------------+" -ForegroundColor DarkGray

if ($failedDepots.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAILED DOWNLOADS:" -ForegroundColor Red
    Write-Host ""
    foreach ($failed in $failedDepots) {
        Write-Host "    Depot $($failed.DepotId) (Manifest: $($failed.ManifestId))" -ForegroundColor Red
        Write-Host "    Error: $($failed.Error)" -ForegroundColor DarkRed
        Write-Host ""
    }
}

Write-Host ""
Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
