#!/usr/bin/env python3
"""Find the official NFL YouTube highlights video for finished games.

Usage: recap.py '<json list>'   where each entry is
  {"id": "401872656", "year": 2026, "type": 2, "week": 1,
   "away": {"name": "New England Patriots", "nick": "Patriots"},
   "home": {"name": "Seattle Seahawks",     "nick": "Seahawks"}}

Prints one JSON line per game as soon as it is resolved:
  {"id": "401872656", "yt": "hyEng1b5j8o", "title": "..."}   (yt is "" when none)

Results are cached in ~/.cache/onra-nfl-scores/recaps.json. A found video is
kept forever; a miss is retried after RETRY_AFTER seconds, because the NFL
posts highlights some hours after the final whistle.
"""
import json
import os
import re
import subprocess
import sys
import time

CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "onra-nfl-scores")
CACHE = os.path.join(CACHE_DIR, "recaps.json")
RETRY_AFTER = 30 * 60
CHANNEL = "NFL"


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, CACHE)


def search(query, n=8):
    try:
        out = subprocess.run(
            ["yt-dlp", "--flat-playlist", "--no-warnings",
             "--print", "%(id)s\t%(channel)s\t%(title)s", "ytsearch%d:%s" % (n, query)],
            capture_output=True, text=True, timeout=25,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    rows = []
    for line in out.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            rows.append({"id": parts[0], "channel": parts[1], "title": parts[2]})
    return rows


def matches(row, g):
    # The league's own channel, or one of its collaboration uploads ("NFL and Houston Texans").
    if row["channel"] != CHANNEL and not row["channel"].startswith(CHANNEL + " and "):
        return False
    t = row["title"].lower()
    if "game highlights" not in t:
        return False
    if g["away"]["nick"].lower() not in t or g["home"]["nick"].lower() not in t:
        return False
    if str(g["year"]) not in t:
        return False
    # Regular-season titles carry "Week N"; the number must match exactly
    # (week 1 must not match week 10). Preseason/playoff titles vary.
    if g["type"] == 2 and not re.search(r"week %d\b" % g["week"], t):
        return False
    return True


def resolve(g):
    q = "%s vs %s highlights %s NFL" % (g["away"]["name"], g["home"]["name"], g["year"])
    if g["type"] == 2:
        q += " Week %d" % g["week"]
    rows = search(q)
    if rows is None:
        return None  # network/tool failure: do not cache
    for row in rows:
        if matches(row, g):
            return row
    return {"id": "", "title": ""}


def main():
    games = json.loads(sys.argv[1])
    cache = load_cache()
    now = time.time()
    dirty = False
    for g in games:
        gid = str(g["id"])
        hit = cache.get(gid)
        if hit and (hit.get("yt") or now - hit.get("at", 0) < RETRY_AFTER):
            print(json.dumps({"id": gid, "yt": hit.get("yt", ""), "title": hit.get("title", "")}), flush=True)
            continue
        row = resolve(g)
        if row is None:
            continue
        cache[gid] = {"yt": row["id"], "title": row["title"], "at": now}
        dirty = True
        print(json.dumps({"id": gid, "yt": row["id"], "title": row["title"]}), flush=True)
        save_cache(cache)
    if dirty:
        save_cache(cache)


if __name__ == "__main__":
    main()
