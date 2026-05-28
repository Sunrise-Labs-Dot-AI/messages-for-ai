---
name: birthday-reminder
description: Surface upcoming birthdays from the user's social graph and optionally draft a happy-birthday iMessage to the relevant contact. Use when the user asks "whose birthday is coming up", "any birthdays this week", "any birthdays this month", "remind me of birthdays", "draft a birthday text to [name]", "what should I text [name] for their birthday", "did I miss anyone's birthday", "birthday reminders", or any variant about surfacing or acting on contact birthdays. Read-only on birthday data; outbound is draft-only via the imessage-drafts MCP — never auto-sends. Pairs with the texting-analytics skill (recency / relationship depth context) and the james-text-voice skill (voice-correct drafts).
---

# birthday-reminder

A skill for noticing upcoming birthdays in the user's social graph and (optionally) drafting a happy-birthday iMessage that sounds like the user, with the right amount of warmth for the relationship.

## When to use

Trigger this skill when the user asks any of:

- "Whose birthday is coming up?"
- "Any birthdays this week / month?"
- "Remind me of birthdays."
- "Did I miss anyone's birthday?"
- "Draft a birthday text to [contact]."
- "What should I text [contact] for their birthday?"
- "Run my birthday check."

The skill **never auto-sends**. Drafts go through the standard `imessage-drafts` MCP hold-to-fire approval gate.

## Data source

Birthdays come from a user-maintained JSON file at `~/.messages-mcp/birthdays.json` (v1). Schema:

```json
[
  {
    "name": "Alex Chen",
    "contact_handle": "+15551234567",
    "birthday": "MM-DD or YYYY-MM-DD",
    "relationship": "friend | family | colleague | partner",
    "last_year_skipped": false,
    "notes": "free-form context — shared inside joke, year you met, etc."
  }
]
```

`contact_handle` should match the canonical handle the iMessage MCP returns from `list_threads`. If the user doesn't have this file yet, walk them through creating it — start with 5–10 closest people, expand from there.

**Future**: in a later version, pull from `CNContactStore` via a new daemon RPC method (`listBirthdays`) so this isn't manual. For now the JSON is the source of truth — much faster to ship and gives the user full control over scope.

## What it produces

Three possible outputs depending on the ask:

1. **Briefing** (default): a short markdown summary of birthdays in the next 14 days (or whatever window the user names), sorted by date. Each line: name, date, days-out, relationship, and a one-line context cue.
2. **Single draft**: a single staged iMessage draft via `stage_draft`, ready for the user to approve in the menubar.
3. **Batch drafts**: one staged draft per upcoming-birthday contact, when the user explicitly asks "draft birthday texts to everyone with a birthday this week."

## How to run it

Three phases. Don't skip any.

### Phase 1: Resolve upcoming birthdays

1. Read `~/.messages-mcp/birthdays.json`. If the file doesn't exist, stop and walk the user through creating it (see "First-time setup" below).
2. Compute "days until next occurrence" for each entry against today's date. Default window: 14 days. Honor an explicit window from the user ("next 30 days", "this month").
3. Sort by days-out ascending. Filter out anything outside the window.
4. If the list is empty, say so plainly — don't pad. "No birthdays in the next 14 days."

### Phase 2: Enrich with context (optional)

For each upcoming birthday, optionally pull lightweight context from the `imessage-drafts` MCP:

- `list_threads` with `contact_filter` set to the contact's name to find the thread_id.
- Once you have the thread, look at the last message's timestamp — surface "last texted N days ago" so the user knows the relationship temperature.
- Do NOT pull the full message body. The contact's recent message content is not needed for a birthday reminder; pulling it bloats context and risks leaking through to a draft.

Skip Phase 2 if the user only asked for a list.

### Phase 3: Briefing or draft

**If briefing**: render markdown like:

```
## Birthdays — next 14 days

- **Allison** — Wed Jun 4 (in 7 days) · partner · last texted today
- **Mark** — Sat Jun 7 (in 10 days) · friend · last texted 3 weeks ago
- **Mom** — Sun Jun 8 (in 11 days) · family · last texted yesterday
```

End with a one-line nudge if any "last texted" is >2 weeks ago: "Worth a no-occasion check-in to Mark before the birthday text lands."

**If draft**: invoke the `james-text-voice` skill (if available) for voice-correct phrasing. Pass it:
- The contact's name, relationship, and any notes from the JSON.
- A directive: "Draft a happy-birthday text for [name], who is James's [relationship]. Tone: [warm-and-personal for family/partner, casual-friendly for friends, brief-and-kind for colleagues]. Don't make it generic — use the `notes` field for specificity if present."

Then call `stage_draft` with the rendered text and the contact's handle. The menubar will pick up the draft for hold-to-fire approval.

## First-time setup

If `~/.messages-mcp/birthdays.json` doesn't exist, write a starter version with three example entries and tell the user:

> Birthday list lives at `~/.messages-mcp/birthdays.json`. I've created a starter with example entries — edit it with your real people (10–20 closest is a sensible start). Then run the briefing again.

Don't try to scrape Contacts or guess birthdays from message history. Be honest that this is currently manual.

## Notes for the LLM running this

1. **Never auto-send.** Even when the user says "send a birthday text to Mark," stage a draft and tell them it's queued in the menubar. The approval gate is the product.
2. **Don't pull message bodies for context.** The recency timestamp is enough. Bodies leak into drafts and risk awkwardness ("you mentioned X last week..." when "X" is half-remembered).
3. **Don't fake a birthday you don't have.** If the user asks "is anyone's birthday this week" and the JSON has no entries this week, say no. Don't infer from message data.
4. **For family/partner birthdays**, the bar is higher — surface that the JSON entry has a `notes` field and use it. A generic "Happy birthday!" to a spouse is worse than no reminder.
5. **Handles must match.** When staging a draft, the `to_handle` must match a handle from `list_threads` — otherwise the menubar can't route the message. Resolve via `list_threads` with `contact_filter` before staging.
6. **Privacy**: this skill reads from a local JSON file the user controls. Don't ever write the birthday list to anywhere outside `~/.messages-mcp/`. Don't paste names + birthdays into a third-party service.

## Future extensions

Not in v1, but reasonable next steps:

- `scripts/birthdays.py` — a thin Python helper that takes today's date + the JSON and returns a structured "upcoming" list (so the model isn't doing date math).
- `listBirthdays` daemon RPC method that pulls from `CNContactStore` so the JSON isn't required.
- Weekly digest mode: scheduled task that runs every Monday and texts the user a "this week's birthdays" summary via iMessage to themselves.
- "Did I miss anyone?" mode: surface birthdays from the last 7 days where no outbound message went to the contact on the day.
- Group-birthday awareness: surface upcoming birthdays for members of a specific group thread, so the user can coordinate.
