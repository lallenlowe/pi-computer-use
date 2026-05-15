---
name: computer-use
description: Interact with macOS GUI windows using semantic screenshots, clicks, typing, and waits. Use this when the task requires operating a visible app window.
---

# Computer Use

Use these tools when shell/file tools are not enough and you need to operate a macOS app window directly.

## The contract: one rule

> **Input ops never steal focus. Two tools change frontmost — both ask the user.**

Real coordinate clicks, real keypresses, real text input — all delivered via per-PID `CGEventPostToPid`, which lands the event in the target app's queue without changing the user's frontmost or moving the system cursor. This is the only mode; there is no separate "stealth" toggle.

The two tools that change frontmost are gated by `requireFocusChangeApproval` — they call `ctx.ui.confirm(…)` before activating, surfacing the `reason` you pass:

- **`surface_window({ windowRef, reason })`** — activates the app and raises the window. Switches the user's viewport to the window's Space (or moves the window to active, depending on Spaces settings). Always pass a clear `reason` so the user understands the prompt.
- **`launch_app({ bundleId, activate: true, reason })`** — launches the app foreground. Same gate. The default `activate: false` is unconditionally safe (background launch).

For autonomous runs, the user can set `focus_auto_approve: true` in config to skip the prompt. As the agent, behave the same either way: pass a real `reason`, and treat a thrown "User declined" as a directive to find a non-focus alternative.

Everything else — `click`, `double_click`, `type_text`, `set_text`, `keypress`, `scroll`, `drag`, `move_mouse`, `computer_actions`, `apple_script`, `list_apps`, `list_windows`, `screenshot`, `wake_window`, `wait`, `launch_app({ activate: false })` — runs without prompting.

## Core workflow

1. **Call `screenshot` first** to pick the target window and get current UI state.
2. If the latest screenshot includes AX target refs, use those first for `click` / `set_text`. Refs are more reliable than coordinates and don't require visual grounding.
3. To discover/switch apps or windows, use `list_apps`, `list_windows`, then `screenshot({ window: "@w1" })` or pass `window` to action tools.
4. To launch an app that isn't running, use `launch_app({ bundleId })` (or `appName`). Default is background launch; the returned pid is immediately usable with `screenshot({ pid })`.
5. For text input, prefer `set_text({ ref: "@eN", text })` when the screenshot exposes a matching AX text target. Use click + `type_text({ text })` for fields without AX values (Electron webview content is the common case).
6. Use `keypress({ keys })` for Enter, Tab, Escape, arrows, deletion, and shortcuts. Enter/Escape/Space try semantic AX actions first; everything else delivers via per-PID `CGEventPostToPid`.
7. For browser navigation, use `keypress(["Command+L"])` → `set_text(URL)` → `keypress(["Enter"])`. Batched via `computer_actions` when no intermediate screenshot is needed.
8. Use `computer_actions({ actions })` to batch obvious actions like click + type + Enter when no intermediate screenshot is needed.
9. Every successful action returns the **latest semantic state**. If AX targets are missing, sparse, or ambiguous, an image is attached for vision fallback.

## Practical rules

- Action tools operate on the **current controlled window** by default, or an explicit `window` ref/id when provided.
- For browsers, prefer a **separate window** for agent work, not a new tab in the user's current window.
- `screenshot` may include compact AX targets like `@e1`; prefer refs for `click({ ref: "@e1" })` and `set_text({ ref: "@e1", text })` whenever a listed target matches what you want. For `set_text`, prefer targets marked `canSetValue`.
- Coordinates for `click`/`double_click`/`move_mouse`/`drag`/`scroll` are **window-relative logical points** (top-left origin), in `[0, windowWidth]` × `[0, windowHeight]` — the same units as the `framePoints.w/h` returned by `list_windows`. **Not image pixels.** On retina displays the screenshot image is captured at the display's backing scale (typically 2×), so pixel measurements read off the image are ~2× larger than the logical points the tools expect. The screenshot envelope's `Coords:` line tells you the exact window dims, image dims, and scale; divide image-pixel measurements by `scale` before passing them as coordinates. Targets near the right or bottom edge are particularly easy to miss because doubled coords fall outside the window frame entirely — the tool will reject those with a clear error rather than silently dispatching to dead space.
- `stateId` is optional. If provided and stale, refresh with `screenshot`.
- `type_text` inserts text at the current cursor/selection. Use `set_text` when you need to replace an AX text value; prefer a ref over relying on focus.
- `scroll` can use an AX ref marked `scroll` or screenshot-relative coordinates. `drag` can use a ref marked `adjust` plus a path for sliders/steppers, otherwise it uses screenshot-relative path points. `move_mouse`, `double_click`, and coordinate clicks use screenshot-relative coordinates from the latest screenshot.
- For shortcut sequences, use chord strings like `keypress({ keys: ["Command+L", "Enter"] })`; reserve `["Command", "L"]` for a single chord call.
- `computer_actions` executes one to twenty actions and returns one state update plus per-action execution metadata. Do not batch if the next action depends on seeing an intermediate result.
- `wait({ ms })` pauses and then returns the latest semantic state for polling/loading states.
- Accessibility permission is mandatory for actions.
- Screen Recording permission is mandatory for screenshots and model vision context.
- Public tool surface is `list_apps`, `list_windows`, `screenshot`, `click`, `double_click`, `move_mouse`, `drag`, `scroll`, `keypress`, `type_text`, `set_text`, `wait`, `arrange_window`, `computer_actions`, `apple_script`, `wake_window`, `surface_window`, `launch_app`.
- Run `/computer-use` to show effective config. Config files are `~/.pi/agent/extensions/pi-computer-use.json` globally and `.pi/computer-use.json` per project.
- `browser_use=false` blocks control of known browser apps. `focus_auto_approve=true` makes the focus-change tools skip their `ctx.ui.confirm` prompt.
- If a `screenshot` result includes an `--- App-specific instructions for ... ---` block, prefer the guidance there over generic heuristics for that app. The instructions are hand-written for surprising behaviors (selection rules, modifier conventions, irreversible actions) the AX tree alone won't tell you about. Apps without instructions are normal — work it out from AX targets and the screenshot as usual.

## When errors happen

If an action reports stale state, target mismatch, or missing target/window, call `screenshot` again to refresh and continue.

If a click or keypress lands but the app doesn't respond, the app may gate input on foreground status. Modern apps (Electron, Catalyst, recent Cocoa) honor per-PID input regardless of foreground; some legacy AppKit apps don't. If the app needs to be foreground, call `surface_window({ windowRef: "@wN", reason: "..." })` — the user will be prompted before focus moves.

### Recovery loop: "the controlled window is no longer available"

This error usually does **not** mean the window is gone. The most common cause is that the user switched macOS Spaces, leaving the window on a different Space.

**macOS reality:** off-Space windows cannot be driven silently. AX cannot deliver actions to them, and there is no SIP-respecting way for one process to move another process's window between Spaces. Surfacing the window switches the user's viewport — that's why the tool prompts the user. So the recovery loop is: discover non-GUI alternatives first, fall back to `surface_window` only when the task actually requires the window foreground.

1. Call `list_windows({ pid })` (or `list_windows({ app })`). If the window appears with `off_active_space` in its flags, the window is on another Space.
2. Call `wake_window({ windowRef: "@wN" })`. This is a **status + recovery probe**, not a window-mover. It un-minimizes minimized-but-on-Space windows (silent), and for off-Space windows returns a structured recipe of non-GUI alternatives.
3. Read the response carefully. Try the alternatives in this order:
   1. **`apple_script`** — if enabled, this is your best path. Apple Events do not raise the window or change Spaces. Most macOS apps expose at least basic operations through their scripting dictionary.
   2. **app instructions** — if `wake_window` reports `appInstructions.found: true`, the app has a bundled or user-supplied recipe (URL scheme, command-line tool, file-based workflow) that bypasses the GUI. Pull up an on-Space window of the app via `screenshot` to read the full instructions, or check `~/.pi/agent/extensions/pi-computer-use/instructions/<bundleId>.md`.
   3. **app-specific knowledge** — many apps have URL schemes (`obsidian://`, `vscode://`, `slack://`), CLIs (`code`, `gh`, `osascript`), or file-based workflows that bypass the GUI.
4. If steps 1–3 cannot complete the task, call `surface_window({ windowRef: "@wN", reason: "..." })`. The tool will prompt the user via `ctx.ui.confirm`; pass a `reason` that names the task so the prompt is informative.
5. After `surface_window` succeeds, call `screenshot({ window: "@wN" })` and resume — once the window is foreground, all input ops work normally.

If the controlled-window error message itself includes a `wake_window({ windowRef: "@wN" })` suggestion, follow it directly — the resolver already detected the off-Space case for you.

If `list_windows` returns no entries at all and `list_apps` doesn't list the app either, the app has actually quit. Use `launch_app({ bundleId, activate: false })` to re-launch it in the background, then run `screenshot({ pid })` with the returned pid.

If `list_apps` still lists the app but `list_windows` returns nothing, the app has no open windows. Try `launch_app({ bundleId, activate: false })` (already-running apps with no windows often spawn a default window when re-opened) or use the app's own "new window" shortcut (e.g. `keypress({ keys: ["Command+N"] })`).

### Recovery loop: app doesn't respond to per-PID input

Modern apps accept per-PID input regardless of foreground. If you've sent clicks/keys to a non-foreground window and nothing happened:

1. Confirm the input was actually delivered: tool result shows successful execution, no error.
2. Check whether the app needs foreground for *that specific operation*. Modal dialogs and some Electron settings panes only render when foreground.
3. Call `surface_window({ windowRef: "@wN", reason: "..." })`. Once foreground, retry the operation.

The `[contract: …]` marker at the top of `screenshot`, `list_apps`, and `list_windows` responses tells you what's currently in play, including the current `focus_auto_approve` state.
