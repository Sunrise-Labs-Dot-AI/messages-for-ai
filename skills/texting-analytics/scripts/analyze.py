#!/usr/bin/env python3
"""Generalized analytics core: normalized message export(s) -> analysis.json.

Platform-agnostic. Consumes ONLY the normalized_messages contract (v1.0) and knows
nothing about iMessage or WhatsApp. Accepts one or more exports and merges them, so a
cross-platform Wrapped is just `--input imessage.json whatsapp.json`.

Output matches the analysis.json schema that build_charts.py renders.
"""
import argparse, json, re, statistics, time

SUBSTANTIVE = {"text", "media"}
REPLY_CAP_MIN = 960  # 16h: longer gaps are conversation death, not a reply
TOLLFREE_NPAS = {"800", "833", "844", "855", "866", "877", "888"}


def counterparty_class(sender_key):
    """Body-free classification of a 1:1 counterparty from its normalized sender_key.
    Returns 'person' | 'shortcode' | 'tollfree' | 'alpha'. Business = the non-person ones.
    NOTE: the strongest business signal (not-in-contacts AND never-replied) needs an
    adapter-supplied `in_contacts` flag; this covers the pattern-detectable cases."""
    if not sender_key or "@" in sender_key:
        return "person"
    digits = sender_key.lstrip("+")
    if digits.isdigit():
        if 3 <= len(digits) <= 6:
            return "shortcode"
        npa = digits[1:4] if (len(digits) == 11 and digits[0] == "1") else digits[0:3]
        return "tollfree" if npa in TOLLFREE_NPAS else "person"
    if re.search("[A-Za-z]", sender_key):
        return "alpha"  # alphanumeric sender ID (AMAZON, Uber, VERIFY...)
    return "person"


def business_thread_ids(threads, events):
    """1:1 threads whose counterparty looks automated/business (pattern-based)."""
    counterparty = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"] or e["from_me"]:
            continue
        counterparty.setdefault(e["thread_id"], e.get("sender_key"))
    return {tid for tid, sk in counterparty.items()
            if counterparty_class(sk) != "person"}


def size_bucket(participant_count, large_min=6):
    if participant_count is None:
        return "unknown"
    if participant_count <= 2:
        return "one_to_one"
    return "small" if participant_count < large_min else "large"


def load(paths):
    threads, events = {}, []
    for p in paths:
        d = json.load(open(p))
        for t in d["threads"]:
            threads[t["thread_id"]] = t
        events.extend(d["events"])
    return threads, events


def latency_block(threads, events):
    """How fast the user replies, over 1:1 threads, substantive messages only."""
    by_thread = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"] or e["kind"] not in SUBSTANTIVE:
            continue
        by_thread.setdefault(e["thread_id"], []).append(e)
    deltas, tcount = [], 0
    for evs in by_thread.values():
        evs.sort(key=lambda e: e["ts_ms"])
        had = False
        for i, e in enumerate(evs):
            if e["from_me"]:
                continue
            nxt = next((x for x in evs[i + 1:] if x["from_me"]), None)
            if nxt:
                d = (nxt["ts_ms"] - e["ts_ms"]) / 60000.0
                if 0 < d < REPLY_CAP_MIN:
                    deltas.append(d)
                    had = True
        if had:
            tcount += 1
    n = len(deltas)
    pct = lambda thr: round(100 * sum(1 for d in deltas if d <= thr) / n, 1) if n else 0
    return {
        "total_reply_pairs": n,
        "pct_within_5min": pct(5), "pct_within_30min": pct(30),
        "pct_within_1hr": pct(60), "pct_within_4hr": pct(240),
        "mean_minutes": round(statistics.mean(deltas), 1) if n else 0,
        "median_minutes": round(statistics.median(deltas), 1) if n else 0,
        "thread_count": tcount, "window_label": "past 24 months",
    }


def ball_block(threads, events, until_ms):
    last = {}
    for e in events:
        cur = last.get(e["thread_id"])
        if cur is None or e["ts_ms"] > cur["ts_ms"]:
            last[e["thread_id"]] = e
    recent = sorted(last.items(), key=lambda kv: kv[1]["ts_ms"], reverse=True)[:100]
    sampled = len(recent)
    bic = sum(1 for _, e in recent if not e["from_me"])
    live = sum(1 for _, e in recent if (until_ms - e["ts_ms"]) <= 30 * 86400 * 1000)
    return {
        "total_threads_sampled": sampled,
        "threads_with_ball_in_court": bic,
        "pct_ball_in_court": round(100 * bic / sampled, 1) if sampled else 0,
        "live_conversations_estimate": live,
        "snapshot_label": "now",
    }


def group_block(threads, events, min_msgs=20, large_min=6):
    groups = {tid: t for tid, t in threads.items() if t["is_group"]}
    per = {}
    for e in events:
        if e["thread_id"] not in groups:
            continue
        d = per.setdefault(e["thread_id"], dict(total=0, user=0, user_react=0, peer=0, peer_react=0))
        react = e["kind"] == "reaction"
        d["total"] += 1
        if e["from_me"]:
            d["user"] += 1; d["user_react"] += int(react)
        else:
            d["peer"] += 1; d["peer_react"] += int(react)
    # Keep only groups with real activity; 1-2 message "groups" are noise.
    per = {tid: d for tid, d in per.items() if d["total"] >= min_msgs}
    tot = sum(d["total"] for d in per.values())
    um = sum(d["user"] for d in per.values())
    ur = sum(d["user_react"] for d in per.values())
    pm = sum(d["peer"] for d in per.values())
    pr = sum(d["peer_react"] for d in per.values())
    per_thread, silent, mostly = [], 0, 0
    buckets = {}  # size bucket -> rollup
    for tid, d in per.items():
        pc = groups[tid].get("participant_count")
        bucket = size_bucket(pc, large_min)
        b = buckets.setdefault(bucket, dict(groups=0, total=0, user=0))
        b["groups"] += 1; b["total"] += d["total"]; b["user"] += d["user"]
        if d["user"] == 0:
            silent += 1
        if d["user"] and d["user_react"] / d["user"] >= 0.5:
            mostly += 1
        upct = round(100 * d["user"] / d["total"], 1) if d["total"] else 0
        # fair-share ratio: your share vs an even split (1/N). 1.0 = even, <1 = lurking.
        fair = round(upct / (100.0 / pc), 2) if (pc and pc > 1 and d["total"]) else None
        per_thread.append({
            "thread_label": groups[tid].get("display_name") or tid,
            "participant_count": pc, "size": bucket,
            "total": d["total"], "user_count": d["user"],
            "user_pct": upct, "fair_share_ratio": fair,
            "user_reaction_pct": round(100 * d["user_react"] / d["user"], 1) if d["user"] else 0,
        })
    per_thread.sort(key=lambda x: x["user_pct"], reverse=True)
    per_thread = per_thread[:12]  # chart readability; aggregates below still cover all groups
    by_size = {b: {"groups": v["groups"],
                   "contribution_pct": round(100 * v["user"] / v["total"], 1) if v["total"] else 0}
               for b, v in buckets.items()}
    return {
        "total_groups_analyzed": len(per),
        "total_messages_in_groups": tot,
        "user_messages_in_groups": um,
        "user_contribution_pct": round(100 * um / tot, 1) if tot else 0,
        "user_reaction_rate_pct": round(100 * ur / um, 1) if um else 0,
        "peer_reaction_rate_pct": round(100 * pr / pm, 1) if pm else 0,
        "groups_where_user_silent": silent,
        "groups_mostly_reactions": mostly,
        "by_size": by_size,
        "per_thread": per_thread,
    }


def top_people_block(threads, events, limit=10):
    """Most-texted 1:1 people by total message volume, across all platforms
    (events are already merged). Name comes from the thread's display_name
    (the MCP resolves real contact names in production; the harness may show a
    handle). For the user's own view — keep it out of any shared composite."""
    counts = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"]:
            continue
        counts[e["thread_id"]] = counts.get(e["thread_id"], 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:limit]
    return [{"name": threads.get(tid, {}).get("display_name") or tid, "count": c}
            for tid, c in ranked]


def top_people_by_chars_block(threads, events, limit=10):
    """Same 1:1 ranking but summed by character volume (text_len) instead of
    message count. Surfaces the people you actually wrote PARAGRAPHS to vs. the
    rapid-fire short-text relationships. Metadata-only: we only have the per-
    message text LENGTH, never the body."""
    chars = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"]:
            continue
        n = e.get("text_len") or 0
        if n <= 0:
            continue
        chars[e["thread_id"]] = chars.get(e["thread_id"], 0) + n
    ranked = sorted(chars.items(), key=lambda kv: kv[1], reverse=True)[:limit]
    return [{"name": threads.get(tid, {}).get("display_name") or tid, "chars": c}
            for tid, c in ranked]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", nargs="+", required=True, help="one or more normalized exports")
    ap.add_argument("--output", required=True)
    ap.add_argument("--large-min", type=int, default=6, help="participant count at which a group is 'large'")
    ap.add_argument("--keep-business", action="store_true", help="don't filter automated/business 1:1 threads")
    a = ap.parse_args()
    threads, events = load(a.input)
    biz = set() if a.keep_business else business_thread_ids(threads, events)
    if biz:
        events = [e for e in events if e["thread_id"] not in biz]
        threads = {tid: t for tid, t in threads.items() if tid not in biz}
    until_ms = max((e["ts_ms"] for e in events), default=int(time.time() * 1000))
    out = {
        "latency": latency_block(threads, events),
        "ball_in_court": ball_block(threads, events, until_ms),
        "group_contribution": group_block(threads, events, large_min=a.large_min),
        "top_people": top_people_block(threads, events),
        "top_people_by_chars": top_people_by_chars_block(threads, events),
        "filters": {"excluded_business_1to1_threads": len(biz)},
    }
    json.dump(out, open(a.output, "w"), indent=2)
    print(f"[analyze] threads={len(threads)} events={len(events)} biz_excluded={len(biz)} -> {a.output}")


if __name__ == "__main__":
    main()
