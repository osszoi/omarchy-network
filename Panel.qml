pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Logic.js" as Logic

Panel {
  id: root
  moduleName: "eduardo.network"
  ipcTarget: "eduardo.network"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool ready: !!svc && svc.ready === true
  readonly property bool reachable: ready && svc.reachable === true
  readonly property var lanes: ready && svc.lanes ? svc.lanes : []
  readonly property var devices: ready ? svc.devices : []
  readonly property int unsorted: ready ? svc.unsortedCount : 0
  readonly property var health: ready ? svc.health : ({})
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: "󰌗"
  readonly property string shieldGlyph: "󰒘"
  readonly property string healthGlyph: "󰋚"
  readonly property int laneWidth: Style.space(232)
  readonly property int laneGap: Style.space(10)

  property var editing: null
  property string editError: ""
  property string toast: ""
  property bool toastBad: false
  property bool infoOpen: false
  property var lookups: []
  property string lookupsState: ""
  property var outages: []
  property string confirmUrl: ""

  // the sheet follows the live device, not the snapshot taken when it opened
  readonly property var dev: {
    if (!editing) return null
    for (var i = 0; i < devices.length; i++) if (devices[i].mac === editing.mac) return devices[i]
    return editing.device
  }
  readonly property bool devBusy: !!dev && ready && !!svc.busy[dev.mac]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (svc) svc.watching = opened
    if (opened && svc) svc.refresh()
    if (!opened) { cancelEdit(); infoOpen = false }
  }

  Connections {
    target: root.svc
    function onOpenRequested() { root.open() }
    function onActionFinished(mac, ok, message) { root.showToast(message, !ok) }
  }

  function devicesIn(laneId) {
    return devices.filter(function(d) { return d.lane === laneId })
  }

  function outsideLanes() {
    return devices.filter(function(d) { return d.lane === "" })
  }

  function showToast(message, bad) {
    toast = message
    toastBad = bad
    toastTimer.restart()
  }

  function poolText() {
    for (var i = 0; i < lanes.length; i++) if (lanes[i].pool) return lanes[i].name + " (." + lanes[i].fromIp.split(".")[3] + "–." + lanes[i].toIp.split(".")[3] + ")"
    return "the new-device range"
  }

  function laneName(id) {
    for (var i = 0; i < lanes.length; i++) if (lanes[i].id === id) return lanes[i].name
    return id
  }

  function beginEdit(device, laneId, moving) {
    if (!svc || !device) return
    infoOpen = false
    var target = laneId || device.lane || (lanes.length ? lanes[0].id : "")
    editing = { mac: device.mac, device: device, laneId: target, moving: moving === true }
    editError = ""
    nameField.text = device.named ? device.name : (device.hostName || "")
    ipField.text = svc.suggestIp(device.mac, target)
    fromField.text = device.bedtime ? device.bedtime.from : "23:00"
    toField.text = device.bedtime ? device.bedtime.to : "07:00"
    sheetFlick.contentY = 0
    loadLookups()
    nameField.forceActiveFocus()
    nameField.selectAll()
  }

  function loadLookups() {
    if (!editing || !svc) return
    lookups = []
    lookupsState = "loading"
    var mac = editing.mac
    svc.loadLookups(mac, function(list, err) {
      if (!root.editing || root.editing.mac !== mac) return
      root.lookups = list
      root.lookupsState = err ? err : (list.length ? "" : "none")
    })
  }

  function pickLane(laneId) {
    if (!editing || !svc) return
    editing = Object.assign({}, editing, { laneId: laneId })
    ipField.text = svc.suggestIp(editing.mac, laneId)
    editError = ""
  }

  function cancelEdit() {
    editing = null
    editError = ""
    lookups = []
    keyCatcher.forceActiveFocus()
  }

  function save() {
    if (!editing || !svc || !dev) return
    var name = nameField.text
    var ip = ipField.text.trim()
    var err = ""
    if (!dev.isStatic || ip !== dev.ip || editing.laneId !== dev.lane) err = svc.assign(dev.mac, editing.laneId, ip, name)
    else if (name.trim() !== dev.name) err = svc.rename(dev.mac, name)
    if (err) { editError = err; return }
    cancelEdit()
  }

  function act(err) {
    if (err) editError = err === "busy" ? "Wait for the last change to finish" : err
    else editError = ""
  }

  function openInfo() {
    cancelEdit()
    infoOpen = true
    confirmUrl = ""
    if (!svc) return
    svc.refreshHealth()
    svc.loadOutages(function(lines) { root.outages = lines })
  }

  Timer {
    id: toastTimer
    interval: 5000
    onTriggered: root.toast = ""
  }

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Body: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    labelText: root.unsorted > 0 ? String(root.unsorted) : ""
    active: root.unsorted > 0
    dimmed: root.ready && !root.reachable
    tooltipText: !root.ready ? "Home network"
      : !root.reachable ? "Home network · " + (root.svc.lastError || root.svc.configError || "router unreachable")
      : "Home network · " + root.svc.onlineCount + " online" + (root.unsorted > 0 ? " · " + root.unsorted + " new" : "") + (root.svc.quarantine ? " · quarantine on" : "")
    onPressed: function(b) {
      if (b === Qt.RightButton && root.svc) root.svc.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(460), root.lanes.length * root.laneWidth + Math.max(0, root.lanes.length - 1) * root.laneGap))
    contentHeight: panel.fittedContentHeight(Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing !== null
      onCloseRequested: {
        if (root.infoOpen) root.infoOpen = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if ((t === "r" || t === "R") && root.svc) root.svc.refresh()
        else if (t === "h" || t === "H") root.infoOpen ? root.infoOpen = false : root.openInfo()
      }

      Item {
        id: body
        anchors.fill: parent

        Row {
          id: head
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(10)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.glyph
            color: root.reachable ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(40) - healthButton.width - refreshButton.width - parent.spacing * 3
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Home network"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: !root.ready ? "Loading…"
                : root.svc.configError !== "" ? root.svc.configError
                : !root.reachable ? (root.svc.lastError || "Router unreachable")
                : root.svc.identity + "  ·  " + root.devices.length + " devices  ·  " + root.svc.onlineCount + " online" + (root.unsorted > 0 ? "  ·  " + root.unsorted + " to sort" : "")
              color: root.ready && (root.svc.configError !== "" || !root.reachable) ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              visible: root.reachable && root.health.version !== undefined
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: (root.health.internetUp === false ? "internet DOWN" : "internet up") + (root.health.latency ? " " + root.health.latency : "")
                + (root.health.publicIp ? "  ·  " + root.health.publicIp : "")
                + (root.health.wanSince ? "  ·  WAN since " + root.health.wanSince.split(" ").pop() : "")
                + "  ·  CPU " + (root.health.cpu || 0) + "%" + (root.health.temp !== null && root.health.temp !== undefined ? " " + root.health.temp + "°C" : "")
                + (root.svc && root.svc.quarantine ? "  ·  quarantine on" : "")
              color: root.health.internetUp === false ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            id: healthButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.healthGlyph
            tooltipText: "Health, quarantine, updates (h)"
            selected: root.infoOpen
            foreground: root.foreground
            onClicked: root.infoOpen ? root.infoOpen = false : root.openInfo()
          }

          Button {
            id: refreshButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh (r)"
            iconSpinning: root.ready && root.svc.refreshing
            foreground: root.foreground
            onClicked: if (root.svc) root.svc.refresh()
          }
        }

        Row {
          id: laneRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: head.bottom
          anchors.bottom: footer.top
          anchors.topMargin: Style.space(14)
          anchors.bottomMargin: Style.space(8)
          spacing: root.laneGap

          Repeater {
            model: root.lanes
            Lane {
              required property var modelData
              lane: modelData
              width: (laneRow.width - root.laneGap * Math.max(0, root.lanes.length - 1)) / Math.max(1, root.lanes.length)
              height: laneRow.height
              devices: root.devicesIn(modelData.id)
              busy: root.ready ? root.svc.busy : ({})
              history: root.ready ? root.svc.history : ({})
              dragLayer: dragLayer
              fontFamily: root.fontFamily
              foreground: root.foreground
              accent: root.accent
              onDeviceDropped: function(device, laneId) { root.beginEdit(device, laneId, true) }
              onDeviceClicked: function(device) { root.beginEdit(device, "", false) }
            }
          }
        }

        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(16)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.toast !== "" ? root.toast
            : root.outsideLanes().length > 0 ? root.outsideLanes().length + " device(s) outside every lane"
            : "Drag a device to another lane to give it a fixed address · click it for controls"
          color: root.toast !== "" ? (root.toastBad ? root.urgent : root.accent) : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Behavior on color { ColorAnimation { duration: Style.duration(160) } }
        }

        Item {
          id: dragLayer
          anchors.fill: parent
          z: 50
        }

        // device sheet
        Item {
          id: sheet
          anchors.fill: parent
          z: 100
          visible: opacity > 0
          opacity: root.editing !== null ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(root.editing !== null ? 180 : 120); easing.type: Easing.OutCubic } }

          Rectangle {
            anchors.fill: parent
            color: Util.alpha(Commons.Color.popups.background, 0.82)
            MouseArea { anchors.fill: parent; onClicked: root.cancelEdit() }
          }

          Rectangle {
            id: card
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(40), Style.space(440))
            height: Math.min(parent.height - Style.space(24), form.implicitHeight + Style.space(32))
            radius: Style.cornerRadius
            color: Commons.Color.popups.background
            border.width: Math.max(1, Style.space(1))
            border.color: root.accent
            scale: root.editing !== null ? 1 : 0.97
            Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

            MouseArea { anchors.fill: parent }

            Flickable {
              id: sheetFlick
              anchors.fill: parent
              anchors.margins: Style.space(16)
              contentHeight: form.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: form
                width: sheetFlick.width
                spacing: Style.space(10)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: !root.dev ? "" : root.editing.moving ? "Move to " + root.laneName(root.editing.laneId) : root.dev.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Caption {
                  width: parent.width
                  wrapMode: Text.WrapAnywhere
                  text: !root.dev ? "" : root.dev.mac + (root.dev.hostName ? "  ·  " + root.dev.hostName : "") + "  ·  now " + (root.dev.activeIp || root.dev.ip) + (root.dev.wifi ? "  ·  " + root.dev.wifi.ap + " " + root.dev.wifi.band + " " + root.dev.wifi.signal + " dBm" : "")
                }

                Caption {
                  visible: !!root.dev && !!root.dev.guess && root.dev.guess.label !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  color: root.accent
                  text: root.dev && root.dev.guess ? "Looks like: " + root.dev.guess.label + "  (" + root.dev.guess.why + ")" : ""
                }

                Caption {
                  readonly property string hint: Logic.guessFromLookups(root.lookups)
                  visible: hint !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  color: root.accent
                  text: "Talks mostly to: " + hint
                }

                Row {
                  width: parent.width
                  spacing: Style.space(4)
                  Repeater {
                    model: root.lanes
                    Button {
                      required property var modelData
                      text: modelData.name
                      selected: !!root.editing && root.editing.laneId === modelData.id
                      bordered: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(6)
                      onClicked: root.pickLane(modelData.id)
                    }
                  }
                }

                Caption { text: "Name" }

                TextField {
                  id: nameField
                  width: parent.width
                  maximumLength: 48
                  placeholderText: "Living room TV"
                  font.family: root.fontFamily
                  Keys.onReturnPressed: root.save()
                  Keys.onEnterPressed: root.save()
                  Keys.onEscapePressed: root.cancelEdit()
                  Keys.onTabPressed: ipField.forceActiveFocus()
                }

                Caption { text: "Fixed address" }

                TextField {
                  id: ipField
                  width: parent.width
                  maximumLength: 15
                  font.family: root.fontFamily
                  validator: RegularExpressionValidator { regularExpression: /[0-9.]{0,15}/ }
                  Keys.onReturnPressed: root.save()
                  Keys.onEnterPressed: root.save()
                  Keys.onEscapePressed: root.cancelEdit()
                  Keys.onTabPressed: nameField.forceActiveFocus()
                }

                Caption {
                  visible: !!root.dev && root.dev.note !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.dev && root.dev.note ? "Reached by IP: " + root.dev.note + ". Update it after moving." : ""
                  color: root.urgent
                }

                Caption {
                  visible: !!root.dev && !!root.dev.wifi && (!root.dev.isStatic || ipField.text !== root.dev.ip)
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "It gets disconnected from WiFi for a moment to pick up the new address."
                }

                Text {
                  visible: root.editError !== ""
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: root.editError
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  anchors.right: parent.right
                  spacing: Style.space(6)

                  Button {
                    visible: !!root.dev && root.dev.isStatic
                    text: "Forget"
                    bordered: true
                    foreground: root.urgent
                    onClicked: { root.act(root.svc.forget(root.dev.mac)); if (root.editError === "") root.cancelEdit() }
                  }
                  Button {
                    text: "Close"
                    bordered: true
                    foreground: root.foreground
                    onClicked: root.cancelEdit()
                  }
                  Button {
                    text: root.editing && root.editing.moving ? "Move" : "Save"
                    bordered: true
                    selected: true
                    foreground: root.foreground
                    onClicked: root.save()
                  }
                }

                PanelSeparator { width: parent.width }

                Toggle {
                  width: parent.width
                  label: "Pause internet"
                  description: root.dev && root.dev.paused ? "Blocked right now" : "Cuts it off the internet until you turn this off"
                  checked: !!root.dev && root.dev.paused === true
                  enabled: !root.devBusy
                  fontFamily: root.fontFamily
                  onClicked: root.act(root.svc.setPaused(root.dev.mac, !root.dev.paused))
                }

                Toggle {
                  width: parent.width
                  label: "Bedtime"
                  description: root.dev && root.dev.bedtime ? "No internet " + root.dev.bedtime.from + " → " + root.dev.bedtime.to + " every day" : "No internet every night between the two times below"
                  checked: !!root.dev && !!root.dev.bedtime
                  enabled: !root.devBusy
                  fontFamily: root.fontFamily
                  onClicked: root.act(root.svc.setBedtime(root.dev.mac, !root.dev.bedtime, fromField.text.trim(), toField.text.trim()))
                }

                Row {
                  spacing: Style.space(8)
                  TextField {
                    id: fromField
                    width: Style.space(80)
                    maximumLength: 5
                    font.family: root.fontFamily
                    validator: RegularExpressionValidator { regularExpression: /[0-9:]{0,5}/ }
                    Keys.onEscapePressed: root.cancelEdit()
                  }
                  Caption { anchors.verticalCenter: parent.verticalCenter; text: "→" }
                  TextField {
                    id: toField
                    width: Style.space(80)
                    maximumLength: 5
                    font.family: root.fontFamily
                    validator: RegularExpressionValidator { regularExpression: /[0-9:]{0,5}/ }
                    Keys.onEscapePressed: root.cancelEdit()
                  }
                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!root.dev && !!root.dev.bedtime && (fromField.text !== root.dev.bedtime.from || toField.text !== root.dev.bedtime.to)
                    text: "Update"
                    bordered: true
                    foreground: root.foreground
                    onClicked: root.act(root.svc.setBedtime(root.dev.mac, true, fromField.text.trim(), toField.text.trim()))
                  }
                }

                Toggle {
                  width: parent.width
                  label: "Through " + (root.ready ? root.svc.vpnLabel : "the VPN")
                  description: "Its traffic leaves through the VPN tunnel instead of home. Tunnel down = no internet for it."
                  checked: !!root.dev && root.dev.vpn === true
                  enabled: !root.devBusy
                  fontFamily: root.fontFamily
                  onClicked: root.act(root.svc.setVpn(root.dev.mac, !root.dev.vpn))
                }

                Toggle {
                  width: parent.width
                  label: "Notify when it comes and goes"
                  description: "For someone's phone: a notification when they get home or leave (after " + (root.ready && root.svc.cfg ? root.svc.cfg.awayMinutes : 10) + " min off the WiFi)"
                  checked: !!root.dev && root.dev.person === true
                  fontFamily: root.fontFamily
                  onClicked: root.svc.setPerson(root.dev.mac, !root.dev.person)
                }

                PanelSeparator { width: parent.width }

                Body {
                  width: parent.width
                  text: !root.dev ? "" : "Traffic  ↓ " + Logic.formatRate(root.dev.rateDown) + "   ↑ " + Logic.formatRate(root.dev.rateUp)
                }

                Canvas {
                  id: bigSpark
                  width: parent.width
                  height: Style.space(40)
                  property var points: root.dev && root.ready ? (root.svc.history[root.dev.mac] || []) : []
                  onPointsChanged: requestPaint()
                  onWidthChanged: requestPaint()
                  onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var p = points || []
                    ctx.fillStyle = Util.alpha(root.foreground, 0.04)
                    ctx.fillRect(0, 0, width, height)
                    if (p.length < 2) return
                    var max = 1
                    for (var i = 0; i < p.length; i++) max = Math.max(max, p[i])
                    ctx.strokeStyle = root.accent
                    ctx.lineWidth = Math.max(1, Style.space(1.5))
                    ctx.beginPath()
                    for (var j = 0; j < p.length; j++) {
                      var x = width * j / (p.length - 1)
                      var y = height - 2 - (height - 4) * p[j] / max
                      if (j === 0) ctx.moveTo(x, y)
                      else ctx.lineTo(x, y)
                    }
                    ctx.stroke()
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Body {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - lookupsButton.width - parent.spacing
                    text: "Recent lookups"
                    font.bold: true
                  }
                  Button {
                    id: lookupsButton
                    text: "Reload"
                    bordered: true
                    fontSize: Style.font.caption
                    foreground: root.foreground
                    onClicked: root.loadLookups()
                  }
                }

                Caption {
                  visible: root.lookupsState !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.lookupsState === "loading" ? "Loading…"
                    : root.lookupsState === "none" ? "Nothing in the last stretch of the router's DNS log. Devices using their own encrypted DNS never show up here."
                    : root.lookupsState
                }

                Repeater {
                  model: root.lookups
                  Row {
                    required property var modelData
                    width: form.width
                    spacing: Style.space(8)
                    Caption { text: modelData.time }
                    Body {
                      width: parent.width - Style.space(60)
                      text: modelData.name
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }
        }

        // health sheet
        Item {
          id: infoSheet
          anchors.fill: parent
          z: 90
          visible: opacity > 0
          opacity: root.infoOpen ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(root.infoOpen ? 180 : 120); easing.type: Easing.OutCubic } }

          Rectangle {
            anchors.fill: parent
            color: Util.alpha(Commons.Color.popups.background, 0.82)
            MouseArea { anchors.fill: parent; onClicked: root.infoOpen = false }
          }

          Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(40), Style.space(520))
            height: Math.min(parent.height - Style.space(24), info.implicitHeight + Style.space(32))
            radius: Style.cornerRadius
            color: Commons.Color.popups.background
            border.width: Math.max(1, Style.space(1))
            border.color: root.accent
            scale: root.infoOpen ? 1 : 0.97
            Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

            MouseArea { anchors.fill: parent }

            Flickable {
              anchors.fill: parent
              anchors.margins: Style.space(16)
              contentHeight: info.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: info
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "Network health"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Repeater {
                  model: [
                    ["Internet", root.health.internetUp === false ? "DOWN" : "up" + (root.health.internetSince ? " since " + root.health.internetSince : "")],
                    ["Latency", root.health.latency || "—"],
                    ["Public IP", root.health.publicIp || "—"],
                    ["Movistar link", root.health.wanUp === false ? "DOWN" : (root.health.wanName || "WAN") + " up since " + (root.health.wanSince || "?")],
                    ["Router", (root.ready ? root.svc.identity : "") + "  ·  RouterOS " + (root.health.version || "?") + "  ·  up " + (root.health.uptime || "?")],
                    ["Load", "CPU " + (root.health.cpu || 0) + "%" + (root.health.temp !== null && root.health.temp !== undefined ? "  ·  " + root.health.temp + "°C" : "")]
                  ]
                  Row {
                    required property var modelData
                    width: info.width
                    Caption { width: Style.space(110); text: modelData[0] }
                    Body { width: info.width - Style.space(110); text: modelData[1] }
                  }
                }

                PanelSeparator { width: parent.width }

                Toggle {
                  width: parent.width
                  label: "Quarantine new devices"
                  description: "Devices in " + root.poolText() + " get internet only: they can't reach anything at home and nothing at home can reach them. Works for traffic through the routers (WiFi); devices on the same plain switch still see each other."
                  checked: root.ready && root.svc.quarantine === true
                  fontFamily: root.fontFamily
                  onClicked: root.svc.setQuarantine(!root.svc.quarantine)
                }

                PanelSeparator { width: parent.width }

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Body {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - checkButton.width - parent.spacing
                    text: "RouterOS updates"
                    font.bold: true
                  }
                  Button {
                    id: checkButton
                    text: "Check"
                    bordered: true
                    fontSize: Style.font.caption
                    foreground: root.foreground
                    onClicked: root.svc.checkUpdates()
                  }
                }

                Repeater {
                  model: root.ready ? Object.keys(root.svc.updates) : []
                  Row {
                    required property var modelData
                    readonly property var u: root.svc.updates[modelData]
                    readonly property bool newer: u.latest !== "" && u.installed !== "" && u.latest !== u.installed
                    width: info.width
                    spacing: Style.space(8)
                    Body {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - installButton.width - parent.spacing
                      text: parent.u.name + "  ·  " + (parent.u.installed || "?") + (parent.newer ? "  →  " + parent.u.latest : "  ·  " + (parent.u.status || "up to date"))
                    }
                    Button {
                      id: installButton
                      visible: parent.newer
                      text: root.confirmUrl === parent.modelData ? "Reboots it, sure?" : "Install"
                      bordered: true
                      fontSize: Style.font.caption
                      foreground: root.confirmUrl === parent.modelData ? root.urgent : root.foreground
                      onClicked: {
                        if (root.confirmUrl === parent.modelData) { root.svc.installUpdate(parent.modelData); root.confirmUrl = "" }
                        else root.confirmUrl = parent.modelData
                      }
                    }
                  }
                }

                PanelSeparator { width: parent.width }

                Body { text: "Outage log"; font.bold: true }

                Caption {
                  visible: root.outages.length === 0
                  text: "No outages logged"
                }

                Repeater {
                  model: root.outages
                  Caption {
                    required property string modelData
                    width: info.width
                    elide: Text.ElideRight
                    text: modelData
                    color: modelData.indexOf("DOWN") !== -1 || modelData.indexOf("unreachable") !== -1 ? root.urgent : root.dim
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
