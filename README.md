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

### 2. Global scope

**Decision:** the `.cs` write block is **active in every repo** the moment the plugin is enabled — not gated on the presence of a `.serena/` folder or any per-repo opt-in.

**Why:** brownfield .NET work spans many repos and worktrees; a per-repo gate means the discipline silently lapses wherever setup was skipped — exactly the repos that need it most. Global-on makes the safe path the default. The **escape hatch** (below) is the anti-deadlock safety valve — reach for it when Serena's LSP isn't ready or you genuinely need raw edits — rather than making every repo opt in.

---

## Coexistence with `codebase-memory-mcp`

serena-forge **does not replace** `codebase-memory-mcp` (cbm). They are complementary and both stay wired. Keep using cbm for what it's good at; use Serena for symbol-level work in the repo you're actually editing.

| Question / task | Use | Why |
| --- | --- | --- |
| Architecture overview, package/service map, clusters | **cbm** (`get_architecture`) | Global multi-repo graph |
| Complexity / hot-path / dead-code / refactor candidates | **cbm** (`query_graph` Cypher) | Precomputed metrics across the whole index |
| Cross-service / cross-repo impact, call chains between services | **cbm** (`trace_path`, cross-repo edges) | Spans repos serena can't see |
| "Who calls this?" **within the current repo** | **Serena** (`find_referencing_symbols`) | Roslyn-accurate, live |
| Read / navigate a symbol in the current repo | **Serena** (`get_symbols_overview`, `find_symbol`) | Precise symbol tree, not text |
| Edit / rename / delete / refactor a C# symbol | **Serena** (write tools) | The only allowed C# write path here |
| Broad structural discovery before you know where code lives | **cbm** first, then **Serena** to act | cbm points, Serena operates |

**Rule of thumb:** cbm answers *"where and how big"* across all repos; Serena answers *"read/change this exact symbol"* in the current one. Never drop cbm in favour of Serena — they run side by side.

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

## Escape hatch (anti-deadlock)

If Serena's LSP isn't ready (see the ~30 s init pitfall) or you truly need raw `.cs` edits, disable enforcement. The guards **fail open** on this signal, so you never get stuck:

- **Marker file:** create `.serena-forge-off` in the current working directory, **or**
- **Env var:** set `SERENA_FORGE_OFF=1`.

Either one disables both the `.cs` write block and the destructive-command guard for that session/cwd.

Convenience commands:

| Command | Effect |
| --- | --- |
| `/forge-off` | Drop the `.serena-forge-off` marker (enforcement off in this repo) |
| `/forge-on` | Remove the marker (enforcement back on) |

> The escape hatch is a **safety valve**, not the per-repo opt-in — enforcement is global-on by design (see Design decision #2). Turn it off deliberately, turn it back on when done.

---

## Components

### Hooks

| Hook | Event / matcher | What it does |
| --- | --- | --- |
| `hooks/enforce-symbolic-edit.sh` | `PreToolUse` · `Edit\|Write\|MultiEdit` | DENY writes to `*.cs`; message redirects to Serena symbol tools. Non-`.cs` writes pass through. |
| `hooks/protect-commands.sh` | `PreToolUse` · `Bash` | ASK/DENY on the destructive command set above. |
| `hooks/serena-first.sh` | `SessionStart` · `startup\|resume\|clear\|compact` | Injects the Serena-first navigation protocol into the session. |

All hooks **fail open**: any internal error, a missing dependency, the `.serena-forge-off` marker, or `SERENA_FORGE_OFF=1` results in *allow* — the plugin never blocks the user on its own malfunction.

### Skills / commands

| Skill / command | Purpose |
| --- | --- |
| `/serena-forge-setup` | Onboard a repo: `activate_project`, Serena onboarding, **.NET 9 refusal/warning**, verify the LSP is up. |
| `/serena-navigate` | Read & explore via Serena symbols (`get_symbols_overview`, `find_symbol`, `find_referencing_symbols`) — the read-side counterpart to the write block. |
| `/serena-refactor` | Perform symbolic edits/refactors (`replace_symbol_body`, `rename_symbol`, `insert_after_symbol`, `safe_delete_symbol`) — and **check the diff for CRLF/whitespace pollution** afterward (see Pitfalls). |
| `/forge-off`, `/forge-on` | Toggle the escape hatch. |

---

## Known pitfalls

1. **.NET 9 → LSP timeout.** Serena's Roslyn backend throws `System.TimeoutException` (a hardcoded ~10 s `BuildHost` timeout) on **.NET 9** projects. Use **.NET 10 only** — `/serena-forge-setup` warns/refuses on .NET 9 rather than letting you hang.

2. **~30 s cold init.** On large brownfield solutions, Serena waits up to ~30 s for Roslyn's `workspace/projectInitializationComplete` before it's ready. The first C# operation after activation can stall for that long (plus a one-time NuGet download of the language server). This slow-start is **precisely why the escape hatch exists** — if the LSP isn't ready and you're blocked, `/forge-off` and proceed.

3. **CRLF / `dotnet format` diff pollution.** A live end-of-turn formatter (`queue-format.sh` → `flush-format-queue.sh`, running `dotnet format`) reformats edited `.cs` files. a corporate `.editorconfig` forces **CRLF** while some sources (e.g. `Program.cs`) are **LF**, so a surgical Serena symbol edit gets amplified at turn-end into a whole-file CRLF/whitespace diff. After a `/serena-refactor`, **inspect the diff**; if it's polluted, commit with `--no-verify` and re-insert the intended change via `perl -i` (or drain/re-check the format queue). This is a formatter concern on the `PostToolUse`/`Stop` phase — it does not involve serena-forge's own hooks, but the refactor skill flags it.

4. **husky offline (unrelated, avoid making it worse).** some repos have husky `pre-commit`/`pre-push` hooks that fail offline (npx can't install). serena-forge does not touch these — but **don't add npm/husky dependencies** to work around Serena; that's out of scope and makes the offline problem worse.

---

## Repo housekeeping (`.gitignore`)

Serena writes a per-project `.serena/` folder (project config, memories, caches) and this plugin uses a local `.serena-forge-off` marker. In consuming repositories, add at minimum:

```gitignore
# serena-forge / Serena local state
.serena-forge-off
.serena/cache/
.serena/memories/
```

Keep `.serena/project.yml` **tracked** if you want the project's Serena config shared with the team; ignore the `cache/` and `memories/` subfolders, which are machine-local and churny. The `.serena-forge-off` marker is always machine-local — never commit it (committing it would silently disable enforcement for everyone).
