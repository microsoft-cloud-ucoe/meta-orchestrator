[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Org,
  [int]$Limit = 200,
  [string]$ManifestPath = "$PSScriptRoot/../repos.json"
)

$ErrorActionPreference = "Stop"

$raw = gh repo list $Org --json name,url,defaultBranchRef -L $Limit | ConvertFrom-Json

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

($manifest | ConvertTo-Json -Depth 5) | Set-Content -Path $ManifestPath -NoNewline
Write-Host "Updated manifest with $($manifest.repositories.Count) repositories for $Org"
