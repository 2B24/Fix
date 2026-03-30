#Requires -Version 5.1
# Clean Lua Script - Removes bad Lua files from Steam stplug-in folder

Clear-Host
$scriptStart = Get-Date

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Success {
    param([string]$Text)
    Write-Host "  [SUCCESS] $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "  [INFO] $Text" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [WARNING] $Text" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Text)
    Write-Host "  [ERROR] $Text" -ForegroundColor Red
}

function Write-Bad {
    param([string]$Text)
    Write-Host "  [BAD] $Text" -ForegroundColor Red
}

function Write-Detail {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Gray
}

function Get-SteamPath {
    Write-Detail "Searching for Steam installation..."

    $registryPaths = @(
        @{ Path = "HKCU:\Software\Valve\Steam"; Name = "SteamPath" },
        @{ Path = "HKLM:\Software\Valve\Steam"; Name = "InstallPath" },
        @{ Path = "HKLM:\Software\WOW6432Node\Valve\Steam"; Name = "InstallPath" }
    )

    foreach ($entry in $registryPaths) {
        if (Test-Path $entry.Path) {
            $value = (Get-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue).$($entry.Name)
            if ($value -and (Test-Path $value)) {
                return $value
            }
        }
    }

    return $null
}

function Test-ValidLuaLine {
    param([string]$Line)

    $trimmedLine = $Line.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
        return $true
    }

    if ($trimmedLine.StartsWith('-')) {
        return $true
    }

    if ($trimmedLine -cmatch '^addappid') {
        if (-not ($trimmedLine -cmatch '^addappid\s*\(')) {
            return $false
        }

        $beforeComment = $trimmedLine
        if ($trimmedLine.Contains('--')) {
            $beforeComment = $trimmedLine.Substring(0, $trimmedLine.IndexOf('--'))
        }

        $openParen = $beforeComment.IndexOf('(')
        if ($openParen -lt 0) {
            return $false
        }

        $parenCount = 0
        $closeParen = -1
        for ($i = $openParen; $i -lt $beforeComment.Length; $i++) {
            if ($beforeComment[$i] -eq '(') {
                $parenCount++
            }
            elseif ($beforeComment[$i] -eq ')') {
                $parenCount--
                if ($parenCount -eq 0) {
                    $closeParen = $i
                    break
                }
            }
        }

        if ($closeParen -lt 0) {
            return $false
        }

        if ($closeParen + 1 -lt $beforeComment.Length) {
            $afterCloseParen = $beforeComment.Substring($closeParen + 1).Trim()
            if ($afterCloseParen -ne '') {
                return $false
            }
        }

        $parenLength = $closeParen - $openParen - 1
        if ($parenLength -gt 0) {
            $parenContent = $beforeComment.Substring($openParen + 1, $parenLength)
            $withoutQuotes = $parenContent -replace '"[^"]*"', ''
            if ($withoutQuotes -match '[a-f0-9]{40,}') {
                return $false
            }
        }

        return $true
    }

    if ($trimmedLine -cmatch '^setManifestid') {
        if (-not ($trimmedLine -cmatch '^setManifestid\s*\(')) {
            return $false
        }

        $beforeComment = $trimmedLine
        if ($trimmedLine.Contains('--')) {
            $beforeComment = $trimmedLine.Substring(0, $trimmedLine.IndexOf('--'))
        }

        $openParen = $beforeComment.IndexOf('(')
        if ($openParen -lt 0) {
            return $false
        }

        $parenCount = 0
        $closeParen = -1
        for ($i = $openParen; $i -lt $beforeComment.Length; $i++) {
            if ($beforeComment[$i] -eq '(') {
                $parenCount++
            }
            elseif ($beforeComment[$i] -eq ')') {
                $parenCount--
                if ($parenCount -eq 0) {
                    $closeParen = $i
                    break
                }
            }
        }

        if ($closeParen -lt 0) {
            return $false
        }

        if ($closeParen + 1 -lt $beforeComment.Length) {
            $afterCloseParen = $beforeComment.Substring($closeParen + 1).Trim()
            if ($afterCloseParen -ne '') {
                return $false
            }
        }

        $parenLength = $closeParen - $openParen - 1
        if ($parenLength -gt 0) {
            $parenContent = $beforeComment.Substring($openParen + 1, $parenLength)
            $withoutQuotes = $parenContent -replace '"[^"]*"', ''
            if ($withoutQuotes -match '[a-f0-9]{40,}') {
                return $false
            }
        }

        return $true
    }

    if ($trimmedLine -cmatch '^addtoken') {
        return $true
    }

    if ($trimmedLine -match '^(?i)addappid' -or
        $trimmedLine -match '^(?i)addtoken' -or
        $trimmedLine -match '^(?i)setManifestid') {
        return $false
    }

    return $false
}

function Get-UniqueDestinationPath {
    param(
        [string]$FolderPath,
        [string]$FileName
    )

    $destinationPath = Join-Path $FolderPath $FileName
    if (-not (Test-Path $destinationPath)) {
        return $destinationPath
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    $counter = 1

    do {
        $newName = "{0}_{1}{2}" -f $baseName, $counter, $extension
        $destinationPath = Join-Path $FolderPath $newName
        $counter++
    } while (Test-Path $destinationPath)

    return $destinationPath
}

Write-Banner "Lua Checker"

Write-Step "Prep: Locating Steam installation..."
$steamPath = Get-SteamPath

if (-not $steamPath) {
    Write-ErrorMsg "Steam installation not found in registry."
    Write-Warn "Please ensure Steam is installed on your system."
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
    exit
}

Write-Success "Steam found!"
Write-Host "  Location: $steamPath" -ForegroundColor White
Write-Host ""

Write-Step "Step 1: Checking stplug-in folder..."
$stpluginPath = Join-Path $steamPath "config\stplug-in"

if (-not (Test-Path $stpluginPath)) {
    Write-ErrorMsg "Luas folder does not exist! Add some games bozo"
    Write-Warn "Expected path: $stpluginPath"
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
    exit
}

Write-Success "stplug-in folder found"
Write-Host "  Location: $stpluginPath" -ForegroundColor White
Write-Host ""

$invalidFolder = Join-Path $stpluginPath "Invalid_LUA"
if (-not (Test-Path $invalidFolder)) {
    New-Item -Path $invalidFolder -ItemType Directory -Force | Out-Null
    Write-Info "Created Invalid_LUA folder"
    Write-Host "  Location: $invalidFolder" -ForegroundColor White
    Write-Host ""
}

$badFiles = @()
$totalFilesFound = 0
$totalValidFiles = 0
$totalInvalidFiles = 0

Write-Step "Step 2: Checking for non-.lua files..."
$allFiles = Get-ChildItem -Path $stpluginPath -File -ErrorAction SilentlyContinue
$totalFilesFound = ($allFiles | Measure-Object).Count

$nonLuaFiles = @()
foreach ($file in $allFiles) {
    if ($file.DirectoryName -eq $invalidFolder) {
        continue
    }

    if ($file.Extension -ne ".lua") {
        Write-Bad "Non-Lua file found: $($file.Name)"
        $badFiles += @{
            File = $file
            BadLines = @()
            Reason = "Non-Lua file"
        }
        $nonLuaFiles += $file
    }
}

if ($nonLuaFiles.Count -eq 0) {
    Write-Info "No non-.lua files found"
}
Write-Host ""

Write-Step "Step 3: Checking Lua files for invalid content..."
$luaFiles = Get-ChildItem -Path $stpluginPath -Filter "*.lua" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -ne $invalidFolder }

$luaFileCount = ($luaFiles | Measure-Object).Count

if ($luaFileCount -eq 0) {
    Write-Info "No .lua files found to check"
}
else {
    Write-Detail "Found $luaFileCount .lua file(s) to check..."

    $fileIndex = 0
    foreach ($luaFile in $luaFiles) {
        $fileIndex++
        $badLines = @()

        try {
            $lines = Get-Content -Path $luaFile.FullName -ErrorAction Stop
            $lineNumber = 0

            foreach ($line in $lines) {
                $lineNumber++
                if (-not (Test-ValidLuaLine -Line $line)) {
                    $badLines += @{
                        LineNumber = $lineNumber
                        Content = $line.Trim()
                    }
                }
            }

            if ($badLines.Count -gt 0) {
                Write-Bad "Invalid content in: $($luaFile.Name)"
                Write-Detail "Bad lines: $(($badLines | ForEach-Object { $_.LineNumber }) -join ', ')"
                $badFiles += @{
                    File = $luaFile
                    BadLines = $badLines
                    Reason = "Invalid Lua content"
                }
            }
            else {
                Write-OK $luaFile.Name
            }
        }
        catch {
            Write-ErrorMsg "Failed to read file: $($luaFile.Name) - $_"
            $badFiles += @{
                File = $luaFile
                BadLines = @()
                Reason = "Unreadable file"
            }
        }

        if ($fileIndex % 10 -eq 0 -or $fileIndex -eq $luaFileCount) {
            Write-Detail "Progress: $fileIndex / $luaFileCount files checked..."
        }
    }
}

Write-Host ""

Write-Step "Step 4: Moving bad files to Invalid_LUA..."
$movedCount = 0

foreach ($badFileInfo in $badFiles) {
    $badFile = $badFileInfo.File

    if (-not (Test-Path $badFile.FullName)) {
        continue
    }

    $destinationPath = Get-UniqueDestinationPath -FolderPath $invalidFolder -FileName $badFile.Name

    try {
        Move-Item -Path $badFile.FullName -Destination $destinationPath -Force
        Write-OK "$($badFile.Name) -> $(Split-Path $destinationPath -Leaf)"
        $movedCount++
    }
    catch {
        Write-ErrorMsg "Failed to move $($badFile.Name): $_"
    }
}

$totalInvalidFiles = $badFiles.Count
$totalValidFiles = $totalFilesFound - $totalInvalidFiles

$timeTaken = (Get-Date) - $scriptStart
$formattedTime = "{0:mm\:ss\.fff}" -f $timeTaken

Write-Host ""
Write-Banner "Summary"
Write-Host ""

Write-Host "  Total files found   : $totalFilesFound" -ForegroundColor White
Write-Host "  Total valid files   : $totalValidFiles" -ForegroundColor Green
Write-Host "  Total invalid files : $totalInvalidFiles" -ForegroundColor Yellow
Write-Host "  Total moved files   : $movedCount" -ForegroundColor Cyan
Write-Host "  Time taken          : $formattedTime" -ForegroundColor White
Write-Host ""

if ($badFiles.Count -eq 0) {
    Write-Success "No bad files found! All files are clean."
}
else {
    Write-Warn "Found $($badFiles.Count) bad file(s)."
    Write-Info "Moved $movedCount file(s) to Invalid_LUA"
    Write-Host ""

    foreach ($badFileInfo in $badFiles) {
        $badFile = $badFileInfo.File
        $badLines = $badFileInfo.BadLines
        $reason = $badFileInfo.Reason

        Write-Host "    - $($badFile.Name) [$reason]" -ForegroundColor Red
        if ($badLines.Count -gt 0) {
            foreach ($badLine in $badLines) {
                Write-Host "      Line $($badLine.LineNumber): $($badLine.Content)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
    }
}

Write-Host ""
Write-Banner "Press Enter to exit..."
Read-Host