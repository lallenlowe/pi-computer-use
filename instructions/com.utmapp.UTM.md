# UTM

Two very different surfaces:

1. **Management chrome** (main window, VM wizard, settings). Native SwiftUI. AX refs work; drive normally.
2. **VM display window** (guest framebuffer). Opaque to macOS AX. Coord clicks only, and only land when Capture Input is on.

Know which surface you're on before clicking.

## VM management chrome

Standard rules. Use AX refs when listed. SwiftUI checkboxes in wizard sheets often don't surface as AX targets — coord-click those. Envelope `scale` (~2.0 on retina) is correct: divide image-pixel measurements by `scale` to get logical points. Confirmed coord-only: "Use Apple Virtualization", "Boot from kernel image", "Enable Rosetta".

## VM display window

### Capture Input must be on for guest clicks to land

When the toolbar `AXCheckBox "Capture Input"` is **off**, clicks stay in macOS coord space and hit whatever macOS widget sits at that pixel — NOT the guest. Symptoms: clicks open macOS Settings, raise other apps, or do nothing.

- Read value before driving the guest: `apple_script` `value of AXCheckBox "Capture Input"` (0 / 1). The AX dump shows the checkbox but not its value.
- `click({ ref })` on Capture Input is unreliable (AXPress no-ops). Use `apple_script` `click checkbox "Capture Input" of …`, then re-verify.
- **`surface_window` silently turns Capture Input off.** Re-verify and re-enable every time you raise the VM window.

### Coordinate scale & misses

Envelope `scale` IS correct. **A miss is almost always Capture Input being off, not a scale mismatch — don't keep adjusting scale, re-check Capture Input first.** Verify scale once by clicking a known sharp-edge target (close-X, button corner).

### Guest AX is unreachable

GNOME AT-SPI / Windows UIA are invisible to macOS. The `@eN` targets you see are UTM's toolbar buttons, not widgets inside the guest. **Coord clicks are your only option for guest UI.**

### Keyboard

`keypress` works when Capture Input is on. Two gaps:

- **Standalone modifier-only events (Super, Cmd alone) don't propagate through UTM** — UTM-side filter. Use UTM's `View → Send Key`, or remap the guest shortcut to a chord (Ctrl+Alt+X).
- For guest text input, prefer `apple_script` `keystroke "..."` over per-character `type_text` — more reliable when Capture Input is flapping.

## Don't drive OS installers via this skill

Anaconda, Ubuntu Server installer, Windows Setup live entirely in the guest framebuffer — no AX, no DOM, every click is dead-reckoning. **Use kickstart / preseed / unattend.xml** to skip the GUI. If you must drive the installer: don't try to recover from a wrong click (restart the VM), and switch to SSH the moment the install completes.

## Ask before

- VM transport (Start, Stop, Pause, Restart) — Stop is a power-cut.
- Destructive ops (Delete VM, delete snapshot, reset NVRAM).
- Destructive guest-side actions.

OK without asking: screenshotting, reading toolbar state, inspecting AX targets in the chrome.
