import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Logic.js" as Logic

Item {
  id: root

  required property var modelData
  readonly property var device: modelData
  property Item dragLayer: null
  property string fontFamily: Style.font.family
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string busyText: ""
  property var hist: []
  readonly property bool active: (hist || []).some(function(v) { return v >= 2000 })
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property bool dragging: mouse.drag.active

  readonly property string wifiGlyph: "󰖩"
  readonly property string wiredGlyph: "󰈀"
  readonly property string noteGlyphChar: "\uDB80\uDF37"

  signal clicked()

  implicitHeight: tile.height
  height: tile.height

  property bool shown: false
  opacity: shown ? 1 : 0
  scale: shown ? 1 : 0.97
  Component.onCompleted: shown = true
  Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
  Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

  function lineThree() {
    var d = root.device
    if (d.wifi) return d.wifi.ap + (d.wifi.band ? " · " + d.wifi.band : "")
    if (d.online) return "wired"
    if (d.bound) return "connected"
    if (!d.lastSeen || d.lastSeen === "never") return "offline · never seen"
    return "offline · seen " + d.lastSeen + " ago"
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.busyText === ""
    drag.target: tile
    drag.threshold: Style.space(6)
    cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    onReleased: {
      if (tile.Drag.active) tile.Drag.drop()
      tile.x = 0
      tile.y = 0
    }
    onClicked: root.clicked()
  }

  Rectangle {
    id: tile
    width: root.width
    height: content.implicitHeight + Style.space(18)
    radius: Style.cornerRadius
    color: root.dragging ? Commons.Color.popups.background : Util.alpha(root.foreground, mouse.containsMouse ? 0.09 : 0.045)
    border.width: Math.max(1, Style.space(1))
    border.color: root.dragging ? root.accent : Util.alpha(root.foreground, mouse.containsMouse ? 0.28 : 0.12)
    scale: root.dragging ? 1.04 : 1

    Drag.active: root.dragging
    Drag.keys: ["eduardo.network.device"]
    Drag.source: root
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

    states: State {
      when: root.dragging && root.dragLayer !== null
      ParentChange { target: tile; parent: root.dragLayer }
    }

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(3)

      Row {
        width: parent.width
        spacing: Style.space(7)

        Rectangle {
          id: dot
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.device.online ? root.accent : "transparent"
          border.width: Math.max(1, Style.space(1))
          border.color: root.device.online ? root.accent : Util.alpha(root.foreground, root.device.bound ? 0.6 : 0.3)
          Behavior on color { ColorAnimation { duration: Style.duration(200) } }
        }

        Text {
          width: parent.width - dot.width - parent.spacing - (badges.width > 0 ? badges.width + parent.spacing : 0)
          textFormat: Text.PlainText
          text: root.device.name
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Row {
          id: badges
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          Repeater {
            model: [
              { on: root.device.paused === true, glyph: "\uDB80\uDFE4", tint: root.urgent },
              { on: !!root.device.bedtime, glyph: "\uDB81\uDD94", tint: root.dim },
              { on: root.device.vpn === true, glyph: "\uDB80\uDDE7", tint: root.accent },
              { on: root.device.person === true, glyph: "\uDB80\uDC04", tint: root.dim },
              { on: root.device.note !== "", glyph: root.noteGlyphChar, tint: root.dim }
            ]
            Text {
              required property var modelData
              visible: modelData.on
              textFormat: Text.PlainText
              text: modelData.glyph
              color: modelData.tint
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.busyText !== "" ? root.device.ip + "  ·  " + root.busyText + "…"
          : root.device.pending ? root.device.activeIp + "  →  " + root.device.ip + "  · on next renewal"
          : root.device.ip
        elide: Text.ElideRight
        color: root.device.pending || root.busyText !== "" ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        width: parent.width
        spacing: Style.space(5)

        Text {
          id: linkGlyph
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.device.wifi ? root.wifiGlyph : root.wiredGlyph
          visible: root.device.online || root.device.bound
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - (linkGlyph.visible ? linkGlyph.width + parent.spacing : 0) - (bars.visible ? bars.width + parent.spacing : 0)
          textFormat: Text.PlainText
          text: root.lineThree()
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          id: bars
          anchors.verticalCenter: parent.verticalCenter
          visible: !!root.device.wifi
          spacing: Style.space(1)
          readonly property int level: root.device.wifi ? Logic.signalBars(root.device.wifi.signal) : 0
          Repeater {
            model: 4
            Rectangle {
              required property int index
              anchors.bottom: parent.bottom
              width: Style.space(2)
              height: Style.space(3 + index * 2)
              color: index < bars.level ? root.foreground : Util.alpha(root.foreground, 0.2)
            }
          }
        }
      }


      Text {
        visible: !root.device.named && !!root.device.guess && root.device.guess.label !== ""
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        text: root.device.guess ? "Probably " + root.device.guess.label : ""
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: parent.width
        height: Style.space(16)
        visible: root.device.rateDown + root.device.rateUp >= 2000 || root.active

        Text {
          id: rateText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "\u2193 " + Logic.formatRate(root.device.rateDown) + "   \u2191 " + Logic.formatRate(root.device.rateUp)
          color: root.device.rateDown + root.device.rateUp >= 2000 ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Canvas {
          id: spark
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - rateText.width - Style.space(8))
          height: parent.height
          property var points: root.hist
          onPointsChanged: requestPaint()
          onWidthChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var p = points || []
            if (p.length < 2 || width <= 0) return
            var max = 1
            for (var i = 0; i < p.length; i++) max = Math.max(max, p[i])
            ctx.strokeStyle = root.accent
            ctx.lineWidth = Math.max(1, Style.space(1.2))
            ctx.beginPath()
            for (var j = 0; j < p.length; j++) {
              var x = width * j / (p.length - 1)
              var y = height - 1 - (height - 2) * p[j] / max
              if (j === 0) ctx.moveTo(x, y)
              else ctx.lineTo(x, y)
            }
            ctx.stroke()
          }
        }
      }
    }
  }
}
