#!/usr/bin/env bash
# ============================================================================
# serena-forge :: hooks/queue-build.sh
#
# PostToolUse hook (matcher = Serena's symbolic WRITE tools, wired in
# hooks/hooks.json). Its only job is CHEAP: figure out which .csproj the edited
# symbol lives in and append that project's absolute path to a per-repo build
# queue. The actual `dotnet build` runs ONCE at end of turn in
# flush-build-queue.sh (Stop hook). This debounce is deliberate: a full build
# after every symbolic edit is prohibitively slow on large brownfield solutions,
# so we coalesce all edits of a turn into a single scoped build.
#
# This is the compilation safety net the graph tools cannot give you: after
# Serena mutates a symbol, the touched project is actually compiled by Roslyn's
# real build, and any error is fed back to the agent (see flush-build-queue.sh).
#
# Queue location: a temp file keyed by the repo cwd, NOT a file inside the repo —
# so we never pollute the consumer's working tree or risk it being committed.
#
# OPT-OUT: export SERENA_FORGE_BUILD=0 to disable the build safety net entirely
# (this hook becomes a silent no-op, and so does the flush).
#
# FAIL-OPEN ON OWN MALFUNCTION: a PostToolUse hook cannot un-do the edit; its
# only effect here is enqueuing. Any internal error (no jq, bad stdin, no csproj)
# => enqueue nothing and exit 0. Never break the turn because of our own bug.

set -uo pipefail

# Global opt-out.
[[ "${SERENA_FORGE_BUILD:-1}" == "0" ]] && exit 0

# jq is required to parse the payload; without it, fail-open (no queueing).
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

# Session cwd = the activated Serena project root (Serena relative_path is
# resolved against it). Fall back to the hook process PWD.
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${PWD:-.}"

# Serena's symbolic edit tools carry the target file under tool_input.relative_path
# (relative to the project root). Some tools may instead use file_path; accept both.
rel="$(printf '%s' "$input" | jq -r '.tool_input.relative_path // .tool_input.file_path // empty' 2>/dev/null || true)"
[[ -n "$rel" ]] || exit 0

# Resolve to an absolute path. If rel is already absolute, keep it.
if [[ "$rel" = /* ]]; then
  abs="$rel"
else
  abs="$cwd/$rel"
fi

# Only C# edits are worth compiling.
[[ "$abs" == *.[cC][sS] ]] || exit 0

# Walk up from the edited file's directory to the repo root, looking for the
# nearest .csproj (the "touched project"). Stop at cwd so we never escape the repo.
dir="$(dirname "$abs")"
proj=""
while [[ -n "$dir" && "$dir" != "/" ]]; do
  # First .csproj found on the way up wins.
  for candidate in "$dir"/*.csproj; do
    if [[ -f "$candidate" ]]; then
      proj="$candidate"
      break
    fi
  done
  [[ -n "$proj" ]] && break
  # Stop once we've checked the repo root itself.
  [[ "$dir" == "$cwd" ]] && break
  dir="$(dirname "$dir")"
done

# No project found => nothing to build; fail-open.
[[ -n "$proj" ]] || exit 0

# Per-repo queue file in TMPDIR, keyed by a checksum of cwd so concurrent repos
# don't collide and we never write inside the working tree.
key="$(printf '%s' "$cwd" | cksum 2>/dev/null | cut -d' ' -f1)"
[[ -n "$key" ]] || key="default"
queue="${TMPDIR:-/tmp}/serena-forge-build-queue-${key}"

# Append the project (dedup on flush, not here — keep this hook branch-free/fast).
printf '%s\n' "$proj" >> "$queue" 2>/dev/null || true

exit 0
