#!/usr/bin/env bash
# Managed by serena-forge setup/install-wsl.sh — regenerated on every run.
# Compact model badge + the clepsydre context gauge.
in=$(cat)

# Window comes from context_window_size (the model's real window), not the
# CLAUDE_CODE_AUTO_COMPACT_WINDOW denominator clepsydre uses.
model=$(printf '%s' "$in" | node -e '
  let d={};try{d=JSON.parse(require("fs").readFileSync(0,"utf8"))}catch{}
  const name=d.model?.display_name||"";const n=name.toLowerCase();
  const icon=n.includes("opus")?"🎼 ":n.includes("sonnet")?"🪶 ":n.includes("haiku")?"🍃 ":n.includes("fable")?"📖":"🤖";
  const ver=(name.match(/[0-9]+(?:\.[0-9]+)?/)||[""])[0];
  const cw=d.context_window?.context_window_size||0;
  const win=cw>=1000000?"1M":cw>=1000?Math.round(cw/1000)+"k":"";
  if(!name){process.exit(0)}
  process.stdout.write(icon+ver+(win?" ("+win+")":""));
' 2>/dev/null)

gauge=$(printf '%s' "$in" | node "{{CLEPSYDRE}}" 2>/dev/null \
  | sed -e 's/ · /·/g' -e 's/  */ /g')
# clepsydre renders its own "[model]" prefix; ours replaces it.
[ -n "$model" ] && gauge=$(printf '%s' "$gauge" | sed -E 's/^\[[^]]*\] ?//')

[ -n "$model" ] && printf '\033[38;5;80m%s\033[0m ' "$model"
printf '%s' "$gauge"
