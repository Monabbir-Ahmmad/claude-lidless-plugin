#!/bin/sh
# Lidless SessionStart hook.
#
# Does nothing unless Lidless left something behind. If it did (a crash, a
# power cut, a killed terminal), this puts normal sleep behaviour back when
# no session that uses Lidless is alive any more. It also follows a /clear or
# /resume inside a session that has Lidless on.
#
# It prints nothing: whatever a SessionStart hook prints is added to Claude's context.

LD=${LIDLESS_HOME:-$HOME/.claude/lidless}
[ -d "$LD" ] || exit 0

# Version 1.0.0 kept copies of its scripts in the state folder. They are not used any more.
if [ -e "$LD/VERSION" ]; then
  rm -f "$LD/VERSION" "$LD/lidless.sh" "$LD/common.sh" "$LD/linux.sh" "$LD/macos.sh" \
    "$LD/macos-setup.sh" "$LD/lidless.ps1" "$LD/boot-reset.ps1" 2>/dev/null
fi

need=0
[ -e "$LD/on" ] && need=1
if [ "$need" = 0 ]; then
  for f in "$LD"/sessions/* "$LD"/state/* "$LD"/run/inhibit.*.pid "$LD"/run/caffeinate.*.pid; do
    if [ -e "$f" ]; then need=1; break; fi
  done
fi
[ "$need" = 1 ] || exit 0

# The new session id, so a /clear or /resume inside a running session is followed.
input=$(head -c 4096)
sid=
case $input in
  *'"session_id"'*)
    sid=${input#*'"session_id"'}
    sid=${sid#*\"}
    sid=${sid%%\"*}
    ;;
esac
case $sid in *[!A-Za-z0-9_-]*) sid= ;; esac

DIR=${0%/*}
[ "$DIR" = "$0" ] && DIR=.
exec sh "$DIR/lidless.sh" reconcile "sid=$sid" > /dev/null 2>&1
