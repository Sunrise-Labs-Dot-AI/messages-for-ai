# Spotify Wrapped Story System

## Positioning

Literal Wrapped for texting behavior: full-bleed story cards, huge numbers, abstract backgrounds, swipeable flow, and a final archetype reveal.

This is optimized for mobile sharing and referral traffic. The card should read in one second, make the viewer laugh in two, and make `messagesfor.ai` easy to remember.

## Card Arc

1. Cover: `Your Texting Wrapped 2026`  
   Verdict: `The receipts are local.`

2. Hero number: `1,284 texts sent`  
   Verdict: `A mock total until the data side ships totals.`

3. Top People: `Your Top People`  
   Ranked list: `1 Maya`, `2 Alex`, `3 Priya`, `4 Ben`, `5 Sam`  
   Verdict: `The Top Artists slot, but socially risky.`

4. Reply behavior: `8.6 min vs 85.5 min`  
   Verdict: `Fast when you reply. The tail tells on you.`  
   Support: `47% within 5 min`

5. Ball in court: `93%`  
   Verdict: `Almost every active thread is waiting on you.`

6. Group-chat reveal: `0.7%`  
   Verdict: `Group chat presence: mostly folklore.`  
   Support: `Silent in 12 of 15 groups. One 1,589-message group got 0 from you.`

7. Archetype payoff and share: `The Group Chat Ghost`  
   Verdict: `Left-on-Read Royalty with lurker energy.`  
   CTA: `Share your Texting Wrapped`  
   Secondary: `Replay from beginning`

## Treatments

- `neon-orbit`: closest to Spotify Wrapped, saturated gradients, orbital ribbons, huge condensed type, high-contrast stamp.
- `liquid-pop`: bright liquid gradients, warped blobs, layered color bands, playful scale, feed-native energy.
- `blacklight-royalty`: dark story mode, purple and acid green gradients, crown motifs, premium but loud.

All treatments use the same seven-card system. Differences are background, type rhythm, and art direction, not format.

## Voice Rules

- One idea per card.
- Hero number first.
- Minimal copy.
- One verdict line per card.
- No em dashes in card copy.
- Footer stamp on every card: `sunriselabs.ai · messagesfor.ai`.

## Mock Data Notes

The real supplied WhatsApp metrics are stored directly in `mock-analysis.json`.

Mock-only future fields:

- `mock_totals.texts_sent`: `1284`
- `mock_top_people`: invented names for the Top People card

These fields are for creative exploration only. They do not change the production schema or data-layer contract.

## Archetype

Primary archetype: `The Group Chat Ghost`.

Derived from:

- very high ball-in-court rate: `93%`
- extremely low group contribution: `0.7%`
- silent in `12 of 15` groups
- one `1,589` message group with `0` sent
- median reply is fast-ish, mean reply is much slower

Supporting flavor: `Left-on-Read Royalty`.
