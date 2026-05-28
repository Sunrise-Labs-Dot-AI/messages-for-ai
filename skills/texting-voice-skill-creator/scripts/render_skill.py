#!/usr/bin/env python3
"""render_skill.py — turn a voice fingerprint into a new <slug>-text-voice skill.

Reads a fingerprint JSON (produced by analyze_voice.py) and writes:
    <output_dir>/<slug>-text-voice/SKILL.md
    <output_dir>/<slug>-text-voice/fingerprint.json

Pure stdlib. The SKILL.md is generated from a deterministic template — same
fingerprint in, same SKILL.md out — so re-running is safe and diffable.

INVARIANT: the output never contains a message body. Aggregates only.

Usage:
    python3 render_skill.py --fingerprint fp.json --output-dir ./skills

Exit codes:
    0 — success
    2 — fingerprint malformed
    4 — output directory already contains <slug>-text-voice/ (won't overwrite)
"""

import argparse
import json
import os
import sys

PARTNER_HINTS = {"partner", "spouse", "wife", "husband", "girlfriend", "boyfriend"}


def render_description(fp):
    return (
        f"Draft iMessages to {fp['contact']} in James's voice for that specific "
        f"relationship. Use whenever James asks \"text {fp['contact']}\", "
        f"\"reply to {fp['contact']}\", \"what should I say to {fp['contact']}\", "
        f"\"draft a message to {fp['contact']}\" — for the 1:1 iMessage thread with "
        f"{fp['contact']}. Captures voice patterns observed across N={fp['sample_size']} "
        f"outbound messages (window: {fp['window']}). Pairs with james-text-voice — "
        f"apply james-text-voice's base rules first, then the overlays here."
    )


def render_fingerprint_bullets(fp):
    lines = []
    L = fp["length"]
    lines.append(
        f"- **Length** — median {L['median_chars']} chars (p25 {L['p25_chars']}, p75 {L['p75_chars']}); "
        f"{int(L['pct_under_20_chars'] * 100)}% are under 20 chars."
    )
    C = fp["capitalization"]
    lines.append(
        f"- **Capitalization** — {int(C['pct_lowercase_start'] * 100)}% of messages start lowercase; "
        f"{int(C['pct_all_lowercase'] * 100)}% are fully lowercase."
    )
    P = fp["punctuation"]
    lines.append(
        f"- **Punctuation** — {int(P['pct_ending_with_nothing'] * 100)}% end with nothing, "
        f"{int(P['pct_ending_with_period'] * 100)}% with a period, "
        f"{int(P['pct_ending_with_exclaim'] * 100)}% with `!`, "
        f"{int(P['pct_ending_with_question'] * 100)}% with `?`."
    )
    E = fp["emoji"]
    top_emo = ", ".join(f"{e['emoji']} ({e['count']})" for e in E["top_5"]) or "none"
    lines.append(
        f"- **Emoji** — {int(E['pct_messages_with_emoji'] * 100)}% of messages have emoji. "
        f"Top: {top_emo}."
    )
    if fp["abbreviations"]:
        abbr = ", ".join(f"{k}×{v}" for k, v in fp["abbreviations"].items())
        lines.append(f"- **Abbreviations used** — {abbr}.")
    B = fp["bursts"]
    lines.append(
        f"- **Multi-message bursts** — median {B['median_messages_per_burst']} message(s) per burst, "
        f"p75 {B['p75_messages_per_burst']} (burst = consecutive outbound within "
        f"{B['burst_definition_minutes']} min)."
    )
    O = fp["openers"]
    if O["top_3"]:
        opn = ", ".join(f"\"{o['phrase']}\" ({o['count']})" for o in O["top_3"])
        lines.append(f"- **Top openers** — {opn}.")
    Cl = fp["closers"]
    if Cl["top_3"]:
        cls = ", ".join(f"\"{c['phrase']}\" ({c['count']})" for c in Cl["top_3"])
        lines.append(f"- **Top closers** — {cls}.")
    return "\n".join(lines)


def render_drafting_rules(fp):
    rules = []
    L = fp["length"]
    rules.append(f"- Target {L['median_chars']} chars per message. Wall-of-text is off-voice.")
    C = fp["capitalization"]
    if C["pct_lowercase_start"] >= 0.5:
        rules.append("- Default to lowercase first word — uppercase reads as formal/distant.")
    elif C["pct_lowercase_start"] < 0.2:
        rules.append("- Use standard capitalization. James capitalizes consistently with this contact.")
    P = fp["punctuation"]
    if P["pct_ending_with_nothing"] >= 0.5:
        rules.append("- Most messages end with no terminal punctuation. Only add a period for genuine formality or finality.")
    if P["pct_ending_with_period"] >= 0.5:
        rules.append("- End most messages with a period — this contact gets the more careful, considered tone.")
    E = fp["emoji"]
    if E["pct_messages_with_emoji"] >= 0.3 and E["top_5"]:
        favorites = " / ".join(e["emoji"] for e in E["top_5"][:3])
        rules.append(f"- Emoji rate is high ({int(E['pct_messages_with_emoji'] * 100)}%). Favor {favorites}.")
    elif E["pct_messages_with_emoji"] < 0.1:
        rules.append("- Emoji are rare in this thread — don't add them by default.")
    B = fp["bursts"]
    if B["median_messages_per_burst"] >= 2:
        rules.append(
            f"- Multi-message bursts are normal here (median {B['median_messages_per_burst']}). "
            "When the response is naturally two thoughts, stage them as two separate drafts, "
            "not one long message with a paragraph break."
        )
    else:
        rules.append("- One message per reply is the norm. Don't fragment.")
    return "\n".join(rules)


def render_anti_patterns(fp):
    """Things observed absent or vanishingly rare. Be careful with small samples."""
    notes = []
    L = fp["length"]
    if L["pct_under_20_chars"] >= 0.3:
        notes.append("- Avoid wall-of-text — over a third of this thread's outbound is under 20 chars.")
    C = fp["capitalization"]
    if C["pct_all_lowercase"] >= 0.4:
        notes.append("- Don't start a message with \"Hey there\" or other formal-feeling openers — they're absent in the sample.")
    P = fp["punctuation"]
    if P["pct_ending_with_exclaim"] < 0.05:
        notes.append("- Exclamation marks are rare (<5% of messages). Don't over-use them.")
    if not notes:
        notes.append("- (No strong anti-patterns surfaced — sample may be too small or voice may be eclectic.)")
    return "\n".join(notes)


def render_skill_md(fp):
    sample_caveat = ""
    if fp["sample_size"] < 100:
        sample_caveat = (
            f"\n> **Small-sample caveat**: this skill was generated from {fp['sample_size']} "
            "outbound messages. Patterns below are suggestive, not strongly statistical. "
            "Re-run the analyzer when you have more history with this contact.\n"
        )

    return f"""---
name: {fp['slug']}-text-voice
description: {render_description(fp)}
---

# {fp['slug']}-text-voice
{sample_caveat}
How James texts **{fp['contact']}**, captured from N={fp['sample_size']} outbound 1:1 messages over the window {fp['window']}.

This skill is an **overlay** to `anthropic-skills:james-text-voice`, not a replacement. Apply the base voice rules first, then the relationship-specific overlays here.

## Voice fingerprint (observed)

{render_fingerprint_bullets(fp)}

## Drafting rules (derived)

{render_drafting_rules(fp)}

## Anti-patterns

{render_anti_patterns(fp)}

## Drift detection

The `fingerprint.json` next to this `SKILL.md` is the snapshot at generation time. If James starts texting {fp['contact']} very differently in 6 months, re-run `texting-voice-skill-creator` and diff against this fingerprint.

## Notes

- Aggregate stats only. No message bodies were stored in this skill.
- Patterns are statistical, not absolute. Don't be robotic about them.
- If James explicitly overrides ("draft a formal message to {fp['contact']}"), honor the override.
"""


def main():
    ap = argparse.ArgumentParser(description="Render a per-relationship voice skill from a fingerprint.")
    ap.add_argument("--fingerprint", required=True, help="Path to fingerprint JSON from analyze_voice.py.")
    ap.add_argument("--output-dir", required=True, help="Parent directory where <slug>-text-voice/ will be created.")
    args = ap.parse_args()

    try:
        with open(args.fingerprint) as f:
            fp = json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": "fingerprint not found", "path": args.fingerprint}), file=sys.stderr)
        sys.exit(2)

    required = {"contact", "slug", "sample_size", "window", "length", "capitalization",
                "punctuation", "emoji", "abbreviations", "bursts", "openers", "closers"}
    missing = required - set(fp)
    if missing:
        print(json.dumps({"error": "fingerprint missing keys", "missing": sorted(missing)}),
              file=sys.stderr)
        sys.exit(2)

    skill_dir = os.path.join(args.output_dir, f"{fp['slug']}-text-voice")
    if os.path.exists(skill_dir):
        print(json.dumps({
            "error": "skill directory already exists",
            "path": skill_dir,
            "guidance": "Pick a different slug, version it (e.g. add a year suffix), or delete the existing one.",
        }), file=sys.stderr)
        sys.exit(4)

    os.makedirs(skill_dir)
    skill_md = render_skill_md(fp)
    with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
        f.write(skill_md)
    with open(os.path.join(skill_dir, "fingerprint.json"), "w") as f:
        json.dump(fp, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(json.dumps({
        "status": "ok",
        "skill_dir": skill_dir,
        "files": ["SKILL.md", "fingerprint.json"],
        "sample_size": fp["sample_size"],
        "next_step": (
            f"Symlink for dev-time auto-load: "
            f"ln -snf ../../skills/{fp['slug']}-text-voice .claude/skills/{fp['slug']}-text-voice "
            f"(or run scripts/dev-link-skills.sh)"
        ),
    }, indent=2))


if __name__ == "__main__":
    main()
