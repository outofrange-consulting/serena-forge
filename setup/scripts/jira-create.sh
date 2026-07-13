#!/usr/bin/env bash
# Create a Jira work item from a --from-json file and print ONLY the resulting key.
#
# Exists because `acli jira workitem create --json` prints a large payload whose "key"
# is not near the tail: truncating it with `tail` loses the key, and re-running `create`
# to recover the key silently creates a DUPLICATE ticket (LOT denies delete permission,
# so a duplicate can only be cancelled, never removed).
#
# Two guards, in order:
#   1. LOCAL LEDGER (authoritative). Jira's search index is ASYNC — a ticket created
#      seconds ago is not yet findable, which is exactly the window in which the
#      duplicate happens. The ledger closes it; a remote search cannot.
#   2. Remote search (backstop for tickets created on another machine/session).
#
# Prints the key on stdout, or fails loudly with the full payload. Never silent.
#
# Usage: jira-create.sh <from-json-file> [extra acli args...]
#   e.g. jira-create.sh /tmp/wi.json --parent LCT-46421
set -euo pipefail

LEDGER="${JIRA_CREATE_LEDGER:-$HOME/.claude/state/jira-created.tsv}"
mkdir -p "$(dirname "$LEDGER")"
touch "$LEDGER"

JSON_FILE="${1:?usage: jira-create.sh <from-json-file> [extra acli args...]}"
shift || true
[ -r "$JSON_FILE" ] || { echo "jira-create: cannot read $JSON_FILE" >&2; exit 1; }

read -r PROJECT SUMMARY < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
p=d.get("projectKey") or ""
s=(d.get("summary") or "").replace("\n"," ").replace("\t"," ").strip()
if not p or not s:
    sys.exit("jira-create: projectKey and summary are required in the JSON")
print(p, s)
' "$JSON_FILE")
SUMMARY="${SUMMARY# }"
FINGERPRINT="$PROJECT	$SUMMARY"

# --- Guard 1: local ledger (immune to Jira's async search index) ---
if PRIOR=$(grep -iF "$FINGERPRINT	" "$LEDGER" 2>/dev/null | tail -1 | cut -f3) && [ -n "${PRIOR:-}" ]; then
  echo "jira-create: this exact summary was already created as $PRIOR (local ledger) — NOT creating a duplicate." >&2
  echo "jira-create: if you truly want another ticket, change the summary or edit $LEDGER." >&2
  echo "$PRIOR"
  exit 0
fi

# --- Guard 2: remote search (catches other machines/sessions; misses fresh tickets) ---
JQL_SUMMARY=${SUMMARY//\"/\\\"}
EXISTING=$(acli jira workitem search \
  --jql "project = $PROJECT AND summary ~ \"$JQL_SUMMARY\" AND statusCategory != Done" \
  --json 2>/dev/null \
  | python3 -c '
import json,sys
want=sys.argv[1].strip().lower()
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
items=d if isinstance(d,list) else d.get("issues") or d.get("workItems") or []
for it in items:
    f=it.get("fields") or {}
    if (f.get("summary") or it.get("summary") or "").strip().lower()==want:
        print(it.get("key") or f.get("key") or "")
' "$SUMMARY" | head -1)

if [ -n "$EXISTING" ]; then
  echo "jira-create: an open ticket with this exact summary already exists — NOT creating a duplicate." >&2
  printf '%s\t%s\n' "$FINGERPRINT" "$EXISTING" >>"$LEDGER"
  echo "$EXISTING"
  exit 0
fi

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
if ! acli jira workitem create --from-json "$JSON_FILE" --json "$@" >"$OUT" 2>&1; then
  echo "jira-create: acli create FAILED — no ticket was created. Full output:" >&2
  cat "$OUT" >&2
  exit 1
fi

KEY=$(grep -oE '"key" *: *"[A-Z]+-[0-9]+"' "$OUT" | head -1 | grep -oE '[A-Z]+-[0-9]+' || true)
if [ -z "$KEY" ]; then
  # The ticket EXISTS even though we cannot name it. Record the attempt so a re-run is blocked.
  printf '%s\t%s\n' "$FINGERPRINT" "UNPARSED-SEE-JIRA" >>"$LEDGER"
  echo "jira-create: created, but could NOT parse the key. DO NOT re-run create." >&2
  echo "jira-create: find it with: acli jira workitem search --jql 'project = $PROJECT ORDER BY created DESC'" >&2
  cat "$OUT" >&2
  exit 1
fi

printf '%s\t%s\n' "$FINGERPRINT" "$KEY" >>"$LEDGER"
echo "$KEY"
