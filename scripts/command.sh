#!/bin/sh
# Lidless: answers the Lidless slash commands without a model turn.
#
# UserPromptExpansion hook. When the user types /lidless, /lidless-off,
# /lidless-status or /lidless-setup, this runs the command straight away,
# shows what it reported and stops the prompt there. The answer is on screen
# in about a second, instead of after Claude has written a reply.
#
# Whenever something looks unusual (another command, unexpected characters in
# the arguments, no report), it prints nothing and exits 0. The command then
# runs the normal way, through its skill. The same happens on a Claude Code
# version that does not know this hook.
#
# What it reads from the hook input: the command name, its arguments and the
# session id. It stores none of it.
#
# Plain POSIX sh: on Windows this runs under Git Bash, on macOS under /bin/sh.

input=$(head -c 8192)

# jget KEY: put the string value of the first "KEY" in $input into JV.
jget() {
  JV=
  case $input in *"\"$1\""*) ;; *) return 1 ;; esac
  JV=${input#*"\"$1\""}
  JV=${JV#*\"}
  JV=${JV%%\"*}
}

jget command_name || exit 0
case ${JV#lidless:} in
  lidless) sub=on ;;
  lidless-off) sub=off ;;
  lidless-status) sub=status ;;
  lidless-setup) sub=setup ;;
  *) exit 0 ;;
esac

# The arguments are a time limit, "all" or "remove". Anything else goes to the skill.
jget command_args
args=$JV
case $args in *[!A-Za-z0-9+:.\ -]*) exit 0 ;; esac

jget session_id
sid=$JV
case $sid in *[!A-Za-z0-9_-]*) sid= ;; esac

DIR=${0%/*}
[ "$DIR" = "$0" ] && DIR=.
LD=${LIDLESS_HOME:-$HOME/.claude/lidless}

# "on" marks a new session busy, because it normally runs inside a turn.
# Here no turn follows, so nothing would ever mark it idle again.
mark=
if [ "$sub" = on ] && [ -n "$sid" ] && [ ! -e "$LD/busy/$sid" ]; then mark=$LD/busy/$sid; fi

set -f
case $sub in
  on) out=$(sh "$DIR/lidless.sh" on "sid=$sid" $args 2>/dev/null) ;;
  status) out=$(sh "$DIR/lidless.sh" status 2>/dev/null) ;;
  *) out=$(sh "$DIR/lidless.sh" "$sub" $args 2>/dev/null) ;;
esac
set +f
[ -n "$out" ] || exit 0

if [ -n "$mark" ] && [ -e "$mark" ]; then echo idle > "$mark" 2>/dev/null; fi

# The report goes back as the reason of a blocked prompt, which Claude Code
# shows to the user as it is.
esc=$(printf '%s\n' "$out" | tr -d '\r' | tr '\t' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')
printf '{"decision":"block","reason":"%s"}\n' "$esc"
exit 0
