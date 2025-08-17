[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json",
  [switch]$Prune
)

$ErrorActionPreference = "Stop"

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$baseDir = Join-Path (Split-Path $ManifestPath -Parent) $manifest.baseDir

foreach ($r in $manifest.repositories) {
  $target = Join-Path $baseDir $r.path
  if (!(Test-Path (Join-Path $target ".git"))) {
    Write-Host "Skipping (not cloned): $($r.name)"
    continue
  }
  Push-Location $target
  try {
    if ($Prune) { git fetch --all --prune | Out-Null } else { git fetch --all | Out-Null }
    git switch $r.branch
    git pull --ff-only
  } finally {
    Pop-Location
  }
}
Write-Host "Update complete."
