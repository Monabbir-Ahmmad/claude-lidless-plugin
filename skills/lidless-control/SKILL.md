---
name: lidless-control
description: Control Lidless, the plugin that keeps the user's laptop awake with the lid closed while they work from their phone over Claude Code Remote Control. Use only in Claude Code running on the user's own laptop, when the user asks in plain words to keep the laptop or PC awake, stay awake longer, add time, change or remove the keep-awake time limit, turn Lidless on or off, let the laptop sleep again, or asks how long is left or whether Lidless is on. Also use it to act on a "Lidless notice" in the conversation, or to change a Lidless setting.
user-invocable: false
allowed-tools: 'Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" *)'
---

# Lidless control

Lidless keeps the user's laptop awake and online with the lid closed, so a Remote Control session from their phone keeps working. It is only on while the user asks for it. The user is usually away from the laptop and reading on a phone, so keep replies short.

## Where this works

Lidless controls the computer that Claude Code itself runs on. It works in Claude Code on the user's own Windows, Linux or macOS laptop. It does nothing useful in a chat on claude.ai, in a cloud session, or in a sandbox or virtual machine, because the lid and the power settings belong to a different computer there. If you are not running in Claude Code on the user's own laptop, do not run anything. Tell the user in one sentence that Lidless only works from Claude Code on the laptop.

## Commands

Everything goes through one script. Run it with the Bash tool, then tell the user what it printed. The script always explains itself in plain words, including when something is wrong, so pass its message on instead of guessing.

| The user wants | Run |
| --- | --- |
| Turn it on, no limit given | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" on sid=${CLAUDE_SESSION_ID}` |
| Turn it on for a while, or set a new limit counted from now ("keep the laptop awake 2 more hours", "stay awake until I am back in 90 minutes") | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" on sid=${CLAUDE_SESSION_ID} 2h` |
| Add time on top of what is left ("add 30 minutes", "extend it by an hour") | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" on sid=${CLAUDE_SESSION_ID} +30m` |
| Remove the limit ("no limit", "keep it on until I say stop") | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" on sid=${CLAUDE_SESSION_ID} 0` |
| Turn it off for this session ("turn lidless off", "let it sleep") | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" off` |
| Turn it off for every session | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" off all` |
| Status ("how long is left?", "is lidless on?", "how is the battery?") | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" status` |
| The one-time setup command | `sh "${CLAUDE_PLUGIN_ROOT}/scripts/lidless.sh" setup` |

Copy the command exactly as it is written in the table, including the quotes, and only change the limit at the end.

Limits look like `3h`, `90m`, `1h30m`, or a bare number, which means hours. Turn the user's words into one of these. "Two and a half hours" is `2h30m`. If the user gives a clock time such as "until 6 pm", work out the minutes from now and use that.

## Rules

- Always run the script. Never tell the user that Lidless is on, off or extended without having run it in this turn and read its answer.
- Only act when the user asks. Do not turn Lidless on, extend it or change a setting on your own initiative.
- Do not change power settings yourself (`powercfg`, `pmset`, `systemd-inhibit`, `caffeinate`). Lidless tracks what it changed so it can put it back, and changes made around it break that.
- Do not run the setup command that `setup` prints. It needs administrator or sudo rights and the user runs it by hand at the laptop. Show it in a code block instead.
- Lidless never puts the laptop to sleep and never shuts it down. Turning it off only gives the laptop its normal behaviour back. If the user wants the laptop to sleep right now, say that turning Lidless off is the way, and that with the lid closed the laptop then sleeps by its own rules.
- Lidless is per session. Another Claude Code session on the same laptop can keep it awake after this one turns it off. The script says so when that is the case.

## Lidless notices

Sometimes a line starting with "Lidless notice" is added to the conversation when the user sends a message. It means an automatic turn-off is close: the time limit ends within 15 minutes, or the battery is within 5% of the floor. Tell the user at the start of the reply, in one or two sentences, with the number from the notice and how to extend: send `/lidless 2h` or just ask for more time. For battery, the fix is to plug in the charger. Then carry on with what they asked. Do not extend the limit yourself unless the user asks.

## Settings

Settings live in `~/.claude/lidless/config.json`. If the user asks to change one, edit that file and keep the other keys as they are. Changes apply within a few seconds, no restart needed.

- `idleMinutes`: turn off when Claude has finished and nothing has happened for this many minutes. `0` means never, which is the default, because the user is away on purpose.
- `batteryFloor`: turn off at or below this battery percentage when running on battery. Default `20`. `0` or `false` disables it.
- `defaultLimit`: the limit used when `/lidless` is run without one, for example `"4h"`. `0` means no limit.
- `lockOnLidClose`: lock the screen when the lid closes. Default `true`.

If the user lowers `batteryFloor` or disables it, mention once that a laptop left running in a closed bag can drain its battery completely.
