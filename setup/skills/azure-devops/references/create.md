# Creating a new PR (and its Jira ticket via `acli`)

Open a PR with `az repos pr create`. For `feat`/`fix` work that has no ticket
yet, create the Jira issue **first** (with `acli`) so the PR title can carry the
required ticket number.

All commands are plain `az` / `git` / `acli` — no prefix; ctx-wire shims filter
the output.

## Step 1 — Determine type, description, and branch state
Settle what the branch name, ticket, and PR title all share — but **don't push
yet**, the branch may need renaming first (Step 4).
```bash
git branch --show-current          # where are we? (main/develop, or a feature branch)
git log <target>..HEAD --oneline   # commits being merged
git diff <target>...HEAD --stat    # changed files
```
From the work, decide:
- **type** — `feat | fix | chore | style | refactor | docs | test | perf | ci | build`
- **description** — a short kebab-case slug (e.g. `add-bulk-cancellation`)

Target branch defaults to `main` unless the user says otherwise.

## Step 2 — Decide whether a ticket is needed
Conventional-commit convention: the PR title needs a ticket for `feat`/`fix`.
`chore` / `docs` / `refactor` / `test` / `ci` / `build` / `style` do not require
one.

**Which project — `LCT` vs `LOT`?** Pick by what the work is, not a fixed default:
- **`LCT-#####` (Client)** — Client-facing / Client-tribe work.
- **`LOT-#####` (order / P&O Enabler)** — order-domain / P&O work, e.g. the
  `dom-order-api` repo (Order module) and other Enabler-owned services.

(`#MER-####` merchant exists too but this flow doesn't create it.) If unsure
which tribe owns the work, ask rather than guessing — the two land on different
boards.

If the branch name, a commit message, or the user already names a ticket, reuse
it and skip to Step 4. Otherwise create one (Step 3).

## Step 3 — Create the Jira ticket with `acli`
Jira site `smarter-edenred.atlassian.net` — `acli` is already authenticated to it
(check once with `acli jira auth status`). Two project paths, chosen in Step 2:

- **`LCT` (Client)** — parent Epic `LCT-46421`, Team `Client Cross Tribe Tech`
  (`customfield_10001 = 9d71c95d-ef4e-4847-8b56-3a6255330ad7`). Story-points +
  fix version `Client - Next release` apply. This is the path the JSON below and
  the rest of this step document in full.
- **`LOT` (order / P&O Enabler)** — Team `Enabler Tribe-P&O`
  (`customfield_10001 = a40d150c-6907-47f6-b44c-c962b4b9e726-28`, board 28
  "Enabler P&O SCRUM"). Same create mechanics; the **only mandatory** custom
  field is `Team` (see the LOT box below) — parent Epic, story points and fix
  version are all **optional** and can be omitted. Use this for `dom-order-api`
  and other Enabler services.

Both paths use `acli jira workitem create --from-json` with the same `type`
(`Story`/`Bug`/`Task`) and assignee rules; only the project key and the fields
noted above differ.

The parent (`LCT-46421`) is an **Epic** (hierarchy level 1), so the child is a
normal Story/Bug/Task (level 0) linked as a child. The ticket must be **assigned
to you**, **estimated with story points** (estimate it first — see below), and
tagged with the fix version **`Client - Next release`**. The Sprint is **not**
set — leave it unset (the ticket lands in the backlog).

### NEVER run `acli jira workitem create` directly — use the wrapper

`create` is **not idempotent and cannot be undone**: LOT denies delete permission,
so a duplicate ticket can only be transitioned to `Annulé`, never removed. And
`acli … create --json` prints a large payload whose `"key"` is **not** near the
tail — pipe it through `tail`/`head` and you lose the key. Re-running `create` to
recover it silently creates a **second ticket**. This has bitten us more than once.

Always go through **`~/.claude/scripts/jira-create.sh <json-file> [acli args…]`**.
It prints **only** the resulting key (safe to pipe), or fails loudly with the full
payload, and it refuses to create a second ticket with the same summary.

It dedupes against a **local ledger** (`~/.claude/state/jira-created.tsv`), not just
a Jira search, because **Jira's search index is asynchronous**: a ticket created
seconds ago is not yet findable by JQL — which is exactly the window in which the
duplicate gets created. A search-based guard alone silently fails right when you
need it (verified: it created a duplicate on an immediate re-run).

If it ever prints *"created, but could NOT parse the key"*: the ticket **exists**.
Find it with `acli jira workitem search --jql 'project = LOT ORDER BY created DESC'`
— **do not re-run create**.

`acli jira workitem create` takes the full definition from a JSON file via
`--from-json`; custom fields go under `additionalAttributes`. Write the file,
then create:

```bash
cat > /tmp/wi.json <<'JSON'
{
  "projectKey": "LCT",
  "type": "Story",
  "summary": "<concise summary, in English>",
  "assignee": "712020:c8fbc26b-004f-4908-be22-1a34af79e66f",
  "description": {
    "type": "doc", "version": 1,
    "content": [ { "type": "paragraph", "content": [
      { "type": "text", "text": "<what & why, in English; add the PR link once created>" } ] } ]
  },
  "additionalAttributes": {
    "customfield_10001": "9d71c95d-ef4e-4847-8b56-3a6255330ad7",
    "customfield_10026": <storyPoints>,
    "fixVersions": [ { "name": "Client - Next release" } ]
  }
}
JSON
~/.claude/scripts/jira-create.sh /tmp/wi.json --parent "LCT-46421"
```

- `type` is **case-sensitive**: `Story` (feat) | `Bug` (fix) | `Tâche` (other).
  **On LOT the "task" type is the French `Tâche`** — plain `Task` is rejected
  ("Please provide valid issue type"). Allowed LOT types: `Story, Tâche, Bug,
  Sous-tâche, Epic, Initiative, …`.
- `assignee` = your account id `712020:c8fbc26b-004f-4908-be22-1a34af79e66f`
  (Geoffrey MARC); `@me` also works but the id is unambiguous.
- `customfield_10001` (**Team**) is a **plain-string id** — an object `{id:…}` is
  rejected. It is mandatory on **both** projects even though createmeta reports
  `required:false`; without it the create fails with *"The Team value is
  mandatory"*. Ids:
  - **LCT** → `9d71c95d-ef4e-4847-8b56-3a6255330ad7` (**Client Cross Tribe
    Tech**). **Do not assign `Client Tribe-CLT1` anymore.** This team has no squad
    board of its own — intentional; the cross-tribe Epic is `LCT-46421`.
  - **LOT** → `a40d150c-6907-47f6-b44c-c962b4b9e726-28` (**Enabler Tribe-P&O**,
    board 28 "Enabler P&O SCRUM").

### LOT (order / P&O) — minimal create
Same command, project `LOT`. Team is the only mandatory custom field; Epic /
story points / fix version are optional (add them only if the user asks). The
lean JSON:
```bash
cat > /tmp/wi.json <<'JSON'
{
  "projectKey": "LOT",
  "type": "Story",
  "summary": "<concise summary, in English>",
  "assignee": "712020:c8fbc26b-004f-4908-be22-1a34af79e66f",
  "description": {
    "type": "doc", "version": 1,
    "content": [ { "type": "paragraph", "content": [
      { "type": "text", "text": "<what & why, in English>" } ] } ]
  },
  "additionalAttributes": {
    "customfield_10001": "a40d150c-6907-47f6-b44c-c962b4b9e726-28",
    "customfield_10026": <storyPoints, optional>
  }
}
JSON
~/.claude/scripts/jira-create.sh /tmp/wi.json
```
Caveats: a **Bug** on LOT needs the same two extra fields as LCT (Detection Envs
+ Severity — see below). `acli jira workitem view/search` **strips all
customfields**, so you cannot read a ticket's Team back — trust the id you set.
- The returned key (e.g. `LCT-45123`) is the ticket for the PR title.
- **Epic link fallback**: if `--parent "LCT-46421"` is not honored (some
  company-managed projects gate the Epic link behind a custom field), find the
  epic-link field id (`acli jira workitem create --generate-json` /
  `acli jira project view LCT --json`) and set it in `additionalAttributes`, or
  link right after creation with `acli jira workitem edit --key <new> --from-json`.

### Bug type — two extra mandatory fields (else the create fails)
A `fix` maps to issue type **Bug**. On **LCT** (as on LOT) a Bug requires two
custom fields **in addition to** the `Team` field, or the create fails with
*"Detection Envs est obligatoire"* / *"Severity est obligatoire"*. Add both to
`additionalAttributes` on the create call — don't wait for the error then retry:
- **`customfield_10905` (Detection Envs)** — multi-select, pass `[{ "id": "<id>" }]`.
  Values: DEV `13113`, UAT `13114`, STG `14487`, PFR `13115`, UMX `14951`,
  PMX `14952`, PEE `14953`.
- **`customfield_10730` (Severity)** — single-select, pass `{ "id": "<id>" }`.
  Values: Minor `12751`, Medium `14501`, Major `12750`, Blocker `12752`.

For a tooling/dev-found bug the sane default is `Detection Envs=DEV` +
`Severity=Minor`, so `additionalAttributes` becomes:
```json
"additionalAttributes": {
  "customfield_10001": "9d71c95d-ef4e-4847-8b56-3a6255330ad7",
  "customfield_10026": <storyPoints>,
  "customfield_10905": [ { "id": "13113" } ],
  "customfield_10730": { "id": "12751" },
  "fixVersions": [ { "name": "Client - Next release" } ]
}
```
(Story `feat` and Task `other` do **not** need these two fields — Bug only.)

### Fix version (`fixVersions`)
**LCT only.** Tag every **Client** ticket with `Client - Next release`, referenced
by name in the `fixVersions` array. **LOT** tickets don't take this version — omit
`fixVersions` (or use a LOT release only if the user names one). If the create
rejects the name (version not found, or the
project requires an id), look up the `LCT` project versions and pass
`{"id": "<versionId>"}` instead, or set it right after creation with
`acli jira workitem edit --key <new key> --from-json` (an `additionalAttributes`
with just `fixVersions`).

### Sprint — only when the user asks for one
By default leave the Sprint unset (the ticket lands in the backlog). When the user
names a sprint, resolve its id and add the ticket after creation:
```bash
acli jira board list-sprints --id 28 --state active,future --json   # board 28 = Enabler P&O SCRUM (LOT)
```
Sprint names carry a PI prefix — "P&O Sprint 2" is really `PI#19 P&O Sprint 2`, so
**match on the suffix, not the exact name**. Then add it with the Atlassian MCP tool
`jira_add_issues_to_sprint(sprint_id, issue_keys)` (`acli` has no add-to-sprint verb).

### Assignee
Always assign the new ticket to **yourself** — never leave it unassigned. Account
id `712020:c8fbc26b-004f-4908-be22-1a34af79e66f` (Geoffrey MARC), or `--assignee
"@me"`. (When *reusing* an existing ticket per Step 2, leave its assignee as-is —
don't hijack someone else's ticket.)

### Story points (`customfield_10026`)
Estimate the ticket's effort and set it (numeric field). Scale: **Fibonacci —
1, 2, 3, 5, 8, 13, 21**. In practice tickets rarely exceed **8** (most land on
2 / 3 / 5 / 8). Base the estimate on the diff you already gathered in Step 1
(files touched, components crossed, risk, uncertainty):

| Pts | When |
|---|---|
| 1  | Trivial — one-liner, version bump, config tweak |
| 2  | Small & well-understood — a few files, one component, low risk |
| 3  | Moderate — several files / clear logic across one area |
| 5  | Sizeable — multiple files or some unknowns, still one area |
| 8  | Large — multiple components/services, or meaningful unknowns |
| 13, 21 | Very large — should probably be split |

- **Confirm with the user before setting anything above 8** (13 / 21) — that size
  is unusual and usually means the work should be split; don't post it unconfirmed.
- **Ask the user when it isn't obvious** even within 1–8 — high uncertainty, broad
  cross-cutting scope, or the work sits on a boundary between two values (e.g.
  3 vs 5, 5 vs 8). Use a quick question with the scale above; don't silently guess.
- **If you decide on your own** (the size is obvious and ≤ 8), set the value AND
  **state the chosen points + a one-line rationale in the final summary** you
  return after creating the PR — never set points silently.
- Set it in `additionalAttributes: {"customfield_10026": <n>}` at creation
  (fallback: `acli jira workitem edit --key <new key> --from-json` with an
  `additionalAttributes` carrying just the points).

## Step 4 — Name the branch and push
Branch format: `<type>/gma/<description>`. For the types that require a ticket
(`feat`/`fix`), glue the ticket in front of the description:
`<type>/gma/<TICKET>-<description>`. `gma` is the fixed trigramme.

Examples:
- `feat/gma/LCT-12345-add-bulk-cancellation`
- `fix/gma/LCT-12346-retry-on-timeout`
- `chore/gma/bump-nuget-packages`  (no ticket)

Get the local branch onto that name **before** the first push:
- On the default branch (`main`/`develop`) with the work committed → cut a fresh
  branch at HEAD: `git switch -c <name>`.
- On a feature branch that is misnamed and **not yet pushed** → rename it:
  `git branch -m <name>`.
- Already pushed under another name → leave it (renaming a published branch is
  disruptive) and just flag it to the user.

Then push:
```bash
git push -u origin HEAD
```

## Step 5 — Create the PR
Title = **Conventional Commits with the Jira ticket as a trailing `#` reference**.
This is enforced by `commitlint`: every service repo ships a `commit-msg` hook +
`commitlint.config.js`, and `front-end` uses `@commitlint/config-conventional`.
On squash-merge the PR title becomes the commit subject GitVersion parses, so the
title must pass these rules. Write the title and description in English. Never add
AI attribution or Co-Authored-By.

**Format:** `<type>(<scope>): <subject> #<TICKET>`
```bash
az repos pr create \
  --source-branch <current> --target-branch <target> \
  --title "<type>(<scope>): <subject> #<TICKET>" \
  --description "<markdown summary>" --open
```
Example: `feat(clients): add hasProductClassFamilyPreferences filter to client search #LCT-46420`.

Rules the title MUST satisfy (the binding one is the service repos' custom
`function-rules/subject-case` in `commitlint.config.js`):
- **`<type>`** lower-case, one of `build, chore, ci, docs, feat, fix, perf,
  refactor, revert, style, test`. Exactly `: ` (colon + space) after
  `<type>(<scope>)`.
- **`<scope>`** lower-case, optional, in parens (e.g. `clients`, `ordering`).
- **`<subject>`** starts **lower-case** and is imperative; **no trailing period**.
- **For `feat` and `fix` the ticket is mandatory**: the subject must match
  `^[a-z].+#[A-Z]+-[0-9]+$` — start lower-case and **end** with `#<TICKET>`,
  where `<TICKET>` is `[A-Z]+-[0-9]+` (`#LCT-####` Client, `#LOT-####` order/P&O,
  `#MER-####` merchant). **Nothing may follow the ticket.**
- **Other types** (`chore`, `docs`, `refactor`, …) don't require a ticket — the
  subject just needs to start lower-case; omit `#<TICKET>`.
- **Whole title ≤ 100 characters** (`header-max-length`), trimmed.

Why the ticket sits at the end: the linter rejects any subject that doesn't start
lower-case, so a leading upper-case `LCT-####` only squeaks through via the legacy
form. The trailing `#<TICKET>` keeps the subject starting with a lowercase verb
and reads cleanly in the generated changelog.

Optionally add reviewers:
```bash
az repos pr reviewer add --id <pr-id> --reviewers <email-or-id>
```

## Step 6 — Kick off the Claude review gate
The "Claude AI Code Review" policy is `manualQueueOnly` and will **not** auto-run
on PR creation. Requeue it (same mechanism as `comments.md` Step 4 — `az pipelines
run` does not satisfy the gate):
```bash
EVAL_ID=$(az repos pr policy list --id <pr-id> \
  --query "[?configuration.settings.displayName == \`Claude AI Code Review\`].evaluationId" -o tsv)
[ -n "$EVAL_ID" ] && az devops invoke --area policy --resource Evaluations \
  --route-parameters project=<project> evaluationId=$EVAL_ID \
  --http-method PATCH --api-version 7.0-preview
```

## Step 7 — When the PR is merged: move the ticket to Done
The skill does not watch PRs. **When you tell it a PR has been completed/merged** —
and that PR carries a linked Jira ticket — transition the ticket to **Done**:
1. Get the ticket key from the PR title's trailing `#<TICKET>` (or the branch name
   `<type>/gma/<TICKET>-…`). Confirm the PR is actually merged first:
   ```bash
   az repos pr show --id <pr-id> --query "{title:title, status:status}" -o json
   ```
   Proceed only if `status == completed`. For an **abandoned** PR (not merged),
   ask the user whether the ticket should move at all — don't force Done.
2. Transition it — `acli` resolves the status name to the right transition:
   ```bash
   acli jira workitem transition --key <TICKET> --status "Done" --yes
   ```
   The landing status may read `Done` / `Resolved` / `Closed` depending on the
   `LCT` workflow — pick the one in the **Done** status category. If `acli`
   reports the status isn't a valid transition from the current state, list the
   issue (`acli jira workitem view <TICKET> --fields status`) and pick the label
   the workflow actually exposes.
3. Confirm the target ticket with the user before transitioning — it's an
   externally visible state change.

## Notes
- Output the PR URL + id when done.
- ADO auth = the PAT wired by `install-wsl.sh` (`AZURE_DEVOPS_EXT_PAT`). Jira goes
  through `acli` (separate credential — `acli jira auth login`).
- Creating a PR and a Jira ticket are externally visible, hard-to-undo actions —
  confirm the title/target/ticket with the user before firing if anything is
  ambiguous.
