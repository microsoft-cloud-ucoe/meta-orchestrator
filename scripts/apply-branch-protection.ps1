[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Org,
  [Parameter(Mandatory=$true)][string]$Repo,
  [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

# Acquire token from gh
$token = & gh auth token 2>$null
if (-not $token) { throw "GitHub token not available. Run: gh auth login" }

$json = @'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "CI",
      "CI / build-node",
      "CI / build-python",
      "CodeQL",
      "CodeQL / analyze"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": false,
    "require_review_thread_resolution": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
'@
$uri = "https://api.github.com/repos/$Org/$Repo/branches/$Branch/protection"
$headers = @{
  Authorization = "Bearer $token"
  Accept        = "application/vnd.github+json"
  'X-GitHub-Api-Version' = '2022-11-28'
}

try {
  Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $json -ContentType 'application/json' | Out-Null
} catch {
  # If lacking admin:repo_hook or proper permissions, GitHub returns 403. Don't fail the whole job.
  Write-Warning "Skipping branch protection for ${Org}/${Repo} (${Branch}): $_"
  return
}

# Enable required signed commits on the branch (separate endpoint)
try {
  $sigUri = "https://api.github.com/repos/$Org/$Repo/branches/$Branch/protection/required_signatures"
  Invoke-RestMethod -Method Put -Uri $sigUri -Headers $headers | Out-Null
} catch {
  Write-Warning "Could not enable required signatures for ${Org}/${Repo} (${Branch}): $_"
}

Write-Host "Applied branch protection to ${Org}/${Repo} (${Branch})"
