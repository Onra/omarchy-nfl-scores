.pragma library

// Pure helpers for the NFL scores panel: ESPN scoreboard parsing and
// formatting. No QML types in here so it stays easy to test with plain JS.

var BASE = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"

var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var POST_SHORT = { "1": "WC", "2": "DIV", "3": "CONF", "4": "PB", "5": "SB" }

function pad2(n) { return (n < 10 ? "0" : "") + n }

function weekKey(type, week) { return type + "-" + week }

// URL for one week. With no arguments ESPN answers for "right now", which is
// also how the current week and the season calendar are discovered.
function url(year, type, week) {
  if (!type || !week) return BASE
  return BASE + "?dates=" + year + "&seasontype=" + type + "&week=" + week
}

// Flatten the season calendar into one ordered list the panel can step
// through: preseason, regular season, postseason. Off-season has no entries.
function parseWeeks(json) {
  var out = []
  var leagues = json && json.leagues
  var cal = leagues && leagues[0] && leagues[0].calendar
  if (!cal) return out
  for (var i = 0; i < cal.length; i++) {
    var section = cal[i]
    var type = parseInt(section.value)
    var entries = section.entries || []
    for (var j = 0; j < entries.length; j++) {
      var e = entries[j]
      out.push({
        type: type,
        week: parseInt(e.value),
        key: weekKey(type, parseInt(e.value)),
        section: section.label,
        label: e.label,
        start: Date.parse(e.startDate) || 0,
        end: Date.parse(e.endDate) || 0
      })
    }
  }
  return out
}

// Compact label for the bar: W2, P3, DIV, SB.
function shortWeekLabel(w) {
  if (!w) return "NFL"
  if (w.type === 1) return "P" + w.week
  if (w.type === 3) return POST_SHORT[String(w.week)] || "PO"
  return "W" + w.week
}

function parseGame(e) {
  var comp = (e.competitions && e.competitions[0]) || {}
  var st = e.status || comp.status || {}
  var type = st.type || {}
  var away = null, home = null
  var cs = comp.competitors || []
  for (var i = 0; i < cs.length; i++) {
    var c = cs[i]
    var rec = ""
    var recs = c.records || []
    for (var r = 0; r < recs.length; r++)
      if (recs[r].type === "total") rec = recs[r].summary
    var t = {
      abbr: (c.team && c.team.abbreviation) || "TBD",
      name: (c.team && (c.team.shortDisplayName || c.team.displayName)) || "TBD",
      fullName: (c.team && c.team.displayName) || "",
      logo: (c.team && c.team.logo) || "",
      score: c.score === undefined || c.score === "" ? "" : String(c.score),
      record: rec,
      winner: c.winner === true
    }
    if (c.homeAway === "home") home = t
    else away = t
  }
  var blank = { abbr: "TBD", name: "TBD", fullName: "", logo: "", score: "", record: "", winner: false }
  var net = ""
  var gb = comp.broadcasts
  if (gb && gb.length && gb[0].names) net = gb[0].names.join("/")
  else if (comp.broadcast) net = String(comp.broadcast)
  var odds = comp.odds && comp.odds[0] && comp.odds[0].details ? String(comp.odds[0].details) : ""
  return {
    id: e.id,
    date: Date.parse(e.date) || 0,
    timeValid: comp.timeValid !== false,
    state: type.state || "pre",           // pre | in | post
    statusName: type.name || "",
    detail: type.shortDetail || "",
    away: away || blank,
    home: home || blank,
    network: net,
    odds: odds,
    venue: comp.venue ? comp.venue.fullName : ""
  }
}

// Returns { year, type, week, weeks, games } for a scoreboard response.
function parseScoreboard(json) {
  var events = (json && json.events) || []
  var games = []
  for (var i = 0; i < events.length; i++) games.push(parseGame(events[i]))
  games.sort(function(a, b) { return a.date - b.date })
  return {
    year: json && json.season ? json.season.year : 0,
    type: json && json.season ? json.season.type : 0,
    week: json && json.week ? json.week.number : 0,
    weeks: parseWeeks(json),
    games: games
  }
}

function liveCount(games) {
  var n = 0
  for (var i = 0; i < (games || []).length; i++) if (games[i].state === "in") n++
  return n
}

// A finished week never changes, so its cached copy is final.
function allFinal(games) {
  if (!games || games.length === 0) return false
  for (var i = 0; i < games.length; i++) if (games[i].state !== "post") return false
  return true
}

function clock(ms) {
  var d = new Date(ms)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function dayLabel(ms) {
  var d = new Date(ms)
  return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
}

function dayKey(ms) {
  var d = new Date(ms)
  return d.getFullYear() * 10000 + d.getMonth() * 100 + d.getDate()
}

// Status column text: local kickoff time, live clock, or the final line.
function statusText(g) {
  if (g.state === "pre") {
    if (g.statusName !== "STATUS_SCHEDULED") return g.detail
    return g.timeValid ? clock(g.date) : "TBD"
  }
  return g.detail
}

// Games grouped by local calendar day, in kickoff order:
// [{ label, games: [...] }, ...]
function groupByDay(games) {
  var groups = []
  var last = null
  for (var i = 0; i < (games || []).length; i++) {
    var g = games[i]
    var k = g.timeValid ? dayKey(g.date) : -1
    if (!last || last.k !== k) {
      last = { k: k, label: g.timeValid ? dayLabel(g.date) : "Date TBD", games: [] }
      groups.push(last)
    }
    last.games.push(g)
  }
  return groups
}

// Flatten groups into one list of delegates: day headers interleaved with
// games, which is what a ListView wants.
function rows(games) {
  var out = []
  var groups = groupByDay(games)
  for (var i = 0; i < groups.length; i++) {
    out.push({ kind: "day", label: groups[i].label })
    for (var j = 0; j < groups[i].games.length; j++)
      out.push({ kind: "game", game: groups[i].games[j] })
  }
  return out
}

// "16 Sep – 22 Sep" span of the games shown, for the header subtitle.
function rangeLabel(games) {
  if (!games || games.length === 0) return ""
  var first = games[0], last = games[games.length - 1]
  if (!first.timeValid) return ""
  var a = new Date(first.date), b = new Date(last.date)
  var fa = a.getDate() + " " + MONTHS[a.getMonth()]
  var fb = b.getDate() + " " + MONTHS[b.getMonth()]
  return fa === fb ? fa : fa + " – " + fb
}

// Entries for recap.py: finished games with both teams known.
function recapEntries(games, year, type, week) {
  var out = []
  for (var i = 0; i < (games || []).length; i++) {
    var g = games[i]
    if (g.state !== "post" || !g.away.fullName || !g.home.fullName) continue
    out.push({
      id: g.id, year: year, type: type, week: week,
      away: { name: g.away.fullName, nick: g.away.name },
      home: { name: g.home.fullName, nick: g.home.name }
    })
  }
  return out
}

// ---- standings -------------------------------------------------------------------

var STANDINGS_URL = "https://site.api.espn.com/apis/v2/sports/football/nfl/standings?level=3"

function standingsUrl() { return STANDINGS_URL }

function statValue(stats, name) {
  for (var i = 0; i < (stats || []).length; i++)
    if (stats[i].name === name) return stats[i].displayValue !== undefined ? String(stats[i].displayValue) : ""
  return ""
}

// Flat delegate list for the standings view: a header row per division
// followed by its teams, in ESPN's own order (it applies the NFL tiebreakers,
// which a plain win-percentage sort would get wrong).
//   { kind: "div",  label: "AFC East" }
//   { kind: "team", team: { name, logo, rec, pct, pf, pa, diff, streak, leader } }
function parseStandings(json) {
  var rows = []
  var confs = (json && json.children) || []
  for (var c = 0; c < confs.length; c++) {
    var divs = confs[c].children || []
    for (var d = 0; d < divs.length; d++) {
      rows.push({ kind: "div", label: divs[d].name || "" })
      var entries = (divs[d].standings && divs[d].standings.entries) || []
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        var st = e.stats || []
        var logos = (e.team && e.team.logos) || []
        rows.push({
          kind: "team",
          team: {
            name: (e.team && (e.team.shortDisplayName || e.team.displayName)) || "TBD",
            logo: logos.length ? logos[0].href : "",
            rec: statValue(st, "overall"),
            pct: statValue(st, "winPercent"),
            pf: statValue(st, "pointsFor"),
            pa: statValue(st, "pointsAgainst"),
            diff: statValue(st, "pointDifferential"),
            streak: statValue(st, "streak"),
            leader: i === 0
          }
        })
      }
    }
  }
  return {
    year: json && json.season ? json.season.year : 0,
    rows: rows
  }
}

// ---- box score ----------------------------------------------------------------

var SUMMARY_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/summary?event="

function summaryUrl(id) { return SUMMARY_URL + id }

// Player tables of the box score, in the order they are drawn: ESPN category
// name, heading, and the column that ranks the players (drawn brighter, bold
// for the leader).
var BOX_CATEGORIES = [
  { name: "passing",       label: "PASSING",       lead: "YDS" },
  { name: "rushing",       label: "RUSHING",       lead: "YDS" },
  { name: "receiving",     label: "RECEIVING",     lead: "YDS" },
  { name: "fumbles",       label: "FUMBLES",       lead: "" },
  { name: "defensive",     label: "DEFENSE",       lead: "TOT" },
  { name: "interceptions", label: "INTERCEPTIONS", lead: "INT" },
  { name: "kickReturns",   label: "KICK RETURNS",  lead: "YDS" },
  { name: "puntReturns",   label: "PUNT RETURNS",  lead: "YDS" },
  { name: "kicking",       label: "KICKING",       lead: "PTS" },
  { name: "punting",       label: "PUNTING",       lead: "YDS" }
]

// Column width in Style.space units, by ESPN label; the rest get COL_WIDTH.
var COL_WIDTH = 34
var COL_WIDTHS = { "C/ATT": 50, "SACKS": 44, "QB HTS": 48, "In 20": 40, "LONG": 40, "TGTS": 40, "RTG": 40, "AVG": 38, "FG": 40, "XP": 36, "PCT": 38 }
var COL_GAP = 6
var NAME_WIDTH = 190

// Team stats compared side by side: ESPN stat name, label.
var TEAM_STATS = [
  ["firstDowns", "1st downs"], ["thirdDownEff", "3rd down"], ["fourthDownEff", "4th down"],
  ["totalYards", "Total yards"], ["yardsPerPlay", "Yards per play"],
  ["netPassingYards", "Passing"], ["completionAttempts", "Comp/Att"], ["sacksYardsLost", "Sacks-yards"],
  ["rushingYards", "Rushing"], ["rushingAttempts", "Rush attempts"], ["yardsPerRushAttempt", "Yards per rush"],
  ["redZoneAttempts", "Red zone"], ["totalPenaltiesYards", "Penalties"], ["turnovers", "Turnovers"],
  ["possessionTime", "Possession"]
]
var TEAM_STAT_WIDTH = 64

function colWidth(label) { return COL_WIDTHS[label] || COL_WIDTH }

function cellsWidth(cells) {
  var w = 0
  for (var i = 0; i < cells.length; i++) w += cells[i].w
  return w + COL_GAP * Math.max(0, cells.length - 1)
}

function summaryTeam(c) {
  var team = c.team || {}
  var lines = []
  var ls = c.linescores || []
  for (var j = 0; j < ls.length; j++)
    lines.push(ls[j].displayValue !== undefined ? String(ls[j].displayValue) : String(ls[j].value))
  return {
    id: String(team.id || ""),
    abbr: team.abbreviation || "TBD",
    name: team.shortDisplayName || team.displayName || "TBD",
    fullName: team.displayName || "",
    logo: team.logo || (team.logos && team.logos.length ? team.logos[0].href : ""),
    score: c.score === undefined || c.score === "" ? "" : String(c.score),
    winner: c.winner === true,
    lines: lines
  }
}

function findTeamBlock(list, id) {
  for (var i = 0; i < (list || []).length; i++)
    if (list[i].team && String(list[i].team.id) === id) return list[i]
  return null
}

function teamStatValue(stats, name) {
  for (var i = 0; i < (stats || []).length; i++)
    if (stats[i].name === name) return String(stats[i].displayValue)
  return ""
}

// Returns { id, state, detail, venue, periods: ["1".."4","OT"], teams: [away, home], width, rows }
// where width (Style.space units) fits the widest table and rows is the flat
// delegate list the box score view draws:
//   { kind: "lines" }                          quarter-by-quarter table
//   { kind: "head", label, cells }             section heading with its column heads
//   { kind: "play", period, clock, abbr, text, score }   one scoring play
//   { kind: "line", name, id, cells }          a team stat or a player's line (id: ESPN athlete)
//   { kind: "team", team }                     team banner
// A cell is { text, w, lead }; lead marks the ranking column, bold when the
// line is the category leader.
function parseSummary(json) {
  var comp = json && json.header && json.header.competitions && json.header.competitions[0] || {}
  var st = (comp.status && comp.status.type) || {}
  var away = null, home = null
  var cs = comp.competitors || []
  for (var i = 0; i < cs.length; i++) {
    var t = summaryTeam(cs[i])
    if (cs[i].homeAway === "home") home = t
    else away = t
  }
  var teams = []
  if (away) teams.push(away)
  if (home) teams.push(home)

  var periods = 0
  for (i = 0; i < teams.length; i++) periods = Math.max(periods, teams[i].lines.length)
  var plabels = []
  for (i = 0; i < Math.max(periods, 4); i++)
    plabels.push(i < 4 ? String(i + 1) : (i === 4 ? "OT" : "OT" + (i - 3)))

  var rows = [{ kind: "lines" }]
  var width = 0

  // Scoring plays, in game order.
  var plays = (json && json.scoringPlays) || []
  if (plays.length > 0) {
    rows.push({ kind: "head", label: "SCORING", cells: [] })
    for (i = 0; i < plays.length; i++) {
      var sp = plays[i]
      var n = sp.period ? sp.period.number : 0
      rows.push({
        kind: "play",
        period: n > 4 ? "OT" : "Q" + n,
        clock: sp.clock ? String(sp.clock.displayValue || "") : "",
        abbr: sp.team ? String(sp.team.abbreviation || "") : "",
        text: String(sp.text || ""),
        score: sp.awayScore + " – " + sp.homeScore
      })
    }
  }

  var box = (json && json.boxscore) || {}

  // Team stats, away then home.
  if (teams.length === 2) {
    var as = findTeamBlock(box.teams, teams[0].id), hs = findTeamBlock(box.teams, teams[1].id)
    if (as && hs) {
      rows.push({ kind: "head", label: "TEAM STATS", cells: [
        { text: teams[0].abbr, w: TEAM_STAT_WIDTH, lead: false },
        { text: teams[1].abbr, w: TEAM_STAT_WIDTH, lead: false }
      ] })
      for (i = 0; i < TEAM_STATS.length; i++) {
        var av = teamStatValue(as.statistics, TEAM_STATS[i][0]), hv = teamStatValue(hs.statistics, TEAM_STATS[i][0])
        if (av === "" && hv === "") continue
        rows.push({ kind: "line", name: TEAM_STATS[i][1], cells: [
          { text: av, w: TEAM_STAT_WIDTH, lead: true },
          { text: hv, w: TEAM_STAT_WIDTH, lead: true }
        ] })
      }
    }
  }

  // Player tables, one team after the other.
  for (var ti = 0; ti < teams.length; ti++) {
    var pl = findTeamBlock(box.players, teams[ti].id)
    if (!pl) continue
    rows.push({ kind: "team", team: teams[ti] })
    for (var ci = 0; ci < BOX_CATEGORIES.length; ci++) {
      var cat = BOX_CATEGORIES[ci]
      var block = null
      for (var b = 0; b < (pl.statistics || []).length; b++)
        if (pl.statistics[b].name === cat.name) block = pl.statistics[b]
      if (!block || !block.athletes || block.athletes.length === 0) continue
      var labels = block.labels || []
      var head = []
      for (var l = 0; l < labels.length; l++) head.push({ text: labels[l], w: colWidth(labels[l]), lead: false })
      width = Math.max(width, cellsWidth(head))
      rows.push({ kind: "head", label: cat.label, cells: head })
      // ESPN lists each table best first, so the first line is the leader.
      for (var a = 0; a < block.athletes.length; a++) {
        var ath = block.athletes[a]
        var cells = []
        for (l = 0; l < labels.length; l++)
          cells.push({
            text: ath.stats && ath.stats[l] !== undefined ? String(ath.stats[l]) : "",
            w: colWidth(labels[l]),
            lead: labels[l] === cat.lead,
            top: a === 0 && labels[l] === cat.lead
          })
        rows.push({
          kind: "line",
          name: (ath.athlete && ath.athlete.displayName) || "",
          id: ath.athlete && ath.athlete.id ? String(ath.athlete.id) : "",
          cells: cells
        })
      }
    }
  }

  var info = (json && json.gameInfo) || {}
  return {
    id: String(json && json.header ? json.header.id : ""),
    state: st.state || "pre",
    detail: st.detail || st.shortDetail || "",
    venue: info.venue ? info.venue.fullName : "",
    periods: plabels,
    teams: teams,
    width: NAME_WIDTH + Math.max(width, TEAM_STAT_WIDTH * 2 + COL_GAP) + 32,
    rows: rows
  }
}

// ---- player card ------------------------------------------------------------------

// Column width in Style.space units, by player.py's label; the rest get PLAYER_COL_WIDTH.
var PLAYER_COL_WIDTH = 34
var PLAYER_COL_WIDTHS = {
  "CMP%": 42, "YDS": 46, "RTG": 42, "SACK": 38, "TGTS": 40, "FG": 54, "FG%": 40, "50+": 42, "XPM": 38, "XPA": 38,
  "PUNTS": 44, "IN20": 38, "NET": 38, "KR YDS": 52, "PR YDS": 52, "KR TD": 44, "PR TD": 44, "SOLO": 40
}
var PLAYER_NAME_WIDTH = 130

function playerCells(labels, values, strong) {
  var out = []
  for (var i = 0; i < labels.length; i++)
    out.push({ text: values ? (values[i] || "") : labels[i], w: PLAYER_COL_WIDTHS[labels[i]] || PLAYER_COL_WIDTH, lead: true, top: strong === true })
  return out
}

// $51,000,000 -> "$51.0M"; 950000 -> "$950K"
function money(n) {
  n = Number(n) || 0
  if (n >= 1e6) return "$" + (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return "$" + Math.round(n / 1e3) + "K"
  return n > 0 ? "$" + n : ""
}

// ESPN's US measures with the metric ones after them:
// 6' 4" -> 6' 4" (1.93 m); 219 lbs -> 219 lbs (99 kg)
function heightText(s) {
  var m = /(\d+)'\s*(\d+)?/.exec(String(s || ""))
  if (!m) return s || ""
  var cm = (parseInt(m[1]) * 12 + (parseInt(m[2]) || 0)) * 2.54
  return s + " (" + (cm / 100).toFixed(2) + " m)"
}

function weightText(s) {
  var m = /(\d+(?:\.\d+)?)\s*lb/i.exec(String(s || ""))
  if (!m) return s || ""
  return s + " (" + Math.round(parseFloat(m[1]) * 0.45359237) + " kg)"
}

// Width (Style.space units) that fits the widest stat table of a card.
function playerWidth(card) {
  var w = 0
  var ts = (card && card.tables) || []
  for (var i = 0; i < ts.length; i++) w = Math.max(w, cellsWidth(playerCells(ts[i].labels)))
  return PLAYER_NAME_WIDTH + Math.max(w, 300) + 32
}

// Flat delegate list for a player card (player.py's output):
//   { kind: "bio" }                                  photo and facts (drawn from the card)
//   { kind: "section", label }                       section title
//   { kind: "head", label, cells }                   a stat table's name and column heads
//   { kind: "line", label, sub, cells, strong }      one stat line
//   { kind: "salary", season, team, salary, note, current, future }
//   { kind: "award", label, sub }
function playerRows(card) {
  var rows = []
  if (!card || card.error) return rows
  rows.push({ kind: "bio" })
  var ts = card.tables || []

  // This season: the line of each table for the season in progress.
  var season = []
  for (var i = 0; i < ts.length; i++)
    for (var j = 0; j < ts[i].rows.length; j++)
      if (ts[i].rows[j].season === card.season && !ts[i].rows[j].total) season.push({ t: ts[i], r: ts[i].rows[j] })
  if (season.length) {
    rows.push({ kind: "section", label: card.season + " season" })
    for (i = 0; i < season.length; i++) {
      rows.push({ kind: "head", label: season[i].t.title.toUpperCase(), cells: playerCells(season[i].t.labels) })
      rows.push({ kind: "line", label: season[i].r.season, sub: season[i].r.team, cells: playerCells(season[i].t.labels, season[i].r.stats, true), strong: true })
    }
  }

  // Newest first: the seasons to come, this season in bold, then the past.
  var paid = (card.salaries || []).filter(function(c) { return c.salary > 0 })
  if (paid.length) {
    rows.push({ kind: "section", label: "Salary" })
    for (i = 0; i < paid.length; i++) {
      var c = paid[i]
      var current = c.season === card.season
      var note = current && c.signedThrough && String(c.signedThrough) > card.season
        ? "signed through " + c.signedThrough : ""
      rows.push({ kind: "salary", season: c.season, team: c.team, salary: money(c.salary), note: note, current: current, future: c.future === true })
    }
  }

  if (card.awards && card.awards.length) {
    rows.push({ kind: "section", label: "Awards" })
    for (i = 0; i < card.awards.length; i++) {
      var aw = card.awards[i]
      rows.push({ kind: "award", label: (aw.count && aw.count !== "1x" ? aw.count.replace("x", "×") + " " : "") + aw.name, sub: aw.seasons.join(", ") })
    }
  }

  if (ts.length) {
    rows.push({ kind: "section", label: "Career · regular season" })
    for (i = 0; i < ts.length; i++) {
      rows.push({ kind: "head", label: ts[i].title.toUpperCase(), cells: playerCells(ts[i].labels) })
      for (j = 0; j < ts[i].rows.length; j++) {
        var r = ts[i].rows[j]
        rows.push({ kind: "line", label: r.season, sub: r.team, cells: playerCells(ts[i].labels, r.stats, false), strong: false })
      }
      if (ts[i].total) rows.push({ kind: "line", label: "Career", sub: "", cells: playerCells(ts[i].labels, ts[i].total, true), strong: true })
    }
  }
  return rows
}
