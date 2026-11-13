# Design (pure): the Canvas tab (E2)

| File | What |
|---|---|
| `draw.luau` | Draws one scene root (CONTRACT §4) on a zgx canvas: fills (solid, linear; radial/angular as linear), image fills (`c:image`), strokes (inside/centre/outside, per-side), radius, clip, shadows (`c:shadow`), opacity, rotation/flip (transformed paths), text (`c:text` with line height, letter spacing, wrap, align, valign), icons (`icon.parts`), shapes (rect, ellipse arcs/donuts, polygon, SVG path). Also used by `render.luau` for agents' screenshots. |
| `model.luau` | Scene index, hit testing (pen.dev's pick rules), snapping, smart guides, Alt measurements. |
| `canvas.luau` | The Canvas component: `ui.canvas { view, each = roots }` for the Design (pan/zoom redraw nothing), a lifted layer for what a move drags, a screen-space overlay canvas for hover, selection, handles, W×H pill, guides, marquee, flashes, text caret. All pointer and key handling. Edits go out as contract ops. |
| `shell.luau` | The editor as pen.dev lays it out, at its sizes: title bar, left panel (Layers / Components / Variables), tool rail, Theme bar, properties, zoom pill, right-click menu. `init.luau` builds a tab from it. |
| `layers.luau` | pen's tree: collapse, type icons, Component/Instance colours, hover synced with the Canvas, click / Shift, double-click rename, eye and lock, drag to reorder or into a frame. |
| `props.luau` | pen's properties: header actions, Alignment, Position, Layout + Dimensions, Appearance, Fill, Stroke, Effects, Typography. Fields commit on Enter or blur (a Canvas click blurs). |
| `picker.luau` | The paint picker: Solid (spectrum, hue, alpha, hex, %, variables), Gradient (type, angle, stops), Image (URL, mode). |
| `kit.luau`, `look.luau`, `icon_paths.luau` | Small parts at pen's metrics, pen's light/dark colours, the panel icons (from port/web/ui.js). |
| `service_source.luau` | The Canvas's source over the service (`scene`, `changed`, `selection`, `edit`, `undo`, `redo`, `select`). |
| `fixture_source.luau` | The same over a fixture, applying ops locally (no layout), for the harness. |
| `render.luau` | `render` events → `ui.render_canvas` → `render_done`. |
| `harness.luau` | A dev app: `zgx-run --inspect harness.luau`. |
| `fixtures/` | Scenes in contract shape: `stillwater`, `pulse` (from zd's layout, `pure/e2/make_fixture.py`), `features` (hand-made, `pure/e2/make_features.py`). |

Run the harness headless (never on the user's desktop):

```sh
ZGX_RENDER_WHEN_COVERED=1 python dev/hidden_desktop.py run E2Canvas pure/e2/harness.log pure/e2/zgx-run.exe --inspect pure/plugin/tab/harness.luau
pure/e2/zgx-cli.exe inspect set harness.fixture '"pulse"'
pure/e2/zgx-cli.exe inspect replay '#design-canvas-pulse' pure/e2/tapes/pulse-sel-drag.tape
python pure/e2/shot.py out.png          # the Canvas alone, via ui.render_canvas
python pure/e2/shotwin.py <pid> out.png  # the whole window, popups included (PrintWindow on the hidden desktop)
python pure/e2/sheets.py <pid>          # pen.dev | ours, per panel state, into pure/e2/sheets/
pure/e2/zgx-cli.exe inspect command bench && pure/e2/zgx-cli.exe inspect state harness.bench --full
```

`zgx-run.exe` is built from `pure/e2/zgx` (hoangvu12/zgx nightly-design + ui.load_font).

On the hidden desktop the window draws a frame only on input: after `inspect set`, move the pointer (`inspect hover 700,250`) before reading or picturing (sheets.py does). Popups (menus, the picker) are windows of their own on Windows; shotwin.py lays them over the main one.

Images: `img:<key>` pictures come from the source (`image_get`, base64), are decoded once with `ui.decode_image` into `Draw.images[key]`, and the roots showing them draw again. Needs zgx nightly-design >= 066f3c583. The eyedropper samples the Design under the pointer (no zgx API samples the screen).





