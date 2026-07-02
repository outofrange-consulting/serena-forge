#!/usr/bin/env bash
# serena-forge :: enforce-serena-write.sh
#
# PreToolUse hook (fires on Edit|Write|MultiEdit — wired in hooks/hooks.json).
# Purpose: redirect all C# (.cs) file writes to Serena's symbolic-editing tools
# so edits happen by symbol, not by raw text patch.
#
# Scope is GLOBAL by design: we DENY .cs writes in every repo once the plugin is
# active. We deliberately do NOT gate on the presence of a .serena/ folder — the
# escape hatch below is the anti-deadlock valve, not per-repo opt-in.
#
# Contract (verified): a PreToolUse hook affects the decision only by printing
# JSON with hookSpecificOutput.permissionDecision and exiting 0. A silent exit 0
# is NOT an approval — it just defers to the normal permission flow, which is
# exactly the "pass through untouched" behaviour we want for everything but .cs.
#
# FAIL-OPEN INVARIANT: this hook must never block the user because of its own
# bug. jq missing, malformed stdin, or any parse error => allow (exit 0). The
# only path that ever blocks is the explicit, well-formed .cs deny below.

set -uo pipefail  # -e intentionally omitted: every error path must reach exit 0

# Drain stdin (the tool-call JSON) up front so we never leave a broken pipe and
# always have the payload available for parsing. Failure here is non-fatal.
input="$(cat 2>/dev/null || true)"

# --- ESCAPE HATCH part 1: env var (cwd-independent) -------------------------
# If Serena's LSP isn't ready (init can take ~30s on large brownfield solutions)
# or the user needs to hand-edit .cs for any reason, they can bypass this hook:
#   * export SERENA_FORGE_OFF=1  (session-wide, checked here — no parsing needed), OR
#   * drop a marker file named ".serena-forge-off" (checked below, once we can
#     resolve the project cwd from the payload).
# Either one => get out of the way (defer to normal flow, no block).
if [[ "${SERENA_FORGE_OFF:-}" == "1" ]]; then
  exit 0
fi

# --- FAIL-OPEN: jq is required to parse the payload -------------------------
# If jq isn't on PATH we cannot reliably inspect the tool input, so allow.
# (This is above the marker check because we use jq to read the payload cwd.)
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# --- ESCAPE HATCH part 2: marker file, resolved against the payload cwd ------
# Resolve the ".serena-forge-off" marker against the project root reported on
# stdin (.cwd), so the hatch works even when the hook process runs from a
# different directory (e.g. under a subagent). Also honor a marker relative to
# the hook's own cwd as a fallback. Either present => defer (no block).
payload_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
if { [[ -n "$payload_cwd" ]] && [[ -e "$payload_cwd/.serena-forge-off" ]]; } \
   || [[ -e ".serena-forge-off" ]]; then
  exit 0
fi

# --- Parse the target file path ---------------------------------------------
# Edit / Write / MultiEdit all carry the target under tool_input.file_path.
# On any jq error, fail open (allow).
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
if [[ $? -ne 0 ]]; then
  exit 0
fi

# --- Only .cs is affected ----------------------------------------------------
# Case-insensitive ".cs" suffix match so Foo.CS / Bar.Cs are caught too. We use
# a bracket glob (*.[cC][sS]) rather than bash-4's `${var,,}` lowercasing: `,,`
# is a "bad substitution" on bash < 4.0 (e.g. macOS's default /bin/bash 3.2.57),
# which — since this hook is GLOBAL by design and distributed cross-platform —
# would abort the script BEFORE the deny and silently fail OPEN on every write.
# The bracket glob works on bash 3.1+ and keeps the precise "ends in .cs"
# semantics: it still excludes .csproj, .cshtml, .csx (none END in ".cs").
# Anything that isn't a .cs write passes through untouched (silent exit 0 =>
# normal permission flow decides).
if [[ "$file_path" != *.[cC][sS] ]]; then
  exit 0
fi

# --- DENY the .cs write and steer the agent to Serena's symbolic tools -------
# Build the JSON with jq (jq is confirmed present here) so any quotes/backslashes
# in file_path are escaped safely — no hand-rolled JSON injection risk. If jq -n
# somehow failed, no decision is emitted and we still exit 0 => fail-open.
reason="Editing .cs via Edit/Write/MultiEdit is blocked by serena-forge (target: ${file_path}). Edit this C# file through Serena's symbolic tools instead: first inspect the file with get_symbols_overview, or locate the exact target with find_symbol; then change it with replace_symbol_body, insert_after_symbol, or insert_before_symbol. Keep using codebase-memory-mcp for cross-repo architecture, complexity, and impact queries — Serena is for reading and editing symbols in the CURRENT repo, and does not replace it. Anti-deadlock: if Serena's LSP is unavailable, set SERENA_FORGE_OFF=1 or create a .serena-forge-off file in the working directory to bypass this hook."

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'

# Decision emitted on stdout; exit 0 per the PreToolUse JSON contract.
exit 0
