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

# No TTY here, so clepsydre would see no COLUMNS and fall back to its narrowest caps.
# The reserve buys columns for the weekly segment we append past clepsydre's own tail,
# which its width budget cannot see — without it, ours is what the terminal clips.
gauge=$(printf '%s' "$in" \
  | COLUMNS="${COLUMNS:-140}" CLEPSYDRE_WIDTH_RESERVE="${CLEPSYDRE_WIDTH_RESERVE:-26}" \
    node "{{CLEPSYDRE}}" 2>/dev/null \
  | sed -e 's/ · /·/g' -e 's/  */ /g' \
        -e 's/MEMORY\.md/Memory/' \
        -e 's|·mem [0-9.]*[BKMG]*/[0-9]*f||')
# clepsydre renders its own "[model]" prefix; ours replaces it.
[ -n "$model" ] && gauge=$(printf '%s' "$gauge" | sed -E 's/^\[[^]]*\] ?//')

# clepsydre pins the 5h window to the far right and reads only rate_limits.five_hour.
# The weekly caps ride just after it: seven_day, or seven_day_opus when that one is
# the higher — the binding constraint is the one worth showing.
weekly=$(printf '%s' "$in" | node -e '
  let d={};try{d=JSON.parse(require("fs").readFileSync(0,"utf8"))}catch{}
  const rl=d.rate_limits;if(!rl)process.exit(0);
  const pick=w=>w&&typeof w.used_percentage==="number"
    ?{pct:Math.trunc(w.used_percentage),at:typeof w.resets_at==="number"?w.resets_at:null}:null;
  const all=pick(rl.seven_day),opus=pick(rl.seven_day_opus);
  const w=!all?opus:!opus?all:opus.pct>all.pct?{...opus,o:1}:all;
  if(!w)process.exit(0);
  const now=Math.floor(Date.now()/1000);
  const left=w.at===null?null:w.at-now;
  if(left!==null&&left<-60){process.stdout.write("\x1b[32m📅 reset\x1b[0m");process.exit(0)}
  const col=w.pct>=90?"\x1b[1;31m":w.pct>=70?"\x1b[33m":"\x1b[32m";
  const cd=s=>{const t=Math.max(0,s),dy=Math.trunc(t/86400),h=Math.trunc((t%86400)/3600);
    return dy>0?`${dy}d${h}h`:h>0?`${h}h${String(Math.trunc((t%3600)/60)).padStart(2,"0")}`:`${Math.trunc(t/60)}m`};
  process.stdout.write(col+"📅 "+w.pct+"%"+(w.o?"ᴼ":"")+(left!==null?" ↻ "+cd(left):"")+"\x1b[0m");
' 2>/dev/null)

[ -n "$model" ] && printf '\033[38;5;80m%s\033[0m ' "$model"
printf '%s' "$gauge"
[ -n "$weekly" ] && printf '·%s' "$weekly"
