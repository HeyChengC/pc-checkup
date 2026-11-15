#requires -Version 5.1
<#
report.ps1 - turns a scan report into the visual checkup page.

It reads <OutDir>\scan-<id>.json, fills the numbers into the fixed template
assets\report-template.html and writes <OutDir>\report-<id>.html next to the JSON.
Nothing else is read, written or changed. The page works offline and loads nothing from the network.

scan.ps1 calls this by itself. Run it by hand only to rebuild the page from an existing report:
  report.ps1 -Manifest "<path to scan-....json>" [-NoOpen]

The template is never edited to "generate" a report; all numbers come from the JSON.
Keep this file ASCII-only (see common.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [string]$Template,
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
if (-not $Template) { $Template = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\report-template.html' }
if (-not [System.IO.File]::Exists($Manifest)) { throw "report not found: $Manifest" }
if (-not [System.IO.File]::Exists($Template)) { throw "template not found: $Template" }

$r = [System.IO.File]::ReadAllText($Manifest, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

# Only what the page shows goes into it: one path per item (for the drive letter), no file lists, no machine facts
# other than memory. The full data stays in the JSON.
$items = New-Object 'System.Collections.Generic.List[object]'
foreach ($it in @($r.items)) {
    if ($null -eq $it) { continue }
    $first = @($it.paths)[0]
    $extra = [ordered]@{}
    if ($it.extra) {
        if ($it.extra.byDrive) { $extra['byDrive'] = $it.extra.byDrive }
        if ($it.extra.frames) { $extra['frames'] = $it.extra.frames }
    }
    $items.Add([ordered]@{
            id = $it.id; level = $it.level; group = $it.group; category = $it.category; label = $it.label
            paths = @([string]$first); sizeBytes = [long]$it.sizeBytes; files = $it.files; newest = $it.newest
            method = $it.method; extra = $extra
        })
}
$prot = New-Object 'System.Collections.Generic.List[object]'
foreach ($p in @($r.notTouched.protectedFolders)) {
    if ($null -eq $p) { continue }
    $prot.Add([ordered]@{ reason = $p.reason; sizeBytes = [long]$p.sizeBytes; byDrive = $p.byDrive })
}
$apps = New-Object 'System.Collections.Generic.List[object]'
foreach ($a in @($r.notTouched.personalApps)) {
    if ($null -eq $a) { continue }
    $apps.Add([ordered]@{ key = $a.key; sizeBytes = [long]$a.sizeBytes })
}
$sysDrive = $r.systemDrive
if (-not $sysDrive) { $sysDrive = ([string]$env:SystemDrive).ToUpperInvariant() }
$slim = [ordered]@{
    schema      = $r.schema
    scanId      = $r.scanId
    generatedAt = $r.generatedAt
    mode        = $r.mode
    systemDrive = $sysDrive
    drives      = @($r.drives)
    items       = $items.ToArray()
    notTouched  = [ordered]@{ protectedFolders = $prot.ToArray(); personalApps = $apps.ToArray(); tempInUseBytes = $r.notTouched.tempInUseBytes }
    quarantinePendingBytes = $r.quarantinePendingBytes
    facts       = [ordered]@{ ramTotalBytes = $r.facts.ramTotalBytes; ramFreeBytes = $r.facts.ramFreeBytes }
}
# Windows PowerShell writes < > & ' as \u00XX, so the data cannot close the <script> block it sits in.
$json = ($slim | ConvertTo-Json -Depth 6 -Compress).Replace('</', '<\/')

$marker = '/*__REPORT_JSON__*/null'
$html = [System.IO.File]::ReadAllText($Template, [System.Text.Encoding]::UTF8)
if (-not $html.Contains($marker)) { throw 'the template has no data slot' }
$html = $html.Replace($marker, $json)

$out = Join-Path (Split-Path $Manifest -Parent) ("report-$($r.scanId).html")
[System.IO.File]::WriteAllText($out, $html, $utf8)
Write-Output "HTML: $out"
if (-not $NoOpen) {
    try { Start-Process -FilePath $out; Write-Output 'HTML-OPENED: yes' }
    catch { Write-Output 'HTML-OPENED: no (open the file above by hand)' }
}
