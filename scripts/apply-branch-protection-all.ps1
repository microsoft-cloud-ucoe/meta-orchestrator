[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json",
  [switch]$Parallel,
  [int]$Concurrency = 4
)

$ErrorActionPreference = "Stop"

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
function Get-GitHubRef {
  param($url)
  if ($url -match 'github.com[:/](?<org>[^/]+)/(?<repo>[^/]+)') {
    return [pscustomobject]@{ Org = $Matches['org']; Repo = $Matches['repo'] }
  }
  throw "Cannot parse org/repo from URL: $url"
}

if ($Parallel) {
  $auto = [Math]::Max(8, [Environment]::ProcessorCount * 2)
  $throttle = if ($PSBoundParameters.ContainsKey('Concurrency')) { $Concurrency } else { $auto }
  Write-Host "Parallel execution enabled. Throttle: $throttle (CPU: $([Environment]::ProcessorCount))"
  $manifest.repositories | ForEach-Object -Parallel {
    $r = $_
    $scriptRoot = $using:PSScriptRoot
    function Get-GitHubRef {
      param($url)
      if ($url -match 'github.com[:/](?<org>[^/]+)/(?<repo>[^/]+)') {
        return [pscustomobject]@{ Org = $Matches['org']; Repo = $Matches['repo'] }
      }
      throw "Cannot parse org/repo from URL: $url"
    }
    $ref = Get-GitHubRef $r.url
    if ($ref.Repo -eq '.github') {
      Write-Host "Skipping branch protection for special repository $($ref.Org)/$($ref.Repo)"
      return
    }
    & "$scriptRoot/apply-branch-protection.ps1" -Org $ref.Org -Repo $ref.Repo -Branch $r.branch
  } -ThrottleLimit $throttle
} else {
  foreach ($r in $manifest.repositories) {
    $ref = Get-GitHubRef $r.url
    if ($ref.Repo -eq '.github') { Write-Host "Skipping branch protection for special repository $($ref.Org)/$($ref.Repo)"; continue }
    & "$PSScriptRoot/apply-branch-protection.ps1" -Org $ref.Org -Repo $ref.Repo -Branch $r.branch
  }
}
