#!/usr/bin/env python3
"""iMessage adapter: chat.db -> normalized message export (contract v1.0).

Service-specific retrieve + normalize ONLY. Metadata only: reads LENGTH(text), never the
text. Opens read-only + immutable (no WAL/lock/dir writes), so it works against a snapshot.

In production this logic lives in the signed MCP (which holds Full Disk Access). This
Python form is the validation harness: point --db at a readable chat.db snapshot.
"""
import argparse, json, os, sqlite3, sys, time

APPLE_EPOCH = 978307200
DEFAULT_DB = os.path.expanduser("~/Library/Messages/chat.db")


def apple_to_ms(d):
    if d is None:
        return None
    secs = d / 1e9 if abs(d) > 1e12 else d  # post-High-Sierra ns vs legacy seconds
    return int(round((secs + APPLE_EPOCH) * 1000))


def norm_handle(hid):
    if not hid:
        return None
    if "@" in hid:
        return hid.lower()
    digits = hid.lstrip("+")
    if digits.isdigit():
        return "+" + digits
    return hid


def kind_for(assoc, item_type, has_attach, tlen, has_body):
    if assoc and 2000 <= assoc <= 3999:   # tapbacks (added 2000-2005, removed 3000-3007)
        return "reaction"
    if item_type and item_type != 0:       # group-name change, participant add/leave, etc.
        return "system"
    if has_attach:
        return "media"
    # Modern macOS stores the body in attributedBody (binary plist), leaving
    # `text` NULL. So a message with no attachment and either a text column OR
    # an attributedBody is a real text message; only genuinely empty rows fall through.
    if tlen or has_body:
        return "text"
    return "other"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--since-days", type=int, default=730)
    ap.add_argument("--output", default="-")
    a = ap.parse_args()

    since_days = min(a.since_days, 730)
    until_ms = int(time.time() * 1000)
    since_ms = until_ms - since_days * 86400 * 1000
    since_ns = int((since_ms / 1000.0 - APPLE_EPOCH) * 1e9)

    con = sqlite3.connect(f"file:{a.db}?mode=ro&immutable=1", uri=True)
    con.row_factory = sqlite3.Row

    # Thread dimension: chat + participant counts.
    pcount = {r["chat_id"]: r["n"] for r in con.execute(
        "SELECT chat_id, COUNT(*) AS n FROM chat_handle_join GROUP BY chat_id")}
    threads, rowid_to_tid = [], {}
    for r in con.execute("SELECT ROWID, guid, style, display_name, chat_identifier FROM chat"):
        is_group = (r["style"] == 43)
        tid = f"imessage:{r['guid']}"
        rowid_to_tid[r["ROWID"]] = (tid, is_group, r["chat_identifier"])
        n = pcount.get(r["ROWID"], 1) + 1  # + the user
        threads.append({
            "platform": "imessage",
            "thread_id": tid,
            "is_group": is_group,
            "participant_count": n,
            "display_name": (r["display_name"] or r["chat_identifier"]) or None,
            "last_event_ts_ms": None,  # filled from events below
        })

    # Event stream.
    events = []
    q = """
        SELECT m.guid AS guid, m.handle_id AS handle_id, m.date AS date,
               m.is_from_me AS is_from_me, m.item_type AS item_type,
               m.associated_message_type AS assoc, m.cache_has_attachments AS att,
               LENGTH(m.text) AS tlen, (m.attributedBody IS NOT NULL) AS has_body,
               h.id AS sender, cmj.chat_id AS chat_id
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.date >= ?
    """
    for r in con.execute(q, (since_ns,)):
        sess = rowid_to_tid.get(r["chat_id"])
        if not sess:
            continue
        tid, is_group, _ = sess
        from_me = bool(r["is_from_me"])
        sender = None if from_me else norm_handle(r["sender"])
        events.append({
            "platform": "imessage",
            "thread_id": tid,
            "event_id": f"imessage:{r['guid']}",
            "sender_key": sender,
            "from_me": from_me,
            "ts_ms": apple_to_ms(r["date"]),
            "kind": kind_for(r["assoc"], r["item_type"], r["att"], r["tlen"], r["has_body"]),
            "text_len": r["tlen"],
        })
    con.close()

    # Backfill last_event_ts_ms per thread.
    last = {}
    for e in events:
        if e["ts_ms"] is not None and e["ts_ms"] > last.get(e["thread_id"], 0):
            last[e["thread_id"]] = e["ts_ms"]
    for t in threads:
        t["last_event_ts_ms"] = last.get(t["thread_id"])

    out = {
        "schema_version": "1.0",
        "source_platform": "imessage",
        "window": {"since_ms": since_ms, "until_ms": until_ms},
        "generated_at_ms": until_ms,
        "truncated": False,
        "threads": [t for t in threads if t["thread_id"] in last],  # drop empty threads
        "events": events,
    }
    payload = json.dumps(out)
    if a.output == "-":
        print(payload)
    else:
        open(a.output, "w").write(payload)
    sys.stderr.write(f"[imessage_chatdb] {len(out['threads'])} threads, {len(events)} events\n")


if __name__ == "__main__":
    main()
