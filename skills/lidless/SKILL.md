---
name: lidless
description: Keep this laptop awake and online with the lid closed for the current Claude Code session, so Remote Control keeps working. Takes an optional time limit such as 3h, 90m or 1h30m. Works only in Claude Code running on the laptop itself.
argument-hint: "[limit]"
disable-model-invocation: true
allowed-tools: 'Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" *)'
---

Lidless was asked to turn on, or to change its time limit. This is what it reported:

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" on sid=${CLAUDE_SESSION_ID} $ARGUMENTS`

Pass this report on to the user in a short reply. Keep every fact, time and command it mentions. Do not run any command and do not add advice of your own.

If there is no report above, this is not Claude Code running on the user's own laptop. Say that Lidless only works there, and do nothing else.
