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
