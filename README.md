# IntelIntent GitHub Core (Meta Orchestrator)

Manage multiple repositories from one place using a simple manifest and PowerShell scripts.

Scripts:

- scripts/bootstrap.ps1 — Clone repos from `repos.json`.
- scripts/update.ps1 — Fetch, switch to the declared branch, and pull fast-forward.
- scripts/status.ps1 — Show branch, ahead/behind, and local changes.
- scripts/foreach.ps1 — Run a custom command across all cloned repos.
- scripts/refresh-repos.ps1 — Populate `repos.json` from your GitHub org.
- scripts/sync-standards.ps1 — Apply the standards pack, commit, push, and open PRs (supports -Parallel).
- scripts/apply-labels-all.ps1 — Apply standard labels across all repos.
- scripts/apply-branch-protection-all.ps1 — Apply branch protection org-wide.

Requirements:

- PowerShell 7+ (pwsh) and Git 2.23+.

Quick start:

1) Edit `repos.json` with your repositories.
2) pwsh .\scripts\bootstrap.ps1
3) pwsh .\scripts\status.ps1

Standards sync (safe to try):

- Dry-run (no commit):

		pwsh .\scripts\sync-standards.ps1 -DryRun

- Parallel sync (fast):

		pwsh .\scripts\sync-standards.ps1 -Parallel -Concurrency 6

Configurable via `standards/standards-map.json`:

- excludes: glob-like patterns to skip
- ifMissingOnly: files copied only if absent
- labels: PR labels to set
- prTitle, prBody, branchPrefix
