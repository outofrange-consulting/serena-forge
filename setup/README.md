# setup/ — WSL bootstrap for a clean Claude Code workstation

One script rebuilds the full toolchain on a fresh WSL (Ubuntu) machine — and
**re-running it later updates everything** (tools, plugins, skills) while
preserving your config and secrets.

```bash
git clone https://github.com/outofrange-consulting/serena-forge.git
bash serena-forge/setup/install-wsl.sh
```

Non-interactive (CI / unattended — missing secrets are skipped, not prompted):

```bash
bash serena-forge/setup/install-wsl.sh -y
```

## What it installs / updates

| Component | Detail |
| --- | --- |
| Base deps | `git curl jq unzip zip build-essential python3 pipx` (apt), GitHub CLI `gh` (+ `gh auth login` if needed — required by dev-team and to clone the private repos) |
| Runtimes | Node LTS (`~/.local`), `uv`/`uvx` (Serena launcher), .NET 10 SDK (`~/.dotnet`, Serena's Roslyn backend — .NET 9 is not supported) |
| Claude Code | native installer; `claude update` on re-run |
| Plugins | `serena-forge@serena-forge` (this repo — symbolic C# enforcement, build safety net, destructive-command guard, all hooks included), `dev-team@bfinster` (**upstream** [bdfinst/agentic-dev-team](https://github.com/bdfinst/agentic-dev-team)), `caveman@caveman` (**upstream** [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)) and `ponytail@ponytail` (**upstream** [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) — the YAGNI / laziest-senior-dev discipline) |
| Skills (`~/.claude/skills`) | `atlassian` (drives `acli`), `context7` (drives `ctx7`) — mirrored from [omp-dev-team](https://github.com/outofrange-consulting/omp-dev-team)'s token-diet — plus `azure-devops` (this repo, drives `az devops`). Stale `caveman`/`yagni` mirrors from earlier runs are removed (they're upstream plugins now) |
| CLI tools | `ctx-wire` (+ shims + token-diet git/dotnet filters merged as a managed block), `acli` (Atlassian CLI + auth), `az` + `azure-devops` extension (+ PAT login + org/project defaults), `ctx7` |
| dev-team tooling | what upstream `/init-dev-team` expects: `jq` + `python3` (hard deps), **CodeGraph** (`codegraph upgrade` on re-run), plus `ast-grep`, `semgrep` (used by the `semgrep-analyze` skill) and a **global Stryker.NET** for the C# mutation gate. Stryker (JS) and pitest stay per-project by upstream design — run `/init-dev-team` inside a repo to wire those |
| Repo indexing | prompts once for `CODE_ROOT` (your repos folder, persisted; or `--code-root=DIR`). **CodeGraph indexes the root itself** — one cross-repo graph (`codegraph init -i` first time, `codegraph sync` on re-run), served to every session by a **user-scope MCP server** (`codegraph`, via the `~/.local/bin/codegraph-root` wrapper) and advertised by a managed block in `~/.claude/CLAUDE.md`. **Serena indexes per repo**: every C# repo (`.sln`/`.csproj`) under the root gets `serena project index` to kill the Roslyn cold start |
| MCP | Miro remote MCP (`https://mcp.miro.com`, user scope) — finish the OAuth with `/mcp` in your first session |
| Second brain | clones [second-brain](https://github.com/outofrange-consulting/second-brain) to `~/second-brain` (or `--brain-dir=…`), renders `.mcp.json` (vault-rag MCP via `rag/launch.sh`) and `.claude/settings.json` (auto-commit / auto-push / statusline hooks) from the repo templates, `npm install` in `rag/`, RAG smoke test |

## Secrets — prompted once, as secure strings

Any variable already present in the environment (or in
`~/.config/claude-tools/secrets.env`) is **never re-asked**. Missing ones are
prompted with `read -s` (nothing echoed) and persisted to
`~/.config/claude-tools/secrets.env` (`chmod 600`):

| Variable | Used for |
| --- | --- |
| `GOOGLE_GEMINI_API_KEY` | second-brain embeddings — written to `<brain>/.env` (skipped if the brain's `.env` sets another `EMBEDDING_PROVIDER`) |
| `AZURE_DEVOPS_ORG`, `AZURE_DEVOPS_PROJECT` | `az devops configure --defaults` |
| `AZURE_DEVOPS_PAT` (also persisted as `AZURE_DEVOPS_EXT_PAT`) | non-interactive `az devops` auth |
| `ACLI_SITE`, `ACLI_EMAIL`, `ACLI_TOKEN` | `acli jira auth login` |
| `CODE_ROOT` (plain, not secret) | root folder scanned for repos to index with CodeGraph/Serena |

## Skill & tool provenance

- `caveman` — installed as the **upstream plugin** `caveman@caveman` ([JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)), auto-updated via its marketplace.
- `ponytail` — installed as the **upstream plugin** `ponytail@ponytail` ([DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)); this is the upstream of what token-diet shipped as `yagni`.
- `context7` + `ctx7` — the `ctx7` npm CLI is published by the Context7 team (Upstash); the skill wrapping it is omp-dev-team's CLI-over-MCP take.
- `atlassian` — omp-dev-team skill driving the official Atlassian `acli`.
- `azure-devops` — authored in this repo, drives the official `az` CLI `azure-devops` extension (Boards, Repos/PRs — create/vote/complete/checkout, Pipelines).
- CodeGraph — [colbymchenry/codegraph](https://github.com/colbymchenry/codegraph), the tool upstream dev-team's `/init-dev-team` and its `codegraph-bootstrap` SessionStart hook expect.

## PATH — non-interactive shells included

A single managed file, `~/.config/claude-tools/env.sh` (PATH for
`~/.local/bin`, `~/.dotnet`, `DOTNET_ROOT`, and the secrets), is sourced from:

- `~/.profile` — login shells (WSL terminal, VS Code remote, `bash -lc`),
- the **top** of `~/.bashrc` — *before* Ubuntu's interactive-guard `return`,
  so `bash -ic` and forced-interactive shells see it too,
- `~/.zshenv` — zsh reads it for **every** shell, non-interactive included.

The doctor step at the end re-checks tool visibility from a fresh login shell
and warns if the wiring didn't take.

## Flags

```
-y, --yes         never prompt (skip missing secrets with a warning)
--no-update       keep already-installed tools as-is
--brain-dir=DIR   second brain location (default ~/second-brain)
--code-root=DIR   repos folder for CodeGraph/Serena indexing (else prompted)
--skip-brain --skip-az --skip-acli --skip-miro --skip-dotnet --skip-index
```

## Design note — root-level CodeGraph without patching dev-team

CodeGraph lives at `CODE_ROOT` (one cross-repo graph), Serena in each repo.
**No transformation pass over dev-team updates is needed**, because dev-team's
per-repo CodeGraph integration is opt-in and fail-open:

- `codegraph_bootstrap` (SessionStart) only acts when the *repo's* `.mcp.json`
  references a codegraph server — we never write one, so it stays silent;
- `codegraph_nudge` (PreToolUse) keys on a repo-local `.codegraph/` sentinel —
  absent, so no nudge fires (the managed `~/.claude/CLAUDE.md` block carries
  the routing hint instead);
- `codegraph_turn_mark` matches `mcp__codegraph__*` tool names — which is
  exactly what the user-scope root server exposes, so it keeps working.

Nothing in the plugin cache is modified, so `claude plugin update dev-team`
can never revert this setup. (A patch-the-cache pipeline would have broken on
the very last upstream release, which rewrote these hooks from bash to
Python.)

## After the first run

1. Open a **new shell** (or `source ~/.config/claude-tools/env.sh`).
2. `claude` → log in, then `/mcp` to complete the Miro OAuth.
3. In a C# repo: `/serena-forge-setup` to onboard Serena.
4. Second brain: `cd ~/second-brain && claude`.
