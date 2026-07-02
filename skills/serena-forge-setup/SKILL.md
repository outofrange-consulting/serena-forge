---
name: serena-forge-setup
description: >-
  Onboard the CURRENT repository with Serena so its Roslyn-backed symbolic
  read/edit tools work. Activates the project, runs Serena onboarding, waits for
  the first index, verifies the C# language server came up, and explains the
  .NET 10-only rule and the anti-deadlock escape hatch. Serena handles symbols
  in the current repo; codebase-memory-mcp (cbm) stays for cross-repo work.
when_to_use: >-
  Trigger when the user says "onboard serena", "onboard this repo", "set up
  serena here", "index this repo with serena", "activate serena", "serena isn't
  working", "serena can't find symbols", "why is serena stalling", or a Serena
  symbolic tool (find_symbol / replace_symbol_body) errors or returns nothing on
  a repo that was never onboarded.
user-invocable: true
allowed-tools: "Bash Read Grep Glob"
---

# Serena Forge — onboard the current repo

Serena gives symbol-level **read and edit** tools (find/rename/replace a symbol,
find references) for the repo you are in right now. `serena-forge` enforces this
globally: direct `Edit`/`Write`/`MultiEdit` on `.cs` files is DENIED and you are
redirected to Serena's symbolic edits. So a repo you actually want to change in
C# must be onboarded first, or you cannot edit its `.cs` files at all (except via
the escape hatch below).

This skill onboards **one repo** — the current working directory.

## Division of labour — cbm stays, do NOT drop it

`serena-forge` does **not** replace `codebase-memory-mcp`. They cover different
jobs; keep both:

| Use `cbm` (global, multi-repo) | Use Serena (current repo, symbol-level) |
| --- | --- |
| Architecture overview, package/service map | Read one symbol's body / signature |
| Complexity, hot paths, dead-code, Cypher queries | Find references / implementations of a symbol |
| Cross-service / cross-repo impact analysis | Rename / replace / insert a symbol (edits) |
| "Where does X live across 29 repos?" | "Edit method Foo in THIS repo safely" |

Rule of thumb: **explore and reason with cbm; read-precisely-and-edit with
Serena.** Never tell the agent to abandon cbm — onboarding a repo with Serena is
additive.

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
backend — keep reading it with `cbm` and native `Read`, and use the escape hatch
if you need to edit its `.cs` files. (`net10.0` and mixed solutions where the
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

3. **Run onboarding.** Call the `onboarding` tool. This inspects the project and
   writes Serena's initial project memories (structure, build/test commands,
   conventions) into `.serena/memories/`. You can confirm what it wrote with
   `list_memories`, and read Serena's own guidance with `initial_instructions`.

4. **Wait for the first index (~30s) — do not retry.** Roslyn indexes the whole
   solution and emits a `workspace/projectInitializationComplete` notification
   when done; Serena waits up to **~30 seconds** for it before treating the
   server as ready. On a large brownfield solution the first symbolic call can
   sit near that limit while the Roslyn LS package downloads from NuGet
   (`Microsoft.CodeAnalysis.LanguageServer.linux-x64` on this box) and indexes.
   **This wait is normal — do not hammer retries, and do not conclude Serena is
   broken before ~30s have elapsed.**

5. **Verify the C# LSP actually came up.** Run a cheap symbolic read as a smoke
   test — call `get_symbols_overview` on one real `.cs` file (a small
   `Program.cs` or any class file). Success (a list of symbols) means Roslyn is
   live and you may now use all Serena read/edit tools. Alternatives:
   `find_symbol` for a class you know exists, or `get_diagnostics_for_file`.
   - A `System.TimeoutException` here almost always means either (a) a
     non-`net10.0` project slipped in — recheck step 1, or (b) the ~30s init has
     not finished — wait once more, then smoke-test again.
   - If it keeps timing out on a confirmed `net10.0` repo, treat the LSP as
     unavailable: use the **escape hatch**, fall back to `cbm` + native `Read`,
     and tell the user rather than looping.

6. **Confirm state** any time with `get_current_config` (shows the active
   project and config).

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

## Escape hatch — never deadlock

Because `.cs` writes are blocked globally, a repo where Serena's LSP won't come
up (the ~30s init never completes, a .NET 9 project, a Roslyn download failure)
would otherwise leave you unable to edit any `.cs` file. The escape hatch is the
safety valve — it disables `serena-forge`'s write-blocking so native
`Edit`/`Write` on `.cs` work again. Two forms:

```bash
# Per-directory, temporary: drop a marker in the current repo.
touch .serena-forge-off      # remove it to re-enable the guard

# Session-wide: export the env var before starting Claude Code.
export SERENA_FORGE_OFF=1
```

Either one turns the guard off. Use it when onboarding genuinely can't succeed —
do **not** use it to skip onboarding out of impatience during the normal ~30s
first-index wait. When you use the escape hatch, say so, and prefer `cbm` +
native `Read` for understanding the code while Serena is unavailable.

## Pitfall — Serena `.cs` edits get reformatted at end of turn

Not a setup step, but flag it while onboarding a .NET repo: a live PostToolUse +
Stop formatter (`queue-format.sh` → `flush-format-queue.sh`, running
`dotnet format`) reformats every edited `.cs` file at turn-end. On a corporate repos
`.editorconfig` forces CRLF, so a surgical Serena symbolic edit can be amplified
into a whole-file CRLF/whitespace diff. This is handled by the **serena-refactor**
skill (check the diff; commit `--no-verify` and re-insert via `perl -i` if the
diff is polluted) — mention it, but don't try to disable the formatter here. Do
not add npm/husky dependencies to work around unrelated offline pre-commit hooks.
