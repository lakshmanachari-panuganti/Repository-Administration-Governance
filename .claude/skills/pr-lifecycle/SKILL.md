---
name: pr-lifecycle
description: Operating knowledge for the lakshmanachari-panuganti org's centralized PR lifecycle and governance system - the branch flow, the reusable workflow, the two GitHub Apps, and the deadlock traps that produced the current design. Use when changing pr-lifecycle.yml, Invoke-Reconcile.ps1, repositories.json, the agent definitions, branch protection, rulesets, required checks, or when onboarding a repository.
---

# PR lifecycle and governance

One reusable workflow in `Repository-Administration-Governance` drives every
repository in the org. Repos carry a thin caller; a fix to the central workflow
reaches all of them at once.

## Architecture

```
ai-driven1  --PR-->  develop  --PR-->  main
 (direct push OK)     (bot-merged)      (human-merged, code-owner gated)
```

- **Central workflow**: `.github/workflows/pr-lifecycle.yml`, `on: workflow_call`.
  Jobs: `flow` → `eligibility` → `guard` → `review` → `respond` → `verdict` → `auto-merge`.
- **Callers**: each repo's own `.github/workflows/pr-lifecycle.yml`, `uses: ...@main`.
  Inputs: `language`, `test-command`, `enable-agents`, `ignore-checks`.
- **Reconciler**: `governance/Invoke-Reconcile.ps1` reads `governance/repositories.json`
  and makes GitHub match it. Idempotent. Runs nightly and on push to `main`.
- **Two GitHub Apps**: Developer (`lakshmanachari-panuganti[bot]`, write) authors and
  merges into `develop`; Reviewer (`devils-advocate-review[bot]`, read + checks) reviews
  and publishes the `ai-review` check.

## Rules that exist because something deadlocked

Each of these was a real outage. Do not "simplify" one away without reproducing
the failure it prevents.

**Never delete an old control until its replacement is observed active on that
specific branch.** Six deadlocks came from removing the old one first.

- **An App's approving review only counts if the App has write access.** The Reviewer
  App is read-only by design, so approval is *not* the gate — the pinned `ai-review`
  check is. Never rely on a bot approval satisfying a required-approvals rule.
- **Apps cannot be CODEOWNERS and cannot be org members.** That is what keeps bots out
  of `main`, and it is load-bearing.
- **Check runs are keyed by commit, not by PR.** Two PRs on one commit collide; flow
  violations are auto-closed for this reason.
- **`verdict` must run `if: always()`.** A required check that never runs is absent, and
  absent blocks forever.
- **Auto-merge must gate on the published check conclusion**, never on `needs.*.result`.
  Testing job result once merged 4 PRs on a failing verdict.
- **One review per round.** Each review fires a `pull_request_review` run; five reviews
  evicted the queued `pull_request` run that publishes `ai-review` and permanently
  blocked the PR. Concurrency is keyed on event type for the same reason.
- **`strict` (up-to-date) on `main` deadlocks every release after the first** — a merge
  commit leaves `main` ahead of `develop`, and `main -> develop` is forbidden. On
  `develop` it is correct and stays on.
- **`main` allows merge commits only; `develop` squash only.** Squashing a long-lived
  branch into another leaves them with no shared history.
- **`require_last_push_approval` is unsatisfiable for a solo maintainer.** Off until a
  second human joins PR Approvers.
- **Rules nothing can satisfy must be gated on their prerequisite**: no code-owner rule
  without a validated CODEOWNERS, no `ai-review` requirement without an adopted caller.
- **Dependabot runs receive no Actions secrets.** App keys must also live in the separate
  Dependabot secret store or every Dependabot PR deadlocks.
- **`ai-driven1` gets `deletion` protection but never `non_fast_forward`.** It is
  squash-merged, so it must be force-resettable or every cycle needs manual conflict work.
- Scripts must end with explicit `exit 0` — a trailing `$LASTEXITCODE` made the nightly
  reconcile report failure while succeeding.

## Solo-maintainer bypass

GitHub has no way to let anyone approve their own PR, and this org has one human.
`ownerBypassOnMain` grants `OrganizationAdmin` a bypass in `pull_request` mode: a PR is
still required, direct pushes still refused. It does **not** open `main` to bots — a
bypass applies to a named actor, and the Developer App is not an org admin and cannot be
a code owner. It **does** waive the required `ai-review` check along with the approval,
because GitHub has no per-rule granularity, so read the check status before merging.
Remove both bypasses the day a second human joins PR Approvers.

## Agent constraints

The reviewer runs `--allowedTools "Bash(gh:*),Read,Grep,Glob"` — no write tool, no
runtime. Two anchoring instructions failed silently against this: a `gh pr review` flag
that does not exist, then a `cat > review.json` it cannot execute. **Before writing any
instruction for an agent, check it against that tool list.** Post reviews with
`gh api .../reviews --input -` on stdin, then read the comments back to confirm they
attached.

`--allowedTools` is mandatory. Without it every `gh` call hits the CLI permission prompt
and the agent finishes having posted nothing.

The reviewer cannot execute tests, so it reports new test files as dead code unless told
otherwise. The `TEST_EVIDENCE` env var passes the guard's result into the prompt. Do not
"fix" this by granting it a runtime — that means executing untrusted PR code in a job
holding an installation token.

## Diagnosing a stuck PR

1. `gh pr view <n> --json statusCheckRollup` — is `ai-review` present on the *head* commit?
2. If absent, find the `pull_request` run. Evicted by a review storm? Cancelled by concurrency?
3. `gh api repos/{o}/{r}/rulesets` — does a rule exist that nothing can satisfy?
4. Check both classic protection and rulesets. They are enforced as a union.
