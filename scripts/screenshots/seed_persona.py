#!/usr/bin/env python3
"""
Seed a persona's transcripts directly into a booted simulator's Jot Core Data
store, so the Recents home / transcript-detail screens render real,
persona-specific content for marketing screenshots.

This writes raw rows into ZTRANSCRIPT (the SwiftData/Core Data backing store).
The app regenerates the keyboard history mirror (transcript-history.json) itself
on next launch via TranscriptHistoryMirror.refresh, so we only seed the store.

Usage:
    python3 seed_persona.py <persona.json> [--udid <sim-udid>]

Prints, to stdout, one line per transcript flagged "feature": true, as
    <uuid>\t<label>
so the capture driver can deep-link each one (jot://transcript?id=<uuid>).
"""
import argparse
import json
import os
import subprocess
import sys
import sqlite3
import uuid as uuidlib
from datetime import datetime, timedelta

BUNDLE_ID = "com.vineetu.jot.mobile.Jot"
APP_GROUP = "group.com.vineetu.jot.mobile.shared"
STORE_REL = "Library/Application Support/JotTranscripts.store"
TRANSCRIPT_ENT = 1  # Z_ENT for the Transcript entity (from Z_PRIMARYKEY)
CORE_DATA_EPOCH = 978307200.0  # seconds between 1970-01-01 and 2001-01-01 UTC


def booted_udid():
    out = subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "booted"], text=True
    )
    for line in out.splitlines():
        if "(Booted)" in line and "iPhone" in line:
            # "    iPhone 17 Pro (UDID) (Booted)"
            return line.split("(")[1].split(")")[0]
    raise SystemExit("No booted iPhone simulator found.")


def store_path(udid):
    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, APP_GROUP],
        text=True,
    ).strip()
    path = os.path.join(container, STORE_REL)
    if not os.path.exists(path):
        raise SystemExit(f"Store not found at {path} — is the app installed?")
    return path


def cd_time(dt):
    return dt.timestamp() - CORE_DATA_EPOCH


def seed(store, items):
    conn = sqlite3.connect(store)
    cur = conn.cursor()

    # Clean slate: transcripts + derived rows.
    for tbl in ("ZTRANSCRIPT", "ZTRANSCRIPTCHUNK",
                "ZTRANSCRIPTEMBEDDING", "ZTRANSCRIPTCATEGORY"):
        cur.execute(f"DELETE FROM {tbl}")

    now = datetime.now()
    feature_ids = []
    pk = 0
    ledger = 0

    for item in items:
        pk += 1
        ledger += 1
        u = uuidlib.uuid4()
        # createdAt = N days ago, at the given HH:MM (local).
        days_ago = int(item.get("days_ago", 0))
        hh, mm = (item.get("time", "09:00").split(":") + ["0"])[:2]
        base = (now - timedelta(days=days_ago)).replace(
            hour=int(hh), minute=int(mm), second=0, microsecond=0
        )
        created = cd_time(base)

        cur.execute(
            """INSERT INTO ZTRANSCRIPT
               (Z_PK, Z_ENT, Z_OPT, ZLEDGERINDEX, ZREWRITEUPVOTED,
                ZCREATEDAT, ZDURATIONSECONDS, ZSUPERSEDEDAT, ZCATEGORY,
                ZCLEANEDTEXT, ZINSTRUCTION, ZREWRITEUSEREDIT, ZSOURCE,
                ZTEXT, ZWATCHORIGINUUID, ZDERIVEDFROMID, ZID)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                pk, TRANSCRIPT_ENT, 1, ledger, None,
                created, item.get("duration"), None, None,
                item.get("cleaned"), item.get("instruction"), None,
                item.get("source", "app"),
                item["text"], None, None, u.bytes,
            ),
        )
        if item.get("feature"):
            feature_ids.append((str(u), item.get("label", item["text"][:32])))

    # Core Data primary-key bookkeeping: next Z_PK must exceed our max.
    cur.execute(
        "UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_ENT = ?",
        (pk, TRANSCRIPT_ENT),
    )
    conn.commit()
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.commit()
    conn.close()
    return feature_ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("persona", help="path to persona JSON")
    ap.add_argument("--udid", default=None)
    args = ap.parse_args()

    udid = args.udid or booted_udid()
    store = store_path(udid)

    with open(args.persona) as f:
        data = json.load(f)
    items = data["transcripts"]

    feature_ids = seed(store, items)
    print(
        f"Seeded {len(items)} transcripts into {os.path.basename(store)} "
        f"({data.get('persona','?')})",
        file=sys.stderr,
    )
    for uid, label in feature_ids:
        print(f"{uid}\t{label}")


if __name__ == "__main__":
    main()
