#!/usr/bin/env bash
# ============================================================================
# serena-forge :: hooks/protect-commands.sh
#
# PreToolUse Bash guard. Reads the tool-call JSON on stdin, extracts
# .tool_input.command, and returns a permission decision using the verified
# PreToolUse stdout contract:
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
#     - dotnet ef database drop                          (drops the EF database)
#     - SQL: DROP {table|database|schema|view|index}     (schema destruction)
#     - SQL: TRUNCATE TABLE                              (empties a table)
#     - SQL: DELETE FROM ... with NO WHERE               (deletes all rows)
#     - SQL: UPDATE <t> SET ... with NO WHERE            (mutates all rows)
#
#   ALLOW (everything else): exit 0 silently — see "ALLOW policy" below.
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
# Only Bash commands are in scope (hooks.json also scopes matcher=Bash).
[[ "$tool_name" == "Bash" ]] || pass

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -n "$cmd" ]] || pass

# Case-insensitive working copy (flags like -Rf, SQL keywords, etc.).
cmd_lc="${cmd,,}"

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
while IFS= read -r seg; do
  # Bulk / recursive file deletion on a path (root/home already denied above).
  # Intentionally NOT allowlisting node_modules/dist/etc: an ASK is a one-click
  # confirm and keeps the guard simple.
  if [[ "$seg" =~ $rm_recursive_re ]]; then
    ask "serena-forge: recursive/bulk file deletion (rm -r/-rf on a path) - confirm the target"
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
done <<< "$segmented"

# ---- ALLOW (default): silent exit 0, defer to normal permission flow --------
pass
