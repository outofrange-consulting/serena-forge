#!/usr/bin/env bash
# serena-forge — WSL-to-WSL migration (old Ubuntu distro -> fresh one).
#
#   OLD machine:  bash migrate-wsl.sh export            -> ~/wsl-migration-<date>.tar.gz
#   NEW machine:  bash migrate-wsl.sh restore <archive> -> auth/memory back, repos re-cloned
#                 then run setup/install-wsl.sh (finds your secrets/auth already in place)
#
# What EXPORT captures:
#   Auth      : ~/.claude/.credentials.json (Claude Code login — NOT ~/.claude.json,
#               which carries stale global mcpServers/plugins; install-wsl.sh
#               rebuilds the MCP set clean), ~/.config/gh (gh),
#               ~/.gitconfig + ~/.git-credentials,
#               ~/.ssh, ~/.azure (az session), acli config, ~/.nuget NuGet.Config,
#               ~/.npmrc, ~/.config/claude-tools/secrets.env (PATs of this setup)
#   MEMORY    : * user memory: ~/.claude/CLAUDE.md + ~/.claude/rules/
#               * AUTO memory: ~/.claude/projects/<project>/memory/ (MEMORY.md
#                 + topic files — Claude's own accumulated learning, machine-
#                 local, NOT in git) + custom autoMemoryDirectory if set
#               * project memory: committed CLAUDE.md/.claude/rules come back
#                 via re-clone; local memory (CLAUDE.local.md,
#                 .claude/settings.local.json, .env, .env.local,
#                 .mcp.local.json, .serena/ minus cache) is saved per repo and
#                 overlaid after clone without overwriting committed files.
#   SESSIONS  : ~/.claude/projects (transcripts — token stats + resume),
#               ~/.claude/sessions, ~/.claude/todos, ~/.claude/history.jsonl.
#   Skills    : ONLY the ones in KEEP_SKILLS (default: NONE — all superseded
#               by install-wsl.sh; --keep-skill=NAME repeatable to opt one in).
#   NOTHING else from ~/.claude migrates — no settings, keybindings,
#   commands/, agents/, hooks, plugins. The whole point: a clean machine
#   where install-wsl.sh rebuilds the harness.
#   Brain     : ~/second-brain — if it has a git remote and is clean+pushed, only
#               .env is exported (re-clone on restore); otherwise the whole
#               folder is archived. Dirty/unpushed state is REPORTED first.
#   Sources   : for every top-level git repo under ~/sources (WORKTREES SKIPPED —
#               .git-file dirs are linked worktrees): origin URL, current branch,
#               HEAD, and the repo's .git/config. Repos are NOT archived —
#               restore re-clones them cleanly and puts the saved config back.
#   Keep-dirs : full copies (default: daft-punk, dom-order-api/docs, teams-graph,
#               litellm-cpa-gateway, memory, ai-journey/{deck,scripts,artifacts}).
#
# What EXPORT verifies (report.txt, also printed):
#   per repo: dirty working tree, unpushed commits, stashes, no remote;
#   brain: same checks; missing usual auth files are listed as absent.
#
# Flags (export):
#   --sources=DIR      default ~/sources
#   --brain=DIR        default ~/second-brain
#   --keep=REL         extra path to copy in full, relative to sources
#                      (repeatable; replaces defaults when given)
#   --out=FILE         archive path (default ~/wsl-migration-<date>.tar.gz)
#   --keep-skill=NAME  personal skill to migrate (repeatable; default: none)
# Flags (restore):
#   --sources=DIR      where to re-clone (default ~/sources)
#   --brain=DIR        default ~/second-brain
set -euo pipefail

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

MODE="${1:-}"; shift || true
SOURCES="$HOME/sources"; BRAIN="$HOME/second-brain"; OUT=""
KEEPS=(); ARCHIVE=""; KEEP_SKILLS_OVERRIDE=()
for a in "$@"; do case "$a" in
  --sources=*) SOURCES="${a#*=}" ;;
  --brain=*)   BRAIN="${a#*=}" ;;
  --keep=*)    KEEPS+=("${a#*=}") ;;
  --keep-skill=*) KEEP_SKILLS_OVERRIDE+=("${a#*=}") ;;
  --out=*)     OUT="${a#*=}" ;;
  -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
  *) [ -z "$ARCHIVE" ] && ARCHIVE="$a" || { echo "unknown arg: $a" >&2; exit 2; } ;;
esac; done
# ai-journey: keep only decks/scripts/artifacts/readme — its raw/ (session copies),
# db/ (rebuildable index) and .venv/ are excluded (sessions already migrate via
# ~/.claude/projects, so re-copying them here would just duplicate ~1 GB).
[ "${#KEEPS[@]}" = 0 ] && KEEPS=("daft-punk" "dom-order-api/docs" "teams-graph" "litellm-cpa-gateway" "memory" \
  "ai-journey/deck" "ai-journey/scripts" "ai-journey/artifacts" "ai-journey/README-BASE.md")

# Home-relative paths worth carrying (auth). Missing ones are skipped.
# NB: ~/.claude.json is deliberately NOT here. It holds the OLD machine's global
# mcpServers / enabledPlugins (e.g. a dev-team cbm server) and per-project trust;
# carrying it pollutes the fresh serena-forge world with stale MCP entries that
# never get pruned. install-wsl.sh is the single source of truth for the MCP set
# (serena plugin + codegraph + miro + azure-devops), so we start clean instead.
AUTH_PATHS=(
  .claude/.credentials.json
  .config/claude-tools/secrets.env
  .config/gh
  .gitconfig .git-credentials
  .ssh
  .azure
  .acli .config/acli
  .nuget/NuGet .npmrc
)

# ~/.claude — STRICT WHITELIST: auth (above) + MEMORY + SESSIONS + kept
# skills. Nothing else migrates (no settings, commands/, agents/, hooks,
# keybindings, plugins…) — the whole point of the migration is a clean
# machine where install-wsl.sh rebuilds the harness from scratch.
#   user memory   : ~/.claude/CLAUDE.md + ~/.claude/rules/
#   AUTO memory   : ~/.claude/projects/<project>/memory/ — carried by taking
#                   projects/ whole (below) + settings.json
#                   autoMemoryDirectory if set
#   sessions      : ~/.claude/projects (transcripts — stats + resume),
#                   ~/.claude/sessions, ~/.claude/todos, ~/.claude/history.jsonl
#   project memory: committed CLAUDE.md/.claude/rules come back via re-clone;
#                   local files via REPO_LOCAL_PATHS below
CLAUDE_MEMORY_PATHS=(
  .claude/CLAUDE.md .claude/rules
  .claude/projects .claude/sessions .claude/todos .claude/history.jsonl
)

# Personal skills to migrate. Default: NONE — every ~/.claude/skills entry is
# superseded by what install-wsl.sh reinstalls (azdo-pr's logic now lives in the
# azure-devops skill it installs). Opt in with repeated --keep-skill=NAME.
KEEP_SKILLS=()
[ "${#KEEP_SKILLS_OVERRIDE[@]}" = 0 ] || KEEP_SKILLS=("${KEEP_SKILLS_OVERRIDE[@]}")

# Per-repo LOCAL memory that a clean re-clone loses (untracked/ignored files).
# Saved per repo on export, overlaid after clone on restore WITHOUT overwriting
# anything the clone brought back. `memory` is the dev-team orchestrator's
# per-repo dir (decisions.md, recon-*, plan-*, rca-*) written when Claude is
# launched from inside a repo — it is untracked, so without this it is lost.
REPO_LOCAL_PATHS=(CLAUDE.local.md .claude/settings.local.json .claude/CLAUDE.local.md .env .env.local .mcp.local.json memory)

is_worktree() { [ -f "$1/.git" ]; }   # linked worktree/submodule: .git is a FILE

# --------------------------------- export ----------------------------------
do_export() {
  local stamp stage rel p repo gitdir origin branch head n=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  OUT="${OUT:-$HOME/wsl-migration-$stamp.tar.gz}"
  stage="$(mktemp -d)/wsl-migration"
  mkdir -p "$stage/home" "$stage/repo-configs" "$stage/keep"
  : > "$stage/report.txt"
  report() { printf '%s\n' "$*" >> "$stage/report.txt"; warn "$*"; }

  say "Auth"
  for rel in "${AUTH_PATHS[@]}"; do
    p="$HOME/$rel"
    if [ -e "$p" ]; then
      mkdir -p "$stage/home/$(dirname "$rel")"
      cp -a "$p" "$stage/home/$(dirname "$rel")/" && ok "$rel"
    else
      printf 'absent: %s\n' "$rel" >> "$stage/report.txt"
    fi
  done
  have gh && ! gh auth status >/dev/null 2>&1 && report "gh not authenticated on this machine"

  say "Claude memory + sessions + kept skills (STRICT whitelist — no settings/commands/agents)"
  if [ -d "$HOME/.claude" ]; then
    # User memory (CLAUDE.md, rules/) + sessions (projects/ — which carries
    # the per-project auto memory dirs — sessions/, todos/, history).
    for rel in "${CLAUDE_MEMORY_PATHS[@]}"; do
      if [ -e "$HOME/$rel" ]; then
        mkdir -p "$stage/home/$(dirname "$rel")"
        cp -a "$HOME/$rel" "$stage/home/$(dirname "$rel")/" && ok "$rel"
      fi
    done
    # Custom autoMemoryDirectory (settings.json) — carried when it lives under ~.
    local amd
    amd="$(jq -r '.autoMemoryDirectory // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)"
    if [ -n "$amd" ]; then
      amd="${amd/#\~/$HOME}"
      case "$amd" in
        "$HOME"/*) [ -d "$amd" ] && { mkdir -p "$stage/home/$(dirname "${amd#"$HOME"/}")"; cp -a "$amd" "$stage/home/$(dirname "${amd#"$HOME"/}")/"; ok "custom autoMemoryDirectory: ${amd#"$HOME"/}"; } ;;
        *) report "autoMemoryDirectory outside \$HOME ($amd) — carry it yourself" ;;
      esac
    fi

    # Personal skills: only KEEP_SKILLS migrate (the rest is superseded by
    # install-wsl.sh); dropped ones are listed in the report.
    local s
    if [ "${#KEEP_SKILLS[@]}" -gt 0 ]; then
      for s in "${KEEP_SKILLS[@]}"; do
        if [ -d "$HOME/.claude/skills/$s" ]; then
          mkdir -p "$stage/home/.claude/skills"
          cp -a "$HOME/.claude/skills/$s" "$stage/home/.claude/skills/" && ok "skill kept: $s"
        else
          report "skill to keep not found: $s"
        fi
      done
    fi
    if [ -d "$HOME/.claude/skills" ]; then
      for s in "$HOME/.claude/skills"/*/; do
        [ -d "$s" ] || continue
        s="$(basename "$s")"
        case " ${KEEP_SKILLS[*]:-} " in *" $s "*) ;; *) printf 'skill dropped (superseded by setup): %s\n' "$s" >> "$stage/report.txt" ;; esac
      done
    fi
  else
    report "absent: .claude"
  fi

  say "Second brain ($BRAIN)"
  if [ -d "$BRAIN/.git" ]; then
    origin="$(git -C "$BRAIN" remote get-url origin 2>/dev/null || true)"
    [ -n "$(git -C "$BRAIN" status --porcelain 2>/dev/null)" ] && report "brain: DIRTY working tree — commit before migrating"
    [ -n "$(git -C "$BRAIN" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && report "brain: UNPUSHED commits — push before migrating"
    if [ -n "$origin" ]; then
      printf '%s\n' "$origin" > "$stage/brain-remote"
      [ -f "$BRAIN/.env" ] && { mkdir -p "$stage/brain"; cp -a "$BRAIN/.env" "$stage/brain/.env"; ok "brain .env (repo re-cloned on restore from $origin)"; }
    else
      report "brain: no git remote — archiving the whole folder"
      tar -C "$(dirname "$BRAIN")" -czf "$stage/brain-full.tar.gz" "$(basename "$BRAIN")"
      ok "brain archived in full"
    fi
  else
    report "brain: $BRAIN is not a git repo (skipped)"
  fi

  say "Sources manifest ($SOURCES — worktrees excluded, repos re-cloned on restore)"
  printf '[\n' > "$stage/manifest.json"
  local first=1
  while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"
    is_worktree "$repo" && continue
    rel="${repo#"$SOURCES"/}"
    origin="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true)"
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    [ -z "$origin" ] && report "$rel: no origin remote — will NOT be re-cloned (archive it yourself if needed)"
    [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && report "$rel: DIRTY working tree"
    [ -n "$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && report "$rel: UNPUSHED commits"
    [ -n "$(git -C "$repo" stash list 2>/dev/null)" ] && report "$rel: has STASHES (not migrated)"
    mkdir -p "$stage/repo-configs/$rel"
    cp "$repo/.git/config" "$stage/repo-configs/$rel/config" 2>/dev/null || true
    # Local memory a clean clone loses: CLAUDE.local.md, local settings, .env…
    # plus .serena (project config + memories) minus its machine-local cache.
    local lp
    for lp in "${REPO_LOCAL_PATHS[@]}"; do
      if [ -e "$repo/$lp" ]; then
        mkdir -p "$stage/repo-local/$rel/$(dirname "$lp")"
        cp -a "$repo/$lp" "$stage/repo-local/$rel/$(dirname "$lp")/"
      fi
    done
    if [ -d "$repo/.serena" ]; then
      mkdir -p "$stage/repo-local/$rel"
      (cd "$repo" && tar -cf - --exclude='./.serena/cache' ./.serena) | tar -xf - -C "$stage/repo-local/$rel"
    fi
    [ "$first" = 1 ] || printf ',\n' >> "$stage/manifest.json"; first=0
    jq -n --arg rel "$rel" --arg origin "$origin" --arg branch "$branch" --arg head "$head" \
      '{rel:$rel,origin:$origin,branch:$branch,head:$head}' >> "$stage/manifest.json"
    n=$((n + 1)); ok "$rel (${branch:-detached})"
  done < <(find "$SOURCES" -maxdepth 3 -name .git -type d -not -path '*/node_modules/*' 2>/dev/null | sort)
  printf '\n]\n' >> "$stage/manifest.json"
  ok "$n repo(s) in manifest"

  say "Keep-dirs (full copies)"
  for rel in "${KEEPS[@]}"; do
    if [ -e "$SOURCES/$rel" ]; then
      mkdir -p "$stage/keep/$(dirname "$rel")"
      cp -a "$SOURCES/$rel" "$stage/keep/$(dirname "$rel")/" && ok "$rel"
    else
      report "keep: $SOURCES/$rel not found"
    fi
  done

  tar -C "$(dirname "$stage")" -czf "$OUT" "$(basename "$stage")"
  chmod 600 "$OUT"
  rm -rf "$(dirname "$stage")"
  echo
  ok "archive: $OUT ($(du -h "$OUT" | cut -f1)) — chmod 600, contains credentials: move it PRIVATELY"
  echo "Report:"
  tar -xzOf "$OUT" wsl-migration/report.txt | sed 's/^/  /' || true
  echo "Fix DIRTY/UNPUSHED items above and re-run export, or accept the loss knowingly."
}

# --------------------------------- restore ---------------------------------
do_restore() {
  [ -f "${ARCHIVE:-}" ] || { echo "usage: migrate-wsl.sh restore <archive.tar.gz>" >&2; exit 2; }
  local stage rel origin branch repo n=0
  stage="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$stage"
  stage="$stage/wsl-migration"

  say "Auth + memory -> \$HOME"
  if [ -d "$stage/home" ]; then
    cp -a "$stage/home/." "$HOME/"
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
    chmod 600 "$HOME/.git-credentials" "$HOME/.claude/.credentials.json" \
              "$HOME/.config/claude-tools/secrets.env" 2>/dev/null || true
    ok "restored (ssh/credentials re-chmodded)"
  fi

  # Re-clones must authenticate WITHOUT the old machine's (often stale) gh token:
  # GitHub over SSH (registered key, restored above), Azure DevOps with the PAT
  # from the just-restored secrets.env. Done before any clone below.
  say "Git auth for re-clones (GitHub -> SSH, Azure DevOps -> PAT)"
  git config --global url."git@github.com:".insteadOf "https://github.com/" || true
  [ -f "$HOME/.config/claude-tools/secrets.env" ] && . "$HOME/.config/claude-tools/secrets.env" 2>/dev/null || true
  ADO_PAT="${AZURE_DEVOPS_EXT_PAT:-${AZURE_DEVOPS_PAT:-}}"
  if [ -n "$ADO_PAT" ]; then
    export AZURE_DEVOPS_EXT_PAT="$ADO_PAT"
    # Credential helper reads the PAT at runtime — never baked into ~/.gitconfig;
    # env.sh keeps AZURE_DEVOPS_EXT_PAT exported for every future shell too.
    git config --global credential."https://dev.azure.com".username pat
    git config --global credential."https://dev.azure.com".helper \
      '!f() { test "$1" = get && printf "password=%s\n" "$AZURE_DEVOPS_EXT_PAT"; }; f'
    ok "GitHub -> SSH, Azure DevOps -> PAT (from secrets.env)"
  else
    warn "no Azure DevOps PAT in secrets.env — ADO repos will fail to clone"
  fi

  say "Second brain -> $BRAIN"
  if [ -e "$BRAIN" ]; then
    warn "$BRAIN already exists — left untouched"
  elif [ -f "$stage/brain-full.tar.gz" ]; then
    tar -xzf "$stage/brain-full.tar.gz" -C "$(dirname "$BRAIN")"
    ok "brain restored from full archive"
  elif [ -f "$stage/brain-remote" ]; then
    git clone --quiet "$(cat "$stage/brain-remote")" "$BRAIN" \
      && ok "brain cloned from $(cat "$stage/brain-remote")" \
      || warn "brain clone failed — clone it manually, then copy .env"
    [ -f "$stage/brain/.env" ] && [ -d "$BRAIN" ] && { cp "$stage/brain/.env" "$BRAIN/.env"; chmod 600 "$BRAIN/.env"; ok "brain .env restored"; }
  fi

  say "Re-cloning sources -> $SOURCES"
  mkdir -p "$SOURCES"
  while IFS=$'\t' read -r rel origin branch; do
    repo="$SOURCES/$rel"
    [ -z "$origin" ] && { warn "$rel: no origin recorded — skipped"; continue; }
    if [ -d "$repo/.git" ]; then ok "$rel already present"; else
      mkdir -p "$(dirname "$repo")"
      if git clone --quiet ${branch:+--branch "$branch"} "$origin" "$repo" 2>/dev/null; then
        n=$((n + 1)); ok "$rel"
      else
        warn "$rel: clone failed ($origin) — auth? run 'gh auth status'"; continue
      fi
    fi
    [ -f "$stage/repo-configs/$rel/config" ] && cp "$stage/repo-configs/$rel/config" "$repo/.git/config"
    # Overlay saved local memory WITHOUT overwriting what the clone brought
    # back (committed .serena/memories etc. win; only missing files land).
    [ -d "$stage/repo-local/$rel" ] && cp -rn "$stage/repo-local/$rel/." "$repo/" 2>/dev/null || true
  done < <(jq -r '.[] | [.rel, .origin, .branch] | @tsv' "$stage/manifest.json")
  ok "$n repo(s) cloned (saved .git/config restored on all present repos)"

  say "Keep-dirs -> $SOURCES"
  [ -d "$stage/keep" ] && cp -a "$stage/keep/." "$SOURCES/" && ok "keep-dirs restored"

  rm -rf "$(dirname "$stage")"
  echo
  ok "restore done. Next: bash setup/install-wsl.sh (it will find your auth/secrets in place)"
}

case "$MODE" in
  export)  have jq || { echo "jq required (sudo apt-get install -y jq)" >&2; exit 1; }; do_export ;;
  restore) have jq || { echo "jq required (sudo apt-get install -y jq)" >&2; exit 1; }; do_restore ;;
  *) sed -n '2,52p' "$0"; exit 2 ;;
esac
