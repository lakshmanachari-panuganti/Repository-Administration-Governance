# Repository Administration & Governance

Centralised administration for the `lakshmanachari-panuganti` organisation: branch
protection, the standard pull request lifecycle, security settings and shared workflows.

Change configuration here; every repository follows.

---

## How it fits together

```
                     Repository-Administration-Governance
                     ├── governance/repositories.json      desired state
                     ├── governance/Invoke-Reconcile.ps1   makes reality match it
                     ├── agents/                           shared reviewer + developer
                     └── .github/workflows/
                         ├── pr-lifecycle.yml              reusable, called by every repo
                         └── reconcile-governance.yml      nightly + on demand
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
        www.srilatha.art      OMG.PSUtilities        PowerShell   …
        (10-line caller)      (10-line caller)      (10-line caller)
```

## Onboarding a repository

Two steps.

1. Add it to [`governance/repositories.json`](governance/repositories.json).
2. Copy [`.github/workflows/caller-template.yml.example`](.github/workflows/caller-template.yml.example)
   into that repository as `.github/workflows/pr-lifecycle.yml`.

The nightly reconcile creates the standard branches, applies the rulesets, and turns on
the security settings. Nothing else is needed.

**Order matters.** The caller workflow must exist and run at least once *before* the
ruleset requires `ai-review`. A required check that nothing can report blocks the branch
permanently.

---

## Branch strategy

| Branch | Purpose | Protection |
|---|---|---|
| `ai-driven1` | AI development. The Developer App pushes here directly. | No deletion, no force-push |
| `develop` | DEV environment | Pull request required, `ai-review` must pass, no human approval needed |
| `main` | PRD environment | Pull request required, **code-owner approval required**, merged by hand |

### Promotion path

```
feature ──> ai-driven1 ──> develop ──> main
```

`main` only accepts pull requests from `develop`. No feature branch and no AI branch may
open a pull request against `main` — every change passes through `develop` first.

A ruleset cannot express "which branch may open this pull request", so the `Branch Flow`
job in `pr-lifecycle.yml` enforces it and reports through the `ai-review` gate.

---

## The merge gate

Every protected branch requires one check: **`ai-review`**, published by the AI Reviewer
App.

```json
{ "context": "ai-review", "integration_id": 4483971 }
```

`integration_id` pins the check to that App. Without the pin, any App with
`checks: write` — including the Developer App — could publish its own `ai-review:
success` and merge itself. This was tested: the Developer App published a check by that
exact name and the pull request stayed blocked.

### Why a check and not an approval

A GitHub App's approving review is submitted successfully and then **ignored** by branch
protection unless the App has write access:

> `At least 1 approving review is required by reviewers with write access.`

So an approval-based gate forces the reviewer to hold `contents: write` — the thing it
must not have. Gating on a check keeps all three properties at once: the reviewer never
gets write access, its verdict gates the merge, and no human is needed on `develop`.

Check runs bind to a commit SHA, so a commit pushed after a green review leaves the new
head ungated and the pull request re-blocks. Stale-review handling comes free.

---

## Production governance

`main` is different on purpose.

- Code-owner approval is required, and [`CODEOWNERS`](.github/CODEOWNERS) names the
  organisation owner.
- **A GitHub App cannot be a code owner.** That single fact is what prevents any bot,
  machine account or automation from merging to production.
- Auto-merge is armed for `develop` only. Pull requests into `main` are merged by hand.
- Agents do not run on pull requests targeting `main`.

---

## Reconciliation, not webhooks

`reconcile-governance.yml` runs nightly, on demand, and on any push to `governance/**`.

A repository-created webhook was the obvious alternative and is worse: a missed webhook
leaves a repository ungoverned forever and nothing notices. A missed reconcile run is
corrected by the next one, and drift introduced by hand is undone automatically.

Manual runs default to **dry run**. Preview first:

```
Actions → Reconcile Governance → Run workflow → dry-run: true
```

Legacy rulesets — anything not named `governance: *` — are reported but never deleted
without the explicit `remove-legacy-rulesets` input. Deleting protection is destructive.

---

## What this repository manages

| Managed now | Where |
|---|---|
| Branch protection / rulesets | `governance/Invoke-Reconcile.ps1` |
| Standard branches | same |
| Repository settings (squash-only, delete on merge) | same |
| Secret scanning, push protection, private vulnerability reporting | same |
| PR lifecycle workflow | `.github/workflows/pr-lifecycle.yml` |
| Required status checks | `governance/repositories.json` |
| Shared agent definitions | `agents/` |
| Pull request template, CODEOWNERS | `.github/` |

Organisation-wide `SECURITY.md`, issue templates and the organisation profile stay in the
[`.github`](https://github.com/lakshmanachari-panuganti/.github) repository — GitHub only
reads organisation defaults from a repository with that exact name.

### Not yet automated

Repository labels · Dependabot configuration · README and LICENSE validation ·
compliance audit reporting · automatic `SECURITY.md` generation per repository.

---

## Identities

| Identity | Purpose | Key permission |
|---|---|---|
| `Lakshmanachari` App (`4483892`) | Writes code, opens pull requests, responds to review | `contents: write` |
| `Devils Advocate` App (`4483971`) | Reviews, comments, publishes `ai-review` | `contents: read` — **cannot push** |
| Governance App | Applies rulesets and settings | `administration: write` |
| `PR Approvers` team | Humans authorised to approve | — |

The reviewer holding `contents: read` is the point. A prompt injection against the
reviewer cannot alter code, because the API refuses the write regardless of what the
model was persuaded to attempt.
