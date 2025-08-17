[CmdletBinding()]
param(
  [string]$Org,
  [string]$Repo
)

$ErrorActionPreference = "Stop"

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
  gh label create "$name" --color "$color" --description "$desc" --repo "$Org/$Repo" 2>$null || gh label edit "$name" --color "$color" --description "$desc" --repo "$Org/$Repo"
}
