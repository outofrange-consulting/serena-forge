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
| Plugins | `serena-forge@serena-forge` (this repo — symbolic C# enforcement, build safety net, destructive-command guard, all hooks included) and `dev-team@bfinster` (**upstream** [bdfinst/agentic-dev-team](https://github.com/bdfinst/agentic-dev-team)) |
| Skills (`~/.claude/skills`) | `caveman`, `yagni`, `atlassian` (drives `acli`), `context7` (drives `ctx7`) — mirrored from [omp-dev-team](https://github.com/outofrange-consulting/omp-dev-team)'s token-diet — plus `azure-devops` (this repo, drives `az devops`) |
| CLI tools | `ctx-wire` (+ shims + token-diet git/dotnet filters merged as a managed block), `acli` (Atlassian CLI + auth), `az` + `azure-devops` extension (+ PAT login + org/project defaults), `ctx7` |
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
--skip-brain --skip-az --skip-acli --skip-miro --skip-dotnet
```

## After the first run

1. Open a **new shell** (or `source ~/.config/claude-tools/env.sh`).
2. `claude` → log in, then `/mcp` to complete the Miro OAuth.
3. In a C# repo: `/serena-forge-setup` to onboard Serena.
4. Second brain: `cd ~/second-brain && claude`.
