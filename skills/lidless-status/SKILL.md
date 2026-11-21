---
name: lidless-status
description: Show whether Lidless is on, how many sessions use it, the time left, battery, busy or idle, the boot-time reset, the settings and the last logged event. Works only in Claude Code running on the laptop itself.
disable-model-invocation: true
allowed-tools: 'Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" *)'
---

Current Lidless status:

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" status`

Show the user these lines as they are, in one code block, with nothing added before or after. The user is probably reading on a phone. Do not run any command.

If there are no status lines above, this is not Claude Code running on the user's own laptop. Say that Lidless only works there, and do nothing else.
