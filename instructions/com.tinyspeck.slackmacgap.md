# Slack

Electron app. Content lives inside an `AXWebArea`. The bridge surfaces both chrome (Search, nav tabs, Back/Forward, workspace switcher) and the composer (`AXTextArea` "Message to ...") via the hybrid text-input rescue pass — coordinates are rarely needed.

## Happy path

1. `screenshot` Slack — composer surfaces as `@e1 AXTextArea "Message to <person|channel>"`.
2. `set_text({ ref, text })` to draft. Lands without raising Slack.
3. **Always confirm with the user before sending.**
4. After confirmation, `keypress({ keys: ["Return"] })` to send.

## Don't surprise the user

- **Sends are irreversible.** Type the draft first, confirm, then send.
- **Don't mark channels read by clicking into them.** Use Activity tab or thread view if you just need to see new content without touching read-state.
- **Don't change workspace.** The workspace switcher (`AXPopUpButton "Switch workspaces…"`) pulls the user out of whatever they're doing.
- **Don't react with emoji unless asked.** Reactions are public.

## Navigation

- Left rail tabs (`Home`, `DMs`, `Activity`, `Later`, `More…`, `Files`) are `AXRadioButton`s with subrole `AXTabButton`. `click({ ref })` them, never coordinates.
- Search button at the top of the toolbar (`AXButton "Search"`) opens the search UI; press it, `set_text` the query, `keypress(["Return"])`. Background-clean path to find anything.
- `cmd+k` (quick-switcher) is delivered per-PID and lands without us raising Slack. **But** Slack's own handler activates the window when the modal opens, so frontmost briefly shifts to Slack as a side-effect. Prefer the Search button when you need to stay clean.
- `cmd+,` opens Preferences. Don't change settings unless asked.

## Composer

- `AXTextArea` with description "Message to ...". `canSetValue: true`; `set_text({ ref, text })` replaces the draft cleanly. Prefer it to typing for non-trivial content.
- **Markdown shortcuts** as you type: `**bold**`, `_italic_`, `` `code` ``, `> quote`, `- list`. Slack converts on the fly.
- Triple-backtick opens a code block. `shift+enter` is a newline; `enter` sends.
- Slash commands (`/remind`, `/dm`, `/giphy`) take effect on send.
- File uploads (`cmd+u`) open a file picker the bridge can't drive; ask the user.

## Threads

- `click({ ref })` a message in the channel feed to open its thread in the right pane.
- Right-pane thread has its own composer, surfaced after a fresh screenshot inside the thread view.
- `keypress(["Escape"])` returns focus to the channel composer.

## OK without asking

- Reading messages (screenshot after navigating).
- Drafting a reply (don't send).
- Searching via the Search button.
- Switching between visible left-rail tabs.

## Ask first

- Sending any message
- Joining/leaving channels
- Reactions
- Invites
- Preferences / workspace settings
- Posting into a channel the user wasn't already viewing
