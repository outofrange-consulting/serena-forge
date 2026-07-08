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
| **ctx-wire** | ✅ Replaced (see the .NET caveat) | lean-ctx's 56 shell-compression modules + 10 read modes are a superset of ctx-wire's shell filtering — **except** localized .NET output (below). |
| **caveman** | ✅ Replaced | Compression is native in lean-ctx (content-addressed cache, ~13-token cached re-reads, pressure auto-downgrade). |
| **ponytail** | ✅ Replaced | Tool profiles (minimal/standard/power) + pressure-based degradation cover the "don't over-fetch" role. |
| **Serena** | ❌ Kept | lean-ctx is tree-sitter (syntactic); Serena is **Roslyn** (the real C# compiler). No contest for C# symbol edits/refactors/diagnostics. lean-ctx has zero .NET/Roslyn awareness. |
| **CodeGraph** | ⚠️ Kept by default | lean-ctx's graph is **per-repo only** — no cross-repo edges, impact, or auto-discovery under a root. Its multi-repo feature is query-time **search federation**, not one graph. CodeGraph's root-level cross-repo graph has no lean-ctx equivalent. |
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

## Decision points (flags)

### `--dotnet-lang=en` (default) vs `fr` — the localization gap

lean-ctx has a dedicated dotnet/msbuild compressor, but it matches **English
literals only** ("Build succeeded", "Error(s)", …). Under a French UI culture the
SDK prints "La génération a réussi / Avertissement(s) / Erreur(s)", which lean-ctx
**silently passes through uncompressed**. Your ctx-wire `filters.d/` had dedicated
FR filters exactly for this — and they are **exit-code-aware** (a clean-looking
summary is *not* collapsed to "ok" when the build actually failed), which lean-ctx's
custom `[[rules]]` schema cannot express.

- **`en` (default, recommended):** the script exports `DOTNET_CLI_UI_LANGUAGE=en`
  (+ `VSLANG=1033`) in `env.sh`, so the SDK emits English. lean-ctx's built-in
  (error-preserving, well-tested) compressor then works, and serena-forge's own
  `dotnet build` safety-net grep is hardened as a bonus. **ctx-wire is fully
  removed.** lean-ctx runs in **hybrid** mode (MCP + shell compression).
- **`fr`:** keep French output. **ctx-wire is kept** for its FR/EN dotnet+git
  filters, and lean-ctx is installed in **MCP-only** mode so the two compression
  layers don't double-process the shell. More moving parts; choose only if you
  want French .NET output preserved verbatim.

### `--codegraph=keep` (default) vs `drop`

Keep the cross-repo CodeGraph graph — lean-ctx cannot replace it (per-repo graph
only). `drop` relies on lean-ctx multi-repo **search** across registered roots,
which is fine if your CodeGraph use is "find/read across repos" but loses
cross-repo dependency/impact traversal.

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
# Default (recommended): English .NET output, keep CodeGraph, guard lean-ctx edits
bash serena-forge/setup/install-wsl.sh          # add -y for unattended

# Keep French .NET output (keeps ctx-wire, lean-ctx MCP-only)
bash serena-forge/setup/install-wsl.sh --dotnet-lang=fr

# Also git-sync lean-ctx knowledge into a repo
bash serena-forge/setup/install-wsl.sh --leanctx-kb-repo=~/second-brain
```

The script is idempotent: on an existing box it uninstalls caveman/ponytail,
removes ctx-wire (English path), installs+configures lean-ctx, updates serena-forge
to v0.3.0 (new hooks), and never re-asks stored secrets.
