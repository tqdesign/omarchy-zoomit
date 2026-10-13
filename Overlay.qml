import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// ZoomIt for Omarchy: freeze the monitor under the pointer, then magnify it,
// draw and type on it, snip a region from it, or cover it with a break timer.
// bin/zoomit-capture takes the still and reports the pointer, since a layer
// surface can read neither. Annotations live in "scene" coordinates (the
// unzoomed screen) so they stay put while the view zooms and pans.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Tunables.
  readonly property real defaultZoom: 2
  readonly property real maxZoom: 32
  readonly property real zoomStep: 1.1
  readonly property int zoomAnimMs: 140
  readonly property real defaultPenWidth: 5
  readonly property real defaultFontSize: 36
  readonly property int defaultBreakMinutes: 10
  readonly property color breakBackground: "#ffffff"
  // ZoomIt puts the arrow head where the drag starts.
  readonly property bool arrowHeadAtStart: true
  readonly property var penColors: ({
    r: "#ff0000", g: "#00ff00", b: "#0000ff",
    o: "#ff8000", y: "#ffff00", p: "#ff00ff"
  })

  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "tqdesign.zoomit"
  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/zoomit"

  property bool opened: false
  property bool pending: false
  property var request: ({})
  // "zoom" | "draw" | "type" | "snip" | "break"
  property string mode: ""
  property var targetScreen: null
  property string shotFile: ""

  // Item already has a final z, so the animated value needs its own name.
  // zoom is the target, shown what is on screen while it animates.
  property real zoom: 1
  property real shown: zoom
  Behavior on shown {
    enabled: root.opened && panel.visible
    NumberAnimation { duration: root.zoomAnimMs; easing.type: Easing.OutCubic }
  }

  // Pointer in window coordinates, and the point the view is scaled about.
  // The anchor follows the pointer in zoom mode and freezes while drawing.
  property real mx: 0
  property real my: 0
  property real anchorX: 0
  property real anchorY: 0
  readonly property real tx: -anchorX * (shown - 1)
  readonly property real ty: -anchorY * (shown - 1)

  property string penKey: "r"
  property bool highlight: false
  property bool blurPen: false
  property real penWidth: defaultPenWidth
  property real fontSize: defaultFontSize
  readonly property color penColor: penColors[penKey] || penColors.r
  // "" | "white" | "black"
  property string board: ""

  // Committed annotations, mutated in place; itemCount and blurCount carry
  // the change to bindings.
  property var items: []
  property var redoStack: []
  property var current: null
  property int itemCount: 0
  property int blurCount: 0
  property bool tabHeld: false

  property bool snipSave: false
  property bool selecting: false
  property real selX1: 0
  property real selY1: 0
  property real selX2: 0
  property real selY2: 0

  property double breakEndMs: 0
  property int breakRemaining: 0

  onShownChanged: repaint()
  onTxChanged: repaint()
  onTyChanged: repaint()

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var want = String(payload.mode || "zoom")
    if (["zoom", "draw", "snip", "break"].indexOf(want) === -1) want = "zoom"

    if (root.pending) return
    if (root.opened) {
      root.retarget(want)
      return
    }

    payload.mode = want
    root.request = payload
    root.pending = true
    capProc.command = [root.pluginDir + "/bin/zoomit-capture"].concat(want === "break" ? ["--no-shot"] : [])
    capProc.running = true
  }

  // A hotkey pressed while the overlay is up: the mode's own key leaves, the
  // draw key steps from zoom into drawing, the zoom key zooms a plain drawing.
  function retarget(want) {
    if (want === "draw" && root.mode === "zoom") {
      root.mode = "draw"
    } else if (want === "zoom" && (root.mode === "draw" || root.mode === "type") && root.zoom <= 1) {
      root.commitText()
      root.anchorX = root.mx
      root.anchorY = root.my
      root.mode = "zoom"
      root.zoom = root.defaultZoom
    } else {
      root.dismiss()
    }
  }

  function close() {
    root.opened = false
    root.pending = false
    root.mode = ""
    root.current = null
    root.items = []
    root.redoStack = []
    root.itemCount = 0
    root.blurCount = 0
    root.tabHeld = false
    root.selecting = false
    root.zoom = 1
    root.shotFile = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function captured(text) {
    if (!root.pending) return
    var info = null
    try { info = JSON.parse(String(text || "").trim()) } catch (e) { info = null }
    if (!info || !info.screen) {
      root.dismiss()
      return
    }

    var screens = Quickshell.screens
    var target = null
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name === info.screen) target = screens[i]
    }
    if (!target) {
      root.dismiss()
      return
    }

    root.pending = false
    root.targetScreen = target
    root.mx = Number(info.x) || 0
    root.my = Number(info.y) || 0
    root.anchorX = root.mx
    root.anchorY = root.my
    root.zoom = 1
    root.board = ""
    root.blurPen = false
    root.mode = root.request.mode
    root.snipSave = root.request.save === true
    root.shotFile = String(info.file || "")

    if (root.mode === "break") {
      var minutes = Number(root.request.minutes) || root.defaultBreakMinutes
      root.breakEndMs = Date.now() + minutes * 60000
      root.tickBreak()
    }

    root.opened = true
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function tickBreak() {
    root.breakRemaining = Math.ceil((root.breakEndMs - Date.now()) / 1000)
  }

  function breakText() {
    var s = Math.abs(root.breakRemaining)
    var text = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
    // Past zero it counts how long the break has overrun.
    return root.breakRemaining < 0 ? "(" + text + ")" : text
  }

  function sceneX(x) { return (x - root.tx) / root.shown }
  function sceneY(y) { return (y - root.ty) / root.shown }

  function repaint() {
    if (!root.opened) return
    ink.requestPaint()
    live.requestPaint()
  }

  function setPen(key, asHighlighter) {
    root.penKey = key
    root.highlight = asHighlighter
    root.blurPen = false
  }

  function zoomBy(notches) {
    root.zoom = Math.max(1, Math.min(root.maxZoom, root.zoom * Math.pow(root.zoomStep, notches)))
  }

  function beginStroke(modifiers) {
    var ctrl = (modifiers & Qt.ControlModifier) !== 0
    var shift = (modifiers & Qt.ShiftModifier) !== 0
    var x = root.sceneX(root.mx)
    var y = root.sceneY(root.my)
    var shape = (ctrl && shift) ? "arrow" : ctrl ? "rect" : shift ? "line" : root.tabHeld ? "ellipse" : ""

    if (shape === "" && root.blurPen) {
      root.current = { t: "blur", pts: [x, y], width: Math.max(root.penWidth * 4, 24) / root.shown }
      root.blurCount += 1
      blurMask.requestPaint()
      return
    }

    var item = {
      t: shape || "pen",
      color: String(root.penColor),
      hl: root.highlight,
      width: (root.highlight ? Math.max(root.penWidth, 16) : root.penWidth) / root.shown
    }
    if (shape === "") item.pts = [x, y]
    else { item.x1 = x; item.y1 = y; item.x2 = x; item.y2 = y }
    root.current = item
    live.requestPaint()
  }

  function extendStroke() {
    var item = root.current
    if (!item || item.t === "text") return
    var x = root.sceneX(root.mx)
    var y = root.sceneY(root.my)
    if (item.pts) {
      item.pts.push(x, y)
    } else {
      item.x2 = x
      item.y2 = y
    }
    if (item.t === "blur") blurMask.requestPaint()
    else live.requestPaint()
  }

  function endStroke() {
    var item = root.current
    if (!item || item.t === "text") return
    root.current = null
    var empty = !item.pts && item.x1 === item.x2 && item.y1 === item.y2
    if (empty) {
      live.requestPaint()
      return
    }
    root.commit(item)
  }

  function commit(item) {
    root.items.push(item)
    root.redoStack = []
    root.itemCount = root.items.length
    // An in-progress blur stroke is already counted.
    if (item.t === "blur") blurMask.requestPaint()
    root.repaint()
  }

  function undo() {
    if (root.mode === "type") return
    var item = root.items.pop()
    if (!item) return
    root.redoStack.push(item)
    root.afterEdit(item, -1)
  }

  function redo() {
    if (root.mode === "type") return
    var item = root.redoStack.pop()
    if (!item) return
    root.items.push(item)
    root.afterEdit(item, 1)
  }

  function afterEdit(item, blurDelta) {
    root.itemCount = root.items.length
    if (item.t === "blur") {
      root.blurCount += blurDelta
      blurMask.requestPaint()
    }
    root.repaint()
  }

  function eraseAll() {
    root.current = null
    root.items = []
    root.redoStack = []
    root.itemCount = 0
    root.blurCount = 0
    blurMask.requestPaint()
    root.repaint()
  }

  function enterType(rightAligned) {
    if (root.mode !== "zoom" && root.mode !== "draw") return
    root.mode = "type"
    var size = root.fontSize / root.shown
    root.current = {
      t: "text", text: "", right: rightAligned,
      x: root.sceneX(root.mx), y: root.sceneY(root.my) - size / 2,
      size: size, color: String(root.penColor)
    }
    live.requestPaint()
  }

  function commitText() {
    var item = root.current
    if (!item || item.t !== "text") return
    root.current = null
    if (item.text.trim() !== "") root.commit(item)
    else live.requestPaint()
  }

  function setFontSize(size) {
    root.fontSize = Math.max(10, Math.min(300, size))
    if (root.current && root.current.t === "text") {
      root.current.size = root.fontSize / root.shown
      live.requestPaint()
    }
  }

  function exportView(action) {
    if (root.mode === "break" || root.mode === "snip") return
    viewport.grabToImage(function(result) {
      var file = root.runtimeDir + "/grab-" + Date.now() + ".png"
      if (result.saveToFile(file))
        Quickshell.execDetached([root.pluginDir + "/bin/zoomit-export", action, file])
    })
    flash.restart()
  }

  function finishSnip() {
    root.selecting = false
    var w = Math.abs(root.selX2 - root.selX1)
    var h = Math.abs(root.selY2 - root.selY1)
    if (w < 3 || h < 3) return
    // The still is in device pixels, the selection in logical ones.
    var s = shot.implicitWidth / viewport.width
    var geometry = Math.round(w * s) + "x" + Math.round(h * s)
      + "+" + Math.round(Math.min(root.selX1, root.selX2) * s)
      + "+" + Math.round(Math.min(root.selY1, root.selY2) * s)
    Quickshell.execDetached([root.pluginDir + "/bin/zoomit-export",
      root.snipSave ? "save" : "copy", root.shotFile, geometry])
    root.dismiss()
  }

  function keyPressed(event) {
    event.accepted = true
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    if (event.key === Qt.Key_Tab) {
      if (!event.isAutoRepeat) root.tabHeld = true
      return
    }

    if (root.mode === "type") {
      var item = root.current
      if (event.key === Qt.Key_Escape) {
        root.commitText()
        root.mode = "draw"
      } else if (event.key === Qt.Key_Up) {
        root.setFontSize(root.fontSize + 2)
      } else if (event.key === Qt.Key_Down) {
        root.setFontSize(root.fontSize - 2)
      } else if (!item) {
        return
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        item.text += "\n"
      } else if (event.key === Qt.Key_Backspace) {
        item.text = item.text.slice(0, -1)
      } else if (!ctrl && event.text.length > 0 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
        item.text += event.text
      }
      live.requestPaint()
      return
    }

    if (event.key === Qt.Key_Escape) {
      root.dismiss()
      return
    }

    if (root.mode === "break") {
      if (event.key === Qt.Key_Up) root.breakEndMs += 60000
      else if (event.key === Qt.Key_Down) root.breakEndMs = Math.max(Date.now(), root.breakEndMs - 60000)
      else root.colorKey(event.key, false)
      root.tickBreak()
      return
    }
    if (root.mode === "snip") return

    if (ctrl) {
      if (event.key === Qt.Key_C) root.exportView("copy")
      else if (event.key === Qt.Key_S) root.exportView("save")
      else if (event.key === Qt.Key_Z) root.undo()
      else if (event.key === Qt.Key_Y) root.redo()
      else if (event.key === Qt.Key_Up) root.penWidth = Math.min(60, root.penWidth + 1)
      else if (event.key === Qt.Key_Down) root.penWidth = Math.max(1, root.penWidth - 1)
      return
    }

    if (root.colorKey(event.key, shift)) return
    switch (event.key) {
    case Qt.Key_Up: if (root.mode === "zoom") root.zoomBy(1); break
    case Qt.Key_Down: if (root.mode === "zoom") root.zoomBy(-1); break
    case Qt.Key_X: root.blurPen = true; break
    case Qt.Key_E: root.eraseAll(); break
    case Qt.Key_W: root.board = root.board === "white" ? "" : "white"; break
    case Qt.Key_K: root.board = root.board === "black" ? "" : "black"; break
    case Qt.Key_T: root.enterType(shift); break
    }
  }

  function colorKey(key, asHighlighter) {
    var map = ({})
    map[Qt.Key_R] = "r"; map[Qt.Key_G] = "g"; map[Qt.Key_B] = "b"
    map[Qt.Key_O] = "o"; map[Qt.Key_Y] = "y"; map[Qt.Key_P] = "p"
    if (!map[key]) return false
    root.setPen(map[key], asHighlighter)
    return true
  }

  function pressed(mouse) {
    root.mx = mouse.x
    root.my = mouse.y

    if (mouse.button === Qt.RightButton) {
      if (root.mode === "type") {
        root.commitText()
        root.mode = "draw"
      } else if (root.mode === "draw" && root.zoom > 1) {
        // Back to panning; the view re-centres on the pointer.
        root.current = null
        root.anchorX = root.mx
        root.anchorY = root.my
        root.mode = "zoom"
        live.requestPaint()
      } else {
        root.dismiss()
      }
      return
    }

    if (root.mode === "type") {
      root.commitText()
      root.mode = "draw"
    } else if (root.mode === "snip") {
      root.selX1 = root.selX2 = root.mx
      root.selY1 = root.selY2 = root.my
      root.selecting = true
    } else if (root.mode === "zoom" || root.mode === "draw") {
      root.mode = "draw"
      root.beginStroke(mouse.modifiers)
    }
  }

  function moved(mouse) {
    root.mx = mouse.x
    root.my = mouse.y
    if (root.mode === "zoom") {
      root.anchorX = root.mx
      root.anchorY = root.my
    } else if (root.selecting) {
      root.selX2 = root.mx
      root.selY2 = root.my
    } else if (root.mode === "draw") {
      root.extendStroke()
    }
  }

  function released(mouse) {
    if (mouse.button !== Qt.LeftButton) return
    if (root.selecting) root.finishSnip()
    else if (root.mode === "draw") root.endStroke()
  }

  function wheeled(wheel) {
    var notches = wheel.angleDelta.y / 120
    if (notches === 0) return
    if (root.mode === "zoom") {
      root.zoomBy(notches)
    } else if (root.mode === "type") {
      root.setFontSize(root.fontSize + notches * 2)
    } else if (root.mode === "draw" && (wheel.modifiers & Qt.ControlModifier)) {
      root.penWidth = Math.max(1, Math.min(60, root.penWidth + notches))
    } else if (root.mode === "break") {
      root.breakEndMs = Math.max(Date.now(), root.breakEndMs + Math.round(notches) * 60000)
      root.tickBreak()
    }
  }

  function tracePoints(ctx, pts) {
    ctx.beginPath()
    ctx.moveTo(pts[0], pts[1])
    // A click with no drag still leaves a dot.
    if (pts.length === 2) ctx.lineTo(pts[0] + 0.01, pts[1])
    for (var i = 2; i < pts.length; i += 2) ctx.lineTo(pts[i], pts[i + 1])
    ctx.stroke()
  }

  function drawItem(ctx, item, withCaret) {
    if (item.t === "blur") return
    ctx.save()
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    ctx.strokeStyle = item.color
    ctx.fillStyle = item.color
    ctx.globalAlpha = item.hl ? 0.45 : 1

    if (item.t === "text") {
      root.drawText(ctx, item, withCaret)
      ctx.restore()
      return
    }

    ctx.lineWidth = item.width
    if (item.t === "pen") {
      root.tracePoints(ctx, item.pts)
    } else if (item.t === "line") {
      ctx.beginPath()
      ctx.moveTo(item.x1, item.y1)
      ctx.lineTo(item.x2, item.y2)
      ctx.stroke()
    } else if (item.t === "rect") {
      ctx.lineJoin = "miter"
      ctx.strokeRect(Math.min(item.x1, item.x2), Math.min(item.y1, item.y2),
        Math.abs(item.x2 - item.x1), Math.abs(item.y2 - item.y1))
    } else if (item.t === "ellipse") {
      ctx.beginPath()
      ctx.ellipse(Math.min(item.x1, item.x2), Math.min(item.y1, item.y2),
        Math.abs(item.x2 - item.x1), Math.abs(item.y2 - item.y1))
      ctx.stroke()
    } else if (item.t === "arrow") {
      root.drawArrow(ctx, item)
    }
    ctx.restore()
  }

  function drawArrow(ctx, item) {
    var hx = root.arrowHeadAtStart ? item.x1 : item.x2
    var hy = root.arrowHeadAtStart ? item.y1 : item.y2
    var tailX = root.arrowHeadAtStart ? item.x2 : item.x1
    var tailY = root.arrowHeadAtStart ? item.y2 : item.y1
    var length = Math.hypot(hx - tailX, hy - tailY)
    if (length === 0) return
    var ux = (hx - tailX) / length
    var uy = (hy - tailY) / length
    var head = Math.min(item.width * 4.5, length)
    var half = head * 0.45
    // Stop the shaft inside the head so its round cap doesn't blunt the tip.
    var baseX = hx - ux * head
    var baseY = hy - uy * head

    ctx.beginPath()
    ctx.moveTo(tailX, tailY)
    ctx.lineTo(baseX + ux * head * 0.3, baseY + uy * head * 0.3)
    ctx.stroke()

    ctx.beginPath()
    ctx.moveTo(hx, hy)
    ctx.lineTo(baseX - uy * half, baseY + ux * half)
    ctx.lineTo(baseX + uy * half, baseY - ux * half)
    ctx.closePath()
    ctx.fill()
  }

  function drawText(ctx, item, withCaret) {
    var lines = item.text.split("\n")
    var lineHeight = item.size * 1.2
    ctx.font = "bold " + Math.max(1, Math.round(item.size)) + "px sans-serif"
    ctx.textBaseline = "top"
    ctx.textAlign = item.right ? "right" : "left"
    for (var i = 0; i < lines.length; i++)
      ctx.fillText(lines[i], item.x, item.y + i * lineHeight)

    if (!withCaret) return
    var last = lines[lines.length - 1]
    var caretX = item.right ? item.x : item.x + ctx.measureText(last).width
    var caretY = item.y + (lines.length - 1) * lineHeight
    ctx.fillRect(caretX + item.size * 0.05, caretY, Math.max(item.size * 0.06, 1 / root.shown), item.size)
  }

  Process {
    id: capProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.captured(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.pending) root.dismiss()
    }
  }

  Timer {
    interval: 200
    repeat: true
    running: root.opened && root.mode === "break"
    onTriggered: root.tickBreak()
  }

  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened && (root.mode === "break" || shot.status === Image.Ready)
    color: "transparent"
    WlrLayershell.namespace: "tqdesign-zoomit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }

    // Zoom in once the still is on screen, so the animation is seen.
    onVisibleChanged: {
      if (visible && root.mode === "zoom" && root.zoom === 1) root.zoom = root.defaultZoom
      if (visible) keyCatcher.forceActiveFocus()
    }

    // Everything a copy or save should contain.
    Item {
      id: viewport
      anchors.fill: parent
      clip: true
      visible: root.mode !== "break"

      Item {
        id: scene
        width: viewport.width
        height: viewport.height
        x: root.tx
        y: root.ty
        scale: root.shown
        transformOrigin: Item.TopLeft

        Image {
          id: shot
          anchors.fill: parent
          source: root.shotFile ? "file://" + root.shotFile : ""
          cache: false
          asynchronous: false
          smooth: true
        }

        // Blur strokes are a mask over a blurred copy of the still.
        Canvas {
          id: blurMask
          anchors.fill: parent
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            ctx.strokeStyle = "#000000"
            var all = root.current && root.current.t === "blur" ? root.items.concat([root.current]) : root.items
            for (var i = 0; i < all.length; i++) {
              if (all[i].t !== "blur") continue
              ctx.lineWidth = all[i].width
              root.tracePoints(ctx, all[i].pts)
            }
          }
        }
        ShaderEffectSource {
          id: blurMaskSource
          sourceItem: blurMask
          hideSource: true
          visible: false
        }
        MultiEffect {
          anchors.fill: shot
          source: shot
          visible: root.blurCount > 0 && root.board === ""
          blurEnabled: true
          blur: 1
          blurMax: 64
          maskEnabled: true
          maskSource: blurMaskSource
        }

        Rectangle {
          anchors.fill: parent
          visible: root.board !== ""
          color: root.board === "white" ? "#ffffff" : "#000000"
        }
      }

      // Ink is painted in window space through the view transform, so lines
      // and text stay sharp at any zoom.
      Canvas {
        id: ink
        anchors.fill: parent
        visible: root.itemCount > 0
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)
          ctx.setTransform(root.shown, 0, 0, root.shown, root.tx, root.ty)
          for (var i = 0; i < root.items.length; i++) root.drawItem(ctx, root.items[i], false)
        }
      }
      Canvas {
        id: live
        anchors.fill: parent
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)
          if (!root.current) return
          ctx.setTransform(root.shown, 0, 0, root.shown, root.tx, root.ty)
          root.drawItem(ctx, root.current, true)
        }
      }
    }

    // Snip: dim everything outside the selection.
    Item {
      id: snip
      anchors.fill: parent
      visible: root.mode === "snip"

      readonly property real sx: root.selecting ? Math.min(root.selX1, root.selX2) : 0
      readonly property real sy: root.selecting ? Math.min(root.selY1, root.selY2) : 0
      readonly property real sw: root.selecting ? Math.abs(root.selX2 - root.selX1) : 0
      readonly property real sh: root.selecting ? Math.abs(root.selY2 - root.selY1) : 0
      readonly property color dim: Qt.rgba(0, 0, 0, 0.4)

      Rectangle { x: 0; y: 0; width: snip.width; height: snip.sy; color: snip.dim }
      Rectangle { x: 0; y: snip.sy + snip.sh; width: snip.width; height: snip.height - snip.sy - snip.sh; color: snip.dim }
      Rectangle { x: 0; y: snip.sy; width: snip.sx; height: snip.sh; color: snip.dim }
      Rectangle { x: snip.sx + snip.sw; y: snip.sy; width: snip.width - snip.sx - snip.sw; height: snip.sh; color: snip.dim }
      Rectangle {
        visible: root.selecting
        x: snip.sx - 1; y: snip.sy - 1
        width: snip.sw + 2; height: snip.sh + 2
        color: "transparent"
        border.width: 1
        border.color: "#ffffff"
      }
    }

    Rectangle {
      id: breakView
      anchors.fill: parent
      visible: root.mode === "break"
      color: root.breakBackground

      Text {
        anchors.centerIn: parent
        text: root.breakText()
        color: root.penColor
        font.family: "monospace"
        font.bold: true
        font.pixelSize: Math.round(breakView.height * 0.22)
      }
    }

    // The pen tip, shown in place of the pointer while drawing.
    Rectangle {
      readonly property real size: Math.max(root.blurPen ? 24 : root.highlight ? Math.max(root.penWidth, 16) : root.penWidth, 4)
      visible: root.mode === "draw"
      x: root.mx - width / 2
      y: root.my - height / 2
      width: size
      height: size
      radius: size / 2
      color: root.blurPen ? Qt.rgba(0.5, 0.5, 0.5, 0.5)
        : Qt.rgba(root.penColor.r, root.penColor.g, root.penColor.b, root.highlight ? 0.45 : 1)
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.5)
    }

    Rectangle {
      anchors.fill: parent
      color: "#ffffff"
      opacity: 0
      NumberAnimation on opacity { id: flash; running: false; from: 0.45; to: 0; duration: 220 }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: root.mode === "draw" || root.mode === "break" ? Qt.BlankCursor
        : root.mode === "type" ? Qt.IBeamCursor
        : root.mode === "snip" ? Qt.CrossCursor
        : Qt.ArrowCursor
      onPressed: function(mouse) { root.pressed(mouse) }
      onPositionChanged: function(mouse) { root.moved(mouse) }
      onReleased: function(mouse) { root.released(mouse) }
      onWheel: function(wheel) { root.wheeled(wheel) }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.keyPressed(event) }
      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Tab && !event.isAutoRepeat) root.tabHeld = false
      }
    }
  }
}
