[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json"
)

$ErrorActionPreference = "Stop"

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$baseDir = Join-Path (Split-Path $ManifestPath -Parent) $manifest.baseDir

$rows = @()
foreach ($r in $manifest.repositories) {
  $target = Join-Path $baseDir $r.path
  if (!(Test-Path (Join-Path $target ".git"))) {
    $rows += [pscustomobject]@{ Name=$r.name; Path=$target; Branch="-"; Ahead=0; Behind=0; Changes="not cloned" }
    continue
  }
  Push-Location $target
  try {
    $branch = (git rev-parse --abbrev-ref HEAD)
    $changes = (git status --porcelain).Length
  $ab = (git rev-list --left-right --count '@{u}...HEAD' 2>$null) -split '\s+'
    if ($ab.Count -lt 2) { $ab = @("0","0") }
    $rows += [pscustomobject]@{
      Name=$r.name; Path=$target; Branch=$branch;
      Ahead=[int]$ab[1]; Behind=[int]$ab[0]; Changes=$changes
    }
  } finally {
    Pop-Location
  }
}
$rows | Sort-Object Name | Format-Table -AutoSize
