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

  // "scores" (default: the current week) or "standings" (by division). Opening
  // the panel always returns to scores.
  property string mode: "scores"
  readonly property bool standingsMode: root.mode === "standings"
  property var standingsRows: []
  property int standingsYear: 0
  readonly property int activeRowCount: root.standingsMode ? root.standingsRows.length : root.viewRows.length
  readonly property var activeList: root.standingsMode ? standingsList : list

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

  function refresh() {
    root.fetchCurrent()
    if (root.standingsMode) root.fetchStandings()
    else if (!root.viewingCurrent) root.fetchView()
  }

  // A refresh the user asked for (r key, IPC) shows a spinner and a footer
  // note. It stays up for at least minRefreshMs so a fast fetch is still
  // visible, and until both fetchers are idle. Background polling stays silent.
  property bool manualRefresh: false
  readonly property int minRefreshMs: 800

  function refreshNow() {
    root.manualRefresh = true
    refreshFloor.restart()
    root.refresh()
  }

  function settleRefresh() {
    if (!root.manualRefresh || refreshFloor.running) return
    if (currentFetcher.busy || viewFetcher.busy || standingsFetcher.busy) return
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
    Quickshell.execDetached(["xdg-open", "https://www.youtube.com/watch?v=" + videoId])
    root.close()
  }

  // Every 30s while a game is live, every 5 minutes otherwise. The viewed
  // week is only refreshed while the panel is on screen.
  Timer {
    interval: root.liveGames > 0 ? 30000 : 300000
    running: true
    repeat: true
    onTriggered: {
      root.fetchCurrent()
      if (root.opened && root.standingsMode) root.fetchStandings()
      else if (root.opened && !root.viewingCurrent) root.fetchView()
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
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(
      Math.max(Style.space(320), header.height + root.activeList.contentHeight + footer.height + Style.space(24)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) { if (!root.standingsMode) root.stepWeek(dx) }
        else root.scrollBy(dy * Style.space(80))
      }
      onTextKey: function(t) {
        if (t === "t") { root.showScores(); root.goCurrent() }
        else if (t === "s") root.toggleStandings()
        else if (t === "r") root.refreshNow()
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
          visible: !root.standingsMode
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
            text: root.standingsMode ? "Standings" : root.viewWeek ? root.viewWeek.label : "NFL"
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

        // Switches between the scores and the standings views.
        Rectangle {
          id: modeButton
          anchors.left: parent.left
          anchors.leftMargin: root.standingsMode ? Style.space(12) : Style.space(50)
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
            text: root.standingsMode ? "‹ Scores" : "Standings"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: modeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleStandings()
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
          visible: !root.standingsMode && !root.viewingCurrent && root.currentKey !== ""
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
          visible: !root.standingsMode
          enabled: root.viewIndex >= 0 && root.viewIndex < root.weeks.length - 1
          onClicked: root.stepWeek(1)
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
        visible: !root.standingsMode
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

          width: list.width
          height: isDay ? Style.space(32) : Style.space(62)

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
            ? "Offline — showing last " + (root.standingsMode ? "standings" : "scores")
            : root.standingsMode ? "s scores   r refresh   esc close"
            : "←/→ week   s standings   t this week   r refresh   esc close"
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
