[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Org,
  [int]$Limit = 200,
  [string]$ManifestPath = "$PSScriptRoot/../repos.json"
)

$ErrorActionPreference = "Stop"

try {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) not found in PATH"
  }
  gh auth status -h github.com | Out-Null
} catch {
  Write-Error "gh authentication check failed: $_"
  throw
}

try {
  $raw = gh repo list $Org --json name,url,defaultBranchRef -L $Limit | ConvertFrom-Json
} catch {
  Write-Error "Failed to list repos for $Org via gh: $_"
  throw
}

$manifest = @{
  baseDir = 'repos'
  repositories = @()
}

foreach ($r in $raw) {
  $manifest.repositories += @{
    name = $r.name
    url = $r.url
    branch = $r.defaultBranchRef.name
    path = $r.name
  }
}

try {
  $json = ($manifest | ConvertTo-Json -Depth 5)
  $tmp = "$ManifestPath.tmp"
  $json | Set-Content -Path $tmp -NoNewline
  Move-Item -Force -Path $tmp -Destination $ManifestPath
  Write-Host "Updated manifest with $($manifest.repositories.Count) repositories for $Org"
} catch {
  Write-Error "Failed to write manifest to ${ManifestPath}: $_"
  throw
}
