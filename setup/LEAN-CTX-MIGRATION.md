# Migrating the stack to lean-ctx

This document explains what `setup/install-wsl.sh` (lean-ctx edition) changes, why,
and the decision points you can steer with flags. It is the writeup behind the
script — read it once, then the script is self-service.

## TL;DR

`lean-ctx` (one Rust binary, [leanctx.com](https://leanctx.com)) replaces the
three-tool compression layer — **ctx-wire + caveman + ponytail** — and adds a
memory/knowledge and code-intelligence layer on top. Everything else in the
workstation is kept: **Serena** (Roslyn C# editing), **CodeGraph** (cross-repo
graph), **dev-team**, the **second-brain** vault, and the domain CLIs.

The install script installs and configures lean-ctx, **migrates an old box away**
from the obsolete tools, and the `serena-forge` plugin (bumped to v0.3.0) ships
the new guard hooks. Re-running the script converges any box onto the new stack.

## What lean-ctx replaces — and what it does not

| Component | Verdict | Why |
| --- | --- | --- |
| **ctx-wire** | ✅ Removed | lean-ctx's shell-compression modules + 10 read modes supersede it. Its only remaining edge was French .NET filters — neutralized by forcing English .NET output (below). |
| **caveman** | ✅ Removed | Compression is native in lean-ctx (content-addressed cache, ~13-token cached re-reads, pressure auto-downgrade). |
| **ponytail** | ✅ Removed | Tool profiles (minimal/standard/power) + pressure-based degradation cover the "don't over-fetch" role. |
| **CodeGraph** | ❌ Kept | lean-ctx cannot replace it: its graph is keyed to a single `project_root`, and its multi-repo feature is cross-repo **search** (RRF fusion), not a graph. `dev-team` also targets `mcp__codegraph__*` directly from 3 hooks, 2 agents and 4 skills. Kept as the one root index over `CODE_ROOT`. |
| **RTK** | ✅ Skipped | Redundant with lean-ctx — same job (compress/dedup/truncate/filter shell output), different layer. tokbench shows no stacking benefit and added latency. See "RTK" below. |
| **Serena** | ❌ Kept | lean-ctx is tree-sitter (syntactic); Serena is **Roslyn** (the real C# compiler). No contest for C# symbol edits/refactors/diagnostics. lean-ctx has zero .NET/Roslyn awareness. |
| **second-brain** | ❌ Kept | Different scope — business knowledge, not code memory (see below). |
| **dev-team / semgrep / ast-grep** | ❌ Kept | Workflow + security tooling; ast-grep is a dev-team dependency. |

## The critical coexistence fix (why the plugin changed)

lean-ctx's editing and shell tools are **MCP tools** (`ctx_patch`, `ctx_edit`,
`ctx_fill`, `ctx_shell`). They do **not** go through Claude Code's native
`Edit`/`Write`/`Bash`, so serena-forge's old hooks — which matched only the
native tools — never fired on them. Left unguarded, the agent could `ctx_patch` a
`.cs` file straight past Serena and the build safety net (lean-ctx's own CLAUDE.md
even nudges "prefer ctx_patch").

serena-forge v0.3.0 closes this:

- **`hooks/guard-leanctx-write.sh`** — denies `.cs` writes via `ctx_patch`/`ctx_edit`/`ctx_fill`. Other languages pass through, so lean-ctx keeps fast editing on JS/TS/etc. Dormant when lean-ctx isn't installed.
- **`hooks/protect-commands.sh`** — extended to guard destructive commands run through `ctx_shell` too, not just native `Bash`.
- **`hooks/prefer-symbolic-read.sh`** — **removed** (per request). The ~100-line read ASK is gone; C# reads are unblocked and only *nudged* by the SessionStart banner. Forcing edits and blocking destructive commands are unchanged.

All new guards were unit-tested (`.cs` denied through lean-ctx; non-`.cs` allowed;
`ctx_shell rm -rf /` denied; `ctx_shell git push --force` asks; benign passes).

## .NET output is forced to English (no flag — always on)

lean-ctx has a dedicated dotnet/msbuild compressor, but it matches **English
literals only** ("Build succeeded", "Error(s)", …). Under a French UI culture the
SDK prints "La génération a réussi / Avertissement(s) / Erreur(s)", which lean-ctx
**silently passes through uncompressed**. That was ctx-wire's last remaining edge —
its `filters.d/` had exit-code-aware FR filters for exactly this.

The script neutralizes the gap by exporting `DOTNET_CLI_UI_LANGUAGE=en`
(+ `VSLANG=1033`) in `env.sh`, so the SDK emits English regardless of host locale.
lean-ctx's built-in (error-preserving, well-tested) compressor then works, **and**
serena-forge's own `dotnet build` safety-net grep is hardened as a bonus. This is
why **ctx-wire is removed entirely** — there's nothing left for it to do. lean-ctx
runs in **hybrid** mode (MCP + shell compression).

## CodeGraph is kept — three layers, one arbitration rule

lean-ctx was a candidate replacement and does not qualify. Its `graph build` is
scoped to a single `project_root`, and `ctx_multi_repo` is cross-repo **search**
(RRF fusion over per-repo indexes), not a cross-repo graph. `dev-team` (10.3.0)
also calls `mcp__codegraph__*` from 3 hooks, 2 agents and 4 skills — soft,
fail-open dependencies, but dropping the server degrades all of them silently.

So all three layers stay, and the installer writes a managed block into
`~/.claude/CLAUDE.md` telling the agent which to reach for:

- **CodeGraph** — structure and blast radius, across every repo under `CODE_ROOT`. One root index, one MCP server (`codegraph-root`).
- **lean-ctx** — compression, search and code memory. Its graph is per-repo, so it is not a CodeGraph substitute.
- **Serena** — C# symbols, via Roslyn. Owns `.cs` reads and all `.cs` edits.
- **Read/Grep/Glob** — confirming one specific detail once a layer above located it.

The installer runs `codegraph init -i` / `codegraph sync` at `CODE_ROOT`, registers
the server, then indexes each repo with lean-ctx and Serena. All three are
incremental on re-run.

## RTK — evaluated, skipped as redundant

RTK ("Rust Token Killer") is a shell-output compressor (filter/group/truncate/dedup
over 100+ commands) that installs as a Claude Code PreToolUse hook. It **is** listed
in lean-ctx's addon registry (`lean-ctx addon add rtk`), but as a second-class,
manually-bridged entry. The problem is overlap, not synergy: RTK does the same job
lean-ctx already does in its L1/L3 pipeline, so enabling it as an addon
**double-processes** the same shell stream (compress → re-compress) with no
documented guard. The independent [tokbench](https://github.com/Entelligentsia/tokbench)
benchmark found every such middleware *increased* billed tokens against a
well-governed harness (RTK the least bad at +27%, but still worse than native), with
no evidence that stacking helps. **Decision: skip RTK.** If you ever want to A/B a
shell-output compressor, install RTK standalone as its own hook and measure against
the provider bill — do not wire it through lean-ctx's addon pipeline.

## Decision points (flags)

### `--leanctx-edit=guard` (default) vs `off`

- **`guard`:** lean-ctx's edit tools stay enabled; serena-forge's hook denies only
  `.cs`. Best of both — Serena owns C#, lean-ctx edits everything else fast.
- **`off`:** disable `ctx_patch`/`ctx_edit`/`ctx_fill` entirely via lean-ctx's
  `disabled_tools`. All editing goes through native tools + Serena. Simplest/safest;
  loses lean-ctx editing on non-C# files.

### `--leanctx-profile=standard` (default) / `minimal` / `power`

Standard = 16 tools (the "hybrid, not 81" you wanted). Power (68+) is reachable at
runtime via `ctx_load_tools` without bloating every session's tool list.

## Memory: two layers, both kept

Your **second-brain** and lean-ctx's memory are **complementary, not redundant**:

| | second-brain (vault-rag) | lean-ctx `ctx_knowledge` |
| --- | --- | --- |
| Scope | **Business knowledge** — architecture, decisions, domain rules | **Code memory** — patterns, gotchas, session findings |
| Answers | "How does our domain work?" | "What did I learn about this code?" |
| Embeddings | Gemini (external API) | MiniLM-L6 ONNX (100% local) |
| Sharing | git repo, team-wide | per-project, local |

### Git-sync / reinstall recovery for lean-ctx memory

lean-ctx stores knowledge under `~/.local/share/lean-ctx/knowledge/<project-hash>/`
(plain JSON). To make it survive a reinstall or share it with the team, export to
**OKF** (Open Knowledge Format — a directory of deterministic, diff-clean Markdown
files) and commit it:

```bash
lean-ctx knowledge export --format okf --output ./kb-okf   # commit ./kb-okf
# teammate / new machine:
lean-ctx knowledge import ./kb-okf --merge append
```

Pass `--leanctx-kb-repo=DIR` to the installer to drop a **`leanctx-kb-sync`**
helper that exports OKF into a git repo and commits it in one shot (run it manually
or from cron). For a full portable snapshot (knowledge + graph + session, signed):
`lean-ctx pack create` → `.ctxpkg` → `lean-ctx pack import --apply`. To relocate the
whole store into a repo, set `LEAN_CTX_DATA_DIR`.

## Running it

```bash
# Default: forced-English .NET, CodeGraph root index, lean-ctx indexes each repo,
# lean-ctx edits guarded (Serena owns .cs)
bash serena-forge/setup/install-wsl.sh          # add -y for unattended

# Disable lean-ctx's edit tools entirely (all editing native + Serena)
bash serena-forge/setup/install-wsl.sh --leanctx-edit=off

# Also git-sync lean-ctx knowledge into a repo
bash serena-forge/setup/install-wsl.sh --leanctx-kb-repo=~/second-brain
```

The script is idempotent: on an existing box it uninstalls caveman/ponytail,
removes ctx-wire (binary, config and `CLAUDE.md` block), installs+configures+indexes
lean-ctx and CodeGraph, vendors the skills, restores the local Claude Code config
(statusline, auto-compact window, PostToolUse hooks) and the tmux ↔ Windows
clipboard bridge, updates serena-forge to v0.3.0 (new hooks), and never re-asks
stored secrets.
