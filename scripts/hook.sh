#!/bin/sh
# Lidless: the script behind the frequent hooks.
#
#   hook.sh prompt     UserPromptSubmit
#   hook.sh busy       PostToolUse
#   hook.sh stop       Stop
#   hook.sh stopfail   StopFailure
#   hook.sh end        SessionEnd
#
# While Lidless is off, the first test below ends the script, so a hook costs
# one file check. While it is on, a hook writes a one-word marker (busy,
# waiting or idle) for the session, using shell builtins and one small read.
#
# What it reads from the hook input: the session id, the reason a session
# ended, and whether background tasks or scheduled wake-ups exist. It never
# stores the prompt, tool input, tool output or any other conversation text.
#
# Plain POSIX sh: on Windows this runs under Git Bash, on macOS under /bin/sh.

LD=${LIDLESS_HOME:-$HOME/.claude/lidless}
[ -e "$LD/on" ] || exit 0
ev=${1:-}

# The session id sits at the front of the hook input, so the frequent events
# only read the first few KB instead of a whole prompt or tool result.
case $ev in
  prompt|busy) input=$(head -c 4096) ;;
  *) input=$(cat) ;;
esac

# jget KEY: put the string value of the first "KEY" in $input into JV.
jget() {
  JV=
  case $input in *"\"$1\""*) ;; *) return 1 ;; esac
  JV=${input#*"\"$1\""}
  JV=${JV#*\"}
  JV=${JV%%\"*}
}

jget session_id
sid=$JV
case $sid in ''|*[!A-Za-z0-9_-]*) sid=unknown ;; esac
mark=$LD/busy/$sid

# Find the Lidless registration that belongs to this conversation.
# Sets mine (file path) and deadline.
find_mine() {
  mine=; deadline=0
  for f in "$LD"/sessions/*; do
    case ${f##*/} in *[!0-9]*) continue ;; esac
    [ -f "$f" ] || continue
    s=; d=0
    while IFS='=' read -r k v; do
      case $k in
        session_id) s=$v ;;
        deadline) d=$v ;;
      esac
    done < "$f"
    if [ "$s" = "$sid" ]; then mine=$f; deadline=$d; return 0; fi
  done
  return 1
}

case $ev in
  busy)
    echo busy > "$mark" 2>/dev/null
    ;;

  prompt)
    echo busy > "$mark" 2>/dev/null
    find_mine || exit 0
    now=$(date +%s)
    note=
    case $deadline in ''|*[!0-9]*) deadline=0 ;; esac
    if [ "$deadline" -gt 0 ]; then
      left=$((deadline - now))
      if [ "$left" -gt 0 ] && [ "$left" -le 900 ]; then
        mins=$(( (left + 59) / 60 ))
        note="the time limit for this session ends in about $mins min. After that the laptop goes back to its normal sleep behaviour, and with the lid closed this remote session will drop. To extend it the user can send /lidless 2h (any limit such as 90m or 1h30m works), or say \"keep the laptop awake 2 more hours\"."
      fi
    fi
    if [ -r "$LD/run/battery" ]; then
      pct=; src=; floor=
      read -r pct src floor < "$LD/run/battery"
      case $pct in ''|*[!0-9]*) pct= ;; esac
      case $floor in ''|*[!0-9]*) floor=0 ;; esac
      if [ -n "$pct" ] && [ "$src" = battery ] && [ "$floor" -gt 0 ] && [ "$pct" -le $((floor + 5)) ]; then
        bnote="the laptop is on battery at ${pct}%. Lidless turns itself off at ${floor}% on battery, and the laptop then sleeps with the lid closed. Plugging in the charger keeps it going. The floor is batteryFloor in ~/.claude/lidless/config.json."
        if [ -n "$note" ]; then note="$note Also, $bnote"; else note=$bnote; fi
      fi
    fi
    [ -n "$note" ] || exit 0
    # Say it at most once every 5 minutes per session.
    w=$LD/run/warned.${mine##*/}
    if [ -r "$w" ]; then
      last=0
      read -r last < "$w"
      case $last in ''|*[!0-9]*) last=0 ;; esac
      [ $((now - last)) -lt 300 ] && exit 0
    fi
    echo "$now" > "$w" 2>/dev/null
    # Plain text on stdout from a UserPromptSubmit hook is added to Claude's context.
    echo "Lidless notice (from the keep-awake plugin running on this laptop): $note The user asked to be told about this in the reply to this message, together with how to extend."
    ;;

  stop)
    # Claude finished its turn. It only counts as idle when nothing is
    # still running in the background and nothing is scheduled to wake it.
    st=idle
    case $input in
      *'"background_tasks"'*)
        rest=$input
        while :; do
          case $rest in *'"type"'*) ;; *) break ;; esac
          rest=${rest#*'"type"'}
          t=${rest#*\"}
          t=${t%%\"*}
          # Monitors run for the whole session, so they do not count as work in flight.
          [ "$t" = monitor ] || st=waiting
        done
        ;;
    esac
    case $input in
      *'"session_crons":[]'*|*'"session_crons": []'*) ;;
      *'"session_crons"'*) st=waiting ;;
    esac
    echo "$st" > "$mark" 2>/dev/null
    ;;

  stopfail)
    echo idle > "$mark" 2>/dev/null
    ;;

  end)
    jget reason
    why=$JV
    # /clear and /resume keep the same Claude process, so Lidless stays on.
    case $why in clear|resume) exit 0 ;; esac
    case $why in ''|*[!A-Za-z0-9_-]*) why=exit ;; esac
    if find_mine; then echo "$why" > "$mine.end" 2>/dev/null; fi
    # On Linux and macOS tidying up is cheap, so do it right away.
    # On Windows the hidden watcher picks the flag up within a few seconds.
    case $(uname -s 2>/dev/null) in
      Linux*|Darwin*)
        DIR=${0%/*}
        [ "$DIR" = "$0" ] && DIR=.
        exec sh "$DIR/lidless.sh" reconcile > /dev/null 2>&1
        ;;
    esac
    ;;
esac
exit 0
