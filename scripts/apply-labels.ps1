[CmdletBinding()]
param(
  [string]$Org,
  [string]$Repo
)

$ErrorActionPreference = "Stop"

# Pre-flight: ensure repo is accessible and supports issues/labels
try {
  $repoInfo = gh api "repos/$Org/$Repo" -H "Accept: application/vnd.github+json" | ConvertFrom-Json
} catch {
  Write-Warning "Skipping $Org/$Repo: unable to query repository ($_)"
  return
}

if (-not $repoInfo.has_issues) {
  Write-Host "Skipping $Org/$Repo: issues are disabled, labels not applicable."
  return
}

$labels = @(
  @{ name = "bug"; color = "d73a4a"; description = "Something isn't working" },
  @{ name = "enhancement"; color = "a2eeef"; description = "New feature or request" },
  @{ name = "chore"; color = "cfd3d7"; description = "Build/infra/maintenance" },
  @{ name = "standards"; color = "5319e7"; description = "Org standards change" }
)

foreach ($l in $labels) {
  $name = $l.name
  $color = $l.color
  $desc = $l.description
  try {
    # Try create first
    & gh label create "$name" --color "$color" --description "$desc" --repo "$Org/$Repo" 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
      # If create failed (likely exists), try edit
      & gh label edit "$name" --color "$color" --description "$desc" --repo "$Org/$Repo" 1>$null 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to ensure label '$name' in $Org/$Repo (exit $LASTEXITCODE). Skipping."
      } else {
        Write-Host "Updated label '$name' in $Org/$Repo"
      }
    } else {
      Write-Host "Created label '$name' in $Org/$Repo"
    }
  } catch {
    # Do not fail the whole job on label errors; log and continue
    Write-Warning "Error ensuring label '$name' in $Org/$Repo: $_"
  }
}
