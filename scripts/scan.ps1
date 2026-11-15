#requires -Version 5.1
<#
scan.ps1 - read-only PC checkup for people who make videos with AI tools.

It deletes nothing and changes no setting. The only things it writes are its own reports:
  <OutDir>\scan-<id>.json     the data
  <OutDir>\report-<id>.html   the visual report, opened in the browser when the scan ends (-NoOpen: do not open)

Usage (run with: powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1 ...):
  scan.ps1                                    full checkup of every fixed drive
  scan.ps1 -Quick                             known cache locations only, no drive walk
  scan.ps1 -ProjectRoots "D:\work;E:\video"   also treat these as the user's own project folders
  scan.ps1 -Protect "D:\photos;E:\backup"     extra folders to leave alone

Keep this file ASCII-only (see common.ps1).
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string[]]$ProjectRoots = @(),
    [string[]]$Protect = @(),
    [int]$InstallerAgeDays = 30,
    [int]$StaleDays = 90,
    [int]$ResidueDays = 180,
    [switch]$Quick,
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }   # do not slow down a render in progress

if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'pc-checkup' }
$OutDir = Get-PcNorm $OutDir
[void][System.IO.Directory]::CreateDirectory($OutDir)

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$G = Initialize-PcGuard -Granted $ProjectRoots -Protect $Protect
$userHome = $G.Home; $local = $G.Local; $roam = $G.Roaming
$MB = 1024L * 1024L; $GB = 1024L * $MB
$now = Get-Date
$drives = Get-PcDrives

$items = New-Object 'System.Collections.Generic.List[object]'
$dropped = New-Object 'System.Collections.Generic.List[object]'

function Add-PcItem {
    # Every path is checked against the protection rules here, so nothing protected can reach the list.
    param([string]$Level, [string]$Category, [string]$Label, [string[]]$Paths, [string]$Method,
          [long]$Size = -1, [int]$Files = 0, [long]$Newest = 0, [string]$Note, [hashtable]$Extra, [long]$MinSize = 0)
    $keep = New-Object 'System.Collections.Generic.List[string]'
    $guarded = $Method -in @('delete-contents', 'delete-old', 'quarantine')
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        if ($guarded) {
            if ($Category -eq 'installer') { $why = Test-PcInstallerFile $p } else { $why = Test-PcProtected $p }
            if (-not $why -and (Test-PcLink $p)) { $why = 'is-link' }
            if ($why) { $dropped.Add([pscustomobject]@{ path = $p; category = $Category; reason = $why }); continue }
        }
        $keep.Add($p)
    }
    if ($keep.Count -eq 0) { return }
    if ($Size -lt 0) {
        $Size = 0L; $Files = 0
        foreach ($p in $keep) {
            if ([System.IO.File]::Exists($p)) {
                $fi = New-Object System.IO.FileInfo $p
                $Size += $fi.Length; $Files++
                if ($fi.LastWriteTimeUtc.Ticks -gt $Newest) { $Newest = $fi.LastWriteTimeUtc.Ticks }
            } else {
                $m = Measure-PcDir $p
                $Size += $m.Size; $Files += $m.Files
                if ($m.Newest -gt $Newest) { $Newest = $m.Newest }
            }
        }
    }
    if ($Size -lt $MinSize -or $Size -le 0) { return }
    # basic   = the classic cleanup list (temp, caches, old installers, recycle bin, uninstall leftovers)
    # creator = AI-video extras (models, headless browsers, node_modules, venvs, frames, duplicate models);
    #           these are only cleaned when the user names them one by one
    $group = 'basic'
    if ($Category -in @('model-cache', 'browser-runtime', 'other-cache', 'node-modules', 'venv', 'frames', 'duplicate')) { $group = 'creator' }
    $items.Add([pscustomobject]@{
            id = $null; level = $Level; group = $group; category = $Category; label = $Label; paths = $keep.ToArray()
            sizeBytes = $Size; files = $Files; newest = (ConvertTo-PcDay $Newest); method = $Method
            note = $Note; extra = $Extra
        })
}

function Get-PcExisting {
    param([string[]]$Paths)
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $Paths) { if ($p -and [System.IO.Directory]::Exists($p)) { $n = Get-PcNorm $p; if ($n -and -not $out.Contains($n)) { $out.Add($n) } } }
    return , $out.ToArray()
}

# ---------------------------------------------------------------- 1. temp files and crash dumps
$tempDir = Get-PcNorm $env:TEMP
$cutoff = Get-PcTempCutoff
$tempOld = 0L; $tempOldCount = 0; $tempRecent = 0L
if ($tempDir -and [System.IO.Directory]::Exists($tempDir)) {
    try {
        foreach ($e in (New-Object System.IO.DirectoryInfo ('\\?\' + $tempDir + '\')).EnumerateFileSystemInfos()) {
            $a = [int]$e.Attributes
            if ($a -band 0x400) { continue }
            if ($a -band 0x10) {
                $m = Measure-PcDir ($tempDir + '\' + $e.Name)
                $n = [Math]::Max($m.Newest, $e.LastWriteTimeUtc.Ticks); $s = $m.Size
            } else { $n = $e.LastWriteTimeUtc.Ticks; $s = $e.Length }
            if ($n -lt $cutoff) { $tempOld += $s; $tempOldCount++ } else { $tempRecent += $s }
        }
    } catch { }
    Add-PcItem -Level green -Category temp -Label 'User temp files from before the last boot' -Paths @($tempDir) -Method 'delete-old' `
        -Size $tempOld -Files $tempOldCount -Note 'programs-recreate-what-they-need' -Extra @{ recentBytes = $tempRecent }
}
Add-PcItem -Level green -Category crash -Label 'Crash dumps and error reports' -Method 'delete-contents' -MinSize (5 * $MB) `
    -Paths (Get-PcExisting @("$local\CrashDumps", "$local\Microsoft\Windows\WER\ReportArchive", "$local\Microsoft\Windows\WER\ReportQueue"))

# ---------------------------------------------------------------- 2. browser and app caches
function Get-PcChromiumCaches {
    param([string]$UserData)
    $out = New-Object 'System.Collections.Generic.List[string]'
    if (-not [System.IO.Directory]::Exists($UserData)) { return , $out.ToArray() }
    foreach ($t in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache') {
        if ([System.IO.Directory]::Exists("$UserData\$t")) { $out.Add("$UserData\$t") }
    }
    foreach ($prof in [System.IO.Directory]::GetDirectories($UserData)) {
        $pn = [System.IO.Path]::GetFileName($prof)
        if ($pn -ne 'Default' -and $pn -notlike 'Profile *' -and $pn -ne 'Guest Profile') { continue }
        foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
                'Service Worker\CacheStorage', 'Service Worker\ScriptCache') {
            if ([System.IO.Directory]::Exists("$prof\$c")) { $out.Add("$prof\$c") }
        }
    }
    return , $out.ToArray()
}
foreach ($b in @(@('Chrome', "$local\Google\Chrome\User Data"), @('Edge', "$local\Microsoft\Edge\User Data"),
        @('Brave', "$local\BraveSoftware\Brave-Browser\User Data"))) {
    Add-PcItem -Level green -Category 'browser-cache' -Label ($b[0] + ' cache') -Paths (Get-PcChromiumCaches $b[1]) `
        -Method 'delete-contents' -MinSize (20 * $MB) -Note 'logins-history-bookmarks-untouched'
}
$ffRoot = "$local\Mozilla\Firefox\Profiles"
if ([System.IO.Directory]::Exists($ffRoot)) {
    $ff = @(); foreach ($p in [System.IO.Directory]::GetDirectories($ffRoot)) { if ([System.IO.Directory]::Exists("$p\cache2")) { $ff += "$p\cache2" } }
    Add-PcItem -Level green -Category 'browser-cache' -Label 'Firefox cache' -Paths $ff -Method 'delete-contents' -MinSize (20 * $MB) `
        -Note 'logins-history-bookmarks-untouched'
}

# Desktop apps built on Chromium (editors, launchers, AI tools) keep the same kind of cache folders.
$skipVendors = @('Google', 'Microsoft', 'BraveSoftware', 'Mozilla', 'Temp', 'Packages', 'Programs')
foreach ($base in @($roam, $local)) {
    if (-not [System.IO.Directory]::Exists($base)) { continue }
    foreach ($d in [System.IO.Directory]::GetDirectories($base)) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($skipVendors -contains $name) { continue }
        if (-not [System.IO.Directory]::Exists("$d\Cache")) { continue }
        if (-not ([System.IO.Directory]::Exists("$d\Code Cache") -or [System.IO.Directory]::Exists("$d\GPUCache"))) { continue }
        $paths = Get-PcExisting @("$d\Cache", "$d\Code Cache", "$d\GPUCache", "$d\DawnCache", "$d\DawnGraphiteCache",
            "$d\DawnWebGPUCache", "$d\CachedData", "$d\Service Worker\CacheStorage", "$d\Service Worker\ScriptCache")
        Add-PcItem -Level green -Category 'app-cache' -Label ($name + ' cache') -Paths $paths -Method 'delete-contents' -MinSize (20 * $MB) `
            -Note 'settings-and-data-untouched'
    }
}
foreach ($v in @(@('JianyingPro', "$local\JianyingPro\User Data\Cache"), @('CapCut', "$local\CapCut\User Data\Cache"))) {
    Add-PcItem -Level yellow -Category 'app-cache' -Label ($v[0] + ' cache (drafts are not included)') -Paths (Get-PcExisting @($v[1])) `
        -Method 'quarantine' -MinSize (50 * $MB) -Note 'effects-and-materials-download-again'
}

# ---------------------------------------------------------------- 3. package-manager caches
$devCaches = @(
    @('pip download cache', @($env:PIP_CACHE_DIR, "$local\pip\Cache"), '(-m\s+pip\s)|(\\pip[0-9.]*(\.exe)?["\s])'),
    @('npm download cache', @("$local\npm-cache", "$roam\npm-cache"), 'npm-cli\.js|npx-cli\.js'),
    @('yarn download cache', @("$local\Yarn\Cache"), 'yarn(\.js|\.cmd|pkg)'),
    @('uv download cache', @($env:UV_CACHE_DIR, "$local\uv\cache"), '\\uv(\.exe)?["\s]')
)
foreach ($c in $devCaches) {
    Add-PcItem -Level green -Category 'dev-cache' -Label $c[0] -Paths (Get-PcExisting $c[1]) -Method 'delete-contents' -MinSize (20 * $MB) `
        -Note 'packages-download-again-when-needed' -Extra @{ busy = $c[2] }
}

# conda: the official "conda clean" is the right tool; it keeps every package an environment still uses.
$condaRoots = New-Object 'System.Collections.Generic.List[string]'
$condaCand = @("$userHome\anaconda3", "$userHome\miniconda3", "$userHome\miniforge3", "$env:ProgramData\anaconda3", "$env:ProgramData\miniconda3")
foreach ($z in $G.Zones) { if ($z.Reason -eq 'installed-app') { $condaCand += $z.Path } }
if ($env:CONDA_EXE) { $condaCand += (Split-Path (Split-Path $env:CONDA_EXE -Parent) -Parent) }
foreach ($r in $condaCand) {
    if ($r -and [System.IO.Directory]::Exists("$r\conda-meta") -and [System.IO.Directory]::Exists("$r\pkgs") -and
        [System.IO.File]::Exists("$r\Scripts\conda.exe") -and -not $condaRoots.Contains($r)) { $condaRoots.Add($r) }
}
foreach ($r in $condaRoots) {
    $lower = 0L; $n = 0
    foreach ($f in (New-Object System.IO.DirectoryInfo "$r\pkgs").EnumerateFiles()) {
        if ($f.Extension -in @('.conda', '.bz2')) { $lower += $f.Length; $n++ }
    }
    $lower += (Measure-PcDir "$r\pkgs\cache").Size
    $all = Measure-PcDir "$r\pkgs"
    Add-PcItem -Level green -Category 'dev-cache' -Label 'conda package cache (conda clean --all)' -Paths @("$r\pkgs") -Method 'command:conda-clean' `
        -Size $lower -Files $n -Newest $all.Newest -MinSize (50 * $MB) -Note 'size-is-a-lower-bound;environments-keep-working' `
        -Extra @{ exe = "$r\Scripts\conda.exe"; upperBytes = $all.Size; busy = '\\conda(\.exe|\.bat)?["\s]' }
}

# ---------------------------------------------------------------- 4. AI model caches and headless browsers
$hub = $null
foreach ($c in @($env:HF_HUB_CACHE, $(if ($env:HF_HOME) { "$env:HF_HOME\hub" }), "$userHome\.cache\huggingface\hub")) {
    if ($c -and [System.IO.Directory]::Exists($c)) { $hub = Get-PcNorm $c; break }
}
if ($hub) {
    foreach ($d in [System.IO.Directory]::GetDirectories($hub)) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($name -notmatch '^(models|datasets|spaces)--(.+)$') { continue }
        $label = 'HuggingFace ' + $Matches[1].TrimEnd('s') + ': ' + ($Matches[2] -replace '--', '/')
        Add-PcItem -Level yellow -Category 'model-cache' -Label $label -Paths @($d) -Method 'quarantine' -MinSize (50 * $MB) `
            -Note 'downloads-again-on-next-use'
    }
}
$ollama = "$userHome\.ollama\models"; if ($env:OLLAMA_MODELS) { $ollama = $env:OLLAMA_MODELS }
$modelDirs = @(
    @('PyTorch hub models', "$userHome\.cache\torch"), @('Whisper models', "$userHome\.cache\whisper"),
    @('ModelScope models', "$userHome\.cache\modelscope"), @('rembg / U2Net matting models', "$userHome\.u2net"),
    @('rembg matting models', "$userHome\.rembg"), @('InsightFace models', "$userHome\.insightface"),
    @('PaddleOCR models', "$userHome\.paddleocr"), @('PaddleX models', "$userHome\.paddlex"),
    @('EasyOCR models', "$userHome\.EasyOCR"), @('Keras models', "$userHome\.keras"), @('DeepFace models', "$userHome\.deepface"),
    @('Ollama models', $ollama), @('LM Studio models', "$userHome\.lmstudio\models"), @('LM Studio models', "$userHome\.cache\lm-studio\models")
)
foreach ($m in $modelDirs) {
    Add-PcItem -Level yellow -Category 'model-cache' -Label $m[0] -Paths (Get-PcExisting @($m[1])) -Method 'quarantine' -MinSize (50 * $MB) `
        -Note 'downloads-again-on-next-use'
}
Add-PcItem -Level yellow -Category 'browser-runtime' -Label 'Puppeteer browsers' -Paths (Get-PcExisting @("$userHome\.cache\puppeteer")) `
    -Method 'quarantine' -MinSize (50 * $MB) -Note 'downloads-again-on-next-use'

$pw = "$local\ms-playwright"; if ($env:PLAYWRIGHT_BROWSERS_PATH -and $env:PLAYWRIGHT_BROWSERS_PATH -ne '0') { $pw = $env:PLAYWRIGHT_BROWSERS_PATH }
if ([System.IO.Directory]::Exists($pw)) {
    $fam = @{}
    foreach ($d in [System.IO.Directory]::GetDirectories($pw)) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($name -match '^(.+)-(\d+)$') {
            if (-not $fam.ContainsKey($Matches[1])) { $fam[$Matches[1]] = @() }
            $fam[$Matches[1]] += , @([int]$Matches[2], $d)
        }
    }
    foreach ($k in $fam.Keys) {
        $vers = @($fam[$k] | Sort-Object { $_[0] } -Descending)
        for ($i = 1; $i -lt $vers.Count; $i++) {
            Add-PcItem -Level yellow -Category 'browser-runtime' -Label ("Playwright $k-" + $vers[$i][0] + ' (older build; newest here is ' + $vers[0][0] + ')') `
                -Paths @($vers[$i][1]) -Method 'quarantine' -MinSize (20 * $MB) -Note 'an-older-project-may-still-ask-for-it'
        }
    }
}

# Anything else large in ~/.cache: by convention regenerable, but we do not know the owner, so it needs a decision.
$known = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
foreach ($it in $items) { foreach ($p in $it.paths) { [void]$known.Add($p) } }
if ([System.IO.Directory]::Exists("$userHome\.cache")) {
    foreach ($d in [System.IO.Directory]::GetDirectories("$userHome\.cache")) {
        $covered = $false
        foreach ($p in $known) { if ((Test-PcUnder $p $d) -or (Test-PcUnder $d $p)) { $covered = $true; break } }
        if ($covered) { continue }
        Add-PcItem -Level yellow -Category 'other-cache' -Label ('~/.cache/' + [System.IO.Path]::GetFileName($d)) -Paths @($d) -Method 'quarantine' `
            -MinSize (200 * $MB) -Note 'cache-of-an-unknown-tool'
    }
}

# ---------------------------------------------------------------- 5. old installers in Downloads
$insts = New-Object 'System.Collections.Generic.List[object]'
if ([System.IO.Directory]::Exists($G.Downloads)) {
    $dirs = @($G.Downloads)
    try { $dirs += [System.IO.Directory]::GetDirectories($G.Downloads) } catch { }
    foreach ($d in $dirs) {
        if (Test-PcLink $d) { continue }
        try {
            foreach ($f in (New-Object System.IO.DirectoryInfo $d).EnumerateFiles()) {
                if ($script:PcInstallerExt -notcontains $f.Extension.ToLowerInvariant()) { continue }
                $t = $f.LastWriteTime; if ($f.CreationTime -gt $t) { $t = $f.CreationTime }
                if (($now - $t).TotalDays -lt $InstallerAgeDays -or $f.Length -lt $MB) { continue }
                $insts.Add([pscustomobject]@{ Path = $f.FullName; Size = $f.Length; Ticks = $t.ToUniversalTime().Ticks; Name = $f.Name })
            }
        } catch { }
    }
}
$instAll = @($insts | Sort-Object Size -Descending)
foreach ($f in ($instAll | Select-Object -First 60)) {
    Add-PcItem -Level yellow -Category installer -Label $f.Name -Paths @($f.Path) -Method 'quarantine' -Size $f.Size -Files 1 -Newest $f.Ticks `
        -Note 'installed-software-does-not-need-its-installer'
}

# ---------------------------------------------------------------- 6. recycle bin
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$binPaths = @(); $binSize = 0L; $binCount = 0; $binNewest = 0L; $binBy = @{}
foreach ($d in $drives) {
    $bp = $d.name + '\$Recycle.Bin\' + $sid
    if (-not [System.IO.Directory]::Exists($bp)) { continue }
    $m = Measure-PcDir $bp
    if ($m.Size -le 0) { continue }
    $binPaths += $bp; $binSize += $m.Size; $binBy[$d.name.ToUpperInvariant()] = $m.Size
    try { $binCount += @([System.IO.Directory]::GetFileSystemEntries($bp, '$R*')).Count } catch { }
    if ($m.Newest -gt $binNewest) { $binNewest = $m.Newest }
}
if ($binPaths.Count) {
    Add-PcItem -Level yellow -Category 'recycle-bin' -Label 'Recycle Bin (all drives)' -Paths $binPaths -Method 'empty-recycle-bin' -Size $binSize `
        -Files $binCount -Newest $binNewest -Note 'cannot-be-undone' -Extra @{ byDrive = $binBy }
}

# ---------------------------------------------------------------- 7. leftovers of uninstalled software
function Get-PcToken { param([string]$s) if (-not $s) { return '' }; return ([regex]::Replace($s.ToLowerInvariant(), '[^\p{L}\p{Nd}]', '')) }
$tokens = New-Object 'System.Collections.Generic.HashSet[string]'
$addTok = { param($s) $t = Get-PcToken $s; if ($t.Length -ge 3) { [void]$tokens.Add($t) } }
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    $entries = @()
    try { $entries = @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue) } catch { }
    foreach ($e in $entries) {
        foreach ($prop in 'DisplayName', 'Publisher', 'PSChildName') {
            $v = $null; try { $v = $e.$prop } catch { }
            if ($v) { & $addTok $v; foreach ($w in ([string]$v).Split(' ')) { if ($w.Length -ge 4) { & $addTok $w } } }
        }
        $loc = $null; try { $loc = $e.InstallLocation } catch { }
        if ($loc) { & $addTok (([string]$loc).Trim('"').TrimEnd('\').Split('\')[-1]) }   # registry values can hold quotes or junk
    }
}
try { foreach ($p in @(Get-AppxPackage -ErrorAction Stop)) { & $addTok $p.Name; foreach ($w in $p.Name.Split('.')) { if ($w.Length -ge 4) { & $addTok $w } } } } catch { }
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { & $addTok $p.ProcessName }
foreach ($sm in @("$roam\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")) {
    if ([System.IO.Directory]::Exists($sm)) {
        try { foreach ($l in [System.IO.Directory]::EnumerateFiles($sm, '*.lnk', 'AllDirectories')) { & $addTok ([System.IO.Path]::GetFileNameWithoutExtension($l)) } } catch { }
    }
}
foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$local\Programs")) {
    if ($pf -and [System.IO.Directory]::Exists($pf)) { foreach ($d in [System.IO.Directory]::GetDirectories($pf)) { & $addTok ([System.IO.Path]::GetFileName($d)) } }
}
$neverResidue = @('microsoft', 'packages', 'temp', 'programs', 'google', 'mozilla', 'nvidia', 'nvidiacorporation', 'intel', 'amd',
    'd3dscache', 'crashdumps', 'pip', 'npm', 'npmcache', 'uv', 'yarn', 'pnpm', 'conda', 'nuget', 'python', 'msplaywright',
    'connecteddevicesplatform', 'comms', 'publishers', 'virtualstore', 'placeholdertilelogofolder', 'squirreltemp',
    'applicationdata', 'history', 'temporaryinternetfiles', 'identities', 'pccheckup')
# Second check: does any uninstall entry, service or startup command still point into a folder of this name?
$hay = New-Object System.Text.StringBuilder
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    $entries = @()
    try { $entries = @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue) } catch { }
    foreach ($e in $entries) {
        foreach ($prop in 'UninstallString', 'DisplayIcon', 'InstallLocation', 'InstallSource') {
            $v = $null; try { $v = $e.$prop } catch { }
            if ($v) { [void]$hay.Append([string]$v).Append('|') }
        }
    }
}
try { foreach ($s in @(Get-CimInstance Win32_Service)) { if ($s.PathName) { [void]$hay.Append($s.PathName).Append('|') } } } catch { }
try { foreach ($s in @(Get-CimInstance Win32_StartupCommand)) { if ($s.Command) { [void]$hay.Append($s.Command).Append('|') } } } catch { }
$haystack = $hay.ToString().ToLowerInvariant()

function Test-PcHasSaves {
    # Game saves and settings often outlive the game. A leftover folder that looks like one is never listed.
    param([string]$Dir)
    $level = @($Dir)
    for ($depth = 0; $depth -lt 3 -and $level.Count -gt 0; $depth++) {
        $next = @()
        foreach ($d in $level) {
            try {
                foreach ($s in [System.IO.Directory]::GetDirectories($d)) {
                    if ([System.IO.Path]::GetFileName($s) -match '^(Saved|SaveGames?|Saves?|SaveData|Profiles?|UserData)$') { return $true }
                    $next += $s
                }
                if (@([System.IO.Directory]::GetFiles($d, '*.sav')).Count -gt 0) { return $true }
            } catch { }
        }
        $level = $next
    }
    return $false
}

$known.Clear()
foreach ($it in $items) { foreach ($p in $it.paths) { [void]$known.Add($p) } }
$residueLimit = $now.AddDays(-$ResidueDays).ToUniversalTime().Ticks
foreach ($base in @($roam, $local, "$userHome\AppData\LocalLow")) {
    if (-not [System.IO.Directory]::Exists($base)) { continue }
    foreach ($d in [System.IO.Directory]::GetDirectories($base)) {
        $tok = Get-PcToken ([System.IO.Path]::GetFileName($d))
        if ($tok.Length -lt 3 -or $neverResidue -contains $tok) { continue }
        if ((Test-PcProtected $d) -or (Test-PcLink $d)) { continue }
        $match = $false
        foreach ($t in $tokens) { if ($t.Contains($tok) -or ($t.Length -ge 4 -and $tok.Contains($t))) { $match = $true; break } }
        if ($match) { continue }
        if ($haystack.Contains('\' + [System.IO.Path]::GetFileName($d).ToLowerInvariant() + '\')) { continue }
        $covered = $false
        foreach ($p in $known) { if (Test-PcUnder $p $d) { $covered = $true; break } }
        if ($covered) { continue }
        $m = Measure-PcDir $d
        if ($m.Size -lt 50 * $MB -or $m.Newest -ge $residueLimit) { continue }
        if (Test-PcHasSaves $d) { continue }
        Add-PcItem -Level yellow -Category residue -Label ([System.IO.Path]::GetFileName($d)) -Paths @($d) -Method 'quarantine' -Size $m.Size `
            -Files $m.Files -Newest $m.Newest -Note 'no-installed-program-matches-this-name;a-guess-not-a-fact'
    }
}

# ---------------------------------------------------------------- 8. things reported but never touched
$system = New-Object 'System.Collections.Generic.List[object]'
$addSys = {
    param($key, $path, $advice)
    $size = $null; $unread = $false
    try {
        if ([System.IO.File]::Exists($path)) { $size = (New-Object System.IO.FileInfo $path).Length }
        elseif ([System.IO.Directory]::Exists($path)) { $m = Measure-PcDir $path; $size = $m.Size; $unread = ($m.Unreadable -gt 0) }
        else { return }
    } catch { $unread = $true }
    $system.Add([pscustomobject]@{ key = $key; path = $path; sizeBytes = $size; needsAdminToMeasure = $unread; advice = $advice })
}
$sr = $env:SystemRoot; $sd = $env:SystemDrive
& $addSys 'windows-temp' "$sr\Temp" 'use-windows-storage-settings'
& $addSys 'windows-update-downloads' "$sr\SoftwareDistribution\Download" 'use-windows-storage-settings'
& $addSys 'previous-windows' "$sd\Windows.old" 'use-windows-storage-settings'
& $addSys 'windows-installer-store' "$sr\Installer" 'never-delete;needed-to-uninstall-and-repair'
& $addSys 'hibernation-file' "$sd\hiberfil.sys" 'see-settings-advice'
foreach ($d in $drives) { & $addSys 'page-file' ($d.name + '\pagefile.sys') 'managed-by-windows' }

$notable = New-Object 'System.Collections.Generic.List[object]'
foreach ($n in @(@('wechat', "$userHome\Documents\WeChat Files"), @('wechat', "$userHome\Documents\xwechat_files"), @('wechat', "$userHome\xwechat_files"),
        @('tencent-apps', "$roam\Tencent"), @('qq', "$userHome\Documents\Tencent Files"), @('feishu', "$roam\LarkShell"),
        @('dingtalk', "$roam\DingTalk"), @('jianying-drafts', "$local\JianyingPro\User Data\Projects"))) {
    if ([System.IO.Directory]::Exists($n[1])) {
        $m = Measure-PcDir $n[1]
        if ($m.Size -ge 300 * $MB) { $notable.Add([pscustomobject]@{ key = $n[0]; path = $n[1]; sizeBytes = $m.Size; advice = 'personal-data;use-the-app-own-storage-manager' }) }
    }
}

# ---------------------------------------------------------------- 9. drive walk
$tree = New-Object 'System.Collections.Generic.List[object]'
$protectedSummary = New-Object 'System.Collections.Generic.List[object]'
$bigFiles = New-Object 'System.Collections.Generic.List[object]'
$otherDups = New-Object 'System.Collections.Generic.List[object]'
$active = [pscustomobject]@{ nodeModulesCount = 0; nodeModulesBytes = 0L; venvCount = 0; venvBytes = 0L }
$walk = [pscustomobject]@{ files = 0L; folders = 0; unreadable = 0; seconds = 0 }

if (-not $Quick) {
    $recName = New-Object 'System.Collections.Generic.List[string]'
    $recParent = New-Object 'System.Collections.Generic.List[int]'
    $recDepth = New-Object 'System.Collections.Generic.List[int]'
    $recState = New-Object 'System.Collections.Generic.List[int]'     # 0 = look for cleanable things, 1 = measure only
    $recSize = New-Object 'System.Collections.Generic.List[long]'
    $recFiles = New-Object 'System.Collections.Generic.List[int]'
    $recNewest = New-Object 'System.Collections.Generic.List[long]'
    $recTag = New-Object 'System.Collections.Generic.List[string]'
    $stackI = New-Object 'System.Collections.Generic.Stack[int]'
    $stackP = New-Object 'System.Collections.Generic.Stack[string]'
    $big = New-Object 'System.Collections.Generic.List[object]'
    $frameCand = New-Object 'System.Collections.Generic.List[object]'

    $imgExt = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    foreach ($x in '.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff', '.exr', '.tga') { [void]$imgExt.Add($x) }
    $marker = New-Object 'System.Collections.Generic.Dictionary[string,int]' ($script:PcIgnoreCase)
    $marker['package.json'] = 1; $marker['pyvenv.cfg'] = 2
    foreach ($x in 'UnityPlayer.dll', 'GameAssembly.dll', 'steam_api.dll', 'steam_api64.dll', 'steam_appid.txt', 'installscript.vdf',
            'EOSSDK-Win64-Shipping.dll') { $marker[$x] = 4 }
    $appDirNames = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    foreach ($x in 'app', 'resources', 'app.asar.unpacked') { [void]$appDirNames.Add($x) }
    $zoneMap = New-Object 'System.Collections.Generic.Dictionary[string,string]' ($script:PcIgnoreCase)
    foreach ($z in $G.Zones) { $zoneMap[$z.Path] = $z.Reason }
    $nameMap = $G.Names; $patterns = $G.Patterns
    $homeTop = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    foreach ($x in $G.HomeTop) { [void]$homeTop.Add($x) }
    $grantSet = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    foreach ($x in $G.Granted) { [void]$grantSet.Add($x) }
    $grantCount = $grantSet.Count
    $homePath = $userHome; $profilesRoot = $G.ProfilesRoot
    $bigMin = 200 * $MB; $frameMin = 100

    foreach ($d in $drives) {
        $recName.Add($d.name); $recParent.Add(-1); $recDepth.Add(0); $recState.Add(0)
        $recSize.Add(0L); $recFiles.Add(0); $recNewest.Add(0L); $recTag.Add($null)
        $stackI.Push($recName.Count - 1); $stackP.Push($d.name)
    }
    $unreadable = 0
    while ($stackI.Count -gt 0) {
        $i = $stackI.Pop(); $path = $stackP.Pop(); $st = $recState[$i]; $dep = $recDepth[$i]
        $size = 0L; $cnt = 0; $newest = 0L; $img = 0
        $subs = $null; $hasPkg = $false; $hasNode = $false; $isVenv = $false; $isGame = $false; $hasExe = $false
        try {
            $di = New-Object System.IO.DirectoryInfo ('\\?\' + $path + '\')
            foreach ($e in $di.EnumerateFileSystemInfos()) {
                $a = [int]$e.Attributes
                if ($a -band 0x400) { continue }
                if ($a -band 0x10) {
                    if ($null -eq $subs) { $subs = New-Object 'System.Collections.Generic.List[string]' }
                    $subs.Add($e.Name); continue
                }
                if ($a -band 0x401000) { continue }
                $len = $e.Length; $size += $len; $cnt++
                $t = $e.LastWriteTimeUtc.Ticks
                if ($t -gt $newest) { $newest = $t }
                if ($len -ge $bigMin) { $big.Add([pscustomobject]@{ Path = ($path + '\' + $e.Name); Size = $len; Ticks = $t }) }
                if ($st -eq 0) {
                    $x = $e.Extension
                    if ($imgExt.Contains($x)) { $img++ }
                    elseif ($x -eq '.exe') { $hasExe = $true; if ($e.Name -eq 'node.exe') { $hasNode = $true } }
                    elseif ($marker.ContainsKey($e.Name)) {
                        $mk = $marker[$e.Name]
                        if ($mk -eq 1) { $hasPkg = $true } elseif ($mk -eq 2) { $isVenv = $true } else { $isGame = $true }
                    }
                }
            }
        } catch { $unreadable++ }
        $recSize[$i] = $size; $recFiles[$i] = $cnt; $recNewest[$i] = $newest

        $childState = $st
        if ($st -eq 0) {
            if ($isVenv) { $recTag[$i] = 'venv'; $childState = 1 }
            elseif ($isGame -or ($hasExe -and $null -ne $subs -and $subs.Contains('Engine'))) { $recTag[$i] = 'prot:games'; $childState = 1 }
            elseif ($img -ge $frameMin) { $frameCand.Add([pscustomobject]@{ Index = $i; Path = $path }) }
        }
        if ($null -eq $subs) { continue }
        $isHome = ($st -eq 0 -and $path -eq $homePath)
        $isProfiles = ($st -eq 0 -and $path -eq $profilesRoot)
        $nmOk = ($st -eq 0 -and $hasPkg -and -not $hasNode -and -not $appDirNames.Contains($recName[$i]))
        foreach ($n in $subs) {
            $cp = $path + '\' + $n
            $cst = $childState; $tag = $null; $descend = $true
            if ($st -eq 0 -and $childState -eq 0) {
                $r = $null
                if (-not $zoneMap.TryGetValue($cp, [ref]$r)) {
                    if (-not $nameMap.TryGetValue($n, [ref]$r)) {
                        foreach ($p in $patterns) { if ($p.Pattern.IsMatch($n)) { $r = $p.Reason; break } }
                    }
                }
                if ($r -eq 'system') { $tag = 'skip:system'; $descend = $false }
                elseif ($r) { $tag = 'prot:' + $r; $cst = 1 }
                elseif ($isHome) { $cst = 1; if (-not $homeTop.Contains($n)) { $tag = 'prot:personal' } }
                elseif ($isProfiles -and $cp -ne $homePath) { $cst = 1; $tag = 'prot:other-user' }
                elseif ($nmOk -and $n -eq 'node_modules') { $cst = 1; $tag = 'node_modules' }
            }
            if ($cst -eq 1 -and $grantCount -gt 0 -and $grantSet.Contains($cp)) { $cst = 0; $tag = 'granted' }
            $recName.Add($n); $recParent.Add($i); $recDepth.Add($dep + 1); $recState.Add($cst)
            $recSize.Add(0L); $recFiles.Add(0); $recNewest.Add(0L); $recTag.Add($tag)
            if ($descend) { $stackI.Push($recName.Count - 1); $stackP.Push($cp) }
        }
    }

    # Roll sizes up to parents. Children always have a higher index than their parent.
    $count = $recName.Count
    $aSize = $recSize.ToArray(); $aFiles = $recFiles.ToArray(); $aNewest = $recNewest.ToArray(); $aParent = $recParent.ToArray()
    $ownNewest = $recNewest.ToArray()
    $totalFiles = 0L
    for ($i = 0; $i -lt $count; $i++) { $totalFiles += $aFiles[$i] }
    for ($i = $count - 1; $i -ge 0; $i--) {
        $p = $aParent[$i]
        if ($p -lt 0) { continue }
        $aSize[$p] += $aSize[$i]; $aFiles[$p] += $aFiles[$i]
        if ($aNewest[$i] -gt $aNewest[$p]) { $aNewest[$p] = $aNewest[$i] }
    }
    $zoneOf = New-Object 'string[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        $t = $recTag[$i]
        if ($t -and ($t.StartsWith('prot:') -or $t.StartsWith('skip:'))) { $zoneOf[$i] = $t.Substring(5) }
        elseif ($aParent[$i] -ge 0) { $zoneOf[$i] = $zoneOf[$aParent[$i]] }
    }
    function Get-PcRecPath {
        param([int]$Index)
        $parts = New-Object 'System.Collections.Generic.List[string]'
        $j = $Index
        while ($j -ge 0) { $parts.Add($recName[$j]); $j = $aParent[$j] }
        $parts.Reverse()
        return ($parts -join '\')
    }

    $staleLimit = $now.AddDays(-$StaleDays).ToUniversalTime().Ticks
    $protAgg = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $t = $recTag[$i]
        if ($t -eq 'node_modules') {
            if ($aSize[$i] -lt 100 * $MB) { continue }
            $proj = Get-PcRecPath $aParent[$i]
            if ($ownNewest[$aParent[$i]] -lt $staleLimit) {
                Add-PcItem -Level yellow -Category 'node-modules' -Label $proj -Paths @($proj + '\node_modules') -Method 'quarantine' -Size $aSize[$i] `
                    -Files $aFiles[$i] -Newest $ownNewest[$aParent[$i]] -Note 'npm-install-brings-it-back;project-untouched-for-a-while'
            } else { $active.nodeModulesCount++; $active.nodeModulesBytes += $aSize[$i] }
        } elseif ($t -eq 'venv') {
            if ($aSize[$i] -lt 100 * $MB) { continue }
            $vp = Get-PcRecPath $i
            if ($aNewest[$i] -lt $staleLimit) {
                Add-PcItem -Level yellow -Category venv -Label $vp -Paths @($vp) -Method 'quarantine' -Size $aSize[$i] -Files $aFiles[$i] `
                    -Newest $aNewest[$i] -Note 'recreate-with-pip-or-uv;nothing-installed-here-for-a-while'
            } else { $active.venvCount++; $active.venvBytes += $aSize[$i] }
        } elseif ($t -and $t.StartsWith('prot:')) {
            $reason = $t.Substring(5)
            if (-not $protAgg.ContainsKey($reason)) { $protAgg[$reason] = [pscustomobject]@{ reason = $reason; sizeBytes = 0L; folders = 0; byDrive = @{}; largest = (New-Object 'System.Collections.Generic.List[object]') } }
            $protAgg[$reason].sizeBytes += $aSize[$i]; $protAgg[$reason].folders++
            $rp = Get-PcRecPath $i
            $dk = $rp.Substring(0, 2).ToUpperInvariant()   # per-drive totals, used by the visual report
            $protAgg[$reason].byDrive[$dk] = [long]$protAgg[$reason].byDrive[$dk] + $aSize[$i]
            if ($aSize[$i] -ge 500 * $MB) { $protAgg[$reason].largest.Add([pscustomobject]@{ path = $rp; sizeBytes = $aSize[$i] }) }
        }
        if ($recDepth[$i] -ge 1 -and (($aSize[$i] -ge $GB -and $recDepth[$i] -le 6) -or ($t -eq 'granted'))) {
            $tree.Add([pscustomobject]@{ path = (Get-PcRecPath $i); sizeBytes = $aSize[$i]; files = $aFiles[$i]; newest = (ConvertTo-PcDay $aNewest[$i]); zone = $zoneOf[$i] })
        }
    }
    foreach ($k in $protAgg.Keys) {
        $e = $protAgg[$k]
        $e.largest = @($e.largest | Sort-Object sizeBytes -Descending | Select-Object -First 8)
        $protectedSummary.Add($e)
    }

    # Rendered frame sequences: numbered images with one prefix and no gaps. Camera-style names never qualify.
    $frameRx = New-Object System.Text.RegularExpressions.Regex '^(.*?)(\d{3,9})$'
    $cameraRx = New-Object System.Text.RegularExpressions.Regex ('^(img|dsc[a-z]?|pxl|mvimg|gopr|dji|cimg|sam|p|photo|pic|scan|screenshot.*|snap.*|wechat.*|mmexport|wx.*)[\s_\-]*$', 'IgnoreCase')
    foreach ($fc in $frameCand) {
        $groups = @{}; $total = 0
        try {
            foreach ($f in (New-Object System.IO.DirectoryInfo ('\\?\' + $fc.Path + '\')).EnumerateFiles()) {
                if (-not $imgExt.Contains($f.Extension)) { continue }
                $total++
                $m = $frameRx.Match([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
                if (-not $m.Success) { continue }
                $pre = $m.Groups[1].Value.ToLowerInvariant()
                if (-not $groups.ContainsKey($pre)) { $groups[$pre] = New-Object 'System.Collections.Generic.List[long]' }
                $groups[$pre].Add([long]$m.Groups[2].Value)
            }
        } catch { continue }
        $best = $null; $bestPre = ''
        foreach ($k in $groups.Keys) { if ($null -eq $best -or $groups[$k].Count -gt $best.Count) { $best = $groups[$k]; $bestPre = $k } }
        if ($null -eq $best -or $best.Count -lt $frameMin -or $best.Count -lt 0.9 * $total) { continue }
        if ($cameraRx.IsMatch($bestPre)) { continue }
        $lo = [long]::MaxValue; $hi = 0L
        foreach ($v in $best) { if ($v -lt $lo) { $lo = $v }; if ($v -gt $hi) { $hi = $v } }
        if (($hi - $lo + 1) -gt [Math]::Ceiling($best.Count * 1.1)) { continue }
        $idx = $fc.Index
        Add-PcItem -Level yellow -Category frames -Label $fc.Path -Paths @($fc.Path) -Method 'quarantine' -Size $aSize[$idx] -Files $aFiles[$idx] `
            -Newest $aNewest[$idx] -MinSize (100 * $MB) -Note 'rendered-frame-sequence;keep-if-the-final-video-is-not-exported-yet' `
            -Extra @{ frames = $best.Count; prefix = $bestPre; stale = ($aNewest[$idx] -lt $staleLimit) }
    }

    # Large files, and byte-identical copies among them (same size, same first and last megabyte).
    # Only model weights become cleanup items. Identical videos, archives and the like are reported
    # as information: one of them is usually the user's original footage.
    $modelExt = @('.safetensors', '.ckpt', '.pt', '.pth', '.onnx', '.gguf', '.bin', '.pb', '.h5', '.tflite', '.engine', '.weights')
    $free = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in ($big | Sort-Object Size -Descending)) {
        $why = Test-PcProtected $b.Path
        if ($bigFiles.Count -lt 40) {
            $bigFiles.Add([pscustomobject]@{ path = $b.Path; sizeBytes = $b.Size; modified = (ConvertTo-PcDay $b.Ticks); zone = $why })
        }
        if (-not $why -and $b.Path -notmatch '\\(site-packages|node_modules|Lib|bin)\\') { $free.Add($b) }
    }
    function Get-PcFingerprint {
        param([string]$Path, [long]$Size)
        try {
            $fs = [System.IO.File]::Open('\\?\' + $Path, 'Open', 'Read', 'ReadWrite')
            try {
                $buf = New-Object byte[] (2 * 1024 * 1024)
                $n = $fs.Read($buf, 0, 1048576)
                [void]$fs.Seek(-1048576, 'End')
                $n2 = $fs.Read($buf, 1048576, 1048576)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                return ([System.BitConverter]::ToString($sha.ComputeHash($buf, 0, 1048576 + $n2)))
            } finally { $fs.Dispose() }
        } catch { return $null }
    }
    foreach ($grp in ($free | Group-Object Size | Where-Object { $_.Count -ge 2 })) {
        $byPrint = @{}
        foreach ($f in $grp.Group) {
            $fp = Get-PcFingerprint $f.Path $f.Size
            if (-not $fp) { continue }
            if (-not $byPrint.ContainsKey($fp)) { $byPrint[$fp] = @() }
            $byPrint[$fp] += $f
        }
        foreach ($k in $byPrint.Keys) {
            $set = @($byPrint[$k] | Sort-Object Ticks -Descending)
            if ($set.Count -lt 2) { continue }
            if ($modelExt -notcontains [System.IO.Path]::GetExtension($set[0].Path).ToLowerInvariant()) {
                $otherDups.Add([pscustomobject]@{ sizeBytes = $set[0].Size; copies = @($set | ForEach-Object { $_.Path }) })
                continue
            }
            for ($j = 1; $j -lt $set.Count; $j++) {
                Add-PcItem -Level yellow -Category duplicate -Label $set[$j].Path -Paths @($set[$j].Path) -Method 'quarantine' -Size $set[$j].Size -Files 1 `
                    -Newest $set[$j].Ticks -Note 'same-model-file-stored-twice;the-program-that-reads-this-copy-will-download-it-again' -Extra @{ sameAs = $set[0].Path }
            }
        }
    }
    $walk.files = $totalFiles; $walk.folders = $count; $walk.unreadable = $unreadable
}

# ---------------------------------------------------------------- 10. facts for the optional settings advice
$facts = [ordered]@{}
foreach ($v in 'HF_HOME', 'HF_HUB_CACHE', 'PIP_CACHE_DIR', 'UV_CACHE_DIR', 'npm_config_cache', 'PLAYWRIGHT_BROWSERS_PATH', 'OLLAMA_MODELS', 'TORCH_HOME', 'MODELSCOPE_CACHE') {
    $facts["env_$v"] = [Environment]::GetEnvironmentVariable($v)
}
$facts['tempDir'] = $tempDir
try { $os = Get-CimInstance Win32_OperatingSystem; $facts['os'] = $os.Caption; $facts['ramTotalBytes'] = [long]$os.TotalVisibleMemorySize * 1024; $facts['ramFreeBytes'] = [long]$os.FreePhysicalMemory * 1024; $facts['lastBoot'] = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm') } catch { }
try { $facts['powerPlan'] = ((& powercfg /getactivescheme) -join ' ').Trim() } catch { }
try { $facts['longPathsEnabled'] = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction Stop).LongPathsEnabled -eq 1) } catch { }
try { $facts['gpuHardwareScheduling'] = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode -eq 2) } catch { }
try { $facts['gpus'] = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) } catch { }
try { $facts['startupEntries'] = @(Get-CimInstance Win32_StartupCommand | ForEach-Object { $_.Name }) } catch { }
$facts['isAdmin'] = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Folders already moved aside by an earlier cleanup and not yet emptied.
$pending = 0L
$indexFile = Join-Path $OutDir 'quarantine-index.json'
if ([System.IO.File]::Exists($indexFile)) {
    try { foreach ($q in @(([System.IO.File]::ReadAllText($indexFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json))) { if ($q.stored -and ([System.IO.Directory]::Exists($q.stored) -or [System.IO.File]::Exists($q.stored))) { $pending += [long]$q.bytes } } } catch { }
}

# ---------------------------------------------------------------- 11. ids and output
$final = New-Object 'System.Collections.Generic.List[object]'
$n = 0; foreach ($it in ($items | Where-Object { $_.level -eq 'green' } | Sort-Object sizeBytes -Descending)) { $n++; $it.id = "G$n"; $final.Add($it) }
$n = 0; foreach ($it in ($items | Where-Object { $_.level -eq 'yellow' } | Sort-Object sizeBytes -Descending)) { $n++; $it.id = "Y$n"; $final.Add($it) }
$sumGreen = 0L; $sumYellow = 0L
foreach ($it in $final) { if ($it.level -eq 'green') { $sumGreen += $it.sizeBytes } else { $sumYellow += $it.sizeBytes } }
$walk.seconds = [int]$watch.Elapsed.TotalSeconds

$scanId = $now.ToString('yyyyMMdd-HHmmss')
$report = [ordered]@{
    schema            = 1
    scanId            = $scanId
    generatedAt       = $now.ToString('yyyy-MM-dd HH:mm:ss')
    mode              = $(if ($Quick) { 'quick' } else { 'full' })
    outDir            = $OutDir
    systemDrive       = ([string]$env:SystemDrive).ToUpperInvariant()
    drives            = $drives
    totals            = [ordered]@{ greenBytes = $sumGreen; yellowBytes = $sumYellow; greenCount = @($final | Where-Object { $_.level -eq 'green' }).Count; yellowCount = @($final | Where-Object { $_.level -eq 'yellow' }).Count }
    items             = $final
    notTouched        = [ordered]@{ system = $system; personalApps = $notable; protectedFolders = $protectedSummary; activeProjects = $active; tempInUseBytes = $tempRecent; installersNotListed = [Math]::Max(0, $instAll.Count - 60) }
    spaceMap          = @($tree | Sort-Object sizeBytes -Descending | Select-Object -First 300)
    largestFiles      = $bigFiles
    identicalFilesInfoOnly = @($otherDups | Sort-Object sizeBytes -Descending | Select-Object -First 30)
    quarantinePendingBytes = $pending
    granted           = $G.Granted
    grantsRejected    = $G.Rejected
    droppedByGuard    = $dropped
    facts             = $facts
    walk              = $walk
}
$jsonPath = Join-Path $OutDir "scan-$scanId.json"
[System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))

function Format-PcSize { param([long]$b) if ($b -ge $GB) { return ('{0:N2} GB' -f ($b / $GB)) } else { return ('{0:N0} MB' -f ($b / $MB)) } }
Write-Output "PC checkup $scanId ($($report.mode)) - nothing was deleted or changed."
foreach ($d in $drives) { Write-Output ("  {0} free {1} of {2}" -f $d.name, (Format-PcSize $d.freeBytes), (Format-PcSize $d.sizeBytes)) }
Write-Output ("  GREEN  (regenerates by itself): {0} in {1} items" -f (Format-PcSize $sumGreen), $report.totals.greenCount)
Write-Output ("  YELLOW (needs the user's decision): {0} in {1} items" -f (Format-PcSize $sumYellow), $report.totals.yellowCount)
foreach ($it in ($final | Select-Object -First 400)) {
    Write-Output ("  {0,-4} {1,10}  {2,-15} {3}" -f $it.id, (Format-PcSize $it.sizeBytes), $it.category, $it.label)
}
if (-not $Quick) { Write-Output ("  walked {0:N0} files in {1:N0} folders, {2} unreadable, {3} s" -f $walk.files, $walk.folders, $walk.unreadable, $walk.seconds) }
# The visual report: a fixed template with this scan's numbers filled in. A failure here never fails the scan.
try {
    $ra = @{ Manifest = $jsonPath }
    if ($NoOpen) { $ra['NoOpen'] = $true }
    & (Join-Path $PSScriptRoot 'report.ps1') @ra
} catch { Write-Output ('HTML: failed - ' + $_.Exception.Message) }
Write-Output "REPORT: $jsonPath"
