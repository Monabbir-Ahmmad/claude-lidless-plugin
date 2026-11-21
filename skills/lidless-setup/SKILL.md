---
name: lidless-setup
description: Print the one-time command that installs the Lidless boot-time reset (administrator on Windows, sudo on macOS, nothing on Linux). The user runs that command themselves. Works only in Claude Code running on the laptop itself.
argument-hint: "[remove]"
disable-model-invocation: true
allowed-tools: 'Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" *)'
---

Lidless setup information for this computer:

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" setup $ARGUMENTS`

Show the user this text as it is. Put any command it contains in a code block, exactly as written, so it can be copied. Do not run that command yourself: it needs administrator or sudo rights and the user wants to run it by hand.

If there is no setup information above, this is not Claude Code running on the user's own laptop. Say that Lidless only works there, and do nothing else.
