[CmdletBinding()]
param(
  [string]$ManifestPath = "$PSScriptRoot/../repos.json",
  [string]$StandardsPath = "$PSScriptRoot/../standards",
  [string]$BranchName = "chore/standards-sync",
  [string]$Org = "",
  [switch]$DryRun,
  [switch]$Parallel,
  [int]$Concurrency = 4
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $StandardsPath)) { throw "Standards folder not found: $StandardsPath" }

$standardsVersion = "v0"
if (Test-Path (Join-Path $StandardsPath ".standards-version")) {
  $standardsVersion = (Get-Content (Join-Path $StandardsPath ".standards-version") -Raw).Trim()
}

$mapPath = Join-Path $StandardsPath 'standards-map.json'
$map = $null
if (Test-Path $mapPath) { $map = Get-Content $mapPath -Raw | ConvertFrom-Json }
$excludes = @()
if ($map -and $map.excludes) { $excludes = $map.excludes }
$ifMissingOnly = @()
if ($map -and $map.ifMissingOnly) { $ifMissingOnly = $map.ifMissingOnly }
$labels = @()
if ($map -and $map.labels) { $labels = $map.labels }
$prTitle = if ($map -and $map.prTitle) { $map.prTitle } else { "chore: sync org standards" }
$prBody  = if ($map -and $map.prBody)  { $map.prBody }  else { "Automated standards sync via orchestrator." }
$branchPrefix = if ($map -and $map.branchPrefix) { $map.branchPrefix } else { "chore/standards-sync/" }
$effectiveBranch = if ($BranchName) { $BranchName } else { "$branchPrefix$standardsVersion" }

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$baseDir = Join-Path (Split-Path $ManifestPath -Parent) $manifest.baseDir

$worker = {
  param($r, $baseDir, $StandardsPath, $effectiveBranch, $Org, $DryRun, $excludes, $ifMissingOnly, $labels, $prTitle, $prBody)
  $target = Join-Path $baseDir $r.path
  if (!(Test-Path (Join-Path $target ".git"))) {
    Write-Host "Skipping (not cloned): $($r.name)"
    return
  }
  $repoOrg = $Org
  if ([string]::IsNullOrWhiteSpace($repoOrg)) {
    if ($r.url -match 'github.com[:/](?<org>[^/]+)/') { $repoOrg = $Matches['org'] }
  }

  git -C $target fetch --all --prune | Out-Null
  git -C $target switch -C $effectiveBranch | Out-Null

  Get-ChildItem -Path $StandardsPath -Recurse -File | ForEach-Object {
    $full = $_.FullName
    $rel = (Resolve-Path $full).Path.Substring($StandardsPath.Length).TrimStart('\\','/')
    foreach ($pattern in $excludes) { if ($rel -like $pattern) { return } }
    $dest = Join-Path $target $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null

    if ($ifMissingOnly -contains $rel -and (Test-Path $dest)) { return }

    if ([string]::IsNullOrWhiteSpace($repoOrg)) {
      Copy-Item -Path $full -Destination $dest -Force
    } else {
      $content = Get-Content $full -Raw
      $content = $content -replace '\bORG\b', $repoOrg
      Set-Content -Path $dest -Value $content -NoNewline
    }
  }

  git -C $target add -A
  if ($DryRun) {
    git -C $target status --porcelain
    git -C $target restore --staged .
    git -C $target checkout -- .
    git -C $target switch $r.branch | Out-Null
    return
  }

  if ((git -C $target diff --cached --name-only).Length -eq 0) {
    Write-Host "No staged changes for $($r.name)"
    git -C $target switch $r.branch | Out-Null
    return
  }

  git -C $target commit -m "chore: sync org standards" | Out-Null
  git -C $target push -u origin $effectiveBranch -f | Out-Null

  try {
    if ($r.url -match 'github.com[:/](?<org>[^/]+)/(?<repo>[^/.]+)') {
      $repoFull = "$($Matches['org'])/$($Matches['repo'])"
      $prUrl = gh pr create -R $repoFull --fill --base $r.branch --head $effectiveBranch --title $prTitle --body $prBody 2>$null
      if ($labels -and $labels.Count -gt 0) {
        foreach ($l in $labels) { gh pr edit -R $repoFull --add-label "$l" 2>$null }
      }
    }
  } catch {
    Write-Host "PR may already exist for $($r.name). Skipping create."
  }
}

if ($Parallel) {
  $auto = [Math]::Max(8, [Environment]::ProcessorCount * 2)
  $throttle = if ($PSBoundParameters.ContainsKey('Concurrency')) { $Concurrency } else { $auto }
  Write-Host "Parallel execution enabled. Throttle: $throttle (CPU: $([Environment]::ProcessorCount))"
  $manifest.repositories | ForEach-Object -Parallel $worker -ThrottleLimit $throttle -ArgumentList $baseDir, $StandardsPath, $effectiveBranch, $Org, $DryRun, $excludes, $ifMissingOnly, $labels, $prTitle, $prBody
} else {
  foreach ($r in $manifest.repositories) {
    & $worker $r $baseDir $StandardsPath $effectiveBranch $Org $DryRun $excludes $ifMissingOnly $labels $prTitle $prBody
  }
}
