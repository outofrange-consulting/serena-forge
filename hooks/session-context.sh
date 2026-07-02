#!/usr/bin/env bash
# serena-forge :: session-context.sh
#
# SessionStart hook (wired in hooks/hooks.json with no matcher => fires on every
# SessionStart event: startup, resume, clear, compact). It injects a short
# "Serena-first" protocol banner into the session via additionalContext.
#
# Verified SessionStart output contract: print JSON on stdout with
#   { "hookSpecificOutput": { "hookEventName": "SessionStart",
#                             "additionalContext": "<text>" } }
# and exit 0. The additionalContext string is added to the model's context for
# the session. This text is loaded EVERY session, so keep it tight.
#
# FAIL-OPEN ON OWN MALFUNCTION: this hook must never break session startup
# because of its OWN bug. Any internal error (jq missing, bad stdin, jq -n
# failure) => emit no context and exit 0. Silent exit 0 simply means "no banner
# this session"; the session starts normally.

set -uo pipefail  # -e intentionally omitted: every error path must still exit 0

# Drain the SessionStart payload up front (non-fatal on failure). It carries the
# session cwd, which we use to check onboarding status.
input="$(cat 2>/dev/null || true)"

# Resolve the working directory: prefer the cwd reported on stdin, fall back to
# the hook process's own PWD. Either is acceptable; the .serena/ check below is
# advisory only.
cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
if [[ -z "$cwd" ]]; then
  cwd="${PWD:-.}"
fi

# --- Onboarding status (advisory) -------------------------------------------
# A Serena-onboarded repo has a .serena/ folder in its root (project.yml,
# memories, caches). Choose one of two fully-static sentences — no path is
# interpolated into the message, so there is no JSON-injection surface even in
# the no-jq fallback.
if [[ -d "$cwd/.serena" ]]; then
  onboard_line="Current repo: Serena-onboarded (.serena/ present) — Serena tools are ready to use here."
else
  onboard_line="Current repo: NOT Serena-onboarded (no .serena/ folder). Serena's symbolic read/edit tools will not work here, and .cs writes are blocked, until this repo is onboarded. As soon as C# work is requested here, PROPOSE onboarding to the user (offer to run the serena-forge-setup skill) and run it only once they agree — do not silently skip it and do not try to edit .cs around the block."
fi

# --- The injected banner -----------------------------------------------------
# Tight: read policy, write policy, onboarding status. No bypass instructions.
context="Serena-first protocol (serena-forge active).

Serena provides symbol-level read and edit tools for the CURRENT repository, backed by the Roslyn language server.

Read policy: native Read of .cs files is allowed, but PREFER Serena for navigation. Mandatory workflow for reading C#: (1) get_symbols_overview to map a file, (2) find_symbol on the target, (3) include_body: true ONLY on the specific symbol you need. Use find_referencing_symbols (real call sites via the LSP) instead of grep for any change-impact analysis. Do not reflexively Read whole .cs files — a whole-file Read over ~100 lines will prompt for confirmation.

Write policy: editing .cs via Edit/Write/MultiEdit is BLOCKED globally by serena-forge. Change C# through Serena's symbolic edits: replace_symbol_body, insert_after_symbol, insert_before_symbol (and rename_symbol / safe_delete_symbol for structural changes). If Serena cannot make an edit, stop and ask the user to fix Serena or disable the hook — do not work around the block.

Build safety net: after your C# edits, serena-forge compiles the touched project(s) with dotnet build at end of turn. If it fails, you will be handed the compiler errors and asked to fix them before finishing — treat a red build as unfinished work.

${onboard_line}"

# --- Emit the context (fail-open) -------------------------------------------
# jq encodes the (multi-line) string safely. If jq is unavailable or jq -n
# fails, emit nothing and exit 0 — the session still starts, just without the
# banner.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' \
    2>/dev/null || true
fi

exit 0
