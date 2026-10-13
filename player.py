#!/usr/bin/env python3
"""One NFL player's card: bio, draft and college, salary, awards, career stats.

Usage: player.py <espn-athlete-id> [season]     prints one JSON object (see build())

season is the NFL season in progress (the year it starts); without it, the
league year is taken to turn over in March.

Sources (ESPN, no key), fetched in parallel:
  - athletes/<id>            bio: age, size, birthplace, draft, college, team, injuries
  - athletes/<id>/overview   awards
  - athletes/<id>/stats      regular season stats season by season, by category
  - core API contracts       salary of each season under contract, the seasons
                             to come included

Cache: ~/.cache/onra-nfl-scores/players/<id>.json for CACHE_TTL. Past salaries
never change, so the salary of a past season is kept for good.
"""
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "onra-nfl-scores", "players")
CACHE_TTL = 6 * 3600
WEB = "https://site.web.api.espn.com/apis/common/v3/sports/football/nfl/athletes/"
CORE = "https://sports.core.api.espn.com/v2/sports/football/leagues/nfl/athletes/"
TEAMS = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams"

# The stat tables a card can show, in ESPN's category names, with the columns
# kept from each (ESPN name, label) and the volume stats that decide whether
# the table is worth showing: the player's main category always is, the others
# only past MIN_VOLUME (a quarterback's two tackles are not a defense table).
CATEGORIES = {
    "passing": ("Passing", ("passingAttempts",), 20, [
        ("gamesPlayed", "GP"), ("completions", "CMP"), ("passingAttempts", "ATT"), ("completionPct", "CMP%"),
        ("passingYards", "YDS"), ("passingTouchdowns", "TD"), ("interceptions", "INT"), ("sacks", "SACK"),
        ("QBRating", "RTG")]),
    "rushing": ("Rushing", ("rushingAttempts",), 20, [
        ("gamesPlayed", "GP"), ("rushingAttempts", "CAR"), ("rushingYards", "YDS"), ("yardsPerRushAttempt", "AVG"),
        ("rushingTouchdowns", "TD"), ("longRushing", "LNG"), ("rushingFirstDowns", "FD"), ("rushingFumbles", "FUM")]),
    "receiving": ("Receiving", ("receptions",), 10, [
        ("gamesPlayed", "GP"), ("receptions", "REC"), ("receivingTargets", "TGTS"), ("receivingYards", "YDS"),
        ("yardsPerReception", "AVG"), ("receivingTouchdowns", "TD"), ("longReception", "LNG"),
        ("receivingFirstDowns", "FD")]),
    "defensive": ("Defense", ("totalTackles",), 10, [
        ("gamesPlayed", "GP"), ("totalTackles", "TOT"), ("soloTackles", "SOLO"), ("sacks", "SACK"),
        ("fumblesForced", "FF"), ("fumblesRecovered", "FR"), ("interceptions", "INT"), ("passesDefended", "PD"),
        ("interceptionTouchdowns", "TD")]),
    "kicking": ("Kicking", ("extraPointAttempts", "fieldGoalsMade-fieldGoalAttempts"), 5, [
        ("gamesPlayed", "GP"), ("fieldGoalsMade-fieldGoalAttempts", "FG"), ("fieldGoalPct", "FG%"),
        ("fieldGoalsMade50-fieldGoalAttempts50", "50+"), ("longFieldGoalMade", "LNG"), ("extraPointsMade", "XPM"),
        ("extraPointAttempts", "XPA"), ("totalKickingPoints", "PTS")]),
    "punting": ("Punting", ("punts",), 5, [
        ("gamesPlayed", "GP"), ("punts", "PUNTS"), ("puntYards", "YDS"), ("grossAvgPuntYards", "AVG"),
        ("netAvgPuntYards", "NET"), ("longPunt", "LNG"), ("puntsInside20", "IN20"), ("touchbacks", "TB")]),
    "returning": ("Returns", ("kickReturns", "puntReturns"), 10, [
        ("gamesPlayed", "GP"), ("kickReturns", "KR"), ("kickReturnYards", "KR YDS"), ("kickReturnTouchdowns", "KR TD"),
        ("puntReturns", "PR"), ("puntReturnYards", "PR YDS"), ("puntReturnTouchdowns", "PR TD")]),
}
MAX_TABLES = 3


def get(url, timeout=12):
    try:
        out = subprocess.run(["curl", "-fsS", "--compressed", "--max-time", str(timeout), url],
                             capture_output=True, text=True, timeout=timeout + 5).stdout
        return json.loads(out) if out.strip() else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def number(s):
    """"1,408" -> 1408; "23-27" (made-attempts) -> 27."""
    try:
        return float(str(s).replace(",", "").split("-")[-1])
    except ValueError:
        return 0.0


def default_season():
    t = time.localtime()
    return t.tm_year if t.tm_mon >= 3 else t.tm_year - 1


def team_map():
    path = os.path.join(CACHE_DIR, "_teams.json")
    cached = load(path)
    if cached and time.time() - cached.get("at", 0) < 30 * 86400:
        return cached["teams"]
    j = get(TEAMS)
    teams = {}
    for s in ((j or {}).get("sports") or [{}])[0].get("leagues", [{}])[0].get("teams", []):
        t = s.get("team") or {}
        teams[str(t.get("id"))] = t.get("abbreviation", "")
    if teams:
        save(path, {"at": time.time(), "teams": teams})
    return teams


def contracts(pid, old, season):
    """[{key, season, teamId, salary, ...}] newest first. Past seasons come from the cache."""
    idx = get(CORE + pid + "/contracts?limit=50")
    refs = [i["$ref"] for i in (idx or {}).get("items", [])]
    known = {c["key"]: c for c in (old or [])}

    def one(ref):
        key = re.search(r"/contracts/(\d+)", ref).group(1)
        if key in known and int(key) < season:
            return known[key]
        c = get(ref)
        if not c:
            return known.get(key)
        team = re.search(r"/teams/(\d+)", ((c.get("team") or {}).get("$ref") or ""))
        return {"key": key, "season": key, "teamId": team.group(1) if team else "",
                "salary": c.get("salary") or 0, "signedThrough": c.get("signedThrough")}

    with ThreadPoolExecutor(max_workers=6) as pool:
        out = [c for c in pool.map(one, refs) if c]
    out.sort(key=lambda c: c["key"], reverse=True)
    return out


def tables(stats, teams):
    """The stat tables worth showing, main category first (ESPN's own order)."""
    out = []
    for i, cat in enumerate((stats or {}).get("categories", [])):
        spec = CATEGORIES.get(cat.get("name"))
        if not spec:
            continue
        title, volume, minimum, columns = spec
        names = cat.get("names") or []

        def pick(values):
            m = dict(zip(names, values or []))
            return [str(m.get(n, "")) for n, _ in columns]

        totals = dict(zip(names, cat.get("totals") or []))
        if out and sum(number(totals.get(v, 0)) for v in volume) < minimum:
            continue
        # A season with two teams has a line for each, then a line of totals
        # with no team.
        rows = [{"season": str((r.get("season") or {}).get("year", "")),
                 "team": teams.get(str(r.get("teamId")), "") if r.get("teamId") else "total",
                 "total": not r.get("teamId"),
                 "stats": pick(r.get("stats"))}
                for r in cat.get("statistics", [])]
        rows.reverse()  # newest first
        out.append({"title": title, "labels": [label for _, label in columns], "rows": rows,
                    "total": pick(cat.get("totals"))})
        if len(out) == MAX_TABLES:
            break
    return out


def build(pid, bio, overview, stats, salaries, teams, season):
    a = (bio or {}).get("athlete") or {}
    team = a.get("team") or {}
    college = a.get("college") or {}
    injuries = a.get("injuries") or []
    injury = ""
    if injuries:
        i = injuries[0]
        injury = " · ".join(x for x in [i.get("status", ""), (i.get("details") or {}).get("type", "")] if x)

    stat_tables = tables(stats, teams)

    # ESPN files a contract under the team that signed it; the stats know
    # where the player actually played each past season.
    team_of_season = {}
    for t in stat_tables:
        for row in t["rows"]:
            if not row["total"]:
                team_of_season.setdefault(row["season"], row["team"])
    for c in salaries:
        # The seasons to come name no team: the player's current one holds them.
        c["team"] = (team_of_season.get(c["season"]) or teams.get(c.get("teamId", ""), "")
                     or team.get("abbreviation", ""))
        c["future"] = int(c["key"]) > season

    return {
        "id": pid,
        "name": a.get("displayName", ""),
        "headshot": (a.get("headshot") or {}).get("href", ""),
        "jersey": a.get("displayJersey") or ("#" + a["jersey"] if a.get("jersey") else ""),
        "position": (a.get("position") or {}).get("displayName", ""),
        "team": team.get("displayName", ""),
        "age": a.get("age"),
        "dob": a.get("displayDOB", ""),
        "birthplace": a.get("displayBirthPlace", ""),
        "height": a.get("displayHeight", ""),
        "weight": a.get("displayWeight", ""),
        "draft": a.get("displayDraft", "") or "Undrafted",
        "college": college.get("name", ""),
        "experience": a.get("displayExperience", ""),
        "injury": injury,
        "season": str(season),
        "tables": stat_tables,
        "awards": [{"name": w.get("name", ""), "count": w.get("displayCount", ""),
                    "seasons": [str(s) for s in w.get("seasons", [])]}
                   for w in (overview or {}).get("awards") or [] if isinstance(w, dict)],
        "salaries": salaries,
    }


def main():
    pid = re.sub(r"\D", "", sys.argv[1]) if len(sys.argv) > 1 else ""
    if not pid:
        print(json.dumps({"error": "No player"}))
        return
    season = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() and int(sys.argv[2]) > 0 else default_season()
    path = os.path.join(CACHE_DIR, pid + ".json")
    cached = load(path)
    if cached and time.time() - cached.get("at", 0) < CACHE_TTL:
        print(json.dumps(cached["card"]))
        return
    old_salaries = (cached or {}).get("card", {}).get("salaries") or []
    with ThreadPoolExecutor(max_workers=5) as pool:
        f_bio = pool.submit(get, WEB + pid)
        f_ov = pool.submit(get, WEB + pid + "/overview")
        f_st = pool.submit(get, WEB + pid + "/stats")
        f_sal = pool.submit(contracts, pid, old_salaries, season)
        f_teams = pool.submit(team_map)
        bio, ov, st, sal, teams = f_bio.result(), f_ov.result(), f_st.result(), f_sal.result(), f_teams.result()
    if not bio:
        if cached:
            print(json.dumps(cached["card"]))
        else:
            print(json.dumps({"error": "Couldn't reach ESPN"}))
        return
    card = build(pid, bio, ov, st, sal, teams, season)
    save(path, {"at": time.time(), "card": card})
    print(json.dumps(card))


if __name__ == "__main__":
    main()
