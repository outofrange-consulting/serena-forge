#!/usr/bin/env bash
# ============================================================================
# serena-forge :: hooks/flush-build-queue.sh
#
# Stop hook. Runs ONCE at end of turn. It drains the per-repo build queue that
# queue-build.sh filled during the turn and compiles each touched .csproj with a
# real `dotnet build`. If any project fails to compile, it BLOCKS the stop and
# feeds the compiler errors back to the agent so it fixes them before finishing —
# this is the "build → then continue" validation loop from the recommendations.
#
# Stop-hook output contract (verified):
#   - exit 0 with no JSON  => allow the turn to stop normally.
#   - print {"decision":"block","reason":"<text>"} and exit 0 => the turn does
#     NOT stop; <reason> is shown to the model, which keeps working.
# We only block on a genuine compile failure, and we honour stop_hook_active to
# avoid an infinite build/fix loop: if we already blocked once this turn and the
# build still fails, we REPORT the failure but let the turn end (no re-block), so
# the user is never trapped.
#
# OPT-OUT: SERENA_FORGE_BUILD=0 disables the whole build safety net.
#
# FAIL-OPEN ON OWN MALFUNCTION: any internal error (no jq, no dotnet, unreadable
# queue) => allow the stop (exit 0). We never trap the user because of our own
# bug, and a missing toolchain simply means "no build this turn".

set -uo pipefail

# Always clear the queue on exit so a stale queue can't trigger phantom builds
# on a later, unrelated turn.
queue=""
cleanup() { [[ -n "$queue" ]] && rm -f "$queue" 2>/dev/null || true; }
trap cleanup EXIT

# Global opt-out.
[[ "${SERENA_FORGE_BUILD:-1}" == "0" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${PWD:-.}"

# Did a previous Stop hook already block this turn? If so we must not block again
# (loop guard) — we degrade to report-only.
stop_active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"

key="$(printf '%s' "$cwd" | cksum 2>/dev/null | cut -d' ' -f1)"
[[ -n "$key" ]] || key="default"
queue="${TMPDIR:-/tmp}/serena-forge-build-queue-${key}"

# Nothing queued => nothing to validate.
[[ -s "$queue" ]] || exit 0

# Need the SDK to build; without it, fail-open (report nothing).
command -v dotnet >/dev/null 2>&1 || exit 0

# Dedup the queued projects, preserving order.
mapfile -t projects < <(awk 'NF && !seen[$0]++' "$queue" 2>/dev/null || true)
[[ "${#projects[@]}" -gt 0 ]] || exit 0

failures=""
for proj in "${projects[@]}"; do
  [[ -f "$proj" ]] || continue
  # Scoped, restore-free build of just the touched project. --nologo keeps the
  # captured output lean; we only surface it on failure.
  out="$(dotnet build "$proj" --no-restore --nologo -clp:NoSummary 2>&1)"
  if [[ $? -ne 0 ]]; then
    # Keep only the compiler error lines (and cap them) so we hand the agent a
    # tight, actionable error list instead of a wall of MSBuild noise.
    errs="$(printf '%s\n' "$out" | grep -iE 'error|: error ' | head -n 40 || true)"
    [[ -n "$errs" ]] || errs="$(printf '%s\n' "$out" | tail -n 40)"
    failures+="Project: ${proj}"$'\n'"${errs}"$'\n\n'
  fi
done

# All queued projects compiled => allow the stop silently.
[[ -n "$failures" ]] || exit 0

reason="serena-forge build validation FAILED after your C# edits. The touched project(s) do not compile. Fix these compiler errors through Serena's symbolic tools (do not stop with a broken build), then let the turn finish:

${failures}"

# Loop guard: if we already blocked once this turn, report but let the turn end.
if [[ "$stop_active" == "true" ]]; then
  # Emit nothing to stdout (allow stop); surface the failure on stderr so it is
  # visible without re-blocking and trapping the user.
  printf '%s\n' "$reason" 1>&2
  exit 0
fi

# First failure this turn: block the stop and feed the errors back to the agent.
jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
exit 0
