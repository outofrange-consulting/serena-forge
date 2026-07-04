#!/usr/bin/env bash
# serena-forge — WSL workstation bootstrap for a clean Claude Code setup.
#
# Installs / updates, idempotently (safe to re-run — everything is refreshed
# to the latest version by default, your config and secrets are preserved):
#
#   Runtimes & deps : apt basics (git, curl, jq, unzip, build tools), Node LTS,
#                     uv/uvx (Serena launcher), .NET 10 SDK (Serena's Roslyn
#                     backend), GitHub CLI (gh — required by dev-team)
#   Claude Code     : native installer, `claude update` on re-run
#   Plugins         : serena-forge (this repo's marketplace, hooks included)
#                     dev-team@bfinster (upstream bdfinst/agentic-dev-team)
#   Skills (~/.claude/skills) : caveman, yagni, atlassian (acli), context7
#                     (from outofrange-consulting/omp-dev-team) + azure-devops
#                     (this repo, drives `az devops`)
#   CLI tools       : ctx-wire (+ shims + git/dotnet filters), acli (Atlassian),
#                     az + azure-devops extension, ctx7 (docs CLI)
#   dev-team tooling: CodeGraph, ast-grep, semgrep, Stryker.NET (global) —
#                     Stryker JS / pitest stay per-project (/init-dev-team)
#   Repo indexing   : asks for a code root, then per repo: codegraph init/sync
#                     (+ per-repo .mcp.json) and `serena project index` on C#
#   MCP             : Miro remote MCP (OAuth via /mcp in-session)
#   Second brain    : clones outofrange-consulting/second-brain, renders
#                     .mcp.json / .claude/settings.json (vault-rag MCP +
#                     auto-commit/auto-push hooks), installs the RAG engine
#
# Secrets: any missing value is prompted as a SECURE string (read -s, never
# echoed) and persisted to ~/.config/claude-tools/secrets.env (chmod 600).
# Already-set environment variables are never re-asked.
#   GOOGLE_GEMINI_API_KEY               second-brain embeddings (goes to <brain>/.env)
#   AZURE_DEVOPS_ORG / _PROJECT / _PAT  az devops defaults + PAT login
#   ACLI_SITE / ACLI_EMAIL / ACLI_TOKEN Atlassian CLI auth
#
# PATH: persisted through ~/.config/claude-tools/env.sh, wired into
# ~/.profile (login shells), the TOP of ~/.bashrc (before the interactive
# guard, so `bash -ic` sees it) and ~/.zshenv (read by ALL zsh shells,
# including non-interactive ones).
#
# Flags:
#   -y, --yes        non-interactive: never prompt (missing secrets are skipped
#                    with a warning, auth steps that need them are deferred)
#   --no-update      keep tools that are already installed (don't refresh)
#   --brain-dir=DIR  where the second brain lives (default: ~/second-brain)
#   --code-root=DIR  root folder of your repos for CodeGraph/Serena indexing
#                    (also via CODE_ROOT env; prompted once and persisted)
#   --skip-brain / --skip-az / --skip-acli / --skip-miro / --skip-dotnet /
#   --skip-index     skip that component entirely
#   -h, --help       this help
set -euo pipefail

YES=0; NO_UPDATE=0; SKIP_BRAIN=0; SKIP_AZ=0; SKIP_ACLI=0; SKIP_MIRO=0; SKIP_DOTNET=0; SKIP_INDEX=0
BRAIN_DIR="${SECOND_BRAIN_DIR:-$HOME/second-brain}"
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --no-update) NO_UPDATE=1 ;;
  --brain-dir=*) BRAIN_DIR="${a#*=}" ;;
  --code-root=*) CODE_ROOT="${a#*=}" ;;
  --skip-brain) SKIP_BRAIN=1 ;; --skip-az) SKIP_AZ=1 ;; --skip-acli) SKIP_ACLI=1 ;;
  --skip-miro) SKIP_MIRO=1 ;; --skip-dotnet) SKIP_DOTNET=1 ;; --skip-index) SKIP_INDEX=1 ;;
  -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

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
# PATH & env persistence — works for login, interactive AND non-interactive
# shells. One managed env.sh, sourced from ~/.profile, the TOP of ~/.bashrc
# (Ubuntu's default .bashrc `return`s early when non-interactive, so appended
# lines never run under `bash -ic` — we insert BEFORE that guard) and
# ~/.zshenv (zsh reads it for every shell type).
# ---------------------------------------------------------------------------
MARK_BEGIN="# >>> claude-tools env (serena-forge setup) >>>"
MARK_END="# <<< claude-tools env (serena-forge setup) <<<"

write_env_file() {
  cat > "$ENV_FILE" <<'EOF'
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# Sourced from ~/.profile, ~/.bashrc (top) and ~/.zshenv so PATH is correct
# even in non-interactive shells (Claude Code's Bash tool, cron, ssh cmd…).
# Written `set -e`-safe: only if-statements, no bare && lists.
for _d in "$HOME/.local/bin" "$HOME/.dotnet" "$HOME/.dotnet/tools"; do
  if [ -d "$_d" ]; then
    case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
  fi
done
unset _d
export PATH
if [ -d "$HOME/.dotnet" ]; then export DOTNET_ROOT="$HOME/.dotnet"; fi
if [ -f "$HOME/.config/claude-tools/secrets.env" ]; then
  . "$HOME/.config/claude-tools/secrets.env"
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
  ok "env.sh wired into ~/.profile, ~/.bashrc (top), ~/.zshenv"
}

# ---------------------------------------------------------------------------
# Secrets — prompt as secure string only when missing, persist chmod 600.
# ---------------------------------------------------------------------------
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

ensure_gh() {  # dev-team (upstream) requires gh; also used to clone private repos
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

# Global npm installs (ctx7, ast-grep, codegraph…) must land on PATH
# (~/.local/bin), not inside the versioned node dir.
ensure_npm_prefix() { have npm && npm config set prefix "$HOME/.local" >/dev/null 2>&1 || true; }

ensure_node() {  # second-brain RAG needs Node >= 20 (better-sqlite3, tsx)
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

ensure_uv() {  # serena-forge launches Serena via uvx
  if have uvx && [ "$NO_UPDATE" = 1 ]; then ok "uvx $(uvx --version 2>/dev/null | head -1)"; return; fi
  say "Installing/updating uv (uvx — Serena launcher)"
  if have uv; then uv self update >/dev/null 2>&1 || true
  else curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null || warn "uv install failed — https://docs.astral.sh/uv/"; fi
  hash -r 2>/dev/null || true
  have uvx && ok "uvx $(uvx --version 2>/dev/null | head -1)" || warn "uvx not on PATH"
}

ensure_dotnet() {  # Serena's C# backend (Roslyn) requires .NET 10+ (NOT 9)
  [ "$SKIP_DOTNET" = 1 ] && return 0
  if dotnet --list-sdks 2>/dev/null | grep -q '^10\.' && [ "$NO_UPDATE" = 1 ]; then
    ok "dotnet SDK 10 present"; return
  fi
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
  export DOTNET_ROOT="$HOME/.dotnet"
}

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
ensure_claude() {
  if have claude; then
    if [ "$NO_UPDATE" = 1 ]; then ok "claude $(claude --version 2>/dev/null | head -1)"
    else say "Updating Claude Code"; claude update >/dev/null 2>&1 || true; ok "claude $(claude --version 2>/dev/null | head -1)"; fi
  else
    say "Installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash || { warn "Claude Code install failed"; return 1; }
    hash -r 2>/dev/null || true
    have claude && ok "claude $(claude --version 2>/dev/null | head -1)" || warn "claude not on PATH yet — open a new shell and re-run"
  fi
}

# ---------------------------------------------------------------------------
# Sibling repos (cached under ~/.claude-setup/src, pulled on every run)
# ---------------------------------------------------------------------------
clone_or_update() {  # clone_or_update <owner/repo> <dest>
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
# Plugins & marketplaces (serena-forge + upstream agentic-dev-team)
# ---------------------------------------------------------------------------
ensure_plugin() {  # ensure_plugin <marketplace-slug-or-repo> <marketplace-name> <plugin>
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
# Skills (~/.claude/skills) — mirrored copies, refreshed on every run
# ---------------------------------------------------------------------------
install_skill() {  # install_skill <src-dir> <name>
  local src="$1" name="$2" dest="$HOME/.claude/skills/$2"
  [ -d "$src" ] || { warn "skill source missing: $src"; return 0; }
  rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
  cp -R "$src" "$dest"
  ok "skill $name -> ~/.claude/skills/$name"
}

ensure_skills() {
  say "Skills"
  local td="$SRC_DIR/omp-dev-team/plugins/token-diet/skills"
  install_skill "$td/caveman"   caveman
  install_skill "$td/yagni"     yagni
  install_skill "$td/atlassian" atlassian
  install_skill "$td/context7"  context7
  install_skill "$ROOT/setup/skills/azure-devops" azure-devops
}

# ---------------------------------------------------------------------------
# ctx-wire (+ shims + filters), ctx7
# ---------------------------------------------------------------------------
ensure_ctx_wire() {
  if have ctx-wire; then
    [ "$NO_UPDATE" = 1 ] || { say "Updating ctx-wire"; ctx-wire update >/dev/null 2>&1 || true; }
  else
    say "Installing ctx-wire"
    curl -fsSL https://ctx-wire.dev/install.sh | sh || { warn "ctx-wire install failed"; return 0; }
    hash -r 2>/dev/null || true
  fi
  have ctx-wire || { warn "ctx-wire not on PATH"; return 0; }
  ctx-wire shims install >/dev/null 2>&1 || warn "ctx-wire shims install failed"
  # Merge the token-diet git/dotnet filters (EN+FR) as a managed block.
  local fdir="$SRC_DIR/omp-dev-team/plugins/token-diet/ctx-wire/filters.d"
  local ftoml="$HOME/.config/ctx-wire/filters.toml" tmp
  if [ -d "$fdir" ]; then
    mkdir -p "$(dirname "$ftoml")"; touch "$ftoml"
    tmp="$(mktemp)"
    sed '/^# >>> serena-forge filters >>>$/,/^# <<< serena-forge filters <<<$/d' "$ftoml" > "$tmp"
    {
      cat "$tmp"
      echo "# >>> serena-forge filters >>>"
      cat "$fdir"/*.toml 2>/dev/null || true
      echo "# <<< serena-forge filters <<<"
    } > "$ftoml"
    rm -f "$tmp"
    ctx-wire verify >/dev/null 2>&1 || warn "ctx-wire verify reported issues — check $ftoml"
  fi
  ok "ctx-wire $(ctx-wire --version 2>/dev/null | head -1)"
}

ensure_ctx7() {  # docs CLI used by the context7 skill
  have npm || { warn "npm missing — skipping ctx7"; return 0; }
  if have ctx7 && [ "$NO_UPDATE" = 1 ]; then ok "ctx7 present"; return; fi
  say "Installing/updating ctx7"
  npm install -g ctx7@latest >/dev/null 2>&1 && ok "ctx7 $(ctx7 --version 2>/dev/null | head -1)" || warn "ctx7 install failed"
}

# ---------------------------------------------------------------------------
# acli (Atlassian CLI) — used by the atlassian skill
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
# Azure DevOps — az CLI + azure-devops extension + PAT login
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
      # AZURE_DEVOPS_EXT_PAT is what az reads non-interactively; keep both names.
      persist_secret AZURE_DEVOPS_EXT_PAT "$AZURE_DEVOPS_PAT"
      export AZURE_DEVOPS_EXT_PAT="$AZURE_DEVOPS_PAT"
      printf '%s' "$AZURE_DEVOPS_PAT" | az devops login --organization "https://dev.azure.com/$AZURE_DEVOPS_ORG" >/dev/null 2>&1 \
        && ok "az devops logged in ($AZURE_DEVOPS_ORG)" \
        || warn "az devops login failed — check the PAT"
    fi
  fi
}

# ---------------------------------------------------------------------------
# dev-team tooling — what upstream /init-dev-team expects on the machine:
# jq + python3 (apt above), CodeGraph, plus ast-grep, semgrep (semgrep-analyze
# skill) and a global Stryker.NET for the C# mutation gate. Stryker (JS) and
# pitest stay PER-PROJECT by upstream design (npm dev-dep / build-file edit) —
# run /init-dev-team inside a repo to wire those.
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

ensure_stryker_dotnet() {  # C# mutation gate — global so it works in any repo
  have dotnet || return 0
  if dotnet tool list --global 2>/dev/null | grep -q dotnet-stryker; then
    [ "$NO_UPDATE" = 1 ] || dotnet tool update --global dotnet-stryker >/dev/null 2>&1 || true
    ok "dotnet-stryker (global)"
  else
    say "Installing Stryker.NET (global dotnet tool)"
    dotnet tool install --global dotnet-stryker >/dev/null 2>&1 \
      && ok "dotnet-stryker installed" || warn "dotnet-stryker install failed"
  fi
}

# ---------------------------------------------------------------------------
# Repo indexing — asks for a code root, then per git repo under it:
#   * CodeGraph: `codegraph init -i` (first time) / `codegraph sync` (re-run),
#     and merges the upstream `codegraph serve --mcp` server into the repo's
#     .mcp.json (same deep-merge as upstream /init-dev-team — commit it with
#     .codegraph/.gitignore so clones auto-bootstrap).
#   * Serena: `serena project index` on repos with a .sln/.csproj (kills the
#     first-find_symbol Roslyn cold start; .NET 10 only — failures are warned,
#     never fatal).
# ---------------------------------------------------------------------------
merge_codegraph_mcp() {  # merge_codegraph_mcp <repo>
  local repo="$1" mcp="$1/.mcp.json" tmp
  have jq || return 0
  local block='{"mcpServers":{"codegraph":{"type":"stdio","command":"codegraph","args":["serve","--mcp"]}}}'
  if [ -f "$mcp" ]; then
    jq -e '.mcpServers.codegraph' "$mcp" >/dev/null 2>&1 && return 0
    if tmp="$(mktemp)" && jq --argjson add "$block" '. * $add' "$mcp" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$mcp"
    else rm -f "${tmp:-}"; warn "  could not merge $mcp — left unchanged"; return 0; fi
  else
    printf '%s\n' "$block" | jq . > "$mcp"
  fi
}

index_repos() {
  [ "$SKIP_INDEX" = 1 ] && return 0
  say "Repo indexing (CodeGraph + Serena)"
  if ! require_var CODE_ROOT "Root folder containing your git repos (e.g. ~/code — Enter to skip indexing)" plain; then
    return 0
  fi
  local root="${CODE_ROOT/#\~/$HOME}"
  [ -d "$root" ] || { warn "CODE_ROOT does not exist: $root — skipping indexing"; return 0; }
  local gitdir repo count=0
  while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"; count=$((count + 1))
    say "Indexing $repo"
    if have codegraph; then
      if [ -d "$repo/.codegraph" ]; then
        (cd "$repo" && codegraph sync >/dev/null 2>&1) && ok "  codegraph sync" || warn "  codegraph sync failed"
      else
        (cd "$repo" && codegraph init -i >/dev/null 2>&1) && { ok "  codegraph init"; merge_codegraph_mcp "$repo"; } \
          || warn "  codegraph init failed"
      fi
    fi
    if have uvx && [ -n "$(find "$repo" -maxdepth 3 \( -name '*.sln' -o -name '*.csproj' \) -not -path '*/bin/*' -not -path '*/obj/*' -print -quit 2>/dev/null)" ]; then
      say "  serena project index (Roslyn — can take a while on first run)"
      uvx -p 3.13 --from git+https://github.com/oraios/serena \
        serena project index "$repo" >/dev/null 2>&1 \
        && ok "  serena index" || warn "  serena index failed (.NET 9 target? LSP cold start?)"
    fi
  done < <(find "$root" -maxdepth 3 -name .git \( -type d -o -type f \) -not -path '*/node_modules/*' 2>/dev/null)
  [ "$count" = 0 ] && warn "no git repos found under $root" || ok "$count repo(s) processed"
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
# Second brain — clone, render configs, install RAG engine, wire the key
# ---------------------------------------------------------------------------
# Mirrors installer.mjs's substitutions for Linux: {{NODE}} becomes
# `/bin/sh \"<brain>/scripts/run-node.sh\"` (quotes JSON-escaped, self-heal
# PATH wrapper) and the vault-rag MCP server launches via rag/launch.sh.
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

ensure_second_brain() {
  [ "$SKIP_BRAIN" = 1 ] && return 0
  say "Second brain ($BRAIN_DIR)"
  clone_or_update "$GH_ORG/second-brain" "$BRAIN_DIR"
  [ -d "$BRAIN_DIR" ] || { warn "second brain not available — skipping"; return 0; }
  render_brain_configs
  [ -f "$BRAIN_DIR/.env" ] || { cp "$BRAIN_DIR/.env.example" "$BRAIN_DIR/.env" 2>/dev/null || true; }
  # Gemini key: only needed for the default Gemini embedder; skip if the .env
  # already carries a key or a non-Gemini EMBEDDING_PROVIDER.
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
    if [ -f "$BRAIN_DIR/scripts/verify-rag.mjs" ]; then
      (cd "$BRAIN_DIR" && node scripts/verify-rag.mjs >/dev/null 2>&1) \
        && ok "RAG smoke test passed" \
        || warn "RAG smoke test failed — check the embedder config in $BRAIN_DIR/.env"
    fi
  else
    warn "npm missing — RAG engine not installed"
  fi
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------
doctor() {
  bold "Doctor"
  local fail=0 t
  check() {  # check <tool> <required|optional> [version-cmd]
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
  check uvx      required "uvx --version"
  check dotnet   optional "dotnet --version"
  check ctx-wire optional "ctx-wire --version"
  check ctx7     optional
  check codegraph optional "codegraph --version"
  check ast-grep optional "ast-grep --version"
  check semgrep  optional "semgrep --version"
  check acli     optional "acli --version"
  check az       optional
  # Fresh-login-shell visibility: catches PATH wiring that only lives in this
  # process. If this fails, the profile wiring above did not take.
  for t in claude node; do
    have "$t" && ! bash -lc "command -v $t" >/dev/null 2>&1 \
      && warn "$t is not visible from a fresh login shell — check ~/.profile"
  done
  [ "$fail" = 0 ] && bold "All set ✓" || { bold "Finished with warnings — see above"; return 1; }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
bold "serena-forge WSL setup — clean Claude Code workstation"
grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ] \
  || warn "WSL not detected — continuing anyway (plain Linux is fine)"

setup_env_wiring
load_secrets
ensure_base_deps
ensure_gh
ensure_node
ensure_uv
ensure_dotnet
ensure_claude
clone_or_update "$GH_ORG/omp-dev-team" "$SRC_DIR/omp-dev-team"
ensure_plugins
ensure_skills
ensure_ctx_wire
ensure_ctx7
ensure_codegraph
ensure_ast_grep
ensure_semgrep
ensure_stryker_dotnet
ensure_acli
ensure_az_devops
ensure_miro
ensure_second_brain
index_repos
doctor || true

echo
echo "Next steps:"
echo "  1. Open a NEW shell (or: source ~/.config/claude-tools/env.sh)"
echo "  2. 'claude' -> log in, then /mcp to finish the Miro OAuth"
echo "  3. In a C# repo: /serena-forge-setup to onboard Serena"
echo "  4. Second brain: cd $BRAIN_DIR && claude"
echo "Re-run this script anytime — it updates everything and never re-asks stored secrets."
