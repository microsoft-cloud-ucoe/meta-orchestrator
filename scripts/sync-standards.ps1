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
$baseDir = (Resolve-Path (Join-Path (Split-Path $ManifestPath -Parent) $manifest.baseDir)).Path
$stdRoot = (Resolve-Path $StandardsPath).Path

# Prepare status tracking for parallel runs
$statusLogDir = Join-Path $PSScriptRoot '../logs'
if (!(Test-Path $statusLogDir)) { New-Item -ItemType Directory -Force -Path $statusLogDir | Out-Null }
$statusLogPath = Join-Path $statusLogDir ("sync-status-" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmss") + ".log")
Set-Content -Path $statusLogPath -Value "" -Encoding UTF8

function Invoke-StandardsWorker {
  param($r)
  Write-Host ("==> Repo: {0}" -f $r.name)
  $target = Join-Path $baseDir $r.path
  if (!(Test-Path (Join-Path $target ".git"))) {
    Write-Host "Skipping (not cloned): $($r.name)"
    return
  }
  $repoOrg = $Org
  if ([string]::IsNullOrWhiteSpace($repoOrg)) {
    if ($r.url -match 'github.com[:/](?<org>[^/]+)/') { $repoOrg = $Matches['org'] }
  }

  try {
    git -C $target fetch --all --prune | Out-Null
    git -C $target switch -C $effectiveBranch | Out-Null

    Get-ChildItem -Path $StandardsPath -Recurse -File | ForEach-Object {
    $full = $_.FullName
    $fullResolved = (Resolve-Path $full).Path
    if (-not $fullResolved.StartsWith($stdRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Path resolution error: $fullResolved is not under standards root $stdRoot"
    }
  $rel = $fullResolved.Substring($stdRoot.Length).TrimStart([char[]]"\\/")
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
      # Reset any staged/working changes back to HEAD for dry-run
      git -C $target reset --hard HEAD | Out-Null
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
      gh pr create -R $repoFull --fill --base $r.branch --head $effectiveBranch --title $prTitle --body $prBody 2>$null
      if ($labels -and $labels.Count -gt 0) {
        foreach ($l in $labels) { gh pr edit -R $repoFull --add-label "$l" 2>$null }
      }
  # Try enable auto-merge (squash) if branch protection allows it
  try { gh pr merge -R $repoFull --auto --squash 2>$null } catch {}
    }
  } catch {
    Write-Host "PR may already exist for $($r.name). Skipping create."
  }
  } catch {
    Write-Warning ("Worker error in {0}: {1}" -f $r.name, $_.Exception.Message)
    try { git -C $target switch $r.branch | Out-Null } catch {}
  }
}

if ($Parallel) {
  $auto = [Math]::Max(8, [Environment]::ProcessorCount * 2)
  $throttle = if ($PSBoundParameters.ContainsKey('Concurrency')) { $Concurrency } else { $auto }
  Write-Host "Parallel execution enabled. Throttle: $throttle (CPU: $([Environment]::ProcessorCount))"
  $manifest.repositories | ForEach-Object -Parallel {
    $r = $_
  $ErrorActionPreference = 'Stop'
    $baseDir        = $using:baseDir
    $StandardsPath  = $using:StandardsPath
    $stdRoot        = $using:stdRoot
    $effectiveBranch= $using:effectiveBranch
    $Org            = $using:Org
    $DryRun         = $using:DryRun
    $excludes       = $using:excludes
    $ifMissingOnly  = $using:ifMissingOnly
    $labels         = $using:labels
    $prTitle        = $using:prTitle
    $prBody         = $using:prBody
  $statusLogPath  = $using:statusLogPath

    # Inline worker logic (mirrors Invoke-StandardsWorker)
    $target = Join-Path $baseDir $r.path
    if (!(Test-Path (Join-Path $target ".git"))) {
      Write-Host "Skipping (not cloned): $($r.name)"
      try { Add-Content -Path $statusLogPath -Value "SKIP $($r.name) not-cloned" } catch {}
      return
    }
    $repoOrg = $Org
    if ([string]::IsNullOrWhiteSpace($repoOrg)) {
      if ($r.url -match 'github.com[:/](?<org>[^/]+)/') { $repoOrg = $Matches['org'] }
    }

  try {
      git -C $target fetch --all --prune | Out-Null
      git -C $target switch -C $effectiveBranch | Out-Null

      Get-ChildItem -Path $StandardsPath -Recurse -File | ForEach-Object {
      $full = $_.FullName
      $fullResolved = (Resolve-Path $full).Path
      if (-not $fullResolved.StartsWith($stdRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path resolution error: $fullResolved is not under standards root $stdRoot"
      }
  $rel = $fullResolved.Substring($stdRoot.Length).TrimStart([char[]]"\\/")
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
    try { git -C $target status --porcelain } catch {}
    try { git -C $target reset --hard HEAD | Out-Null } catch {}
    try { git -C $target switch $r.branch | Out-Null } catch {}
    try { Add-Content -Path $statusLogPath -Value "OK   $($r.name) dry-run" } catch {}
    return
  }

    if ((git -C $target diff --cached --name-only).Length -eq 0) {
      Write-Host "No staged changes for $($r.name)"
      git -C $target switch $r.branch | Out-Null
      try { Add-Content -Path $statusLogPath -Value "OK   $($r.name) no-changes" } catch {}
      return
    }

    git -C $target commit -m "chore: sync org standards" | Out-Null
    git -C $target push -u origin $effectiveBranch -f | Out-Null

    try {
      if ($r.url -match 'github.com[:/](?<org>[^/]+)/(?<repo>[^/]+)') {
        $repoFull = "$($Matches['org'])/$($Matches['repo'])"
        gh pr create -R $repoFull --fill --base $r.branch --head $effectiveBranch --title $prTitle --body $prBody 2>$null
        if ($labels -and $labels.Count -gt 0) {
          foreach ($l in $labels) { gh pr edit -R $repoFull --add-label "$l" 2>$null }
        }
  # Try enable auto-merge (squash) if branch protection allows it
  try { gh pr merge -R $repoFull --auto --squash 2>$null } catch {}
      }
    } catch {
      Write-Host "PR may already exist for $($r.name). Skipping create."
    }
    try { Add-Content -Path $statusLogPath -Value "OK   $($r.name) updated" } catch {}
    } catch {
      Write-Warning ("Worker error in {0}: {1}" -f $r.name, $_.Exception.Message)
      try { git -C $target switch $r.branch | Out-Null } catch {}
      try { Add-Content -Path $statusLogPath -Value "ERROR $($r.name) $_" } catch {}
    }
  } -ThrottleLimit $throttle
  # Summarize and set exit code appropriately
  $hadErrors = $false
  if (Test-Path $statusLogPath) {
    $lines = Get-Content $statusLogPath
    if ($lines | Where-Object { $_ -like 'ERROR *' }) { $hadErrors = $true }
  }
  if ($hadErrors) {
    Write-Warning "One or more repositories failed during parallel sync. See $statusLogPath for details."
    exit 1
  } else {
    Write-Host "Parallel sync completed successfully. See $statusLogPath for summary."
    exit 0
  }
} else {
  foreach ($r in $manifest.repositories) {
    Invoke-StandardsWorker $r
  }
  exit 0
}
