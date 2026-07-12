#!/usr/bin/env bash
set -u
shopt -s extglob

payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

declare -a candidates=()

resolve_and_add() {
  local p="$1" root
  [ -n "$p" ] || return 0
  case "$p" in
    /*) candidates+=("$p"); return 0 ;;
  esac
  if [ -f "$cwd/$p" ]; then
    candidates+=("$cwd/$p"); return 0
  fi
  root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$root" ] && [ -f "$root/$p" ]; then
    candidates+=("$root/$p"); return 0
  fi
  candidates+=("$cwd/$p")
}

for key in '.tool_input.file_path' '.tool_input.relative_path' '.tool_input.path'; do
  v="$(printf '%s' "$payload" | jq -r "$key // empty")"
  resolve_and_add "$v"
done

case "$tool" in
  *ctx_execute|*ctx_shell|*replace_in_files|*rename_symbol|*safe_delete_symbol|*replace_content)
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
    while IFS= read -r f; do candidates+=("$f"); done < <(
      find "$root" \
        -type d \( -name .git -o -name node_modules -o -name bin -o -name obj -o -name .vs -o -name .idea \) -prune -o \
        -type f -newermt '25 seconds ago' -print 2>/dev/null | head -300
    )
    ;;
esac

[ "${#candidates[@]}" -gt 0 ] || exit 0

git_eol() {
  local file="$1" dir out
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)" || return 1
  out="$(git -C "$dir" check-attr eol -- "$file" 2>/dev/null)" || return 1
  case "$out" in
    *": eol: crlf") printf crlf ;;
    *": eol: lf") printf lf ;;
    *) return 1 ;;
  esac
}

section_matches() {
  local sec="$1" file="$2" ecdir="$3" pat rel base
  sec="${sec#\[}"; sec="${sec%\]}"
  [ -n "$sec" ] || return 1
  pat="$(printf '%s' "$sec" | perl -pe 's/\{([^{}]*)\}/"\@(".join("|",split(\/,\/,$1)).")"/ge')"
  rel="${file#"$ecdir"/}"
  base="$(basename "$file")"
  case "$pat" in
    */*)
      pat="${pat#/}"
      [[ "$rel" == $pat ]] && return 0
      [[ "$rel" == $pat ]] || [[ "/$rel" == $pat ]] && return 0
      return 1
      ;;
    *)
      [[ "$base" == $pat ]] && return 0
      return 1
      ;;
  esac
}

editorconfig_eol() {
  local file="$1" dir ec line sec val result=""
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)" || return 1
  while :; do
    ec="$dir/.editorconfig"
    if [ -f "$ec" ]; then
      sec=""
      while IFS= read -r line; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
          '#'*|';'*|'') continue ;;
          '['*']'*) sec="${line%%]*}]"; continue ;;
        esac
        case "$line" in
          [Ee][Nn][Dd]_[Oo][Ff]_[Ll][Ii][Nn][Ee]*([[:space:]])=*)
            val="${line#*=}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%%[[:space:];#]*}"
            val="$(printf '%s' "$val" | tr 'A-Z' 'a-z')"
            if [ -z "$sec" ] || section_matches "$sec" "$file" "$dir"; then
              result="$val"
            fi
            ;;
        esac
      done < "$ec"
      [ -n "$result" ] && { printf '%s' "$result"; return 0; }
      grep -qiE '^[[:space:]]*root[[:space:]]*=[[:space:]]*true' "$ec" && return 1
    fi
    [ "$dir" = "/" ] && return 1
    dir="$(dirname "$dir")"
  done
}

wants_crlf() {
  local file="$1" eol
  if command -v editorconfig >/dev/null 2>&1; then
    eol="$(editorconfig "$file" 2>/dev/null | sed -n 's/^end_of_line=//Ip' | head -1 | tr 'A-Z' 'a-z')"
    [ -n "$eol" ] && { [ "$eol" = "crlf" ]; return; }
  fi
  eol="$(editorconfig_eol "$file")" && [ -n "$eol" ] && { [ "$eol" = "crlf" ]; return; }
  eol="$(git_eol "$file")" && [ -n "$eol" ] && { [ "$eol" = "crlf" ]; return; }
  return 1
}

for f in "${candidates[@]}"; do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  wants_crlf "$f" || continue
  perl -i -pe 's/\r?\n/\r\n/' "$f" 2>/dev/null || true
done
exit 0
