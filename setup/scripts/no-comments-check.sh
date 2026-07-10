#!/usr/bin/env bash
# Interdit les commentaires dans les lignes AJOUTEES d'un diff .cs.
# /// autorise uniquement au-dessus d'un record / enum / membre d'enum.
# L'existant deja commite n'est jamais signale.
#
#   no-comments-check.sh HEAD                  hook PostToolUse (defaut)
#   no-comments-check.sh --cached              pre-commit
#   no-comments-check.sh origin/develop...HEAD CI
set -uo pipefail
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
DIFF_ARGS=${1:-HEAD}
rc=0

scan() { # $1=fichier  $2=lignes ajoutees separees par espace, ou "ALL"
  awk -v F="$1" -v ADD="$2" '
    BEGIN { all = (ADD == "ALL"); n = split(ADD, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    function report(ln, msg) { if (all || ln in ok) { printf "%s:%d: %s\n", F, ln, msg; rc = 1 } }
    /^[[:space:]]*\/\/\// { if (!d) d = FNR; next }
    { code = $0; gsub(/"([^"\\]|\\.)*"/, "\"\"", code) }
    d && code ~ /^[[:space:]]*(\[|$)/ { next }
    d {
      if (code !~ /(^|[^A-Za-z])(record|enum)([^A-Za-z]|$)/ &&
          code !~ /^[[:space:]]*[A-Z][A-Za-z0-9_]*[[:space:]]*(=[^,]*)?,?[[:space:]]*$/)
        report(d, "XML doc interdite ici (record ApiModel / enum uniquement)")
      d = 0
    }
    code ~ /^[[:space:]]*\/\// || code ~ /[^\/]\/\/[^\/]/ || code ~ /^[[:space:]]*\/\*/ {
      report(FNR, "commentaire interdit")
    }
    END { exit rc }
  ' "$1"
}

while IFS= read -r f; do
  [ -f "$f" ] || continue
  lines=$(git diff $DIFF_ARGS -U0 -- "$f" | awk '
    /^@@/ { split($3, h, ","); s = substr(h[1], 2) + 0; n = (h[2] == "" ? 1 : h[2] + 0)
            for (i = 0; i < n; i++) printf "%d ", s + i }')
  [ -z "$lines" ] && continue
  scan "$f" "$lines" >&2 || rc=1
done < <(git diff $DIFF_ARGS --name-only --diff-filter=ACM -- '*.cs')

if [ "$DIFF_ARGS" = "HEAD" ]; then
  while IFS= read -r f; do
    scan "$f" ALL >&2 || rc=1
  done < <(git ls-files --others --exclude-standard -- '*.cs')
fi

if [ $rc -ne 0 ]; then
  echo "Regle CLAUDE.md : supprime ces commentaires. Un nom clair remplace le commentaire." >&2
  exit 2
fi
exit 0
