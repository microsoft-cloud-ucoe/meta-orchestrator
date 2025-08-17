[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ManifestPath)) {
  throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$baseDir = Join-Path (Split-Path $ManifestPath -Parent) $manifest.baseDir
New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

foreach ($r in $manifest.repositories) {
  $target = Join-Path $baseDir $r.path
  if (Test-Path (Join-Path $target ".git")) {
    Write-Host "Already cloned: $($r.name) -> $target"
    continue
  }
  Write-Host "Cloning $($r.url) (branch $($r.branch)) -> $target"
  git clone --branch $r.branch $r.url $target
}
Write-Host "Bootstrap complete."
