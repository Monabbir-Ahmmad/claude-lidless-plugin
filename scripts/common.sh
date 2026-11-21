# Lidless: logic shared by Linux and macOS. Sourced by lidless.sh.
# The OS file (linux.sh or macos.sh) supplies the os_* functions:
#   os_preflight        check the tools Lidless needs, print why if missing
#   os_apply            switch lid-close sleep off machine wide (first session)
#   os_session_start P  per session keep-awake tied to Claude pid P
#   os_session_stop P   undo os_session_start
#   os_restore_all      put everything back to normal
#   os_dirty            true when something Lidless changed is still in place
#   os_tick N           periodic self check, called by the monitor
#   os_lid              prints open, closed or unknown
#   os_lock_screen      lock the screen now
#   os_battery          prints "<percent> ac", "<percent> battery" or "none"
#   os_boot_reset       prints installed, missing or notneeded
#   os_setup            print the one-time setup command
# A failing os_* function leaves a message for the user in OS_ERR.

SESS=$LD/sessions
RUN=$LD/run
BUSY=$LD/busy
STATE=$LD/state
LOG=$LD/lidless.log
CFG=$LD/config.json
OS_ERR=
LAST_REASON=

say() { printf '%s\n' "$*"; }

ensure_dirs() {
  mkdir -p "$SESS" "$RUN" "$BUSY" "$STATE" 2>/dev/null
  # First use: write the settings file with its defaults, so it is easy to find and edit.
  if [ ! -f "$CFG" ]; then
    cat > "$CFG" <<'JSON'
{
  "idleMinutes": 0,
  "batteryFloor": 20,
  "defaultLimit": 0,
  "lockOnLidClose": true
}
JSON
  fi
}

now() { date +%s; }

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# Keep the log from growing forever.
trim_log() {
  [ -f "$LOG" ] || return 0
  _n=$(wc -l < "$LOG" | tr -d ' ')
  if [ "${_n:-0}" -gt 1000 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
}

is_uint() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- settings
# ~/.claude/lidless/config.json is a small flat JSON object. 0 or false turns a check off.
cfg_load() {
  CFG_IDLE=0
  CFG_FLOOR=20
  CFG_LIMIT=0
  CFG_LOCK=true
  [ -f "$CFG" ] || return 0
  _flat=$(tr -d '\r\n\t "' < "$CFG" | tr -d '{}' | tr ',' '\n')
  _oldifs=$IFS
  IFS='
'
  set -f
  for _kv in $_flat; do
    _k=${_kv%%:*}
    _v=${_kv#*:}
    case $_k in
      idleMinutes)
        if is_uint "$_v"; then CFG_IDLE=$_v; else CFG_IDLE=0; fi ;;
      batteryFloor)
        if is_uint "$_v"; then CFG_FLOOR=$_v; elif [ "$_v" = false ]; then CFG_FLOOR=0; fi ;;
      defaultLimit)
        CFG_LIMIT=$_v ;;
      lockOnLidClose)
        case $_v in false|0) CFG_LOCK=false ;; *) CFG_LOCK=true ;; esac ;;
    esac
  done
  set +f
  IFS=$_oldifs
}

# ------------------------------------------------------------------- limits
# parse_limit TEXT: prints seconds, "none" (no limit) or "bad".
# Accepts 3h, 90m, 1h30m, 1h30, 1:30, 1.5h, "2 hours", and a bare number (hours).
parse_limit() {
  printf '%s\n' "$1" | awk '{
    s = tolower($0)
    gsub(/[ \t]/, "", s)
    if (s == "0" || s == "none" || s == "off" || s == "no" || s == "nolimit" || s == "unlimited" || s == "false") { print "none"; exit }
    gsub(/hours|hour|hrs|hr/, "h", s)
    gsub(/minutes|minute|mins|min/, "m", s)
    if (s ~ /^[0-9]+:[0-9][0-9]$/) { split(s, a, ":"); s = a[1] "h" a[2] "m" }
    if (s ~ /^[0-9]+(\.[0-9]+)?h[0-9]+$/) { s = s "m" }
    if (s ~ /^[0-9]+(\.[0-9]+)?$/) {
      t = s * 3600
    } else if (s != "" && s ~ /^([0-9]+(\.[0-9]+)?h)?([0-9]+m)?$/) {
      h = 0; m = 0
      i = index(s, "h"); if (i > 0) { h = substr(s, 1, i - 1); s = substr(s, i + 1) }
      i = index(s, "m"); if (i > 0) { m = substr(s, 1, i - 1) }
      t = h * 3600 + m * 60
    } else { print "bad"; exit }
    t = int(t + 0.5)
    if (t == 0) { print "none"; exit }
    if (t < 60 || t > 604800) { print "bad"; exit }
    print t
  }'
}

# fmt_dur SECONDS: "1h 30m", "45m", "under 1m"
fmt_dur() {
  _s=$1
  [ "$_s" -lt 0 ] && _s=0
  if [ "$_s" -lt 60 ]; then echo "under 1m"; return; fi
  _h=$((_s / 3600))
  _m=$(( (_s % 3600 + 30) / 60 ))
  if [ "$_m" -eq 60 ]; then _h=$((_h + 1)); _m=0; fi
  if [ "$_h" -gt 0 ] && [ "$_m" -gt 0 ]; then echo "${_h}h ${_m}m"
  elif [ "$_h" -gt 0 ]; then echo "${_h}h"
  else echo "${_m}m"
  fi
}

# fmt_clock EPOCH: local HH:MM (GNU date first, then BSD date)
fmt_clock() {
  date -d "@$1" '+%H:%M' 2>/dev/null || date -r "$1" '+%H:%M' 2>/dev/null || echo "?"
}

# --------------------------------------------------------------- processes
# Start time as printed by ps. Together with the pid it identifies one process,
# so a recycled pid is never mistaken for the old Claude Code process.
proc_start() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'
}

proc_alive() { # pid start
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "$2" ] && [ "$(proc_start "$1")" = "$2" ]
}

is_claude() { # comm args
  _b=${1##*/}
  case $_b in claude|claude-code|Claude) return 0 ;; esac
  _first=${2%% *}
  case ${_first##*/} in claude|claude-code) return 0 ;; esac
  case $_first in */claude/versions/*) return 0 ;; esac
  case $_b in
    node|nodejs|bun|deno)
      case $2 in *claude*) return 0 ;; esac ;;
  esac
  return 1
}

# Walk up the parent processes until the Claude Code process is found.
find_claude() {
  _p=$$
  _hops=0
  while is_uint "$_p" && [ "$_p" -gt 1 ] && [ "$_hops" -lt 25 ]; do
    _comm=$(ps -o comm= -p "$_p" 2>/dev/null) || return 1
    _args=$(ps -o args= -p "$_p" 2>/dev/null)
    if [ "$_hops" -gt 0 ] && is_claude "$_comm" "$_args"; then
      echo "$_p"
      return 0
    fi
    _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
    _hops=$((_hops + 1))
  done
  return 1
}

# Run a command fully detached, so it survives the shell, the terminal and
# Claude Code itself going away.
detach() {
  if command -v setsid > /dev/null 2>&1; then
    setsid "$@" < /dev/null > /dev/null 2>&1 &
  elif command -v perl > /dev/null 2>&1; then
    perl -e 'use POSIX; exit 0 if fork; POSIX::setsid(); exec @ARGV; exit 1' "$@" < /dev/null > /dev/null 2>&1
  else
    ( trap '' HUP; exec "$@" ) < /dev/null > /dev/null 2>&1 &
  fi
}

# -------------------------------------------------------------------- lock
lock() {
  _tries=0
  while ! mkdir "$RUN/lock" 2>/dev/null; do
    _tries=$((_tries + 1))
    if [ "$_tries" -gt 100 ]; then
      # Whoever held it is long gone.
      rmdir "$RUN/lock" 2>/dev/null
      _tries=0
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

unlock() { rmdir "$RUN/lock" 2>/dev/null; }

# ---------------------------------------------------------------- sessions
# One file per Claude Code process that has Lidless on: sessions/<pid>
sess_load() { # file -> S_PID S_START S_SID S_SINCE S_DEADLINE S_LIMIT
  S_PID=; S_START=; S_SID=; S_SINCE=0; S_DEADLINE=0; S_LIMIT=none
  while IFS='=' read -r _k _v; do
    case $_k in
      pid) S_PID=$_v ;;
      start) S_START=$_v ;;
      session_id) S_SID=$_v ;;
      since) S_SINCE=$_v ;;
      deadline) S_DEADLINE=$_v ;;
      limit) S_LIMIT=$_v ;;
    esac
  done < "$1"
  is_uint "$S_DEADLINE" || S_DEADLINE=0
  is_uint "$S_SINCE" || S_SINCE=0
}

sess_write() { # pid start sid since deadline limit
  printf 'pid=%s\nstart=%s\nsession_id=%s\nsince=%s\ndeadline=%s\nlimit=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$SESS/$1.tmp" && mv -f "$SESS/$1.tmp" "$SESS/$1"
}

# List the session files (pids) one per line.
sess_list() {
  for _f in "$SESS"/*; do
    case ${_f##*/} in *[!0-9]*) continue ;; esac
    [ -f "$_f" ] && echo "${_f##*/}"
  done
}

count_sessions() {
  _c=0
  for _f in "$SESS"/*; do
    case ${_f##*/} in *[!0-9]*) continue ;; esac
    [ -f "$_f" ] && _c=$((_c + 1))
  done
  echo "$_c"
}

end_session() { # pid reason
  os_session_stop "$1"
  if [ -f "$SESS/$1" ]; then
    sess_load "$SESS/$1"
    [ -n "$S_SID" ] && rm -f "$BUSY/$S_SID"
  fi
  rm -f "$SESS/$1" "$SESS/$1.end" "$SESS/$1.tmp" "$RUN/warned.$1"
  log "OFF  session $1: $2"
  LAST_REASON=$2
}

# Busy or idle for one session. Sets B_STATE (busy, waiting, idle) and B_SINCE.
busy_state() { # session id
  _mark=
  if [ -n "$1" ] && [ -f "$BUSY/$1" ]; then
    _mark=$BUSY/$1
  elif [ -z "$1" ]; then
    # The session id is not known. Use the most recent marker there is.
    _newest=$(ls -t "$BUSY" 2>/dev/null | head -n 1)
    [ -n "$_newest" ] && _mark=$BUSY/$_newest
  fi
  if [ -z "$_mark" ]; then
    # Nothing recorded yet: assume busy, which never triggers the idle rule.
    B_STATE=busy
    B_SINCE=$(now)
    return
  fi
  B_STATE=busy
  read -r B_STATE < "$_mark"
  case $B_STATE in busy|waiting|idle) ;; *) B_STATE=busy ;; esac
  B_SINCE=$(mtime "$_mark")
  # A missing timestamp must never look like "idle since forever".
  if ! is_uint "$B_SINCE" || [ "$B_SINCE" -le 0 ]; then B_SINCE=$(now); fi
}

# sweep quick|full [battery]
#   quick: drop sessions whose Claude Code process is gone or that were ended.
#   full:  also apply the time limit, the battery floor and the idle rule.
sweep() {
  _mode=$1
  _bat=${2:-none}
  _bpct=${_bat%% *}
  _bsrc=${_bat#* }
  _t=$(now)
  for _pid in $(sess_list); do
    _file=$SESS/$_pid
    [ -f "$_file" ] || continue
    sess_load "$_file"
    if [ -f "$_file.end" ]; then
      _why=exit
      read -r _why < "$_file.end"
      end_session "$_pid" "the session ended (${_why:-exit})"
      continue
    fi
    if ! proc_alive "$_pid" "$S_START"; then
      end_session "$_pid" "Claude Code is no longer running"
      continue
    fi
    [ "$_mode" = full ] || continue
    if [ "$S_DEADLINE" -gt 0 ] && [ "$_t" -ge "$S_DEADLINE" ]; then
      end_session "$_pid" "time limit reached ($S_LIMIT)"
      continue
    fi
    if [ "$CFG_FLOOR" -gt 0 ] && [ "$_bsrc" = battery ] && is_uint "$_bpct" && [ "$_bpct" -le "$CFG_FLOOR" ]; then
      end_session "$_pid" "battery at ${_bpct}% on battery power (floor ${CFG_FLOOR}%)"
      continue
    fi
    if [ "$CFG_IDLE" -gt 0 ]; then
      busy_state "$S_SID"
      if [ "$B_STATE" = idle ] && [ $((_t - B_SINCE)) -ge $((CFG_IDLE * 60)) ]; then
        end_session "$_pid" "Claude was idle for ${CFG_IDLE} minutes"
        continue
      fi
    fi
  done
}

# Put the machine back to normal when no session needs Lidless any more.
restore_now() { # reason
  if os_dirty || [ -e "$LD/on" ]; then
    if os_restore_all; then
      log "RESTORED normal sleep behaviour: $1"
    else
      log "FAILED to restore normal sleep behaviour: $OS_ERR"
    fi
  fi
  rm -f "$LD/on" "$RUN/battery"
  rm -f "$BUSY"/* "$RUN"/warned.* 2>/dev/null
  monitor_alive || rm -f "$RUN/monitor.pid"
  return 0
}

# ----------------------------------------------------------------- monitor
monitor_alive() {
  [ -f "$RUN/monitor.pid" ] || return 1
  _mp=; _ms=
  IFS='|' read -r _mp _ms < "$RUN/monitor.pid"
  is_uint "$_mp" && proc_alive "$_mp" "$_ms"
}

ensure_monitor() {
  monitor_alive && return 0
  detach sh "$DIR/lidless.sh" monitor
}

monitor_stop_signal() {
  trap '' TERM INT HUP
  lock
  sweep quick
  if [ "$(count_sessions)" -gt 0 ]; then
    # Something stopped the watcher while sessions still need it. Hand over to a new one.
    rm -f "$RUN/monitor.pid"
    log "NOTE the watcher was stopped while Lidless is on, starting a new one"
    unlock
    detach sh "$DIR/lidless.sh" monitor
  else
    restore_now "${LAST_REASON:-the watcher was stopped}"
    rm -f "$RUN/monitor.pid"
    unlock
  fi
  exit 0
}

monitor_main() {
  lock
  if monitor_alive; then
    unlock
    exit 0
  fi
  printf '%s|%s\n' "$$" "$(proc_start $$)" > "$RUN/monitor.pid"
  unlock
  trap monitor_stop_signal TERM INT HUP

  _lid_prev=$(os_lid)
  _tick=0
  while :; do
    cfg_load
    _battery=$(os_battery)
    lock
    sweep full "$_battery"
    if [ "$(count_sessions)" -eq 0 ]; then
      restore_now "${LAST_REASON:-no session is using it}"
      rm -f "$RUN/monitor.pid"
      unlock
      exit 0
    fi
    os_tick "$_tick"
    unlock

    # The prompt hook reads this to warn before the battery floor is reached.
    printf '%s %s\n' "$_battery" "$CFG_FLOOR" > "$RUN/battery.tmp" && mv -f "$RUN/battery.tmp" "$RUN/battery"

    _lid=$(os_lid)
    if [ "$_lid" = closed ] && [ "$_lid_prev" != closed ]; then
      if [ "$CFG_LOCK" = true ]; then
        if os_lock_screen; then
          log "LID  closed, screen locked"
        else
          log "LID  closed, but the screen lock could not be confirmed"
        fi
      else
        log "LID  closed (lockOnLidClose is off)"
      fi
    fi
    _lid_prev=$_lid

    _tick=$((_tick + 1))
    # Sleep in the background so a stop signal is handled at once.
    sleep 3 &
    wait $!
  done
}

# ---------------------------------------------------------------- commands
battery_line() { # "pct src" or none
  case $1 in
    none|'') return 1 ;;
  esac
  _p=${1%% *}
  _s=${1#* }
  if [ "$_s" = battery ]; then
    if [ "$CFG_FLOOR" -gt 0 ]; then
      echo "Battery: ${_p}%, on battery. Lidless turns off at ${CFG_FLOOR}%."
    else
      echo "Battery: ${_p}%, on battery. The battery floor is off."
    fi
  else
    echo "Battery: ${_p}%, plugged in."
  fi
}

setup_reminder() {
  [ "$(os_boot_reset)" = missing ] || return 0
  [ -e "$LD/setup-reminded" ] && return 0
  : > "$LD/setup-reminded"
  say "Tip, shown once: the boot-time reset is not set up yet. Run /lidless-setup to see the one-time command."
}

cmd_on() {
  _sid=
  _spec=
  for _a in "$@"; do
    case $_a in
      sid=*) _sid=${_a#sid=} ;;
      *) _spec="$_spec$_a" ;;
    esac
  done
  case $_sid in *[!A-Za-z0-9_-]*) _sid= ;; esac

  cfg_load
  os_preflight || return 0

  if ! _cpid=$(find_claude); then
    say "Lidless could not find the Claude Code process that ran this command, so it has no session to tie itself to."
    say "Run /lidless from inside Claude Code."
    return 0
  fi
  _cstart=$(proc_start "$_cpid")

  _plus=0
  _secs=
  if [ -n "$_spec" ]; then
    case $_spec in +*) _plus=1; _spec=${_spec#+} ;; esac
    _secs=$(parse_limit "$_spec")
    if [ "$_secs" = bad ]; then
      say "Invalid limit \"$_spec\". Use something like 3h, 90m or 1h30m, or a plain number of hours. Use 0 for no limit."
      return 0
    fi
  fi

  lock
  sweep quick
  _t=$(now)

  # ---- already on for this session: only the limit can change
  if [ -f "$SESS/$_cpid" ]; then
    sess_load "$SESS/$_cpid"
    _new=$S_DEADLINE
    _label=$S_LIMIT
    _msg=
    if [ "$_secs" = none ]; then
      _new=0; _label=none
    elif [ -n "$_secs" ] && [ "$_plus" = 1 ]; then
      if [ "$S_DEADLINE" -gt 0 ]; then
        _new=$((S_DEADLINE + _secs))
        _label="$S_LIMIT + $(fmt_dur "$_secs")"
      else
        _msg="There is no time limit on this session, so there is nothing to extend."
      fi
    elif [ -n "$_secs" ]; then
      _new=$((_t + _secs))
      _label=$(fmt_dur "$_secs")
    fi
    [ -n "$_sid" ] || _sid=$S_SID
    sess_write "$_cpid" "$_cstart" "$_sid" "$S_SINCE" "$_new" "$_label"
    if [ "$_new" != "$S_DEADLINE" ]; then
      rm -f "$RUN/warned.$_cpid"
      if [ "$_new" -gt 0 ]; then
        log "LIMIT session $_cpid: now $(fmt_dur $((_new - _t))) left"
      else
        log "LIMIT session $_cpid: limit removed"
      fi
    fi
    : > "$LD/on"
    ensure_monitor
    unlock
    if [ -n "$_msg" ]; then
      say "$_msg"
    elif [ "$_new" != "$S_DEADLINE" ] && [ "$_new" -gt 0 ]; then
      say "Lidless time limit updated: $(fmt_dur $((_new - _t))) left, until $(fmt_clock "$_new")."
    elif [ "$_new" != "$S_DEADLINE" ]; then
      say "Lidless time limit removed. It stays on until this session ends."
    elif [ "$_new" -gt 0 ]; then
      say "Lidless is already on for this session: $(fmt_dur $((_new - _t))) left, until $(fmt_clock "$_new")."
    else
      say "Lidless is already on for this session, with no time limit."
    fi
    return 0
  fi

  # ---- turning on for this session
  _isfirst=0
  [ "$(count_sessions)" -eq 0 ] && _isfirst=1
  if [ "$_isfirst" = 1 ] && os_dirty; then
    restore_now "leftover state from an earlier run"
  fi
  if ! os_apply; then
    unlock
    say "$OS_ERR"
    return 0
  fi
  if ! os_session_start "$_cpid"; then
    [ "$_isfirst" = 1 ] && os_restore_all
    unlock
    say "$OS_ERR"
    return 0
  fi

  _note=
  if [ -z "$_secs" ]; then
    _secs=$(parse_limit "$CFG_LIMIT")
    if [ "$_secs" = bad ]; then
      _secs=none
      _note="Note: defaultLimit in config.json is not a valid limit, so no limit was set."
    fi
  fi
  _deadline=0
  _label=none
  if [ "$_secs" != none ]; then
    _deadline=$((_t + _secs))
    _label=$(fmt_dur "$_secs")
  fi

  sess_write "$_cpid" "$_cstart" "$_sid" "$_t" "$_deadline" "$_label"
  # This command runs inside a turn, so the session is busy right now.
  [ -n "$_sid" ] && echo busy > "$BUSY/$_sid"
  : > "$LD/on"
  trim_log
  log "ON   session $_cpid: limit $_label"
  ensure_monitor
  _count=$(count_sessions)
  unlock

  say "Lidless is ON for this session."
  if [ "$CFG_LOCK" = true ]; then
    say "Closing the lid will not put the laptop to sleep. The screen locks when the lid closes."
  else
    say "Closing the lid will not put the laptop to sleep. Locking on lid close is switched off in the settings."
  fi
  if [ "$_deadline" -gt 0 ]; then
    say "Time limit: $_label, until $(fmt_clock "$_deadline")."
  else
    say "Time limit: none. It stays on until this session ends."
  fi
  battery_line "$(os_battery)"
  [ "$_count" -gt 1 ] && say "$_count sessions are using Lidless now."
  [ -n "$_note" ] && say "$_note"
  setup_reminder
  return 0
}

cmd_off() {
  _all=0
  for _a in "$@"; do
    case $_a in all|--all|-a) _all=1 ;; esac
  done

  lock
  sweep quick
  _n=$(count_sessions)

  if [ "$_all" = 1 ]; then
    for _pid in $(sess_list); do
      end_session "$_pid" "turned off by the user (all sessions)"
    done
  else
    if ! _cpid=$(find_claude); then
      unlock
      say "Lidless could not find the Claude Code process that ran this command."
      say "To turn it off for every session, run /lidless-off all."
      return 0
    fi
    if [ -f "$SESS/$_cpid" ]; then
      end_session "$_cpid" "turned off by the user"
    elif [ "$_n" -gt 0 ]; then
      unlock
      say "Lidless is not on for this session. $_n other session(s) still have it on."
      say "To turn it off everywhere, run /lidless-off all."
      return 0
    fi
  fi

  _left=$(count_sessions)
  if [ "$_left" -eq 0 ]; then
    restore_now "${LAST_REASON:-turned off by the user}"
    unlock
    if [ "$_n" -gt 0 ]; then
      say "Lidless is OFF. Normal sleep behaviour is back, so closing the lid sleeps the laptop again."
    else
      say "Lidless is already off. Sleep behaviour is normal."
    fi
    if [ -n "$OS_ERR" ]; then say "$OS_ERR"; fi
  else
    unlock
    say "Lidless is off for this session. $_left other session(s) still keep the laptop awake."
    say "To turn it off everywhere, run /lidless-off all."
  fi
  return 0
}

cmd_status() {
  cfg_load
  _t=$(now)
  _cpid=$(find_claude) || _cpid=
  _n=0
  _mine=0
  _others=
  for _pid in $(sess_list); do
    sess_load "$SESS/$_pid"
    proc_alive "$_pid" "$S_START" || continue
    _n=$((_n + 1))
    if [ "$_pid" = "$_cpid" ]; then
      _mine=1
      _my_deadline=$S_DEADLINE
      _my_sid=$S_SID
    fi
  done

  if [ "$_n" -gt 0 ]; then
    if [ "$_n" -eq 1 ]; then say "Lidless: ON (1 session)"; else say "Lidless: ON ($_n sessions)"; fi
  else
    say "Lidless: OFF"
  fi

  if [ "$_mine" = 1 ]; then
    if [ "$_my_deadline" -gt 0 ]; then
      say "This session: on, $(fmt_dur $((_my_deadline - _t))) left (until $(fmt_clock "$_my_deadline"))"
    else
      say "This session: on, no time limit"
    fi
  else
    say "This session: off"
  fi

  _bat=$(os_battery)
  case $_bat in
    none|'') say "Battery: none found" ;;
    *)
      _p=${_bat%% *}
      if [ "${_bat#* }" = battery ]; then _src="on battery"; else _src="plugged in"; fi
      if [ "$CFG_FLOOR" -gt 0 ]; then say "Battery: ${_p}%, $_src (floor ${CFG_FLOOR}%)"; else say "Battery: ${_p}%, $_src (floor off)"; fi
      ;;
  esac

  if [ "$_mine" = 1 ]; then
    busy_state "$_my_sid"
    case $B_STATE in
      idle) say "Claude: idle for $(fmt_dur $((_t - B_SINCE)))" ;;
      waiting) say "Claude: waiting on background work (counts as busy)" ;;
      *) say "Claude: busy" ;;
    esac
  else
    say "Claude: not tracked while Lidless is off here"
  fi

  case $(os_boot_reset) in
    installed) say "Boot reset: installed" ;;
    missing) say "Boot reset: not installed (run /lidless-setup)" ;;
    *) say "Boot reset: not needed on this system" ;;
  esac

  if [ "$CFG_IDLE" -gt 0 ]; then _idle="${CFG_IDLE}m"; else _idle=off; fi
  if [ "$CFG_FLOOR" -gt 0 ]; then _floor="${CFG_FLOOR}%"; else _floor=off; fi
  _dl=$(parse_limit "$CFG_LIMIT")
  case $_dl in none) _dl=none ;; bad) _dl="invalid" ;; *) _dl=$(fmt_dur "$_dl") ;; esac
  if [ "$CFG_LOCK" = true ]; then _lk=on; else _lk=off; fi
  say "Settings: idle off-switch $_idle, battery floor $_floor, default limit $_dl, lock on lid close $_lk"

  if [ -s "$LOG" ]; then
    say "Last event: $(tail -n 1 "$LOG")"
  else
    say "Last event: none yet"
  fi
  return 0
}

# Called at every Claude Code start (SessionStart hook) and after a session ends.
cmd_reconcile() {
  _sid=
  for _a in "$@"; do
    case $_a in sid=*) _sid=${_a#sid=} ;; esac
  done
  case $_sid in *[!A-Za-z0-9_-]*) _sid= ;; esac

  lock
  sweep quick
  if [ "$(count_sessions)" -eq 0 ]; then
    restore_now "${LAST_REASON:-leftover state from an earlier run}"
  else
    # /clear and /resume start a new conversation inside the same Claude
    # process. Follow the new session id so busy and idle keep working.
    if [ -n "$_sid" ] && _cpid=$(find_claude) && [ -f "$SESS/$_cpid" ]; then
      sess_load "$SESS/$_cpid"
      if [ "$S_SID" != "$_sid" ]; then
        [ -n "$S_SID" ] && rm -f "$BUSY/$S_SID"
        sess_write "$_cpid" "$S_START" "$_sid" "$S_SINCE" "$S_DEADLINE" "$S_LIMIT"
        [ -f "$BUSY/$_sid" ] || echo idle > "$BUSY/$_sid"
      fi
    fi
    : > "$LD/on"
    ensure_monitor
  fi
  unlock
  return 0
}

usage() {
  say "Lidless commands: /lidless [limit], /lidless-off, /lidless-status, /lidless-setup"
}

main() {
  ensure_dirs
  case $cmd in
    on) shift; cmd_on "$@" ;;
    off) shift; cmd_off "$@" ;;
    status) cmd_status ;;
    setup) shift; os_setup "$@" ;;
    reconcile) shift; cmd_reconcile "$@" > /dev/null 2>&1 ;;
    monitor) monitor_main ;;
    *) usage ;;
  esac
}
