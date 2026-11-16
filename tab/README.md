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
| `agent_fx.luau` | (N1) An agent's changes animated over the board, Paper-style (`pure/anim/n1/README.md`): reveal sweep + staggered child outlines + ring for new nodes, tint for edits, ghost for deletes, a wash for reads, blinking dots on Screens in progress. Small elements animated by `anime` in Rust, only while on screen; `reduce` = "Reduce agent animations". (N8, `pure/anim/n8/README.md`) plays once: dropped when panned away, never replayed; a cover goes if the zoom changes; one ticker ends entries. |
| `agent_fx_plan.luau` | (N8) Pure: when each piece of one agent call reveals. A new Screen with 2+ parts = a fast "shell" sweep then each part (reading order) ~180 ms apart, all within 2 s; several new nodes staggered; edits/deletes/reads at once. Also the play-once rule (`state`). |
| `variations_bar.luau` | (N2) The Variations bar (`pure/anim/n2/README.md`): (N8) at the bottom centre of the board, the node most in view outlined thinly, its name zooms to it; "2 of 5 · name ‹ › Use this ×"; ← → when focused, Enter = Use this. Sends `variation` ops (show: no undo step; keep / discard: one each). Mounted by `shell.luau` over the Canvas, as the comment pins (inside the Canvas the board keeps the pointer, so its buttons would get no click). |
| `fixture_source.luau` | The same over a fixture, applying ops locally (no layout), for the harness. |
| `render.luau` | `render` events → `ui.render_canvas` → `render_done`. |
| `proto.luau` | Prototyping's shared reading of the scene (`ia`, `st`, `sttr`; spec `pure/anim/proto-step1-spec.md`): drivers and their hover/press looks, Play's hit test, each transition's motion and its reverse, eases as anime's `cubicBezier`. Pure. |
| `play.luau` | Play (Ctrl+Enter): each Screen its own `ui.canvas` element, the Screens a link reaches mounted ahead under the shown one; transitions move/fade those elements with `anime` (no script per frame; `pure/anim/m0-perf.md`). Nodes with states are lifted into small overlay elements (rest, hover, pressed looks, each drawn once), faded and scaled with `ui.tween`; the Screen under them is drawn once with them hidden. Back, Restart, Esc, flows. |
| `gif.luau` | GIF layers (step 7, `pure/anim/f7/gif/README.md`), pure: which GIF fills of a Screen layer play in Play (`plan`: 4 always, up to 16 while their boxes are small (`MIN`/`AREA`/`CAP`), decoded (2nd result: the ones still decoding), turned ones in their bounding box, not inside a turned clip, not left out, cut by the clips around, opacity carried, whether something paints over), `ids` (Draw's `gifs`), `has_gif` (Layers' badge). The board draws first frames only. |
| `play_gifs.luau` | Play's playing GIFs (`pure/anim/f7/followups/README.md`): `layer` plans a layer's (or a driver look's) GIFs and adds a late-decoded one when its picture arrives (Draw.listeners), `add` puts the `ui.image` elements (zgx plays them) over the layer's canvas with the small canvas of what paints over each (Draw's `after`), `look` wraps a driver's hover/press look with its GIFs. |
| `comments.luau`, `comments_rules.luau`, `comments_ui.luau` | Local comments (step 7, `pure/anim/f7/comments/README.md`). `comments_rules`: the pure rules (add, reply, edit, resolve, reopen, delete; rows → pins), shared with `engine/comments.luau`. `comments`: pure tab helpers (a pin's place on a Screen as drawn, a click → Screen and layer point, the sidebar's groups, an in-memory store for the fixture source). `comments_ui`: pins and cards as elements over the stage or board, the list, and Play's comment mode (`play`, built in Play as `dev.cm`). |
| `curve.luau` | The Prototype panel's curve editors (step 2), the panel's full width: a custom bézier with its two handles to drag; a custom spring dragged on its graph as SwiftUI's and Framer's time (sideways) and bounce (up and down), the duration following live (`Proto.spring_feel` / `spring_from_feel`). Their numbers, labelled, sit under Advanced. A drag commits once, on release (one undo step). |
| `proto_panel.luau` | The properties' Prototype tab: Interactions (navigate / back / link, animation, direction, ms, ease), States (Hover, Pressed, layers inside, transition), Reset for an Instance's overrides; Flows with nothing selected. Every change one `edit` op. Step 5 (V5a): Set variable, Toggle variable, Set variable mode, Conditional (if box, Then/Else lists, nested, folded past 3 levels), checked inline with `proto_vars.luau`. Step 6 (F6 panel rows): Device (grouped presets with sizes, Model, Portrait / Landscape, a thumbnail drawn with `device_frame.luau`, Show device frame, Scaling, Background), a Description box per flow, and a selected Screen's Flow starting point. Rebuilt (`ui.presence`) when `flows` or `prototype` change. |
| `play_flows.luau` | Step 6 (F6 P3), pure: Play's flows sidebar: its width (`W`, 240), open by default (`open`: the viewer's choice, else 2+ flows), the playing flow (`current`), and a flow's description cut into paragraphs, `- ` / `1. ` lists and links (`blocks`, `runs`). Used by `play.luau`. |
| `proto_match.luau` | Step 6 (F6 C2), pure: several layers' interactions as one panel (`merge`: a row per trigger key, values they don't share as `MIXED`, `transition`/`offset` merged by key, a differing Conditional branch Mixed whole) and Select matching (`matching`: the same name path from the Screen, in every Screen, with an `equal` reaction; `scene_k`). Used by `proto_panel.luau`. |
| `ia_clip.luau` | Step 6 (F6 C3): the interaction clipboard, module-wide (every Design tab in the window), apart from the service's layer clipboard; Ctrl+V pastes whichever was copied last (`newer`). `records` (noodles `{ id, k }` → stored records), `keep` (destinations not in the Design dropped, inside Conditionals too), `ops` / `paste` (appended to each layer, an Instance's inherited list kept under it, one edit). Used by `canvas.luau`, `proto_panel.luau`, `shell.luau`. |
| `proto_vars.luau` | The Prototype panel's variable actions, pure: reads the Tokens, checks Set variable / Toggle / mode / if with `expr.luau` (V1's messages), turns typed text into the stored `to`/`cond`, makes fresh actions. V5b: the binding helpers (`bind_vars`, `vars_of`, `bind_ref`, `var_text`, `bind_literal`). |
| `bind.luau` | Step 5 (V5b): binding a property to a variable. `Bind.button` (Apply variable: the typed list, `Picker.Vars`, beside the panel) and `Bind.chip` (a bound value: name, value, detach, a click swaps it). Used by `props.luau` (text, visibility, fill, numbers) and `proto_panel.luau` (Variant rows). |
| `expr.luau` | **A byte-for-byte copy of `engine/expr.luau`** (the harness can't load modules above `tab/`). After an engine change, copy it over: `tests/vars_panel.luau` fails until you do. |
| `harness.luau` | A dev app: `zgx-run --inspect harness.luau`. Commands `play-state` (Play's numbers into `harness.play`) and `proto-heavy` (links two busy Screens of the loaded fixture). |
| `fixtures/` | Scenes in contract shape: `stillwater`, `pulse` (from zd's layout, `pure/e2/make_fixture.py`), `features` (hand-made, `pure/e2/make_features.py`), `proto` (hand-made: three Screens, a Component button with states, links, a flow). |

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





