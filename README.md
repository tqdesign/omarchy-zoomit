# ZoomIt

Screen zoom, annotation, break timer, snip, recording and DemoType for
presentations, modelled on Sysinternals
[ZoomIt](https://learn.microsoft.com/sysinternals/downloads/zoomit). Built as an
[Omarchy](https://omarchy.org/) shell plugin for Hyprland.

## Hotkeys

| Key | Mode |
| --- | --- |
| `Ctrl+1` | Zoom: freeze the screen and magnify it around the pointer |
| `Ctrl+2` | Draw on the frozen screen without zooming |
| `Ctrl+3` | Break timer |
| `Ctrl+4` | Live zoom: the desktop stays usable; `Ctrl+Up`/`Ctrl+Down` change the level |
| `Ctrl+5` | Start or stop a screen recording (`Ctrl+Shift+5` picks a region) |
| `Ctrl+6` | Snip a region to the clipboard (`Ctrl+Shift+6` saves a file) |
| `Ctrl+7` | DemoType: type the next segment (`Ctrl+Shift+7` steps back) |

These are ZoomIt's defaults, so `Ctrl+1`..`Ctrl+7` no longer reach apps (browser
tab switching, for one). Change them in the `keys` table at the top of
`hypr/zoomit.lua`.

The overlay opens on the monitor the pointer is on. Pressing a mode's key again
leaves it; so does `Esc`.

### Zoom

| Input | Action |
| --- | --- |
| Move the mouse | Pan |
| Wheel, `Up`, `Down` | Zoom level |
| Left click | Start drawing |
| `T` | Start typing |
| Right click, `Esc` | Leave |

### Draw

| Input | Action |
| --- | --- |
| Drag | Freehand |
| `Shift`+drag | Straight line |
| `Ctrl`+drag | Rectangle |
| `Tab`+drag | Ellipse |
| `Ctrl+Shift`+drag | Arrow, head at the start of the drag |
| `R` `G` `B` `O` `Y` `P` | Pen colour: red, green, blue, orange, yellow, pink |
| `Shift`+colour | Highlighter in that colour |
| `X` | Blur pen |
| `Ctrl`+wheel, `Ctrl+Up`, `Ctrl+Down` | Pen width |
| `Ctrl+Z`, `Ctrl+Y` | Undo, redo |
| `E` | Erase everything |
| `W`, `K` | White or black board (again to return) |
| `T`, `Shift+T` | Type at the pointer, left or right aligned |
| `Ctrl+C` | Copy the view to the clipboard |
| `Ctrl+S` | Save the view to your Pictures folder |
| Right click | Back to zoom, or leave when not zoomed |

While typing, the wheel or `Up`/`Down` change the font size, `Enter` starts a new
line, and `Esc` or a click finishes the text.

### Break timer

Counts down from 10 minutes, then shows the overrun in brackets. `Up`/`Down` or
the wheel add and remove a minute; the colour keys recolour the digits.
`zoomit break 15` starts at 15 minutes.

### DemoType

Put the script in `~/.config/zoomit/demotype.txt`; with no file it types the
clipboard. `[end]` splits it into segments, one per key press. Inside a segment,
`[pause:2]` waits two seconds and `[enter]` `[tab]` `[up]` `[down]` `[left]`
`[right]` press that key. `zoomit demotype reset` starts over.

## Install

```bash
omarchy plugin add https://github.com/tqdesign/omarchy-zoomit.git --enable
```

Add the hotkeys to `~/.config/hypr/bindings.lua`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/tqdesign.zoomit/hypr/zoomit.lua")
```

Validate with `hyprctl reload && hyprctl configerrors`. To use the commands from
a terminal, put the launcher on your `PATH`:

```bash
ln -s ~/.config/omarchy/plugins/tqdesign.zoomit/bin/zoomit ~/.local/bin/zoomit
```

Needs `grim`, `jq`, `imagemagick`, `wl-clipboard` and `wtype`, all of which
Omarchy installs.

## How it works

`Overlay.qml` runs `bin/zoomit-capture`, which finds the monitor under the
pointer and freezes it with `grim`. The overlay shows that still on a
layer-shell surface with exclusive keyboard focus and scales it about the
pointer. Annotations are stored in unzoomed screen coordinates and painted
through the view transform, so they stay sharp and in place at any zoom.

Live zoom is Hyprland's `cursor.zoom_factor`, and recording is Omarchy's
`omarchy-capture-screenrecording`; `hypr/zoomit.lua` and `bin/zoomit` only give
them ZoomIt's keys.

## Tuning

Edit the properties at the top of `Overlay.qml`, then run
`omarchy restart shell`.

| Property | Default | Meaning |
| --- | --- | --- |
| `defaultZoom` | `2` | Zoom level when zoom mode opens |
| `zoomStep` | `1.1` | Zoom change per wheel notch |
| `defaultPenWidth` | `5` | Pen width in px |
| `defaultFontSize` | `36` | Text size in px |
| `defaultBreakMinutes` | `10` | Break timer length |
| `breakBackground` | `"#ffffff"` | Break timer background |
| `arrowHeadAtStart` | `true` | `false` puts the arrow head where the drag ends |

## Differences from ZoomIt

- `Ctrl+S` saves straight to the Pictures folder instead of asking for a name.
- Recording has no window mode, and no trim editor afterwards.
- DemoType always types by itself; there is no key-per-character mode.
- There is no settings dialog; tune the files above.

## License

MIT
