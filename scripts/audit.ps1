[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json",
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (!(Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$baseDir = Join-Path (Split-Path $ManifestPath -Parent) $manifest.baseDir

$date = Get-Date -Format 'yyyyMMddHHmmss'
$reportDir = Join-Path $PSScriptRoot '../logs'
if (!(Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
if (-not $OutputPath) { $OutputPath = Join-Path $reportDir ("audit-" + $date + ".md") }

function Get-GitHubRef { param($url)
  if ($url -match 'github.com[:/](?<org>[^/]+)/(?<repo>[^/]+)') {
    return [pscustomobject]@{ Org = $Matches['org']; Repo = $Matches['repo'] }
  }
  throw "Cannot parse org/repo from URL: $url"
}

function Test-Label {
  param($org, $repo, $name)
  try {
    $labels = gh label list --repo "$org/$repo" --json name 2>$null | ConvertFrom-Json
    return $labels.name -contains $name
  } catch { return $false }
}

function Get-Protection {
  param($org, $repo, $branch)
  try {
    $p = gh api repos/$org/$repo/branches/$branch/protection -H "Accept: application/vnd.github+json" 2>$null | ConvertFrom-Json
    return $p
  } catch { return $null }
}

function Get-RepoSettings {
  param($org, $repo)
  try {
    $r = gh api repos/$org/$repo -H "Accept: application/vnd.github+json" 2>$null | ConvertFrom-Json
    return $r
  } catch { return $null }
}

function Get-WorkflowNames {
  param($org, $repo)
  try {
    $wfs = gh api repos/$org/$repo/actions/workflows -H "Accept: application/vnd.github+json" 2>$null | ConvertFrom-Json
    if ($wfs -and $wfs.workflows) { return @($wfs.workflows.name) }
    return @()
  } catch { return @() }
}

function Test-StandardsFiles {
  param($repoPath)
  $required = @(
    '.github/dependabot.yml',
    '.github/workflows/ci.yml',
    '.github/workflows/codeql.yml',
    '.github/CODEOWNERS',
    '.editorconfig',
    '.gitattributes'
  )
  $results = @{}
  foreach ($rel in $required) {
    $results[$rel] = Test-Path (Join-Path $repoPath $rel)
  }
  [pscustomobject]$results
}

$lines = @()
$lines += "# Audit Report ($date)"
$lines += ""

foreach ($r in $manifest.repositories) {
  $ref = Get-GitHubRef $r.url
  $repoPath = Join-Path $baseDir $r.path

  $prot = Get-Protection $ref.Org $ref.Repo $r.branch
  $settings = Get-RepoSettings $ref.Org $ref.Repo
  $wfNames = Get-WorkflowNames $ref.Org $ref.Repo
  $files = Test-StandardsFiles $repoPath
  $labelsOk = @('bug','enhancement','chore','standards') | ForEach-Object { $_, (Test-Label $ref.Org $ref.Repo $_) }

  $lines += "## $($ref.Org)/$($ref.Repo) ($($r.branch))"
  $lines += "- Branch protection: " + $(if ($prot) { 'ENABLED' } else { 'MISSING' })
  if ($prot) {
    $ctxCount = if ($prot.required_status_checks -and $prot.required_status_checks.contexts) { $prot.required_status_checks.contexts.Count } else { 0 }
    $lines += "  - Strict: $($prot.required_status_checks.strict)"
    $lines += "  - Required status checks: $ctxCount"
    if ($ctxCount -gt 0) {
      $lines += "    - Contexts: " + ($prot.required_status_checks.contexts -join ', ')
    }
    $lines += "  - Code owner reviews: $($prot.required_pull_request_reviews.require_code_owner_reviews)"
    $lines += "  - Review count: $($prot.required_pull_request_reviews.required_approving_review_count)"
    $lines += "  - Linear history: $($prot.required_linear_history)"
    # Compare expected vs actual contexts
    $expected = @()
    if ($wfNames -contains 'CI') { $expected += @('CI / build-node','CI / build-python') }
  if ($wfNames -contains 'CodeQL') { $expected += @('CodeQL / codeql') }
    if ($expected.Count -gt 0) {
      $actual = @()
      if ($prot.required_status_checks -and $prot.required_status_checks.contexts) { $actual = @($prot.required_status_checks.contexts) }
      $missing = @($expected | Where-Object { $actual -notcontains $_ })
      if ($missing.Count -gt 0) {
        $lines += "  - Missing required contexts (based on detected workflows): " + ($missing -join ', ')
      }
    }
  }
  if ($wfNames.Count -gt 0) {
    $lines += "- Detected workflows: " + ($wfNames -join ', ')
  }
  if ($settings) {
    $s = $settings
    $lines += "- Visibility: $($s.visibility) | Issues: $($s.has_issues) | Wiki: $($s.has_wiki) | Delete branch on merge: $($s.delete_branch_on_merge) | Auto-merge: $($s.allow_auto_merge)"
    if ($s.security_and_analysis) {
      $sa = $s.security_and_analysis
      $lines += "- Security & analysis:"
      $lines += "  - Advanced Security: $($sa.advanced_security.status)"
      $lines += "  - Secret scanning: $($sa.secret_scanning.status)"
      $lines += "  - Push protection: $($sa.secret_scanning_push_protection.status)"
      if ($sa.dependabot_security_updates) { $lines += "  - Dependabot security updates: $($sa.dependabot_security_updates.status)" }
    }
  }
  $lines += "- Labels: bug=$($labelsOk[1]) enhancement=$($labelsOk[3]) chore=$($labelsOk[5]) standards=$($labelsOk[7])"
  $lines += "- Standards files present:"
  foreach ($k in $files.PSObject.Properties.Name) {
    $val = $files.PSObject.Properties[$k].Value
    $lines += ("  - {0}: {1}" -f $k, $val)
  }
  $lines += ""
}

Set-Content -Path $OutputPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
Write-Host "Audit report written to $OutputPath"
