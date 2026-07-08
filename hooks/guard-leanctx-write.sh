#!/usr/bin/env bash
# ============================================================================
# serena-forge :: hooks/guard-leanctx-write.sh
#
# PreToolUse hook (matcher = lean-ctx's MCP WRITE tools, wired in hooks.json:
#   mcp__lean-ctx__ctx_patch | mcp__lean-ctx__ctx_edit | mcp__lean-ctx__ctx_fill
# and prefix-tolerant variants). Purpose: close the hole that lean-ctx opens.
#
# WHY THIS EXISTS
#   serena-forge's enforce-serena-write.sh denies native Edit|Write|MultiEdit on
#   .cs files so all C# editing goes through Serena's Roslyn-backed symbolic
#   tools. But lean-ctx ships its OWN write tools (ctx_patch/ctx_edit/ctx_fill)
#   as MCP tools — they do NOT go through Claude Code's native Edit/Write, so the
#   native write block never fires on them. Left unguarded, the agent could edit
#   a .cs file through ctx_patch and bypass Serena, the build safety net, and
#   Roslyn entirely (lean-ctx's CLAUDE.md even nudges "prefer ctx_patch"). This
#   hook re-imposes the SAME .cs write policy on lean-ctx's edit tools.
#
# SCOPE: only .cs writes are denied. Every other file (.ts/.js/.py/.md/.json…)
# passes through untouched, so lean-ctx keeps its fast editing on non-C# code.
#
# DORMANT WITHOUT LEAN-CTX: this hook only ever runs when a lean-ctx write tool
# is actually invoked, which can only happen if lean-ctx is installed. On a box
# without lean-ctx it never fires — safe to ship unconditionally in the plugin.
#
# CONTRACT (same as enforce-serena-write.sh): a PreToolUse hook changes the
# decision only by printing JSON with hookSpecificOutput.permissionDecision and
# exiting 0. A silent exit 0 is NOT an approval — it defers to the normal
# permission flow, which is exactly "pass through untouched" for non-.cs writes.
#
# FAIL-OPEN ON OWN MALFUNCTION: never block the user because of THIS hook's own
# bug (jq missing, malformed stdin, parse error) => allow (exit 0). The only
# path that blocks is the explicit, well-formed .cs deny below.

set -uo pipefail  # -e intentionally omitted: every error path must reach exit 0

# Drain stdin (the tool-call JSON) up front. Failure here is non-fatal.
input="$(cat 2>/dev/null || true)"

# --- FAIL-OPEN: jq is required to inspect the payload -----------------------
command -v jq >/dev/null 2>&1 || exit 0

# --- Only act on lean-ctx WRITE tools ---------------------------------------
# hooks.json already scopes the matcher, but re-check here so the hook is correct
# even if the matcher over-matches (fail-open on anything unexpected).
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$tool_name" in
  *ctx_patch|*ctx_edit|*ctx_fill) : ;;   # a lean-ctx write tool — in scope
  *) exit 0 ;;                            # anything else — defer
esac

# --- Collect every candidate target path from tool_input --------------------
# lean-ctx write tools name their target differently across versions/tools
# (path / file_path / file), and some accept batches (paths[] / files[] /
# edits[].path). Pull them all; on any jq error, fail open (allow).
paths="$(printf '%s' "$input" | jq -r '
  [ .tool_input.path?,
    .tool_input.file_path?,
    .tool_input.file?,
    (.tool_input.paths?  // [])[]?,
    (.tool_input.files?  // [])[]?,
    (.tool_input.edits?  // [])[]?.path?,
    (.tool_input.patches? // [])[]?.path?
  ] | map(select(. != null and . != "")) | .[]' 2>/dev/null || true)"

# No resolvable path => nothing to judge => defer (fail-open).
[[ -n "$paths" ]] || exit 0

# --- Is any target a .cs file? ----------------------------------------------
# Case-insensitive ".cs" suffix via a bracket glob (*.[cC][sS]) — bash 3.1+ safe
# (no ${var,,}), and still excludes .csproj/.cshtml/.csx (none END in ".cs").
hit=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if [[ "$p" == *.[cC][sS] ]]; then hit="$p"; break; fi
done <<< "$paths"

# No .cs target => pass through untouched (lean-ctx edits non-C# files freely).
[[ -n "$hit" ]] || exit 0

# --- Onboarding-aware guidance (message only; never changes the decision) ----
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${PWD:-.}"

if [[ -d "$cwd/.serena" ]]; then
  reason="Editing .cs through lean-ctx (${tool_name}, target: ${hit}) is blocked by serena-forge — C# edits must go through Serena's Roslyn-backed symbolic tools, not lean-ctx's text patcher. To CREATE a new C# file use Serena's create_text_file; to EDIT one, map it with get_symbols_overview, locate the target with find_symbol, then change it with replace_symbol_body / insert_after_symbol / insert_before_symbol (rename_symbol / safe_delete_symbol for structural changes). lean-ctx's ctx_patch/ctx_edit/ctx_fill remain fine for non-.cs files. If Serena genuinely cannot make this edit, STOP and ask the user — do not route around this block."
else
  reason="Editing .cs through lean-ctx (${tool_name}, target: ${hit}) is blocked by serena-forge. This repo is NOT Serena-onboarded yet (no .serena/ folder), so Serena's symbolic edit tools cannot act on it. PROPOSE onboarding to the user (offer the serena-forge-setup skill) and run it once they agree, then edit through Serena's symbolic tools. Do NOT fall back to a lean-ctx text patch on the .cs file. (ctx_patch/ctx_edit/ctx_fill stay available for non-.cs files.)"
fi

# Build the JSON with jq so any quotes/backslashes in the path/tool are escaped
# safely. If jq -n somehow fails, no decision is emitted and we exit 0 (fail-open).
jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'

exit 0
