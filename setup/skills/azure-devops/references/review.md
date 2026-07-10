# Reviewing a PR's code

You've already resolved the PR (project, repoId, repo, source/target branches) via
the shared setup. Now read the diff, analyze it, and optionally vote. All commands
are plain `az` / `git` — no prefix.

## Step 1 — Get the diff

Fetch the branches and diff source against target. Use the `src`/`tgt` from the
shared setup (strip the `refs/heads/` prefix):

```bash
git fetch origin
git diff origin/<target-branch>...origin/<source-branch>
```

The three-dot form shows what the source branch adds relative to the merge-base —
i.e. exactly what the PR introduces, not unrelated drift on the target.

## Step 2 — Get existing comment threads (context)

So you don't re-flag something a reviewer already raised:

```bash
az devops invoke --area git --resource pullRequestThreads \
  --route-parameters project=<project> repositoryId=<repoId> pullRequestId=<pr-id> \
  --api-version 7.0 --query "value[?status=='active'].comments[].content" -o json
```

## Step 3 — Analyze and report

Cover, concisely:
- **Summary** — what the PR does, in a sentence or two.
- **Issues** — bugs, correctness, security concerns (rank by severity). Tie each
  to a `file:line`.
- **Quality** — naming, structure, test coverage, anything that will age badly.
- **Suggestions** — concrete, actionable improvements.

Skip praise-padding; lead with what needs attention.

## Step 4 — Offer to post the findings on the PR (per-comment choice)

After reporting in chat, **always offer to post the findings as PR comments** —
don't post silently. Present the issues/suggestions as a numbered list and let the
user pick **which ones to post, one by one** (they may choose all, none, or a
subset). Don't post anything they didn't select.

Each selected finding becomes its **own thread** (so each is independently
resolvable). Comment content must be in **English** (see the skill's language
rule). Write each thread's JSON to a temp file, then POST it:

```bash
az devops invoke --area git --resource pullRequestThreads \
  --route-parameters project=<project> repositoryId=<repoId> pullRequestId=<pr-id> \
  --http-method POST --in-file <thread-json> --api-version 7.0
```

- **Finding tied to a `file:line`** → inline thread. `filePath` starts with `/`;
  the `right*` side is the source branch. Example JSON:
  ```json
  {
    "comments": [{ "parentCommentId": 0, "content": "<finding, in English>", "commentType": "text" }],
    "status": "active",
    "threadContext": {
      "filePath": "/src/Orders/OrderService.cs",
      "rightFileStart": { "line": 42, "offset": 1 },
      "rightFileEnd": { "line": 42, "offset": 1 }
    }
  }
  ```
- **General finding** (not bound to a line) → omit `threadContext` for an overall
  PR comment.

Report back the thread ids / count posted.

## Step 5 — Optionally vote

Only if the user asks you to set a vote:

```bash
az repos pr set-vote --id <pr-id> \
  --vote <approve | approve-with-suggestions | wait-for-author | reject>
```

`approve-with-suggestions` is the right default when the PR is mergeable but you
flagged non-blocking items.
