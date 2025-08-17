[CmdletBinding()]
param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutputDir = (Join-Path $PSScriptRoot '../logs'),
  [int]$MaxLocBytes = 1048576
)

$ErrorActionPreference = 'Stop'

if (!(Test-Path $Root)) { throw "Root not found: $Root" }
if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$jsonOut = Join-Path $OutputDir ("inventory-" + $timestamp + ".json")
$mdOut   = Join-Path $OutputDir ("inventory-" + $timestamp + ".md")
${trimChars} = @([char]92,[char]47)

function Get-GitMeta {
  param([string]$path)
  $git = @{ isRepo = $false }
  try {
    $top = git -C "$path" rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { $git.isRepo = $true; $git.root = $top.Trim() }
  } catch {}
  if ($git.isRepo) {
    try { $git.branch = (git -C "$path" rev-parse --abbrev-ref HEAD).Trim() } catch {}
    try { $git.remote = (git -C "$path" remote get-url origin).Trim() } catch {}
    try { $git.sha = (git -C "$path" rev-parse --short HEAD).Trim() } catch {}
    try { $git.dirty = -not [string]::IsNullOrWhiteSpace((git -C "$path" status --porcelain=v1)) } catch {}
  }
  return [pscustomobject]$git
}

$extToLang = @{
  '.ps1'='PowerShell'; '.psm1'='PowerShell'; '.psd1'='PowerShell';
  '.js'='JavaScript'; '.ts'='TypeScript'; '.jsx'='JavaScript'; '.tsx'='TypeScript';
  '.py'='Python'; '.json'='JSON'; '.yml'='YAML'; '.yaml'='YAML'; '.md'='Markdown'; '.sh'='Shell';
  '.bat'='Batch'; '.cmd'='Batch'; '.ps1xml'='PowerShell'; '.ini'='Config'; '.toml'='TOML'; '.xml'='XML'
}

$excludeDirs = @('.git','node_modules','.venv','venv','dist','build','out','.pytest_cache','__pycache__','.idea','.vscode')
function Get-Files {
  param([string]$root)
  $items = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
      $p = $_.FullName
      # Exclude if under any excluded directory root
      ($excludeDirs | Where-Object {
        $exRoot = (Join-Path $root $_)
        $p -like ("$exRoot*")
      }).Count -eq 0
    }
  return $items
}

function Measure-Lines {
  param([IO.FileInfo]$file)
  try {
    if ($file.Length -gt $MaxLocBytes) { return $null }
    $lc = (Get-Content -LiteralPath $file.FullName -ErrorAction Stop | Measure-Object -Line).Lines
    return $lc
  } catch { return $null }
}

function Get-WorkflowMeta {
  param([string]$file)
  $name = $null
  try {
    $lines = Get-Content -LiteralPath $file -TotalCount 50
    foreach ($l in $lines) { if ($l -match '^name:\s*(?<n>.+)$') { $name = $Matches['n'].Trim(); break } }
  } catch {}
  # Collect actions used
  $uses = @()
  try {
    (Select-String -Path $file -Pattern '^\s*uses:\s*([^\s]+)\s*$' -AllMatches).Matches | ForEach-Object {
      $uses += $_.Groups[1].Value.Trim()
    }
  } catch {}
  [pscustomobject]@{ path=$file; name=$name; uses=$uses }
}

function Get-Dependencies {
  param([string]$root)
  $dep = @{ }
  $pkgJson = Join-Path $root 'package.json'
  if (Test-Path $pkgJson) {
    try {
      $pj = Get-Content $pkgJson -Raw | ConvertFrom-Json
      $dep.npm = @{
        dependencies = $pj.dependencies
        devDependencies = $pj.devDependencies
      }
    } catch {}
  }
  $reqTxt = Join-Path $root 'requirements.txt'
  if (Test-Path $reqTxt) { $dep.pip = (Get-Content $reqTxt | Where-Object { $_ -and -not $_.StartsWith('#') }) }
  $pyproj = Join-Path $root 'pyproject.toml'
  if (Test-Path $pyproj) { $dep.pyproject = [pscustomobject]@{ path=$pyproj } }
  return [pscustomobject]$dep
}

# Begin scan
$git = Get-GitMeta -path $Root
$files = Get-Files -root $Root

$totalBytes = 0
$byExt = @{}
$byLang = @{}
$locByLang = @{}
$largest = New-Object System.Collections.Generic.List[object]

foreach ($f in $files) {
  $totalBytes += $f.Length
  $ext = [System.IO.Path]::GetExtension($f.Name).ToLowerInvariant()
  if (-not $ext) { $ext = '(none)' }
  if (-not $byExt.ContainsKey($ext)) { $byExt[$ext] = @{ count=0; bytes=0 } }
  $byExt[$ext].count++
  $byExt[$ext].bytes += $f.Length
  $lang = $extToLang[$ext]
  if (-not $lang) { $lang = 'Other' }
  if (-not $byLang.ContainsKey($lang)) { $byLang[$lang] = @{ count=0; bytes=0 } }
  $byLang[$lang].count++
  $byLang[$lang].bytes += $f.Length
  # LOC for text-likely types
  if ($lang -in @('PowerShell','JavaScript','TypeScript','Python','YAML','Markdown','JSON','Shell')) {
    $lc = Measure-Lines -file $f
  if ($null -ne $lc) {
      if (-not $locByLang.ContainsKey($lang)) { $locByLang[$lang] = 0 }
      $locByLang[$lang] += $lc
    }
  }
}

# Largest 15 files
$largest = $files | Sort-Object Length -Descending | Select-Object -First 15 | ForEach-Object {
  $rel = $_.FullName.Substring($Root.Length).TrimStart($trimChars)
  [pscustomobject]@{ path = $rel; sizeBytes = $_.Length }
}

# Workflows and actions used
$wfRoot = Join-Path $Root '.github/workflows'
$workflows = @()
if (Test-Path $wfRoot) {
  Get-ChildItem -LiteralPath $wfRoot -Filter *.yml -File | ForEach-Object { $workflows += (Get-WorkflowMeta -file $_.FullName) }
}
$actionsUsed = @()
foreach ($w in $workflows) { if ($w.uses) { $actionsUsed += $w.uses } }
$actionsUsed = @([string[]]$actionsUsed | Sort-Object -Unique)

# Scripts inventory
$scriptFiles = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -File -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
  $rel = $_.FullName.Substring($Root.Length).TrimStart($trimChars)
  [pscustomobject]@{ name = $_.Name; path = $rel; sizeBytes = $_.Length }
}

# Standards inventory
$standards = @{
  hasEditorConfig = Test-Path (Join-Path $Root '.editorconfig')
  hasGitAttributes = Test-Path (Join-Path $Root '.gitattributes')
  hasCODEOWNERS = Test-Path (Join-Path $Root '.github/CODEOWNERS')
  hasDependabot = Test-Path (Join-Path $Root '.github/dependabot.yml')
  hasCI = Test-Path (Join-Path $Root '.github/workflows/ci.yml')
  hasCodeQL = Test-Path (Join-Path $Root '.github/workflows/codeql.yml')
}

$deps = Get-Dependencies -root $Root

$summary = [pscustomobject]@{
  root = $Root
  git = $git
  counts = [pscustomobject]@{
    files = $files.Count
    bytes = $totalBytes
    directories = (Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue | Measure-Object).Count
  }
  byExtension = $byExt
  byLanguage = $byLang
  locByLanguage = $locByLang
  largest = $largest
  workflows = $workflows
  actionsUsed = $actionsUsed
  scripts = $scriptFiles
  standards = $standards
  dependencies = $deps
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonOut -Encoding UTF8

# Markdown report
$lines = @()
$lines += "# Inventory Report ($timestamp)"
$lines += ""
$lines += "- Root: ``$($summary.root)``"
if ($summary.git.isRepo) {
  $lines += "- Git: branch=$($summary.git.branch), sha=$($summary.git.sha), dirty=$($summary.git.dirty), remote=$($summary.git.remote)"
}
$lines += "- Files: $($summary.counts.files) | Dirs: $($summary.counts.directories) | Size: $([Math]::Round($summary.counts.bytes/1MB,2)) MB"
$lines += ""
$lines += "## Languages"
foreach ($kv in $summary.byLanguage.GetEnumerator() | Sort-Object { $_.Value.bytes } -Descending) {
  $lang = $kv.Key; $val = $kv.Value
  $loc = if ($summary.locByLanguage.ContainsKey($lang)) { $summary.locByLanguage[$lang] } else { 0 }
  $lines += "- ${lang}: files=$($val.count), size=$([Math]::Round($val.bytes/1KB,1)) KB, loc=$loc"
}
$lines += ""
$lines += "## Top 15 Largest Files"
foreach ($l in $summary.largest) { $lines += "- $($l.path) ($([Math]::Round($l.sizeBytes/1KB,1)) KB)" }
$lines += ""
$lines += "## Workflows"
if ($summary.workflows.Count -gt 0) {
  foreach ($w in $summary.workflows) { $lines += "- $($w.name) — ``$($w.path)``"; if ($w.uses.Count -gt 0) { $lines += "  - uses: " + ($w.uses -join ', ') } }
} else { $lines += "- None" }
$lines += ""
$lines += "## Actions Used"
if ($summary.actionsUsed.Count -gt 0) { $lines += ($summary.actionsUsed | ForEach-Object { "- $_" }) } else { $lines += "- None" }
$lines += ""
$lines += "## Scripts"
if ($summary.scripts.Count -gt 0) { foreach ($s in $summary.scripts) { $lines += "- $($s.name) — ``$($s.path)`` ($([Math]::Round($s.sizeBytes/1KB,1)) KB)" } } else { $lines += "- None" }
$lines += ""
$lines += "## Standards"
$lines += "- .editorconfig: $($summary.standards.hasEditorConfig)"
$lines += "- .gitattributes: $($summary.standards.hasGitAttributes)"
$lines += "- CODEOWNERS: $($summary.standards.hasCODEOWNERS)"
$lines += "- Dependabot: $($summary.standards.hasDependabot)"
$lines += "- CI workflow: $($summary.standards.hasCI)"
$lines += "- CodeQL workflow: $($summary.standards.hasCodeQL)"
$lines += ""
$lines += "## Dependencies"
if ($summary.dependencies.npm) {
  $lines += "- npm dependencies: " + (($summary.dependencies.npm.dependencies.PSObject.Properties.Name) -join ', ')
  $lines += "- npm devDependencies: " + (($summary.dependencies.npm.devDependencies.PSObject.Properties.Name) -join ', ')
}
if ($summary.dependencies.pip) { $lines += "- pip requirements: " + ($summary.dependencies.pip -join ', ') }
if ($summary.dependencies.pyproject) { $lines += "- pyproject.toml present" }

Set-Content -Path $mdOut -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
Write-Host "Inventory JSON: $jsonOut"
Write-Host "Inventory Markdown: $mdOut"