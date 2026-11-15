# common.ps1 - protection rules and file helpers shared by scan.ps1 and clean.ps1.
# Keep every .ps1 in this folder ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI,
# so non-ASCII text would be garbled. Names that need Chinese live in protected-names.txt (UTF-8).

$script:PcGuard = $null
$script:PcCmp = [System.StringComparison]::OrdinalIgnoreCase
$script:PcIgnoreCase = [System.StringComparer]::OrdinalIgnoreCase
$script:PcInstallerExt = @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.iso')
$script:PcQuarantineName = '_pc-checkup-quarantine'

function Get-PcNorm {
    # Absolute path without a trailing backslash, or $null when the input is not a local absolute path.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"')
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return $null }
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function Test-PcUnder {
    # True when Path equals Base or lies inside it.
    param([string]$Path, [string]$Base)
    if (-not $Path -or -not $Base) { return $false }
    if ($Path.Equals($Base, $script:PcCmp)) { return $true }
    $b = $Base
    if (-not $b.EndsWith('\')) { $b = $b + '\' }
    return $Path.StartsWith($b, $script:PcCmp)
}

function Split-PcList {
    # "-File" passes an array argument as one string, so lists are separated by ';' or '|'.
    param([string[]]$Value)
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($v in $Value) {
        if (-not $v) { continue }
        foreach ($part in $v.Split(@(';', '|'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $t = $part.Trim()
            if ($t) { $out.Add($t) }
        }
    }
    return , $out.ToArray()
}

function Get-PcInstalledLocations {
    # Folders that installed programs registered with Windows. They belong to that software, not to us.
    $out = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $keys) {
        $entries = @()
        try { $entries = @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue) } catch { }
        foreach ($e in $entries) {
            $loc = $null
            try { $loc = $e.InstallLocation } catch { }
            $n = Get-PcNorm $loc
            if ($n -and $n.Length -gt 3 -and [System.IO.Directory]::Exists($n)) { [void]$out.Add($n) }
        }
    }
    return $out
}

function Initialize-PcGuard {
    # Granted: folders the user explicitly named as their own project folders. A grant lifts the
    #          "personal" and "installed-app" rules for that folder only; system, game, chat and
    #          credential rules always win.
    # Protect: extra folders the user wants left alone.
    param([string[]]$Granted = @(), [string[]]$Protect = @(), [string]$NamesFile)
    if (-not $NamesFile) { $NamesFile = Join-Path $PSScriptRoot 'protected-names.txt' }

    $userHome = Get-PcNorm $env:USERPROFILE
    $local = Get-PcNorm $env:LOCALAPPDATA
    $roam = Get-PcNorm $env:APPDATA
    $low = Join-Path (Split-Path $local -Parent) 'LocalLow'
    $sys = $env:SystemDrive.TrimEnd('\')

    $zones = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    $add = {
        param($p, $reason)
        $n = Get-PcNorm $p
        if ($n -and $n.Length -gt 3 -and $seen.Add($n)) { $zones.Add([pscustomobject]@{ Path = $n; Reason = $reason }) }
    }

    foreach ($p in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData,
            "$sys\Recovery", "$sys\Windows.old", "$sys\PerfLogs", "$sys\MSOCache", "$sys\Config.Msi",
            "$sys\`$WinREAgent", "$sys\`$Windows.~BT", "$sys\`$Windows.~WS", "$sys\`$SysReset", "$sys\Documents and Settings",
            "$local\Microsoft", "$roam\Microsoft", "$low\Microsoft", "$local\Packages")) {
        & $add $p 'system'
    }
    # Programs and command-line tools installed per user (global npm packages, uv/pipx tools, Python, version managers).
    foreach ($p in @("$local\Programs", "$roam\npm", "$roam\nvm", "$roam\fnm", "$roam\uv", "$roam\Python", "$local\pipx",
            "$local\Python", "$local\pnpm", "$local\Volta", "$local\bun")) {
        & $add $p 'installed-app'
    }

    foreach ($sf in 'Desktop', 'MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic', 'Favorites',
            'CommonDesktopDirectory', 'CommonDocuments', 'CommonPictures', 'CommonMusic', 'CommonVideos') {
        try { & $add ([Environment]::GetFolderPath($sf)) 'personal' } catch { }
    }
    $downloads = $null
    try {
        $raw = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($raw) { $downloads = Get-PcNorm ([Environment]::ExpandEnvironmentVariables($raw)) }
    } catch { }
    if (-not $downloads) { $downloads = "$userHome\Downloads" }
    & $add $downloads 'personal'
    foreach ($n in 'Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads', 'Favorites', 'Contacts', 'Links',
            'Searches', '3D Objects', 'Saved Games', 'OneDrive') {
        & $add (Join-Path $userHome $n) 'personal'
    }
    foreach ($p in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, $env:PUBLIC)) { & $add $p 'personal' }

    foreach ($p in (Split-PcList $Protect)) { & $add $p 'user-protected' }
    foreach ($p in (Get-PcInstalledLocations)) {
        if (Test-PcUnder $userHome $p) { continue }   # a location that swallows the whole profile is a bad registry entry
        & $add $p 'installed-app'
    }

    # Segment names: a folder with one of these names is protected wherever it sits.
    $names = New-Object 'System.Collections.Generic.Dictionary[string,string]' ($script:PcIgnoreCase)
    $patterns = New-Object 'System.Collections.Generic.List[object]'
    $names['$Recycle.Bin'] = 'system'
    $names['System Volume Information'] = 'system'
    $names['WindowsApps'] = 'system'
    foreach ($f in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'DumpStack.log.tmp') { $names[$f] = 'system' }
    $names['Program Files'] = 'installed-app'
    $names['Program Files (x86)'] = 'installed-app'
    $names[$script:PcQuarantineName] = 'quarantine'
    if ([System.IO.File]::Exists($NamesFile)) {
        $section = 'user-protected'
        foreach ($line in [System.IO.File]::ReadAllLines($NamesFile, [System.Text.Encoding]::UTF8)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($t -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
            if ($t.IndexOfAny(@('*', '?')) -ge 0) {
                $patterns.Add([pscustomobject]@{ Pattern = (New-Object System.Management.Automation.WildcardPattern ($t, 'IgnoreCase')); Reason = $section })
            } else { $names[$t] = $section }
        }
    }

    $homeBases = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in "$userHome\AppData\Local", "$userHome\AppData\Roaming", "$userHome\AppData\LocalLow") {
        $homeBases.Add([pscustomobject]@{ Path = $b; Self = $false })
    }
    foreach ($b in '.cache', '.ollama\models', '.lmstudio\models', '.u2net', '.rembg', '.insightface', '.paddleocr',
            '.paddlex', '.EasyOCR', '.keras', '.deepface', '.conda\pkgs') {
        $homeBases.Add([pscustomobject]@{ Path = (Join-Path $userHome $b); Self = ($b -ne '.cache') })
    }

    $cacheNames = New-Object 'System.Collections.Generic.HashSet[string]' ($script:PcIgnoreCase)
    foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'CacheStorage', 'ScriptCache', 'DawnCache', 'DawnGraphiteCache',
            'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'cache2') { [void]$cacheNames.Add($c) }

    $script:PcGuard = [pscustomobject]@{
        Home         = $userHome
        ProfilesRoot = (Split-Path $userHome -Parent)
        Local        = $local
        Roaming      = $roam
        Downloads    = $downloads
        Zones        = $zones
        Exceptions   = @("$local\Microsoft\Edge\User Data", "$local\Microsoft\Windows\INetCache", "$local\Microsoft\Windows\WER")
        Names        = $names
        Patterns     = $patterns
        HomeBases    = $homeBases
        HomeTop      = @('AppData', '.cache', '.ollama', '.lmstudio', '.u2net', '.rembg', '.insightface', '.paddleocr',
                         '.paddlex', '.EasyOCR', '.keras', '.deepface', '.conda')
        CacheNames   = $cacheNames
        Granted      = @()
        Rejected     = @()
    }

    # A grant must sit strictly inside or outside the protected zones. It can never be a drive, the
    # profile, a whole protected zone, a parent of one, or anything system/game/chat/credential.
    $ok = New-Object 'System.Collections.Generic.List[string]'
    $bad = New-Object 'System.Collections.Generic.List[object]'
    foreach ($raw in (Split-PcList $Granted)) {
        $n = Get-PcNorm $raw
        $why = $null
        if (-not $n) { $why = 'not-a-local-path' }
        elseif ($n.Length -le 3) { $why = 'drive-root' }
        elseif (-not [System.IO.Directory]::Exists($n)) { $why = 'not-found' }
        elseif (Test-PcUnder $userHome $n) { $why = 'contains-profile' }
        else {
            foreach ($z in $zones) {
                if (Test-PcUnder $z.Path $n) { $why = 'contains-' + $z.Reason; break }
                if ((Test-PcUnder $n $z.Path) -and $z.Reason -notin @('personal', 'installed-app')) { $why = $z.Reason; break }
            }
            if (-not $why) { $why = Get-PcNameReason $n }
        }
        if ($why) { $bad.Add([pscustomobject]@{ path = $raw; reason = $why }) } else { $ok.Add($n) }
    }
    $script:PcGuard.Granted = $ok.ToArray()
    $script:PcGuard.Rejected = $bad.ToArray()
    return $script:PcGuard
}

function Get-PcNameReason {
    # Reason when any folder name on the path is on the protected-names list, else $null.
    param([string]$NormPath)
    $g = $script:PcGuard
    $segs = $NormPath.Split('\')
    for ($i = 1; $i -lt $segs.Length; $i++) {
        $s = $segs[$i]
        $r = $null
        if ($g.Names.TryGetValue($s, [ref]$r)) { return $r }
        foreach ($p in $g.Patterns) { if ($p.Pattern.IsMatch($s)) { return $p.Reason } }
    }
    return $null
}

function Test-PcProtected {
    # Returns the reason a path must not be deleted or moved, or $null when it may be.
    # This is the backstop: scan.ps1 uses it before listing an item, clean.ps1 uses it again before acting.
    param([string]$Path)
    $g = $script:PcGuard
    if (-not $g) { throw 'Initialize-PcGuard has not been called' }
    $p = Get-PcNorm $Path
    if (-not $p) { return 'not-a-local-path' }
    if ($p.Length -le 3) { return 'drive-root' }

    $granted = $false
    foreach ($r in $g.Granted) { if (Test-PcUnder $p $r) { $granted = $true; break } }
    $excepted = $false
    foreach ($x in $g.Exceptions) { if (Test-PcUnder $p $x) { $excepted = $true; break } }

    foreach ($z in $g.Zones) {
        if (Test-PcUnder $p $z.Path) {
            if ($granted -and $z.Reason -in @('personal', 'installed-app')) { continue }
            if ($excepted -and $z.Reason -eq 'system') { continue }
            return $z.Reason
        }
        if (Test-PcUnder $z.Path $p) { return 'contains-' + $z.Reason }
    }

    $nameReason = Get-PcNameReason $p
    if ($nameReason) { return $nameReason }

    if ((Test-PcUnder $p $g.ProfilesRoot) -and -not (Test-PcUnder $p $g.Home)) { return 'other-user' }
    if ((Test-PcUnder $p $g.Home) -and -not $granted) {
        $allowed = $false
        foreach ($b in $g.HomeBases) {
            if (-not (Test-PcUnder $p $b.Path)) { continue }
            if ($b.Self -or -not $p.Equals($b.Path, $script:PcCmp)) { $allowed = $true; break }
        }
        if (-not $allowed) { return 'personal' }
    }

    # Browser and Chromium-app profiles hold logins, history and drafts. Only their cache folders are fair game.
    $segs = $p.Split('\')
    $ud = [Array]::FindIndex($segs, [Predicate[string]] { param($s) $s -eq 'User Data' })
    $ff = [Array]::FindIndex($segs, [Predicate[string]] { param($s) $s -eq 'Profiles' })
    $start = -1
    if ($ud -ge 0) { $start = $ud } elseif ($ff -ge 0 -and ($segs -contains 'Firefox')) { $start = $ff }
    if ($start -ge 0) {
        $isCache = $false
        for ($i = $start + 1; $i -lt $segs.Length; $i++) { if ($g.CacheNames.Contains($segs[$i])) { $isCache = $true; break } }
        if (-not $isCache) { return 'app-profile' }
    }
    return $null
}

function Test-PcInstallerFile {
    # The one exception inside Downloads: an old installer file. Returns $null when the file qualifies.
    param([string]$Path)
    $g = $script:PcGuard
    $p = Get-PcNorm $Path
    if (-not $p) { return 'not-a-local-path' }
    if (-not (Test-PcUnder $p $g.Downloads) -or $p.Equals($g.Downloads, $script:PcCmp)) { return 'not-in-downloads' }
    if (-not [System.IO.File]::Exists($p)) { return 'not-a-file' }
    if ($script:PcInstallerExt -notcontains [System.IO.Path]::GetExtension($p).ToLowerInvariant()) { return 'not-an-installer' }
    return (Get-PcNameReason $p)
}

function Test-PcLink {
    # True for junctions, symlinks and other reparse points. Links are never followed or emptied.
    param([string]$Path)
    try { return [bool]([int][System.IO.File]::GetAttributes('\\?\' + $Path) -band 0x400) } catch { return $false }
}

function Measure-PcDir {
    # Size of a folder tree from file metadata only. Links are not followed; cloud placeholders are not counted.
    param([string]$Path)
    $size = 0L; $files = 0; $newest = 0L; $bad = 0
    if ($Path -and [System.IO.Directory]::Exists($Path)) {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Path.TrimEnd('\'))
        while ($stack.Count -gt 0) {
            $p = $stack.Pop()
            try {
                $di = New-Object System.IO.DirectoryInfo ('\\?\' + $p + '\')
                foreach ($e in $di.EnumerateFileSystemInfos()) {
                    $a = [int]$e.Attributes
                    if ($a -band 0x400) { continue }
                    if ($a -band 0x10) { $stack.Push($p + '\' + $e.Name); continue }
                    if ($a -band 0x401000) { continue }
                    $size += $e.Length; $files++
                    $t = $e.LastWriteTimeUtc.Ticks
                    if ($t -gt $newest) { $newest = $t }
                }
            } catch { $bad++ }
        }
    }
    return [pscustomobject]@{ Size = $size; Files = $files; Newest = $newest; Unreadable = $bad }
}

function ConvertTo-PcDay {
    param([long]$Ticks)
    if ($Ticks -le 0) { return $null }
    return ([DateTime]::new($Ticks, [DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd')
}

function Get-PcDrives {
    $out = @()
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
        $out += [pscustomobject]@{ name = $d.DeviceID; sizeBytes = [long]$d.Size; freeBytes = [long]$d.FreeSpace }
    }
    return , $out
}

function Get-PcTempCutoff {
    # Temp files written since the last boot, or within the last day, may belong to a running program.
    $boot = (Get-Date).AddDays(-1)
    try { $b = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; if ($b -lt $boot) { $boot = $b } } catch { }
    return $boot.ToUniversalTime().Ticks
}

$script:PcRmFreed = 0L
$script:PcRmKept = 0

function Remove-PcTreeInner {
    param([string]$Dir, [bool]$KeepThis)
    $empty = $true
    $entries = $null
    try { $entries = (New-Object System.IO.DirectoryInfo ('\\?\' + $Dir + '\')).GetFileSystemInfos() }
    catch { $script:PcRmKept++; return $false }
    foreach ($e in $entries) {
        $child = $Dir + '\' + $e.Name
        $lp = '\\?\' + $child
        $a = [int]$e.Attributes
        if ($a -band 0x400) {
            # Unlink only. The folder or file the link points at is left untouched.
            try { if ($a -band 0x10) { [System.IO.Directory]::Delete($lp, $false) } else { [System.IO.File]::Delete($lp) } }
            catch { $script:PcRmKept++; $empty = $false }
            continue
        }
        if ($a -band 0x10) {
            if (-not (Remove-PcTreeInner -Dir $child -KeepThis $false)) { $empty = $false }
            continue
        }
        try {
            $len = $e.Length
            if ($a -band 0x1) { [System.IO.File]::SetAttributes($lp, [System.IO.FileAttributes]::Normal) }
            [System.IO.File]::Delete($lp)
            $script:PcRmFreed += $len
        } catch { $script:PcRmKept++; $empty = $false }
    }
    if ($KeepThis) { return $true }
    if (-not $empty) { return $false }
    try { [System.IO.Directory]::Delete('\\?\' + $Dir, $false); return $true } catch { $script:PcRmKept++; return $false }
}

function Remove-PcTree {
    # Permanently deletes a file, or a folder tree (or only its contents with -KeepRoot).
    # Files that are locked or in use are left in place and counted in Kept.
    param([string]$Path, [switch]$KeepRoot)
    $script:PcRmFreed = 0L; $script:PcRmKept = 0
    $lp = '\\?\' + $Path
    if ([System.IO.File]::Exists($lp)) {
        try {
            $fi = New-Object System.IO.FileInfo $lp
            $len = $fi.Length
            if ([int]$fi.Attributes -band 0x1) { [System.IO.File]::SetAttributes($lp, [System.IO.FileAttributes]::Normal) }
            [System.IO.File]::Delete($lp)
            $script:PcRmFreed = $len
        } catch { $script:PcRmKept = 1 }
    } elseif ([System.IO.Directory]::Exists($lp)) {
        [void](Remove-PcTreeInner -Dir $Path -KeepThis ([bool]$KeepRoot))
    }
    return [pscustomobject]@{ Freed = $script:PcRmFreed; Kept = $script:PcRmKept }
}
