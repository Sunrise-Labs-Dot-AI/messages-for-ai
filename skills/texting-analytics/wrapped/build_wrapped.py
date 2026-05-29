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
    contributed least (ideally zero). Returns {name, messages, userSent} or
    None. Prefers the `worst_offender` block emitted by analyze.py (computed
    over the FULL group set); falls back to scanning per_thread for older
    analyses that didn't emit it (per_thread is truncated to top-12 by user
    contribution, so silent groups can be missing — the fallback is best-
    effort)."""
    pick = group.get("worst_offender")
    if not pick:
        threads = group.get("per_thread") or []
        if not threads:
            return None
        zero = [t for t in threads if t.get("user_count", 1) == 0]
        pool = zero or threads
        pick = max(pool, key=lambda t: (t.get("total", 0), -t.get("user_count", 0)))
    return {
        "name": pick.get("thread_label", "a group"),
        "messages": pick.get("total", 0),
        "userSent": pick.get("user_count", 0),
    }


def derive_archetype(median, mean, fast_pct, ball, group_pct, silent, total_groups, emoji_pct=0):
    """Pick the most salient archetype. Priority-ordered: first match wins, most
    distinctive/spicy first. Verdict/why use the real numbers so it's honest."""
    slow_tail = mean >= max(4 * max(median, 0.1), median + 20)
    A = lambda name, short, verdict, why: {"name": name, "short": short, "verdict": verdict, "why": why}

    if group_pct < 3 and ball >= 80:
        return A("The Group Chat Ghost", "Ghost", "present in name, absent in spirit.",
                 f"{group_pct:.1f}% group share, silent in {silent} of {total_groups} groups, {ball}% of threads waiting on you.")
    if ball >= 75:
        return A("Left-on-Read Royalty", "Royalty", "the throne is built on unanswered threads.",
                 f"{ball}% of active threads are waiting on a reply from you.")
    if ball <= 20:
        return A("The Closer", "Closer", "inbox zero, but make it texting.",
                 f"only {ball}% of threads are waiting on you — you finish what you start.")
    if group_pct >= 30:
        return A("The Group MVP", "MVP", "the group chat would collapse without you.",
                 f"you send {group_pct:.1f}% of all group-thread messages — far above an even share.")
    if emoji_pct >= 45:
        return A("The Emoji Maximalist", "Maximalist", "why use words when a face will do.",
                 f"{emoji_pct:.0f}% of your texts carry an emoji.")
    if slow_tail and median <= 10:
        return A("The Fast Starter", "Fast Starter", "quick on the draw, slow on the follow-through.",
                 f"median reply {median:g} min, but the mean is {mean:g} min — the long tail tells on you.")
    if median <= 3:
        return A("The Quick Draw", "Quick Draw", "replies before the typing bubble fades.",
                 f"median reply {median:g} min, {fast_pct}% within five.")
    if group_pct < 5:
        return A("The Quiet Lurker", "Lurker", "reads everything, says little.",
                 f"just {group_pct:.1f}% of group-thread messages, silent in {silent} of {total_groups} groups.")
    return A("The Steady Hand", "Steady", "consistent, present, hard to rattle.",
             f"median {median:g} min, {ball}% ball-in-court, {group_pct:.1f}% group share.")


def build_data(analysis, year, total_sent, show_people):
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
    emoji_pct = float(analysis.get("emoji", {}).get("pct_messages_with_emoji", 0))

    archetype = derive_archetype(median, mean, fast_pct, ball, group_pct, silent, total_groups, emoji_pct)
    worst_ghost = derive_worst_ghost(grp)

    # Card arc — start with the always-available cards.
    cards = ["cover"]
    if total_sent:
        cards.append("volume")
    # Top people: included whenever analyze.py produced the list (it's a
    # personal "keep" card). show_people=False suppresses it (e.g. public share).
    top_people = analysis.get("top_people") if show_people else None
    top_people_by_chars = analysis.get("top_people_by_chars") if show_people else None
    if top_people:
        cards.append("people")
    top_people_l30 = analysis.get("top_people_l30") if show_people else None
    if top_people_l30:
        # Second People card — same surface, restricted to the LAST 30 DAYS.
        # Pairs with the past-year ranking to show what's hot right now.
        cards.append("people_l30")
    talk_listen = analysis.get("talk_listen") if show_people else None
    if talk_listen and talk_listen.get("you_words") and talk_listen.get("them_words"):
        # Third People-adjacent card — aggregate talker/listener ratio + per-
        # person outliers. Highlights surface names → personal-only.
        cards.append("talk_listen")
    cards += ["latency", "ballincourt", "groups"]
    emoji = analysis.get("emoji")
    if emoji:
        cards.append("emoji")
    age = analysis.get("age")
    if age:
        cards.append("age")
    cards += ["archetype", "share"]

    # Window label: "May 2025 — May 2026" for a year-bounded analysis, "All
    # time" if the analyze step ran with --window-days 0. Lets the wrapped
    # show the actual data range instead of anchoring to a single calendar
    # year (a Wrapped run in mid-2026 should say so).
    import datetime as _dt
    f = analysis.get("filters", {}) or {}
    since_ms, until_ms = f.get("since_ts_ms"), f.get("until_ts_ms")
    window_days = f.get("window_days")
    if window_days == 0 or since_ms in (None, 0):
        window_label = "All time"
    elif until_ms:
        start = _dt.datetime.fromtimestamp(since_ms / 1000)
        end = _dt.datetime.fromtimestamp(until_ms / 1000)
        window_label = f"{start.strftime('%b %Y')} — {end.strftime('%b %Y')}"
    else:
        window_label = str(year)

    data = {
        "year": year,
        "windowLabel": window_label,
        "windowDays": window_days if window_days is not None else 365,
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
    if top_people_l30:
        data["topPeopleL30"] = top_people_l30
    if talk_listen and talk_listen.get("you_words") and talk_listen.get("them_words"):
        data["talkListen"] = talk_listen
    if emoji:
        data["emoji"] = emoji
    if analysis.get("style"):
        data["style"] = analysis["style"]
    if age:
        data["age"] = age
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
    ap.add_argument("--no-people", action="store_true",
                    help="Suppress the Top People card (it shows contact NAMES — pass this "
                         "when generating a Wrapped meant for public sharing).")
    ap.add_argument("--toggle-href", default=None,
                    help="If set, include a toggle button (top-right of the page chrome) "
                         "that navigates to this URL — used to jump between the past-year "
                         "and all-time views of the same wrapped.")
    ap.add_argument("--toggle-label", default=None,
                    help="Label for the toggle button (e.g. 'All time' or 'Past year'). "
                         "Required when --toggle-href is set.")
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

    data = build_data(analysis, args.year, args.total_sent, show_people=not args.no_people)

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
    toggle_js = ""
    if args.toggle_href and args.toggle_label:
        toggle_js = (f"window.WRAPPED_TOGGLE = "
                     f"{json.dumps({'href': args.toggle_href, 'label': args.toggle_label})};")
    parts = [
        HEAD.format(year=args.year),
        f'<script>window.WRAPPED_DATA = {data_js}; window.WRAPPED_TREATMENT = {json.dumps(args.treatment)}; {toggle_js}</script>',
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
                 "Volume card omitted (no --total-sent). Top People shows when analysis.json has top_people (suppress with --no-people)."),
    }, indent=2))


if __name__ == "__main__":
    main()
