---
name: azure-devops
description: Drive Azure DevOps (Boards, Repos/PRs, Pipelines) from the shell with the az CLI and its azure-devops extension. Use whenever the user mentions Azure DevOps, ADO, boards, work items, ADO pull requests, or ADO pipelines. Reads and writes; PAT-authenticated. If the azdo-pr skill is installed, it OWNS the full PR lifecycle (create-review-complete + linked Jira tickets) — defer to it for end-to-end PR flows; this skill is the raw az CLI layer.
---

# Azure DevOps via `az devops`

> **PR lifecycle**: when the `azdo-pr` skill is present, end-to-end PR flows
> (create → review → complete, with linked Jira tickets) go through it. Use
> this skill for the underlying `az` commands and everything non-PR-lifecycle.

Use the `az` CLI (extension `azure-devops`) for everything Azure DevOps. Never
guess org/project — defaults are pre-configured; PAT auth is already wired.

## Auth & defaults (already set up by install-wsl.sh)

- `AZURE_DEVOPS_EXT_PAT` is exported from `~/.config/claude-tools/secrets.env`
  → every `az devops/repos/boards/pipelines` call authenticates non-interactively.
- Defaults live in `az devops configure -l` (organization, project). Override
  per call with `--org https://dev.azure.com/<org>` / `--project <p>` only when
  the user targets another org/project.
- If a call returns 401/`TF400813`: the PAT is missing/expired — tell the user
  to update `AZURE_DEVOPS_PAT` + `AZURE_DEVOPS_EXT_PAT` in
  `~/.config/claude-tools/secrets.env` (or re-run `setup/install-wsl.sh`).
  Do not loop retries.

## Output discipline (token diet)

Always constrain output: `-o table` for humans, `-o tsv --query '…'` when you
consume the value. Never dump raw `-o json` of list commands without a
`--query` projection and a `--top`/date filter.

## Boards (work items)

```bash
az boards work-item show --id 1234 -o table
az boards work-item create --type "User Story" --title "…" --description "…"
az boards work-item update --id 1234 --state "Active" --assigned-to user@org.com
az boards query --wiql "SELECT [System.Id],[System.Title],[System.State] FROM WorkItems WHERE [System.AssignedTo]=@Me AND [System.State]<>'Closed'" -o table
```

## Repos & pull requests

```bash
az repos list -o table
az repos pr list --status active -o table
az repos pr show --id 42 --query '{title:title,status:status,source:sourceRefName,reviewers:reviewers[].displayName}'
az repos pr create --repository <repo> --source-branch feat/x --target-branch main \
  --title "…" --description "…" --draft false
az repos pr set-vote --id 42 --vote approve      # approve|approve-with-suggestions|reject|reset|wait-for-author
az repos pr update --id 42 --status completed    # complete/abandon
az repos pr checkout --id 42                     # fetch + checkout the PR branch locally
```

Diff of a PR: `az repos pr show --id 42 --query 'lastMergeSourceCommit.commitId' -o tsv`
then `git fetch origin <sha> && git diff origin/<target>...<sha> --stat`.

## Pipelines

```bash
az pipelines list -o table
az pipelines runs list --top 5 -o table
az pipelines runs show --id 9876 --query '{status:status,result:result,pipeline:definition.name}'
az pipelines build queue --definition-name "<pipeline>" --branch refs/heads/main
```

Failing run: get the id from `runs list`, then fetch logs via
`az pipelines runs show` + the timeline REST call only if the summary isn't
enough — prefer the smallest read that answers the question.

## Guardrails

- Destructive/irreversible ops (`pr update --status abandoned`, deleting refs,
  `az repos delete`) — confirm with the user first.
- Writes (create/update/vote/queue) should quote back exactly what was done
  (id + URL from the response).
