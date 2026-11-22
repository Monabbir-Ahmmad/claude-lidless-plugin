# Lidless: Linux. Sourced by lidless.sh after common.sh.
#
# A systemd-inhibit lock (sleep + handle-lid-switch) is held by a small helper
# that lives exactly as long as the Claude Code process. The lock is a running
# process, not a setting, so nothing is left behind after a crash or a reboot.

PS_DIR=${LIDLESS_SYSFS:-/sys/class/power_supply}
LID_DIR=${LIDLESS_LID:-/proc/acpi/button/lid}

os_preflight() {
  if ! command -v systemd-inhibit > /dev/null 2>&1; then
    say "Lidless needs systemd on Linux (the systemd-inhibit command), and this system does not have it."
    return 1
  fi
  if ! tail --help 2>&1 | grep -q -- '--pid'; then
    say "Lidless needs GNU tail (tail --pid) on Linux, and the tail on this system does not support it."
    return 1
  fi
  return 0
}

# Nothing machine wide to switch on Linux. Each session holds its own lock.
os_apply() { return 0; }

inhibitor_running() { # claude pid
  [ -f "$RUN/inhibit.$1.pid" ] || return 1
  _ip=
  read -r _ip < "$RUN/inhibit.$1.pid"
  is_uint "$_ip" || return 1
  case "$(ps -o args= -p "$_ip" 2>/dev/null)" in
    *systemd-inhibit*) return 0 ;;
  esac
  return 1
}

os_session_start() { # claude pid
  inhibitor_running "$1" && return 0
  _err=$RUN/inhibit.$1.err
  _noask=
  systemd-inhibit --help 2>/dev/null | grep -q -- '--no-ask-password' && _noask=--no-ask-password

  # tail --pid exits when Claude Code exits, and the lock goes with it.
  if command -v setsid > /dev/null 2>&1; then
    setsid systemd-inhibit $_noask --what=sleep:handle-lid-switch --mode=block \
      --who=Lidless --why="Claude Code session $1 is in use remotely" \
      tail --pid="$1" -f /dev/null < /dev/null > "$_err" 2>&1 &
  else
    systemd-inhibit $_noask --what=sleep:handle-lid-switch --mode=block \
      --who=Lidless --why="Claude Code session $1 is in use remotely" \
      tail --pid="$1" -f /dev/null < /dev/null > "$_err" 2>&1 &
  fi
  _ip=$!

  # logind answers at once: either the lock is held, or the helper has already quit.
  _w=0
  while [ "$_w" -lt 10 ]; do
    kill -0 "$_ip" 2>/dev/null || break
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done
  if ! kill -0 "$_ip" 2>/dev/null; then
    _why=
    [ -s "$_err" ] && _why=$(head -n 1 "$_err")
    rm -f "$_err"
    OS_ERR="Linux refused the sleep lock${_why:+ ($_why)}. This usually happens when Claude Code runs over SSH or outside the laptop's own desktop login, because only the active local session may block lid-close sleep. Start Claude Code in a terminal on the laptop itself, then connect from your phone with Remote Control."
    return 1
  fi
  echo "$_ip" > "$RUN/inhibit.$1.pid"

  # Remember the desktop login session, so the lock command reaches the right screen.
  case ${XDG_SESSION_ID:-} in
    ''|*[!A-Za-z0-9_-]*) ;;
    *) echo "$XDG_SESSION_ID" > "$RUN/logind-session" ;;
  esac
  return 0
}

os_session_stop() { # claude pid
  _pf=$RUN/inhibit.$1.pid
  if [ -f "$_pf" ]; then
    _ip=
    read -r _ip < "$_pf"
    if is_uint "$_ip"; then
      case "$(ps -o args= -p "$_ip" 2>/dev/null)" in
        *systemd-inhibit*)
          # Stopping the tail child makes systemd-inhibit exit and release the lock.
          pkill -TERM -P "$_ip" 2>/dev/null
          kill -TERM "$_ip" 2>/dev/null
          ;;
      esac
    fi
  fi
  rm -f "$_pf" "$RUN/inhibit.$1.err"
  return 0
}

os_restore_all() {
  for _pf2 in "$RUN"/inhibit.*.pid; do
    [ -f "$_pf2" ] || continue
    _cp=${_pf2##*/inhibit.}
    _cp=${_cp%.pid}
    os_session_stop "$_cp"
  done
  rm -f "$RUN/logind-session"
  return 0
}

os_dirty() {
  for _pf2 in "$RUN"/inhibit.*.pid; do
    [ -f "$_pf2" ] && return 0
  done
  return 1
}

# Make sure every session still holds its lock. If something killed the helper, put it back.
os_tick() {
  for _sp in $(sess_list); do
    inhibitor_running "$_sp" && continue
    if os_session_start "$_sp"; then
      log "NOTE the sleep lock for session $_sp had gone and was put back"
    else
      end_session "$_sp" "the sleep lock was lost and Linux would not give it back"
    fi
  done
}

os_lid() {
  for _lf in "$LID_DIR"/*/state; do
    [ -r "$_lf" ] || continue
    _ll=
    read -r _ll < "$_lf"
    case $_ll in
      *closed*) echo closed; return ;;
      *open*) echo open; return ;;
    esac
  done
  echo unknown
}

os_lock_screen() {
  _ls=
  [ -r "$RUN/logind-session" ] && read -r _ls < "$RUN/logind-session"
  case $_ls in *[!A-Za-z0-9_-]*) _ls= ;; esac
  if [ -n "$_ls" ] && loginctl lock-session "$_ls" 2>/dev/null; then return 0; fi
  loginctl lock-session 2>/dev/null && return 0
  loginctl lock-sessions 2>/dev/null
}

os_battery() {
  _pct=
  _status=
  _mains=0
  _online=0
  for _d in "$PS_DIR"/*; do
    [ -r "$_d/type" ] || continue
    _ty=
    read -r _ty < "$_d/type"
    case $_ty in
      Battery)
        # Skip batteries of mice, keyboards and the like.
        if [ -r "$_d/scope" ]; then
          _sc=
          read -r _sc < "$_d/scope"
          [ "$_sc" = Device ] && continue
        fi
        if [ -z "$_pct" ] && [ -r "$_d/capacity" ]; then
          read -r _pct < "$_d/capacity"
          [ -r "$_d/status" ] && read -r _status < "$_d/status"
        fi
        ;;
      Mains|USB*)
        if [ -r "$_d/online" ]; then
          _mains=1
          _on=0
          read -r _on < "$_d/online"
          [ "$_on" = 1 ] && _online=1
        fi
        ;;
    esac
  done
  if ! is_uint "$_pct"; then
    echo none
    return
  fi
  if [ "$_status" = Discharging ]; then
    echo "$_pct battery"
  elif [ "$_mains" = 1 ] && [ "$_online" = 0 ] && [ "$_status" != Charging ] && [ "$_status" != Full ]; then
    echo "$_pct battery"
  else
    echo "$_pct ac"
  fi
}

os_boot_reset() { echo notneeded; }

os_shutdown_check() {
  command -v systemctl > /dev/null 2>&1 && return 0
  OS_ERR="Lidless shuts Linux down with the systemctl command, and this system does not have it. Nothing was changed."
  return 1
}

# logind lets the active local login power the computer off without a password.
os_poweroff() {
  systemctl poweroff --no-ask-password > /dev/null 2>&1 && return 0
  OS_ERR="systemctl poweroff was refused. Linux refuses when another user is logged in, or when Claude Code does not run in the laptop's own desktop login."
  return 1
}

os_setup() {
  say "No setup is needed on Linux."
  say "Lidless holds its sleep lock inside a running helper process, so a restart, a shutdown or a crash always clears it by itself."
}
