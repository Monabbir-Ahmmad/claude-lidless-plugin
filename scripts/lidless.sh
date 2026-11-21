#!/bin/sh
# Lidless entry script for the commands.
#
#   lidless.sh on [limit]     turn on for this Claude Code session, or change the limit
#   lidless.sh off [all]      turn off for this session (or for every session)
#   lidless.sh status         short status
#   lidless.sh setup          show the one-time setup command for this OS
#   lidless.sh reconcile      tidy up after sessions that ended (session start and end hooks)
#   lidless.sh monitor        background watcher (started by "on")
#
# The scripts run from the plugin folder. Everything Lidless remembers
# (settings, sessions, log) lives in ~/.claude/lidless.
# Plain POSIX sh: on Windows this runs under Git Bash, on macOS under /bin/sh.

LD=${LIDLESS_HOME:-$HOME/.claude/lidless}
cmd=${1:-status}

DIR=${0%/*}
[ "$DIR" = "$0" ] && DIR=.

quiet=0
case $cmd in reconcile|monitor) quiet=1 ;; esac

os=${LIDLESS_OS:-$(uname -s 2>/dev/null)}
case $os in
  Linux*)
    if [ -z "$LIDLESS_OS" ] && grep -qi microsoft /proc/version 2>/dev/null; then
      [ "$quiet" = 1 ] || echo "Lidless cannot work from inside WSL, because Windows owns the lid and the power settings. Run Claude Code directly on Windows (with Git Bash) to use it."
      exit 0
    fi
    . "$DIR/common.sh"
    . "$DIR/linux.sh"
    ;;
  Darwin*)
    . "$DIR/common.sh"
    . "$DIR/macos.sh"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    ps1=$DIR/lidless.ps1
    home=$LD
    if command -v cygpath > /dev/null 2>&1; then
      ps1=$(cygpath -w "$ps1")
      home=$(cygpath -w "$LD")
      # Both paths are Windows paths now, so stop Git Bash from rewriting arguments.
      MSYS_NO_PATHCONV=1
      MSYS2_ARG_CONV_EXCL='*'
      export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
    fi
    psexe=powershell.exe
    command -v powershell.exe > /dev/null 2>&1 || psexe="${SYSTEMROOT:-C:/Windows}/System32/WindowsPowerShell/v1.0/powershell.exe"
    "$psexe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" "home=$home" "$@" < /dev/null
    exit 0
    ;;
  *)
    [ "$quiet" = 1 ] || echo "Lidless does not support this system (${os:-unknown}). It works on Windows, Linux and macOS."
    exit 0
    ;;
esac

main "$@"
exit 0
