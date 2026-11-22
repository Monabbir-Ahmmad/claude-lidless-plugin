# Lidless

Lidless keeps your laptop awake and online with the lid closed, but only while you ask for it. Close the laptop, put it in your bag, and keep working with Claude Code from your phone through Remote Control. When the session ends, everything goes back to normal by itself.

It is a Claude Code plugin for Windows, Linux and macOS. It makes no network connections and collects nothing.

**Status: early release.** See "What has been tested" before you rely on it.

## Read this first: heat and battery

A laptop that stays awake inside a closed bag has nowhere to send its heat. It can get very hot, and it drains its battery much faster than you expect.

- Do not leave it running in a bag while Claude is doing heavy work such as builds, tests or anything that spins the fans.
- Give it air if you can: an open pocket, or outside the sleeve.
- Set a time limit (`/lidless 2h`) instead of leaving it on with none.
- Keep the battery floor on. It is 20% by default.
- Laptops with a hot dedicated graphics card are the riskiest.

Lidless has three safety nets (time limit, battery floor, session end), but none of them measures temperature. You decide whether the bag is safe.

## Where it works

Lidless controls the computer that Claude Code itself runs on. Use it in Claude Code on your own laptop: the terminal, an IDE extension, or the Code tab of the desktop app.

It does nothing in a chat on claude.ai, in a cloud session, or in a sandbox or virtual machine, because the lid and the power settings belong to a different computer there. Its commands say so and leave everything alone.

Requirements:

- Windows: Git for Windows, because Claude Code runs the plugin's hooks and commands through Git Bash. Windows PowerShell 5.1, which Windows includes.
- Linux: systemd, and a desktop that listens to logind for locking (GNOME and KDE do). Not inside WSL.
- macOS: the one-time setup described below.

## Install

Inside Claude Code:

```
/plugin install lidless --marketplace Monabbir-Ahmmad/claude-lidless-plugin
```

Or from a terminal:

```
claude plugin marketplace add Monabbir-Ahmmad/claude-lidless-plugin
claude plugin install lidless@tajbir-tools
```

If you added Lidless from the directory on claude.ai instead, Claude Code loads it by itself at the next start.

Then start Claude Code again and run `/lidless-setup` once.

## One-time setup

`/lidless-setup` prints one command for you to run yourself. Lidless never runs it for you.

| System | What the setup does | Needed? |
| --- | --- | --- |
| Windows | Adds a Task Scheduler task that runs at startup as SYSTEM and puts your sleep settings back if Lidless was on when the PC went down. Run the printed command in an administrator PowerShell. | Optional. Without it, the reset happens at logon and at the next Claude Code start instead. `/lidless` reminds you once. |
| macOS | Adds a sudo rule that allows only `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password, and a LaunchDaemon that runs `pmset -a disablesleep 0` at every boot. Run the printed command with sudo in Terminal. | Required. macOS will not let Lidless block lid-close sleep without it. |
| Linux | Nothing. | No setup needed. |

To undo the setup later, run `/lidless-setup remove` on macOS, or `/lidless-setup` on Windows, which prints the removal command once the task is installed.

## Use

| Command | What it does |
| --- | --- |
| `/lidless` | Turn on for this session. Lid close no longer sleeps the laptop. The screen still turns off, and it locks the moment the lid closes. |
| `/lidless 3h` | Turn on with a time limit, or change the limit if it is already on. `90m`, `1h30m`, `1:30` and a bare number (hours) all work. `+30m` adds to the time that is left. `0` removes the limit. |
| `/lidless-off` | Turn off for this session. `/lidless-off all` turns it off for every session. |
| `/lidless-status` | A few short lines: on or off, session count, time left, battery, busy or idle, boot reset, settings, last logged event. |
| `/lidless-setup` | Print the one-time setup command. |

If another plugin uses one of these names, the long form always works, for example `/lidless:lidless-off`.

A typed command is answered at once, in about a second, without waiting for Claude to write a reply. Claude Code shows such an answer as a stopped prompt, so it begins with the line "UserPromptExpansion operation blocked by hook:" and ends with the command you typed. That wording comes from Claude Code and is expected. Nothing went wrong.

### Examples

Three things to try, as commands or in plain words from your phone:

1. "Keep the laptop awake for 2 hours." Claude runs Lidless with a 2 hour limit and tells you when it ends.
2. "How long is left, and how is the battery?" Claude shows the status lines.
3. "Turn lidless off." The laptop goes back to its normal sleep behaviour.

A typical trip: start Claude Code on the laptop, start Remote Control, run `/lidless 2h`, close the lid, go. From the phone, ask for more time when you need it.

## When it turns itself off

Turning off only gives the laptop its normal behaviour back. Lidless never puts the laptop to sleep and never shuts it down.

- **The session ends.** Exit, a closed terminal, a killed Claude Code, a crash. A small background watcher notices within a few seconds. `/clear` does not turn it off.
- **Restart or shutdown.** Always resets. See "How it works" for what guarantees that on each system.
- **The time limit runs out.**
- **The battery reaches the floor.** On battery at or below `batteryFloor` (20% by default). Plugged in, the floor does not apply.
- **Idle, if you switch it on.** With `idleMinutes` above 0, it turns off once Claude has finished and nothing has happened for that long. It is off by default, because you are away on purpose and it would cut your phone session.

Several Claude Code sessions can have Lidless on at once. Each one ends on its own, and normal behaviour comes back when the last one ends.

**Before an automatic turn-off, you get a warning.** When you send a message and the time limit is under 15 minutes away, or the battery is within 5% of the floor, Claude tells you in its reply and says how to extend. The warning repeats at most every 5 minutes.

**What counts as idle.** Only a finished turn with nothing left running. A pending permission prompt is not idle. Background shells, background subagents and scheduled wake-ups such as `/loop` are not idle either. If you stop Claude with Esc, that session counts as busy until your next message finishes, because Claude Code does not report an interrupted turn.

## Settings

Settings live in `~/.claude/lidless/config.json`. The file is created the first time you use a Lidless command. Changes apply within a few seconds.

```json
{
  "idleMinutes": 0,
  "batteryFloor": 20,
  "defaultLimit": 0,
  "lockOnLidClose": true
}
```

| Key | Meaning |
| --- | --- |
| `idleMinutes` | Turn off after Claude has been idle this many minutes. `0` disables it. |
| `batteryFloor` | Turn off at or below this battery percentage when on battery. `0` or `false` disables it. |
| `defaultLimit` | The limit `/lidless` uses when you give none, for example `"4h"`. `0` means no limit. |
| `lockOnLidClose` | Lock the screen when the lid closes. `false` disables it. |

## What Lidless does on your computer

This section lists everything the plugin runs, changes and writes, so you can check it against the source. All of it is plain shell and PowerShell in the `scripts` folder.

**Network.** None. Lidless opens no connections, sends nothing and downloads nothing.

**Data.** Claude Code hands each hook a block of input that can include your prompt or a tool result. The hook scripts take these things from it and discard the rest: the session id, the reason a session ended, whether background tasks or scheduled wake-ups exist, and, when you type a Lidless command, its name and arguments. Nothing from the conversation is written to disk or sent anywhere. Per session Lidless stores the Claude Code process id, that process's start time, the session id, the time limit, and one word: busy, waiting or idle.

**Hooks.** All seven run a script from the plugin folder. The first six below end after one file check while Lidless is off. The last one only runs when you type one of the four Lidless commands.

| Hook | What it does while Lidless is on |
| --- | --- |
| SessionStart | If Lidless left something behind after a crash, puts normal sleep behaviour back. Follows `/clear`. Prints nothing. |
| UserPromptSubmit | Marks the session busy. If an automatic turn-off is close, prints one "Lidless notice" sentence, which Claude Code adds to the conversation so Claude can warn you. |
| PostToolUse | Marks the session busy. |
| Stop, StopFailure | Marks the session idle, or waiting when background work is still running. |
| SessionEnd | Flags the session as ended so Lidless resets. |
| UserPromptExpansion | On or off, and only for `/lidless`, `/lidless-off`, `/lidless-status` and `/lidless-setup`: runs the command, shows its report and stops the prompt there, so no reply from Claude is needed. Anything unusual in the arguments is left to Claude instead. |

**Commands.** The four commands and the plain language skill may run one thing without asking: the plugin's own `scripts/lidless.sh`. They have no other pre-approved tools. Claude only turns Lidless on, extends it or changes a setting when you ask.

**Files it writes.** Everything is in `~/.claude/lidless`: `config.json`, `lidless.log`, and small state files in `sessions`, `busy`, `run` and `state`. On Windows, while Lidless is on, there is also a shortcut named "Lidless reset" in your Startup folder. It is removed when Lidless turns off.

**System changes while it is on.**

- Windows: with `powercfg`, three settings of the active power plan are set to 0 (lid close action, sleep after idle, hibernate after idle, for mains and battery). The old values are saved first and written back afterwards. The display timeout is not touched. A hidden PowerShell process watches the session, receives the lid notification from Windows and calls the Windows lock function. PowerShell is started with `-ExecutionPolicy Bypass` so it can run the plugin's own script file. To find the Claude Code process, the script reads the local process list once per command.
- Linux: a `systemd-inhibit` lock for `sleep` and `handle-lid-switch`, held by `tail --pid` until Claude Code exits. A background shell loop reads the lid state from `/proc/acpi/button/lid` and the battery from `/sys/class/power_supply`, and runs `loginctl lock-session` when the lid closes.
- macOS: `sudo -n pmset -a disablesleep 1`, and `0` afterwards. `caffeinate -i -w` tied to the Claude Code process. A background shell loop reads the lid state with `ioreg` and the battery with `pmset -g batt`. When the lid closes it locks the screen with one `osascript` call to the system's lock function, then `pmset displaysleepnow` as a fallback.

**What the one-time setup installs, when you run it yourself.**

- Windows: a scheduled task named "Lidless Boot Reset" followed by your user folder name, running at startup as SYSTEM, and a copy of `scripts/boot-reset.ps1` in `C:\Program Files\Lidless`, where only administrators can change it. That script only reads the saved values and accepts nothing but the exact lines Lidless writes.
- macOS: one file in `/etc/sudoers.d` with the rule described above, and `/Library/LaunchDaemons/com.tajbir.lidless.reset.plist`.

Nothing else is installed, and nothing starts with your computer apart from those two reset helpers.

## How it works

### Windows

- If the active power plan changes (OEM tools such as OMEN Gaming Hub, plugging in, unplugging), the settings are applied to the new plan too, and every plan that was changed is restored afterwards. If something writes the old values back, Lidless applies them again.
- Reset on restart and shutdown has four layers: the watcher restores the settings when Windows signs you out or shuts down; the boot task from `/lidless-setup` restores them at startup, before logon; the Startup folder shortcut restores them at logon and then deletes itself; and the next Claude Code start checks again.

One thing to know: if the lid is already closed when Lidless turns off, Windows does not sleep right away, because the lid did not move. It sleeps when its normal idle timer runs out. If your plan is set to never sleep while plugged in, a plugged-in laptop stays awake until you open and close the lid.

### Linux

- The sleep lock is a running process, not a setting, so a crash or a reboot can never leave it behind.
- Linux only lets the active local login block lid sleep. Over SSH, `/lidless` tells you that the lock was refused.

### macOS

- Lidless reads the flag back from `pmset -g` to confirm that the change took effect.
- While sleep is disabled this way, macOS may also skip its own low-battery sleep. The battery floor is what protects you there, so keep it on.
- For the most reliable lock, set "Require password after screen saver begins or display is turned off" to "Immediately" in System Settings, Lock Screen.
- If sleep was already disabled before Lidless turned on, Lidless leaves it disabled afterwards.

### Shared

- The Claude Code process is found by walking up the parent processes. Lidless stores its process id together with its start time, so a recycled id is never mistaken for it.
- The idle rule relies on the `background_tasks` field that current Claude Code versions pass to Stop hooks.

## What has been tested

- **Claude Code 2.1.330 on Linux**: the plugin passes `claude plugin validate` with the directory profile in strict mode. Installed from its marketplace file, `/lidless 10m` and `/lidless-status` ran through the real command line: the commands resolved, the script ran without a permission prompt, Lidless turned on, and it reset itself when the session ended. Install paths with spaces, apostrophes and ampersands worked. A path with round brackets did not (see "Messages you may see"). A stand-in replaced `systemd-inhibit`, because the test machine has no systemd.
- **Linux**: every flow in this README was run with stand-ins for `systemd-inhibit`, `loginctl`, the lid file and the battery files. It has not been run on a real laptop with a real lid.
- **macOS**: the same flows were run on Linux with stand-ins for `pmset`, `sudo`, `ioreg` and `caffeinate`. Nothing was run on macOS itself. The screen lock call is the least certain part.
- **Windows**: the command logic (save, apply, restore, plan changes, limits, battery, idle, crash cleanup) was run under PowerShell on Linux with `powercfg` replaced by a stand-in. The hidden watcher window, the lid notification, the lock call, the Startup shortcut and the Task Scheduler task have not been run.

If you try it on real hardware, please report what you see.

## First run check

Do this once at a desk before you trust it in a bag.

1. `/lidless 10m`, then `/lidless-status`. It should say ON with about 10 minutes left.
2. Close the lid for a minute. From your phone, send a message through Remote Control. It should answer.
3. Open the lid. The screen should be locked.
4. `/lidless-off`, then close the lid. The laptop should sleep as usual.
5. Turn it on again and close the terminal window without turning it off. Wait ten seconds, then check that lid close sleeps the laptop again. The log should show `RESTORED`.

To put things back by hand at any time:

- Windows: `/lidless-off all`. If Claude Code is not available, open Power Options and set "When I close the lid" back to Sleep.
- macOS: `sudo pmset -a disablesleep 0`
- Linux: nothing to do. The lock ends with Claude Code.

## Log

`~/.claude/lidless/lidless.log` records every on and off with the reason, plus lid closes and anything Lidless had to repair. `/lidless-status` shows the last line.

```
2026-11-21 14:02:21  ON   session 4821: limit 3h
2026-11-21 14:03:09  LID  closed, screen locked
2026-11-21 17:02:24  OFF  session 4821: time limit reached (3h)
2026-11-21 17:02:24  RESTORED normal sleep behaviour: time limit reached (3h)
```

## Messages you may see

| Message | What to do |
| --- | --- |
| Lidless could not find the Claude Code process | Run the command from inside Claude Code on the laptop, not from a plain terminal or a sandbox. |
| Invalid limit | Use `3h`, `90m`, `1h30m` or a number of hours. |
| Linux refused the sleep lock | Claude Code is running over SSH or outside the laptop's desktop login. Start it in a terminal on the laptop itself. |
| macOS needs a one-time setup | Run `/lidless-setup` and then the command it prints. |
| Lidless does not support this system | It only runs on Windows, Linux and macOS. Inside WSL it explains that Windows owns the lid. |
| Windows did not accept the power setting change | A company policy is probably locking power settings. Lidless cannot work on that PC. |
| Lidless could not start its background watcher | Nothing was left changed. The reason is printed and logged. |
| Shell command permission check failed | The folder the plugin is installed in has a round bracket in its path, for example a user folder named "Sam (Work)". The commands' permission rule cannot express such a path. Ask in plain words instead, for example "turn lidless on for 2 hours", and approve the prompt. |

## Removing

1. `/lidless-off all`
2. Undo the one-time setup (see "One-time setup").
3. Uninstall the plugin: `claude plugin uninstall lidless@tajbir-tools`, or remove it where you added it.
4. Delete `~/.claude/lidless`.

## Support

Report problems and ask questions in the issue tracker of this repository: https://github.com/Monabbir-Ahmmad/claude-lidless-plugin/issues

Please include `~/.claude/lidless/lidless.log` and the output of `/lidless-status`. Neither contains conversation text.

## License

MIT. See `LICENSE`.
