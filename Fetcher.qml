import QtQuick
import Quickshell.Io

// One-at-a-time JSON fetch over curl. fetch(url) while a run is in flight
// remembers the newest wish and re-runs when the current one exits, so quick
// week-to-week navigation never stacks processes.
Item {
  id: root

  property string activeUrl: ""
  property string wantedUrl: ""
  property bool busy: false
  property bool again: false

  signal loaded(string url, var json)
  signal failed(string url)

  function fetch(url) {
    if (root.busy) {
      if (url !== root.activeUrl) {
        root.wantedUrl = url
        root.again = true
      }
      return
    }
    root.start(url)
  }

  function start(url) {
    root.activeUrl = url
    root.again = false
    root.busy = true
    proc.command = ["curl", "-fsS", "--max-time", "10", url]
    proc.running = true
  }

  Process {
    id: proc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        var parsed = null
        if (raw) {
          try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
        }
        if (parsed) root.loaded(root.activeUrl, parsed)
        else root.failed(root.activeUrl)
      }
    }
    onExited: {
      root.busy = false
      if (root.again) Qt.callLater(function() { root.start(root.wantedUrl) })
    }
  }
}
