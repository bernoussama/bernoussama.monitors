import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Draggable 2D layout editor for Hyprland monitor positions.
// Summon with `omarchy-shell shell toggle bernoussama.monitors`.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool applying: false
  property string statusText: ""
  property int movedCount: 0
  property bool fixXAxis: true
  property int selectedIndex: 0
  readonly property var selectedMonitor: (selectedIndex >= 0 && selectedIndex < monitorModel.count) ? monitorModel.get(selectedIndex) : null
  onSelectedIndexChanged: {
    if (root.selectedMonitor) {
      resWField.text = String(root.selectedMonitor.width)
      resHField.text = String(root.selectedMonitor.height)
      rrField.text = String(root.selectedMonitor.refreshRate)
    }
  }
  property string fontFamily: Style.font.menuFamily

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property color dimmed: Qt.darker(foreground, 1.4)
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding

  // Canvas view state. viewK maps logical monitor px to UI px.
  readonly property int viewPad: Style.space(32)
  readonly property int snapThreshold: 24
  readonly property int gridStep: 10
  property real viewK: 0.1
  property real viewMinX: 0
  property real viewMinY: 0

  function open(payloadJson) {
    root.opened = true
    root.statusText = ""
    root.reload()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "bernoussama.monitors")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function scriptPath() {
    if (root.manifest && root.manifest.__sourceDir) return root.manifest.__sourceDir + "/apply-monitors"
    return Qt.resolvedUrl("apply-monitors").toString().replace(/^file:\/\//, "")
  }

  function reload() {
    if (monitorsProc.running) return
    monitorsProc.running = true
  }

  function loadMonitors(raw) {
    var list = []
    try { list = JSON.parse(String(raw || "[]")) } catch (e) { list = [] }
    monitorModel.clear()
    var selIdx = 0
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      if (!m || !m.name) continue
      var scale = Number(m.scale) || 1
      var w = Number(m.width) || 1920
      var h = Number(m.height) || 1080
      var rr = Math.round((Number(m.refreshRate) || 60) * 100) / 100
      var modes = Array.isArray(m.availableModes) ? m.availableModes : []
      if (m.focused) selIdx = monitorModel.count

      monitorModel.append({
        name: String(m.name),
        desc: String(m.description || m.model || m.name),
        posX: Math.round(Number(m.x) || 0),
        posY: Math.round(Number(m.y) || 0),
        origX: Math.round(Number(m.x) || 0),
        origY: Math.round(Number(m.y) || 0),
        width: w,
        height: h,
        origWidth: w,
        origHeight: h,
        lw: Math.round(w / scale),
        lh: Math.round(h / scale),
        scaleFactor: scale,
        origScale: scale,
        refreshRate: rr,
        origRefreshRate: rr,
        availableModes: modes,
        transformValue: Number(m.transform) || 0,
        focused: m.focused === true,
        locked: String(m.mirrorOf || "none") !== "none",
        moved: false
      })
    }
    if (monitorModel.count > 0) {
      if (selIdx >= monitorModel.count) selIdx = 0
      root.selectedIndex = selIdx
    }
    root.syncMovedCount()
    root.recomputeView()
  }

  function checkMonitorMoved(index) {
    var m = monitorModel.get(index)
    if (!m) return
    var isMoved = (m.posX !== m.origX || m.posY !== m.origY
      || m.width !== m.origWidth || m.height !== m.origHeight
      || m.refreshRate !== m.origRefreshRate || m.scaleFactor !== m.origScale)
    monitorModel.setProperty(index, "moved", isMoved)
    root.syncMovedCount()
  }

  function setMonitorResolution(index, w, h) {
    var m = monitorModel.get(index)
    if (!m || m.locked) return
    var nw = Math.max(320, parseInt(w) || m.origWidth)
    var nh = Math.max(240, parseInt(h) || m.origHeight)
    var nlw = Math.round(nw / m.scaleFactor)
    var nlh = Math.round(nh / m.scaleFactor)
    monitorModel.setProperty(index, "width", nw)
    monitorModel.setProperty(index, "height", nh)
    monitorModel.setProperty(index, "lw", nlw)
    monitorModel.setProperty(index, "lh", nlh)
    root.checkMonitorMoved(index)
    root.recomputeView()
  }

  function setMonitorRefreshRate(index, rr) {
    var m = monitorModel.get(index)
    if (!m || m.locked) return
    var nrr = Math.max(1, parseFloat(rr) || m.origRefreshRate)
    monitorModel.setProperty(index, "refreshRate", nrr)
    root.checkMonitorMoved(index)
  }

  function setMonitorMode(index, modeStr) {
    var match = String(modeStr || "").match(/^(\d+)x(\d+)(?:@([\d\.]+)Hz)?/)
    if (match) {
      var nw = parseInt(match[1])
      var nh = parseInt(match[2])
      var nrr = match[3] ? parseFloat(match[3]) : 60
      root.setMonitorResolution(index, nw, nh)
      root.setMonitorRefreshRate(index, nrr)
    }
  }

  function syncMovedCount() {
    var n = 0
    for (var i = 0; i < monitorModel.count; i++)
      if (monitorModel.get(i).moved) n++
    root.movedCount = n
  }

  // Fit all monitors into the canvas with outer edge padding.
  function recomputeView() {
    if (monitorModel.count === 0) return
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < monitorModel.count; i++) {
      var m = monitorModel.get(i)
      minX = Math.min(minX, m.posX)
      minY = Math.min(minY, m.posY)
      maxX = Math.max(maxX, m.posX + m.lw)
      maxY = Math.max(maxY, m.posY + m.lh)
    }
    var spanW = maxX - minX
    var spanH = maxY - minY
    var availW = workspace.width - root.viewPad * 2
    var availH = workspace.height - root.viewPad * 2
    if (availW <= 0 || availH <= 0 || spanW <= 0 || spanH <= 0) return

    var k = Math.min(availW / spanW, availH / spanH, 0.22)
    root.viewK = k

    var contentW = spanW * k
    var contentH = spanH * k
    var offsetX = (availW - contentW) / 2
    var offsetY = (availH - contentH) / 2
    root.viewMinX = minX - (offsetX / k)
    root.viewMinY = minY - (offsetY / k)
  }

  // Keep a dragged monitor visible by shifting the origin, without rescaling.
  function extendViewOrigin(x, y) {
    if (x < root.viewMinX) root.viewMinX = x
    if (y < root.viewMinY) root.viewMinY = y
  }

  // Snap the dragged monitor to another monitor's edges (adjacency and
  // alignment), else fall back to a grid step.
  function snapMonitor(index) {
    var m = monitorModel.get(index)
    if (!m || m.locked) return
    var bestX = null, bestY = null
    var dx = root.snapThreshold + 1, dy = root.snapThreshold + 1
    for (var i = 0; i < monitorModel.count; i++) {
      if (i === index) continue
      var o = monitorModel.get(i)
      var xc = [o.posX - m.lw, o.posX + o.lw, o.posX, o.posX + o.lw - m.lw]
      var yc = [o.posY - m.lh, o.posY + o.lh, o.posY, o.posY + o.lh - m.lh]
      for (var a = 0; a < xc.length; a++) {
        var dxa = Math.abs(xc[a] - m.posX)
        if (dxa < dx) { dx = dxa; bestX = xc[a] }
      }
      for (var b = 0; b < yc.length; b++) {
        var dya = Math.abs(yc[b] - m.posY)
        if (dya < dy) { dy = dya; bestY = yc[b] }
      }
    }
    var nx = root.fixXAxis ? m.origX : ((bestX !== null && dx <= root.snapThreshold)
      ? bestX : Math.round(m.posX / root.gridStep) * root.gridStep)
    var ny = (bestY !== null && dy <= root.snapThreshold)
      ? bestY : Math.round(m.posY / root.gridStep) * root.gridStep
    monitorModel.setProperty(index, "posX", nx)
    monitorModel.setProperty(index, "posY", ny)
    root.checkMonitorMoved(index)
  }

  function resetLayout() {
    for (var i = 0; i < monitorModel.count; i++) {
      var m = monitorModel.get(i)
      monitorModel.setProperty(i, "posX", m.origX)
      monitorModel.setProperty(i, "posY", m.origY)
      monitorModel.setProperty(i, "width", m.origWidth)
      monitorModel.setProperty(i, "height", m.origHeight)
      monitorModel.setProperty(i, "lw", Math.round(m.origWidth / m.origScale))
      monitorModel.setProperty(i, "lh", Math.round(m.origHeight / m.origScale))
      monitorModel.setProperty(i, "refreshRate", m.origRefreshRate)
      monitorModel.setProperty(i, "scaleFactor", m.origScale)
      monitorModel.setProperty(i, "moved", false)
    }
    root.statusText = ""
    root.syncMovedCount()
    root.recomputeView()
  }

  function commitActiveInputs() {
    if (!root.selectedMonitor) return
    var w = parseInt(resWField.text)
    var h = parseInt(resHField.text)
    var rr = parseFloat(rrField.text)
    if (!isNaN(w) && !isNaN(h) && (w !== root.selectedMonitor.width || h !== root.selectedMonitor.height))
      root.setMonitorResolution(root.selectedIndex, w, h)
    if (!isNaN(rr) && rr !== root.selectedMonitor.refreshRate)
      root.setMonitorRefreshRate(root.selectedIndex, rr)
  }

  function applyLayout() {
    root.commitActiveInputs()
    if (root.applying || root.movedCount === 0) return
    var payload = []
    for (var i = 0; i < monitorModel.count; i++) {
      var m = monitorModel.get(i)
      if (!m.locked) {
        payload.push({
          name: m.name,
          x: m.posX,
          y: m.posY,
          width: m.width,
          height: m.height,
          refreshRate: m.refreshRate,
          scale: m.scaleFactor
        })
      }
    }
    if (payload.length === 0) return
    root.applying = true
    root.statusText = ""
    applyProc.command = [root.scriptPath(), JSON.stringify(payload)]
    applyProc.running = true
  }

  ListModel { id: monitorModel }

  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector { id: monitorsOut; waitForEnd: true }
    onExited: root.loadMonitors(monitorsOut.text)
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      root.statusText = exitCode === 0
        ? (applyOut.text || "").trim()
        : "Failed: " + (applyErr.text || "").trim().slice(0, 120)
      if (exitCode === 0) root.reload()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "bernoussama-monitors"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(860), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape
              || ((event.modifiers & Qt.MetaModifier)
                && (event.key === Qt.Key_Q || event.key === Qt.Key_W))) {
            root.dismiss()
            event.accepted = true
          }
        }

        Item {
          id: content
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          anchors.rightMargin: card.contentRightInset

          // ---------- Header ----------
          Item {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: Math.max(iconText.implicitHeight, titleCol.implicitHeight, headerStatus.implicitHeight)

            Text {
              id: iconText
              text: "󰍹"
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: titleCol
              anchors {
                left: iconText.right
                leftMargin: Style.space(10)
                verticalCenter: parent.verticalCenter
              }

              Text {
                text: "Monitor Layout"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Bold
              }

              Text {
                text: "Drag to arrange · edges snap · Apply saves to hypr config"
                color: root.dimmed
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: headerStatusPill
              visible: root.movedCount > 0
              width: headerStatus.implicitWidth + Style.space(10)
              height: headerStatus.implicitHeight + Style.space(6)
              radius: height / 2
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
              border.width: 1
              border.color: Color.accent
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: headerStatus
                text: root.movedCount > 0 ? "● " + root.movedCount + " UNSAVED" : ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.centerIn: parent
              }
            }

            Text {
              visible: root.movedCount === 0
              text: monitorModel.count + (monitorModel.count === 1 ? " DISPLAY" : " DISPLAYS")
              color: root.dimmed
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSeparator {
            id: headerSep
            anchors {
              top: header.bottom
              left: parent.left
              right: parent.right
              topMargin: Style.space(8)
            }
            foreground: root.foreground
          }

          // ---------- Layout section ----------
          Item {
            id: layoutHeader
            anchors {
              top: headerSep.bottom
              left: parent.left
              right: parent.right
              topMargin: Style.space(10)
            }
            height: Math.max(layoutLabel.implicitHeight, fixXRow.implicitHeight, syncText.implicitHeight)

            PanelSectionHeader {
              id: layoutLabel
              text: "LAYOUT"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: fixXRow
              anchors.right: syncText.left
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                text: "Lock X axis"
                color: root.fixXAxis ? root.foreground : root.dimmed
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              ToggleSwitch {
                checked: root.fixXAxis
                onToggled: root.fixXAxis = !root.fixXAxis
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              id: syncText
              text: root.movedCount > 0 ? root.movedCount + " moved" : "in sync"
              color: root.movedCount > 0 ? Color.accent : root.dimmed
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Rectangle {
            id: workspace
            clip: true
            anchors {
              top: layoutHeader.bottom
              left: parent.left
              right: parent.right
              bottom: propsSep.top
              topMargin: Style.space(4)
              bottomMargin: Style.space(8)
            }
            radius: Math.max(4, root.cornerRadius - Style.space(4))
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            onWidthChanged: root.recomputeView()
            onHeightChanged: root.recomputeView()

            Text {
              text: "No monitors detected"
              color: root.dimmed
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.centerIn: parent
              visible: monitorModel.count === 0
            }

            Repeater {
              model: monitorModel

              Rectangle {
                id: monRect

                required property int index
                required property string name
                required property int posX
                required property int posY
                required property int origX
                required property int origY
                required property int lw
                required property int lh
                required property real scaleFactor
                required property real refreshRate
                required property bool focused
                required property bool locked
                required property bool moved
                readonly property bool isSelected: root.selectedIndex === monRect.index

                x: root.viewPad + (monRect.posX - root.viewMinX) * root.viewK
                y: root.viewPad + (monRect.posY - root.viewMinY) * root.viewK
                width: Math.max(2, monRect.lw * root.viewK)
                height: Math.max(2, monRect.lh * root.viewK)
                radius: Math.max(3, root.cornerRadius / 2)
                color: monRect.isSelected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
                  : (monRect.focused
                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                    : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08))
                border.width: monRect.isSelected ? 2 : (monRect.focused || monRect.moved ? Math.max(2, Style.space(1)) : 1)
                border.color: monRect.isSelected || ((monRect.focused || monRect.moved) && !monRect.locked)
                  ? Color.accent
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, dragArea.containsMouse && !monRect.locked ? 0.5 : 0.3)
                opacity: monRect.locked ? 0.45 : 1

                Behavior on x { enabled: !dragArea.pressed; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on y { enabled: !dragArea.pressed; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                // Manual drag: the model position updates so bindings stay
                // live and nothing rescales mid-drag.
                MouseArea {
                  id: dragArea
                  anchors.fill: parent
                  enabled: !monRect.locked
                  cursorShape: monRect.locked ? Qt.ForbiddenCursor : (root.fixXAxis ? Qt.SizeVerCursor : Qt.SizeAllCursor)
                  hoverEnabled: true

                  property real grabMx
                  property real grabMy
                  property real startLx
                  property real startLy

                  onPressed: function(mouse) {
                    root.selectedIndex = monRect.index
                    grabMx = mouse.x
                    grabMy = mouse.y
                    startLx = monRect.posX
                    startLy = monRect.posY
                  }

                  onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var nx = root.fixXAxis ? startLx : Math.round(startLx + (mouse.x - grabMx) / root.viewK)
                    var ny = Math.round(startLy + (mouse.y - grabMy) / root.viewK)
                    monitorModel.setProperty(monRect.index, "posX", nx)
                    monitorModel.setProperty(monRect.index, "posY", ny)
                    root.extendViewOrigin(nx, ny)
                  }

                  onReleased: {
                    root.snapMonitor(monRect.index)
                    root.recomputeView()
                  }
                }

                Text {
                  text: monRect.locked ? "󰁌" : "󰍹"
                  color: monRect.isSelected ? Color.accent : root.dimmed
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconSmall
                  anchors { top: parent.top; left: parent.left; margins: Style.space(4) }
                  visible: monRect.height > Style.space(30) && monRect.width > Style.space(60)
                }

                Text {
                  text: "⠿"
                  color: monRect.isSelected ? Color.accent : root.dimmed
                  opacity: dragArea.containsMouse && !monRect.locked ? 0.9 : (monRect.isSelected ? 0.8 : 0.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors { top: parent.top; right: parent.right; margins: Style.space(4) }
                  visible: !monRect.locked && monRect.height > Style.space(30) && monRect.width > Style.space(60)
                }

                Column {
                  anchors.centerIn: parent
                  spacing: 1

                  Text {
                    text: monRect.name
                    color: monRect.isSelected || (monRect.focused && !monRect.locked) ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.weight: Font.Bold
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: monRect.height > Style.space(34)
                  }

                  Text {
                    text: Math.round(monRect.lw * monRect.scaleFactor) + "x"
                      + Math.round(monRect.lh * monRect.scaleFactor) + " · "
                      + monRect.refreshRate + "Hz · " + monRect.scaleFactor + "x"
                    color: root.dimmed
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: monRect.height > Style.space(52)
                  }

                  Text {
                    text: monRect.posX + "x" + monRect.posY
                    color: monRect.moved ? Color.accent : root.dimmed
                    opacity: monRect.moved ? 1 : 0.75
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: monRect.height > Style.space(70)
                  }
                }
              }
            }
          }

          // ---------- Display settings section ----------
          PanelSeparator {
            id: propsSep
            anchors {
              bottom: propsSection.top
              left: parent.left
              right: parent.right
              bottomMargin: Style.space(8)
            }
            foreground: root.foreground
          }

          Item {
            id: propsSection
            anchors {
              bottom: footerSep.top
              left: parent.left
              right: parent.right
              bottomMargin: Style.space(8)
            }
            height: propsCol.implicitHeight

            Column {
              id: propsCol
              anchors { left: parent.left; right: parent.right; top: parent.top }
              spacing: Style.space(6)

              Row {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  text: root.selectedMonitor
                    ? "SETTINGS · " + root.selectedMonitor.name
                    : "SETTINGS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.selectedMonitor ? root.selectedMonitor.desc : ""
                  color: root.dimmed
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - Style.space(160))
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Row {
                spacing: Style.space(12)
                anchors.left: parent.left
                anchors.right: parent.right

                // Resolution Width x Height
                Row {
                  spacing: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: "Resolution"
                    color: root.dimmed
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  TextField {
                    id: resWField
                    width: Style.space(64)
                    verticalPadding: Style.space(2)
                    horizontalPadding: Style.space(6)
                    font.pixelSize: Style.font.caption
                    font.family: root.fontFamily
                    text: root.selectedMonitor ? String(root.selectedMonitor.width) : "1920"
                    validator: IntValidator { bottom: 320; top: 7680 }
                    onTextEdited: {
                      var val = parseInt(text)
                      if (!isNaN(val) && val >= 320 && root.selectedMonitor) {
                        root.setMonitorResolution(root.selectedIndex, val, root.selectedMonitor.height)
                      }
                    }
                    onEditingFinished: {
                      if (root.selectedMonitor)
                        root.setMonitorResolution(root.selectedIndex, parseInt(text), root.selectedMonitor.height)
                    }
                  }

                  Text {
                    text: "×"
                    color: root.dimmed
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  TextField {
                    id: resHField
                    width: Style.space(64)
                    verticalPadding: Style.space(2)
                    horizontalPadding: Style.space(6)
                    font.pixelSize: Style.font.caption
                    font.family: root.fontFamily
                    text: root.selectedMonitor ? String(root.selectedMonitor.height) : "1080"
                    validator: IntValidator { bottom: 240; top: 4320 }
                    onTextEdited: {
                      var val = parseInt(text)
                      if (!isNaN(val) && val >= 240 && root.selectedMonitor) {
                        root.setMonitorResolution(root.selectedIndex, root.selectedMonitor.width, val)
                      }
                    }
                    onEditingFinished: {
                      if (root.selectedMonitor)
                        root.setMonitorResolution(root.selectedIndex, root.selectedMonitor.width, parseInt(text))
                    }
                  }
                }

                // Refresh Rate
                Row {
                  spacing: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: "Rate"
                    color: root.dimmed
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  TextField {
                    id: rrField
                    width: Style.space(56)
                    verticalPadding: Style.space(2)
                    horizontalPadding: Style.space(6)
                    font.pixelSize: Style.font.caption
                    font.family: root.fontFamily
                    text: root.selectedMonitor ? String(root.selectedMonitor.refreshRate) : "60"
                    validator: DoubleValidator { bottom: 1; top: 500; decimals: 2 }
                    onTextEdited: {
                      var val = parseFloat(text)
                      if (!isNaN(val) && val >= 1 && root.selectedMonitor) {
                        root.setMonitorRefreshRate(root.selectedIndex, val)
                      }
                    }
                    onEditingFinished: {
                      if (root.selectedMonitor)
                        root.setMonitorRefreshRate(root.selectedIndex, parseFloat(text))
                    }
                  }

                  Text {
                    text: "Hz"
                    color: root.dimmed
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Mode Preset Dropdown
                Row {
                  spacing: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.selectedMonitor && root.selectedMonitor.availableModes && root.selectedMonitor.availableModes.length > 0

                  Text {
                    text: "Preset"
                    color: root.dimmed
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Dropdown {
                    id: modeDropdown
                    width: Style.space(160)
                    rowHeight: Style.space(24)
                    options: root.selectedMonitor ? root.selectedMonitor.availableModes : []
                    value: root.selectedMonitor ? (root.selectedMonitor.width + "x" + root.selectedMonitor.height + "@" + Number(root.selectedMonitor.refreshRate).toFixed(2) + "Hz") : ""
                    onChanged: function(val) {
                      if (root.selectedMonitor) {
                        root.setMonitorMode(root.selectedIndex, val)
                        resWField.text = String(root.selectedMonitor.width)
                        resHField.text = String(root.selectedMonitor.height)
                        rrField.text = String(root.selectedMonitor.refreshRate)
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------- Footer ----------
          PanelSeparator {
            id: footerSep
            anchors {
              bottom: footer.top
              left: parent.left
              right: parent.right
              bottomMargin: Style.space(8)
            }
            foreground: root.foreground
          }

          Item {
            id: footer
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: buttonsRow.implicitHeight

            Text {
              text: root.statusText !== ""
                ? root.statusText
                : "Esc · close"
              color: root.statusText.indexOf("Failed") === 0 ? Color.urgent
                : root.statusText !== "" ? Color.accent : root.dimmed
              opacity: root.statusText !== "" ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: Math.min(implicitWidth, parent.width - buttonsRow.implicitWidth - Style.space(12))
              anchors {
                left: parent.left
                verticalCenter: buttonsRow.verticalCenter
              }
            }

            Row {
              id: buttonsRow
              anchors { right: parent.right; bottom: parent.bottom }
              spacing: Style.spacing.md

              Button {
                text: "Reset"
                iconText: "󰑐"
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.body
                bordered: true
                enabled: root.movedCount > 0 && !root.applying
                opacity: enabled ? 1 : 0.5
                onClicked: root.resetLayout()
              }

              Button {
                text: root.applying ? "Applying…" : "Apply"
                iconText: "󰄬"
                iconSpinning: root.applying
                fontFamily: root.fontFamily
                foreground: root.background
                background: Color.accent
                fontSize: Style.font.body
                enabled: root.movedCount > 0 && !root.applying
                opacity: enabled ? 1 : 0.5
                onClicked: root.applyLayout()
              }

              Button {
                text: "Close"
                iconText: "󰅖"
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.body
                onClicked: root.dismiss()
              }
            }
          }
        }
      }
    }
  }
}
