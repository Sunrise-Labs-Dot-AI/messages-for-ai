#!/usr/bin/env python3
"""build_wrapped.py — render a shareable "Texting Wrapped" from analysis.json.

Takes the same analysis.json the chart generator uses and produces a single,
self-contained wrapped.html: a 7-card swipeable story in an iPhone frame, from
the Claude Design handoff (see DESIGN-HANDOFF.md). The design files
(ios-frame.jsx, treatments.jsx, app.jsx) are the source of truth for the look;
this script just maps real data into them and inlines everything into one file.

Pure stdlib.

Data mapping (analysis.json → card data):
  latency.median_minutes        → median reply
  latency.mean_minutes          → mean reply
  latency.pct_within_5min       → fast %
  ball_in_court.pct_ball_in_court → ball-in-court %
  group_contribution.user_contribution_pct → group share
  group_contribution.groups_where_user_silent / total_groups_analyzed
  group_contribution.per_thread → "top offender" ghost thread (derived)
  archetype                     → derived from the metrics

Honest about gaps in the current analytics:
  - The Volume card needs a total-sent count, which analysis.json doesn't carry
    yet. Pass --total-sent N to include it; otherwise the Volume card is omitted.
  - The Top People card needs contact NAMES — a privacy call. It's omitted unless
    you pass --include-people AND analysis.json has a "top_people" array.

Usage:
  python3 build_wrapped.py --analysis analysis.json --output wrapped.html
  python3 build_wrapped.py --analysis a.json --treatment pager --year 2026 \\
      --total-sent 12400 --include-people --output wrapped.html

Exit codes: 0 ok · 2 input malformed
"""

import argparse
import json
import os
import sys

TREATMENTS = {"sunrise", "receipt", "pager"}
HERE = os.path.dirname(os.path.abspath(__file__))


def derive_worst_ghost(group):
    """Pick the most damning group thread: highest message count where the user
    contributed least (ideally zero). Returns {name, messages, userSent} or None."""
    threads = group.get("per_thread") or []
    if not threads:
        return None
    # Prefer threads the user sent 0 to; among those, the largest. Else the
    # largest thread with the lowest user share.
    zero = [t for t in threads if t.get("user_count", 1) == 0]
    pool = zero or threads
    pick = max(pool, key=lambda t: (t.get("total", 0), -t.get("user_count", 0)))
    return {
        "name": pick.get("thread_label", "a group"),
        "messages": pick.get("total", 0),
        "userSent": pick.get("user_count", 0),
    }


def derive_archetype(median, mean, fast_pct, ball, group_pct, silent, total_groups):
    """Pick the most salient archetype from the metrics. Verdict/why use the
    real numbers so the payoff card is honest, not canned."""
    slow_tail = mean >= max(4 * max(median, 0.1), median + 20)
    if group_pct < 3 and ball >= 80:
        return {
            "name": "The Group Chat Ghost",
            "short": "Ghost",
            "verdict": "present in name, absent in spirit.",
            "why": f"{group_pct:.1f}% group share, silent in {silent} of {total_groups} groups, {ball}% of threads waiting on you.",
        }
    if ball >= 75:
        return {
            "name": "Left-on-Read Royalty",
            "short": "Royalty",
            "verdict": "the throne is built on unanswered threads.",
            "why": f"{ball}% of active threads are waiting on a reply from you.",
        }
    if slow_tail and median <= 10:
        return {
            "name": "The Fast Starter",
            "short": "Fast Starter",
            "verdict": "quick on the draw, slow on the follow-through.",
            "why": f"median reply {median:g} min, but the mean is {mean:g} min — the long tail tells on you.",
        }
    if group_pct < 5:
        return {
            "name": "The Quiet Lurker",
            "short": "Lurker",
            "verdict": "reads everything, says little.",
            "why": f"just {group_pct:.1f}% of group-thread messages, silent in {silent} of {total_groups} groups.",
        }
    if median <= 5:
        return {
            "name": "The Quick Draw",
            "short": "Quick Draw",
            "verdict": "replies before the typing bubble fades.",
            "why": f"median reply {median:g} min, {fast_pct}% within five.",
        }
    return {
        "name": "The Steady Hand",
        "short": "Steady",
        "verdict": "consistent, present, hard to rattle.",
        "why": f"median {median:g} min, {ball}% ball-in-court, {group_pct:.1f}% group share.",
    }


def build_data(analysis, year, total_sent, include_people):
    lat = analysis.get("latency", {})
    bic = analysis.get("ball_in_court", {})
    grp = analysis.get("group_contribution", {})

    median = float(lat.get("median_minutes", 0))
    mean = float(lat.get("mean_minutes", 0))
    fast_pct = int(round(lat.get("pct_within_5min", 0)))
    ball = int(round(bic.get("pct_ball_in_court", 0)))
    group_pct = float(grp.get("user_contribution_pct", 0))
    silent = int(grp.get("groups_where_user_silent", 0))
    total_groups = int(grp.get("total_groups_analyzed", 0))

    archetype = derive_archetype(median, mean, fast_pct, ball, group_pct, silent, total_groups)
    worst_ghost = derive_worst_ghost(grp)

    # Card arc — start with the always-available cards.
    cards = ["cover"]
    if total_sent:
        cards.append("volume")
    top_people = analysis.get("top_people") if include_people else None
    if top_people:
        cards.append("people")
    cards += ["latency", "ballincourt", "groups"]
    emoji = analysis.get("emoji")
    if emoji:
        cards.append("emoji")
    cards += ["archetype", "share"]

    data = {
        "year": year,
        "median": round(median, 1),
        "mean": round(mean, 1),
        "fastPct": fast_pct,
        "ballInCourt": ball,
        "groupContribPct": round(group_pct, 1),
        "silentGroups": silent,
        "totalGroups": total_groups,
        "worstGhost": worst_ghost,
        "archetype": archetype,
        "cards": cards,
    }
    if total_sent:
        data["totalSent"] = int(total_sent)
    if top_people:
        data["topPeople"] = top_people
    if emoji:
        data["emoji"] = emoji
    if analysis.get("style"):
        data["style"] = analysis["style"]
    return data


HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Texting Wrapped {year}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Instrument+Serif:ital@0;1&family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  html, body {{ margin: 0; padding: 0; height: 100%; background: #0a0a0c;
    font-family: 'Inter', system-ui, sans-serif; -webkit-font-smoothing: antialiased;
    text-rendering: geometricPrecision; }}
  #root {{ width: 100%; height: 100%; }}
  * {{ box-sizing: border-box; }}
  button {{ font: inherit; }}
</style>
</head>
<body>
<div id="root"></div>
<script src="https://unpkg.com/react@18.3.1/umd/react.production.min.js" crossorigin></script>
<script src="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js" crossorigin></script>
<script src="https://unpkg.com/@babel/standalone@7.29.0/babel.min.js" crossorigin></script>
<script src="https://unpkg.com/html2canvas@1.4.1/dist/html2canvas.min.js" crossorigin></script>
"""


def main():
    ap = argparse.ArgumentParser(description="Render a shareable Texting Wrapped from analysis.json.")
    ap.add_argument("--analysis", required=True, help="Path to analysis.json.")
    ap.add_argument("--output", required=True, help="Path to write wrapped.html.")
    ap.add_argument("--treatment", default="sunrise", choices=sorted(TREATMENTS),
                    help="Visual treatment (default sunrise).")
    ap.add_argument("--year", type=int, default=2026)
    ap.add_argument("--total-sent", type=int, default=None,
                    help="Total texts sent — enables the Volume card (analysis.json lacks this).")
    ap.add_argument("--include-people", action="store_true",
                    help="Include the Top People card (needs contact NAMES — a privacy choice). "
                         "Requires a 'top_people' array in analysis.json.")
    args = ap.parse_args()

    try:
        with open(args.analysis) as f:
            analysis = json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": "analysis file not found", "path": args.analysis}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    data = build_data(analysis, args.year, args.total_sent, args.include_people)

    # Read the design files (source of truth for the look). Tweaks-panel is the
    # dev-only treatment switcher and is intentionally NOT inlined into the
    # shipped artifact — the treatment is fixed at generation time.
    def read(name):
        with open(os.path.join(HERE, name), encoding="utf-8") as f:
            return f.read()

    try:
        ios = read("ios-frame.jsx")
        treatments = read("treatments.jsx")
        app = read("app.jsx")
    except FileNotFoundError as e:
        print(json.dumps({"error": "design file missing", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    data_js = json.dumps(data, ensure_ascii=False)
    parts = [
        HEAD.format(year=args.year),
        f'<script>window.WRAPPED_DATA = {data_js}; window.WRAPPED_TREATMENT = {json.dumps(args.treatment)};</script>',
        f'<script type="text/babel">\n{ios}\n</script>',
        f'<script type="text/babel">\n{treatments}\n</script>',
        f'<script type="text/babel">\n{app}\n</script>',
        "</body>\n</html>\n",
    ]
    html = "\n".join(parts)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(html)

    print(json.dumps({
        "status": "ok",
        "output": args.output,
        "treatment": args.treatment,
        "cards": data["cards"],
        "archetype": data["archetype"]["name"],
        "note": (None if args.total_sent else
                 "Volume card omitted (no --total-sent). People card omitted unless --include-people + top_people present."),
    }, indent=2))


if __name__ == "__main__":
    main()
