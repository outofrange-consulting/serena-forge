# serena-forge

A Claude Code plugin that **forces symbolic C# editing through [Serena](https://github.com/oraios/serena)** and adds a **granular destructive-command guard**. It bundles the Serena MCP server, blocks freehand `.cs` writes so refactors go through Serena's Roslyn-aware symbol tools, and asks/denies on the specific destructive shell commands that hurt on a brownfield .NET solution.

Built for large, brownfield **.NET 10** codebases where "edit the right symbol" beats "rewrite the file", and where an accidental `git reset --hard` or `dotnet ef database drop` is expensive.

---

## What it does

| Capability | Mechanism |
| --- | --- |
| **Symbolic write/refactor** | `Edit`/`Write`/`MultiEdit` on `*.cs` are **DENIED** and redirected to Serena's symbol tools (`replace_symbol_body`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol`, …). |
| **Serena-first reading** | Native `Read` on `*.cs` stays **ALLOWED**, but a `SessionStart` hook pushes a navigation protocol: reach for `get_symbols_overview` / `find_symbol` / `find_referencing_symbols` before dumping whole files. |
| **Granular destructive guard** | A `PreToolUse Bash` hook **ASKs/DENYs** on a precise set of destructive commands (see below) instead of the coarse WARN-only default. |
| **Bundled Serena MCP server** | The plugin ships the Serena MCP server config; enabling the plugin starts it. No separate `claude mcp add`. |

### Write-only enforcement, not read-blocking

Reading `.cs` with the native `Read` tool is deliberately left open — blocking reads would cripple the agent and provoke workarounds. What's enforced is the **write path**: every mutation of C# goes through Serena so edits are symbol-scoped and Roslyn-validated, never a blind text replace. The `SessionStart` navigation nudge handles the read side by preference, not by force.

### Destructive commands guarded (ASK / DENY)

- `rm -rf` / `rm -r` / `rm -fr` targeting `/` or `~`, and generic file deletion
- `git push --force` / `-f`, `git reset --hard`, `git clean -fd[x]`, `git checkout -- .`, `git branch -D`
- SQL `DROP` / `TRUNCATE`, and unqualified `DELETE` / `UPDATE`
- `dotnet ef database drop`

> **Coexistence with `dev-team`'s `destructive-guard.sh` (design decision: keep both, accept the duplicate line).**
> On a Bash call, both hooks fire on the same `rm` / `git` / SQL categories. They speak *different* protocols and do **not** contradict:
> - `destructive-guard.sh` uses the legacy protocol — by default it prints a `CAUTION: …` line and exits `0` (a warning, it does **not** block). It only hard-blocks (`exit 2`) when `/careful` mode is active.
> - `protect-commands.sh` uses the modern protocol — it exits `0` with a `permissionDecision` of `ask`/`deny` in JSON. On the ALLOW majority it stays silent (never emits `"allow"`, so it never overrides other guards).
>
> Claude Code aggregates the guards and the strictest verdict wins (`deny` > `ask` > warn/allow), so the **effective** decision is always serena-forge's `ask`/`deny`. The cost is purely cosmetic: you'll see dev-team's `CAUTION:` line *in addition to* the serena-forge prompt. **This duplicate is expected and left in place on purpose** — we do not unwire `destructive-guard.sh` because it carries the `/careful` hard-block (`exit 2`) that serena-forge does not replicate, and it lives in the auto-updating plugin cache (any unwiring would be reverted on the next `dev-team` upgrade). Even under `/careful`, there is no conflict: serena-forge never emits `"allow"`, so dev-team's `exit 2` block still dominates.
>
> **Not overlapping:** serena-forge does **not** guard migration-**file** edits (`/Migrations/`, `*.Designer.cs`) — that's `block-migrations.sh` (an `Edit|Write` file guard, zero Bash overlap). And since no existing hook guards the *Bash* command `dotnet ef database drop`, serena-forge owns that one cleanly.

---

## Two design decisions (and why)

### 1. Write-only enforcement

**Decision:** deny `Edit`/`Write`/`MultiEdit` on `.cs`; leave `Read` allowed.

**Why:** the goal is **discipline plus navigation**, not a sandbox. Forcing writes through Serena means every change is a scoped symbolic operation on a Roslyn-parsed tree — you rename a method and its references move, you replace a body without disturbing the file around it. Blocking reads too would only teach the agent to route around the guard; a `SessionStart` protocol that *prefers* symbolic reads gets the navigation benefit without the friction.

### 2. Global scope, no bypass

**Decision:** the `.cs` write block is **active in every repo** the moment the plugin is enabled — not gated on the presence of a `.serena/` folder or any per-repo opt-in. There is **no built-in escape hatch** (no marker file, no env toggle).

**Why:** brownfield .NET work spans many repos and worktrees; a per-repo gate means the discipline silently lapses wherever setup was skipped — exactly the repos that need it most. Global-on makes the safe path the default. And a documented bypass is a bypass the agent will reach for under pressure — so when Serena genuinely can't make an edit, the plugin tells the agent to **stop and ask the user** to fix Serena or disable the hook, rather than working around the block. Enforcement is only turned off by a human (disable the plugin, or remove the hook), never by the agent mid-task.

---

## Prerequisites

- **`uvx`** on `PATH` (from [uv](https://github.com/astral-sh/uv)) — the bundled server launches Serena via `uvx`.
- **.NET SDK 10.0+** — Serena's C# backend is the Roslyn-based `Microsoft.CodeAnalysis.LanguageServer`, which requires .NET 10+. **.NET 9 is not supported** (see Pitfalls).
- Serena downloads the Roslyn language server from NuGet automatically on first C# use — first activation on a large solution is slow (see Pitfalls).

Verified on this box: `uvx` present, `dotnet 10.0.301`, Ubuntu 24.04 / WSL2.

---

## Install / enable

1. **Enable the plugin.** Point Claude Code at wherever the plugin lives (marketplace or local path) and enable `serena-forge`. Enabling it also **starts the bundled Serena MCP server** — there is no separate MCP registration step.

   The bundled server launches roughly as:

   ```
   uvx -p 3.13 --from git+https://github.com/oraios/serena \
     serena start-mcp-server --context claude-code
   ```

   (`stdio` is the default transport; no `--transport` flag needed.)

2. **Onboard the current repo.** Run **`/serena-forge-setup`** in the target repository. It activates the project for Serena (`activate_project`), runs Serena onboarding, and **refuses / warns on .NET 9** projects before you hit the LSP timeout. Because the plugin is global, the project isn't hardcoded in the server config — the setup skill activates whichever repo you're in.

3. **Work.** Use `/serena-navigate` to explore symbols and `/serena-refactor` to make symbolic edits. `.cs` writes via the native tools will be denied with a message pointing you at Serena.

---

## When Serena can't make an edit

There is **no bypass** to reach for — that is deliberate (see Design decision #2). If Serena's LSP isn't ready or a change can't be made symbolically, the hooks and skills tell the agent to:

1. Wait out the normal ~30 s cold-init and retry once if it looks like a warm-up delay (see Pitfalls).
2. Otherwise **stop and ask you** — reporting the specific cause (LSP unavailable / timed out / `.NET 9` / change not expressible symbolically) — so you can either fix Serena or disable the hook. The agent never falls back to native `.cs` edits.

To turn enforcement off yourself, disable the plugin (or remove the `enforce-serena-write.sh` hook entry). That is a human action, not something the agent does on its own.

---

## Components

### Hooks

| Hook | Event / matcher | What it does |
| --- | --- | --- |
| `hooks/enforce-serena-write.sh` | `PreToolUse` · `Edit\|Write\|MultiEdit` | DENY writes to `*.cs`; message redirects to Serena symbol tools. Non-`.cs` writes pass through. |
| `hooks/protect-commands.sh` | `PreToolUse` · `Bash` | ASK/DENY on the destructive command set above. |
| `hooks/session-context.sh` | `SessionStart` · `startup\|resume\|clear\|compact` | Injects the Serena-first navigation protocol into the session. |

All hooks **fail open on their own malfunction**: an internal error or a missing dependency (e.g. `jq`) results in *allow* — the plugin never blocks the user because of its own bug. This is internal robustness, not a user-facing bypass: it is never advertised to the agent as a way around the block, and it cannot be triggered on purpose.

### Skills

| Skill | Purpose |
| --- | --- |
| `/serena-forge-setup` | Onboard a repo: `activate_project`, Serena onboarding, **.NET 9 refusal/warning**, verify the LSP is up. |
| `/serena-navigate` | Read & explore via Serena symbols (`get_symbols_overview`, `find_symbol`, `find_referencing_symbols`) — the read-side counterpart to the write block. |
| `/serena-refactor` | Perform symbolic edits/refactors (`replace_symbol_body`, `rename_symbol`, `insert_after_symbol`, `safe_delete_symbol`) — and **check the diff for CRLF/whitespace pollution** afterward (see Pitfalls). |

---

## Known pitfalls

1. **.NET 9 → LSP timeout.** Serena's Roslyn backend throws `System.TimeoutException` (a hardcoded ~10 s `BuildHost` timeout) on **.NET 9** projects. Use **.NET 10 only** — `/serena-forge-setup` warns/refuses on .NET 9 rather than letting you hang.

2. **~30 s cold init.** On large brownfield solutions, Serena waits up to ~30 s for Roslyn's `workspace/projectInitializationComplete` before it's ready. The first C# operation after activation can stall for that long (plus a one-time NuGet download of the language server). If the LSP isn't ready, wait and retry once — do not conclude a symbol is missing, and do not try to route around the write block.

3. **CRLF / `dotnet format` diff pollution.** A live end-of-turn formatter (`queue-format.sh` → `flush-format-queue.sh`, running `dotnet format`) reformats edited `.cs` files. a corporate `.editorconfig` forces **CRLF** while some sources (e.g. `Program.cs`) are **LF**, so a surgical Serena symbol edit gets amplified at turn-end into a whole-file CRLF/whitespace diff. After a `/serena-refactor`, **inspect the diff**; if it's polluted, commit with `--no-verify` and re-insert the intended change via `perl -i`. This is a formatter concern on the `PostToolUse`/`Stop` phase — it does not involve serena-forge's own hooks, but the refactor skill flags it.

4. **husky offline (unrelated, avoid making it worse).** some repos have husky `pre-commit`/`pre-push` hooks that fail offline (npx can't install). serena-forge does not touch these — but **don't add npm/husky dependencies** to work around Serena; that's out of scope and makes the offline problem worse.

---

## Repo housekeeping (`.gitignore`)

Serena writes a per-project `.serena/` folder (project config, memories, caches). In consuming repositories, add at minimum:

```gitignore
# Serena local state
.serena/cache/
.serena/memories/
```

Keep `.serena/project.yml` **tracked** if you want the project's Serena config shared with the team; ignore the `cache/` and `memories/` subfolders, which are machine-local and churny.
