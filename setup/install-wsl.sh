#!/usr/bin/env bash
# serena-forge — WSL workstation bootstrap, lean-ctx edition.
#
# Swaps the ctx-wire + caveman + ponytail compression stack for a single Rust
# binary (lean-ctx) and, on an existing box, MIGRATES the old stack away.
# CodeGraph is KEPT: dev-team's hooks and agents target mcp__codegraph__*, and
# lean-ctx's graph is per-repo only (its multi-repo feature is search, not graph),
# so the cross-repo structural query has no other home. Serena owns C# symbols.
#
# Idempotent: safe to re-run. Tools refresh to latest by default; config and
# secrets are preserved; the migration step converges an old box onto the new
# stack without re-asking anything.
#
#   Runtimes & deps : apt basics (git, curl, jq, unzip, build tools), Node LTS,
#                     uv/uvx (Serena launcher), .NET 10 SDK (Serena's Roslyn
#                     backend), GitHub CLI (gh — required by dev-team)
#   Claude Code     : native installer, `claude update` on re-run
#   Plugins         : serena-forge (this repo — Serena force + destructive guard
#                     + lean-ctx guard hooks), dev-team@bfinster (upstream
#                     bdfinst/agentic-dev-team)
#                     REMOVED vs the old stack: caveman, ponytail, ctx-wire
#   Context layer   : lean-ctx (leanctx.com) — hybrid mode (MCP tools + shell
#                     output compression), tool profile + per-repo index built on
#                     install. Replaces ctx-wire + caveman + ponytail.
#   Code graph      : CodeGraph — ONE index at CODE_ROOT, served to every session
#                     by a user-scope MCP server. Cross-repo structure/impact.
#   Skills (~/.claude/skills) : all vendored in setup/skills — atlassian (acli +
#                     MCP fallback), context7, azure-devops, aspire-cli, datadog
#   CLI tools       : acli (Atlassian), az + azure-devops extension, ctx7 (docs),
#                     aspire (.NET Aspire CLI), pup (Datadog CLI, EU), aoe (tmux
#                     multi-agent), Docker Engine (native WSL)
#   dev-team tooling: ast-grep, semgrep, Stryker.NET (global)
#   Repo indexing   : Serena `project index` per C# repo, CodeGraph once at the
#                     code root, lean-ctx `index build` + `graph build` per repo
#   MCP             : Miro (remote, OAuth via /mcp), Atlassian (local Docker
#                     server — the acli skill's write fallback), CodeGraph (root)
#   Local config    : ~/.claude/settings.json managed block (statusline, auto-compact
#                     window, CRLF + no-comments PostToolUse hooks), ~/.tmux.conf
#                     clipboard bridge, WSLInterop binfmt registration
#   Second brain    : clones outofrange-consulting/second-brain, renders configs,
#                     installs the RAG engine (business-knowledge vault — distinct
#                     from lean-ctx's per-repo code memory; both are kept)
#
# .NET output is FORCED to English (DOTNET_CLI_UI_LANGUAGE=en + VSLANG=1033 in
# env.sh) so lean-ctx's English-only dotnet/msbuild compressor fires regardless of
# host locale, AND serena-forge's dotnet-build safety-net grep is hardened. This
# is why ctx-wire (whose only remaining edge was French dotnet filters) is dropped
# entirely.
#
# Secrets: any missing value is prompted as a SECURE string (read -s, never
# echoed) and persisted to ~/.config/claude-tools/secrets.env (chmod 600).
#   GOOGLE_GEMINI_API_KEY               second-brain embeddings (goes to <brain>/.env)
#   AZURE_DEVOPS_ORG / _PROJECT / _PAT  az devops defaults + PAT login
#   ACLI_SITE / ACLI_EMAIL / ACLI_TOKEN Atlassian CLI auth — also feed the
#                                       Atlassian MCP server (same site + token)
#
# Flags:
#   -y, --yes            non-interactive: never prompt (missing secrets skipped)
#   --no-update          keep already-installed tools (don't refresh)
#   --leanctx-edit=guard|off  how to keep .cs edits on Serena (default guard).
#                        guard = serena-forge hooks deny ctx_patch/ctx_edit on .cs
#                        (lean-ctx still edits other languages). off = disable
#                        lean-ctx's edit tools entirely via disabled_tools
#   --leanctx-profile=minimal|standard|power  lean-ctx tool profile (default standard)
#   --leanctx-kb-repo=DIR  git repo to sync lean-ctx knowledge into as OKF Markdown
#                        (installs the leanctx-kb-sync helper; default: off)
#   --brain-dir=DIR      where the second brain lives (default: ~/second-brain)
#   --code-root=DIR      root folder of your repos for indexing (also CODE_ROOT env)
#   --skip-brain / --skip-az / --skip-acli / --skip-miro / --skip-dotnet /
#   --skip-index / --skip-leanctx / --skip-atlassian-mcp / --skip-local-config
#                        skip that component entirely
#   -h, --help           this help
set -euo pipefail

YES=0; NO_UPDATE=0; SKIP_BRAIN=0; SKIP_AZ=0; SKIP_ACLI=0; SKIP_MIRO=0; SKIP_DOTNET=0; SKIP_INDEX=0; SKIP_LEANCTX=0
SKIP_ATLASSIAN_MCP=0; SKIP_LOCAL_CONFIG=0
LEANCTX_EDIT=guard; LEANCTX_PROFILE=standard; LEANCTX_KB_REPO=""
BRAIN_DIR="${SECOND_BRAIN_DIR:-$HOME/second-brain}"
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --no-update) NO_UPDATE=1 ;;
  --leanctx-edit=*) LEANCTX_EDIT="${a#*=}" ;;
  --leanctx-profile=*) LEANCTX_PROFILE="${a#*=}" ;;
  --leanctx-kb-repo=*) LEANCTX_KB_REPO="${a#*=}" ;;
  --brain-dir=*) BRAIN_DIR="${a#*=}" ;;
  --code-root=*) CODE_ROOT="${a#*=}" ;;
  --skip-brain) SKIP_BRAIN=1 ;; --skip-az) SKIP_AZ=1 ;; --skip-acli) SKIP_ACLI=1 ;;
  --skip-miro) SKIP_MIRO=1 ;; --skip-dotnet) SKIP_DOTNET=1 ;; --skip-index) SKIP_INDEX=1 ;;
  --skip-leanctx) SKIP_LEANCTX=1 ;;
  --skip-atlassian-mcp) SKIP_ATLASSIAN_MCP=1 ;;
  --skip-local-config) SKIP_LOCAL_CONFIG=1 ;;
  -h|--help) sed -n '2,72p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

case "$LEANCTX_EDIT"   in guard|off) ;; *) echo "--leanctx-edit must be guard|off" >&2; exit 2 ;; esac
case "$LEANCTX_PROFILE" in minimal|standard|power) ;; *) echo "--leanctx-profile must be minimal|standard|power" >&2; exit 2 ;; esac

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # serena-forge repo root
CFG_DIR="$HOME/.config/claude-tools"
ENV_FILE="$CFG_DIR/env.sh"
SECRETS_FILE="$CFG_DIR/secrets.env"
SRC_DIR="$HOME/.claude-setup/src"                          # cached sibling repos
GH_ORG="outofrange-consulting"
mkdir -p "$CFG_DIR" "$SRC_DIR" "$HOME/.local/bin" "$HOME/.claude/skills"

# ---------------------------------------------------------------------------
# PATH & env persistence — login, interactive AND non-interactive shells.
# ---------------------------------------------------------------------------
MARK_BEGIN="# >>> claude-tools env (serena-forge setup) >>>"
MARK_END="# <<< claude-tools env (serena-forge setup) <<<"

write_env_file() {
  cat > "$ENV_FILE" <<EOF
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# Sourced from ~/.profile, ~/.bashrc (top) and ~/.zshenv so PATH is correct
# even in non-interactive shells (Claude Code's Bash tool, cron, ssh cmd…).
# Written \`set -e\`-safe: only if-statements, no bare && lists.
for _d in "\$HOME/.local/bin" "\$HOME/.dotnet" "\$HOME/.dotnet/tools" "\$HOME/.aspire/bin"; do
  if [ -d "\$_d" ]; then
    case ":\$PATH:" in *":\$_d:"*) ;; *) PATH="\$_d:\$PATH" ;; esac
  fi
done
unset _d
export PATH
if [ -d "\$HOME/.dotnet" ]; then export DOTNET_ROOT="\$HOME/.dotnet"; fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# Force English .NET CLI/MSBuild output so lean-ctx's (English-only) dotnet
# compression fires regardless of host locale, and so serena-forge's
# dotnet-build safety-net grep matches.
export DOTNET_CLI_UI_LANGUAGE=en
export VSLANG=1033
# Datadog (pup CLI + dd tracers): default org is the EU site.
export DD_SITE=datadoghq.eu
if [ -f "\$HOME/.config/claude-tools/secrets.env" ]; then
  . "\$HOME/.config/claude-tools/secrets.env"
fi
EOF
  chmod 644 "$ENV_FILE"
}

wire_rc() {  # wire_rc <file> <top|bottom> — idempotent managed block
  local f="$1" pos="$2" block
  block="$MARK_BEGIN
[ -f \"\$HOME/.config/claude-tools/env.sh\" ] && . \"\$HOME/.config/claude-tools/env.sh\"
$MARK_END"
  [ -e "$f" ] || : > "$f"
  grep -qsF "$MARK_BEGIN" "$f" && return 0
  if [ "$pos" = top ]; then
    printf '%s\n\n' "$block" | cat - "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    printf '\n%s\n' "$block" >> "$f"
  fi
}

setup_env_wiring() {
  say "Persisting PATH / env (login, interactive and non-interactive shells)"
  write_env_file
  wire_rc "$HOME/.profile" bottom
  wire_rc "$HOME/.bashrc"  top
  wire_rc "$HOME/.zshenv"  bottom
  # shellcheck disable=SC1090
  . "$ENV_FILE" || true
  ok "env.sh wired (English .NET output forced)"
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
load_secrets() { [ -f "$SECRETS_FILE" ] && { set -a; . "$SECRETS_FILE"; set +a; } || true; }

persist_secret() {  # persist_secret NAME VALUE
  local name="$1" value="$2" tmp
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  tmp="$(mktemp)"
  grep -v "^export ${name}=" "$SECRETS_FILE" > "$tmp" 2>/dev/null || true
  printf 'export %s=%q\n' "$name" "$value" >> "$tmp"
  mv "$tmp" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
}

require_var() {  # require_var NAME "label" secret|plain -> 0 if value available
  local name="$1" label="$2" mode="${3:-secret}" val
  val="${!name:-}"
  [ -n "$val" ] && return 0
  if [ "$YES" = 1 ] || [ ! -r /dev/tty ]; then
    warn "$name not set — skipping ($label). Set it in $SECRETS_FILE and re-run."
    return 1
  fi
  if [ "$mode" = secret ]; then
    read -r -s -p "  $label ($name): " val </dev/tty || val=""
    printf '\n' >/dev/tty
  else
    read -r -p "  $label ($name): " val </dev/tty || val=""
  fi
  [ -n "$val" ] || { warn "$name left empty — skipping ($label)."; return 1; }
  export "$name=$val"
  persist_secret "$name" "$val"
  ok "$name saved to $SECRETS_FILE (chmod 600)"
}

# ---------------------------------------------------------------------------
# Base dependencies (apt) + GitHub CLI
# ---------------------------------------------------------------------------
APT_UPDATED=0
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ "${#missing[@]}" = 0 ] && return 0
  if ! sudo -n true 2>/dev/null && [ "$YES" = 1 ] && [ ! -r /dev/tty ]; then
    warn "sudo needs a password — skipping apt install of: ${missing[*]}"; return 0
  fi
  [ "$APT_UPDATED" = 1 ] || { sudo apt-get update -qq || true; APT_UPDATED=1; }
  sudo apt-get install -y -qq "${missing[@]}" || warn "apt install failed for: ${missing[*]}"
}

ensure_base_deps() {
  say "Base packages (apt)"
  apt_install git curl ca-certificates jq unzip zip build-essential python3 pipx
  ok "base packages present"
}

ensure_browser_opener() {
  say "Browser opener (device-code / OAuth flows)"
  if have wslview; then ok "wslview present ($(command -v wslview))"; return; fi
  if apt_install wslu 2>/dev/null && have wslview; then
    ok "wslu installed (wslview)"; return
  fi
  local ps='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  if [ ! -x "$ps" ]; then warn "no wslu and no powershell.exe — browser flows may fail"; return; fi
  mkdir -p "$HOME/.local/bin"
  local name
  for name in wslview xdg-open; do
    cat > "$HOME/.local/bin/$name" <<'SH'
#!/bin/sh
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# WSL browser opener bridging to the Windows default browser (wslu fallback).
[ -n "$1" ] || exit 0
exec /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "Start-Process '$1'"
SH
    chmod +x "$HOME/.local/bin/$name"
  done
  hash -r 2>/dev/null || true
  have wslview && ok "wslview/xdg-open shim installed (-> Windows browser)" \
               || warn "wslview shim created but not on PATH yet — open a new shell"
}

ensure_gh() {
  if have gh && [ "$NO_UPDATE" = 1 ]; then ok "gh $(gh --version | head -1)"; return; fi
  say "Installing/updating GitHub CLI (gh)"
  if ! have gh; then
    sudo install -dm755 /etc/apt/keyrings 2>/dev/null || true
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null || true
    APT_UPDATED=0
  fi
  apt_install gh
  have gh && ok "gh $(gh --version | head -1)" || warn "gh install failed — dev-team needs it (https://cli.github.com)"
  if have gh && ! gh auth status >/dev/null 2>&1; then
    if [ "$YES" = 0 ] && [ -r /dev/tty ]; then
      say "GitHub auth (needed to clone the private $GH_ORG repos)"
      gh auth login </dev/tty || warn "gh auth login failed — run it manually, then re-run this script"
    else
      warn "gh is not authenticated — run 'gh auth login' (private repo clones will fail until then)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Runtimes: Node LTS, uv/uvx, .NET 10 SDK
# ---------------------------------------------------------------------------
node_major() { node --version 2>/dev/null | sed 's/^v//; s/\..*//' || echo 0; }
ensure_npm_prefix() { have npm && npm config set prefix "$HOME/.local" >/dev/null 2>&1 || true; }

ensure_node() {
  if have node && [ "$(node_major)" -ge 20 ] && [ "$NO_UPDATE" = 1 ]; then
    ensure_npm_prefix; ok "node $(node --version)"; return
  fi
  say "Installing/updating Node.js (LTS) into ~/.local"
  local os arch ver file url tmp dir b
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) warn "unsupported arch for auto Node"; return ;; esac
  os=linux
  ver="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | tr '}' '\n' | grep -m1 '"lts":"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [ -n "$ver" ] || { warn "could not resolve Node LTS version"; ensure_npm_prefix; return; }
  if have node && [ "$(node --version)" = "$ver" ]; then ensure_npm_prefix; ok "node $ver (already latest LTS)"; return; fi
  file="node-${ver}-${os}-${arch}.tar.gz"; url="https://nodejs.org/dist/${ver}/${file}"
  tmp="$(mktemp -d)"
  if curl -fsSL "$url" -o "$tmp/node.tgz" && tar -xzf "$tmp/node.tgz" -C "$HOME/.local"; then
    dir="$HOME/.local/${file%.tar.gz}"
    for b in node npm npx corepack; do [ -e "$dir/bin/$b" ] && ln -sf "$dir/bin/$b" "$HOME/.local/bin/$b"; done
    hash -r 2>/dev/null || true
    ensure_npm_prefix
    ok "node $(node --version)"
  else
    warn "Node download failed — install manually from https://nodejs.org"
  fi
  rm -rf "$tmp" 2>/dev/null || true
}

ensure_uv() {
  if have uvx && [ "$NO_UPDATE" = 1 ]; then ok "uvx $(uvx --version 2>/dev/null | head -1)"; return; fi
  say "Installing/updating uv (uvx — Serena launcher)"
  if have uv; then uv self update >/dev/null 2>&1 || true
  else curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null || warn "uv install failed — https://docs.astral.sh/uv/"; fi
  hash -r 2>/dev/null || true
  have uvx && ok "uvx $(uvx --version 2>/dev/null | head -1)" || warn "uvx not on PATH"
}

ensure_dotnet() {
  [ "$SKIP_DOTNET" = 1 ] && return 0
  apt_install libicu-dev libssl-dev
  if dotnet --list-sdks 2>/dev/null | grep -q '^10\.' && [ "$NO_UPDATE" = 1 ]; then
    ok "dotnet SDK 10 present"
  else
    say "Installing/updating .NET 10 SDK into ~/.dotnet (Serena Roslyn backend)"
    local tmp; tmp="$(mktemp)"
    if curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp"; then
      bash "$tmp" --channel 10.0 --install-dir "$HOME/.dotnet" >/dev/null \
        && ok "dotnet $("$HOME/.dotnet/dotnet" --version 2>/dev/null)" \
        || warn ".NET 10 install failed — https://dot.net"
    else
      warn "could not download dotnet-install.sh"
    fi
    rm -f "$tmp"
  fi
  export DOTNET_ROOT="$HOME/.dotnet"
  case ":$PATH:" in *":$HOME/.dotnet:"*) ;; *) export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH" ;; esac
  have dotnet || return 0
  dotnet dev-certs https >/dev/null 2>&1 || true
  if [ ! -d "$HOME/.nuget/plugins/netcore/CredentialProvider.Microsoft" ]; then
    say "Installing Azure Artifacts NuGet credential provider"
    curl -fsSL https://aka.ms/install-artifacts-credprovider.sh | bash >/dev/null 2>&1 \
      && ok "artifacts-credprovider installed" || warn "artifacts-credprovider install failed"
  fi
}

dotnet_tool() {
  local pkg="$1"
  if dotnet tool list --global 2>/dev/null | grep -qi "^$pkg "; then
    [ "$NO_UPDATE" = 1 ] || dotnet tool update --global "$pkg" >/dev/null 2>&1 || true
    ok "$pkg (global, updated)"
  else
    dotnet tool install --global "$pkg" >/dev/null 2>&1 \
      && ok "$pkg installed" || warn "$pkg install failed"
  fi
}

ensure_dotnet_tools() {
  have dotnet || return 0
  say "dotnet global tools"
  dotnet_tool dotnet-ef
  dotnet_tool dotnet-stryker
  dotnet_tool dotnet-reportgenerator-globaltool
  dotnet_tool dotnet-outdated-tool
}

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
ensure_claude() {
  local cur; cur="$(command -v claude 2>/dev/null || true)"
  case "$cur" in
    ""|/mnt/*|/c/*)
      say "Installing Claude Code (native Linux)"
      curl -fsSL https://claude.ai/install.sh | bash || { warn "Claude Code install failed"; return 1; }
      hash -r 2>/dev/null || true
      have claude && ok "claude $(claude --version 2>/dev/null | head -1)" || warn "claude not on PATH yet — open a new shell and re-run"
      ;;
    *)
      if [ "$NO_UPDATE" = 1 ]; then ok "claude $(claude --version 2>/dev/null | head -1)"
      else say "Updating Claude Code"; claude update >/dev/null 2>&1 || true; ok "claude $(claude --version 2>/dev/null | head -1)"; fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Sibling repos (cached under ~/.claude-setup/src, pulled on every run)
# ---------------------------------------------------------------------------
clone_or_update() {
  local slug="$1" dest="$2"
  if [ -d "$dest/.git" ]; then
    git -C "$dest" fetch --quiet origin 2>/dev/null || { warn "fetch failed for $slug (offline / no auth?)"; return 0; }
    [ "$NO_UPDATE" = 1 ] || git -C "$dest" pull --ff-only --quiet 2>/dev/null || warn "$slug has local changes — not updated"
    ok "$slug up to date"
  else
    say "Cloning $slug"
    if have gh && gh auth status >/dev/null 2>&1; then gh repo clone "$slug" "$dest" -- --quiet || warn "clone failed: $slug"
    else git clone --quiet "https://github.com/$slug.git" "$dest" || warn "clone failed: $slug (private? run 'gh auth login')"; fi
  fi
}

# ---------------------------------------------------------------------------
# MIGRATION — converge an OLD box (ctx-wire + caveman + ponytail + CodeGraph)
# onto the new lean-ctx stack. Idempotent: a no-op on a clean box. Runs before
# install so the new tools land on a cleaned foundation.
# ---------------------------------------------------------------------------
uninstall_plugin() {  # uninstall_plugin <plugin> <marketplace>
  local plugin="$1" market="$2"
  have claude || return 0
  if claude plugin list 2>/dev/null | grep -q "$plugin"; then
    say "Migration: removing obsolete plugin ${plugin}@${market}"
    claude plugin uninstall "${plugin}@${market}" >/dev/null 2>&1 \
      || claude plugin remove "${plugin}@${market}" >/dev/null 2>&1 \
      || claude plugin disable "${plugin}@${market}" >/dev/null 2>&1 \
      || warn "could not auto-remove ${plugin} — run: claude plugin uninstall ${plugin}@${market}"
    claude plugin marketplace remove "$market" >/dev/null 2>&1 || true
    ok "removed ${plugin}"
  fi
}

USER_CLAUDE_MD="$HOME/.claude/CLAUDE.md"

strip_claude_md_block() {  # strip_claude_md_block <begin-marker> <end-marker>
  local b="$1" e="$2" tmp
  [ -f "$USER_CLAUDE_MD" ] || return 0
  grep -qF "$b" "$USER_CLAUDE_MD" 2>/dev/null || return 1
  tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$USER_CLAUDE_MD" > "$tmp" \
    && mv "$tmp" "$USER_CLAUDE_MD"
}

remove_ctx_wire() {
  if have ctx-wire; then
    say "Migration: removing ctx-wire (replaced by lean-ctx + forced-English dotnet)"
    ctx-wire shims uninstall >/dev/null 2>&1 || true
    local b; b="$(command -v ctx-wire || true)"
    [ -n "$b" ] && rm -f "$b" 2>/dev/null || true
    rm -rf "$HOME/.config/ctx-wire" 2>/dev/null || true
    ok "ctx-wire removed"
  fi
  local d="$HOME/.local/bin" f
  if [ -d "$d" ]; then
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      grep -qsF "ctx-wire shim" "$f" 2>/dev/null && rm -f "$f" 2>/dev/null || true
    done
  fi
  # ctx-wire writes its own instruction block into the user's CLAUDE.md. Left
  # behind, it tells the agent to shell out through a binary we just deleted.
  strip_claude_md_block "<!-- ctx-wire-instructions -->" "<!-- /ctx-wire-instructions -->" \
    && ok "ctx-wire block stripped from ~/.claude/CLAUDE.md"
  return 0
}

# dev-team 8.x briefly routed structural queries to a `codebase-memory` server.
# 10.x is back on CodeGraph and no cbm server exists — rewrite the stale line.
fix_stale_claude_md() {
  [ -f "$USER_CLAUDE_MD" ] || return 0
  grep -q 'codebase-memory' "$USER_CLAUDE_MD" 2>/dev/null || return 0
  sed -i 's/`codebase-memory` graph/`codegraph` graph/g' "$USER_CLAUDE_MD"
  ok "~/.claude/CLAUDE.md: codebase-memory -> codegraph"
}

migrate_obsolete() {
  bold "Migration: obsolete stack -> lean-ctx"
  uninstall_plugin caveman  caveman
  uninstall_plugin ponytail ponytail
  remove_ctx_wire
  fix_stale_claude_md
  local s
  for s in caveman yagni; do
    [ -d "$HOME/.claude/skills/$s" ] && { rm -rf "$HOME/.claude/skills/$s"; ok "removed stale mirrored skill $s"; }
  done
  return 0
}

# ---------------------------------------------------------------------------
# Plugins & marketplaces (serena-forge + upstream agentic-dev-team). caveman and
# ponytail are intentionally NOT installed — see migrate_obsolete.
# ---------------------------------------------------------------------------
ensure_plugin() {
  local repo="$1" market="$2" plugin="$3"
  claude plugin marketplace add "$repo" >/dev/null 2>&1 || true
  claude plugin marketplace update "$market" >/dev/null 2>&1 || true
  if claude plugin list 2>/dev/null | grep -q "$plugin"; then
    [ "$NO_UPDATE" = 1 ] || claude plugin update "${plugin}@${market}" >/dev/null 2>&1 || true
    ok "plugin ${plugin}@${market} (updated)"
  elif claude plugin install "${plugin}@${market}" >/dev/null 2>&1; then
    ok "plugin ${plugin}@${market} installed"
  elif claude plugin update "${plugin}@${market}" >/dev/null 2>&1; then
    ok "plugin ${plugin}@${market} (updated)"
  else
    warn "could not install ${plugin}@${market} — run: claude plugin install ${plugin}@${market}"
  fi
}

ensure_plugins() {
  have claude || { warn "claude missing — skipping plugins"; return 0; }
  say "Claude Code plugins"
  ensure_plugin "$GH_ORG/serena-forge"       serena-forge serena-forge
  ensure_plugin "bdfinst/agentic-dev-team"   bfinster     dev-team
}

# ---------------------------------------------------------------------------
# Skills (~/.claude/skills) — all vendored under setup/skills, copied on every
# run. install_skill wipes its destination, so a skill edited in ~/.claude/skills
# is lost on the next run: change it HERE, in the repo.
# ---------------------------------------------------------------------------
install_skill() {
  local name="$1" src="$ROOT/setup/skills/$1" dest="$HOME/.claude/skills/$1"
  [ -d "$src" ] || { warn "skill source missing: $src"; return 0; }
  rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
  cp -R "$src" "$dest"
  ok "skill $name -> ~/.claude/skills/$name"
}

ensure_skills() {
  say "Skills"
  local s
  for s in atlassian context7 azure-devops aspire-cli datadog; do install_skill "$s"; done
}

# ---------------------------------------------------------------------------
# lean-ctx — the context layer (replaces ctx-wire + caveman + ponytail + CodeGraph)
# ---------------------------------------------------------------------------
ensure_lean_ctx() {
  [ "$SKIP_LEANCTX" = 1 ] && return 0
  if have lean-ctx && [ "$NO_UPDATE" = 1 ]; then
    ok "lean-ctx $(lean-ctx --version 2>/dev/null | head -1)"
  else
    say "Installing/updating lean-ctx (context layer)"
    if have lean-ctx; then
      lean-ctx update >/dev/null 2>&1 || true
    fi
    if ! have lean-ctx; then
      curl -fsSL https://leanctx.com/install.sh | sh >/dev/null 2>&1 || true
      hash -r 2>/dev/null || true
    fi
    if ! have lean-ctx && have npm; then
      npm install -g lean-ctx-bin >/dev/null 2>&1 || true; hash -r 2>/dev/null || true
    fi
    if ! have lean-ctx && have cargo; then
      cargo install lean-ctx >/dev/null 2>&1 || true; hash -r 2>/dev/null || true
    fi
    have lean-ctx && ok "lean-ctx $(lean-ctx --version 2>/dev/null | head -1)" \
                  || { warn "lean-ctx install failed — https://leanctx.com"; return 0; }
  fi

  # Hybrid mode: MCP tools + shell-output compression (Claude Code has shell access).
  say "Wiring lean-ctx into Claude Code (hybrid mode)"
  lean-ctx init --agent claude --mode hybrid >/dev/null 2>&1 \
    || lean-ctx init --agent claude >/dev/null 2>&1 \
    || warn "lean-ctx init failed — run: lean-ctx init --agent claude"

  # Tool profile (minimal|standard|power). standard (16 tools) is the sane default;
  # power (68+) is reachable at runtime via ctx_load_tools.
  lean-ctx tools "$LEANCTX_PROFILE" >/dev/null 2>&1 || true
  ok "lean-ctx tool profile: $LEANCTX_PROFILE"

  # Config: keep Claude Code's native read-before-write gate (auto), don't compress
  # the human's interactive shell, and on --leanctx-edit=off disable lean-ctx's own
  # edit tools so ALL editing goes native + Serena. On 'guard' (default) the edit
  # tools stay enabled and serena-forge's guard-leanctx-write hook denies only .cs.
  local cfg="$HOME/.config/lean-ctx/config.toml"
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"
  local b="# >>> serena-forge managed >>>" e="# <<< serena-forge managed <<<"
  local tmp; tmp="$(mktemp)"
  sed "/^${b}$/,/^${e}$/d" "$cfg" > "$tmp" 2>/dev/null || true
  {
    cat "$tmp"
    echo "$b"
    echo "# Managed by serena-forge setup/install-wsl.sh — regenerated on every run."
    echo 'read_redirect = "auto"   # keep Claude Code'\''s native read-before-write gate'
    echo 'read_dedup = "auto"'
    echo 'shell_activation = "agents-only"   # do not compress the human'\''s interactive shell'
    if [ "$LEANCTX_EDIT" = "off" ]; then
      echo 'disabled_tools = ["ctx_patch", "ctx_edit", "ctx_fill"]   # --leanctx-edit=off: all edits go native + Serena'
    fi
    echo "$e"
  } > "$cfg"
  rm -f "$tmp"
  [ "$LEANCTX_EDIT" = "off" ] \
    && ok "lean-ctx edit tools DISABLED (editing via native tools + Serena only)" \
    || ok "lean-ctx edit tools kept (serena-forge guard denies .cs; other languages allowed)"

  lean-ctx doctor >/dev/null 2>&1 && ok "lean-ctx doctor: wiring active" \
    || warn "lean-ctx doctor reported issues — run: lean-ctx doctor"
}

# Optional: sync lean-ctx's learned knowledge into a git repo as OKF Markdown, so
# it survives a reinstall and can be shared/reviewed by the team.
install_leanctx_kb_sync() {
  [ -n "$LEANCTX_KB_REPO" ] || return 0
  have lean-ctx || return 0
  local repo="${LEANCTX_KB_REPO/#\~/$HOME}" wrapper="$HOME/.local/bin/leanctx-kb-sync"
  say "Installing leanctx-kb-sync (OKF knowledge -> git: $repo)"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# Export lean-ctx knowledge as OKF Markdown into a git repo and commit it, so the
# learned memory survives reinstalls and can be reviewed/shared. Run manually or
# from cron. Restore on a new machine with: lean-ctx knowledge import <dir> --merge append
set -euo pipefail
REPO="$repo"
mkdir -p "\$REPO"
lean-ctx knowledge export --format okf --output "\$REPO/kb-okf"
cd "\$REPO"
if [ -d .git ] && ! git diff --quiet -- kb-okf 2>/dev/null; then
  git add kb-okf
  git commit -m "chore(kb): sync lean-ctx knowledge (OKF)" >/dev/null
  echo "leanctx-kb-sync: committed knowledge update"
else
  echo "leanctx-kb-sync: no changes (or not a git repo)"
fi
EOF
  chmod +x "$wrapper"
  ok "leanctx-kb-sync installed — run it to snapshot knowledge into $repo"
}

# ---------------------------------------------------------------------------
# ctx7 (docs CLI), Docker, aoe — unchanged domain tooling
# ---------------------------------------------------------------------------
ensure_ctx7() {
  have npm || { warn "npm missing — skipping ctx7"; return 0; }
  if have ctx7 && [ "$NO_UPDATE" = 1 ]; then ok "ctx7 present"; return; fi
  say "Installing/updating ctx7"
  npm install -g ctx7@latest >/dev/null 2>&1 && ok "ctx7 $(ctx7 --version 2>/dev/null | head -1)" || warn "ctx7 install failed"
}

ensure_docker() {
  if have docker; then
    [ "$NO_UPDATE" = 1 ] || apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "docker $(docker --version 2>/dev/null | head -1)"
  else
    say "Installing Docker Engine (native, official apt repo)"
    sudo install -dm755 /etc/apt/keyrings 2>/dev/null || true
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null || true
    APT_UPDATED=0
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    have docker || { warn "docker install failed — https://docs.docker.com/engine/install/ubuntu/"; return 0; }
    ok "docker $(docker --version 2>/dev/null | head -1)"
  fi
  if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
    sudo groupadd -f docker 2>/dev/null || true
    sudo usermod -aG docker "$USER" 2>/dev/null \
      && warn "added $USER to the docker group — log out/in (or 'wsl --shutdown') for it to apply" || true
  fi
  if have systemctl && [ -d /run/systemd/system ]; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable the docker service — check 'systemctl status docker'"
  else
    warn "systemd not active in this WSL distro — enable it ([boot] systemd=true in /etc/wsl.conf) then re-run"
  fi
}

ensure_aoe() {
  apt_install tmux
  if have aoe && [ "$NO_UPDATE" = 1 ]; then ok "aoe $(aoe --version 2>/dev/null | head -1)"; return; fi
  say "Installing/updating agent-of-empires (aoe)"
  curl -fsSL https://raw.githubusercontent.com/agent-of-empires/agent-of-empires/main/scripts/install.sh | bash >/dev/null 2>&1 \
    || warn "aoe install failed — https://github.com/agent-of-empires/agent-of-empires"
  hash -r 2>/dev/null || true
  have aoe && ok "aoe $(aoe --version 2>/dev/null | head -1)" || warn "aoe not on PATH"
}

# systemd-binfmt rewrites /proc/sys/fs/binfmt_misc from /usr/lib/binfmt.d and
# drops WSL's own WSLInterop registration, after which every Windows .exe fails
# with "Exec format error" — including the PowerShell clipboard bridge below.
# Declaring it as a binfmt.d unit makes the registration survive the rewrite.
ensure_wsl_interop() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || return 0
  local conf=/usr/lib/binfmt.d/WSLInterop.conf line=':WSLInterop:M::MZ::/init:PF'
  if [ "$(cat "$conf" 2>/dev/null)" != "$line" ]; then
    say "Registering WSLInterop with systemd-binfmt"
    printf '%s\n' "$line" | sudo tee "$conf" >/dev/null || { warn "could not write $conf"; return 0; }
  fi
  if [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    sudo systemctl restart systemd-binfmt >/dev/null 2>&1 || warn "systemd-binfmt restart failed"
  fi
  [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
    && ok "WSLInterop registered (Windows .exe callable)" \
    || warn "WSLInterop still unregistered — Windows executables will fail"
  return 0
}

# Copy/paste between tmux panes and the Windows clipboard. wl-copy is unreliable
# under WSLg and clip.exe mangles UTF-8, so both directions go through PowerShell
# with the encoding pinned. Mouse stays OFF: Claude Code panes capture the mouse,
# tmux never enters copy-mode, and a drag falls through to Windows Terminal's
# native selection (which needs copyOnSelect:true on the Windows side).
ensure_tmux_clipboard() {
  local ps1=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$ps1" ] || { warn "powershell.exe not found — skipping the tmux clipboard bridge"; return 0; }
  say "tmux clipboard bridge (Windows)"

  cat > "$HOME/.local/bin/tmux-clip-copy" <<EOF
#!/bin/sh
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
exec $ps1 -NoProfile -Command '[Console]::InputEncoding=[Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())'
EOF
  cat > "$HOME/.local/bin/tmux-clip-paste" <<EOF
#!/bin/sh
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
exec $ps1 -NoProfile -Command '[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Clipboard -Raw'
EOF
  chmod +x "$HOME/.local/bin/tmux-clip-copy" "$HOME/.local/bin/tmux-clip-paste"

  local conf="$HOME/.tmux.conf" b="# >>> serena-forge managed >>>" e="# <<< serena-forge managed <<<" tmp
  touch "$conf"; tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$conf" > "$tmp"
  {
    cat "$tmp"
    printf '%s\n' "$b"
    cat <<EOF
set -g mouse off
set -g mode-keys vi
set -g set-clipboard on
set -g copy-command '$HOME/.local/bin/tmux-clip-copy'
bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel
bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel
bind-key p run-shell '$HOME/.local/bin/tmux-clip-paste | tmux load-buffer - && tmux paste-buffer'
EOF
    printf '%s\n' "$e"
  } > "$conf"
  rm -f "$tmp"
  ok "~/.tmux.conf clipboard block + tmux-clip-copy/paste wrappers"
  return 0
}

# ---------------------------------------------------------------------------
# acli (Atlassian CLI)
# ---------------------------------------------------------------------------
ensure_acli() {
  [ "$SKIP_ACLI" = 1 ] && return 0
  local arch
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) warn "unsupported arch for acli"; return 0 ;; esac
  if ! have acli || [ "$NO_UPDATE" = 0 ]; then
    say "Installing/updating acli (Atlassian CLI)"
    if curl -fsSL -o "$HOME/.local/bin/acli.new" "https://acli.atlassian.com/linux/latest/acli_linux_${arch}/acli"; then
      chmod +x "$HOME/.local/bin/acli.new" && mv "$HOME/.local/bin/acli.new" "$HOME/.local/bin/acli"
    else
      rm -f "$HOME/.local/bin/acli.new"; warn "acli download failed"
    fi
  fi
  have acli || return 0
  ok "acli $(acli --version 2>/dev/null | head -1)"
  if ! acli jira auth status >/dev/null 2>&1; then
    say "Atlassian auth (acli)"
    if require_var ACLI_SITE  "Atlassian site (e.g. yourorg.atlassian.net)" plain \
       && require_var ACLI_EMAIL "Atlassian account email" plain \
       && require_var ACLI_TOKEN "Atlassian API token (https://id.atlassian.com/manage-profile/security/api-tokens)" secret; then
      printf '%s' "$ACLI_TOKEN" | acli jira auth login --site "$ACLI_SITE" --email "$ACLI_EMAIL" --token \
        && ok "acli authenticated on $ACLI_SITE" \
        || warn "acli auth failed — retry: acli jira auth login"
    fi
  else
    ok "acli already authenticated"
  fi
}

# ---------------------------------------------------------------------------
# Azure DevOps
# ---------------------------------------------------------------------------
ensure_az_devops() {
  [ "$SKIP_AZ" = 1 ] && return 0
  say "Azure CLI + azure-devops extension"
  if ! have az; then
    have pipx || { warn "pipx missing — cannot install az"; return 0; }
    pipx install azure-cli >/dev/null 2>&1 || { warn "az install failed (pipx install azure-cli)"; return 0; }
    pipx ensurepath >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
  elif [ "$NO_UPDATE" = 0 ]; then
    pipx upgrade azure-cli >/dev/null 2>&1 || true
  fi
  have az || { warn "az not on PATH"; return 0; }
  az extension add --name azure-devops --upgrade --only-show-errors >/dev/null 2>&1 || warn "azure-devops extension install failed"
  ok "az $(az version --query '"azure-cli"' -o tsv 2>/dev/null) + azure-devops extension"
  if require_var AZURE_DEVOPS_ORG "Azure DevOps organization name (dev.azure.com/<org>)" plain; then
    require_var AZURE_DEVOPS_PROJECT "Default Azure DevOps project (optional, Enter to skip)" plain || true
    az devops configure --defaults "organization=https://dev.azure.com/$AZURE_DEVOPS_ORG" \
      ${AZURE_DEVOPS_PROJECT:+"project=$AZURE_DEVOPS_PROJECT"} >/dev/null 2>&1 || true
    if require_var AZURE_DEVOPS_PAT "Azure DevOps PAT (Code R/W, PR R/W, Build R)" secret; then
      persist_secret AZURE_DEVOPS_EXT_PAT "$AZURE_DEVOPS_PAT"
      export AZURE_DEVOPS_EXT_PAT="$AZURE_DEVOPS_PAT"
      printf '%s' "$AZURE_DEVOPS_PAT" | az devops login --organization "https://dev.azure.com/$AZURE_DEVOPS_ORG" >/dev/null 2>&1 \
        && ok "az devops logged in ($AZURE_DEVOPS_ORG)" \
        || warn "az devops login failed — check the PAT"
    fi
  fi
}

# ---------------------------------------------------------------------------
# dev-team tooling: CodeGraph, ast-grep, semgrep
# ---------------------------------------------------------------------------
ensure_codegraph() {
  if have codegraph; then
    [ "$NO_UPDATE" = 1 ] || { say "Updating CodeGraph"; codegraph upgrade >/dev/null 2>&1 || true; }
  else
    say "Installing CodeGraph"
    if have npm; then npm install -g @colbymchenry/codegraph >/dev/null 2>&1 || true; fi
    have codegraph || curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh || true
    hash -r 2>/dev/null || true
  fi
  have codegraph && ok "codegraph $(codegraph --version 2>/dev/null | head -1)" \
    || warn "codegraph install failed — https://github.com/colbymchenry/codegraph"
}

ensure_ast_grep() {
  have npm || { warn "npm missing — skipping ast-grep"; return 0; }
  if have ast-grep && [ "$NO_UPDATE" = 1 ]; then ok "ast-grep $(ast-grep --version 2>/dev/null)"; return; fi
  say "Installing/updating ast-grep"
  npm install -g @ast-grep/cli@latest >/dev/null 2>&1 \
    && ok "ast-grep $(ast-grep --version 2>/dev/null)" || warn "ast-grep install failed"
}

ensure_semgrep() {
  have pipx || { warn "pipx missing — skipping semgrep"; return 0; }
  if have semgrep; then
    [ "$NO_UPDATE" = 1 ] || pipx upgrade semgrep >/dev/null 2>&1 || true
  else
    say "Installing semgrep (dev-team semgrep-analyze skill)"
    pipx install semgrep >/dev/null 2>&1 || { warn "semgrep install failed"; return 0; }
  fi
  ok "semgrep $(semgrep --version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# Repo indexing — Serena `project index` per C# repo, and each repo registered +
# indexed as a lean-ctx root (cross-repo SEARCH; lean-ctx replaces CodeGraph's
# cross-repo find/read, though not a cross-repo graph — see the migration doc).
# ---------------------------------------------------------------------------
run_ticking() {
  local label="$1" wd="$2"; shift 2
  local pid s=0 rc=0
  ( cd "$wd" && "$@" ) </dev/null >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  … %s (%ds)   ' "$label" "$s"
    sleep 2; s=$((s + 2))
  done
  printf '\r\033[K'
  wait "$pid" || rc=$?
  return "$rc"
}

# CodeGraph: ONE index at $CODE_ROOT covering every repo under it — the cross-repo
# structural case neither lean-ctx (per-repo graph) nor Serena (per-repo, C#-only)
# can answer. Served to every session by a user-scope MCP server through a wrapper
# that cd's to the root first.
#
# dev-team's own per-repo CodeGraph wiring stays dormant: codegraph_bootstrap only
# acts when the REPO's .mcp.json references codegraph, and codegraph_nudge's
# sentinel is a repo-local .codegraph/ dir. We create neither, so only the root
# graph is exposed — and dev-team's turn-mark hook matches mcp__codegraph__* anyway.
register_codegraph_root() {  # register_codegraph_root <root>
  local root="$1" wrapper="$HOME/.local/bin/codegraph-root"
  cat > "$wrapper" <<EOF
#!/bin/sh
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# Serves the CODE_ROOT-level CodeGraph index to every Claude Code session.
cd "$root" || exit 1
exec codegraph serve --mcp
EOF
  chmod +x "$wrapper"
  if have claude && ! claude mcp get codegraph >/dev/null 2>&1; then
    claude mcp add -s user codegraph -- "$wrapper" >/dev/null 2>&1 \
      && ok "codegraph MCP registered (user scope, root graph)" \
      || warn "codegraph MCP registration failed — run: claude mcp add -s user codegraph -- $wrapper"
  fi
}

# Managed block in ~/.claude/CLAUDE.md, replaced in place on every run. Three
# code-intelligence layers ship together, so the routing has to be stated once.
write_codegraph_claude_md() {  # write_codegraph_claude_md <root>
  local root="$1" tmp
  local b="<!-- >>> serena-forge setup: codegraph root >>> -->" e="<!-- <<< serena-forge setup: codegraph root <<< -->"
  mkdir -p "$(dirname "$USER_CLAUDE_MD")"; touch "$USER_CLAUDE_MD"
  tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$USER_CLAUDE_MD" > "$tmp"
  {
    cat "$tmp"
    printf '\n%s\n' "$b"
    cat <<EOF
## Code intelligence — three layers, one rule each
- **CodeGraph** (\`mcp__codegraph__*\`) — structure. A user-scope MCP server holds
  ONE graph over every repo under \`$root\`. Use it for cross-repo or multi-file
  exploration, "who calls X", and blast radius, before any Read/Grep sweep.
- **lean-ctx** (\`ctx_*\`) — compression, search and code memory. Its graph is
  per-repo, so it does not replace CodeGraph for cross-repo questions.
- **Serena** (serena-forge) — C# symbols. The Roslyn source of truth for reading
  and editing \`.cs\` in the current repo. Never edit C# around it.

Read/Grep/Glob stay for confirming one specific detail you already located.
EOF
    printf '%s\n' "$e"
  } > "$USER_CLAUDE_MD"
  rm -f "$tmp"
  ok "code-intelligence routing note written to ~/.claude/CLAUDE.md (managed block)"
}

# lean-ctx `index build` and `graph build` are incremental (unchanged files reused
# via content hash), so this is cheap to re-run. Runs with cwd already at the repo.
leanctx_index_repo() {
  lean-ctx index build || lean-ctx index build-full || return 1
  lean-ctx graph build || return 1
}

index_repos() {
  [ "$SKIP_INDEX" = 1 ] && return 0
  say "Repo indexing (CodeGraph at the root + lean-ctx and Serena per repo)"
  if ! require_var CODE_ROOT "Root folder containing your git repos (e.g. ~/code — Enter to skip indexing)" plain; then
    return 0
  fi
  local root="${CODE_ROOT/#\~/$HOME}"
  [ -d "$root" ] || { warn "CODE_ROOT does not exist: $root — skipping indexing"; return 0; }

  if have codegraph; then
    if [ -d "$root/.codegraph" ]; then
      say "CodeGraph: syncing the root graph ($root)"
      run_ticking "codegraph sync" "$root" codegraph sync && ok "codegraph sync" || warn "codegraph sync failed"
    else
      say "CodeGraph: building the root graph ($root — first run can take a while)"
      run_ticking "codegraph init (first build)" "$root" codegraph init -i && ok "codegraph init" || warn "codegraph init failed"
    fi
    [ -d "$root/.codegraph" ] && { register_codegraph_root "$root"; write_codegraph_claude_md "$root"; }
  fi

  local gitdir repo count=0
  while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"; count=$((count + 1))
    if have lean-ctx && [ "$SKIP_LEANCTX" = 0 ]; then
      run_ticking "lean-ctx index $(basename "$repo")" "$repo" leanctx_index_repo \
        && ok "  lean-ctx indexed $(basename "$repo")" || warn "  lean-ctx index failed for $(basename "$repo")"
    fi
    if have uvx && [ -n "$(find "$repo" -maxdepth 3 \( -name '*.sln' -o -name '*.csproj' \) -not -path '*/bin/*' -not -path '*/obj/*' -print -quit 2>/dev/null)" ]; then
      say "Serena: indexing $repo (Roslyn — can take a while on first run)"
      # --language csharp: without it Serena auto-creates project.yml, prompts
      # "enable <lang> too?" on stray files, reads EOF under run_ticking and dies.
      run_ticking "serena index $(basename "$repo")" "$repo" \
        uvx -p 3.13 --from git+https://github.com/oraios/serena serena project index --language csharp "$repo" \
        && ok "  serena index" || warn "  serena index failed"
    fi
  done < <(find "$root" -maxdepth 3 -name .git \( -type d -o -type f \) -not -path '*/node_modules/*' 2>/dev/null)
  [ "$count" = 0 ] && warn "no git repos found under $root" || ok "$count repo(s) scanned"
  return 0
}

# ---------------------------------------------------------------------------
# Atlassian MCP — the write fallback behind the `atlassian` skill. acli stays the
# primary (reads, most writes); this server covers what its build cannot do:
# Confluence page create/update, worklogs, comment edits, typed links, sprints.
# NOT the official remote mcp.atlassian.com server — this is sooperset's local
# container, authenticated with the same site + API token as acli, and narrowed
# to the gap tools so it doesn't shadow acli's surface.
# ---------------------------------------------------------------------------
ATLASSIAN_MCP_IMAGE="ghcr.io/sooperset/mcp-atlassian:latest"
ATLASSIAN_MCP_TOOLS="jira_add_worklog,jira_get_worklog,jira_edit_comment,jira_link_to_epic,jira_create_remote_issue_link,jira_remove_issue_link,jira_batch_create_issues,jira_batch_create_versions,jira_create_version,jira_get_project_versions,jira_get_project_components,jira_create_sprint,jira_update_sprint,jira_add_issues_to_sprint,jira_search_fields,jira_get_field_options,jira_get_link_types,jira_get_issue_development_info,jira_get_issues_development_info,jira_get_issue_sla,jira_get_issue_dates,jira_get_issue_proforma_forms,jira_get_proforma_form_details,jira_update_proforma_form_answers,jira_get_service_desk_for_project,jira_get_service_desk_queues,jira_get_queue_issues,jira_batch_get_changelogs,jira_get_user_profile,confluence_create_page,confluence_update_page,confluence_delete_page,confluence_move_page,confluence_add_comment,confluence_reply_to_comment,confluence_get_comments,confluence_add_label,confluence_get_labels,confluence_search,confluence_search_user,confluence_get_page_children,confluence_get_space_page_tree,confluence_get_page_history,confluence_get_page_diff,confluence_get_page_views,confluence_get_page_images,confluence_get_attachments,confluence_download_attachment,confluence_download_content_attachments,confluence_upload_attachment,confluence_upload_attachments,confluence_delete_attachment"

ensure_atlassian_mcp() {
  [ "$SKIP_ATLASSIAN_MCP" = 1 ] && return 0
  have claude || return 0
  have docker || { warn "docker missing — skipping the Atlassian MCP server"; return 0; }
  say "Atlassian MCP (write fallback for the acli skill)"
  if claude mcp get atlassian >/dev/null 2>&1; then
    ok "atlassian MCP already registered (remove it first to rotate the token)"
    return 0
  fi
  require_var ACLI_SITE  "Atlassian site (e.g. yourorg.atlassian.net)" plain \
    && require_var ACLI_EMAIL "Atlassian account email" plain \
    && require_var ACLI_TOKEN "Atlassian API token" secret \
    || { warn "Atlassian credentials unavailable — skipping the MCP server"; return 0; }

  docker pull "$ATLASSIAN_MCP_IMAGE" >/dev/null 2>&1 || warn "could not pre-pull $ATLASSIAN_MCP_IMAGE"
  claude mcp add -s user atlassian \
    -e "JIRA_URL=https://$ACLI_SITE" \
    -e "JIRA_USERNAME=$ACLI_EMAIL" \
    -e "JIRA_API_TOKEN=$ACLI_TOKEN" \
    -e "CONFLUENCE_URL=https://$ACLI_SITE/wiki" \
    -e "CONFLUENCE_USERNAME=$ACLI_EMAIL" \
    -e "CONFLUENCE_API_TOKEN=$ACLI_TOKEN" \
    -e "ENABLED_TOOLS=$ATLASSIAN_MCP_TOOLS" \
    -- docker run -i --rm \
      -e JIRA_URL -e JIRA_USERNAME -e JIRA_API_TOKEN \
      -e CONFLUENCE_URL -e CONFLUENCE_USERNAME -e CONFLUENCE_API_TOKEN \
      -e ENABLED_TOOLS "$ATLASSIAN_MCP_IMAGE" >/dev/null 2>&1 \
    && ok "atlassian MCP registered (mcp__atlassian__* tools appear after a session restart)" \
    || warn "atlassian MCP registration failed — check 'claude mcp list'"
  return 0
}

# ---------------------------------------------------------------------------
# Miro MCP (remote, OAuth completed in-session via /mcp)
# ---------------------------------------------------------------------------
ensure_miro() {
  [ "$SKIP_MIRO" = 1 ] && return 0
  have claude || return 0
  say "Miro MCP"
  if claude mcp get miro >/dev/null 2>&1; then ok "miro MCP already registered"
  else
    claude mcp add -s user -t http miro https://mcp.miro.com >/dev/null 2>&1 \
      && ok "miro MCP registered (run /mcp in Claude Code to complete the OAuth)" \
      || warn "miro MCP registration failed — run: claude mcp add -s user -t http miro https://mcp.miro.com"
  fi
}

# ---------------------------------------------------------------------------
# Second brain — business-knowledge vault (kept; distinct from lean-ctx memory)
# ---------------------------------------------------------------------------
render_brain_configs() {
  local tmpdir="${TMPDIR:-/tmp}" tpl="$BRAIN_DIR/.claude/settings.json.template"
  local node_repl='/bin/sh \\"'"$BRAIN_DIR"'/scripts/run-node.sh\\"'
  if [ ! -f "$BRAIN_DIR/.mcp.json" ]; then
    cat > "$BRAIN_DIR/.mcp.json" <<EOF
{
  "mcpServers": {
    "vault-rag": {
      "type": "stdio",
      "command": "/bin/sh",
      "args": ["rag/launch.sh"],
      "cwd": "$BRAIN_DIR",
      "env": {}
    }
  }
}
EOF
    ok "rendered .mcp.json (vault-rag MCP)"
  fi
  if [ -f "$tpl" ] && [ ! -f "$BRAIN_DIR/.claude/settings.json" ]; then
    sed -e "s|{{PROJECT_ROOT}}|$BRAIN_DIR|g" \
        -e "s|{{TMP_DIR}}|$tmpdir|g" \
        -e "s|{{NODE}}|$node_repl|g" "$tpl" > "$BRAIN_DIR/.claude/settings.json"
    if have jq && ! jq empty "$BRAIN_DIR/.claude/settings.json" >/dev/null 2>&1; then
      warn "rendered settings.json is not valid JSON — check $BRAIN_DIR/.claude/settings.json"
    else
      ok "rendered .claude/settings.json (auto-commit/auto-push hooks, statusline)"
    fi
  fi
}

register_vault_rag_user() {
  local wrapper="$HOME/.local/bin/vault-rag-server.sh"
  mkdir -p "$HOME/.local/bin"
  cat > "$wrapper" <<EOF
#!/bin/sh
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# Serves the second-brain vault-rag MCP to EVERY Claude Code session (user scope).
cd "$BRAIN_DIR" || exit 1
exec /bin/sh rag/launch.sh
EOF
  chmod +x "$wrapper"
  if have claude && ! claude mcp get vault-rag >/dev/null 2>&1; then
    claude mcp add -s user vault-rag -- "$wrapper" >/dev/null 2>&1 \
      && ok "vault-rag MCP registered (user scope)" \
      || warn "vault-rag MCP registration failed — run: claude mcp add -s user vault-rag -- $wrapper"
  fi
}

ensure_second_brain() {
  [ "$SKIP_BRAIN" = 1 ] && return 0
  say "Second brain ($BRAIN_DIR)"
  clone_or_update "$GH_ORG/second-brain" "$BRAIN_DIR"
  [ -d "$BRAIN_DIR" ] || { warn "second brain not available — skipping"; return 0; }
  render_brain_configs
  [ -f "$BRAIN_DIR/.env" ] || { cp "$BRAIN_DIR/.env.example" "$BRAIN_DIR/.env" 2>/dev/null || true; }
  if [ -f "$BRAIN_DIR/.env" ] \
     && ! grep -qE '^GOOGLE_GEMINI_API_KEY=.+' "$BRAIN_DIR/.env" \
     && ! grep -qE '^EMBEDDING_PROVIDER=.+' "$BRAIN_DIR/.env"; then
    if require_var GOOGLE_GEMINI_API_KEY "Google Gemini API key (https://aistudio.google.com/apikey)" secret; then
      if grep -qE '^GOOGLE_GEMINI_API_KEY=' "$BRAIN_DIR/.env"; then
        sed -i "s|^GOOGLE_GEMINI_API_KEY=.*|GOOGLE_GEMINI_API_KEY=$GOOGLE_GEMINI_API_KEY|" "$BRAIN_DIR/.env"
      else
        printf 'GOOGLE_GEMINI_API_KEY=%s\n' "$GOOGLE_GEMINI_API_KEY" >> "$BRAIN_DIR/.env"
      fi
      ok "GOOGLE_GEMINI_API_KEY written to $BRAIN_DIR/.env"
    fi
  fi
  if have npm; then
    say "Installing the RAG engine (npm install in rag/)"
    (cd "$BRAIN_DIR/rag" && npm install --no-fund --no-audit --silent) \
      && ok "RAG engine ready" || warn "npm install failed in $BRAIN_DIR/rag"
    register_vault_rag_user
  else
    warn "npm missing — RAG engine not installed"
  fi
}

# ---------------------------------------------------------------------------
# .NET Aspire CLI + pup (Datadog CLI)
# ---------------------------------------------------------------------------
ensure_aspire() {
  local abin="$HOME/.aspire/bin/aspire"
  if ! { [ -x "$abin" ] && [ "$NO_UPDATE" = 1 ]; }; then
    say "Installing/updating .NET Aspire CLI (~/.aspire/bin)"
    curl -fsSL https://aka.ms/aspire/get/install.sh | bash -s -- --skip-path >/dev/null 2>&1 \
      || warn "aspire CLI install failed — see https://aspire.dev"
  fi
  if [ -d "$HOME/.aspire/bin" ]; then
    case ":$PATH:" in *":$HOME/.aspire/bin:"*) ;; *) export PATH="$HOME/.aspire/bin:$PATH" ;; esac
  fi
  if [ -x "$abin" ]; then ok "aspire $("$abin" --version 2>/dev/null | head -1)"; fi
}

ensure_pup() {
  local arch ver asset url tmp bin
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;;
    *) warn "pup: unsupported arch $(uname -m)"; return 0 ;;
  esac
  if have pup && [ "$NO_UPDATE" = 1 ]; then ok "pup $(pup --version 2>/dev/null | head -1)"; return 0; fi
  say "Installing/updating pup (Datadog CLI, EU site)"
  ver="$(curl -fsSL https://api.github.com/repos/DataDog/pup/releases/latest 2>/dev/null | jq -r '.tag_name // empty')"
  [ -n "$ver" ] || { warn "pup: could not resolve latest release (GitHub API)"; return 0; }
  asset="pup_${ver#v}_Linux_${arch}.tar.gz"
  url="https://github.com/DataDog/pup/releases/download/${ver}/${asset}"
  tmp="$(mktemp -d)"
  if curl -fsSL "$url" -o "$tmp/pup.tgz" && tar -xzf "$tmp/pup.tgz" -C "$tmp"; then
    bin="$(find "$tmp" -type f -name pup | head -1)"
    if [ -n "$bin" ] && install -m 0755 "$bin" "$HOME/.local/bin/pup"; then
      ok "pup $("$HOME/.local/bin/pup" --version 2>/dev/null | head -1)"
    else
      warn "pup: could not install binary into ~/.local/bin"
    fi
  else
    warn "pup: download failed ($url)"
  fi
  rm -rf "$tmp"
  if have pup && ! pup auth status >/dev/null 2>&1; then
    warn "pup not authenticated — run: pup auth login (browser OAuth, EU site)"
  fi
}

# ---------------------------------------------------------------------------
# Local Claude Code config — statusline, context window, PostToolUse hooks.
#
# ~/.claude/settings.json is shared with tools that write to it at runtime (aoe
# injects its own hooks on every launch), so this is a jq merge, never a rewrite.
# Our hook entries are tagged `# serena-forge managed` and replaced by tag.
# ---------------------------------------------------------------------------
ensure_clepsydre() {
  local dest="$SRC_DIR/clepsydre"
  clone_or_update "tpierrain/clepsydre" "$dest"
  [ -f "$dest/clepsydre.mjs" ] || { warn "clepsydre.mjs missing — statusline gauge disabled"; return 1; }
  say "Statusline (clepsydre gauge)"
  sed "s|{{CLEPSYDRE}}|$dest/clepsydre.mjs|g" "$ROOT/setup/statusline.sh" > "$HOME/.claude/statusline.sh"
  chmod +x "$HOME/.claude/statusline.sh"
  ok "~/.claude/statusline.sh"
}

ensure_claude_settings() {
  [ "$SKIP_LOCAL_CONFIG" = 1 ] && return 0
  have jq || { warn "jq missing — skipping ~/.claude/settings.json"; return 0; }
  say "Claude Code local settings"

  mkdir -p "$HOME/.claude/scripts"
  install -m 0755 "$ROOT/setup/scripts/no-comments-check.sh" "$HOME/.claude/scripts/no-comments-check.sh"
  ok "~/.claude/scripts/no-comments-check.sh"

  ensure_clepsydre || return 0

  local settings="$HOME/.claude/settings.json" managed tmp
  [ -s "$settings" ] || printf '{}\n' > "$settings"
  jq empty "$settings" 2>/dev/null || { warn "$settings is not valid JSON — leaving it alone"; return 0; }
  cp "$settings" "$settings.bak.$(date +%Y%m%dT%H%M%S)"

  managed="$(mktemp)"
  cat > "$managed" <<'JSON'
{
  "matcher": "Edit|Write|MultiEdit|mcp__plugin_serena-forge_serena__(replace_symbol_body|insert_after_symbol|insert_before_symbol|replace_in_files|replace_content|create_text_file|rename_symbol|safe_delete_symbol)",
  "hooks": [
    {
      "type": "command",
      "statusMessage": "Normalizing line endings to CRLF",
      "command": "f=$(jq -r '.tool_input.file_path // .tool_input.relative_path // empty'); [ -n \"$f\" ] && [ -f \"$f\" ] && case \"$f\" in *.cs|*.csproj|*.props|*.targets|*.json|*.editorconfig|*.md|*.yml|*.yaml) perl -i -pe 's/\\r?\\n/\\r\\n/' \"$f\";; esac 2>/dev/null || true # serena-forge managed"
    },
    {
      "type": "command",
      "statusMessage": "Checking for forbidden comments",
      "command": "f=$(jq -r '.tool_input.file_path // .tool_input.relative_path // empty'); case \"$f\" in *.cs) cd \"$(dirname \"$f\")\" 2>/dev/null && \"$HOME/.claude/scripts/no-comments-check.sh\" HEAD;; esac # serena-forge managed"
    }
  ]
}
JSON

  tmp="$(mktemp)"
  jq --slurpfile m "$managed" --arg sl "bash \"$HOME/.claude/statusline.sh\"" '
    .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = "230000"
    | .statusLine = { type: "command", command: $sl, padding: 0 }
    | .hooks.PostToolUse = (
        ((.hooks.PostToolUse // [])
          | map(select([.hooks[]?.command // "" | contains("serena-forge managed")] | any | not)))
        + $m )
  ' "$settings" > "$tmp" && mv "$tmp" "$settings" \
    && ok "settings.json: statusline, auto-compact window, CRLF + no-comments hooks" \
    || warn "settings.json merge failed — restore from the .bak next to it"
  rm -f "$managed" "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------
doctor() {
  bold "Doctor"
  local fail=0 t
  check() {
    local tool="$1" req="$2" vc="${3:-}" v=""
    if have "$tool"; then
      [ -n "$vc" ] && v="$(eval "$vc" 2>/dev/null | head -1)"
      ok "$tool ${v:+($v)}"
    elif [ "$req" = required ]; then warn "$tool MISSING (required)"; fail=1
    else warn "$tool not found (optional)"; fi
  }
  check git      required "git --version"
  check node     required "node --version"
  check jq       required "jq --version"
  check gh       required "gh --version"
  check claude   required "claude --version"
  case "$(command -v claude 2>/dev/null)" in
    /mnt/*|/c/*) warn "claude resolves to the Windows install ($(command -v claude)) — native Linux Claude Code is NOT on PATH; re-run to install it"; fail=1;;
  esac
  check uvx      required "uvx --version"
  check dotnet   optional "dotnet --version"
  check lean-ctx optional "lean-ctx --version"
  check ctx7     optional
  check docker   optional "docker --version"
  check aoe      optional "aoe --version"
  check ast-grep optional "ast-grep --version"
  check semgrep  optional "semgrep --version"
  check acli     optional "acli --version"
  check az       optional
  check aspire   optional "aspire --version"
  check pup      optional "pup --version"
  check codegraph optional "codegraph --version"
  check tmux     optional "tmux -V"
  have claude && ! claude mcp get codegraph >/dev/null 2>&1 \
    && warn "codegraph MCP not registered — re-run without --skip-index"
  have claude && [ "$SKIP_ATLASSIAN_MCP" = 0 ] && ! claude mcp get atlassian >/dev/null 2>&1 \
    && warn "atlassian MCP not registered — the acli skill loses its write fallback"
  [ -x "$HOME/.claude/statusline.sh" ] || warn "~/.claude/statusline.sh missing"
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
    && { warn "WSLInterop unregistered — Windows .exe (clipboard bridge) will fail"; fail=1; }
  # Retired tools should be GONE after migration.
  have ctx-wire  && warn "ctx-wire is still installed — it should have been removed; run: ctx-wire shims uninstall && rm \$(command -v ctx-wire)"
  for t in claude node; do
    have "$t" && ! bash -lc "command -v $t" >/dev/null 2>&1 \
      && warn "$t is not visible from a fresh login shell — check ~/.profile"
  done
  [ "$fail" = 0 ] && bold "All set ✓" || { bold "Finished with warnings — see above"; return 1; }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
bold "serena-forge WSL setup — lean-ctx edition (leanctx-edit=$LEANCTX_EDIT, profile=$LEANCTX_PROFILE)"
grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ] \
  || warn "WSL not detected — continuing anyway (plain Linux is fine)"

setup_env_wiring
load_secrets
ensure_base_deps
ensure_browser_opener
ensure_gh
ensure_node
ensure_uv
ensure_dotnet
ensure_claude
ensure_wsl_interop
migrate_obsolete
ensure_plugins
ensure_skills
ensure_lean_ctx
install_leanctx_kb_sync
ensure_codegraph
ensure_ctx7
ensure_docker
ensure_aoe
ensure_tmux_clipboard
ensure_ast_grep
ensure_semgrep
ensure_dotnet_tools
ensure_aspire
ensure_pup
ensure_acli
ensure_atlassian_mcp
ensure_az_devops
ensure_miro
ensure_second_brain
ensure_claude_settings
index_repos
doctor || true

echo
echo "Next steps:"
echo "  1. Open a NEW shell (or: source ~/.config/claude-tools/env.sh)"
echo "  2. 'claude' -> log in, then /mcp to finish the Miro OAuth"
echo "  3. Restart any running Claude Code session: the atlassian + codegraph MCP servers and the statusline are picked up at startup"
echo "  4. In a C# repo: /serena-forge-setup to onboard Serena"
echo "  5. lean-ctx: 'lean-ctx doctor' to confirm wiring; ctx_* tools appear in-session"
[ -n "$LEANCTX_KB_REPO" ] && echo "  6. Knowledge git-sync: run 'leanctx-kb-sync' to snapshot lean-ctx memory as OKF into $LEANCTX_KB_REPO"
echo "Re-run this script anytime — it updates everything, migrates an old box, and never re-asks stored secrets."
