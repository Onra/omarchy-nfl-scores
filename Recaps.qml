import QtQuick
import Quickshell.Io

// Looks up YouTube highlight videos for finished games through recap.py and
// keeps the answers. want(entries) is cheap to call repeatedly: games already
// answered (or in flight) are skipped, and a miss is only asked again after
// retryMs, since highlights are posted hours after a game ends.
Item {
  id: root

  readonly property string script: Qt.resolvedUrl("recap.py").toString().replace("file://", "")
  readonly property int retryMs: 30 * 60 * 1000

  property var results: ({})   // gameId -> { yt, title, at }
  property int version: 0
  property bool busy: false
  property var pending: []     // entries waiting for the running batch to end
  property var inFlight: ({})  // gameId -> true

  function videoId(gameId) {
    root.version  // dependency: bindings re-run when answers arrive
    var r = root.results[gameId]
    return r ? r.yt : ""
  }

  function stale(id) {
    var r = root.results[id]
    if (!r) return true
    return r.yt === "" && Date.now() - r.at > root.retryMs
  }

  function want(entries) {
    var fresh = []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (root.inFlight[e.id] || !root.stale(e.id)) continue
      var queued = false
      for (var j = 0; j < root.pending.length; j++)
        if (root.pending[j].id === e.id) { queued = true; break }
      if (!queued) fresh.push(e)
    }
    if (fresh.length === 0) return
    root.pending = root.pending.concat(fresh)
    if (!root.busy) root.run()
  }

  function run() {
    var batch = root.pending
    root.pending = []
    if (batch.length === 0) return
    var flight = ({})
    for (var i = 0; i < batch.length; i++) flight[batch[i].id] = true
    root.inFlight = flight
    root.busy = true
    proc.command = ["python3", root.script, JSON.stringify(batch)]
    proc.running = true
  }

  Process {
    id: proc
    stdout: SplitParser {
      onRead: function(line) {
        var r = null
        try { r = JSON.parse(line) } catch (e) { return }
        var next = ({})
        for (var k in root.results) next[k] = root.results[k]
        next[r.id] = { yt: r.yt || "", title: r.title || "", at: Date.now() }
        root.results = next
        root.version++
      }
    }
    onExited: {
      root.busy = false
      root.inFlight = ({})
      if (root.pending.length > 0) Qt.callLater(root.run)
    }
  }
}
