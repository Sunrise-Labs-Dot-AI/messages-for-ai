#!/usr/bin/env python3
"""qa_fixtures.py — synthetic users covering every Texting Wrapped archetype.

Generates one analysis.json per archetype (crafted to trip each branch of
build_wrapped.derive_archetype), writes them to examples/archetypes/ as reusable
committed fixtures, then renders each to a clickable wrapped.html preview under
dist/wrapped-preview/fixtures/ (gitignored) plus an index. Use this to QA the
whole card system across the full range of real-world texters in one pass.

Run:  python3 qa_fixtures.py        (then open the printed fixtures/index.html)
"""

import json
import os
import subprocess
import sys

import build_wrapped  # same dir

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FIXTURES = os.path.join(HERE, "..", "examples", "archetypes")
OUT = os.path.join(REPO, "dist", "wrapped-preview", "fixtures")


TOP_PEOPLE = [
    {"name": "Maya Chen", "count": 2847}, {"name": "Daniel Park", "count": 1962},
    {"name": "Jordan Reyes", "count": 1403}, {"name": "Sophie Liu", "count": 982},
    {"name": "Alex Whitman", "count": 711}, {"name": "Priya Nair", "count": 640},
    {"name": "Sam Okafor", "count": 588}, {"name": "Lena Fischer", "count": 502},
    {"name": "Marcus Bell", "count": 477}, {"name": "Nina Alvarez", "count": 401},
]


def analysis(median, mean, fast, ball, group_pct, silent, total_groups, worst_total, worst_user, emoji_pct=23.0):
    """Build a schema-complete analysis.json for a synthetic user."""
    return {
        "top_people": TOP_PEOPLE,
        "latency": {
            "total_reply_pairs": 800, "pct_within_5min": fast, "pct_within_30min": min(fast + 20, 95),
            "pct_within_1hr": min(fast + 30, 97), "pct_within_4hr": min(fast + 45, 99),
            "mean_minutes": mean, "median_minutes": median, "thread_count": 90,
            "window_label": "past 12 months",
        },
        "ball_in_court": {
            "total_threads_sampled": 100, "threads_with_ball_in_court": ball,
            "pct_ball_in_court": ball, "live_conversations_estimate": 40, "snapshot_label": "May 2026",
        },
        "group_contribution": {
            "total_groups_analyzed": total_groups, "total_messages_in_groups": 900,
            "user_messages_in_groups": int(900 * group_pct / 100), "user_contribution_pct": group_pct,
            "user_reaction_rate_pct": 30, "peer_reaction_rate_pct": 32,
            "groups_where_user_silent": silent, "groups_mostly_reactions": 5,
            "per_thread": [
                {"thread_label": "the worst offender crew", "total": worst_total,
                 "user_count": worst_user, "user_pct": 0, "user_reaction_pct": 0},
                {"thread_label": "weekend plans", "total": 60, "user_count": 14, "user_pct": 23, "user_reaction_pct": 10},
            ],
        },
        "emoji": {
            "pct_messages_with_emoji": emoji_pct, "emoji_per_message": round(emoji_pct / 56, 2),
            "top": [{"emoji": "😂", "count": 612}, {"emoji": "❤️", "count": 388},
                    {"emoji": "🙏", "count": 201}, {"emoji": "🔥", "count": 144},
                    {"emoji": "😭", "count": 97}],
        },
        "style": {
            "pct_end_period": 9.0, "pct_all_lowercase": 61.0,
            "laugh_tokens": {"lol": 240, "haha": 180, "joy": 612}, "dominant_laugh": "joy",
            "sample_size": 4000,
        },
    }


# (key, treatment, total_sent|None, expected_archetype, analysis)
SCENARIOS = [
    ("ghost",        "pager",   None,  "The Group Chat Ghost",
     analysis(median=8,  mean=90, fast=44, ball=93, group_pct=0.7, silent=12, total_groups=15, worst_total=1589, worst_user=0)),
    ("royalty",      "sunrise", 9800,  "Left-on-Read Royalty",
     analysis(median=9,  mean=30, fast=40, ball=82, group_pct=12,  silent=3,  total_groups=14, worst_total=120, worst_user=2)),
    ("fast_starter", "receipt", None,  "The Fast Starter",
     analysis(median=4,  mean=77, fast=47, ball=60, group_pct=8.8, silent=2,  total_groups=19, worst_total=48,  worst_user=0)),
    ("lurker",       "pager",   None,  "The Quiet Lurker",
     analysis(median=12, mean=25, fast=20, ball=55, group_pct=4,   silent=8,  total_groups=14, worst_total=200, worst_user=0)),
    ("quick_draw",   "sunrise", 14200, "The Quick Draw",
     analysis(median=3,  mean=8,  fast=72, ball=45, group_pct=18,  silent=1,  total_groups=10, worst_total=80,  worst_user=3)),
    ("steady",       "receipt", None,  "The Steady Hand",
     analysis(median=18, mean=30, fast=22, ball=50, group_pct=22,  silent=1,  total_groups=12, worst_total=70,  worst_user=6)),
    ("closer",       "pager",   None,  "The Closer",
     analysis(median=10, mean=20, fast=45, ball=12, group_pct=15,  silent=2,  total_groups=12, worst_total=90,  worst_user=4)),
    ("mvp",          "sunrise", 11200, "The Group MVP",
     analysis(median=6,  mean=15, fast=50, ball=45, group_pct=38,  silent=0,  total_groups=8,  worst_total=60,  worst_user=20)),
    ("maximalist",   "receipt", None,  "The Emoji Maximalist",
     analysis(median=5,  mean=12, fast=55, ball=40, group_pct=15,  silent=1,  total_groups=10, worst_total=70,  worst_user=5, emoji_pct=52.0)),
]


def archetype_of(a):
    lat, bic, grp = a["latency"], a["ball_in_court"], a["group_contribution"]
    return build_wrapped.derive_archetype(
        float(lat["median_minutes"]), float(lat["mean_minutes"]), lat["pct_within_5min"],
        bic["pct_ball_in_court"], grp["user_contribution_pct"],
        grp["groups_where_user_silent"], grp["total_groups_analyzed"],
        a.get("emoji", {}).get("pct_messages_with_emoji", 0),
    )["name"]


def main():
    os.makedirs(FIXTURES, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    rows, links, mismatches = [], [], 0

    for key, treatment, total_sent, expected, a in SCENARIOS:
        fpath = os.path.join(FIXTURES, f"{key}.json")
        with open(fpath, "w") as f:
            json.dump(a, f, indent=2)

        # Merge a playful texting-age block (age_estimate reads style/latency).
        age_cmd = [sys.executable, os.path.join(HERE, "..", "scripts", "age_estimate.py"), "--analysis", fpath]
        if total_sent:
            age_cmd += ["--total-sent", str(total_sent)]
        age_out = subprocess.run(age_cmd, capture_output=True, text=True)
        if age_out.returncode == 0:
            a["age"] = json.loads(age_out.stdout)["age"]
            with open(fpath, "w") as f:
                json.dump(a, f, indent=2)

        got = archetype_of(a)
        ok = got == expected
        mismatches += 0 if ok else 1

        html = os.path.join(OUT, f"{key}.html")
        cmd = [sys.executable, os.path.join(HERE, "build_wrapped.py"),
               "--analysis", fpath, "--treatment", treatment, "--output", html]
        if total_sent:
            cmd += ["--total-sent", str(total_sent)]
        subprocess.run(cmd, check=True, capture_output=True)

        rows.append(f"  {'✓' if ok else '✗'} {key:<13} {treatment:<8} → {got}"
                    + ("" if ok else f"  (expected {expected})"))
        links.append(f'<li><a href="{key}.html">{key}</a> — {got} · {treatment}'
                     + (" · +volume" if total_sent else "") + "</li>")

    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write("<!doctype html><meta charset=utf-8><title>Wrapped QA fixtures</title>"
                "<style>body{font:16px system-ui;background:#111;color:#eee;padding:40px;max-width:640px;margin:auto}"
                "a{color:#7cf}li{margin:8px 0}</style>"
                "<h1>Texting Wrapped — archetype QA fixtures</h1>"
                "<p>One synthetic user per archetype. Open each, swipe the cards (←/→), test Share.</p><ul>"
                + "".join(links) + "</ul>")

    print("\n".join(rows))
    print(f"\nfixtures: {os.path.relpath(FIXTURES, REPO)}/  ·  previews: {os.path.relpath(OUT, REPO)}/index.html")
    if mismatches:
        print(f"\n✗ {mismatches} archetype mismatch(es) — derive_archetype and the fixtures disagree.")
        sys.exit(1)
    print(f"\n✓ all {len(SCENARIOS)} archetypes rendered and matched.")


if __name__ == "__main__":
    main()
