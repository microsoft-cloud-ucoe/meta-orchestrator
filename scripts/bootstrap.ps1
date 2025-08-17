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
  # If the target directory exists but isn't a git repo, back it up before cloning
  if (Test-Path $target -and -not (Test-Path (Join-Path $target '.git'))) {
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backup = "$target.bak-$timestamp"
    Write-Host "Backing up existing non-git folder: $target -> $backup"
    Move-Item -Force -Path $target -Destination $backup
  }

  $token = $env:GH_TOKEN
  if (-not $token -and $env:GITHUB_TOKEN) { $token = $env:GITHUB_TOKEN }
  Write-Host "Cloning $($r.url) (branch $($r.branch)) -> $target"

  try {
    if ($token) {
      # Prefer gh if available since it handles auth cleanly
      if (Get-Command gh -ErrorAction SilentlyContinue) {
        # Use gh repo clone owner/repo <path> -- -b <branch>
        # Convert full URL to owner/repo
        $ownerRepo = $r.url -replace '^https?://github.com/', ''
        gh repo clone $ownerRepo $target -- -b $r.branch
      } else {
        # Fallback to git with token in URL ( avoids interactive auth )
        $authUrl = $r.url -replace '^https://', "https://x-access-token:$token@"
        git clone --branch $r.branch $authUrl $target
      }
    } else {
      # No token available; attempt unauthenticated clone (works for public repos)
      git clone --branch $r.branch $r.url $target
    }
  } catch {
    Write-Error "Failed to clone $($r.url): $_"
    throw
  }
}
Write-Host "Bootstrap complete."
