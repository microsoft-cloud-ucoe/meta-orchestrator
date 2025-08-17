[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Org,
  [Parameter(Mandatory=$true)][string]$Repo,
  [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

# Acquire token: prefer a high-privilege token if provided
$token = $env:GH_ADMIN_TOKEN
if (-not $token -or [string]::IsNullOrWhiteSpace($token)) {
  $token = & gh auth token 2>$null
}
if (-not $token) { throw "GitHub token not available. Provide GH_ADMIN_TOKEN or run: gh auth login" }

# Discover desired status check contexts based on active workflows
function Get-DesiredStatusContexts {
  param(
    [string]$org,
    [string]$repo,
    [string]$branch
  )
  $contexts = New-Object System.Collections.Generic.List[string]
  try {
    $wfs = gh api repos/$org/$repo/actions/workflows -H "Accept: application/vnd.github+json" 2>$null | ConvertFrom-Json
    $names = @()
    if ($wfs -and $wfs.workflows) { $names = $wfs.workflows.name }
    # Our standards name workflows "CI" and "CodeQL"
    if ($names -contains 'CI') {
      $contexts.Add('CI / build-node')
      $contexts.Add('CI / build-python')
    }
    if ($names -contains 'CodeQL') {
      # Determine the actual job id used by the CodeQL workflow (commonly 'analyze' or 'codeql')
      try {
        $codeqlWfs = @($wfs.workflows | Where-Object { $_.name -eq 'CodeQL' })
        if ($codeqlWfs.Count -gt 0) {
          foreach ($wf in $codeqlWfs) {
            if (-not $wf.path) { continue }
            $content = gh api repos/$org/$repo/contents/$($wf.path)?ref=$branch -H "Accept: application/vnd.github+json" 2>$null | ConvertFrom-Json
            if ($null -ne $content -and $content.content) {
              $yaml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($content.content))
              if ($yaml -match "(?ms)^\s*jobs:\s*.*?^\s{2,}analyze:\s") {
                $contexts.Add('CodeQL / analyze')
              } elseif ($yaml -match "(?ms)^\s*jobs:\s*.*?^\s{2,}codeql:\s") {
                $contexts.Add('CodeQL / codeql')
              } else {
                # Fallback if unknown job id
                $contexts.Add('CodeQL / codeql')
              }
            } else {
              $contexts.Add('CodeQL / codeql')
            }
          }
        } else {
          $contexts.Add('CodeQL / codeql')
        }
      } catch {
        $contexts.Add('CodeQL / codeql')
      }
    }
  } catch {
    Write-Warning "Could not enumerate workflows for ${org}/${repo}; using default required contexts. $_"
    $contexts.Clear()
    $contexts.Add('CI / build-node')
    $contexts.Add('CI / build-python')
    $contexts.Add('CodeQL / codeql')
  }
  # Deduplicate
  return ,(@($contexts) | Select-Object -Unique)
}

$contexts = Get-DesiredStatusContexts -org $Org -repo $Repo -branch $Branch
# Ensure contexts is always an array for JSON serialization
if (-not ($contexts -is [System.Array])) { $contexts = @($contexts) }

$payload = [pscustomobject]@{
  required_status_checks = [pscustomobject]@{
    strict   = $true
    contexts = @($contexts)
  }
  enforce_admins = $true
  required_pull_request_reviews = [pscustomobject]@{
    required_approving_review_count = 1
    dismiss_stale_reviews           = $true
    require_code_owner_reviews      = $true
    require_last_push_approval      = $false
    require_review_thread_resolution = $true
  }
  restrictions = $null
  required_linear_history = $true
  allow_force_pushes = $false
  allow_deletions = $false
  required_conversation_resolution = $true
  required_signatures = $true
  allow_squash_merge = $true
  allow_merge_commit = $false
  allow_rebase_merge = $false
}
$json = $payload | ConvertTo-Json -Depth 6
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
