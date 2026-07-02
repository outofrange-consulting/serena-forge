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
# FAIL-OPEN INVARIANT: this hook must never break session startup because of its
# own bug. Any internal error (jq missing, bad stdin, jq -n failure) => emit no
# context and exit 0. Silent exit 0 simply means "no banner this session"; the
# session starts normally.

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
  onboard_line="Current repo: NOT Serena-onboarded (no .serena/ folder). Run the serena-forge-setup skill to onboard it — Serena's read/edit tools will not work in this repo until then."
fi

# --- The injected banner -----------------------------------------------------
# Tight but complete: division of labor (cbm never abandoned), read policy,
# write policy, escape hatch, onboarding status.
context="Serena-first protocol (serena-forge active).

Division of labor — codebase-memory-mcp and Serena COEXIST; NEVER abandon codebase-memory-mcp in favor of Serena:
- codebase-memory-mcp (cbm): the global multi-repo graph — architecture, complexity, cross-service impact, Cypher queries, dead-code. Use it for anything spanning repos or reasoning about structure at scale.
- Serena: reading, editing, and refactoring SYMBOLS of the CURRENT repo. Use it for precise, symbol-level navigation and edits in the repo you are working in.

Read policy: native Read of .cs files is allowed, but PREFER Serena for navigation — get_symbols_overview to survey a file, find_symbol to jump to a target, find_referencing_symbols to find callers — instead of reading whole files.

Write policy: editing .cs via Edit/Write/MultiEdit is BLOCKED globally by serena-forge. Change C# through Serena's symbolic edits: replace_symbol_body, insert_after_symbol, insert_before_symbol.

Escape hatch (anti-deadlock): if Serena's Roslyn LSP is not ready — initialization can take ~30s on large brownfield solutions, and .NET 9 projects hit a Roslyn BuildHost timeout — bypass the .cs write block with SERENA_FORGE_OFF=1 or by creating a .serena-forge-off file in the working directory.

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
