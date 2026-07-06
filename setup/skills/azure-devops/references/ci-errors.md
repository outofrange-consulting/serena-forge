# Reading CI errors from a failing PR pipeline

Read the real test/build errors from a failing Azure DevOps PR pipeline without
drowning in logs. All commands are plain `az` — no prefix; ctx-wire caps and
scrubs the output.

A failed build's logs are large — a single test task log here was 34 KB+, and a
pipeline has many tasks. Downloading whole logs to find one assertion failure
burns context for no reason. There are two targeted paths:

- **Test failures** → the Test Results API returns the assertion message *and* the
  source `file:line` directly. No log reading at all.
- **Build/compile errors** (or any task with no published test results) → fetch
  **only the failed task's log** (identified from the timeline) and grep for error
  markers.

Always identify *which* path applies first (Step 1) before fetching anything heavy.

## Step 0 — Resolve the PR to its failing build

The PR's build-validation policies carry the build ids. Failing = `rejected`.

```bash
az repos pr policy list --id <pr-id> \
  --query "[?context.buildId != null].{policy:configuration.settings.displayName, status:status, buildId:context.buildId}" -o json
```

A PR can have several policy builds (CI, a Claude review gate, etc.). Pick the ones
with `"status": "rejected"`. Note the `<buildId>`. Get `<project>` from the shared
setup (`repository.project.name`, e.g. `SmartER`).

## Step 1 — Find which task failed (the timeline)

This tells you whether it's a test failure, a compile error, or something else —
and gives the `logId` you'll need for the fallback path.

```bash
az devops invoke --area build --resource Timeline \
  --route-parameters project=<project> buildId=<buildId> --api-version 7.1 \
  --query "records[?result=='failed'].{name:name, type:type, logId:log.id, issues:issues[].message}" -o json
```

Interpreting the result:
- A failed `Task` named `Test (...)`, `VSTest`, `dotnet test` → tests failed → **Step 2A**.
- A failed `Task` named `dotnet build`, `MSBuild`, `Build` → compile/restore error → **Step 2B** with that task's `logId`.
- The `issues` message is often unhelpful (e.g. `"PowerShell exited with code '1'"`).
  Don't trust it as the real error — it just points at the failed step.

## Step 2A — Test failures (Test Results API, no logs)

`ResultDetailsByBuild` returns *shallow* result objects (no message), but it gives
you the `testRun.id` of every failed test, which is what the detailed endpoints
need. The `test` area requires a **`-preview`** api-version.

```bash
# a. Distinct test-run ids that contain failures
az devops invoke --area test --resource ResultDetailsByBuild \
  --route-parameters project=<project> --query-parameters buildId=<buildId> \
  --api-version 7.1-preview -o json \
  | jq -c '[.resultsForGroup[].results[] | select(.outcome=="Failed") | .testRun.id] | unique'
```

```bash
# b. For each failing run id: test names + assertion messages (the actual error)
az devops invoke --area test --resource Results \
  --route-parameters project=<project> runId=<runId> \
  --query-parameters '$top=200' outcomes=Failed detailsToInclude=Text \
  --api-version 7.1-preview \
  --query "value[].{test:automatedTestName, msg:errorMessage}" -o json
```

`errorMessage` is usually enough to know what's wrong. When you need the **source
file and line** to make the fix, fetch the single result (it also carries
`stackTrace`):

```bash
# c. Optional: stack trace + source file:line for one result
#    (resultId comes from the same ResultDetailsByBuild call: .results[].id)
az devops invoke --area test --resource Results \
  --route-parameters project=<project> runId=<runId> testCaseResultId=<resultId> \
  --api-version 7.1-preview \
  --query "{test:automatedTestName, msg:errorMessage, stack:stackTrace}" -o json
```

The `stackTrace` contains lines like `... in /home/vsts/work/1/s/tests/<Project>/<File>.cs:line 25`
— strip the agent prefix (`/home/vsts/work/1/s/`) to get the repo-relative path.

## Step 2B — Build/compile errors, or no test results published

Fetch **only** the failed task's log (the `logId` from Step 1) and grep for markers
— never the whole build. `az devops invoke` returns the log as a JSON array of
timestamped lines, and the lines carry ANSI colour codes (`[31m`), so always pipe
through a filter:

```bash
az devops invoke --area build --resource Logs \
  --route-parameters project=<project> buildId=<buildId> logId=<logId> --api-version 7.1 -o json 2>/dev/null \
  | grep -iE "error (CS|MSB|NU)[0-9]|: error|build FAILED|\[FAIL\]|Assert|Expected|Unhandled exception" \
  | head -40
```

Tune the grep to the failure kind: `error CS####` (C# compiler), `error MSB####`
(MSBuild), `error NU####` (NuGet restore), `[FAIL]` / `Expected` (test output if it
landed in the log instead of the Test API).

If the log is still too big to reason about, save it and analyze out-of-context
rather than reading it inline:
```bash
az devops invoke --area build --resource Logs --route-parameters project=<project> buildId=<buildId> logId=<logId> --api-version 7.1 -o json > /tmp/ci-log-<logId>.json
```

## Reporting back

Summarize concisely: for each failure give the test/target name, the one-line
error, and the source `file:line`. Group identical root causes. Then state the fix
— don't paste raw logs into chat.

## Worked example (PR 53167, build 526959, project SmartER)
- `policy list` → `{buildId: 526959, status: "rejected"}`
- timeline → failed `Task` `Test (Microsoft Testing Platform)`, `logId: 67`, issue `"PowerShell exited with code '1'"` (unhelpful — go to the Test API)
- `ResultDetailsByBuild` → failing runs `275542`, `275544`
- `Results` per run → `SpannableTests.ApiModels_WhenCheckSpannableAttribute_ShouldDecorate` : *"Expected type ...Request to be decorated with SpannableAttribute, but the attribute was not found"*
- detail → `tests/.../Conventions/SpannableTests.cs:line 25`

## Notes
- Failing policy status is `rejected`; `approved` is green, `queued`/`running` not finished.
- The `test` area needs `--api-version 7.1-preview` (non-preview returns a "must supply -preview" error). The `build` area works with `7.1`.
- `ResultDetailsByBuild` result objects are intentionally shallow — use them only to discover `testRun.id` / result `id`, then call the detailed `Results` endpoints.
- Web link for the user: `https://dev.azure.com/edenred-emea-benefits/<project>/_build/results?buildId=<buildId>&view=ms.vss-test-web.build-test-results-tab`.
