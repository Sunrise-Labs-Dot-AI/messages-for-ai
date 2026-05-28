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
    # Skip variation selectors / ZWJ so ZWJ sequences don't over-count.
    return [c for c in text if is_emoji_char(c)]


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

    texts = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        if args.outbound_only and not m.get("from_me"):
            continue
        t = (m.get("text") or "").strip()
        if t:
            texts.append(t)

    n = len(texts)
    if n == 0:
        print(json.dumps({"error": "no usable messages"}), file=sys.stderr)
        sys.exit(2)

    with_emoji = 0
    total_emoji = 0
    glyphs = Counter()
    period = 0
    all_lower = 0
    laughs = Counter()

    for t in texts:
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

    def pct(x):
        return round(100 * x / n, 1)

    out = {
        "emoji": {
            "pct_messages_with_emoji": pct(with_emoji),
            "emoji_per_message": round(total_emoji / n, 2),
            "top": [{"emoji": g, "count": c} for g, c in glyphs.most_common(8)],
        },
        "style": {
            "pct_end_period": pct(period),
            "pct_all_lowercase": pct(all_lower),
            "laugh_tokens": dict(laughs.most_common(8)),
            "dominant_laugh": (laughs.most_common(1)[0][0] if laughs else None),
            "sample_size": n,
        },
    }

    # Privacy guard: nothing emitted should be a multi-word message body.
    blob = json.dumps(out, ensure_ascii=False)
    for t in texts:
        if " " in t and t in blob:
            print(json.dumps({"error": "privacy guard tripped: a message body in output",
                              "body_length": len(t)}), file=sys.stderr)
            sys.exit(5)

    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
