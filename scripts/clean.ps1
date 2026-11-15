#requires -Version 5.1
<#
clean.ps1 - carries out a cleanup the user has confirmed. It only acts on items of a scan report,
and re-checks every path against the protection rules before touching it.

Run with: powershell -NoProfile -ExecutionPolicy Bypass -File clean.ps1 ...

  -Manifest <scan-*.json> -Ids "G1;G2;Y3"            dry run: prints the plan, changes nothing
  -Manifest <scan-*.json> -Ids "G1;G2;Y3" -Execute   does it
  -Ids "all-green"                                    every green item of the report
  -ExtraPaths "D:\work\x\frames"                      extra folders the user named; must sit inside a granted project folder
  -Permanent                                          yellow items are deleted for good instead of being moved to quarantine
  -Undo [-Ids "Y3"]                                   put quarantined items back where they were
  -Purge                                              permanently delete everything in quarantine (this is what frees the space)

What each method does:
  delete-contents / delete-old   permanent delete of regenerable cache files; files in use are skipped
  quarantine                     the folder is moved aside on the same drive; nothing is lost until -Purge
  empty-recycle-bin              empties the Recycle Bin; cannot be undone
  command:conda-clean            runs "conda clean --all -y"

Keep this file ASCII-only (see common.ps1).
#>
[CmdletBinding()]
param(
    [string]$Manifest,
    [string]$Ids = '',
    [string]$ExtraPaths = '',
    [switch]$Execute,
    [switch]$Permanent,
    [switch]$Undo,
    [switch]$Purge,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

$MB = 1024L * 1024L; $GB = 1024L * $MB
$utf8 = New-Object System.Text.UTF8Encoding $false
function Format-PcSize { param([long]$b) if ($b -ge $GB) { return ('{0:N2} GB' -f ($b / $GB)) } else { return ('{0:N0} MB' -f ($b / $MB)) } }
function Stop-PcWith { param([string]$Message) Write-Output "ERROR: $Message"; exit 2 }

$report = $null
if ($Manifest) {
    if (-not [System.IO.File]::Exists($Manifest)) { Stop-PcWith "report not found: $Manifest" }
    $report = [System.IO.File]::ReadAllText($Manifest, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($report.schema -ne 1) { Stop-PcWith 'this report was not written by scan.ps1' }
    if (-not $OutDir) { $OutDir = $report.outDir }
}
if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'pc-checkup' }
$OutDir = Get-PcNorm $OutDir
[void][System.IO.Directory]::CreateDirectory($OutDir)
$indexFile = Join-Path $OutDir 'quarantine-index.json'

function Read-PcIndex {
    if (-not [System.IO.File]::Exists($indexFile)) { return , @() }
    try { return , @([System.IO.File]::ReadAllText($indexFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return , @() }
}
function Write-PcIndex {
    param([object[]]$Entries)
    if (-not $Entries -or $Entries.Count -eq 0) { [System.IO.File]::WriteAllText($indexFile, '[]', $utf8); return }
    [System.IO.File]::WriteAllText($indexFile, (ConvertTo-Json -InputObject @($Entries) -Depth 4), $utf8)
}
function Test-PcQuarantinePath {
    # Purge and undo only ever act inside the two places this script itself moves things to.
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path.StartsWith((Join-Path $OutDir 'quarantine') + '\', $script:PcCmp)) { return $true }
    return ($Path.Length -gt 3 -and $Path.Substring(2).StartsWith('\' + $script:PcQuarantineName + '\', $script:PcCmp))
}
function Get-PcIdList {
    param([string]$Text)
    return , @($Text.Split(@(';', ',', ' ', '|'), [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim().ToUpperInvariant() })
}

# ---------------------------------------------------------------- undo / purge
if ($Undo -or $Purge) {
    $index = Read-PcIndex
    $only = Get-PcIdList $Ids
    $left = New-Object 'System.Collections.Generic.List[object]'
    $bytes = 0L; $done = 0; $failed = 0
    foreach ($q in $index) {
        if ($only.Count -and $only -notcontains ([string]$q.id).ToUpperInvariant()) { $left.Add($q); continue }
        $exists = [System.IO.Directory]::Exists($q.stored) -or [System.IO.File]::Exists($q.stored)
        if (-not $exists) { continue }   # already restored or deleted by hand
        if (-not (Test-PcQuarantinePath $q.stored)) { Write-Output ("  left alone (not inside the quarantine folders): " + $q.stored); $left.Add($q); $failed++; continue }
        if ($Undo) {
            if ([System.IO.Directory]::Exists($q.original) -or [System.IO.File]::Exists($q.original)) {
                Write-Output ("  kept in quarantine (something new is at the original place): " + $q.original); $left.Add($q); $failed++; continue
            }
            try {
                [void][System.IO.Directory]::CreateDirectory((Split-Path $q.original -Parent))
                if ([System.IO.File]::Exists($q.stored)) { [System.IO.File]::Move('\\?\' + $q.stored, '\\?\' + $q.original) }
                else { [System.IO.Directory]::Move('\\?\' + $q.stored, '\\?\' + $q.original) }
                Write-Output ("  restored: " + $q.original); $bytes += [long]$q.bytes; $done++
            } catch { Write-Output ("  could not restore " + $q.original + ": " + $_.Exception.Message); $left.Add($q); $failed++ }
        } else {
            $r = Remove-PcTree -Path $q.stored
            $bytes += $r.Freed
            if ($r.Kept -gt 0) { Write-Output ("  partly deleted (" + $r.Kept + " files in use): " + $q.stored); $left.Add($q); $failed++ }
            else {
                $done++
                foreach ($up in @((Split-Path $q.stored -Parent), (Split-Path (Split-Path $q.stored -Parent) -Parent))) {
                    try { if (Test-PcQuarantinePath ($up + '\x')) { [System.IO.Directory]::Delete($up, $false) } } catch { }
                }
            }
        }
    }
    Write-PcIndex $left.ToArray()
    if ($Undo) { Write-Output ("UNDO: restored {0} item(s), {1}; {2} could not be restored." -f $done, (Format-PcSize $bytes), $failed) }
    else { Write-Output ("PURGE: permanently deleted {0} item(s), freed {1}; {2} left." -f $done, (Format-PcSize $bytes), $failed) }
    exit 0
}

# ---------------------------------------------------------------- pick the items
if (-not $report) { Stop-PcWith 'give -Manifest <scan report>, or use -Undo / -Purge' }
$scanTime = [DateTime]::ParseExact($report.generatedAt, 'yyyy-MM-dd HH:mm:ss', $null)
if (((Get-Date) - $scanTime).TotalHours -gt 24) { Stop-PcWith 'this report is more than 24 hours old. Run scan.ps1 again so the list matches the disk.' }
$G = Initialize-PcGuard -Granted @($report.granted)

$byId = @{}
foreach ($it in @($report.items)) { $byId[([string]$it.id).ToUpperInvariant()] = $it }
$picked = New-Object 'System.Collections.Generic.List[object]'
foreach ($id in (Get-PcIdList $Ids)) {
    if ($id -eq 'ALL-GREEN') { foreach ($it in @($report.items)) { if ($it.level -eq 'green' -and -not $picked.Contains($it)) { $picked.Add($it) } }; continue }
    if (-not $byId.ContainsKey($id)) { Stop-PcWith "there is no item $id in this report" }
    if (-not $picked.Contains($byId[$id])) { $picked.Add($byId[$id]) }
}
$n = 0
foreach ($raw in (Split-PcList @($ExtraPaths))) {
    $p = Get-PcNorm $raw
    $inGrant = $false
    foreach ($r in $G.Granted) { if ($p -and (Test-PcUnder $p $r) -and -not $p.Equals($r, $script:PcCmp)) { $inGrant = $true; break } }
    if (-not $inGrant) { Stop-PcWith "extra path is not inside a project folder the user granted at scan time: $raw" }
    $n++
    $picked.Add([pscustomobject]@{ id = "X$n"; level = 'yellow'; category = 'user-named'; label = $p; paths = @($p); sizeBytes = (Measure-PcDir $p).Size; method = 'quarantine'; extra = $null })
}
if ($picked.Count -eq 0) { Stop-PcWith 'nothing selected. Pass -Ids, for example -Ids "G1;G2" or -Ids "all-green".' }
$order = @{ 'empty-recycle-bin' = 0 }
$plan = @($picked | Sort-Object @{ Expression = { if ($order.ContainsKey($_.method)) { 0 } elseif ($_.level -eq 'green') { 1 } else { 2 } } }, @{ Expression = { $_.sizeBytes }; Descending = $true })

function Get-PcVerdict {
    # Reason this path must be skipped right now, or $null.
    param($Item, [string]$Path)
    if (-not ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path))) { return 'already-gone' }
    if ($Item.category -eq 'installer') { $why = Test-PcInstallerFile $Path } else { $why = Test-PcProtected $Path }
    if ($why) { return 'protected:' + $why }
    if (Test-PcLink $Path) { return 'is-a-link' }
    return $null
}

# ---------------------------------------------------------------- dry run
if (-not $Execute) {
    Write-Output 'DRY RUN - nothing has been changed. Add -Execute after the user confirms.'
    foreach ($it in $plan) {
        $what = $it.method
        if ($it.method -eq 'quarantine' -and $Permanent) { $what = 'permanent-delete' }
        Write-Output ("  {0,-4} {1,10}  {2,-18} {3}" -f $it.id, (Format-PcSize ([long]$it.sizeBytes)), $what, $it.label)
        if ($it.method -in @('delete-contents', 'delete-old', 'quarantine')) {
            foreach ($p in @($it.paths)) { $v = Get-PcVerdict $it $p; if ($v) { Write-Output ("         SKIP ($v): $p") } }
        }
    }
    exit 0
}

# ---------------------------------------------------------------- execute
$cmdLines = @()
try { $cmdLines = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine } | ForEach-Object { $_.CommandLine }) } catch { }
$before = Get-PcDrives
$cutoff = Get-PcTempCutoff
$index = New-Object 'System.Collections.Generic.List[object]'
foreach ($q in (Read-PcIndex)) { $index.Add($q) }
$results = New-Object 'System.Collections.Generic.List[object]'
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

foreach ($it in $plan) {
    $res = [pscustomobject]@{ id = $it.id; label = $it.label; method = $it.method; status = 'done'; freedBytes = 0L; quarantinedBytes = 0L; keptInUse = 0; skipped = @() }
    $busy = $null
    if ($it.extra -and $it.extra.busy) { foreach ($c in $cmdLines) { if ($c -match $it.extra.busy) { $busy = $c; break } } }
    if ($busy) {
        $res.status = 'skipped'; $res.skipped = @('tool-is-running-now: ' + $busy.Substring(0, [Math]::Min(120, $busy.Length)))
        $results.Add($res); continue
    }
    try {
        switch -Wildcard ($it.method) {
            'empty-recycle-bin' {
                $b = 0L; foreach ($p in @($it.paths)) { $b += (Measure-PcDir $p).Size }
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                $a = 0L; foreach ($p in @($it.paths)) { $a += (Measure-PcDir $p).Size }
                $res.freedBytes = $b - $a
            }
            'command:conda-clean' {
                $exe = [string]$it.extra.exe
                if (-not $exe -or [System.IO.Path]::GetFileName($exe) -ne 'conda.exe' -or -not [System.IO.File]::Exists($exe)) { throw 'conda.exe not found' }
                $pk = @($it.paths)[0]
                $b = (Measure-PcDir $pk).Size
                & $exe clean --all -y 2>&1 | Out-Null
                $res.freedBytes = $b - (Measure-PcDir $pk).Size
            }
            'delete-old' {
                foreach ($p in @($it.paths)) {
                    $v = Get-PcVerdict $it $p
                    if ($v) { $res.skipped += "$v $p"; continue }
                    foreach ($e in (New-Object System.IO.DirectoryInfo ('\\?\' + $p + '\')).GetFileSystemInfos()) {
                        $a = [int]$e.Attributes
                        if ($a -band 0x400) { continue }
                        $child = $p + '\' + $e.Name
                        if ($a -band 0x10) { $newest = [Math]::Max((Measure-PcDir $child).Newest, $e.LastWriteTimeUtc.Ticks) } else { $newest = $e.LastWriteTimeUtc.Ticks }
                        if ($newest -ge $cutoff) { continue }
                        $r = Remove-PcTree -Path $child
                        $res.freedBytes += $r.Freed; $res.keptInUse += $r.Kept
                    }
                }
            }
            'delete-contents' {
                foreach ($p in @($it.paths)) {
                    $v = Get-PcVerdict $it $p
                    if ($v) { $res.skipped += "$v $p"; continue }
                    $r = Remove-PcTree -Path $p -KeepRoot
                    $res.freedBytes += $r.Freed; $res.keptInUse += $r.Kept
                }
            }
            'quarantine' {
                foreach ($p in @($it.paths)) {
                    $v = Get-PcVerdict $it $p
                    if ($v) { $res.skipped += "$v $p"; continue }
                    $isFile = [System.IO.File]::Exists($p)
                    if ($isFile) { $fi = New-Object System.IO.FileInfo $p; $size = $fi.Length; $newest = $fi.LastWriteTime }
                    else { $m = Measure-PcDir $p; $size = $m.Size; $newest = ([DateTime]::new([Math]::Max($m.Newest, 1), [DateTimeKind]::Utc)).ToLocalTime() }
                    if ($newest -gt $scanTime) { $res.skipped += "changed-since-the-scan $p"; continue }
                    if ($Permanent) {
                        $r = Remove-PcTree -Path $p
                        $res.freedBytes += $r.Freed; $res.keptInUse += $r.Kept
                        continue
                    }
                    $drive = $p.Substring(0, 2)
                    if ($drive -ieq $OutDir.Substring(0, 2)) { $qroot = Join-Path $OutDir 'quarantine' } else { $qroot = $drive + '\' + $script:PcQuarantineName }
                    $slot = Join-Path $qroot ($report.scanId + '\' + $it.id)
                    $dest = Join-Path $slot ([System.IO.Path]::GetFileName($p))
                    $k = 1
                    while ([System.IO.Directory]::Exists($dest) -or [System.IO.File]::Exists($dest)) { $k++; $dest = Join-Path $slot ([System.IO.Path]::GetFileName($p) + ".$k") }
                    try {
                        [void][System.IO.Directory]::CreateDirectory($slot)
                        if ($isFile) { [System.IO.File]::Move('\\?\' + $p, '\\?\' + $dest) } else { [System.IO.Directory]::Move('\\?\' + $p, '\\?\' + $dest) }
                        $res.quarantinedBytes += $size
                        $index.Add([pscustomobject]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); scanId = $report.scanId; id = $it.id; label = $it.label; original = $p; stored = $dest; bytes = $size })
                    } catch { $res.skipped += ('could-not-move (in use, or on another drive): ' + $p + ' - ' + $_.Exception.Message) }
                }
            }
            default { $res.status = 'skipped'; $res.skipped = @('this item is information only') }
        }
    } catch { $res.status = 'failed'; $res.skipped += $_.Exception.Message }
    if ($res.status -eq 'done' -and @($res.skipped).Count -gt 0) {
        if ($res.freedBytes -le 0 -and $res.quarantinedBytes -le 0) { $res.status = 'skipped' } else { $res.status = 'partial' }
    }
    $results.Add($res)
}
Write-PcIndex $index.ToArray()

$after = Get-PcDrives
$freed = 0L; $moved = 0L
foreach ($r in $results) { $freed += $r.freedBytes; $moved += $r.quarantinedBytes }
$driveDelta = @()
foreach ($d in $after) { $b = $before | Where-Object { $_.name -eq $d.name }; $driveDelta += [pscustomobject]@{ name = $d.name; freeBefore = $b.freeBytes; freeAfter = $d.freeBytes } }
$out = [ordered]@{ scanId = $report.scanId; finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); permanent = [bool]$Permanent
    deletedBytes = $freed; quarantinedBytes = $moved; drives = $driveDelta; results = $results }
$logPath = Join-Path $OutDir "clean-$stamp.json"
[System.IO.File]::WriteAllText($logPath, ($out | ConvertTo-Json -Depth 6), $utf8)

Write-Output ("CLEANED: deleted {0}; moved {1} to quarantine (still on disk until -Purge)." -f (Format-PcSize $freed), (Format-PcSize $moved))
foreach ($d in $driveDelta) { Write-Output ("  {0} free {1} -> {2}" -f $d.name, (Format-PcSize $d.freeBefore), (Format-PcSize $d.freeAfter)) }
foreach ($r in $results) {
    Write-Output ("  {0,-4} {1,-8} deleted {2,10}  quarantined {3,10}  in-use {4,5}  {5}" -f $r.id, $r.status, (Format-PcSize $r.freedBytes), (Format-PcSize $r.quarantinedBytes), $r.keptInUse, $r.label)
    foreach ($s in @($r.skipped)) { Write-Output ("         " + $s) }
}
Write-Output "RESULT: $logPath"
