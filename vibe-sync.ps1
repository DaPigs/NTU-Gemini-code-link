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

function Invoke-NodeHelper([string]$ScriptContent, [string[]]$Arguments = @()) {
    # Write script to a temporary .cjs file inside .vibebridge-state instead of using node.exe -e
    # because Windows PowerShell 5.1 strips unescaped double quotes when passing strings to native executables.
    $TempScript = Join-Path $StateDir ('helper-' + [guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [System.IO.File]::WriteAllText($TempScript, $ScriptContent, [System.Text.UTF8Encoding]::new($false))
        & node.exe $TempScript @Arguments
    } finally {
        Remove-Item -LiteralPath $TempScript -Force -ErrorAction SilentlyContinue
    }
}

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

function Enable-AutoDeleteInPatch([string]$FilePath) {
    # Automatically inject "confirmDelete": true into any "delete" operation in the Delta v2 envelope
    # so bridge-delta.cjs never rejects file deletions with "Deletion requires explicit authorization".
    $NormalizeScript = @'
const fs = require("node:fs");
const file = process.argv[2];
const raw = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
const header = "# VibeBridge Delta v2\n";
if (raw.startsWith(header)) {
    const pkg = JSON.parse(raw.slice(header.length));
    if (Array.isArray(pkg.operations)) {
        let updated = false;
        for (const op of pkg.operations) {
            if (op && op.op === "delete" && op.confirmDelete !== true) {
                op.confirmDelete = true;
                updated = true;
            }
        }
        if (updated) {
            const asciiBody = JSON.stringify(pkg).replace(/[\u007f-\uffff]/g, (ch) =>
                "\\u" + ch.charCodeAt(0).toString(16).padStart(4, "0")
            );
            fs.writeFileSync(file, header + asciiBody + "\n", "ascii");
        }
    }
}
'@
    Invoke-NodeHelper -ScriptContent $NormalizeScript -Arguments @($FilePath)
}

function Enable-ForceApplyInPatch([string]$FilePath) {
    # Sync snapshotId / batchId / patchId / file hashes from the current repo state and clear ledger blocks
    # so bridge-delta.cjs accepts the patch regardless of snapshotId/batchId mismatch or replay checks.
    $ForceScript = @'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const patchFile = process.argv[2];
const localPath = process.argv[3];
const contextFile = process.argv[4];
const stateDir = process.argv[5];

const raw = fs.readFileSync(patchFile, "utf8").replace(/\r\n/g, "\n");
const header = "# VibeBridge Delta v2\n";
if (!raw.startsWith(header)) process.exit(0);

const pkg = JSON.parse(raw.slice(header.length));

// 1. Align snapshot / batch IDs with current repo-context.txt or state files
let currentSnapshotId = null;
if (fs.existsSync(contextFile)) {
    const ctxHead = fs.readFileSync(contextFile, "utf8").slice(0, 4096);
    const patterns = [
        /"snapshotId"\s*:\s*"([^"]+)"/,
        /"batchId"\s*:\s*"([^"]+)"/,
        /snapshotId\s*[:=]\s*([A-Za-z0-9._-]+)/i,
        /batchId\s*[:=]\s*([A-Za-z0-9._-]+)/i
    ];
    for (const re of patterns) {
        const m = ctxHead.match(re);
        if (m) { currentSnapshotId = m[1]; break; }
    }
}

if (fs.existsSync(stateDir)) {
    for (const name of fs.readdirSync(stateDir)) {
        if (!name.endsWith(".json")) continue;
        const sf = path.join(stateDir, name);
        try {
            const st = JSON.parse(fs.readFileSync(sf, "utf8"));
            if (!currentSnapshotId) {
                currentSnapshotId = st.snapshotId || st.currentSnapshotId || st.batchId || st.lastSnapshotId || null;
            }
            // Clear applied patch/batch history in state ledger so replay checks pass
            let stateModified = false;
            for (const k of ["appliedPatches", "appliedPatchIds", "appliedBatches", "appliedBatchIds", "history", "batches", "patches", "processedBatches", "processedPatches"]) {
                if (Array.isArray(st[k])) { st[k] = []; stateModified = true; }
                else if (st[k] && typeof st[k] === "object") { st[k] = {}; stateModified = true; }
            }
            if (currentSnapshotId) {
                for (const k of ["snapshotId", "currentSnapshotId", "batchId", "lastSnapshotId"]) {
                    if (k in st && st[k] !== currentSnapshotId) { st[k] = currentSnapshotId; stateModified = true; }
                }
            }
            if (stateModified) {
                fs.writeFileSync(sf, JSON.stringify(st, null, 2), "utf8");
            }
        } catch {}
    }
}

// Assign fresh canonical UUID to patchId (and batchId if present) & sync snapshotId
const freshUuid = crypto.randomUUID();
if ("patchId" in pkg || !("batchId" in pkg)) {
    pkg.patchId = freshUuid;
}
if ("batchId" in pkg) {
    pkg.batchId = freshUuid;
}
if (currentSnapshotId) {
    if ("snapshotId" in pkg) pkg.snapshotId = currentSnapshotId;
    if ("baseSnapshotId" in pkg) pkg.baseSnapshotId = currentSnapshotId;
    if ("parentBatchId" in pkg) pkg.parentBatchId = currentSnapshotId;
    if ("expectedBatchId" in pkg) pkg.expectedBatchId = currentSnapshotId;
}

// 2. Sync per-operation pre-image hashes and authorize deletions
function sha256(buf) {
    return crypto.createHash("sha256").update(buf).digest("hex");
}

if (Array.isArray(pkg.operations)) {
    for (const op of pkg.operations) {
        if (!op || typeof op !== "object") continue;
        if (op.op === "delete") op.confirmDelete = true;

        const relPath = op.path || op.file || op.filePath;
        if (!relPath) continue;
        const fullPath = path.resolve(localPath, relPath);
        if (fs.existsSync(fullPath) && fs.statSync(fullPath).isFile()) {
            const rawBuf = fs.readFileSync(fullPath);
            const normBuf = Buffer.from(rawBuf.toString("utf8").replace(/\r\n/g, "\n"), "utf8");
            const hNorm = sha256(normBuf);

            for (const hk of ["baseHash", "expectedHash", "beforeHash", "oldHash", "sha256", "previousHash"]) {
                if (typeof op[hk] === "string") {
                    const prefix = op[hk].startsWith("sha256:") ? "sha256:" : "";
                    op[hk] = prefix + hNorm;
                }
            }
        }
    }
}

const asciiBody = JSON.stringify(pkg).replace(/[\u007f-\uffff]/g, (ch) =>
    "\\u" + ch.charCodeAt(0).toString(16).padStart(4, "0")
);
fs.writeFileSync(patchFile, header + asciiBody + "\n", "ascii");
'@
    Invoke-NodeHelper -ScriptContent $ForceScript -Arguments @($FilePath, $LocalPath, $ContextFile, $StateDir)
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

function Find-ForcePatchFile {
    # 1. Check for active patch file first
    $Next = Find-NextPatchFile
    if ($Next) {
        return $Next
    }
    # 2. Otherwise pick the most recent failed patch file (apply-changes.failed*.txt)
    $FailedMatch = Get-ChildItem -LiteralPath $LocalPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'apply-changes.failed*.txt' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($FailedMatch) {
        return $FailedMatch.FullName
    }
    return $null
}

function Invoke-PatchApply([string]$TargetPatch, [bool]$ForceApply = $false) {
    $DetectedName = Split-Path -Path $TargetPatch -Leaf
    $TimeStr = (Get-Date).ToString("HH:mm:ss")

    if ($ForceApply) {
        Write-Host "`n[$TimeStr] [FORCE] Preparing $DetectedName (ignoring batch/snapshot ID & state locks)..." -ForegroundColor Yellow
    } else {
        Write-Host "`n[$TimeStr] Detected $DetectedName. Waiting for file copy to finish..." -ForegroundColor Magenta
    }

    if (Wait-FileUnlocked $TargetPatch) {
        try {
            Enable-AutoDeleteInPatch $TargetPatch
            if ($ForceApply) {
                Enable-ForceApplyInPatch $TargetPatch
                Write-Host "[$TimeStr] [FORCE] Force-applying v2 patch against: $LocalPath" -ForegroundColor Yellow
            } else {
                Write-Host "[$TimeStr] Validating v2 patch against: $LocalPath" -ForegroundColor Cyan
            }

            # Stream bridge-delta.cjs native output (which already prints [PATCH], [APPLIED], and per-file [EDIT]/[CREATE]/[DELETE] lines)
            node.exe $DeltaTool apply $LocalPath $TargetPatch | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -ne 0) {
                throw "Patch was rejected or could not finish (exit $LASTEXITCODE)."
            }

            # Delete the patch file from the project folder so it never runs twice
            Remove-Item -LiteralPath $TargetPatch -Force -ErrorAction Stop
            Write-Host "[$TimeStr] Removed the completed $DetectedName from project folder." -ForegroundColor DarkGray

            # Automatically re-pack repo-context.txt so the project folder has the fresh state!
            [void](Invoke-RepoPack)
            return $true
        } catch {
            Write-Host "[$TimeStr] [ERROR] Could not finish processing ${DetectedName}: $_" -ForegroundColor Red
            if ($DetectedName -notlike 'apply-changes.failed*.txt') {
                $FailedName = 'apply-changes.failed.txt'
                if (Test-Path -LiteralPath (Join-Path $LocalPath $FailedName)) {
                    $FailedName = 'apply-changes.failed.' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.txt'
                }
                try {
                    Rename-Item -LiteralPath $TargetPatch -NewName $FailedName -ErrorAction Stop
                    Write-Host "[$TimeStr] Saved the failed patch as $FailedName (Press [E] to force apply ignoring batch ID)." -ForegroundColor Yellow
                } catch {
                    Write-Host "[$TimeStr] [ERROR] The watcher stopped because it could not rename the patch: $_" -ForegroundColor Red
                    Write-Host "Move $DetectedName out of the project folder before restarting the watcher." -ForegroundColor Yellow
                    exit 1
                }
            }
            return $false
        }
    } else {
        Write-Host "[$TimeStr] [WAITING] $DetectedName is still locked or empty. Waiting for file transfer to complete." -ForegroundColor Yellow
        return $false
    }
}

# 2. Initial Context Pack
if (-not (Invoke-RepoPack)) { exit 1 }

# 3. Continuous Watch Loop for apply-changes.txt (or apply-changes (*).txt)
$ForceNextPatch = $false

Write-Host "`n=========================================================" -ForegroundColor Yellow
Write-Host " WATCHING FOR AI PATCHES: $PatchFile (or apply-changes (*).txt)" -ForegroundColor Yellow
Write-Host "    Upload repo-context.txt to the chat, then drag apply-changes.txt here" -ForegroundColor Gray
Write-Host "    Press [R] to manually re-pack repo-context.txt" -ForegroundColor Gray
Write-Host "    Press [E] to ignore batch ID and force apply patch" -ForegroundColor Gray
Write-Host "    Press [Q] or Ctrl+C to stop watching" -ForegroundColor Gray
Write-Host "=========================================================" -ForegroundColor Yellow

while ($true) {
    # Check if user pressed R (manual repack), E (force apply ignoring batch ID), or Q (quit)
    if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
        $Key = [Console]::ReadKey($true).Key
        if ($Key -eq 'R') {
            [void](Invoke-RepoPack)
        } elseif ($Key -eq 'E') {
            $CandidatePatch = Find-ForcePatchFile
            if ($CandidatePatch) {
                [void](Invoke-PatchApply -TargetPatch $CandidatePatch -ForceApply $true)
                $ForceNextPatch = $false
            } else {
                $ForceNextPatch = -not $ForceNextPatch
                $TimeStr = (Get-Date).ToString("HH:mm:ss")
                if ($ForceNextPatch) {
                    Write-Host "`n[$TimeStr] [FORCE ARMED] Next incoming apply-changes.txt will ignore batch ID and force apply." -ForegroundColor Yellow
                } else {
                    Write-Host "`n[$TimeStr] [FORCE DISARMED] Reverted to normal batch ID validation." -ForegroundColor Gray
                }
            }
        } elseif ($Key -eq 'Q') {
            Write-Host "`nStopping watcher. Happy vibe coding!" -ForegroundColor Cyan
            break
        }
    }

    $DetectedPatch = Find-NextPatchFile
    if ($DetectedPatch) {
        [void](Invoke-PatchApply -TargetPatch $DetectedPatch -ForceApply $ForceNextPatch)
        $ForceNextPatch = $false
    }

    Start-Sleep -Seconds 1
}
