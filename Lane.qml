import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

Rectangle {
  id: root

  required property var lane
  property var devices: []
  property var busy: ({})
  property var history: ({})
  property Item dragLayer: null
  property string fontFamily: Style.font.family
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property bool hot: drop.containsDrag && drop.acceptsCurrent

  signal deviceDropped(var device, string laneId)
  signal deviceClicked(var device)

  radius: Style.cornerRadius
  color: Util.alpha(hot ? accent : foreground, hot ? 0.12 : 0.025)
  border.width: Math.max(1, Style.space(1))
  border.color: hot ? accent : Util.alpha(foreground, 0.1)
  Behavior on color { ColorAnimation { duration: Style.duration(140) } }
  Behavior on border.color { ColorAnimation { duration: Style.duration(140) } }

  Column {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(10)
    spacing: Style.space(2)

    Row {
      width: parent.width
      spacing: Style.space(6)

      Text {
        width: parent.width - count.width - parent.spacing
        textFormat: Text.PlainText
        text: root.lane.name
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        id: count
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: String(root.devices.length)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "." + root.lane.fromIp.split(".")[3] + " – ." + root.lane.toIp.split(".")[3] + (root.lane.pool ? "  ·  new devices land here" : "")
      elide: Text.ElideRight
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  ListView {
    id: list
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(8)
    anchors.topMargin: Style.space(10)
    spacing: Style.space(6)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: ScriptModel {
      objectProp: "key"
      values: root.devices
    }

    // variable-height delegates can leave the view a few px under the top after a refresh
    onContentHeightChanged: if (!moving && !dragging && contentY < originY + Style.space(40)) contentY = originY

    displaced: Transition {
      NumberAnimation { properties: "y"; duration: Style.duration(200); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    delegate: DeviceCard {
      width: list.width
      dragLayer: root.dragLayer
      fontFamily: root.fontFamily
      foreground: root.foreground
      accent: root.accent
      busyText: root.busy[modelData.mac] || ""
      hist: root.history[modelData.mac] || []
      onClicked: root.deviceClicked(modelData)
    }
  }

  Text {
    anchors.centerIn: list
    visible: root.devices.length === 0
    textFormat: Text.PlainText
    text: root.hot ? "Drop here" : "Nothing here yet"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  DropArea {
    id: drop
    anchors.fill: parent
    keys: ["eduardo.network.device"]
    readonly property bool acceptsCurrent: !!drag.source && !!drag.source.device && drag.source.device.lane !== root.lane.id
    onDropped: function(ev) {
      var d = ev.source ? ev.source.device : null
      if (!d || d.lane === root.lane.id) return
      ev.accept()
      root.deviceDropped(d, root.lane.id)
    }
  }
}
