import QtQuick
import qs.Core

// Small text button. Destructive ones arm on first click and act on the
// second, the same two-step a note's delete control uses.
Rectangle {
  id: button

  property string text: ""
  property bool danger: false
  property bool confirm: false
  property bool armed: false

  signal activated()

  implicitWidth: label.width + 22
  implicitHeight: 26
  radius: 6
  color: Theme.withAlpha(button.armed ? Theme.urgent : Theme.foreground,
                         hit.containsMouse ? (button.armed ? 0.3 : 0.12) : 0.06)
  border.width: 1
  border.color: Theme.withAlpha(button.armed ? Theme.urgent : Theme.foreground, 0.2)

  Text {
    id: label
    anchors.centerIn: parent
    text: button.armed ? "Click again" : button.text
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontBase - 1
    color: button.armed ? Theme.urgent
           : (button.danger ? Theme.withAlpha(Theme.urgent, 0.85) : Theme.foreground)
  }

  Timer {
    id: disarm
    interval: 2600
    onTriggered: button.armed = false
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    onClicked: {
      if (button.confirm && !button.armed) {
        button.armed = true
        disarm.restart()
        return
      }
      disarm.stop()
      button.armed = false
      button.activated()
    }
  }
}
