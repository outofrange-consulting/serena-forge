#!/usr/bin/env bash
# serena-forge :: enforce-serena-write.sh
#
# PreToolUse hook (fires on Edit|Write|MultiEdit — wired in hooks/hooks.json).
# Purpose: redirect all C# (.cs) file writes to Serena's symbolic-editing tools
# so edits happen by symbol, not by raw text patch.
#
# Scope is GLOBAL by design: .cs writes are DENIED in every repo once the plugin
# is active. There is intentionally NO built-in bypass (no marker file, no env
# toggle). If Serena genuinely cannot make an edit, the agent is told to stop and
# ask the user to fix Serena or disable this hook — it must not route around it.
#
# Contract (verified): a PreToolUse hook affects the decision only by printing
# JSON with hookSpecificOutput.permissionDecision and exiting 0. A silent exit 0
# is NOT an approval — it just defers to the normal permission flow, which is
# exactly the "pass through untouched" behaviour we want for everything but .cs.
#
# FAIL-OPEN ON OWN MALFUNCTION: this hook must never block the user because of
# its OWN bug (jq missing, malformed stdin, parse error) => allow (exit 0). This
# is internal robustness, not a user-facing bypass: it is never advertised to the
# agent as a way around the block. The only path that ever blocks is the
# explicit, well-formed .cs deny below.

set -uo pipefail  # -e intentionally omitted: every error path must reach exit 0

# Drain stdin (the tool-call JSON) up front so we never leave a broken pipe and
# always have the payload available for parsing. Failure here is non-fatal.
input="$(cat 2>/dev/null || true)"

# --- FAIL-OPEN: jq is required to parse the payload -------------------------
# If jq isn't on PATH we cannot reliably inspect the tool input, so allow.
if ! command -v jq >/dev/null 2>&1; then
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

# --- Onboarding-aware guidance ----------------------------------------------
# Resolve the session cwd (repo root) from the payload; on any jq error fall back
# to PWD. Used only to tailor the deny message — never to change the decision.
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${PWD:-.}"

# --- DENY the .cs write and steer the agent to Serena's symbolic tools -------
# Build the JSON with jq (jq is confirmed present here) so any quotes/backslashes
# in file_path are escaped safely — no hand-rolled JSON injection risk. If jq -n
# somehow failed, no decision is emitted and we still exit 0 => fail-open.
#
# The message deliberately does NOT tell the agent how to disable the guard. When
# Serena can't make the edit, the agent must escalate to the user, not bypass.
if [[ -d "$cwd/.serena" ]]; then
  reason="Editing .cs via Edit/Write/MultiEdit is blocked by serena-forge (target: ${file_path}). To CREATE a new C# file, use Serena's create_text_file tool. To EDIT an existing one, use Serena's symbolic tools instead: inspect it with get_symbols_overview, or locate the exact target with find_symbol, then change it with replace_symbol_body, insert_after_symbol, or insert_before_symbol. If you cannot make this change through Serena — the language server is unavailable or the edit cannot be expressed symbolically — STOP and ask the user to either fix Serena or disable this hook. Do not attempt to work around this block."
else
  # No .serena/ => this repo was never onboarded, so Serena's symbolic tools
  # cannot act on it yet. Steer the agent to PROPOSE onboarding to the user
  # rather than fall back to a native .cs write.
  reason="Editing .cs via Edit/Write/MultiEdit is blocked by serena-forge (target: ${file_path}). This repo is NOT Serena-onboarded yet (no .serena/ folder), so Serena's symbolic edit tools cannot act on it. PROPOSE to the user that you onboard this repo now with the serena-forge-setup skill (it activates the project and indexes it), and run it once they agree — then make the change through Serena's symbolic tools (replace_symbol_body / insert_after_symbol / rename_symbol). Do NOT work around this block with a native .cs write."
fi

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'

# Decision emitted on stdout; exit 0 per the PreToolUse JSON contract.
exit 0
