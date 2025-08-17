[CmdletBinding()]
param(
  [string]$Repo = "microsoft-cloud-ucoe/meta-orchestrator",
  [string]$Org,
  [string]$Token,
  [switch]$OrgLevel
)

$ErrorActionPreference = 'Stop'

function Test-GhCli() {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) not found. Install from https://github.com/cli/cli and retry."
  }
}

Test-GhCli

try { gh auth status -h github.com 1>$null 2>$null } catch {
  Write-Warning "gh not authenticated. Run: gh auth login -s repo,admin:repo_hook,read:org,write:org -h github.com -p https -w"
  throw
}

$tokenValue = $Token
if ([string]::IsNullOrWhiteSpace($tokenValue)) { $tokenValue = $env:GH_ADMIN_TOKEN }
if ([string]::IsNullOrWhiteSpace($tokenValue)) {
  try {
    # As a convenience, fallback to the current gh OAuth token if available
    $tokenValue = (& gh auth token 2>$null)
  } catch { $tokenValue = $null }
}
if ([string]::IsNullOrWhiteSpace($tokenValue)) {
  Write-Host "No token provided via -Token, GH_ADMIN_TOKEN env var, or gh auth token."
  Write-Host "Please authenticate and/or create a PAT with scopes: repo, admin:repo_hook, read:org (or write:org) and re-run:"
  Write-Host "  gh auth login -s repo,admin:repo_hook,read:org -h github.com -p https -w"
  Write-Host "Then run: ./scripts/setup-secrets.ps1"
  exit 1
}

if ($OrgLevel) {
  if (-not $Org) { throw "-Org is required when -OrgLevel is specified." }
  Write-Host "Setting org secret GH_ADMIN_TOKEN in org '$Org'..."
  $tokenValue | gh secret set GH_ADMIN_TOKEN --org $Org --app actions --repos $Repo 1>$null
  Write-Host "Org secret GH_ADMIN_TOKEN set."
} else {
  Write-Host "Setting repo secret GH_ADMIN_TOKEN in $Repo..."
  $tokenValue | gh secret set GH_ADMIN_TOKEN -R $Repo 1>$null
  Write-Host "Repo secret GH_ADMIN_TOKEN set."
}

Write-Host "Done. The orchestrator workflow will use GH_ADMIN_TOKEN if present."
