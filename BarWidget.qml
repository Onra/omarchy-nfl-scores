import QtQuick
import qs.Ui

// Bar entry point: football glyph, current week and live-game count. Data
// fetching and the scores panel live in Panel.qml (loaded once, panel opens on
// click), mirroring the structure of the first-party weather plugin.
BarWidget {
  id: root
  moduleName: "onra.nfl-scores"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (Bar.requestPopout prefers closeForPopoutSwitch over close).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Glyph only on vertical bars; glyph + week (+ live count) on horizontal.
    text: panelLoader.item
      ? (root.vertical ? panelLoader.item.barIcon : panelLoader.item.barText)
      : ""
    dimmed: panelLoader.item ? !panelLoader.item.hasData : true
    // Tooltip suppressed: the panel is the detail view.
    tooltipText: ""
    // Something live right now reads in the bar's active colour.
    active: panelLoader.item ? panelLoader.item.liveGames > 0 : false

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b !== Qt.RightButton) root.togglePanel()
    }
  }
}
