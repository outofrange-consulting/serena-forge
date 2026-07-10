---
name: atlassian
description: >-
  Query or update Jira and Confluence via the `acli` CLI — search/view/create/edit
  work items, comment, transition status, link issues, and read Confluence pages/
  spaces/blogs. Use automatically whenever the user mentions Jira, Confluence, a
  ticket/issue/epic/story/bug (by name or by key, e.g. "LCT-12345", "PROJ-123"),
  or pastes an atlassian.net URL (`/browse/...`, `/wiki/spaces/...`,
  `/wiki/.../pages/...`). Trigger on phrasings like "what's the status of
  PROJ-123", "create a Jira ticket for...", "comment on LCT-46421", "move this
  to In Progress", "what does this Confluence page say", "summarize the design
  doc at <url>". Do NOT use for Azure DevOps PRs (see `azdo-pr`, which also owns
  PR-linked Jira ticket creation) — this skill is for everything else Atlassian.
---

# atlassian — Jira & Confluence (acli first, MCP for the gaps)

Two backends, **acli first**:

1. **`acli`** — the official Atlassian CLI (`~/.local/bin/acli`, installed by
   token-diet's `install.sh`). Default for **reads and bulk JQL** — its output is
   English/structural, and ctx-wire's `acli.toml` filter compacts it and redacts
   bare `ATATT…`/`ATCTT…`/`ATOAT…` tokens before anything reaches context.
2. **Atlassian MCP** (`mcp__atlassian__*`) — the `sooperset/mcp-atlassian`
   Docker server registered in `~/.claude.json`, same API token as acli. Use it
   for **anything acli can't do or does badly**: Confluence page/comment writes
   (acli pages are read-only), worklogs, comment edits, watchers, issue links by
   type, remote links, versions/components, agile sprint edits, service-desk. It
   returns raw JSON (unfiltered — page/keep responses small: use `fields`/limits).

**Routing rule:** reach for acli first. The moment the operation isn't in acli's
table below — or an acli write 4xx's / lacks the subcommand — switch to the
matching `mcp__atlassian__*` tool instead of giving up or hitting raw REST.
Tools appear only after the MCP server is registered (needs a session restart the
first time). If `mcp__atlassian__*` tools aren't listed, say so; don't `curl` the
REST API by hand.

## Conventions

- **Check auth once per session**, before the first call: `acli auth status`
  (combined), or `acli jira auth status` / `acli confluence auth status` (per
  product — Jira and Confluence are authenticated independently). Not logged in?
  `acli jira auth login --web` / `acli confluence auth login --web` (browser
  OAuth), or non-interactively: `printf '%s' "$TOKEN" | acli jira auth login
  --site "<site>.atlassian.net" --email "<email>" --token` (same shape for
  `confluence`).
- **Recognize triggers without the words "Jira"/"Confluence"**: a bare issue key
  matching `[A-Z][A-Z0-9]*-[0-9]+` (e.g. `LCT-12345`, `PROJ-7`), an
  `atlassian.net/browse/<KEY>` URL (Jira issue), or an
  `atlassian.net/wiki/spaces/<KEY>` / `.../pages/<id>/...` URL (Confluence space
  / page) all mean this skill, even if the user never says "Jira" or "Confluence".
- Use `--jql` on `workitem search`/`edit`/`transition` for queries over many
  issues; use `--key <KEY>` for one or a few already-known keys.
- **Write everything in English** — summaries, descriptions, comments — the same
  convention as `azdo-pr`, even mid-conversation in another language.
- Creating a ticket **from a PR/branch** (`feat`/`fix`, always Client/`LCT` under
  Epic `LCT-46421`) and closing it on merge is `azdo-pr`'s job
  (`references/create.md`) — don't duplicate that flow here. Use *this* skill for
  everything else: standalone lookups, ad-hoc ticket creation/edits, comments,
  transitions, links, and Confluence reads.

## Jira — `acli jira …`

| Command | Purpose |
|---|---|
| `workitem search --jql "<JQL>" [--fields a,b] [--limit N] [--json\|--csv]` | Query issues |
| `workitem view <KEY> [--fields a,b] [--json] [--web]` | Read one issue |
| `workitem create --project <KEY> --type <Task\|Bug\|Story\|Epic> --summary "<s>" [--description "<d>"] [--assignee <email\|@me>] [--label a,b] [--parent <KEY>]` | Create an issue |
| `workitem edit --key <KEY>[,<KEY>...] [--summary] [--description] [--assignee] [--labels] [--type] [--yes]` | Edit issue(s); also takes `--jql`/`--filter` at scale |
| `workitem comment create --key <KEY> --body "<text>"` | Add a comment |
| `workitem comment list --key <KEY>` | Read comments |
| `workitem transition --key <KEY> --status "<Status>" [--yes]` | Move status (also `--jql`/`--filter`) |
| `workitem link create --out <KEY> --in <KEY> --type <LinkType>` | Link two issues |
| `workitem attachment ...` / `workitem watcher ...` / `workitem archive` / `workitem clone` / `workitem delete` | Less common — run with `--help` |
| `project view <KEY>` / `project list` | Project metadata |
| `board search` / `board view --id <N>` / `sprint view --id <N>` / `sprint list-workitems --id <N>` | Board/sprint drill-down |
| `filter list` / `filter view <ID>` | Saved filters |
| `dashboard search` | Dashboards |

## Confluence — `acli confluence …`

| Command | Purpose |
|---|---|
| `page view --id <PAGEID> [--body-format storage\|view\|atlas_doc_format] [--include-labels] [--include-version] [--json]` | Read a page. **This acli build is read-only for pages** — no `create`/`update` subcommand exists; use the MCP `confluence_create_page` / `confluence_update_page` / `confluence_add_comment` for writes (no longer hand off to the web UI). |
| `space list [--type global\|personal] [--keys A,B] [--json]` | List spaces |
| `space view --id <SPACEID> [--include-all] [--json]` | Space details |
| `blog list --space <KEY>` / `blog view --id <ID>` / `blog create --space <KEY> ...` | Blog posts |

## MCP — `mcp__atlassian__*` (what acli can't do)

Same site/token as acli, via the `sooperset/mcp-atlassian` Docker server in
`~/.claude.json`. The server is **filtered** (`ENABLED_TOOLS`) to the **52 tools
acli can't do** — everything acli already covers (issue search/view/create/edit,
comment-create, transition, generic link, watchers, attachments, boards,
sprint-reads, projects, `page view`) is switched off, so every exposed
`mcp__atlassian__*` tool is a genuine gap-filler. Highlights:

| MCP tool | Use when |
|---|---|
| `confluence_create_page` / `confluence_update_page` / `confluence_delete_page` | Write Confluence pages — acli can't. Body is `storage`/markdown; pass `space_id`+`title`+`content` (`parent_id` to nest). |
| `confluence_add_comment` / `confluence_add_label` | Comment on / label a page. |
| `confluence_search` (CQL) / `confluence_get_page` / `confluence_get_page_children` | Confluence read with CQL or by id, when acli's `page view` isn't enough. |
| `jira_add_comment` / `jira_edit_comment` | Comment (and **edit** an existing comment — acli only creates). |
| `jira_add_worklog` / `jira_get_worklog` | Log/read time — no acli subcommand. |
| `jira_create_issue_link` (typed) / `jira_link_to_epic` / `jira_create_remote_issue_link` / `jira_remove_issue_link` | Richer linking than acli's `link create`. |
| `jira_add_watcher` / `jira_remove_watcher` / `jira_get_issue_watchers` | Watchers. |
| `jira_create_version` / `jira_get_project_versions` / `jira_get_project_components` | Versions & components. |
| `jira_create_sprint` / `jira_update_sprint` / `jira_add_issues_to_sprint` | Agile sprint edits. |
| `jira_update_issue` / `jira_transition_issue` / `jira_batch_create_issues` | Field-level edits / bulk create when acli's flags fall short. |

Writes are **enabled** (server runs with read-only mode OFF). MCP responses are
raw JSON and unfiltered by ctx-wire — request specific `fields` and small limits.

## Extracting keys/IDs from a pasted URL

- `https://<site>.atlassian.net/browse/PROJ-123` → Jira key `PROJ-123` → `acli jira workitem view PROJ-123`
- `https://<site>.atlassian.net/wiki/spaces/<SPACEKEY>/pages/<id>/<slug>` → Confluence page → `acli confluence page view --id <id>`
- `https://<site>.atlassian.net/wiki/spaces/<SPACEKEY>/overview` → Confluence space → `acli confluence space view --id <SPACEKEY-or-numeric-id>`
- `https://<site>.atlassian.net/jira/software/projects/<KEY>/boards/<N>` → `acli jira board view --id <N>`

## Examples

```bash
acli jira workitem search --jql "project = LCT AND status != Done" --fields key,summary,status --limit 20
acli jira workitem view LCT-46421 --fields summary,description,status
acli jira workitem create --project LCT --type Task --summary "Rotate staging DB creds" --assignee @me
acli jira workitem comment create --key LCT-12345 --body "Reproduced on staging; logs attached."
acli jira workitem transition --key LCT-12345 --status "In Progress" --yes
acli jira workitem link create --out LCT-12345 --in LCT-12000 --type Blocks
acli confluence page view --id 123456789 --body-format storage
acli confluence space list --type global
```

## Troubleshooting

- `acli: command not found` → token-diet's `install.sh` wasn't run, or it ran
  after this OMP process started (shims land in `~/.local/bin`, only picked up on
  restart) — say so, don't fall back to raw `curl` against the Atlassian REST API.
- A 401/403 from any `acli` call almost always means the OAuth/API-token grant
  expired or lacks scope for that site/product — re-run the matching
  `acli <jira|confluence> auth login`, don't retry blindly.
