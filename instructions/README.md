# App Instructions

Hand-written, app-specific guidance the bridge injects into screenshot results when the model is looking at a matching app. Modeled on OpenAI Codex's `Codex Computer Use.app/.../AppInstructions/` directory.

## Why

Many macOS apps have surprising interaction semantics that an LLM has to discover the hard way: Notion's `cmd+a`-twice behavior, Slack's read-receipt rules, Numbers' formula bar quirks. A few hundred words of prompt context can save dozens of tool calls.

These instructions are **purely additive**. Apps without an instructions file work exactly as before — the model figures things out from AX targets and screenshots. Apps with one get a head start.

## File naming

- **Bundle-id form (preferred):** `<bundle-id>.md` — e.g. `com.tinyspeck.slackmacgap.md`. This is what the Mac sees and is stable across renames.
- **App-name form (fallback):** `<App Name>.md` — e.g. `Slack.md`. Used when the bundle-id file is absent.

Bundle-id files win over name files when both exist.

## User overrides

Files dropped in `~/.pi/computer-use/instructions/` win over the bundled ones with the same name. Fork-and-improve, or experiment with your own instructions for an app the project hasn't covered yet.

## What goes in an instructions file

Markdown. Aim for ≤ 3 KB. The bridge will warn and truncate longer files. Useful sections:

- **Editing semantics** that aren't obvious from AX (block-vs-inline, list creation, modifier-key conventions)
- **Selection rules** that differ from standard macOS (`cmd+a` overrides, multi-step focus dance)
- **Placeholder text** so the model doesn't try to delete it
- **Navigation shortcuts** the app exposes
- **What NOT to do** — irreversible actions, things that cost money, things that send messages on your behalf

Skip:

- Re-explaining click/type/keypress mechanics that the bridge handles
- Anything that's already obvious from the AX role/label (the model can read those)
- Long flat lists of features — the model can ask, give it heuristics not catalogs

## Contributing a new file

1. Use Accessibility Inspector or a `screenshot` call from pi to see the bundle id and what AX exposes.
2. Write the file. Test it: drop your version in `~/.pi/computer-use/instructions/`, restart pi, and screenshot the app. Confirm the instructions appear in the tool result.
3. Open an issue describing the app and the workflow the instructions help.
4. PR adding `instructions/<bundle-id>.md`.
