#!/usr/bin/env python3
"""emoji_stats.py — aggregate emoji + writing-style stats from message text.

PRIVACY: reads text in memory and emits ONLY aggregates — counts, percentages,
single emoji glyphs, and short slang/laugh tokens. It never writes a message
body. Same no-bodies invariant as texting-voice-skill-creator/analyze_voice.py;
a guard checks the output before printing.

This is the one place the analytics reads message CONTENT (the rest of the
pipeline is metadata-only). Feed it the messages the MCP already pulled.

Input JSON: array of { "text": "...", "from_me": true|false? }.
  Default counts ALL messages; --outbound-only restricts to from_me=true.

Output JSON (merge into analysis.json):
  {
    "emoji": { "pct_messages_with_emoji", "emoji_per_message", "top": [{emoji,count}] },
    "style": { "pct_end_period", "pct_all_lowercase", "laugh_tokens": {...},
               "dominant_laugh", "sample_size" }
  }

Exit codes: 0 ok · 2 input malformed · 5 privacy guard tripped
"""

import argparse
import json
import re
import sys
import unicodedata
from collections import Counter

# Laugh tokens — word forms + the emoji that stand in for laughing. Generational
# signal (feeds the future age-estimate card) and fun on its own.
LAUGH_PATTERNS = {
    "haha": r"\b(?:ha){2,}h?\b",
    "hehe": r"\b(?:he){2,}\b",
    "lol": r"\blol\b",
    "lmao": r"\blmao+\b",
    "lmfao": r"\blmfao+\b",
    "rofl": r"\brofl\b",
}
LAUGH_EMOJI = {"😂": "joy", "🤣": "rofl", "💀": "skull", "😭": "sob"}

# Canonical emoji for the legacy iMessage tapback types. 2006 is "Reacted
# with a custom emoji" — the actual emoji is parsed from the reaction body.
TAPBACK_EMOJI = {
    2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂",
    2004: "‼️", 2005: "❓",
    # 2006 → custom; 2007 → sticker (skip from emoji counts)
}

# Slang phrase counts (whole-word / phrase matches). Generational signal that
# sharpens the age estimate — counting tokens, never storing message bodies.
GENZ_SLANG = [r"\brizz\b", r"\bskibidi\b", r"\bno cap\b", r"\bfr fr\b", r"\bbussin\b",
              r"\bgyatt?\b", r"\bdelulu\b", r"\bmid\b", r"\bate\b", r"\bslay\b"]
AGING_SLANG = [r"\blit\b", r"\btbh\b", r"\bngl\b", r"\blowkey\b", r"\bhighkey\b",
               r"\bsus\b", r"\byeet\b", r"\bsalty\b", r"\bextra\b"]


def is_emoji_char(c):
    if not c:
        return False
    cp = ord(c)
    if cp < 0x2000:
        return False
    if unicodedata.category(c) == "So":
        return True
    if 0x1F000 <= cp <= 0x1FFFF:
        return True
    if 0x2600 <= cp <= 0x27BF:
        return True
    return False


def extract_emoji(text):
    # Skip variation selectors / ZWJ so ZWJ sequences don't over-count. Also
    # skip U+FFFC (object replacement character — iMessage uses it as a
    # placeholder for attachments). It would dominate the inline-emoji top
    # otherwise.
    return [c for c in text if is_emoji_char(c) and c != "￼"]


def end_period(text):
    s = text.rstrip()
    while s and (is_emoji_char(s[-1]) or s[-1].isspace()):
        s = s[:-1].rstrip()
    return bool(s) and s.endswith(".") and not s.endswith("..")


def main():
    ap = argparse.ArgumentParser(description="Aggregate emoji + style stats from message text.")
    ap.add_argument("--input", required=True, help="Path to messages JSON ([{text, from_me?}, ...]).")
    ap.add_argument("--outbound-only", action="store_true", help="Count only from_me=true messages.")
    args = ap.parse_args()

    try:
        with open(args.input, encoding="utf-8") as f:
            messages = json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": "file not found", "path": args.input}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)
    if not isinstance(messages, list):
        print(json.dumps({"error": "expected a JSON array"}), file=sys.stderr)
        sys.exit(2)

    # Split messages by KIND. Reactions get their emoji counted into a separate
    # bucket — a 👍 tapback is qualitatively different from a 👍 typed inline.
    # Style + slang stats only consider inline text (kind != "reaction").
    inline_texts = []
    reaction_emoji = Counter()
    for m in messages:
        if not isinstance(m, dict):
            continue
        if args.outbound_only and not m.get("from_me"):
            continue
        kind = m.get("kind")
        if kind == "reaction":
            # Map known tapback codes to their canonical emoji; for "custom
            # emoji" reactions (2006) and any unknown codes, parse the body.
            assoc = m.get("assoc")
            if assoc in TAPBACK_EMOJI:
                reaction_emoji[TAPBACK_EMOJI[assoc]] += 1
            else:
                body = (m.get("text") or "").strip()
                emo = extract_emoji(body)
                if emo:
                    # Take the FIRST emoji — reaction bodies look like
                    # "Reacted 😂 to '<original>'", so the first emoji is the
                    # reaction itself, not anything from the quoted message.
                    reaction_emoji[emo[0]] += 1
            continue
        if kind and kind not in ("text", "media"):
            continue
        t = (m.get("text") or "").strip()
        if t:
            inline_texts.append(t)

    n = len(inline_texts)
    if n == 0:
        print(json.dumps({"error": "no usable messages"}), file=sys.stderr)
        sys.exit(2)

    with_emoji = 0
    total_emoji = 0
    glyphs = Counter()
    period = 0
    all_lower = 0
    laughs = Counter()
    genz_hits = aging_hits = ellipsis_msgs = rexcl_msgs = emoji_end_msgs = 0

    for t in inline_texts:
        emo = extract_emoji(t)
        if emo:
            with_emoji += 1
            total_emoji += len(emo)
            glyphs.update(emo)
        if end_period(t):
            period += 1
        if not any(c.isupper() for c in t):
            all_lower += 1
        lower = t.lower()
        for name, pat in LAUGH_PATTERNS.items():
            c = len(re.findall(pat, lower))
            if c:
                laughs[name] += c
        for ch in t:
            if ch in LAUGH_EMOJI:
                laughs[LAUGH_EMOJI[ch]] += 1
        # phrase / punctuation signals
        genz_hits += sum(1 for p in GENZ_SLANG if re.search(p, lower))
        aging_hits += sum(1 for p in AGING_SLANG if re.search(p, lower))
        if "..." in t or "…" in t:
            ellipsis_msgs += 1
        if re.search(r"[!?]{2,}", t):
            rexcl_msgs += 1
        stripped = t.rstrip()
        if stripped and is_emoji_char(stripped[-1]):
            emoji_end_msgs += 1

    def pct(x):
        return round(100 * x / n, 1)

    out = {
        "emoji": {
            "pct_messages_with_emoji": pct(with_emoji),
            "emoji_per_message": round(total_emoji / n, 2),
            "top_inline": [{"emoji": g, "count": c} for g, c in glyphs.most_common(8)],
            "top_reactions": [{"emoji": g, "count": c} for g, c in reaction_emoji.most_common(8)],
            # legacy field — kept for back-compat with any downstream consumer
            # that hasn't migrated to top_inline yet.
            "top": [{"emoji": g, "count": c} for g, c in glyphs.most_common(8)],
        },
        "style": {
            "pct_end_period": pct(period),
            "pct_all_lowercase": pct(all_lower),
            "laugh_tokens": dict(laughs.most_common(8)),
            "dominant_laugh": (laughs.most_common(1)[0][0] if laughs else None),
            "genz_slang_hits": genz_hits,
            "aging_slang_hits": aging_hits,
            "pct_ellipsis": pct(ellipsis_msgs),
            "pct_repeated_exclaim": pct(rexcl_msgs),
            "pct_emoji_ending": pct(emoji_end_msgs),
            "sample_size": n,
        },
    }

    # Privacy guard: nothing emitted should be a multi-word message body.
    # Check inline_texts (reaction bodies aren't included in output, only the
    # first emoji is, so they're safe).
    blob = json.dumps(out, ensure_ascii=False)
    for t in inline_texts:
        if " " in t and t in blob:
            print(json.dumps({"error": "privacy guard tripped: a message body in output",
                              "body_length": len(t)}), file=sys.stderr)
            sys.exit(5)

    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
