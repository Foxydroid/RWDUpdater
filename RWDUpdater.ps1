$ErrorActionPreference = "Stop"

# ===== FUNCTIONS =====

function Test-GitAvailable {
    try {
        $null = & git --version 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

# Run git command and return output only (without printing extra output)
function Run-GitSilent {
    param(
        [string]$Arguments,
        [string]$WorkingDirectory = $null
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $process = [System.Diagnostics.Process]::Start($psi)
    $output = $process.StandardOutput.ReadToEnd()
    $error = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Git error: $error"
    }
    return $output
}

function Copy-DirectoryRecursive {
    param(
        [string]$From,
        [string]$To
    )
    Get-ChildItem -Path $From -Recurse | ForEach-Object {
        $relPath = $_.FullName.Substring($From.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
        $destPath = Join-Path $To $relPath
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Path $destPath -Force | Out-Null
        } else {
            New-Item -ItemType Directory -Path (Split-Path $destPath) -Force | Out-Null
            Copy-Item -Path $_.FullName -Destination $destPath -Force
        }
    }
}

function Force-DeleteDir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return
    }
    try {
        Get-ChildItem -Path $Path -Recurse -Force | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "[WARN] Cannot fully delete directory $Path : $_"
    }
}

function Get-DirectoryHashes {
    param([string]$Path)
    $hashes = @()
    Get-ChildItem -Path $Path -File -Recurse | ForEach-Object {
        try {
            $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
            $relPath = $_.FullName.Substring($Path.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar) -replace '\\', '/'
            $hashes += "$relPath|$hash"
        } catch {
            Write-Host "[WARN] Failed to hash $($_.FullName): $_"
        }
    }
    return $hashes | Sort-Object
}

function Get-RainWorldModsFolder {
    $steamPaths = @()
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Valve\Steam")
        if ($key) {
            $steamPath = $key.GetValue("SteamPath")
            if ($steamPath) {
                $steamPaths += $steamPath -replace '/', '\'
            }
        }
    }
    catch { }
    $allLibs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($steamPath in $steamPaths) {
        $allLibs.Add($steamPath) | Out-Null
        $libraryFolder = Join-Path (Join-Path $steamPath "steamapps") "libraryfolders.vdf"
        if (Test-Path $libraryFolder) {
            $content = Get-Content -Path $libraryFolder -Raw
            [regex]::Matches($content, '"path"\s*"(.+?)"') | ForEach-Object {
                $libPath = $_.Groups[1].Value -replace '\\\\', '\'
                $allLibs.Add($libPath) | Out-Null
            }
        }
    }
    foreach ($libPath in $allLibs) {
        $candidate = Join-Path (Join-Path (Join-Path (Join-Path $libPath "steamapps") "common") "Rain World") "RainWorld_Data\StreamingAssets\mods"
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Select-GameModsFolderDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Please select your Rain World's 'mods' folder (should end with ...StreamingAssets\mods)"
    $dialog.ShowNewFolderButton = $false
    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

# ===== CONSTANTS =====

$MODFOLDER = "Devourment-mod"
$ZIP_URL = "https://gitgud.io/mixbrishelton/rain-world-devourment/-/archive/master/rain-world-devourment-master.zip"
$REPO = "https://gitgud.io/mixbrishelton/rain-world-devourment.git"

# ===== MAIN LOGIC =====

Write-Host "Rain World Devourment Updater"

# Step 1. Detect mods folder or ask user input
$targetPath = Get-RainWorldModsFolder
if (-not $targetPath) {
    Write-Host "Game folder not found. Please select your 'mods' folder in the dialog..."
    $targetPath = Select-GameModsFolderDialog
    if (-not $targetPath -or -not (Test-Path $targetPath)) {
        Write-Host "Path does not exist. Exiting."
        exit
    }
}
Write-Host "[INFO] Game mods folder: $targetPath"

# Step 2. Prepare temp folder
$tempPath = Join-Path $env:TEMP "rainworld_mod_temp"
Force-DeleteDir $tempPath

$fetchSuccess = $false
$sourceModPath = $null

# Step 3. Try git clone as priority
if (Test-GitAvailable) {
    try {
        Write-Host "[INFO] Cloning mod from git..."
        $null = Run-GitSilent "clone --depth=1 `"$REPO`" `"$tempPath`""
        $commitDate = Run-GitSilent "log -1 --format=%cd --date=iso" -WorkingDirectory $tempPath
        Write-Host "[INFO] Latest commit date: $($commitDate.Trim())"
        $sourceModPath = Join-Path $tempPath $MODFOLDER
        $fetchSuccess = $true
    } catch {
        Write-Host "[ERROR] Git clone failed: $_"
    }
}

# Step 4. If git failed/unavailable, do ZIP download/extract
if (-not $fetchSuccess) {
    try {
        Write-Host "[INFO] Git failed or is unavailable. Downloading ZIP archive from repository..."
        $zipFile = Join-Path $tempPath "mod.zip"
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        $progressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ZIP_URL -OutFile $zipFile
        $progressPreference = 'Continue'
        Write-Host "[INFO] Extracting ZIP..."
        Expand-Archive -Path $zipFile -DestinationPath $tempPath -Force
        $dirs = @(Get-ChildItem -Path $tempPath -Directory)
        if ($dirs.Count -gt 0) {
            $potentialPath = Join-Path $dirs[0].FullName $MODFOLDER
            if (Test-Path $potentialPath) {
                $sourceModPath = $potentialPath
            } else {
                $potentialPath = Join-Path $tempPath $MODFOLDER
                if (Test-Path $potentialPath) {
                    $sourceModPath = $potentialPath
                }
            }
        }
        if (-not $sourceModPath) { throw "Devourment-mod folder not found in downloaded archive." }
        $fetchSuccess = $true
    } catch {
        Write-Host "[ERROR] ZIP download or extraction failed: $_"
        Force-DeleteDir $tempPath
        exit
    }
}

# Step 5. If files fetched successfully, compare and update/copy files if needed
if ($fetchSuccess) {
    try {
        $targetModPath = Join-Path $targetPath $MODFOLDER
        $modExists = Test-Path $targetModPath
        if ($modExists) {
            Write-Host "[INFO] Comparing existing mod with the new version..."
            $oldHashes = Get-DirectoryHashes -Path $targetModPath
            $newHashes = Get-DirectoryHashes -Path $sourceModPath
            $areEqual = @(Compare-Object -ReferenceObject $oldHashes -DifferenceObject $newHashes).Count -eq 0
            if ($areEqual) {
                Write-Host "[INFO] Mod is already up to date! No files were copied."
                Force-DeleteDir $tempPath
                Write-Host "All done! Press any key to exit."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                exit
            } else {
                Write-Host "[INFO] Mod changes detected. Updating mod..."
            }
        } else {
            Write-Host "[INFO] Mod not currently installed, will perform a fresh install."
        }
        if ($modExists) { Force-DeleteDir $targetModPath }
        Write-Host "[INFO] Copying mod files..."
        Copy-DirectoryRecursive -From $sourceModPath -To $targetModPath
        if ($modExists) { $status = "updated" } else { $status = "installed" }
        Write-Host "[SUCCESS] Mod $status successfully!"
    } catch {
        Write-Host "[ERROR] Mod installation failed: $_"
        Force-DeleteDir $tempPath
        exit
    }
}

# Step 6. Final cleanup and exit
Force-DeleteDir $tempPath
Write-Host "All done! Press any key to exit."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
