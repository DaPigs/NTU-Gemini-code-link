# =============================================================================
# vibe-sync.ps1 - Watch a local project folder for AI patch files
# Part of Local Vibe Bridge
# =============================================================================

param (
    [string]$ProjectPath
)

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "   Local Vibe Coding Auto-Bridge                         " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 1. Ask for Local Project Path if not provided via parameter
if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $RawInputPath = Read-Host "`nEnter (or paste) your local project folder path"
    $LocalPath    = $RawInputPath.Trim('"', "'", " ")
} else {
    $LocalPath    = $ProjectPath.Trim('"', "'", " ")
}

if ([string]::IsNullOrWhiteSpace($LocalPath) -or -not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
    Write-Host "[ERROR] The path '$LocalPath' does not exist or is not a folder." -ForegroundColor Red
    exit 1
}

$LocalPath   = (Resolve-Path -LiteralPath $LocalPath).ProviderPath
$ProjectName = Split-Path -Path $LocalPath -Leaf
$ContextFile = Join-Path $LocalPath "repo-context.txt"
$PatchFile   = Join-Path $LocalPath "apply-changes.txt"

$DeltaTool = Join-Path $PSScriptRoot 'bridge-delta.cjs'
if (-not (Test-Path -LiteralPath $DeltaTool -PathType Leaf) -or -not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    Write-Host '[ERROR] The delta tool or Node.js is missing. Keep the bridge files together and run setup.ps1.' -ForegroundColor Red
    exit 1
}

$StateDir = Join-Path $LocalPath '.vibebridge-state'
try {
    [void][IO.Directory]::CreateDirectory($StateDir)
    $StateItem = Get-Item -LiteralPath $StateDir -Force -ErrorAction Stop
    if ($StateItem.LinkType) { throw 'The bridge state folder cannot be a link or junction.' }
    $LockFile = Join-Path $StateDir 'watcher.lock'
    $LockItem = Get-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    if ($LockItem.LinkType) { throw 'The watcher lock cannot be a link.' }
    $WatcherLock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Host "[ERROR] Cannot lock the project. Close any other watcher for this project. $_" -ForegroundColor Red
    exit 1
}

Write-Host "`nProject Name : $ProjectName" -ForegroundColor Green
Write-Host "Project Path : $LocalPath" -ForegroundColor Gray
Write-Host "Context File : $ContextFile" -ForegroundColor Gray

# Default exclusion list for Repomix so repo-context.txt stays clean & under 7 MB
$IgnoreList = @(
    ".git", ".svn", ".hg", ".idea", ".vscode", ".vs",
    "node_modules", "bower_components", "jspm_packages",
    ".venv", "venv", "env", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    "dist", "build", "out", "target", "bin", "obj", ".next", ".nuxt", ".output",
    "coverage", ".gradle", ".terraform", "vendor",
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
    "poetry.lock", "Pipfile.lock", "Cargo.lock", "composer.lock",
    "*.pyc", "*.pyo", "*.pyd", "*.exe", "*.dll", "*.so", "*.dylib",
    "*.zip", "*.tar", "*.gz", "*.7z", "*.rar",
    "*.mp4", "*.mov", "*.avi", "*.mp3", "*.wav",
    "*.sqlite", "*.sqlite3", "*.db", ".DS_Store", "Thumbs.db",
    ".vibebridge-state", "repo-context.txt",
    "apply-changes.txt", "apply-changes (*).txt", "apply-changes.failed*.txt",
    "apply-changes.ps1", "apply-changes.failed*.ps1"
) -join ","

function Invoke-RepoPack {
    $TimeStr = (Get-Date).ToString("HH:mm:ss")
    Write-Host "`n[$TimeStr] [PACK] Packing '$ProjectName' into repo-context.txt..." -ForegroundColor Cyan

    $PackedFile = Join-Path $StateDir ('packed-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        if (Get-Command repomix.cmd -ErrorAction SilentlyContinue) {
            repomix.cmd $LocalPath --style json --output $PackedFile --ignore $IgnoreList | Out-Null
        } elseif (Get-Command npx.cmd -ErrorAction SilentlyContinue) {
            npx.cmd --yes repomix $LocalPath --style json --output $PackedFile --ignore $IgnoreList | Out-Null
        } else {
            throw 'Repomix and npx are missing. Run setup.ps1 from the bridge folder.'
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $PackedFile -PathType Leaf)) {
            throw 'Repomix did not generate a snapshot.'
        }
        node.exe $DeltaTool snapshot $LocalPath $PackedFile $ContextFile | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw 'Could not publish the v2 snapshot.' }
    } catch {
        Write-Host "[$TimeStr] [ERROR] Snapshot refresh failed: $_" -ForegroundColor Red
        return $false
    } finally {
        Remove-Item -LiteralPath $PackedFile -Force -ErrorAction SilentlyContinue
    }

    $SizeMB = [math]::Round((Get-Item -LiteralPath $ContextFile).Length / 1MB, 2)
    Write-Host "[$TimeStr] [READY] repo-context.txt generated in project folder ($SizeMB MB)" -ForegroundColor Green
    if ($SizeMB -gt 7) {
        Write-Warning 'The snapshot exceeds 7 MB. Exclude large files with .repomixignore.'
    } elseif ($SizeMB -gt 3.5) {
        Write-Warning 'The snapshot may approach Gemini context limits.'
    }
    return $true
}

function Wait-FileUnlocked([string]$FilePath) {
    # Wait up to 15 seconds for file copy/drag-and-drop operation to finish & unlock the file
    for ($i = 0; $i -lt 30; $i++) {
        try {
            if ((Test-Path -LiteralPath $FilePath -PathType Leaf) -and ((Get-Item -LiteralPath $FilePath).Length -gt 0)) {
                $Stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
                $Stream.Close()
                $Stream.Dispose()
                return $true
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Find-NextPatchFile {
    if (Test-Path -LiteralPath $PatchFile -PathType Leaf) {
        return $PatchFile
    }
    $AltMatch = Get-ChildItem -LiteralPath $LocalPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'apply-changes (*).txt' } |
        Sort-Object LastWriteTimeUtc |
        Select-Object -First 1
    if ($AltMatch) {
        return $AltMatch.FullName
    }
    return $null
}

# 2. Initial Context Pack
if (-not (Invoke-RepoPack)) { exit 1 }

# 3. Continuous Watch Loop for apply-changes.txt (or apply-changes (*).txt)
Write-Host "`n=========================================================" -ForegroundColor Yellow
Write-Host " WATCHING FOR AI PATCHES: $PatchFile (or apply-changes (*).txt)" -ForegroundColor Yellow
Write-Host "    Upload repo-context.txt to the chat, then drag apply-changes.txt here" -ForegroundColor Gray
Write-Host "    Press [R] to manually re-pack repo-context.txt" -ForegroundColor Gray
Write-Host "    Press [Q] or Ctrl+C to stop watching" -ForegroundColor Gray
Write-Host "=========================================================" -ForegroundColor Yellow

while ($true) {
    # Check if user pressed R (manual repack) or Q (quit)
    if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
        $Key = [Console]::ReadKey($true).Key
        if ($Key -eq 'R') {
            [void](Invoke-RepoPack)
        } elseif ($Key -eq 'Q') {
            Write-Host "`nStopping watcher. Happy vibe coding!" -ForegroundColor Cyan
            break
        }
    }

    $DetectedPatch = Find-NextPatchFile
    if ($DetectedPatch) {
        $DetectedName = Split-Path -Path $DetectedPatch -Leaf
        $TimeStr = (Get-Date).ToString("HH:mm:ss")
        Write-Host "`n[$TimeStr] Detected $DetectedName. Waiting for file copy to finish..." -ForegroundColor Magenta

        if (Wait-FileUnlocked $DetectedPatch) {
            try {
                Write-Host "[$TimeStr] Validating v2 patch against: $LocalPath" -ForegroundColor Cyan
                node.exe $DeltaTool apply $LocalPath $DetectedPatch

                if ($LASTEXITCODE -ne 0) {
                    throw "Patch was rejected or could not finish (exit $LASTEXITCODE)."
                }

                # Delete the patch file from the project folder so it never runs twice
                Remove-Item -LiteralPath $DetectedPatch -Force -ErrorAction Stop
                Write-Host "[$TimeStr] Removed the completed $DetectedName from project folder." -ForegroundColor DarkGray

                # Automatically re-pack repo-context.txt so the project folder has the fresh state!
                [void](Invoke-RepoPack)
            } catch {
                Write-Host "[$TimeStr] [ERROR] Could not finish processing ${DetectedName}: $_" -ForegroundColor Red
                $FailedName = 'apply-changes.failed.txt'
                if (Test-Path -LiteralPath (Join-Path $LocalPath $FailedName)) {
                    $FailedName = 'apply-changes.failed.' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.txt'
                }
                try {
                    Rename-Item -LiteralPath $DetectedPatch -NewName $FailedName -ErrorAction Stop
                    Write-Host "[$TimeStr] Saved the failed patch as $FailedName." -ForegroundColor Yellow
                } catch {
                    Write-Host "[$TimeStr] [ERROR] The watcher stopped because it could not rename the patch: $_" -ForegroundColor Red
                    Write-Host "Move $DetectedName out of the project folder before restarting the watcher." -ForegroundColor Yellow
                    exit 1
                }
            }
        } else {
            Write-Host "[$TimeStr] [WAITING] $DetectedName is still locked or empty. Waiting for file transfer to complete." -ForegroundColor Yellow
        }
    }

    Start-Sleep -Seconds 1
}
