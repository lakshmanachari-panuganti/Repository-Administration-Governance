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

function Test-HasProperty {
    param($Object, [string]$Name)
    # Not `$Object.PSObject.Properties.Name -contains $Name`: under Set-StrictMode the
    # member enumeration of .Name throws on an object with no properties, which is
    # exactly what a repository configured as {} produces.
    if ($null -eq $Object) { return $false }
    return [bool]($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name })
}

function Get-RepoSetting {
    param($RepoConfig, [string]$Key)
    if (Test-HasProperty $RepoConfig $Key) { return $RepoConfig.$Key }
    return $config.defaults.$Key
}

# ---------------------------------------------------------------- ruleset bodies

function New-RulesetBody {
    param(
        [ValidateSet('main', 'develop', 'ai-driven1')][string]$Branch,
        [string[]]$ExtraChecks = @(),
        # require_code_owner_review with no CODEOWNERS file is a rule nothing can ever
        # satisfy — it deadlocks main permanently. Only ask for it once the file exists;
        # the next reconcile run adds it automatically.
        [bool]$HasCodeowners = $false,
        # Same hazard: requiring ai-review in a repository that has not adopted the
        # lifecycle workflow means no job can ever publish that check.
        [bool]$HasLifecycle = $false
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

    # Assigned before the hashtable, not inline. Returning @('squash') from an if
    # expression unwraps the single-element array to a scalar, and the ruleset API
    # rejects a string where it expects a list.
    $mergeMethods = @('squash')
    if ($isMain) { $mergeMethods = @('merge') }

    $rules += @{
        type = 'pull_request'
        parameters = @{
            required_approving_review_count   = if ($isMain) { 1 } else { 0 }
            require_code_owner_review         = ($isMain -and $HasCodeowners)
            # Deliberately off. It forbids the person who made the last push from
            # approving. With a single human code owner, any release where that person
            # last pushed to develop becomes unapprovable — nobody else can satisfy it.
            # Turn it on only once a second human joins PR Approvers.
            require_last_push_approval        = $false
            dismiss_stale_reviews_on_push     = $true
            required_review_thread_resolution = $true
            # develop takes feature work: squash, so one pull request is one commit.
            # main takes develop: a merge commit, never a squash. Squashing a long-lived
            # branch into another long-lived branch leaves them with no shared history,
            # so the next develop -> main release sees every past commit as new.
            allowed_merge_methods             = $mergeMethods
        }
    }

    $checks = @()
    if ($HasLifecycle) {
        $checks += @{ context = 'ai-review'; integration_id = [int]$ReviewerAppId }
    }
    foreach ($c in $ExtraChecks) { $checks += @{ context = $c } }

    if ($checks.Count -gt 0) {
        $rules += @{
            type = 'required_status_checks'
            parameters = @{
                # "Require branches to be up to date before merging."
                strict_required_status_checks_policy = $true
                required_status_checks               = $checks
            }
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
    if ($env:GOVERNANCE_DEBUG) { Write-Host "---- $($Body.name) ----`n$json`n----" }
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
            # Both are needed: squash for feature -> develop, merge commit for the
            # develop -> main release. The per-branch ruleset decides which one applies.
            '-F', 'allow_squash_merge=true',
            '-F', 'allow_merge_commit=true',
            '-F', 'allow_rebase_merge=false',
            # Only deletes the head branch. develop and ai-driven1 carry a deletion rule,
            # so this reaches feature branches only.
            '-F', 'delete_branch_on_merge=true',
            '-F', 'allow_auto_merge=true',
            '-F', 'has_issues=true'
        ) | Out-Null
    }
    Write-Change 'apply repository settings (squash + merge commit, delete feature branch on merge)'
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

    if ($current) { return $true }

    if ($DryRun) {
        Write-Change 'create .github/CODEOWNERS'
        return $false
    }

    # Attempt to seed it. This succeeds on a repository whose default branch is not yet
    # protected — which is the case on first onboarding, when it matters. Once main is
    # protected the write is refused, and the file must arrive by pull request.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($desired + "`n"))
    $result = Invoke-GH -AllowFailure -Arguments @(
        'api', '-X', 'PUT', "/repos/$Org/$Repo/contents/.github/CODEOWNERS",
        '-f', 'message=chore: add CODEOWNERS (governance)',
        '-f', "content=$encoded",
        '-f', "branch=$DefaultBranch"
    )

    if ($result) {
        Write-Change 'create .github/CODEOWNERS'
        return $true
    }

    Write-Warn "CODEOWNERS is missing on $Repo and could not be written (the default branch is protected). Commit it by pull request. Until then main will not require code-owner review, so a bot could merge to production."
    return $false
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
        $repo = Invoke-GH -AllowFailure -Arguments @('api', "/repos/$Org/$name", '--jq', '.default_branch')
        if (-not $repo) { Write-Warn 'repository not found — skipping'; continue }
        $defaultBranch = "$repo".Trim()

        # Do not test the `size` field for emptiness — it is in KB and updates lazily, so
        # a small but populated repository reports 0. Absence of the default branch ref
        # is the reliable signal.
        $baseSha = Invoke-GH -AllowFailure -Arguments @(
            'api', "/repos/$Org/$name/git/refs/heads/$defaultBranch", '--jq', '.object.sha')
        if (-not $baseSha) {
            Write-Warn "no commits on $defaultBranch; branches and rulesets cannot be applied yet"
            continue
        }
        $baseSha = "$baseSha".Trim()

        foreach ($branch in (Get-RepoSetting $repoConfig 'branches')) {
            Sync-Branch -Repo $name -Branch $branch -BaseSha $baseSha
        }

        Sync-RepositorySettings -Repo $name
        Sync-SecuritySettings   -Repo $name
        $hasCodeowners = Sync-Codeowners -Repo $name -DefaultBranch $defaultBranch

        $hasLifecycle = [bool](Invoke-GH -AllowFailure -Arguments @(
            'api', "/repos/$Org/$name/contents/.github/workflows/pr-lifecycle.yml?ref=$defaultBranch", '--jq', '.sha'))
        if (-not $hasLifecycle) {
            Write-Warn "$name has not adopted .github/workflows/pr-lifecycle.yml. The ai-review gate is left off until it does — requiring a check nothing can publish would block the branch permanently."
        }

        $extra = Get-RepoSetting $repoConfig 'extraRequiredChecks'
        foreach ($branch in @('ai-driven1', 'develop', 'main')) {
            $checks = @()
            if ($branch -ne 'ai-driven1' -and (Test-HasProperty $extra $branch)) {
                $checks = @($extra.$branch)
            }
            Sync-Ruleset -Repo $name -Body (New-RulesetBody -Branch $branch -ExtraChecks $checks `
                -HasCodeowners $hasCodeowners -HasLifecycle $hasLifecycle)
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
