# UTM

Two very different surfaces:

1. **Management chrome** (main window, VM wizard, settings). Native SwiftUI. AX refs work; drive normally.
2. **VM display window** (guest framebuffer). Opaque to macOS AX. Coord clicks only, and only land when Capture Input is on.

Know which surface you're on before clicking.

## VM management chrome

Standard rules. Use AX refs when listed. SwiftUI checkboxes in wizard sheets often don't surface as AX targets — coord-click those, reading pixel coords directly off the normalized screenshot. Confirmed coord-only: "Use Apple Virtualization", "Boot from kernel image", "Enable Rosetta".

## VM display window

### Capture Input must be on for guest clicks to land

When the toolbar `AXCheckBox "Capture Input"` is **off**, clicks stay in macOS coord space and hit whatever macOS widget sits at that pixel — NOT the guest. Symptoms: clicks open macOS Settings, raise other apps, or do nothing.

- Read value before driving the guest: `apple_script` `value of AXCheckBox "Capture Input"` (0 / 1). The AX dump shows the checkbox but not its value.
- `click({ ref })` on Capture Input is unreliable (AXPress no-ops). Use `apple_script` `click checkbox "Capture Input" of …`, then re-verify.
- **`surface_window` silently turns Capture Input off.** Re-verify and re-enable every time you raise the VM window.

### Coord clicks auto-raise UTM (no need to surface_window first)

Coord clicks into UTM activate the app and raise the target window before posting, so the click lands in the guest even when UTM was behind other windows or another app was frontmost. Side effect: macOS frontmost jumps to UTM. That's a visible focus change. Re-verify Capture Input after the click — it may or may not survive the raise; this hasn't been characterized as carefully as `surface_window`'s known drop.

### Guest AX is unreachable

GNOME AT-SPI / Windows UIA are invisible to macOS. The `@eN` targets you see are UTM's toolbar buttons, not widgets inside the guest. **Coord clicks are your only option for guest UI.**

### Keyboard

`keypress` works when Capture Input is on. Two gaps:

- **Standalone modifier-only events (Super, Cmd alone) don't propagate through UTM** — UTM-side filter. Use UTM's `View → Send Key`, or remap the guest shortcut to a chord (Ctrl+Alt+X).
- For guest text input, prefer `apple_script` `keystroke "..."` over per-character `type_text` — more reliable when Capture Input is flapping.

## Ask before

- VM transport (Start, Stop, Pause, Restart) — Stop is a power-cut.
- Destructive ops (Delete VM, delete snapshot, reset NVRAM).
- Destructive guest-side actions.

OK without asking: screenshotting, reading toolbar state, inspecting AX targets in the chrome.
