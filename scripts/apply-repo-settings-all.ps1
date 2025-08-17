[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json",
  [switch]$Parallel,
  [int]$Concurrency = 8
)

$ErrorActionPreference = "Stop"

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

function Set-RepoSettings {
  param([string]$Org, [string]$Repo)
  # Enable issues, wiki off, merge strategies, delete branch on merge, auto-merge, vulnerability alerts
  try { gh repo edit "$Org/$Repo" --enable-issues --enable-projects=false --enable-wiki=false --allow-update-branch=true --delete-branch-on-merge=true --enable-auto-merge=true | Out-Null } catch {}
  try { gh repo edit "$Org/$Repo" --visibility public | Out-Null } catch {}
  try { gh api -X PUT repos/$Org/$Repo/vulnerability-alerts -H "Accept: application/vnd.github+json" | Out-Null } catch {}
  # Enable Advanced Security, Secret Scanning, Push Protection, and Dependabot security updates
  $payload = @{
    security_and_analysis = @{
      advanced_security = @{ status = 'enabled' }
      secret_scanning = @{ status = 'enabled' }
      secret_scanning_push_protection = @{ status = 'enabled' }
      dependabot_security_updates = @{ status = 'enabled' }
    }
  } | ConvertTo-Json -Depth 5
  try { $payload | gh api -X PATCH repos/$Org/$Repo -H "Accept: application/vnd.github+json" --input - 1>$null 2>$null } catch {}
}

function Get-GitHubRef { param($url)
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
    $r = $_; $ErrorActionPreference = 'Stop'
    function Get-GitHubRef { param($url)
      if ($url -match 'github.com[:/](?<org>[^/]+)/(?<repo>[^/]+)') {
        return [pscustomobject]@{ Org = $Matches['org']; Repo = $Matches['repo'] }
      }
      throw "Cannot parse org/repo from URL: $url"
    }
    $ref = Get-GitHubRef $r.url
    try {
      gh repo view "$($ref.Org)/$($ref.Repo)" 1>$null 2>$null
      gh repo edit "$($ref.Org)/$($ref.Repo)" --enable-issues --enable-projects=false --enable-wiki=false --allow-update-branch=true --delete-branch-on-merge=true --enable-auto-merge=true 1>$null 2>$null
      gh api -X PUT repos/$($ref.Org)/$($ref.Repo)/vulnerability-alerts -H "Accept: application/vnd.github+json" 1>$null 2>$null
      $payload = @{ security_and_analysis = @{ advanced_security = @{ status = 'enabled' }; secret_scanning = @{ status = 'enabled' }; secret_scanning_push_protection = @{ status = 'enabled' }; dependabot_security_updates = @{ status = 'enabled' } } } | ConvertTo-Json -Depth 5
      $payload | gh api -X PATCH repos/$($ref.Org)/$($ref.Repo) -H "Accept: application/vnd.github+json" --input - 1>$null 2>$null
      Write-Host "Settings applied to $($ref.Org)/$($ref.Repo)"
    } catch {
      Write-Warning "Failed to apply settings to $($ref.Org)/$($ref.Repo): $_"
    }
  } -ThrottleLimit $throttle
} else {
  foreach ($r in $manifest.repositories) {
    $ref = Get-GitHubRef $r.url
    Set-RepoSettings -Org $ref.Org -Repo $ref.Repo
    Write-Host "Settings applied to $($ref.Org)/$($ref.Repo)"
  }
}
