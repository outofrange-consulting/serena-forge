---
name: azure-devops
description: Drive Azure DevOps (Boards, Repos/PRs, Pipelines) from the shell with the az CLI, AND own the full pull-request lifecycle end to end — open a PR (creating its Jira LCT ticket via acli when needed), review its code, diagnose why its CI/build is failing, handle its comment threads, and move the linked ticket to Done on merge. Use whenever the user mentions Azure DevOps, ADO, boards, work items, ADO pipelines, OR takes an explicit PR ACTION — "create/open/raise a PR", "review PR <id>", "why did the build fail", "the pipeline is red", "reply to the reviewer", "resolve the threads" — or pastes a dev.azure.com pull request URL and asks to do something with it. Reads and writes; PAT-authenticated. Do NOT trigger on incidental mentions of a PR, a conceptual question about PRs, or mid-implementation with no ADO operation requested. This is the single entry point for ADO; it does NOT merge/complete a PR itself.
---

# Azure DevOps via `az` (+ `acli` for PR-linked Jira)

Two layers in one skill:

1. **Raw `az` layer** — quick Boards / Repos / Pipelines commands for one-off
   reads and writes (below).
2. **PR lifecycle** — four heavier workflows (create + Jira ticket, review,
   CI diagnosis, comment threads) that each live in a `references/` file. Pick
   the workflow, read the matching reference.

Use the `az` CLI (extension `azure-devops`) for everything Azure DevOps, and
`acli` (Atlassian CLI) for the Jira ticket a `feat`/`fix` PR needs. Never guess
org/project — defaults are pre-configured; PAT auth is already wired.

## Auth & defaults (set up by `install-wsl.sh`)

- **ADO** — `AZURE_DEVOPS_EXT_PAT` is exported from
  `~/.config/claude-tools/secrets.env` → every `az devops/repos/boards/pipelines`
  call authenticates non-interactively. `az account show` failing is expected
  (that is Azure AD, unrelated) and does **not** mean ADO auth is missing.
- Defaults live in `az devops configure -l` (organization, project). Default org
  is `edenred-emea-benefits`; the project (e.g. `SmartER`) comes from the PR
  itself or the configured default. Override per call with
  `--org https://dev.azure.com/<org>` / `--project <p>` only when the user
  targets another org/project.
- If a call returns `401` / `TF400813: not authorized`: the PAT is missing or
  expired — tell the user to update `AZURE_DEVOPS_PAT` + `AZURE_DEVOPS_EXT_PAT`
  in `~/.config/claude-tools/secrets.env` (or re-run `setup/install-wsl.sh`).
  Do not loop retries.
- **Jira** (PR-linked tickets) goes through **`acli`**, authenticated separately
  (`acli jira auth status`; login via `install-wsl.sh`). No Atlassian MCP server
  is provisioned here — do not reach for `createJiraIssue`/`transitionJiraIssue`
  MCP tools; use the `acli` commands in `references/create.md`.
- **`az` may not reach the `SmartER` project.** `az devops project list` can
  return only `SmartER-Application` / `SmartER-PaaSAsProduct-QA`, and any
  `az repos` call against `SmartER` then fails with `VS800075` (or `TF401180:
  pull request not found`). Git push/fetch still works (separate credential).
  If the `azure-devops` MCP happens to be registered (not installed by
  `install-wsl.sh`, but may survive a machine migration), fall back to its
  `repo_*` tools (`repo_get_pull_request_by_id`, `repo_update_pull_request`,
  `repo_get_pull_request_changes`, `repo_list_pull_request_threads`, …) with
  `repositoryId:"sdk"`, `project:"SmartER"`. Otherwise report the limitation.

## Language — English on anything published

Write **everything posted to Azure DevOps or Jira in English** — PR titles,
descriptions, comments, replies, vote messages, and Jira summaries &
descriptions — even when the conversation is in another language. Only
chat-facing summaries and analysis follow the conversation language.

## Output discipline (token diet)

Plain `az` / `git` — **no prefix**; ctx-wire's shims filter, cap, and scrub the
output automatically. Always constrain it: `-o table` for humans, `-o tsv
--query '…'` when you consume the value. Never dump raw `-o json` of a list
command without a `--query` projection and a `--top`/date filter. Use
`az repos pr` / `az devops invoke` — never `gh`; this org is Azure DevOps.

## Boards (work items)

```bash
az boards work-item show --id 1234 -o table
az boards work-item create --type "User Story" --title "…" --description "…"
az boards work-item update --id 1234 --state "Active" --assigned-to user@org.com
az boards query --wiql "SELECT [System.Id],[System.Title],[System.State] FROM WorkItems WHERE [System.AssignedTo]=@Me AND [System.State]<>'Closed'" -o table
```

## Repos & pull requests — quick reads/writes

```bash
az repos list -o table
az repos pr list --status active --top 10 -o table
az repos pr show --id 42 --query '{title:title,status:status,source:sourceRefName,reviewers:reviewers[].displayName}'
az repos pr set-vote --id 42 --vote approve      # approve|approve-with-suggestions|reject|reset|wait-for-author
az repos pr checkout --id 42                     # fetch + checkout the PR branch locally
```

For anything richer than a one-off — **opening** a PR, **reviewing** its code,
**diagnosing CI**, or **handling comment threads** — use the PR-lifecycle
workflows below, not raw commands.

## Pipelines

```bash
az pipelines list -o table
az pipelines runs list --top 5 -o table
az pipelines runs show --id 9876 --query '{status:status,result:result,pipeline:definition.name}'
az pipelines build queue --definition-name "<pipeline>" --branch refs/heads/main
```

Failing run: get the id from `runs list`, then `az pipelines runs show` + the
timeline REST call only if the summary isn't enough. For a **PR** build that is
red, use `references/ci-errors.md` — it pulls assertion messages and source
`file:line` from the Test Results API instead of downloading whole logs.

## PR lifecycle — shared setup, then pick the workflow

Creating a PR starts from a branch, not a PR id — skip straight to
`references/create.md`. The three inspect/interact workflows first need the
project and repository id; get them once:

```bash
az repos pr show --id <pr-id> \
  --query "{project:repository.project.name, repoId:repository.id, repo:repository.name, src:sourceRefName, tgt:targetRefName, status:status}" -o json
```

If no PR id was given, `az repos pr list --status active --top 10` and ask which.

Then read the matching reference:

- **Create a PR** — open a PR for the current branch; for `feat`/`fix` create the
  Jira ticket (always Client/`LCT` under Epic `LCT-46421`) first → `references/create.md`.
- **PR merged → close its ticket** — when you report a PR (with a linked Jira
  ticket) has been completed/merged, transition the ticket to Done →
  `references/create.md` (Step 7).
- **Review the code** — analyze the diff, flag bugs/security issues, summarize,
  optionally post findings as PR comments, optionally vote → `references/review.md`.
- **CI is failing** — build red/rejected, pipeline tests failing → `references/ci-errors.md`.
- **Comments / threads** — read, reply to, or resolve threads, or re-trigger the
  gating "Claude AI Code Review" policy → `references/comments.md`.

A single request can span more than one workflow (e.g. "review the PR and tell me
why CI is red") — read both references and combine.

## Guardrails

- Destructive/irreversible ops (`az repos pr update --status abandoned`, deleting
  refs, `az repos delete`) — confirm with the user first. For an abandoned PR,
  ask before moving its ticket at all.
- Creating a PR and a Jira ticket are externally visible, hard-to-undo actions —
  confirm the title/target/ticket with the user before firing if anything is
  ambiguous.
- Writes (create/update/vote/queue) should quote back exactly what was done
  (id + URL from the response).

## Arguments

- `$ARGUMENTS`: the PR id, or a dev.azure.com PR URL (extract the trailing
  number). If omitted, list active PRs and ask which one.
