#!/usr/bin/env bash
# ============================================================================
# serena-forge :: hooks/protect-commands.sh
#
# PreToolUse guard for shell commands — the native Bash tool AND lean-ctx's
# MCP shell tools (ctx_shell / shell), which would otherwise run commands
# outside this guard. Reads the tool-call JSON on stdin, extracts the command
# (tool_input.command / cmd / script), and returns a permission decision using
# the verified PreToolUse stdout contract:
#
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny|ask","permissionDecisionReason":"..."}}
#
# DECISION MATRIX
# ---------------------------------------------------------------------------
#   DENY  (permissionDecision "deny" — refuse outright, unrecoverable):
#     - rm -rf /            (recursive+forced delete of filesystem root)
#     - rm -rf ~  / ~/      (recursive+forced delete of the home directory)
#     - rm -rf /*           (recursive+forced delete of root contents)
#     - rm ... --no-preserve-root  (explicit root-wipe intent)
#     - rm -rf $HOME        (home root via env var)
#     - fork bombs          (self-piping backgrounded function, e.g. :(){ :|:& };:)
#
#   ASK   (permissionDecision "ask" — destructive but recoverable; user confirms):
#     - git push --force / --force-with-lease / push -f  (rewrites remote history)
#     - git reset --hard                                 (discards working tree)
#     - git clean -f / -fd / -fdx (any -f)               (deletes untracked files)
#     - bulk file deletion: rm -r / rm -rf on a *path*   (recursive, non-root)
#         EXEMPT (no ASK) when it is a routine in-tree cleanup — see below
#     - dotnet ef database drop                          (drops the EF database)
#     - SQL: DROP {table|database|schema|view|index}     (schema destruction)
#     - SQL: TRUNCATE TABLE                              (empties a table)
#     - SQL: DELETE FROM ... with NO WHERE               (deletes all rows)
#     - SQL: UPDATE <t> SET ... with NO WHERE            (mutates all rows)
#
#   ALLOW (everything else): exit 0 silently — see "ALLOW policy" below.
#
# LOCAL-CLEANUP EXEMPTION  (recursive rm that we do NOT even ASK about)
# ---------------------------------------------------------------------------
#   A recursive rm is a routine developer cleanup — `rm -rf ./build`,
#   `rm -rf node_modules dist`, `rm -rf .cache` — and should not nag with an
#   ASK, but ONLY when we can statically PROVE it is confined and non-sensitive.
#   All of the following must hold (any doubt => keep the ASK):
#     - the shell cwd (from the PreToolUse payload's .cwd) is inside a git
#       WORKTREE (git -C "$cwd" rev-parse --is-inside-work-tree) and is not
#       itself a sensitive directory;
#     - every rm target is a PLAIN, RELATIVE path (no leading / or ~, no `..`,
#       no glob/`$`/quote/space/other shell metachar) that, resolved against
#       cwd, stays AT OR BELOW cwd;
#     - no resolved target is a sensitive system/home directory (Unix system
#       trees, macOS /System//Library/..., Windows C:\Windows/Program Files/...,
#       or the home dir and its credential/tool subdirs ~/bin ~/.ssh ~/.config
#       ...), nor the worktree's own `.git` store;
#     - the command contains no cd/pushd/popd/chroot (which could move the shell
#       out from under us before the rm runs) and no sudo/doas (root delete).
#   If ANY condition is unmet we fall back to the normal ASK. The root/home
#   DENY rules below still run first and are unaffected. This only relaxes the
#   ASK for provably-local cleanup — it never converts a DENY into an allow.
#
# ALLOW policy
# ---------------------------------------------------------------------------
#   For the non-destructive majority we exit 0 with NO JSON. We intentionally
#   do NOT emit permissionDecision "allow": an explicit allow would OVERRIDE
#   the normal permission flow and every other PreToolUse guard that coexists
#   on Bash. serena-forge only ever *raises* the bar (ask/deny) on the matrix
#   above; for all other commands it defers. Per the verified contract, exit 0
#   with no output means "normal permission flow applies" — the correct,
#   non-intrusive behavior.
#
# FAIL-OPEN
# ---------------------------------------------------------------------------
#   This is a safety net, not a chokepoint: any internal error (no jq, bad
#   JSON, empty command, regex fault) must let the command through. Checks run
#   inside `if` conditions (a failing test is consumed by `if`, never aborts),
#   and control always reaches the final `pass` (exit 0). We do NOT use
#   `set -e` (would abort on a benign non-zero) and set no ERR trap (would
#   fire on a false `&&`), both of which would defeat fail-open.
#
# COEXISTENCE / RECONCILIATION  (see serena-forge setup docs)
# ---------------------------------------------------------------------------
#   * dev-team's PreToolUse Bash guard (destructive-guard.sh) fires on the same
#     rm/git/SQL categories. It speaks the LEGACY protocol: by default it prints
#     "CAUTION: ..." and exits 0 (a warning, NOT a block); it only hard-blocks
#     (exit 2) when /careful mode is active. This hook speaks the MODERN protocol
#     (exit 0 + permissionDecision ask/deny). Claude Code takes the strictest
#     verdict (deny > ask > warn/allow), so serena-forge's ask/deny is the
#     EFFECTIVE decision and the dev-team "CAUTION..." line is expected,
#     harmless duplicate noise. We deliberately do NOT unwire destructive-guard
#     .sh: it owns the /careful hard-block we don't replicate, and it lives in
#     the auto-updating plugin cache (unwiring would be reverted on upgrade).
#     No conflict even under /careful: this hook never emits "allow", so
#     dev-team's exit-2 block still dominates when careful mode is on.
#   * block-migrations.sh is an Edit|Write|MultiEdit *file* guard over
#     /Migrations/ and *.Designer.cs. It does NOT guard any Bash command, and
#     this hook is Bash-only, so there is ZERO overlap by construction. We do
#     NOT add any file/path guard over migrations here — that scope belongs to
#     block-migrations.sh. Because no existing hook guards the *Bash* command
#     `dotnet ef database drop`, serena-forge safely owns it as an ASK (no
#     double-fire, nothing to defer to).
#   * pre-tool-guard.sh (secret-path Write/Edit block) is orthogonal — no
#     reconciliation needed.
#
# KNOWN LIMITATION (safe-side, by design)
# ---------------------------------------------------------------------------
#   There is no shell tokenizer here: matching is regex over the (lowercased)
#   command, scoped to the [;&|] segment that triggered a rule. Destructive
#   KEYWORDS that appear inside a quoted string, a commit message, or a comment
#   within a single segment can still raise a benign ASK — e.g.
#   `echo "drop table users"` or `git commit -m "feat: update users set flag"`.
#   This errs on the safe side (ASK is a one-click, recoverable confirm; it is
#   never a false DENY and never suppresses a real ASK), so it is accepted
#   rather than fixed with fragile quote-stripping. The DENY targets (root/home)
#   and the DELETE/UPDATE no-WHERE checks ARE segment-scoped, so a keyword in a
#   different chained command cannot cause a false DENY or hide a real mutation.
# ============================================================================

set -uo pipefail

# ---- decision emitters (fixed reason strings => hand-built JSON is safe) ----
emit() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  exit 0
}
deny() { emit "deny" "$1"; }
ask()  { emit "ask"  "$1"; }
pass() { exit 0; }   # ALLOW == silent exit 0 (defer to normal permission flow)

# ---- read + parse the tool payload (fail-open at every step) ----------------
input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || pass

command -v jq >/dev/null 2>&1 || pass

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
# In scope: the native Bash tool AND lean-ctx's shell tools (ctx_shell / shell),
# which run commands through their own MCP path and would otherwise bypass this
# destructive-command guard entirely. hooks.json scopes the matcher to the same
# set; this re-check keeps the hook correct even if the matcher over-matches.
case "$tool_name" in
  Bash|*ctx_shell|*__shell) : ;;   # native Bash or a lean-ctx shell tool
  *) pass ;;                        # anything else — defer
esac

# The command lives under tool_input.command for Bash; lean-ctx's shell tools
# may instead name it cmd/script. Accept all three.
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // .tool_input.script // empty' 2>/dev/null || true)"
[[ -n "$cmd" ]] || pass

# Case-insensitive working copy (flags like -Rf, SQL keywords, etc.).
cmd_lc="${cmd,,}"

# Shell cwd for this tool call (same source/fallback as the other hooks). Used
# only to relax the recursive-rm ASK for provably-local, in-tree, non-sensitive
# targets. If it is empty/unusable the relaxation simply never applies.
cwd_raw="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd_raw" ]] || cwd_raw="${PWD:-}"

# ---- pattern library --------------------------------------------------------
# rm invoked as a command: start-of-string or a non-identifier boundary before
# `rm` (so /bin/rm and `sudo rm` match, but `confirm`/`term` do not), then a
# recursive/force flag WITHIN the same command segment ([^;&|]* stops at a
# separator, so a `-r` from a *different* chained command is not attributed).
rm_recursive_re='(^|[^[:alnum:]_])rm[[:space:]]([^;&|]*[[:space:]])?(-[a-z]*r[a-z]*|--recursive)([[:space:]]|/|~|$)'

# Catastrophic targets (only consulted alongside a recursive rm):
cat_root='(^|[[:space:]])/([[:space:]]|$)'          #  " / "  filesystem root
cat_rootglob='(^|[[:space:]])/\*'                   #  " /* " root contents
cat_home='(^|[[:space:]])~/?([[:space:]]|$)'        #  " ~ " or " ~/ " home root
cat_homeenv='\$(home|\{home\})([^[:alnum:]_/]|$)'   #  $HOME / ${HOME} (not $HOME/sub)
cat_nopreserve='--no-preserve-root'

# Fork bomb: a function whose body pipes a BARE call to a BARE call and
# backgrounds it, e.g. :(){ :|:& };:  or  bomb(){ bomb|bomb& }. The two
# identifiers around the pipe must be bare (no arguments between the word and
# the `|`/`&`), which is what makes it a self-replicating bomb. This is tighter
# than "any pipe + `&` inside a function body", so a legit helper that merely
# backgrounds a piped pipeline — fetch(){ curl "$1" | jq . & } — is NOT flagged
# (its `curl "$1" |` has an argument between the word and the pipe).
forkbomb_re='\(\)[[:space:]]*\{[^}]*[a-z_:][a-z0-9_:]*[[:space:]]*\|[[:space:]]*[a-z_:][a-z0-9_:]*[[:space:]]*&'

# git categories
gitpush_re='git[[:space:]]+push'
gitpush_force_re='(--force|(^|[[:space:]])-f([[:space:]]|$))'
gitreset_re='git[[:space:]]+reset'
gitclean_re='git[[:space:]]+clean'
gitclean_force_re='(--force|(^|[[:space:]])-[a-z]*f)'

# EF database drop (Bash command; serena-forge owns it — no other hook guards it)
efdrop_re='dotnet[[:space:]]+ef[[:space:]]+database[[:space:]]+drop'

# SQL categories. NOTE: these MUST live in variables — an inline `[[ =~ ... ]]`
# regex containing a `;` is parsed by bash as a command separator (syntax error).
sql_drop_re='(^|[^[:alnum:]_])drop[[:space:]]+(table|database|schema|view|index)([[:space:]]|;|$)'
sql_truncate_re='(^|[^[:alnum:]_])truncate[[:space:]]+table([[:space:]]|;|$)'
sql_delete_re='delete[[:space:]]+from[[:space:]]'
sql_update_re='update[[:space:]]+[^;]*[[:space:]]set[[:space:]]'
# WHERE must be a real SQL token, not the substring inside nowhere/somewhere/
# anywhere/everywhere or a hostname/path. Require a non-identifier boundary on
# both sides. Combined with per-segment scoping below, a `where` in a different
# chained command cannot suppress the ASK on an unqualified DELETE/UPDATE.
sql_where_re='(^|[^[:alnum:]_])where([^[:alnum:]_]|$)'

# ---- Local-cleanup exemption helpers ----------------------------------------
# See the LOCAL-CLEANUP EXEMPTION note in the header. These let a recursive rm
# whose targets are all provably in-tree and non-sensitive skip the ASK. They
# only ever RELAX the ASK; the DENY rules run first and are untouched.

# Pure string path normalization: collapse //, /./ and a trailing / (NO symlink
# or `..` resolution — segments containing `..` are rejected by the caller).
_normalize_path() {
  local p="$1"
  [[ -z "$p" ]] && { printf '/'; return; }
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  while [[ "$p" == *"/./"* ]]; do p="${p//\/.\//\/}"; done
  p="${p%/.}"
  [[ "$p" != "/" ]] && p="${p%/}"
  [[ -z "$p" ]] && p="/"
  printf '%s' "$p"
}

# Is $1 a sensitive directory we must never auto-exempt? Covers the filesystem
# root, Unix system trees, macOS system trees, Windows system trees (native
# c:/, git-bash /c/ and WSL /mnt/c/ forms), and the home dir plus its
# credential/tooling subdirs (~/bin, ~/.ssh, ~/.config, ...). Case-insensitive
# for the OS-path families.
_is_sensitive_dir() {
  local p="${1%/}"
  [[ -z "$p" ]] && return 0                     # root
  local lp="${p,,}"
  local home="${HOME%/}"

  # home directory itself, or a sensitive first-level subdir of it
  if [[ -n "$home" && "$p" == "$home" ]]; then return 0; fi
  if [[ -n "$home" && "$p" == "$home"/* ]]; then
    local rest="${p#"$home"/}" first
    first="${rest%%/*}"
    case "${first,,}" in
      bin|.ssh|.gnupg|.gpg|.config|.local|.aws|.kube|.docker|.azure|.gcloud|.password-store|.mozilla|.thunderbird|library|.git) return 0 ;;
    esac
  fi

  # Unix system directories (exact or ancestor)
  case "$p" in
    /|/bin|/sbin|/lib|/lib32|/lib64|/libx32|/usr|/etc|/var|/opt|/boot|/dev|/proc|/sys|/run|/srv|/root|/home|/mnt|/media|/nix) return 0 ;;
    /bin/*|/sbin/*|/lib/*|/lib32/*|/lib64/*|/libx32/*|/usr/*|/etc/*|/var/*|/boot/*|/dev/*|/proc/*|/sys/*|/run/*|/srv/*|/root/*) return 0 ;;
  esac

  # macOS system directories (case-insensitive)
  case "$lp" in
    /system|/system/*|/library|/library/*|/applications|/applications/*|/users|/private|/private/*|/volumes|/volumes/*|/cores|/network|/network/*) return 0 ;;
  esac

  # Windows system directories: native c:/, git-bash /c/, WSL /mnt/c/ forms
  case "$lp" in
    [a-z]:|[a-z]:/|[a-z]:/windows|[a-z]:/windows/*|[a-z]:/program*files*|[a-z]:/programdata|[a-z]:/programdata/*|[a-z]:/users|[a-z]:/users/*) return 0 ;;
    /[a-z]/windows|/[a-z]/windows/*|/[a-z]/program*files*|/[a-z]/users|/[a-z]/users/*|/mnt/[a-z]/windows|/mnt/[a-z]/windows/*|/mnt/[a-z]/program*files*|/mnt/[a-z]/users|/mnt/[a-z]/users/*) return 0 ;;
  esac

  return 1
}

# Decide whether the recursive rm in RAW segment $1 is a safe local cleanup,
# given shell cwd $2. Return 0 (safe => suppress the ASK) ONLY when every target
# is provably in-tree and non-sensitive; any doubt => return 1 (keep the ASK).
_rm_local_cleanup_safe() {
  local seg="$1" cwd
  [[ -n "$2" ]] || return 1                      # no cwd => can't judge
  cwd="$(_normalize_path "$2")"
  # A cd/pushd/popd/chroot anywhere on the line may move the shell before this
  # rm runs, so the cwd we were handed may not apply — refuse to relax.
  [[ "$cmd_lc" =~ (^|[[:space:]])(cd|pushd|popd|chroot)([[:space:]]|$) ]] && return 1
  # Privilege elevation deletes as root — never relax.
  [[ "$seg" =~ (^|[[:space:]])(sudo|doas)([[:space:]]|$) ]] && return 1
  # cwd must be a real git worktree and itself non-sensitive.
  command -v git >/dev/null 2>&1 || return 1
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  _is_sensitive_dir "$cwd" && return 1

  local -a toks; read -ra toks <<< "$seg"
  local saw_rm=0 saw_path=0 tok resolved
  for tok in "${toks[@]}"; do
    if [[ $saw_rm -eq 0 ]]; then
      [[ "$tok" == "rm" || "$tok" == */rm ]] && saw_rm=1
      continue
    fi
    [[ "$tok" == "--" ]] && continue
    [[ "$tok" == -* ]] && continue               # a flag
    # strip one layer of surrounding quotes
    tok="${tok#\"}"; tok="${tok%\"}"
    tok="${tok#\'}"; tok="${tok%\'}"
    [[ -z "$tok" ]] && continue
    saw_path=1
    case "$tok" in
      /*|\~*) return 1 ;;                         # absolute or home-anchored
      *..*)   return 1 ;;                         # escapes upward
    esac
    # any non-plain path char (glob, $, backtick, space, ...) => can't resolve
    [[ "$tok" == *[^A-Za-z0-9._/@+=%,-]* ]] && return 1
    resolved="$(_normalize_path "$cwd/$tok")"
    case "$resolved" in
      "$cwd"|"$cwd"/*) : ;;                       # at or below cwd
      *) return 1 ;;
    esac
    case "$resolved" in */.git|*/.git/*) return 1 ;; esac  # protect the git store
    _is_sensitive_dir "$resolved" && return 1
  done
  [[ $saw_path -eq 1 ]] || return 1               # no concrete target => keep ASK
  return 0
}

# ---- Per-segment scoping ----------------------------------------------------
# Split the command on the shell separators ; & | into segments and evaluate
# the "flag + context must co-occur" rules WITHIN a single segment. This is the
# fix for two misattribution bugs that a whole-command match caused:
#   (1) a bare `/`, `~`, `/*`, or `$HOME` in a DIFFERENT chained command (or an
#       echo string) escalating a harmless `rm -rf ./build && cd /` to DENY; and
#   (2) a `where` anywhere on the line (nowhere/somewhere, a path, a hostname,
#       another command) suppressing the no-WHERE ASK on a full-table DELETE.
# Now the root/home target must sit in the SAME segment as the recursive rm, and
# the WHERE must sit in the SAME segment as the DELETE/UPDATE. A benign
# `[;&|]`-replace to newline is bash-3.2 safe. Whole-command keyword rules that
# have no cross-segment attribution problem (fork bomb) stay whole-command.
segmented="${cmd_lc//[;&|]/$'\n'}"
# Same split on the ORIGINAL-case command, so the local-cleanup exemption can
# extract and resolve rm target paths without the case-folding that would
# corrupt case-sensitive paths (e.g. macOS ~/Library). Indices align 1:1 with
# $segmented because both split at the same separator positions.
segmented_raw="${cmd//[;&|]/$'\n'}"

# ---- DENY (unrecoverable) ---------------------------------------------------
# Fork bomb: a self-piping backgrounded function. Whole-command is correct here
# (the pattern is self-contained), and DENY must be evaluated before any ASK.
if [[ "$cmd_lc" =~ $forkbomb_re ]]; then
  deny "serena-forge: fork bomb pattern detected - blocked"
fi

# Recursive rm whose OWN segment also names a root/home target => refuse.
while IFS= read -r seg; do
  if [[ "$seg" =~ $rm_recursive_re ]]; then
    if [[ "$seg" =~ $cat_root ]] || [[ "$seg" =~ $cat_rootglob ]] \
       || [[ "$seg" =~ $cat_home ]] || [[ "$seg" =~ $cat_homeenv ]] \
       || [[ "$seg" =~ $cat_nopreserve ]]; then
      deny "serena-forge: refusing recursive delete of a root/home path (rm -rf on / ~ /* or --no-preserve-root)"
    fi
  fi
done <<< "$segmented"

# ---- ASK (destructive but recoverable) -------------------------------------
# Each rule is scoped to a single segment so a destructive keyword or target in
# a different chained command can neither trigger nor suppress it.
mapfile -t _seg_lc  <<< "$segmented"
mapfile -t _seg_raw <<< "$segmented_raw"
for _i in "${!_seg_lc[@]}"; do
  seg="${_seg_lc[$_i]}"
  seg_raw="${_seg_raw[$_i]}"

  # Bulk / recursive file deletion on a path (root/home already denied above).
  # A provably-local, in-tree, non-sensitive cleanup inside a git worktree is
  # exempt (no ASK — defer to normal flow); everything else still confirms.
  if [[ "$seg" =~ $rm_recursive_re ]]; then
    if ! _rm_local_cleanup_safe "$seg_raw" "$cwd_raw"; then
      ask "serena-forge: recursive/bulk file deletion (rm -r/-rf on a path) - confirm the target"
    fi
  fi

  # git push --force / --force-with-lease / push -f
  if [[ "$seg" =~ $gitpush_re ]] && [[ "$seg" =~ $gitpush_force_re ]]; then
    ask "serena-forge: force push rewrites remote history - confirm"
  fi

  # git reset --hard  (scoped so a `--hard` inside an echo string in another
  # segment cannot trigger it)
  if [[ "$seg" =~ $gitreset_re ]] && [[ "$seg" =~ --hard ]]; then
    ask "serena-forge: git reset --hard discards uncommitted changes - confirm"
  fi

  # git clean with a force flag (-f / -fd / -fdx / --force)
  if [[ "$seg" =~ $gitclean_re ]] && [[ "$seg" =~ $gitclean_force_re ]]; then
    ask "serena-forge: git clean -f deletes untracked files - confirm"
  fi

  # dotnet ef database drop  (serena-forge owns this Bash command; no other hook does)
  if [[ "$seg" =~ $efdrop_re ]]; then
    ask "serena-forge: dotnet ef database drop destroys the database - confirm"
  fi

  # SQL: DROP {table|database|schema|view|index}
  if [[ "$seg" =~ $sql_drop_re ]]; then
    ask "serena-forge: SQL DROP is destructive - confirm"
  fi

  # SQL: TRUNCATE TABLE  (require the TABLE keyword so coreutils `truncate -s` is not flagged)
  if [[ "$seg" =~ $sql_truncate_re ]]; then
    ask "serena-forge: SQL TRUNCATE TABLE empties the table - confirm"
  fi

  # SQL: DELETE FROM ... with no WHERE clause in the SAME segment
  if [[ "$seg" =~ $sql_delete_re ]] && [[ ! "$seg" =~ $sql_where_re ]]; then
    ask "serena-forge: DELETE without a WHERE clause affects all rows - confirm"
  fi

  # SQL: UPDATE <table> SET ... with no WHERE clause in the SAME segment
  if [[ "$seg" =~ $sql_update_re ]] && [[ ! "$seg" =~ $sql_where_re ]]; then
    ask "serena-forge: UPDATE without a WHERE clause affects all rows - confirm"
  fi
done

# ---- ALLOW (default): silent exit 0, defer to normal permission flow --------
pass
