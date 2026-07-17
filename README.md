# serena-forge

A Claude Code plugin that **forces symbolic C# editing through [Serena](https://github.com/oraios/serena)** and adds a **granular destructive-command guard**. It bundles the Serena MCP server, blocks freehand `.cs` writes so refactors are steered through Serena's Roslyn-aware symbol tools, and asks/denies on the specific destructive shell commands that hurt on a brownfield .NET solution.

Built for large, brownfield **.NET 10** codebases where "edit the right symbol" beats "rewrite the file", and where an accidental `git reset --hard` or `dotnet ef database drop` is expensive.

---

## What it does

| Capability | Mechanism |
| --- | --- |
| **Symbolic write/refactor** | `Edit`/`Write`/`MultiEdit` on `*.cs` are **DENIED** and redirected to Serena's symbol tools (`replace_symbol_body`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol`, …). |
| **Serena-first reading** | Native `Read` on `*.cs` stays **ALLOWED** and is not hook-prompted. A `SessionStart` context nudge tells onboarded Serena repos to prefer `get_symbols_overview` → `find_symbol` → `include_body` only on the target, and `find_referencing_symbols` over grep, without interrupting reconnaissance/exploration agents. |
| **Build safety net** | After every Serena symbolic edit, the touched `.csproj` is queued and compiled once with `dotnet build` at end of turn (`Stop` hook). A failed build **blocks the turn** and hands the compiler errors back to the agent to fix. This is the real guard-rail — not a graph. |
| **Granular destructive guard** | A Python `PreToolUse Bash` hook **DENYs catastrophic commands**, **ASKs for recoverable destructive commands**, and allows provably low-risk temp/generated cleanup (see below) instead of the coarse WARN-only default. |
| **Onboard on demand** | serena-forge is global, so it lands in un-onboarded repos. When C# work is requested where there's no `.serena/`, the agent is steered to **propose onboarding** (`/serena-forge-setup`) to the user and run it on agreement — never to route around the block. |
| **Bundled Serena MCP server** | The plugin ships the Serena MCP server config; enabling the plugin starts it. No separate `claude mcp add`. |

### Write-only enforcement, not read-blocking

Reading `.cs` with the native `Read` tool is deliberately left open — blocking reads would cripple the agent and provoke workarounds. What's enforced is the **write path preference**: C# mutations through native edit tools are denied as a safety backstop, steering the normal path through Serena so edits are symbol-scoped and Roslyn-validated rather than blind text replaces. The `SessionStart` navigation nudge handles the read side by preference, not by force.

### Destructive commands guarded (ASK / DENY)

- `rm -rf` / `rm -r` / `rm -fr` targeting `/` or `~`, and generic file deletion
- `git push --force` / `-f`, `git reset --hard`, `git clean -fd[x]`, `git checkout -- .`, `git branch -D`
- SQL `DROP` / `TRUNCATE`, and unqualified `DELETE` / `UPDATE`
- `dotnet ef database drop`

> **Coexistence with `dev-team`'s `destructive-guard.sh` (design decision: keep both, accept the duplicate line).**
> On a Bash call, both hooks fire on the same `rm` / `git` / SQL categories. They speak *different* protocols and do **not** contradict:
> - `destructive-guard.sh` uses the legacy protocol — by default it prints a `CAUTION: …` line and exits `0` (a warning, it does **not** block). It only hard-blocks (`exit 2`) when `/careful` mode is active.
> - `protect_commands.py` uses the modern protocol — it exits `0` with a `permissionDecision` of `ask`/`deny` in JSON. On the ALLOW majority it stays silent (never emits `"allow"`, so it never overrides other guards).
>
> Claude Code aggregates the guards and the strictest verdict wins (`deny` > `ask` > warn/allow), so the **effective** decision is always serena-forge's `ask`/`deny`. The cost is purely cosmetic: you'll see dev-team's `CAUTION:` line *in addition to* the serena-forge prompt. **This duplicate is expected and left in place on purpose** — we do not unwire `destructive-guard.sh` because it carries the `/careful` hard-block (`exit 2`) that serena-forge does not replicate, and it lives in the auto-updating plugin cache (any unwiring would be reverted on the next `dev-team` upgrade). Even under `/careful`, there is no conflict: serena-forge never emits `"allow"`, so dev-team's `exit 2` block still dominates.
>
> **Not overlapping:** serena-forge does **not** guard migration-**file** edits (`/Migrations/`, `*.Designer.cs`) — that's `block-migrations.sh` (an `Edit|Write` file guard, zero Bash overlap). And since no existing hook guards the *Bash* command `dotnet ef database drop`, serena-forge owns that one cleanly.

---

## Two design decisions (and why)

### 1. Write-only enforcement

**Decision:** deny `Edit`/`Write`/`MultiEdit` on `.cs`; leave `Read` allowed and unprompted; rely on session guidance rather than a read hook for Serena-first navigation.

**Why:** the goal is **discipline plus navigation**, not a sandbox. Forcing writes through Serena means every change is a scoped symbolic operation on a Roslyn-parsed tree — you rename a method and its references move, you replace a body without disturbing the file around it. Blocking reads too would only teach the agent to route around the guard; a `SessionStart` protocol that *prefers* symbolic reads gets the navigation benefit without the friction.

### 2. Global scope, no bypass

**Decision:** the `.cs` write protection is **active in every repo** the moment the plugin is enabled — not gated on the presence of a `.serena/` folder or any per-repo opt-in. There is **no built-in escape hatch** (no marker file, no env toggle).

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

3. **Work.** Use `/serena-navigate` to explore symbols and `/serena-refactor` to make symbolic edits. `.cs` writes via native tools will be denied with a message pointing you at Serena.

### Optional: pin the read discipline in `CLAUDE.md`

The `SessionStart` banner injects the Serena-first workflow every session, but a committed `CLAUDE.md` in the target repo makes it durable and reviewable. Paste this into the repo's `CLAUDE.md`:

```markdown
## C# navigation & editing (serena-forge)
- Do NOT `Read` whole `.cs` files. Workflow: `get_symbols_overview` → `find_symbol`
  → `include_body: true` only on the target symbol.
- Use `find_referencing_symbols` (real call sites via the LSP), not grep, for any
  change-impact analysis.
- Never edit `.cs` with Edit/Write/MultiEdit — use Serena's symbolic tools
  (`replace_symbol_body`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol`).
- A red `dotnet build` after an edit is unfinished work — fix it before stopping.
```

### Configuration (env vars)

| Var | Default | Effect |
| --- | --- | --- |
| `SERENA_FORGE_BUILD` | `1` | `0` disables the end-of-turn `dotnet build` safety net. |
| `SERENA_FORGE_BUILD_ON_FAIL` | `block` | `warn` reports build failures without blocking the Stop hook (useful for TDD/Superpowers red phase); `block` forces strict mode. |
| `SERENA_FORGE_TDD` | `0` | `1` enables report-only build failures for TDD red/green workflows. |

---

## When Serena can't make an edit

There is **no bypass** to reach for — that is deliberate (see Design decision #2). If Serena's LSP isn't ready or a change can't be made symbolically, the hooks and skills tell the agent to:

1. Wait out the normal ~30 s cold-init and retry once if it looks like a warm-up delay (see Pitfalls).
2. Otherwise **stop and ask you** — reporting the specific cause (LSP unavailable / timed out / `.NET 9` / change not expressible symbolically) — so you can either fix Serena or disable the hook. The agent never falls back to native `.cs` edits.

To turn enforcement off yourself, disable the plugin (or remove the `enforce_serena_write.py` hook entry). That is a human action, not something the agent does on its own.

---

## Components

### Hooks

| Hook | Event / matcher | What it does |
| --- | --- | --- |
| `hooks/enforce_serena_write.py` | `PreToolUse` · `Edit\|Write\|MultiEdit` | DENY native writes to `*.cs`; message redirects to Serena symbol/file edit tools and, on an un-onboarded repo, tells the agent to propose `/serena-forge-setup`. Non-`.cs` writes pass through. |
| `hooks/protect_commands.py` | `PreToolUse` · `Bash` | ASK/DENY on the destructive command set above. |
| `hooks/queue_build.py` | `PostToolUse` · Serena write tools | Cheap: resolves the nearest `.csproj` after symbol edits and Serena file edits (`create_text_file`, `replace_lines`, `insert_at_line`, `delete_lines`, `replace_content`, `replace_in_files`) and appends it to a per-repo temp build queue. No build here. |
| `hooks/flush_build_queue.py` | `Stop` | Drains the queue and runs one scoped `dotnet build --no-restore` per touched project. On failure, blocks by default, but reports-only in TDD/Superpowers mode (`SERENA_FORGE_TDD=1`, `SERENA_FORGE_BUILD_ON_FAIL=warn`, `SUPERPOWERS*`, `.superpowers/`, or `superpowers.md`). Opt out with `SERENA_FORGE_BUILD=0`. |
| `hooks/session_context.py` | `SessionStart` · `startup\|resume\|clear\|compact` | Injects the Serena-first navigation protocol (mandatory read workflow + build-net note) and, on an un-onboarded repo, the onboard-on-demand instruction. |

All hooks **fail open on their own malfunction**: an internal error or malformed payload results in *allow* — the plugin never blocks the user because of its own bug. This is internal robustness, not a user-facing bypass: it is never advertised to the agent as a way around the block, and it cannot be triggered on purpose.


### End-of-turn build in TDD / Superpowers

The build hook keeps its strong default for normal refactors: if touched C#
projects do not compile, the Stop hook blocks once and feeds compiler errors back
to the agent. TDD workflows intentionally spend time in the red phase, so the
Python hook downgrades build failures to report-only when it detects a TDD
context (`SERENA_FORGE_TDD=1`, `SERENA_FORGE_BUILD_ON_FAIL=warn`, any
`SUPERPOWERS*` environment variable, `.superpowers/`, or `superpowers.md`). To
force the strict gate even in those sessions, set `SERENA_FORGE_BUILD_ON_FAIL=block`.

### Skills

| Skill | Purpose |
| --- | --- |
| `/serena-forge-setup` | Onboard a repo: `activate_project`, set `ignored_paths` (`bin/`, `obj/`, `*.g.cs`, `*.Designer.cs`), **pre-index** (`serena project index`) to kill the first-`find_symbol` cold start, Serena onboarding, **.NET 9 refusal/warning**, wire `.gitignore` so memories are committed, verify the LSP is up. |
| `/serena-navigate` | Read & explore via Serena symbols (`get_symbols_overview`, `find_symbol`, `find_referencing_symbols`) — the read-side counterpart to the write block. |
| `/serena-refactor` | Perform symbolic edits/refactors (`replace_symbol_body`, `rename_symbol`, `insert_after_symbol`, `safe_delete_symbol`) — and **check the diff for CRLF/whitespace pollution** afterward (see Pitfalls). |

---

## Known pitfalls

1. **.NET 9 → LSP timeout.** Serena's Roslyn backend throws `System.TimeoutException` (a hardcoded ~10 s `BuildHost` timeout) on **.NET 9** projects. Use **.NET 10 only** — `/serena-forge-setup` warns/refuses on .NET 9 rather than letting you hang.

2. **~30 s cold init.** On large brownfield solutions, Serena waits up to ~30 s for Roslyn's `workspace/projectInitializationComplete` before it's ready. The first C# operation after activation can stall for that long (plus a one-time NuGet download of the language server). If the LSP isn't ready, wait and retry once — do not conclude a symbol is missing, and do not try to route around the write block.

3. **CRLF / `dotnet format` diff pollution.** A live end-of-turn formatter (`queue-format.sh` → `flush-format-queue.sh`, running `dotnet format`) reformats edited `.cs` files. When a repo's `.editorconfig` forces **CRLF** while some sources (e.g. `Program.cs`) are checked in as **LF**, a surgical Serena symbol edit gets amplified at turn-end into a whole-file CRLF/whitespace diff. After a `/serena-refactor`, **inspect the diff**; if it's polluted, commit with `--no-verify` and re-insert the intended change via `perl -i`. This is a formatter concern on the `PostToolUse`/`Stop` phase — it does not involve serena-forge's own hooks, but the refactor skill flags it.

---

## Repo housekeeping (`.gitignore`)

Serena writes a per-project `.serena/` folder (project config, memories, caches). In consuming repositories, ignore **only the cache**:

```gitignore
# Serena local state — ignore ONLY the machine-local index cache.
.serena/cache/
```

**Commit `.serena/project.yml` and `.serena/memories/`.** This is deliberate and is the whole persistence story:

- `project.yml` shares the Serena config (language, `ignored_paths`) with the team.
- **`memories/` is the persistence layer.** Committed memories let later sessions *read what the repo is* instead of re-exploring it from scratch — which is ~90% of the "memory" value people reach for graph tools (CodeGraph / codebase-memory-mcp) to get, without adding a second, less-reliable source of truth on top of Roslyn.

Only the `cache/` subfolder is machine-local and churny, so that's all you ignore. (If a team decides their memories carry repo-sensitive detail they don't want in git, that's a per-repo opt-out — but the default is: commit them.)

> **Why not just add a code graph too?** On large C# (Wolverine/DDD, heavy DI, extension methods, convention-discovered handlers) a tree-sitter graph mis-resolves or over-approximates edges that Roslyn resolves exactly, and it's read-only. Serena (LSP/Roslyn) is the single source of truth for **both read and write**, committed memories give you persistence, and the `dotnet build` hook gives you the safety net. The one case where a precomputed graph earns its keep is **frequent cross-repo exploration** ("who depends on this contract across the 6 repos?"), where it beats cold-starting a language server per repo — that's out of scope for this plugin, which is deliberately single-repo and Serena-only.

---

## Codex port (branch `codex-port`)

This branch also packages serena-forge as a **Codex plugin** while keeping the
Claude Code plugin files intact.

### Codex plugin layout

| File | Purpose |
| --- | --- |
| `.codex-plugin/plugin.json` | Required Codex plugin manifest for local/plugin-directory installation. |
| `.codex/config.toml` | Codex configuration sample: enables hooks and registers the same Serena MCP server through Codex's `mcp_servers.serena` TOML format. |
| `hooks/hooks.json` | Shared lifecycle hook bundle. Codex discovers this default hook file from the plugin root; Claude Code continues to use the same file. |
| `AGENTS.md` | Codex startup/session instructions that mirror the SessionStart hook: Serena-first C# navigation, Serena-only `.cs` mutation, onboarding on demand, build failures as unfinished work, and no command-guard workarounds. |

### What changes for Codex

- **Same Serena MCP server.** The Codex config launches Serena with `uvx -p 3.13
  --from git+https://github.com/oraios/serena serena start-mcp-server` and the
  bundled `contexts/serena-forge.yml` context.
- **Same hooks, Python implementation.** Codex exposes native edits to hooks as
  `apply_patch`, so `enforce_serena_write.py` scans patch headers as well as
  Claude Code `file_path` payloads. Hook commands now call Python scripts directly; the Bash entrypoints have been removed.
- **Command safety is strong without being noisy.** Catastrophic commands are
  denied, recoverable destructive commands ask for consent, and low-risk cleanup
  such as `/tmp`, `bin/`, `obj/`, `.cache`, generated C# artifacts, and source-generator output is allowed silently.
- **Auto session context.** The shared `SessionStart` hook still injects the
  Serena-first protocol. `AGENTS.md` duplicates the same rules in Codex's native
  repository instruction mechanism so a session starts with the right policy even
  before hook trust is reviewed.

### Local Codex usage

1. Install or enable this folder as a Codex plugin from your plugin directory or
   marketplace.
2. Review and trust the plugin hooks with `/hooks` when Codex prompts you.
3. If you are testing directly from this repository, trust the project-local
   `.codex/config.toml`; otherwise copy its `mcp_servers.serena` block into
   `~/.codex/config.toml` or a Codex profile.
4. Onboard each target .NET repo with the `serena-forge-setup` skill before the
   first C# edit.


### Python hook implementation

The active hook entrypoints in `hooks/hooks.json` call Python scripts directly. This removes the runtime dependency on Unix-only parsing tools such as `jq`, `awk`, `sed`, `wc`, `cksum`, and Bash-specific string features; the Bash entrypoints have been removed.

The relaxed-but-safe defaults are:

- native edits to `.cs` are denied as a safety backstop and steer agents to Serena file/symbol edit tools;
- `rm` under `/tmp` / `$TMPDIR`, build-output folders, caches, and generated
  artifacts is allowed silently;
- catastrophic deletes such as recursive forced removal of `/`, `~`, `$HOME`, or
  `--no-preserve-root` are still denied;
- recoverable destructive operations (`git reset --hard`, `git clean -f`, force
  pushes, database drops, unqualified SQL updates/deletes, and non-low-risk file
  deletion) ask for user confirmation.
