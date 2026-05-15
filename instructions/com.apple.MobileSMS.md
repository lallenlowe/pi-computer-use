# Messages (iMessage / SMS)

Catalyst app. Composer surfaces as `AXTextField "Message" [setValue,press,focus]`. The "Send" button next to it is gated on `UITextInput` change notifications, which `set_text`'s AX setValue does NOT fire. So:

- `set_text` writes the visible text correctly.
- The Send button never enables.
- `keypress(["Return"])` is a no-op because the framework still thinks the composer is empty.

**Use `apple_script` to actually send.** Apple Events are stealth-safe; they deliver to the Messages process without raising it.

## Stealth-mode happy path (sending)

```applescript
tell application "Messages"
    set targetChat to (first chat whose id is "iMessage;-;+15555550100")
    send "your message body" to targetChat
end tell
```

You can enumerate chats first to find the right id:

```applescript
tell application "Messages"
    set out to ""
    repeat with c in chats
        set out to out & (id of c) & " — " & (name of c) & linefeed
    end repeat
    return out
end tell
```

Run via `apple_script({ script: "...", app: "Messages" })`. `frontmostDrifted: false` is the expected outcome.

## Don't surprise the user

- **Sending is irreversible and visible immediately on the recipient's phone.** Always confirm with the user before calling the `send` script.
- Don't enumerate or read message contents from chats the user didn't ask about — Messages contents are private.
- Don't add reactions, send tapbacks, or modify chat properties without explicit instruction.

## Reading messages

- `screenshot` Messages and read what's visible. Don't script-enumerate `messages of chat ...` unless the user explicitly asked for a programmatic read.

## What's safe without asking

- Drafting via `set_text` (the draft sits in the composer; user can review).
- Listing chat names/ids via the enumeration script above (no contents read).
- Switching the visible chat via `click({ ref })` on a sidebar row.

## Ask first

- Sending any message
- Sending tapbacks/reactions
- Reading message contents from a chat the user didn't open
- Deleting or archiving chats
- Anything in Preferences
