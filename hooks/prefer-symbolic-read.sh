#!/usr/bin/env bash
# ============================================================================
# serena-forge :: hooks/prefer-symbolic-read.sh
#
# PreToolUse hook (matcher = Read, wired in hooks/hooks.json). Nudges the agent
# off whole-file reads of large C# files and onto Serena's symbolic reads
# (get_symbols_overview -> find_symbol -> include_body only on the needed symbol).
#
# DESIGN: this is an ASK, never a DENY. serena-forge deliberately does NOT hard-
# block reads (that would only teach the agent to route around the guard — see
# the write-only-enforcement design note in the README). ASK is a one-click,
# recoverable confirm: the user can wave through a legitimate full read, while
# the reflex "dump the whole file" gets a friction point that points at the
# cheaper symbolic path. Only .cs files OVER the line threshold are touched;
# small files and every non-.cs read pass through untouched.
#
# Threshold: SERENA_FORGE_READ_MAXLINES (default 100). Set to 0 to disable this
# guard entirely (every Read passes through).
#
# FAIL-OPEN ON OWN MALFUNCTION: any internal error (no jq, bad stdin, unreadable
# file) => allow (silent exit 0). The only path that ever ASKs is a well-formed,
# confirmed large .cs read.

set -uo pipefail

max="${SERENA_FORGE_READ_MAXLINES:-100}"
# Disabled explicitly.
[[ "$max" == "0" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[[ -n "$file_path" ]] || exit 0

# Only .cs is in scope (case-insensitive suffix; excludes .csproj/.cshtml/.csx).
[[ "$file_path" == *.[cC][sS] ]] || exit 0

# Serena's symbolic reads only EXIST once the repo is onboarded (.serena/ folder
# — same gate the write hook uses). With no .serena/, the nudge points at tools
# that can't act here, so it's pure friction: e.g. dev-team recon subagents
# (Read/Grep/Glob/Bash, no Serena MCP) whole-file reading a non-onboarded repo
# would prompt on every large .cs. Pass through untouched.
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${PWD:-.}"
[[ -d "$cwd/.serena" ]] || exit 0

# If the Read is already a bounded slice (offset/limit set), it's not a whole-file
# dump — let it through. The concern is the reflexive full-file read.
limit="$(printf '%s' "$input" | jq -r '.tool_input.limit // empty' 2>/dev/null || true)"
[[ -n "$limit" ]] && exit 0

# Count lines; if we can't stat/read the file, fail-open.
[[ -f "$file_path" ]] || exit 0
lines="$(wc -l < "$file_path" 2>/dev/null || echo 0)"
# Trim whitespace wc may pad with.
lines="${lines//[[:space:]]/}"
[[ "$lines" =~ ^[0-9]+$ ]] || exit 0

# Under threshold => pass through silently.
[[ "$lines" -gt "$max" ]] || exit 0

reason="This is a whole-file Read of a ${lines}-line C# file (serena-forge prefers symbolic reads over ~${max} lines). Prefer Serena: get_symbols_overview on this file to map its symbols, then find_symbol (include_body: true) on just the target symbol, and find_referencing_symbols instead of grep for impact. Only read the whole file if you genuinely need it — confirm to proceed."

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}'

exit 0
