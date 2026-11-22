---
name: lidless-shutdown
description: Shut this laptop down from Claude Code, for example from a phone over Remote Control when the work is done. Turns Lidless off for every session and powers the computer off after 60 seconds. Use "cancel" to stop a shutdown that is waiting. Works only in Claude Code running on the laptop itself.
argument-hint: "[cancel]"
disable-model-invocation: true
allowed-tools: 'Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" *)'
---

The user typed the Lidless shutdown command. This is what it reported:

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" shutdown $ARGUMENTS`

Pass this report on to the user in a short reply. Keep every fact, time and command it mentions. Do not run any command and do not add advice of your own.

If there is no report above, this is not Claude Code running on the user's own laptop. Say that Lidless only works there, and do nothing else.
