import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Scores and schedule panel. Owns the fetchers and the refresh timer so the
// bar label stays current while the panel is closed. Two fetches run:
//   - "current": ESPN's own idea of right now. Discovers the season calendar
//     and the current week, and drives the bar label.
//   - "view": whichever week the panel is showing, when it isn't the current one.
//   - "box": the summary (box score) of the game opened in the panel.
Panel {
  id: root
  moduleName: "onra.nfl-scores"
  ipcTarget: "onra.nfl-scores"
  manageIpc: false

  property var anchorItem: null
  // The bar tracks the widget mounted in its slot, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- data ----------------------------------------------------------------
  property int year: 0
  property var weeks: []              // flattened season calendar
  property string currentKey: ""      // "<type>-<week>" ESPN reports for now
  property string viewKey: ""         // week the panel is showing
  property var cache: ({})            // key -> { games, at }
  property int cacheVersion: 0
  property string errorMessage: ""

  // "scores" (default: the current week), "box" (one game's box score),
  // "player" (a card opened from a box score) or "standings" (by division).
  // Opening the panel always returns to scores.
  property string mode: "scores"
  readonly property bool standingsMode: root.mode === "standings"
  readonly property bool boxMode: root.mode === "box"
  readonly property bool playerMode: root.mode === "player"
  property var standingsRows: []
  property int standingsYear: 0

  property string boxId: ""
  property var boxes: ({})            // game id -> parsed summary
  property int boxVersion: 0
  readonly property var box: {
    root.boxVersion
    return root.boxes[root.boxId] || null
  }
  readonly property var boxRows: root.box ? root.box.rows : []

  property int selected: 0            // keyboard cursor in the week's games

  readonly property int activeRowCount: root.standingsMode ? root.standingsRows.length
    : root.boxMode ? root.boxRows.length : root.playerMode ? root.playerRows.length : root.viewRows.length
  readonly property var activeList: root.standingsMode ? standingsList : root.boxMode ? boxList
    : root.playerMode ? playerList : list

  // ---- player card -----------------------------------------------------------------
  // A click on a player in a box score opens his card: bio, draft, college,
  // salary, awards, season and career stats, from player.py (cached on disk).
  property string playerId: ""
  property var players: ({})         // athlete id -> card
  property int playerVersion: 0
  readonly property var player: {
    root.playerVersion
    return root.players[root.playerId] || null
  }
  readonly property var playerRows: Model.playerRows(root.player)
  readonly property string playerScript: Qt.resolvedUrl("player.py").toString().replace("file://", "")

  function openPlayer(id) {
    if (!id) return
    root.playerId = id
    root.mode = "player"
    root.errorMessage = ""
    playerList.contentY = 0
    playerProc.command = ["python3", root.playerScript, id, String(root.year)]
    playerProc.running = true
  }

  function backFromPlayer() {
    root.errorMessage = ""
    if (root.boxId !== "") root.mode = "box"
    else root.showScores()
  }

  Process {
    id: playerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        if (d && d.id) {
          var next = ({})
          for (var k in root.players) next[k] = root.players[k]
          next[d.id] = d
          root.players = next
          root.playerVersion++
        } else if (root.playerMode) {
          root.errorMessage = d && d.error ? d.error : "Couldn't load the player"
        }
      }
    }
  }

  // Standings table columns: which team field, header label, width in px.
  readonly property var statColumns: [
    { key: "rec",    label: "W-L",  w: 52 },
    { key: "pct",    label: "PCT",  w: 46 },
    { key: "pf",     label: "PF",   w: 34 },
    { key: "pa",     label: "PA",   w: 34 },
    { key: "diff",   label: "DIFF", w: 42 },
    { key: "streak", label: "STRK", w: 40 }
  ]

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.08)

  function gamesFor(key) {
    root.cacheVersion  // dependency: re-evaluate when the cache changes
    var c = root.cache[key]
    return c ? c.games : []
  }

  function indexOfKey(key) {
    for (var i = 0; i < root.weeks.length; i++)
      if (root.weeks[i].key === key) return i
    return -1
  }

  readonly property int viewIndex: root.indexOfKey(root.viewKey)
  readonly property var viewWeek: root.viewIndex >= 0 ? root.weeks[root.viewIndex] : null
  readonly property var currentWeek: {
    var i = root.indexOfKey(root.currentKey)
    return i >= 0 ? root.weeks[i] : null
  }
  readonly property var viewGames: root.gamesFor(root.viewKey)
  readonly property var viewRows: Model.rows(root.viewGames)
  readonly property bool viewingCurrent: root.viewKey === root.currentKey

  // The game whose box score is open, as listed in the viewed week.
  readonly property var boxGame: {
    var gs = root.viewGames
    for (var i = 0; i < gs.length; i++) if (gs[i].id === root.boxId) return gs[i]
    return null
  }

  readonly property bool hasData: root.currentKey !== "" && root.cache[root.currentKey] !== undefined
  readonly property int liveGames: {
    root.cacheVersion
    return Model.liveCount(root.gamesFor(root.currentKey))
  }

  readonly property string barIcon: "🏈"
  readonly property string barText: {
    if (!root.hasData) return "🏈 NFL"
    var t = "🏈 " + Model.shortWeekLabel(root.currentWeek)
    if (root.liveGames > 0) t += " ● " + root.liveGames
    return t
  }

  function store(key, games) {
    var next = ({})
    for (var k in root.cache) next[k] = root.cache[k]
    next[key] = { games: games, at: Date.now() }
    root.cache = next
    root.cacheVersion++
  }

  function fetchCurrent() { currentFetcher.fetch(Model.url()) }

  function fetchView() {
    var w = root.viewWeek
    if (!w || root.viewingCurrent) { root.fetchCurrent(); return }
    // A finished week never changes: the cached copy is the answer.
    if (Model.allFinal(root.gamesFor(root.viewKey))) return
    viewFetcher.fetch(Model.url(root.year, w.type, w.week))
  }

  function fetchStandings() { standingsFetcher.fetch(Model.standingsUrl()) }

  // A finished game's box score never changes: the cached copy is the answer.
  function fetchBox() {
    if (root.boxId === "") return
    var b = root.boxes[root.boxId]
    if (b && b.state === "post") return
    boxFetcher.fetch(Model.summaryUrl(root.boxId))
  }

  function refresh() {
    root.fetchCurrent()
    if (root.standingsMode) root.fetchStandings()
    else if (!root.viewingCurrent) root.fetchView()
    if (root.boxMode) root.fetchBox()
  }

  // A refresh the user asked for (r key, IPC) shows a spinner and a footer
  // note. It stays up for at least minRefreshMs so a fast fetch is still
  // visible, and until both fetchers are idle. Background polling stays silent.
  property bool manualRefresh: false
  readonly property int minRefreshMs: 800

  function refreshNow() {
    root.manualRefresh = true
    refreshFloor.restart()
    // A manual refresh re-asks even for a finished box score.
    if (root.boxMode && root.boxId !== "") boxFetcher.fetch(Model.summaryUrl(root.boxId))
    root.refresh()
  }

  function settleRefresh() {
    if (!root.manualRefresh || refreshFloor.running) return
    if (currentFetcher.busy || viewFetcher.busy || standingsFetcher.busy || boxFetcher.busy) return
    root.manualRefresh = false
  }

  Timer {
    id: refreshFloor
    interval: root.minRefreshMs
    onTriggered: root.settleRefresh()
  }

  Fetcher {
    id: currentFetcher
    onLoaded: function(url, json) {
      var r = Model.parseScoreboard(json)
      if (r.weeks.length > 0) root.weeks = r.weeks
      if (r.year) root.year = r.year
      var key = Model.weekKey(r.type, r.week)
      var first = root.currentKey === ""
      // The panel follows the calendar rollover (Tuesday -> next week) unless
      // the user has navigated elsewhere.
      var following = first || root.viewKey === root.currentKey
      root.currentKey = key
      if (following) root.viewKey = key
      root.store(key, r.games)
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  Fetcher {
    id: viewFetcher
    onLoaded: function(url, json) {
      var r = Model.parseScoreboard(json)
      // Key by what ESPN answered for; fall back to what was asked.
      var key = Model.weekKey(r.type, r.week)
      root.store(key, r.games)
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  Fetcher {
    id: standingsFetcher
    onLoaded: function(url, json) {
      var r = Model.parseStandings(json)
      root.standingsRows = r.rows
      if (r.year) root.standingsYear = r.year
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  Fetcher {
    id: boxFetcher
    onLoaded: function(url, json) {
      var b = Model.parseSummary(json)
      var id = b.id || url.split("event=")[1]
      var next = ({})
      for (var k in root.boxes) next[k] = root.boxes[k]
      next[id] = b
      root.boxes = next
      root.boxVersion++
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  // ---- recaps ------------------------------------------------------------------
  // YouTube highlight videos for the finished games on screen, resolved by
  // recap.py (cached on disk, so this is cheap after the first look at a week).
  Recaps { id: recaps }

  function requestRecaps() {
    var w = root.viewWeek
    if (!w || root.year === 0) return
    recaps.want(Model.recapEntries(root.viewGames, root.year, w.type, w.week))
  }

  onViewGamesChanged: root.requestRecaps()

  function openRecap(videoId) {
    if (!videoId) return
    Quickshell.execDetached(["xdg-open", "https://www.youtube.com/watch?v=" + videoId])
    root.close()
  }

  // Every 30s while a game is live, every 5 minutes otherwise. The viewed
  // week, standings and box score are only refreshed while on screen.
  Timer {
    interval: root.liveGames > 0 || (root.boxMode && root.box && root.box.state === "in") ? 30000 : 300000
    running: true
    repeat: true
    onTriggered: {
      root.fetchCurrent()
      if (!root.opened) return
      if (root.standingsMode) root.fetchStandings()
      else if (!root.viewingCurrent) root.fetchView()
      if (root.boxMode) root.fetchBox()
    }
  }

  Component.onCompleted: root.fetchCurrent()

  // ---- navigation ------------------------------------------------------------
  function stepWeek(delta) {
    if (root.weeks.length === 0) return
    var i = root.viewIndex >= 0 ? root.viewIndex : 0
    var next = Math.max(0, Math.min(root.weeks.length - 1, i + delta))
    if (next === i) return
    root.viewKey = root.weeks[next].key
    root.errorMessage = ""
    root.fetchView()
  }

  function goCurrent() {
    if (root.currentKey === "" || root.viewingCurrent) return
    root.viewKey = root.currentKey
    root.errorMessage = ""
  }

  function scrollBy(px) {
    var l = root.activeList
    var max = Math.max(0, l.contentHeight - l.height)
    l.contentY = Math.max(0, Math.min(max, l.contentY + px))
  }

  // Row of the scores list that shows game i of the week (day headers sit
  // between the games).
  function rowOfGame(i) {
    var g = root.viewGames[i]
    for (var r = 0; r < root.viewRows.length; r++)
      if (root.viewRows[r].kind === "game" && root.viewRows[r].game.id === (g && g.id)) return r
    return -1
  }

  function moveSelection(delta) {
    var n = root.viewGames.length
    if (n === 0) return
    root.selected = Math.max(0, Math.min(n - 1, root.selected + delta))
    var r = root.rowOfGame(root.selected)
    if (r >= 0) list.positionViewAtIndex(r, ListView.Contain)
  }

  // Box scores exist once a game has kicked off.
  function canOpenBox(g) { return g && g.state !== "pre" }

  function openBox(id) {
    root.boxId = id
    root.mode = "box"
    root.errorMessage = ""
    boxList.keepY = 0
    boxList.contentY = 0
    root.fetchBox()
  }

  function backFromBox() { root.showScores() }

  // Previous/next game of the week from inside a box score.
  function stepBox(delta) {
    var gs = root.viewGames
    var i = -1
    for (var k = 0; k < gs.length; k++) if (gs[k].id === root.boxId) i = k
    for (var j = i + delta; j >= 0 && j < gs.length; j += delta) {
      if (root.canOpenBox(gs[j])) {
        root.selected = j
        root.openBox(gs[j].id)
        return
      }
    }
  }

  function activate() {
    var g = root.viewGames[root.selected]
    if (root.canOpenBox(g)) root.openBox(g.id)
  }

  function recapForCursor() {
    if (root.boxMode) return recaps.videoId(root.boxId)
    var g = root.viewGames[root.selected]
    return g && g.state === "post" ? recaps.videoId(g.id) : ""
  }

  function showStandings() {
    root.mode = "standings"
    root.errorMessage = ""
    standingsList.keepY = 0
    standingsList.contentY = 0
    root.fetchStandings()
  }

  function showScores() {
    if (root.mode === "scores") return
    root.mode = "scores"
    root.errorMessage = ""
  }

  function toggleStandings() {
    if (root.standingsMode) root.showScores()
    else root.showStandings()
  }

  onViewKeyChanged: {
    root.selected = 0
    if (typeof list === "undefined" || !list) return
    list.keepY = 0
    list.contentY = 0
  }

  function open() {
    root.mode = "scores"
    root.goCurrent()
    root.controller.show()
    root.refresh()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Declared here rather than left to the base Panel so every entry point
  // (bar click, summon, IPC) goes through this file's open(), which resets the
  // view to the current week.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function next(): void { root.stepWeek(1) }
    function prev(): void { root.stepWeek(-1) }
    function today(): void { root.showScores(); root.goCurrent() }
    function standings(): void { root.showStandings() }
    function scores(): void { root.showScores() }
    function refresh(): void { root.refreshNow() }
    // Box score of the selected game of the viewed week.
    function box(): void { root.showScores(); root.activate() }
    // Card of an ESPN athlete id.
    function player(id: string): void { root.openPlayer(id) }
  }

  // ---- UI ---------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(
      root.boxMode && root.box ? Math.max(520, root.box.width)
      : root.playerMode ? Math.max(520, Model.playerWidth(root.player)) : 520))
    contentHeight: panel.fittedContentHeight(
      Math.max(Style.space(320), header.height + root.activeList.contentHeight + footer.height + Style.space(24)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.playerMode) root.backFromPlayer()
        else if (root.boxMode) root.backFromBox()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.boxMode) {
          if (dx !== 0) root.stepBox(dx)
          else root.scrollBy(dy * Style.space(80))
        } else if (root.standingsMode || root.playerMode) {
          if (dy !== 0) root.scrollBy(dy * Style.space(80))
        } else {
          if (dx !== 0) root.stepWeek(dx)
          else root.moveSelection(dy)
        }
      }
      onActivateRequested: if (root.mode === "scores") root.activate()
      onTextKey: function(t) {
        if (t === "t") { root.showScores(); root.goCurrent() }
        else if (t === "s") root.toggleStandings()
        else if (t === "r") root.refreshNow()
        else if (t === "b") {
          if (root.playerMode) root.backFromPlayer()
          else if (root.boxMode) root.backFromBox()
          else root.showScores()
        }
        else if (t === "y") root.openRecap(root.recapForCursor())
      }

      // ---- header: ‹  Week 2  › ------------------------------------------------
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(56)

        NavButton {
          id: prevButton
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "‹"
          foreground: root.fg
          fontFamily: root.fontFamily
          visible: root.mode === "scores"
          enabled: root.viewIndex > 0
          onClicked: root.stepWeek(-1)
        }

        Column {
          id: titleColumn
          anchors.centerIn: parent
          spacing: Style.space(3)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: {
              if (root.standingsMode) return "Standings"
              if (root.playerMode) return root.player ? root.player.name : "Player"
              if (root.boxMode) {
                var g = root.boxGame
                if (!g) {
                  var bt = root.box ? root.box.teams : []
                  return bt.length === 2 ? bt[0].abbr + "  " + bt[0].score + " – " + bt[1].score + "  " + bt[1].abbr : "Box score"
                }
                return g.away.abbr + "  " + g.away.score + " – " + g.home.score + "  " + g.home.abbr
              }
              return root.viewWeek ? root.viewWeek.label : "NFL"
            }
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: {
              if (root.standingsMode)
                return (root.standingsYear ? root.standingsYear + " season · " : "") + "by division"
              if (root.playerMode) {
                var pl = root.player
                if (!pl) return ""
                return [pl.jersey, pl.position, pl.team].filter(function(s) { return s }).join(" · ")
              }
              if (root.boxMode) {
                var b = root.box
                if (!b) return root.boxGame ? Model.statusText(root.boxGame) : ""
                return [b.detail, b.venue].filter(function(s) { return s !== "" }).join(" · ")
              }
              if (!root.viewWeek) return ""
              var parts = [root.viewWeek.section]
              var range = Model.rangeLabel(root.viewGames)
              if (range !== "") parts.push(range)
              return parts.join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Switches between the scores and the standings views, or back from a
        // box score.
        Rectangle {
          id: modeButton
          anchors.left: parent.left
          anchors.leftMargin: root.mode === "scores" ? Style.space(50) : Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          width: modeText.implicitWidth + Style.space(16)
          height: Style.space(24)
          radius: Math.min(4, Style.cornerRadius)
          color: modeArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)

          Text {
            id: modeText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.mode === "scores" ? "Standings" : root.playerMode ? "‹ Box score" : "‹ Scores"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: modeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.playerMode) root.backFromPlayer()
              else if (root.boxMode) root.backFromBox()
              else root.toggleStandings()
            }
          }
        }

        // Spinner beside the title while a manual refresh is running: a round
        // 270-degree arc with rounded caps, drawn rather than a font glyph so
        // it stays smooth at any size and theme font.
        Shape {
          id: spinner
          readonly property real size: Style.space(16)
          readonly property real stroke: Math.max(2, Style.space(2))

          anchors.left: titleColumn.right
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          width: size
          height: size
          visible: root.manualRefresh
          layer.enabled: true
          layer.samples: 4

          ShapePath {
            strokeColor: root.fg
            strokeWidth: spinner.stroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
              centerX: spinner.size / 2
              centerY: spinner.size / 2
              radiusX: (spinner.size - spinner.stroke) / 2
              radiusY: (spinner.size - spinner.stroke) / 2
              startAngle: 0
              sweepAngle: 270
            }
          }

          RotationAnimator on rotation {
            running: root.manualRefresh
            from: 0; to: 360
            duration: 800
            loops: Animation.Infinite
          }
        }

        // "This week" appears only once you have wandered off it.
        Rectangle {
          id: todayButton
          visible: root.mode === "scores" && !root.viewingCurrent && root.currentKey !== ""
          anchors.right: nextButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: todayText.implicitWidth + Style.space(16)
          height: Style.space(24)
          radius: Math.min(4, Style.cornerRadius)
          color: todayArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)

          Text {
            id: todayText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "This week"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: todayArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.goCurrent()
          }
        }

        NavButton {
          id: nextButton
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "›"
          foreground: root.fg
          fontFamily: root.fontFamily
          visible: root.mode === "scores"
          enabled: root.viewIndex >= 0 && root.viewIndex < root.weeks.length - 1
          onClicked: root.stepWeek(1)
        }

        // Highlights of the game whose box score is open.
        Rectangle {
          id: boxRecap
          readonly property string videoId: root.boxMode && root.boxGame && root.boxGame.state === "post"
            ? recaps.videoId(root.boxId) : ""
          visible: videoId !== ""
          anchors.right: parent.right
          anchors.rightMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          width: boxRecapText.implicitWidth + Style.space(16)
          height: Style.space(24)
          radius: Math.min(4, Style.cornerRadius)
          color: boxRecapArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, boxRecapArea.containsMouse ? 0.5 : 0.25)

          Text {
            id: boxRecapText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "▶ Recap"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: boxRecapArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openRecap(boxRecap.videoId)
          }
        }
      }

      PanelSeparator {
        id: headerRule
        anchors.top: header.bottom
        foreground: root.fg
      }

      // ---- games -----------------------------------------------------------------
      ListView {
        id: list
        visible: root.mode === "scores"
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.viewRows

        // A refresh swaps the model for a fresh array, which snaps a plain
        // ListView back to the top. Remember where we were and go back there
        // (a week change zeroes keepY first, so that still starts at the top).
        property real keepY: 0
        property bool restoring: false
        onContentYChanged: if (!restoring) keepY = contentY
        onModelChanged: {
          restoring = true
          Qt.callLater(function() {
            list.contentY = Math.min(list.keepY, Math.max(0, list.contentHeight - list.height))
            list.restoring = false
          })
        }

        delegate: Item {
          id: row
          readonly property bool isDay: modelData.kind === "day"
          readonly property var game: modelData.game
          readonly property bool live: !isDay && game.state === "in"
          readonly property bool openable: !isDay && root.canOpenBox(game)
          readonly property bool current: !isDay && root.viewGames[root.selected] !== undefined
            && root.viewGames[root.selected].id === game.id

          width: list.width
          height: isDay ? Style.space(32) : Style.space(62)

          // A game that has kicked off opens its box score.
          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            radius: Math.min(4, Style.cornerRadius)
            color: Style.hoverFillFor(root.fg, Color.accent)
            visible: row.openable && (rowArea.containsMouse || row.current)
            opacity: rowArea.containsMouse ? 1 : 0.6
          }

          MouseArea {
            id: rowArea
            anchors.fill: parent
            enabled: !row.isDay
            hoverEnabled: true
            cursorShape: row.openable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              for (var i = 0; i < root.viewGames.length; i++)
                if (root.viewGames[i].id === row.game.id) root.selected = i
              if (row.openable) root.openBox(row.game.id)
            }
          }

          // Day header
          Text {
            visible: row.isDay
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(5)
            textFormat: Text.PlainText
            text: row.isDay ? modelData.label.toUpperCase() : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          // Game
          Item {
            visible: !row.isDay
            anchors.fill: parent

            Column {
              id: statusColumn
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(88)
              spacing: Style.space(2)

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.isDay ? "" : Model.statusText(row.game)
                color: row.live ? Color.urgent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.live
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.isDay ? "" : row.game.network
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Column {
              anchors.left: statusColumn.right
              anchors.leftMargin: Style.space(12)
              anchors.right: oddsText.left
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter

              TeamLine {
                team: row.isDay ? ({}) : row.game.away
                foreground: root.fg
                fontFamily: root.fontFamily
                showScore: !row.isDay && row.game.state !== "pre"
                finished: !row.isDay && row.game.state === "post"
              }
              TeamLine {
                team: row.isDay ? ({}) : row.game.home
                foreground: root.fg
                fontFamily: root.fontFamily
                showScore: !row.isDay && row.game.state !== "pre"
                finished: !row.isDay && row.game.state === "post"
              }
            }

            // Betting line, only while the game hasn't started.
            Text {
              id: oddsText
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(78)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: !row.isDay && row.game.state === "pre" ? row.game.odds : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // YouTube highlights, shown only once a real video has been found.
            Rectangle {
              id: recapPill
              readonly property string videoId: row.isDay || row.game.state !== "post" ? "" : recaps.videoId(row.game.id)
              visible: videoId !== ""
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: recapText.implicitWidth + Style.space(16)
              height: Style.space(24)
              radius: Math.min(4, Style.cornerRadius)
              color: recapArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, recapArea.containsMouse ? 0.5 : 0.25)

              Text {
                id: recapText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "▶ Recap"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: recapArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openRecap(recapPill.videoId)
              }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              height: 1
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            }
          }
        }

        // Empty / loading / error states.
        Text {
          anchors.centerIn: parent
          visible: list.count === 0
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage
            : (root.viewKey === "" || root.cache[root.viewKey] === undefined) ? "Loading…"
            : "No games scheduled"
          color: root.errorMessage !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      // ---- standings ---------------------------------------------------------------
      ListView {
        id: standingsList
        visible: root.standingsMode
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.standingsRows

        // Same refresh-keeps-position handling as the scores list.
        property real keepY: 0
        property bool restoring: false
        onContentYChanged: if (!restoring) keepY = contentY
        onModelChanged: {
          restoring = true
          Qt.callLater(function() {
            standingsList.contentY = Math.min(standingsList.keepY, Math.max(0, standingsList.contentHeight - standingsList.height))
            standingsList.restoring = false
          })
        }

        delegate: Item {
          id: srow
          readonly property bool isDiv: modelData.kind === "div"
          readonly property var t: modelData.team

          width: standingsList.width
          height: isDiv ? Style.space(36) : Style.space(30)

          // Division header, with the column labels on its right.
          Item {
            visible: srow.isDiv
            anchors.fill: parent

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(5)
              textFormat: Text.PlainText
              text: srow.isDiv ? modelData.label.toUpperCase() : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }
            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(5)
              spacing: Style.space(6)

              Repeater {
                model: root.statColumns
                Text {
                  width: Style.space(modelData.w)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }
            }
          }

          // Team
          Item {
            visible: !srow.isDiv
            anchors.fill: parent

            Image {
              id: teamLogo
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.space(22)
              source: srow.isDiv ? "" : (srow.t.logo || "")
              visible: status === Image.Ready
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Style.space(44)
              sourceSize.height: Style.space(44)
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(46)
              anchors.right: statRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: srow.isDiv ? "" : srow.t.name
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: !srow.isDiv && srow.t.leader
            }

            Row {
              id: statRow
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Repeater {
                model: root.statColumns
                Text {
                  width: Style.space(modelData.w)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: srow.isDiv ? "" : (srow.t[modelData.key] || "")
                  // Record and streak are the headline figures; the rest recede.
                  color: modelData.key === "rec" ? root.fg : Qt.darker(root.fg, 1.25)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: modelData.key === "rec" && !srow.isDiv && srow.t.leader
                }
              }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              height: 1
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: standingsList.count === 0
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage : "Loading…"
          color: root.errorMessage !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      // ---- box score -----------------------------------------------------------------
      ListView {
        id: boxList
        visible: root.boxMode
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.boxRows

        // Same refresh-keeps-position handling as the scores list (live games
        // refresh every 30s).
        property real keepY: 0
        property bool restoring: false
        onContentYChanged: if (!restoring) keepY = contentY
        onModelChanged: {
          restoring = true
          Qt.callLater(function() {
            boxList.contentY = Math.min(boxList.keepY, Math.max(0, boxList.contentHeight - boxList.height))
            boxList.restoring = false
          })
        }

        delegate: Item {
          id: brow
          readonly property var d: modelData
          readonly property string kind: d.kind
          // A player's line under the pointer: it opens his card.
          readonly property bool hovered: kind === "line" && !!d.id && playerArea.containsMouse

          width: boxList.width
          height: kind === "lines" ? Style.space(26) * 3 + Style.space(20)
            : kind === "team" ? Style.space(52)
            : kind === "head" ? Style.space(34)
            : Style.space(26)

          Rectangle {
            visible: brow.hovered
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            radius: Math.min(4, Style.cornerRadius)
            color: Style.hoverFillFor(root.fg, Color.accent)
          }

          // Quarter-by-quarter scoring.
          Column {
            visible: brow.kind === "lines"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
              model: brow.kind === "lines" && root.box ? [null].concat(root.box.teams) : []

              Row {
                readonly property var t: modelData
                height: Style.space(26)
                spacing: Style.space(6)

                Text {
                  width: Style.space(56)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: parent.t ? parent.t.abbr : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: parent.t && parent.t.winner
                }
                Repeater {
                  model: root.box ? root.box.periods : []
                  Text {
                    width: Style.space(32)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: parent.t ? (parent.t.lines[index] || "") : modelData
                    color: parent.t ? Qt.darker(root.fg, 1.25) : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: parent.t ? Style.font.body : Style.font.caption
                  }
                }
                Text {
                  width: Style.space(44)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: parent.t ? parent.t.score : "T"
                  color: parent.t ? root.fg : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: parent.t ? Style.font.body : Style.font.caption
                  font.bold: !!parent.t
                }
              }
            }
          }

          // Team banner.
          Row {
            visible: brow.kind === "team"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            spacing: Style.space(10)

            Image {
              width: Style.space(26)
              height: Style.space(26)
              anchors.verticalCenter: parent.verticalCenter
              source: brow.kind === "team" ? (brow.d.team.logo || "") : ""
              visible: status === Image.Ready
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Style.space(52)
              sourceSize.height: Style.space(52)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: brow.kind === "team" ? brow.d.team.fullName || brow.d.team.name : ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: brow.kind === "team" ? brow.d.team.score : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // Scoring play: quarter and clock, team, what happened, the score after.
          Item {
            visible: brow.kind === "play"
            anchors.fill: parent

            Text {
              id: playWhen
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(76)
              textFormat: Text.PlainText
              text: brow.kind === "play" ? brow.d.period + "  " + brow.d.clock : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              id: playTeam
              anchors.left: playWhen.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(44)
              textFormat: Text.PlainText
              text: brow.kind === "play" ? brow.d.abbr : ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              anchors.left: playTeam.right
              anchors.right: playScore.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: brow.kind === "play" ? brow.d.text : ""
              color: Qt.darker(root.fg, 1.25)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              id: playScore
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: brow.kind === "play" ? brow.d.score : ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // Section headings and lines share one layout: name on the left,
          // the columns on the right.
          Text {
            visible: brow.kind === "head" || brow.kind === "line"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.right: cellRow.left
            anchors.rightMargin: Style.space(8)
            anchors.bottom: brow.kind === "head" ? parent.bottom : undefined
            anchors.bottomMargin: Style.space(6)
            anchors.verticalCenter: brow.kind === "head" ? undefined : parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: brow.kind === "head" ? brow.d.label : brow.kind === "line" ? brow.d.name : ""
            color: brow.kind === "head" ? root.dim : root.fg
            font.family: root.fontFamily
            font.pixelSize: brow.kind === "head" ? Style.font.caption : Style.font.body
            font.letterSpacing: brow.kind === "head" ? 1 : 0
          }

          Row {
            id: cellRow
            visible: brow.kind === "head" || brow.kind === "line"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            anchors.bottom: brow.kind === "head" ? parent.bottom : undefined
            anchors.bottomMargin: Style.space(6)
            anchors.verticalCenter: brow.kind === "head" ? undefined : parent.verticalCenter
            spacing: Style.space(6)

            Repeater {
              model: brow.kind === "head" || brow.kind === "line" ? brow.d.cells : []
              Text {
                width: Style.space(modelData.w)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: modelData.text
                color: brow.kind === "head" ? root.dim
                  : modelData.lead ? root.fg : Qt.darker(root.fg, 1.25)
                font.family: root.fontFamily
                font.pixelSize: brow.kind === "head" ? Style.font.caption : Style.font.body
                font.bold: modelData.top === true
              }
            }
          }

          // Over everything else in the line, so no text under the pointer
          // can take the hover from it.
          MouseArea {
            id: playerArea
            anchors.fill: parent
            z: 10
            enabled: brow.kind === "line" && !!brow.d.id
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.openPlayer(brow.d.id)
          }

          Rectangle {
            visible: brow.kind === "line" || brow.kind === "play" || brow.kind === "head"
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(16)
            height: 1
            color: brow.kind === "head" ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.2) : root.hairline
          }
        }

        Text {
          anchors.centerIn: parent
          visible: boxList.count === 0
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage : "Loading…"
          color: root.errorMessage !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      // ---- player card ------------------------------------------------------------------
      ListView {
        id: playerList
        visible: root.playerMode
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.playerRows

        delegate: Item {
          id: prow
          readonly property var d: modelData
          readonly property string kind: d.kind

          width: playerList.width
          height: kind === "bio" ? bioBlock.height + Style.space(24)
            : kind === "section" ? Style.space(38)
            : kind === "head" ? Style.space(30)
            : Style.space(26)

          // Photo and facts.
          Item {
            id: bioBlock
            visible: prow.kind === "bio"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Style.space(14)
            height: Math.max(photo.height, facts.height)

            Image {
              id: photo
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              width: Style.space(130)
              height: Style.space(95)
              source: prow.kind === "bio" && root.player ? root.player.headshot : ""
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Style.space(260)
              sourceSize.height: Style.space(190)
            }

            Grid {
              id: facts
              anchors.left: photo.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              columns: 2
              columnSpacing: Style.space(14)
              rowSpacing: Style.space(5)

              Repeater {
                model: {
                  var p = root.player
                  if (prow.kind !== "bio" || !p) return []
                  var f = []
                  if (p.age) f.push(["AGE", p.age + (p.dob ? "  (" + p.dob + ")" : "")])
                  f.push(["SIZE", [Model.heightText(p.height), Model.weightText(p.weight)].filter(function(s) { return s }).join(" · ")])
                  if (p.birthplace) f.push(["BORN", p.birthplace])
                  f.push(["DRAFT", p.draft])
                  f.push(["COLLEGE", p.college || "—"])
                  if (p.experience) f.push(["NFL", p.experience])
                  if (p.injury) f.push(["INJURY", p.injury])
                  var out = []
                  for (var i = 0; i < f.length; i++) { out.push({ t: "k", v: f[i][0] }); out.push({ t: "v", v: f[i][1], k: f[i][0] }) }
                  return out
                }
                Text {
                  width: modelData.t === "k" ? Style.space(60) : facts.width - Style.space(60) - facts.columnSpacing
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: modelData.v
                  color: modelData.t === "k" ? root.dim : modelData.k === "INJURY" ? Color.urgent : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: modelData.t === "k" ? Style.font.caption : Style.font.body
                  font.letterSpacing: modelData.t === "k" ? 1 : 0
                }
              }
            }
          }

          Text {
            visible: prow.kind === "section"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(6)
            textFormat: Text.PlainText
            text: prow.kind === "section" ? prow.d.label.toUpperCase() : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
            font.bold: true
          }

          // Table name and column heads, or a stat line: label and team on
          // the left, the columns on the right, as in the box score.
          Row {
            visible: prow.kind === "line" || prow.kind === "head"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.bottom: prow.kind === "head" ? parent.bottom : undefined
            anchors.bottomMargin: Style.space(6)
            anchors.verticalCenter: prow.kind === "head" ? undefined : parent.verticalCenter
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
              text: prow.kind === "line" || prow.kind === "head" ? prow.d.label : ""
              color: prow.kind === "head" ? root.dim : root.fg
              font.family: root.fontFamily
              font.pixelSize: prow.kind === "head" ? Style.font.caption : Style.font.body
              font.letterSpacing: prow.kind === "head" ? 1 : 0
              font.bold: prow.kind === "line" && prow.d.strong
            }
            Text {
              textFormat: Text.PlainText
              text: prow.kind === "line" ? prow.d.sub : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
          Row {
            visible: prow.kind === "line" || prow.kind === "head"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            anchors.bottom: prow.kind === "head" ? parent.bottom : undefined
            anchors.bottomMargin: Style.space(6)
            anchors.verticalCenter: prow.kind === "head" ? undefined : parent.verticalCenter
            spacing: Style.space(6)

            Repeater {
              model: prow.kind === "line" || prow.kind === "head" ? prow.d.cells : []
              Text {
                width: Style.space(modelData.w)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: modelData.text
                color: prow.kind === "head" ? root.dim : Qt.darker(root.fg, 1.15)
                font.family: root.fontFamily
                font.pixelSize: prow.kind === "head" ? Style.font.caption : Style.font.body
                font.bold: prow.kind === "line" && modelData.top === true
              }
            }
          }

          // Salary: season, team, amount. The seasons to come recede.
          Row {
            visible: prow.kind === "salary"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            opacity: prow.kind === "salary" && prow.d.future ? 0.7 : 1
            Text {
              textFormat: Text.PlainText
              text: prow.kind === "salary" ? prow.d.season : ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: prow.kind === "salary" && prow.d.current === true
            }
            Text {
              textFormat: Text.PlainText
              text: prow.kind === "salary" ? prow.d.team : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              textFormat: Text.PlainText
              text: prow.kind === "salary" ? prow.d.note : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            visible: prow.kind === "salary"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            opacity: prow.kind === "salary" && prow.d.future ? 0.7 : 1
            textFormat: Text.PlainText
            text: prow.kind === "salary" ? prow.d.salary : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: prow.kind === "salary" && prow.d.current === true
          }

          // Award: what, how many times; the seasons on the right.
          Text {
            id: awardName
            visible: prow.kind === "award"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: prow.kind === "award" ? prow.d.label : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            visible: prow.kind === "award"
            anchors.left: awardName.right
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            textFormat: Text.PlainText
            text: prow.kind === "award" ? prow.d.sub : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Rectangle {
            visible: prow.kind === "line" || prow.kind === "salary" || prow.kind === "award" || prow.kind === "head"
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(16)
            height: 1
            color: prow.kind === "head" ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.2) : root.hairline
          }
        }

        Text {
          anchors.centerIn: parent
          visible: playerList.count === 0
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage : "Loading…"
          color: root.errorMessage !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      // ---- footer: key hints --------------------------------------------------------
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(26)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.manualRefresh ? "Refreshing…"
            : root.errorMessage !== "" && root.activeRowCount > 0
            ? "Offline — showing last " + (root.standingsMode ? "standings" : root.boxMode ? "box score"
              : root.playerMode ? "card" : "scores")
            : root.standingsMode ? "s scores   r refresh   esc close"
            : root.boxMode ? "←/→ game   click a player for his card   y recap   esc back"
            : root.playerMode ? "↑/↓ scroll   esc back to the box score"
            : "←/→ week   ↑/↓ + enter box score   y recap   s standings   t this week   esc close"
          color: root.manualRefresh ? root.fg
            : root.errorMessage !== "" && root.activeRowCount > 0 ? Color.urgent : Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Small square chevron button for the header.
  component NavButton: Rectangle {
    id: nav
    property string glyph: ""
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    signal clicked()

    width: Style.space(30)
    height: Style.space(30)
    radius: Math.min(4, Style.cornerRadius)
    opacity: enabled ? 1 : 0.3
    color: enabled && navArea.containsMouse ? Style.hoverFillFor(nav.foreground, Color.accent) : "transparent"

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(2)
      textFormat: Text.PlainText
      text: nav.glyph
      color: nav.foreground
      font.family: nav.fontFamily
      font.pixelSize: Style.font.display
    }
    MouseArea {
      id: navArea
      anchors.fill: parent
      enabled: nav.enabled
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: nav.clicked()
    }
  }
}
