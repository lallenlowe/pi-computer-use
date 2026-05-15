# Slack

Slack is an Electron app. Its content is hosted inside an AXWebArea and the bridge surfaces the chrome (Search, nav tabs, Back/Forward, workspace switcher) as AX targets. Anything inside the channel feed/composer is reachable but mostly not labeled — fall back to coordinates from the screenshot for those.

## Don't surprise the user

- **Sending messages is irreversible.** Type a draft into the composer, then ask the user to confirm before pressing Enter unless they explicitly told you to send.
- **Don't mark channels read by clicking into them.** Use the Activity tab or thread view if you need to see new content without changing the user's read-state.
- **Don't change workspace.** The workspace switcher (`AXPopUpButton "Switch workspaces…"`) will pull the user out of whatever they're doing. Stay in the current workspace.
- **Don't react with emoji unless asked.** Reactions are public.

## Navigation

- The left rail has tabs: `Home`, `DMs`, `Activity`, `Later`, `More…`, `Files`. They're `AXRadioButton`s with subrole `AXTabButton`. Press them via AX rather than coordinates.
- `cmd+k` opens the quick-switcher (jump-to-channel/DM). Faster than navigating through the sidebar.
- `cmd+,` opens preferences. Don't change settings unless the user asked.
- The Search button (top toolbar) opens the search UI; type a query and press Enter.

## Composer

- The message composer is at the bottom of a channel/thread/DM view. It's a contenteditable inside the WebArea, usually surfaced as an `AXTextArea`. `set_text({ ref, text })` will replace the current draft; prefer it to typing for long content.
- **Markdown shortcuts work** as you type: `**bold**`, `_italic_`, `` `code` ``, `> quote`, `- list`. Slack converts on the fly.
- **Triple-backtick** opens a code block. `shift+enter` makes a newline inside the message; `enter` sends.
- Slash commands (`/remind`, `/dm`, `/giphy`, etc.) work in the composer. Treat them like real commands — they take effect on send.
- File uploads via `cmd+u` open a file picker. The bridge has no clean path to drive that picker yet; ask the user.

## Threads

- Click the message in the channel feed to open its thread in the right pane. The right pane has its own composer.
- `escape` from a thread returns focus to the channel composer.

## What you can usually do without bothering the user

- Read recent messages in a channel/DM/thread (screenshot the window after navigating).
- Draft a reply into the composer (don't send).
- Search via `cmd+k` or the search bar.
- Switch between the visible tabs (Home/DMs/Activity).

## What to ask first

- Sending any message
- Joining/leaving channels
- Adding reactions
- Inviting people
- Anything in `Preferences` or workspace settings
- Posting to a channel you weren't already viewing
