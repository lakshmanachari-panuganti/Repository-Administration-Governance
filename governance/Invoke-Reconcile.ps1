<#
.SYNOPSIS
    Makes every repository in the organisation match governance/repositories.json.

.DESCRIPTION
    Reconciliation, not event handling. It runs on a schedule and on demand, reads the
    desired state, and applies it. A repository created five minutes ago and one created
    a year ago converge to the same configuration.

    This is deliberately chosen over a webhook that fires on repository creation:
    a missed webhook leaves a repository ungoverned forever and nothing notices, whereas
    a missed reconcile run is corrected by the next one.

    Idempotent. Safe to run repeatedly.

.PARAMETER DryRun
    Report what would change without changing anything.

.PARAMETER RemoveLegacyRulesets
    Delete rulesets not named "governance: *". Off by default — deleting protection is
    destructive and a stale ruleset is reported loudly rather than removed silently.

.PARAMETER Only
    Reconcile a single repository by name.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$RemoveLegacyRulesets,
    [string]$Only
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Org           = $env:GOVERNANCE_ORG
$ReviewerAppId = $env:AI_REVIEWER_APP_ID
$OwnerLogin    = $env:GOVERNANCE_OWNER_LOGIN

foreach ($required in 'GOVERNANCE_ORG', 'AI_REVIEWER_APP_ID', 'GOVERNANCE_OWNER_LOGIN') {
    if (-not (Get-Item "env:$required" -ErrorAction SilentlyContinue).Value) {
        throw "Environment variable $required is not set."
    }
}

$configPath = Join-Path $PSScriptRoot 'repositories.json'
$config     = Get-Content $configPath -Raw | ConvertFrom-Json

$script:Changes  = [System.Collections.Generic.List[string]]::new()
$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Write-Change([string]$Message) {
    $prefix = if ($DryRun) { 'WOULD' } else { 'DID  ' }
    Write-Host "  $prefix  $Message"
    $script:Changes.Add($Message)
}

function Write-Warn([string]$Message) {
    Write-Host "  WARN   $Message"
    $script:Warnings.Add($Message)
}

function Invoke-GH {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $out = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "gh $($Arguments -join ' ') failed: $out"
    }
    return $out
}

function Get-RepoSetting {
    param($RepoConfig, [string]$Key)
    if ($RepoConfig.PSObject.Properties.Name -contains $Key) { return $RepoConfig.$Key }
    return $config.defaults.$Key
}

# ---------------------------------------------------------------- ruleset bodies

function New-RulesetBody {
    param(
        [ValidateSet('main', 'develop', 'ai-driven1')][string]$Branch,
        [string[]]$ExtraChecks = @()
    )

    $rules = @(
        @{ type = 'deletion' }
        @{ type = 'non_fast_forward' }
    )

    if ($Branch -eq 'ai-driven1') {
        # The AI development branch. The Developer App pushes here directly, so no
        # pull request rule — the gate is on develop, which is where its work lands.
        return @{
            name        = "governance: $Branch"
            target      = 'branch'
            enforcement = 'active'
            conditions  = @{ ref_name = @{ include = @("refs/heads/$Branch"); exclude = @() } }
            rules       = $rules
            bypass_actors = @()
        }
    }

    # main is production. A human code owner must approve, and an App cannot be a code
    # owner, so no App can satisfy this rule and therefore no App can merge to main.
    # develop is check-gated: the reviewer App's verdict is the approval.
    $isMain = $Branch -eq 'main'

    $rules += @{
        type = 'pull_request'
        parameters = @{
            required_approving_review_count   = if ($isMain) { 1 } else { 0 }
            require_code_owner_review         = $isMain
            require_last_push_approval        = $isMain
            dismiss_stale_reviews_on_push     = $true
            required_review_thread_resolution = $true
            allowed_merge_methods             = @('squash')
        }
    }

    $checks = @(@{ context = 'ai-review'; integration_id = [int]$ReviewerAppId })
    foreach ($c in $ExtraChecks) { $checks += @{ context = $c } }

    $rules += @{
        type = 'required_status_checks'
        parameters = @{
            # "Require branches to be up to date before merging."
            strict_required_status_checks_policy = $true
            required_status_checks               = $checks
        }
    }

    return @{
        name          = "governance: $Branch"
        target        = 'branch'
        enforcement   = 'active'
        conditions    = @{ ref_name = @{ include = @("refs/heads/$Branch"); exclude = @() } }
        rules         = $rules
        # Empty: "enforce repository administrators to follow the same protection rules".
        bypass_actors = @()
    }
}

# ------------------------------------------------------------------- reconcilers

function Sync-Branch {
    param([string]$Repo, [string]$Branch, [string]$BaseSha)

    $exists = Invoke-GH -AllowFailure -Arguments @('api', "/repos/$Org/$Repo/git/refs/heads/$Branch")
    if ($exists) { return }

    Write-Change "create branch $Branch"
    if (-not $DryRun) {
        Invoke-GH -Arguments @(
            'api', '-X', 'POST', "/repos/$Org/$Repo/git/refs",
            '-f', "ref=refs/heads/$Branch", '-f', "sha=$BaseSha"
        ) | Out-Null
    }
}

function Sync-Ruleset {
    param([string]$Repo, [hashtable]$Body)

    $existing = Invoke-GH -Arguments @('api', "/repos/$Org/$Repo/rulesets", '--jq', '.') | ConvertFrom-Json
    $match    = @($existing | Where-Object { $_.name -eq $Body.name })

    $json = $Body | ConvertTo-Json -Depth 20
    $tmp  = New-TemporaryFile
    Set-Content -Path $tmp -Value $json -Encoding utf8

    try {
        if ($match.Count -gt 0) {
            $id = $match[0].id
            # Always PUT. Comparing nested ruleset JSON for equality is more code than
            # simply asserting the desired state, and PUT is idempotent.
            Write-Change "update ruleset '$($Body.name)' (id $id)"
            if (-not $DryRun) {
                Invoke-GH -Arguments @('api', '-X', 'PUT', "/repos/$Org/$Repo/rulesets/$id", '--input', $tmp) | Out-Null
            }
        }
        else {
            Write-Change "create ruleset '$($Body.name)'"
            if (-not $DryRun) {
                Invoke-GH -Arguments @('api', '-X', 'POST', "/repos/$Org/$Repo/rulesets", '--input', $tmp) | Out-Null
            }
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Sync-LegacyRulesets {
    param([string]$Repo)

    $existing = Invoke-GH -Arguments @('api', "/repos/$Org/$Repo/rulesets", '--jq', '.') | ConvertFrom-Json
    $legacy   = @($existing | Where-Object { $_.name -notlike 'governance: *' })

    foreach ($r in $legacy) {
        if ($RemoveLegacyRulesets) {
            Write-Change "delete legacy ruleset '$($r.name)' (id $($r.id))"
            if (-not $DryRun) {
                Invoke-GH -Arguments @('api', '-X', 'DELETE', "/repos/$Org/$Repo/rulesets/$($r.id)") | Out-Null
            }
        }
        else {
            Write-Warn "legacy ruleset '$($r.name)' (id $($r.id)) still active alongside governance rulesets. Rerun with -RemoveLegacyRulesets to remove it."
        }
    }
}

function Sync-RepositorySettings {
    param([string]$Repo)

    if (-not $DryRun) {
        Invoke-GH -AllowFailure -Arguments @(
            'api', '-X', 'PATCH', "/repos/$Org/$Repo",
            '-F', 'allow_squash_merge=true',
            '-F', 'allow_merge_commit=false',
            '-F', 'allow_rebase_merge=false',
            '-F', 'delete_branch_on_merge=true',
            '-F', 'allow_auto_merge=true',
            '-F', 'has_issues=true'
        ) | Out-Null
    }
    Write-Change 'apply repository settings (squash-only, delete branch on merge)'
}

function Sync-SecuritySettings {
    param([string]$Repo)

    $body = @{
        security_and_analysis = @{
            secret_scanning                       = @{ status = 'enabled' }
            secret_scanning_push_protection       = @{ status = 'enabled' }
        }
    } | ConvertTo-Json -Depth 10

    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $body -Encoding utf8
    try {
        Write-Change 'enable secret scanning + push protection'
        if (-not $DryRun) {
            Invoke-GH -AllowFailure -Arguments @('api', '-X', 'PATCH', "/repos/$Org/$Repo", '--input', $tmp) | Out-Null
        }
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

    Write-Change 'enable private vulnerability reporting'
    if (-not $DryRun) {
        Invoke-GH -AllowFailure -Arguments @('api', '-X', 'PUT', "/repos/$Org/$Repo/private-vulnerability-reporting") | Out-Null
    }
}

function Sync-Codeowners {
    param([string]$Repo, [string]$DefaultBranch)

    # main requires code-owner review. Without this file that rule can never be
    # satisfied and main deadlocks — the exact failure mode of a required check that
    # nothing can report.
    $desired = @(
        '# Generated by Repository-Administration-Governance. Do not edit by hand.',
        '#',
        '# main requires code-owner approval. GitHub Apps cannot be code owners, which',
        '# is what prevents any bot from merging to production.',
        '',
        "* @$OwnerLogin"
    ) -join "`n"

    $current = Invoke-GH -AllowFailure -Arguments @(
        'api', "/repos/$Org/$Repo/contents/.github/CODEOWNERS?ref=$DefaultBranch", '--jq', '.content'
    )

    if ($current) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($current -join '').Replace("`n", '')))
        if ($decoded.Trim() -eq $desired.Trim()) { return }
    }

    Write-Warn "CODEOWNERS missing or stale on $Repo. main will block until it exists. Commit it via a pull request — this script does not push to protected branches."
}

# ------------------------------------------------------------------------ driver

Write-Host "Reconciling organisation '$Org'"
if ($DryRun) { Write-Host 'DRY RUN — no changes will be made.' }
Write-Host ''

$repoNames = $config.repositories.PSObject.Properties.Name
if ($Only) { $repoNames = @($repoNames | Where-Object { $_ -eq $Only }) }
if (-not $repoNames) { throw "No repositories matched." }

$failed = @()

foreach ($name in $repoNames) {
    Write-Host "── $name"
    $repoConfig = $config.repositories.$name

    try {
        $repo = Invoke-GH -AllowFailure -Arguments @('api', "/repos/$Org/$name", '--jq', '{default_branch,size}')
        if (-not $repo) { Write-Warn 'repository not found — skipping'; continue }
        $repoInfo = $repo | ConvertFrom-Json

        if ($repoInfo.size -eq 0) {
            Write-Warn 'repository is empty; branches and rulesets cannot be applied yet'
            continue
        }

        $defaultBranch = $repoInfo.default_branch
        $baseSha = Invoke-GH -Arguments @('api', "/repos/$Org/$name/git/refs/heads/$defaultBranch", '--jq', '.object.sha')

        foreach ($branch in (Get-RepoSetting $repoConfig 'branches')) {
            Sync-Branch -Repo $name -Branch $branch -BaseSha $baseSha
        }

        Sync-RepositorySettings -Repo $name
        Sync-SecuritySettings   -Repo $name
        Sync-Codeowners         -Repo $name -DefaultBranch $defaultBranch

        $extra = Get-RepoSetting $repoConfig 'extraRequiredChecks'
        foreach ($branch in @('ai-driven1', 'develop', 'main')) {
            $checks = @()
            if ($branch -ne 'ai-driven1' -and $extra.PSObject.Properties.Name -contains $branch) {
                $checks = @($extra.$branch)
            }
            Sync-Ruleset -Repo $name -Body (New-RulesetBody -Branch $branch -ExtraChecks $checks)
        }

        Sync-LegacyRulesets -Repo $name
    }
    catch {
        Write-Host "  ERROR  $($_.Exception.Message)"
        $failed += $name
    }
    Write-Host ''
}

Write-Host "Changes: $($script:Changes.Count)   Warnings: $($script:Warnings.Count)   Failed repos: $($failed.Count)"

if ($env:GITHUB_STEP_SUMMARY) {
    $summary = @("## Governance reconcile", "", "- Changes: $($script:Changes.Count)", "- Warnings: $($script:Warnings.Count)", "")
    if ($script:Warnings.Count) {
        $summary += '### Warnings'
        $summary += ($script:Warnings | ForEach-Object { "- $_" })
    }
    $summary -join "`n" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($failed.Count -gt 0) { throw "Reconcile failed for: $($failed -join ', ')" }
