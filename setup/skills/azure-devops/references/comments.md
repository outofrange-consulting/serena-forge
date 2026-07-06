# Reading, replying to, and resolving PR comment threads

You've already resolved the PR (project, repoId) via the shared setup. This covers
fetching threads, replying, resolving, and re-triggering the Claude review gate.
All commands are plain `az` — no prefix.

## Step 1 — Fetch all threads

```bash
az devops invoke --area git --resource pullRequestThreads \
  --route-parameters project=<project> repositoryId=<repoId> pullRequestId=<pr-id> \
  --api-version 7.0
```

Present them grouped: **active (unresolved) first**, resolved/closed after. For
each thread show file path, line, author, comment text, and status — that's what
the user needs to decide what still requires action.

## Step 2 — Reply to a thread

Write the reply in English. Write the comment JSON to a temp file, then POST it (a
reply is a new comment on an existing thread):

```bash
az devops invoke --area git --resource pullRequestThreads \
  --route-parameters project=<project> repositoryId=<repoId> pullRequestId=<pr-id> threadId=<thread-id> \
  --http-method POST --in-file <temp-json> --api-version 7.0
```

## Step 3 — Resolve a thread

PATCH the thread status (e.g. `fixed` / `closed`):

```bash
az devops invoke --area git --resource pullRequestThreads \
  --route-parameters project=<project> repositoryId=<repoId> pullRequestId=<pr-id> threadId=<thread-id> \
  --http-method PATCH --in-file <temp-json> --api-version 7.0
```

## Step 4 — Re-trigger the gating "Claude AI Code Review" policy

After pushing fixes, the PR's Build status stays stale until the gating policy
re-runs. That policy is `manualQueueOnly: true`, so you must mimic the PR page's
"Queue" button — **not** `az pipelines run` (that runs the pipeline but the build
isn't linked to the gate, so the policy stays stale).

```bash
# a. Get the Claude policy evaluationId for the PR
EVAL_ID=$(az repos pr policy list --id <pr-id> \
  --query "[?configuration.settings.displayName == \`Claude AI Code Review\`].evaluationId" -o tsv)

# b. Requeue the policy (PATCH /policy/evaluations/{evaluationId})
az devops invoke --area policy --resource Evaluations \
  --route-parameters project=<project> evaluationId=$EVAL_ID \
  --http-method PATCH --api-version 7.0-preview \
  --query "{evaluationId:evaluationId, status:status, buildId:context.buildId}"
```

The response's `context.buildId` is the gate-aware run id — monitor it with
`az pipelines runs show --id <buildId>`. Only this policy requeue produces a build
the gating Build policy recognises; `az pipelines run --id <pipeline>` does not.
