# Lidless: macOS. Sourced by lidless.sh after common.sh.
#
# "pmset -a disablesleep 1" is the switch that stops lid-close sleep. It needs
# root, so the one-time setup adds a sudo rule for exactly that command.
# caffeinate -i -w <claude pid> covers idle sleep and ends with Claude Code.

PMSET=${LIDLESS_PMSET:-/usr/bin/pmset}
MAC_PLIST=/Library/LaunchDaemons/com.tajbir.lidless.reset.plist

os_preflight() {
  if [ ! -x "$PMSET" ]; then
    say "Lidless needs /usr/bin/pmset on macOS, and it was not found."
    return 1
  fi
  return 0
}

sleep_disabled() {
  [ "$("$PMSET" -g 2>/dev/null | awk '/SleepDisabled/ { print $2; exit }')" = 1 ]
}

mac_sudo_help="macOS needs a one-time setup before Lidless can work: the sudo rule that lets it run \"pmset -a disablesleep\" without a password is missing. Run /lidless-setup to see the command."

os_apply() {
  if [ -e "$STATE/macos" ] && sleep_disabled; then
    return 0
  fi
  # Remember whether sleep was already disabled before Lidless touched it.
  _prior=0
  sleep_disabled && _prior=1
  if ! sudo -n "$PMSET" -a disablesleep 1 > /dev/null 2>&1; then
    OS_ERR=$mac_sudo_help
    return 1
  fi
  # Read the flag back to be sure it took effect.
  if ! sleep_disabled; then
    sudo -n "$PMSET" -a disablesleep 0 > /dev/null 2>&1
    OS_ERR="macOS accepted the command but lid-close sleep is still enabled (pmset -g does not show SleepDisabled 1), so Lidless did not turn on."
    return 1
  fi
  [ -e "$STATE/macos" ] || echo "$_prior" > "$STATE/macos"
  return 0
}

mac_caffeinate_ok() { # claude pid
  [ -f "$RUN/caffeinate.$1.pid" ] || return 1
  _cfp=
  read -r _cfp < "$RUN/caffeinate.$1.pid"
  is_uint "$_cfp" || return 1
  case "$(ps -o comm= -p "$_cfp" 2>/dev/null)" in
    *caffeinate*) return 0 ;;
  esac
  return 1
}

os_session_start() { # claude pid
  mac_caffeinate_ok "$1" && return 0
  ( trap '' HUP; exec caffeinate -i -w "$1" ) < /dev/null > /dev/null 2>&1 &
  echo "$!" > "$RUN/caffeinate.$1.pid"
  return 0
}

os_session_stop() { # claude pid
  if mac_caffeinate_ok "$1"; then
    kill -TERM "$_cfp" 2>/dev/null
  fi
  rm -f "$RUN/caffeinate.$1.pid"
  return 0
}

os_restore_all() {
  for _cf in "$RUN"/caffeinate.*.pid; do
    [ -f "$_cf" ] || continue
    _cpn=${_cf##*/caffeinate.}
    _cpn=${_cpn%.pid}
    os_session_stop "$_cpn"
  done
  [ -e "$STATE/macos" ] || return 0
  _prior=0
  read -r _prior < "$STATE/macos"
  if [ "$_prior" = 1 ]; then
    # Sleep was already disabled before Lidless came along. Leave it that way.
    rm -f "$STATE/macos"
    return 0
  fi
  if ! sudo -n "$PMSET" -a disablesleep 0 > /dev/null 2>&1; then
    OS_ERR="Lidless could not switch lid-close sleep back on, because the sudo rule is missing. Run this yourself: sudo pmset -a disablesleep 0"
    return 1
  fi
  if sleep_disabled; then
    OS_ERR="macOS still reports SleepDisabled 1 after the reset. Run this yourself: sudo pmset -a disablesleep 0"
    return 1
  fi
  rm -f "$STATE/macos"
  return 0
}

os_dirty() {
  [ -e "$STATE/macos" ] && return 0
  for _cf in "$RUN"/caffeinate.*.pid; do
    [ -f "$_cf" ] && return 0
  done
  return 1
}

# Every 30 seconds or so, check that nothing else switched lid-close sleep back on.
os_tick() {
  for _sp in $(sess_list); do
    mac_caffeinate_ok "$_sp" || os_session_start "$_sp"
  done
  [ $(($1 % 10)) -eq 0 ] || return 0
  sleep_disabled && return 0
  if sudo -n "$PMSET" -a disablesleep 1 > /dev/null 2>&1 && sleep_disabled; then
    log "NOTE lid-close sleep had been switched back on by something else and was disabled again"
  else
    log "NOTE lid-close sleep was switched back on by something else and could not be disabled again"
  fi
}

os_lid() {
  case "$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep '"AppleClamshellState"')" in
    *Yes*) echo closed ;;
    *No*) echo open ;;
    *) echo unknown ;;
  esac
}

screen_locked() {
  ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked
}

# macOS only locks on lid close by itself when it is set to ask for the
# password right after the display turns off. So lock it explicitly.
os_lock_screen() {
  # 1. The same call the "Lock Screen" menu item makes.
  osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/login.framework").load; ObjC.bindFunction("SACLockScreenImmediate", ["int", []]); $.SACLockScreenImmediate();' > /dev/null 2>&1
  sleep 1
  screen_locked && return 0
  # 2. Turn the display off, which locks when the password is required immediately.
  "$PMSET" displaysleepnow > /dev/null 2>&1
  sleep 2
  screen_locked
}

os_battery() {
  _out=$("$PMSET" -g batt 2>/dev/null)
  _pct=$(printf '%s\n' "$_out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%;.*/\1/p' | head -n 1)
  if ! is_uint "$_pct"; then
    echo none
    return
  fi
  case $_out in
    *"'Battery Power'"*) echo "$_pct battery" ;;
    *) echo "$_pct ac" ;;
  esac
}

mac_sudo_ok() {
  sudo -n -l "$PMSET" -a disablesleep 1 > /dev/null 2>&1 && sudo -n -l "$PMSET" -a disablesleep 0 > /dev/null 2>&1
}

os_boot_reset() {
  if [ -f "$MAC_PLIST" ]; then echo installed; else echo missing; fi
}

os_shutdown_check() {
  command -v osascript > /dev/null 2>&1 && return 0
  OS_ERR="Lidless shuts macOS down with the osascript command, and it was not found. Nothing was changed."
  return 1
}

# The same request the Apple menu makes. It needs no password. The first time,
# macOS asks whether the terminal may control System Events.
os_poweroff() {
  osascript -e 'tell application "System Events" to shut down' > /dev/null 2>&1 && return 0
  OS_ERR="macOS did not accept the shut down request. The first time, macOS asks whether your terminal may control System Events, and that has to be allowed at the laptop."
  return 1
}

os_setup() {
  _script=$(cd "$DIR" 2>/dev/null && pwd)/macos-setup.sh
  case ${1:-} in
    remove|uninstall)
      say "To remove the Lidless setup from macOS, run this in Terminal:"
      say ""
      say "  sudo sh \"$_script\" remove"
      return 0
      ;;
  esac
  _rule=missing
  mac_sudo_ok && _rule=installed
  _boot=$(os_boot_reset)
  if [ "$_rule" = installed ] && [ "$_boot" = installed ]; then
    say "Lidless setup is already done on this Mac (sudo rule and boot-time reset are both installed)."
    say "To remove it later: sudo sh \"$_script\" remove"
    return 0
  fi
  say "Sudo rule: $_rule. Boot-time reset: $_boot."
  say "Run this once in Terminal. It asks for your password:"
  say ""
  say "  sudo sh \"$_script\""
  say ""
  say "It adds two things:"
  say "1. A sudo rule that lets your account run only \"pmset -a disablesleep 0\" and \"pmset -a disablesleep 1\" without a password."
  say "2. A LaunchDaemon that runs \"pmset -a disablesleep 0\" at every boot, so sleep is back to normal before you log in."
}
