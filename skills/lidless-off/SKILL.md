---
name: lidless-off
description: Turn Lidless off for the current Claude Code session, so the laptop sleeps normally again once no other session needs it. Use "all" to turn it off for every session. Works only in Claude Code running on the laptop itself.
argument-hint: "[all]"
disable-model-invocation: true
allowed-tools: 'Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" *)'
---

Lidless was asked to turn off. This is what it reported:

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" off $ARGUMENTS`

Pass this report on to the user in a short reply. Keep every fact and command it mentions. Do not run any command and do not add advice of your own.

If there is no report above, this is not Claude Code running on the user's own laptop. Say that Lidless only works there, and do nothing else.
