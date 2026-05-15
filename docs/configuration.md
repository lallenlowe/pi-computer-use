# Configuration

`pi-computer-use` has a small configuration surface: browser control and the focus-change approval gate.

## Config Files

Global config:

```text
~/.pi/agent/extensions/pi-computer-use.json
```

Project-local override:

```text
.pi/computer-use.json
```

Example:

```json
{
  "browser_use": true,
  "focus_auto_approve": false
}
```

Project-local config overrides global config. Environment variables override both files.

Run `/computer-use` in Pi to show the effective config and source status.

## Options

### `browser_use`

Default: `true`

When `false`, screenshots and actions against known browser apps are refused. Useful when a project should avoid controlling browser windows.

Known browser families include Safari, Chrome/Chromium-family browsers, Firefox, Arc, Brave, Edge, Vivaldi, and Helium.

### `focus_auto_approve`

Default: `false`

Controls the approval gate for focus-changing tools (`surface_window`, `launch_app({activate:true})`).

- `false` (default): the tool calls `ctx.ui.confirm(…)` before activating. The agent must pass a non-empty `reason` so the user understands why their frontmost is about to change. Decline is surfaced to the agent as a structured error.
- `true`: the tool skips the prompt and activates immediately. Use for fully autonomous runs where you've already accepted that the agent will move your focus.

All other input (clicks, keypresses, type_text, scroll, drag, set_text) is delivered per-PID and never changes the user's frontmost. There is no separate "stealth mode" — that's just how the extension works now.

## Environment Overrides

```bash
PI_COMPUTER_USE_BROWSER_USE=0
PI_COMPUTER_USE_BROWSER_USE=1
PI_COMPUTER_USE_FOCUS_AUTO_APPROVE=0
PI_COMPUTER_USE_FOCUS_AUTO_APPROVE=1
```

### Legacy

`stealth_mode`, `PI_COMPUTER_USE_STEALTH_MODE`, `PI_COMPUTER_USE_STEALTH`, and `PI_COMPUTER_USE_STRICT_AX` are recognised but ignored — they emit a one-time `console.warn` on load and otherwise do nothing. The behaviour they once toggled is now the default and only mode. Remove them from your config.

## Recommended Defaults

For interactive use (you want a confirm dialog when the agent needs to take focus):

```json
{
  "browser_use": true,
  "focus_auto_approve": false
}
```

For autonomous runs (the agent should move focus without bothering you):

```json
{
  "browser_use": true,
  "focus_auto_approve": true
}
```
