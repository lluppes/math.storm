# Cleans up old GitHub Actions workflow runs for the current repository.
# Usage: 
# .\cleanup-all-old-workflow-runs.ps1 [-Days <int>] [-Contains <string>] [-Force]
#
# Parameters:
# -Days: Delete every workflow run older than this many days. Prompted for when omitted.
# -Contains: Only include runs whose workflow name contains this text (case-insensitive).
# -Force: Skip the confirmation prompt before deleting.

[CmdletBinding()]
param(
    # Delete every workflow run older than this many days. Prompted for when omitted.
    [Parameter(Position = 0)]
    [int]$Days = -1,

    # Only include runs whose workflow name or workflow ID contains this text (case-insensitive).
    [Parameter()]
    [string]$Contains,

    # Skip the confirmation prompt before deleting.
    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ($Days -lt 0) {
    $answer = Read-Host 'Delete workflow runs older than how many days?'
    if (-not [int]::TryParse($answer, [ref]$Days) -or $Days -lt 0) {
        throw 'Days must be a whole number of zero or greater.'
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required. Install it and run gh auth login first.'
}

try {
    gh auth status | Out-Null
}
catch {
    throw 'You are not logged into GitHub CLI. Run gh auth login first.'
}

try {
    $repository = (gh repo view --json nameWithOwner --jq '.nameWithOwner').Trim()
}
catch {
    throw 'Could not resolve the current repository from gh. Run this command from inside a GitHub repo.'
}

if ([string]::IsNullOrWhiteSpace($repository)) {
    throw 'Could not resolve current repository. Run this command from inside a GitHub repo.'
}

$cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$Days)
Write-Host "Repository: $repository"
Write-Host "Finding runs created before $($cutoffUtc.ToString('yyyy-MM-dd HH:mm')) UTC ($Days day(s) old)..."

# The created filter returns every run (all workflows) older than the cutoff.
$cutoffFilter = $cutoffUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$perPage = 100
$page = 1
$oldRuns = @()

do {
    $path = "repos/$repository/actions/runs?per_page=$perPage&page=$page&created=%3C$cutoffFilter"
    $json = gh api --method GET --header 'X-GitHub-Api-Version: 2022-11-28' $path
    $pageRuns = @(($json | ConvertFrom-Json).workflow_runs)

    $oldRuns += $pageRuns
    $page += 1
} while ($pageRuns.Count -eq $perPage)

if (-not [string]::IsNullOrWhiteSpace($Contains)) {
    $pattern = "*$([WildcardPattern]::Escape($Contains))*"
    $oldRuns = @($oldRuns | Where-Object { $_.name -like $pattern -or "$($_.workflow_id)" -like $pattern })
}

if ($oldRuns.Count -eq 0) {
    $filterText = if ([string]::IsNullOrWhiteSpace($Contains)) { '' } else { " with a name containing '$Contains'" }
    Write-Host "No workflow runs older than $Days day(s)$filterText were found."
    return
}

$oldRuns = @($oldRuns | Sort-Object -Property created_at)

Write-Host ''
Write-Host "The following $($oldRuns.Count) run(s) will be deleted:"
$oldRuns |
    Select-Object @{ n = 'Workflow'; e = { $_.name } },
                  @{ n = 'WorkflowId'; e = { $_.workflow_id } },
                  @{ n = 'Run';      e = { $_.id } },
                  @{ n = 'Created';  e = { [DateTimeOffset]::Parse($_.created_at).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } },
                  @{ n = 'Status';   e = { if ($_.conclusion) { $_.conclusion } else { $_.status } } } |
    Format-Table -AutoSize

if (-not $Force) {
    $confirm = Read-Host "Delete these $($oldRuns.Count) run(s)? (y/N)"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Host 'Cancelled. Nothing was deleted.'
        return
    }
}

$deleted = 0
foreach ($run in $oldRuns) {
    try {
        gh api --method DELETE --header 'X-GitHub-Api-Version: 2022-11-28' "repos/$repository/actions/runs/$($run.id)" | Out-Null
        $deleted += 1
        Write-Host "Deleted $($run.name) run $($run.id) created $($run.created_at)"
    }
    catch {
        Write-Warning "Failed to delete run $($run.id): $_"
    }
}

Write-Host "Deleted $deleted of $($oldRuns.Count) run(s)."
