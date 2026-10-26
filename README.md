# MC Restart Timer

A separate Windows console that talks to your Minecraft **server window** (Infinity Legacy II, Matcha, ATM10, anything Java). It types `say` / `save-all` / `stop` into that console. No RCON.

Double-click `START TIMER.bat`.

## First time

1. Have the server console already open.
2. Start the timer from `START TIMER.bat` (its own window, not a Terminal tab).
3. Pick the pack. A wrong number stays on that menu.
4. Window picker: click the live Minecraft console, or use the numbered list. Green lines already have that pack's Java. Number + `P` flashes the window.
5. Dashboard must say **ARMED**. Press **T** — a chat ping must show in Minecraft. If it does not, press **W** and click the server console again.

## Keys

| Key | Action |
|-----|--------|
| **T** | Test chat — types a `say` into the bound window |
| **S** | Skip the next scheduled restart |
| **R** | Restart now (10 second warning, then save + stop) |
| **P** | Pause / unpause the schedule |
| **I** | Start this profile's server if it is down |
| **W** | Pick the server window again. Esc keeps the current window |
| **L** | Lag watch on/off. Two `Can't keep up` lines within 2 minutes start a 90s chat warning. Another one before that ends counts down an item clear (60, 40, 20, 5). Off until you press L |
| **H** | Add a hostile clear to that same countdown. Needs one `/reload` so `infinityclearhostiles` exists. Skips the ender dragon and the wither |
| **C** | Crash watch on/off. On by default. A dead-server line in `latest.log` restarts the server. A normal stop does not count. After 3 crash restarts in 15 minutes, the next one waits 90 seconds. Press C to clear that |
| **N** | Switch profile |
| **Q** | Close the timer. The Minecraft server keeps running |

## Clock

`06:00` `12:00` `18:00` `00:00` (this PC's local time)

Warnings at 15 min, 5 min, 1 min, 10 seconds.

After `stop`, the timer hits Enter on "Press any key", closes that console, then starts a fresh one. The bound window is saved in `state.json` so the timer reattaches next launch.

## Chat text

Edit the `messages` block at the top of `profiles.json`. `{time}` becomes `06:00` / `12:00` / `18:00` / `00:00`.

| Key | When |
|-----|------|
| `test` | T key ping |
| `warn15` | 15 minute warning |
| `warn5` | 5 minute warning |
| `warn1` | 1 minute warning |
| `warn10s` | 10 second warning |
| `restartNow` | Right before save + stop |
| `online` | After the server is back |

Keep `say ` at the start of each line (or use `tellraw` / `title`). A pack can override these with its own `messages` object.

## Discord webhook

Same lines also post to Discord (T, warnings, restart, online).

Paste the webhook URL in `profiles.json` as `discordWebhook`, or put it alone in a `discord.webhook` file next to the timer (that file is gitignored).

Leave `discordWebhook` empty if you do not want Discord.

## Adding another pack

Copy a profile in `profiles.json` and set:

- `name`, `workingDirectory`, `startCommand`
- `windowTitleContains` — text in the console title bar
- `processMatch` — text in the java command line (usually the folder name)
- `enabled`: `true`

## Notes

- Keep the server in a normal console window (cmd, PowerShell, or Windows Terminal).
- If the server is a tab in Windows Terminal, leave that tab selected.
- Closing the timer does not stop the game.
- The timer briefly focuses the server window to type, then gives focus back.
- `timer.log` and `state.json` stay local and are not committed.
