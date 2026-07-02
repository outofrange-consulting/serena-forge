---
name: serena-forge-setup
description: >-
  Onboard the CURRENT repository with Serena so its Roslyn-backed symbolic
  read/edit tools work. Activates the project, runs Serena onboarding, waits for
  the first index, verifies the C# language server came up, and explains the
  .NET 10-only rule.
when_to_use: >-
  Trigger when the user says "onboard serena", "onboard this repo", "set up
  serena here", "index this repo with serena", "activate serena", "serena isn't
  working", "serena can't find symbols", "why is serena stalling", or a Serena
  symbolic tool (find_symbol / replace_symbol_body) errors or returns nothing on
  a repo that was never onboarded.
user-invocable: true
allowed-tools: "Bash Read Grep Glob Edit Write"
---

# Serena Forge — onboard the current repo

Serena gives symbol-level **read and edit** tools (find/rename/replace a symbol,
find references) for the repo you are in right now. `serena-forge` enforces this
globally: direct `Edit`/`Write`/`MultiEdit` on `.cs` files is DENIED and you are
redirected to Serena's symbolic edits. So a repo you actually want to change in
C# must be onboarded first, or you cannot edit its `.cs` files at all.

This skill onboards **one repo** — the current working directory.

## STOP — the .NET 10-only rule (read this first)

Serena's C# backend is the Roslyn **Microsoft.CodeAnalysis.LanguageServer**,
which **requires .NET 10 or newer**.

> **WARNING — do NOT onboard a .NET 9 (or older) project.**
> On .NET 9 Roslyn's `BuildHostProcessManager` throws a
> `System.TimeoutException` (hardcoded ~10s BuildHost connect timeout — Serena
> issue #513). Onboarding will appear to hang for ~10s and then fail, and every
> subsequent symbolic call fails the same way. There is no workaround inside
> Serena short of downgrading to .NET 8. **The C# LSP will not come up. Do not
> force it.**

This machine has **.NET 10.0.301**, which satisfies the requirement — but the
SDK version does not matter; the **project's target framework** does. Check it
before onboarding:

```bash
# Any project targeting net9.0 or lower => DO NOT onboard.
grep -rEn '<TargetFrameworks?>' --include='*.csproj' . 2>/dev/null
# Also check the pinned SDK / any global.json test-runner settings:
[ -f global.json ] && cat global.json
```

If **any** `.cs` project you need to touch targets `net9.0`, `net8.0`, or lower,
STOP and tell the user: this repo cannot be onboarded with Serena's Roslyn
backend, and ask them how to proceed (fix Serena's requirements or disable the
serena-forge hook for this repo). (`net10.0` and mixed solutions where the
projects you edit are all `net10.0+` are fine.)

## Onboarding steps

The Serena MCP server is provided by the plugin and starts automatically. You do
not run `uvx` by hand — you drive it through the MCP tools below. (For reference,
the bundled server launches as
`uvx -p 3.13 --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code`,
with no `--project` — the plugin is repo-agnostic, so the project is bound at
runtime via `activate_project` in step 2 below, not pinned at launch.)

1. **Confirm the framework** with the grep above. If it is not `net10.0+`, STOP
   (see the .NET 10-only rule).

2. **Activate the current repo.** Call the `activate_project` tool with the
   **absolute** path to the repo root (use `pwd` to get it — always absolute,
   never relative). This registers the project and points Serena's LSP at it.
   Activation creates `.serena/project.yml`.

3. **Set `ignored_paths` before indexing.** Exclude build output and generated
   code from the scan so the index is smaller and faster and `find_symbol` never
   surfaces generated noise. Add these to `.serena/project.yml` (create the
   `ignored_paths:` block if it isn't there):

   ```yaml
   # .serena/project.yml
   ignored_paths:
     - "**/bin/**"
     - "**/obj/**"
     - "**/*.g.cs"           # generated
     - "**/*.Designer.cs"    # designer-generated
     - "**/*.AssemblyInfo.cs"
     - "**/node_modules/**"  # if the repo has any JS tooling
   ```

4. **Pre-index the repo (avoid the first-`find_symbol` cold start).** Build
   Serena's symbol index up front so the first symbolic call in a real session
   doesn't pay Roslyn's cold start. Run the CLI once from the repo root:

   ```bash
   uvx -p 3.13 --from git+https://github.com/oraios/serena \
     serena project index "$(pwd)"
   ```

   On a large brownfield solution this can take a while (it downloads the Roslyn
   language server from NuGet on first use and walks the whole tree) — that is the
   cost you are paying *now* instead of on the user's first query. If it errors on
   a `.NET 9` target, that's the same .NET 10-only issue (step 1) — do not force it.

5. **Run onboarding.** Call the `onboarding` tool. This inspects the project and
   writes Serena's initial project memories (structure, build/test commands,
   conventions) into `.serena/memories/`. You can confirm what it wrote with
   `list_memories`, and read Serena's own guidance with `initial_instructions`.
   These memories are meant to be **committed** — they are the persistence layer
   that lets later sessions skip re-exploration (see "Repo housekeeping" below).

6. **Wait for the first index (~30s) — do not retry.** Roslyn indexes the whole
   solution and emits a `workspace/projectInitializationComplete` notification
   when done; Serena waits up to **~30 seconds** for it before treating the
   server as ready. On a large brownfield solution the first symbolic call can
   sit near that limit while the Roslyn LS package downloads from NuGet
   (`Microsoft.CodeAnalysis.LanguageServer.linux-x64` on this box) and indexes.
   **This wait is normal — do not hammer retries, and do not conclude Serena is
   broken before ~30s have elapsed.**

7. **Verify the C# LSP actually came up.** Run a cheap symbolic read as a smoke
   test — call `get_symbols_overview` on one real `.cs` file (a small
   `Program.cs` or any class file). Success (a list of symbols) means Roslyn is
   live and you may now use all Serena read/edit tools. Alternatives:
   `find_symbol` for a class you know exists, or `get_diagnostics_for_file`.
   - A `System.TimeoutException` here almost always means either (a) a
     non-`net10.0` project slipped in — recheck step 1, or (b) the ~30s init has
     not finished — wait once more, then smoke-test again.
   - If it keeps timing out on a confirmed `net10.0` repo, treat the LSP as
     unavailable and **stop and tell the user** (ask them to fix Serena or
     disable the serena-forge hook) rather than looping or working around it.

8. **Wire `.gitignore` so memories are committed.** Ensure the repo ignores only
   Serena's churny cache and keeps `project.yml` + `memories/` tracked. Append
   this block if it isn't already present (do not clobber an existing
   `.gitignore` — only add the missing lines):

   ```gitignore
   # Serena local state — ignore ONLY the machine-local index cache.
   # Keep .serena/project.yml and .serena/memories/ tracked (committed memories =
   # the persistence layer; later sessions read them instead of re-exploring).
   .serena/cache/
   ```

   Then `git add .serena/project.yml .serena/memories/` so the onboarding output
   is captured for the team. (Skip committing memories only if the user says
   their memories may contain repo-sensitive detail they don't want in git.)

9. **Confirm state** any time with `get_current_config` (shows the active
   project and config).

## Onboarding on demand (repo not yet initialized)

serena-forge is global, so you will land in repos that were never onboarded.
Because `.cs` writes are blocked everywhere, an un-onboarded repo cannot be
edited until this skill runs. When C# work is requested in such a repo (no
`.serena/` folder), **propose onboarding to the user and run this skill once they
agree** — the SessionStart banner and the write-block message both steer you
here. Do not silently skip onboarding, and never fall back to a native `.cs`
edit to route around the block.

## What `.serena/` contains

Onboarding creates a `.serena/` folder in the repo root:

- **`project.yml`** — the per-project Serena config (language `csharp`, ignored
  paths, etc.).
- **`project.local.yml`** — optional local overrides (not committed).
- **`memories/`** — the project memories written by `onboarding` and by
  `write_memory` (one markdown file per fact; managed with `read_memory`,
  `edit_memory`, `rename_memory`, `delete_memory`).
- **language-server caches** — speed up subsequent indexing.

It is per-repo and self-contained. Global Serena config lives separately at
`~/.serena/serena_config.yml` (auto-created; edit with `serena config edit`). To
un-onboard a repo, call `remove_project`; deleting `.serena/` also resets it.

## When onboarding can't succeed

Because `.cs` writes are blocked globally, a repo where Serena's LSP won't come
up (the ~30s init never completes, a .NET 9 project, a Roslyn download failure)
leaves you unable to edit its `.cs` files. There is **no bypass** — do not route
around the write block.

- If it's the normal ~30s first-index wait, let it finish and retry; don't
  conclude failure prematurely.
- If onboarding genuinely fails (`.NET 9`, the LSP never comes up, a download
  error), **stop and tell the user** what failed and ask them to fix Serena or
  disable the serena-forge hook. Report the specific cause; don't loop or fall
  back to native edits.

## Pitfall — Serena `.cs` edits get reformatted at end of turn

Not a setup step, but flag it while onboarding a .NET repo: a live PostToolUse +
Stop formatter (`queue-format.sh` → `flush-format-queue.sh`, running
`dotnet format`) reformats every edited `.cs` file at turn-end. On a corporate repos
`.editorconfig` forces CRLF, so a surgical Serena symbolic edit can be amplified
into a whole-file CRLF/whitespace diff. This is handled by the **serena-refactor**
skill (check the diff; commit `--no-verify` and re-insert via `perl -i` if the
diff is polluted) — mention it, but don't try to disable the formatter here. Do
not add npm/husky dependencies to work around unrelated offline pre-commit hooks.
