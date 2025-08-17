[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$Command,
  [string]$ManifestPath = "$PSScriptRoot/../repos.json"
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
  Write-Host "[${($r.name)}] > $Command"
  Push-Location $target
  try {
    Invoke-Expression $Command
  } finally {
    Pop-Location
  }
}
