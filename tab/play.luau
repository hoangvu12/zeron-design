--!strict
local ui = require("./pointer").ui
-- Play: the prototype clicked through inside the tab (proto-step1-spec §6),
-- drawn as pure/anim/m0-perf.md found smooth on a heavy Design:
--
-- - each Screen is its own `ui.canvas` element, drawn once (the board canvas
--   is never written while playing); a transition moves and fades those
--   elements (`anime`, on the compositor: no script per frame);
-- - the Screens a link can reach are mounted ahead, under the one shown at
--   a near-zero opacity, so their raster is made before a transition starts;
-- - every node with hover/press states is lifted out of its Screen (drawn
--   once with those nodes hidden) into a small overlay element holding its
--   rest, hover and pressed looks, each drawn once; a state change fades the
--   look over the one under it and scales the element (`ui.tween`, Rust).
--
-- Keys: ← / Backspace back, → / Space / N next (step 6 P1), R restart,
-- Z the next scaling choice, Ctrl+\ hides the bar, Esc closes.

local Draw = require("./draw")
local PlayPlace = require("./play_place")
local PlayFlows = require("./play_flows")
local Look = require("./look")
local Kit = require("./kit")
local Proto = require("./proto")
local Scroll = require("./scroll")
local Smart = require("./smart")
local Variants = require("./variants")
local PV = require("./play_vars")
local DeviceFrame = require("./device_frame")
local Gif = require("./gif")
local CommentsUI = require("./comments_ui")
local PlayGifs = require("./play_gifs")

local M = {}

-- (step 6 P2) A rounded rect path with a radius per corner ({ tl, tr, br, bl }
-- or one number), clockwise; zgx's own rounded rect when they're equal.
local KAPPA = 0.5523
local function rrect(p: any, x: number, y: number, w: number, h: number, r: any): any
	local m = math.max(0, math.min(w, h) / 2)
	if type(r) ~= "table" then
		return p:rect(x, y, w, h, math.min(r or 0, m))
	end
	local tl, tr, br, bl = math.min(r[1] or 0, m), math.min(r[2] or 0, m), math.min(r[3] or 0, m), math.min(r[4] or 0, m)
	if tl == tr and tr == br and br == bl then
		return p:rect(x, y, w, h, tl)
	end
	local k = KAPPA
	p = p:move(x + tl, y):line(x + w - tr, y)
	if tr > 0 then
		p = p:cubic(x + w - tr + tr * k, y, x + w, y + tr - tr * k, x + w, y + tr)
	end
	p = p:line(x + w, y + h - br)
	if br > 0 then
		p = p:cubic(x + w, y + h - br + br * k, x + w - br + br * k, y + h, x + w - br, y + h)
	end
	p = p:line(x + bl, y + h)
	if bl > 0 then
		p = p:cubic(x + bl - bl * k, y + h, x, y + h - bl + bl * k, x, y + h - bl)
	end
	p = p:line(x, y + tl)
	if tl > 0 then
		p = p:cubic(x, y + tl - tl * k, x + tl - tl * k, y, x + tl, y)
	end
	return p:close()
end
local function scaled(r: any, z: number): any
	if type(r) == "table" then
		return { (r[1] or 0) * z, (r[2] or 0) * z, (r[3] or 0) * z, (r[4] or 0) * z }
	end
	return (r or 0) * z
end

-- (step 6 P2) A device frame's shapes (tab/device_frame.luau) painted on a
-- canvas: the screen's top-left at (ox, oy), `z` points a frame point, `bg`
-- the stage's colour (for the `bg = true` cuts).
local function paint_frame(c: Canvas, list: { any }, ox: number, oy: number, z: number, bg: string)
	for _, s in list do
		if s.kind == "rect" then
			c:fill(rrect(ui.path(), ox + s.x * z, oy + s.y * z, s.w * z, s.h * z, scaled(s.r, z)), s.fill)
		elseif s.kind == "circle" then
			c:circle(ox + s.x * z, oy + s.y * z, s.r * z, s.fill)
		elseif s.kind == "corners" then
			local o = (s.o or 0) * z
			local x, y, w, h = ox + s.x * z, oy + s.y * z, s.w * z, s.h * z
			local p = rrect(ui.path(), x - o, y - o, w + 2 * o, h + 2 * o, scaled(s.ro, z))
			c:fill(rrect(p, x, y, w, h, scaled(s.r, z)), s.fill, "evenodd")
		elseif s.kind == "poly" then
			local pts = s.pts
			local p = ui.path():move(ox + pts[1] * z, oy + pts[2] * z)
			for k = 3, #pts - 1, 2 do
				p = p:line(ox + pts[k] * z, oy + pts[k + 1] * z)
			end
			p = p:close()
			c:fill(p, if s.bg then bg else s.fill)
			if s.bg then
				-- (its edges' antialiasing let the Screen's colour through as a
				-- faint outline; just past them is the stage anyway)
				c:stroke(p, bg, 1.5)
			end
		end
	end
end

local BAR_H = 44
local PREFETCH = 4
-- (step 6 P1) The hotspot hint: drawn once, then faded on the compositor
-- (Figma's: strongest at once, gone in about 0.5–1 s)
-- (step 6 P6) Figma's colour, not the Design's accent: a fixed light blue at
-- 85% with a 1.5 px outline of it at the hotspot's own (square) corners,
-- faded inQuad over 500 ms. Fitted to Figma's film on a blue button, base
-- (38,89,242): (45,165,251) at 150 ms (≈ 0.77 of the blue: ours 0.77) and
-- (41,117,245) at 400 ms (≈ 0.31: ours 0.31), the base again by 1.6 s.
local HINT_MS = 500
local HINT_BLUE = "#30B4FF"
local HINT_FILL = "#30B4FFD9" -- (85%)
-- An overlay mounted ahead sits over the Screen: its opacity rounds to no
-- colour at all (0.0004 × 255 < 0.5), yet it's drawn, so its raster is ready.
local OV_SPARE = 0.0004

export type PlayProps = {
	L: any,
	source: any,
	start: string, -- the Screen to start at
	flow: string?, -- its flow's name
	id: string?, -- (step 6 P1) the Design's id: the session's scaling choice is kept per Design
	on_close: () -> (),
	log: ((string) -> ())?,
	expose: ((api: any) -> ())?,
	-- (step 6 P4) "preview": the inline Preview beside the canvas (a compact
	-- bar, no sidebar, phone/tablet/watch frames only, the editor's keys let
	-- through, live edits throttled). Its callbacks: `on_shown(id)` each
	-- Screen shown, `follow` read by the shell; `on_play(id)` Open in Play;
	-- `on_100(w, h)` Resize to 100% (the island's size for the Screen at 100%);
	-- `on_escape` hands keys back to the canvas.
	mode: string?,
	on_shown: ((id: string, follow: boolean) -> ())?,
	on_play: ((id: string) -> ())?,
	on_100: ((w: number, h: number) -> ())?,
	on_escape: (() -> ())?,
}

-- (step 6 P6) The display's scale, when told (0: not told): Play's raster
-- cap counts device pixels. Windows takes no snapshot for Play to measure
-- it by; the hidden-desktop harness tells its 1× here
-- (`play.luau::design.display_scale`).
M.display_scale = ui.state("design.display_scale", 0)

function M.Play(props: PlayProps): Node
	local L = props.L
	local D = Look.of(true) -- (the backdrop is dark, as Figma's presentation)
	local source = props.source
	local roots = source.roots

	local stage = ui.use_state({ w = 0, h = 0 })
	-- The mounted Screens: { key, id }. The one shown is `current`.
	local slots = ui.use_state({} :: { any })
	local zs = ui.use_state({} :: { [string]: number })
	local current = ui.use_state(nil :: string?) -- a slot key
	local title = ui.use_state("")
	local cursor = ui.use_state("default")
	local hint = ui.use_state(nil :: any) -- { key, rects } while flashing
	local hint_ms = HINT_MS -- (tests can slow the fade to take its picture)
	-- The viewport: where the shown Screen is on the stage. It clips every
	-- Screen, as Figma's frame does, so a transition happens inside it (a
	-- push moves each Screen its own width, not across the stage).
	local vp = ui.use_state({ left = 0, top = 0, w = 0, h = 0 })
	-- (step 6 P2) The device frame round the shown Screen's viewport: { k,
	-- left, top, z, vw, vh, sw, sh, frame, rotate, model, bg }, or nil without
	-- one. Set when a Screen is shown, so a transition never moves it; its
	-- canvases are made again only when `k` changes (size, model, rotation).
	-- (`dev` holds P2's parts: Play is near Luau's 200-locals limit)
	local dev: any = { pl = ui.use_state(nil :: any), open = ui.use_state(false) }
	-- (step 6 P4) the inline Preview: `dev.pre` (in `dev` for the locals limit)
	dev.pre = props.mode == "preview"
	-- (step 6 P3) The flow playing, as session state: the flows sidebar picks
	-- another (and restarts there). `cur` = { start, flow }; `side` = the
	-- viewer's sidebar choice, { open = bool? }, kept per Design (nil: open
	-- with 2+ flows). Also in `dev`, for the locals limit.
	dev.cur = ui.use_state({ start = props.start, flow = props.flow })
	dev.side = if props.id
		then ui.state(`design.{props.id}.play_flows`, {} :: any) -- zgx-lint: allow(state-in-component)
		else ui.use_state({} :: any)
	-- Overlays (step 2, figma-parity.md §3.3): slots like a Screen's, each its
	-- own canvas element placed in the viewport over the Screen, with a
	-- backdrop under it; painted after the Screens in `ovs` order. The open
	-- ones, bottom → top, are `ov_stack`; the rest are spares mounted ahead.
	local ovs = ui.use_state({} :: { any })
	local ov_at = ui.use_state({} :: { [string]: any }) -- where each overlay slot is on the stage
	local ov_stack: { string } = {}
	local drop_ov: (key: string) -> () -- (below: smart bases of an overlay use it first)
	-- (L1) The last overlay closed, however (Close, a click outside, Esc,
	-- Back, the pointer leaving): the Screen picks up its variant changes
	-- (F4b's Figma film), then `done`. Set once the variant code is (below).
	local ov_closed: ((done: () -> ()) -> ())? = nil
	-- (L1) Smart Animate's movers for an overlay (a Change to in it, a Swap):
	-- over the overlays, as `movers` are over the Screens
	local ov_movers = ui.use_state({} :: { any })
	local busy = false -- a transition running: input waits
	-- (F4-int) A Change to let go of: its motion plays on over the look now
	-- shown, until it ends or a Change to on that look takes it over.
	local coast: any = nil
	local vpending = 0 -- Change to looks being fetched: a click meanwhile waits for them
	local history: { { id: string, tr: any? } } = {}
	-- (step 6 P1) → : the Screens Back left (newest last), then the shown
	-- Screen's first link to one not yet visited, then the next by x, y.
	local forward: { { id: string, tr: any? } } = {}
	local visited: { [string]: boolean } = {}
	local made = 0
	-- Per slot: its root as drawn, its element, its drivers' states, layout.
	local slot_data: { [string]: any } = {}
	local hovered: any = nil -- { key, d }
	local pressed: any = nil -- { key, link, d }
	-- Timings for the harness's numbers (ms): mount → shown, transitions.
	-- (V3: `vars`, each variable change on the shown Screen: { how, ms, patches })
	local perf = { draw = {} :: { number }, transitions = {} :: { any }, hovers = {} :: { number }, overlays = {} :: { any }, vars = {} :: { any }, hints = 0, relayouts = 0, frame_draws = 0 }

	local function say(s: string)
		if props.log then
			props.log(s)
		end
	end

	-- (step 6 P5) Responsive: the Screens laid out at the window's size (or
	-- the device's), fetched from the service (`source.sized_roots`) per size.
	-- `on`: Responsive is in force; `k` = "<w>x<h>" of `roots` ({ [id] = {
	-- root, src = the Design's root it was made from } }); `want`: the size
	-- being fetched. A Screen's base is its sized root while `on` (an
	-- overlay-only frame keeps its size). Until a size lands, the old look stays.
	dev.rz = { on = false, k = nil :: string?, w = 0, h = 0, roots = {} :: { [string]: any }, want = nil :: string?, fgen = 0, pending = 0, fetches = 0 }
	function dev.root0(id: string): any?
		for _, r in roots:peek() do
			if r.id == id then
				return r
			end
		end
		return nil
	end
	local function base_root(id: string): any?
		local rz = dev.rz
		if rz.on then
			local e = rz.roots[id]
			if e then
				return e.root
			end
		end
		return dev.root0(id)
	end
	-- (step 4, figma-parity.md §3.4) Interactive components: each Screen's
	-- variant state, resolved by the service (`source.variant_root`), as
	-- `vroots[id] = { base, vmap, root }` (good while `base` is the Screen as
	-- the Design has it); `vmem` remembers the member per Instance by Screen
	-- group and name path (tab/variants.luau), shared by matching Screens.
	local vroots: { [string]: any } = {}
	local vmem: { [string]: any } = {}
	-- (step 5, V3; pure/anim/f5/PLAN.md) Variables: the session's run state,
	-- engine/vars.luau's model (tab/play_vars.luau). Kept across navigate,
	-- Back, overlays and Reset component state; only Restart (or the
	-- popover's Reset) clears it. A Screen's look is resolved for its variant
	-- state and the part of this state it reads (`vroots[id].rs`, the root's
	-- `uses`), so every route that fetches a look picks variables up.
	local pv: any = { toks = {}, themes = {}, vars = {}, mode = {}, loaded = false }
	local pv_ver = ui.use_state(0) -- (the values popover reads it)
	local function view_theme(): any
		return if source.view_theme_map then source.view_theme_map() else {}
	end
	-- The run-state key of Screen `id`'s look ("" for the Design's values);
	-- `st` = { vars, mode } instead of the session's (a predicted click).
	local function rsig_of(id: string, st: any?): string
		local b = base_root(id)
		if not b then
			return ""
		end
		return PV.run_sig(pv.toks, b.uses, if st then st.vars else pv.vars, if st then st.mode else pv.mode)
	end
	local function root_of(id: string): any?
		local b = base_root(id)
		local v = vroots[id]
		if b and v and v.base == b then
			return v.root
		end
		return b
	end

	-- The Design's device (the scene's `device`: { w?, h?, fit, bg? }), or nil.
	-- (step 6 P4: the Preview shows phone, tablet and watch frames only)
	local function device(): any?
		local dv = source.device and source.device:peek()
		if type(dv) ~= "table" then
			return nil
		end
		return if dev.pre then PlayPlace.preview_device(dv) else dv
	end

	-- (step 6 P1) The session's choices from the Options menu: { fit?, dfit?,
	-- frame?, hints? }, over the Design's (`prototype.fit` …). Kept per Design
	-- so the next Play remembers them; without an id, for this Play only.
	-- (step 6 P4: the Preview keeps its own, with `follow`)
	local sess = if props.id
		then ui.state(`design.{props.id}.{if dev.pre then "preview_fit" else "play_fit"}`, {} :: any) -- zgx-lint: allow(state-in-component)
		else ui.use_state({} :: any)
	local hide_ui = ui.use_state(false) -- Ctrl+\ (Figma's Hide UI)
	-- (step 6 P6) The display's scale, pixels a point: zgx's raster cache
	-- counts device pixels (PlayPlace.cap_pts). Luau isn't told it, so Play
	-- measures it once: a snapshot of a small element of its own is that many
	-- pixels wide. Until then (or where the host takes no snapshot),
	-- PlayPlace.DEFAULT_SCALE. `dev.cap`: { px, scale, n } for the harness.
	dev.scale_set = M.display_scale
	dev.scale = PlayPlace.DEFAULT_SCALE
	dev.scale_measured = false
	-- (a scale told, `design.display_scale`, wins: read when placing)
	function dev.told()
		local s = dev.scale_set:peek()
		if type(s) == "number" and s >= 1 and s <= 8 then
			dev.scale, dev.scale_why = s, "set"
		end
	end
	dev.cap = { px = 0, scale = dev.scale, n = 0 }
	local function settings(): any
		local st = PlayPlace.settings(device(), sess:peek())
		if dev.pre then
			st.margin = PlayPlace.PREVIEW_MARGIN
		end
		dev.told()
		st.cap = PlayPlace.cap_pts(dev.scale)
		return st
	end

	-- Where a Screen sits on the stage (F2a, figma-parity.md §3.2; step 6 P1,
	-- tab/play_place.luau): the viewport is the device's size (or the
	-- Screen's own without one), a Screen bigger than it scrolls inside it,
	-- and it fits the stage per the scaling chosen (the session's, else the
	-- Design's): plain Actual size / Fit width and height / Fit width / Fill
	-- screen, or with a device frame Fit device / Zoom to fill / 100%, the
	-- frame's insets counted. `vw`, `vh`: the viewport in Canvas units; `w`,
	-- `h`: in points.
	local function place(r: any): any
		local s = stage:peek()
		return PlayPlace.place(s.w, s.h, r.nodes[1].box, device(), settings())
	end

	-- An overlay slot's place: in the shown Screen's viewport (`base`), by
	-- its position (Proto.overlay_place, shared with the engine's Simulate),
	-- at that Screen's zoom; cut to the viewport (what's past it scrolls).
	-- `ox`, `oy`: where it is in the viewport (points).
	local function ov_place(sd: any): any
		local cur = current:peek()
		local base = cur and slot_data[cur]
		local bp = base and (base.place or place(base.root))
		if not bp then
			return place(sd.root)
		end
		local z = bp.z
		local b = sd.root.nodes[1].box
		local ov = sd.ov
		local x, y, w, h = Proto.overlay_place(ov.pos, ov.ox, ov.oy, bp.vw, bp.vh, b.w, b.h, ov.tx, ov.ty)
		return {
			z = z,
			left = math.floor(bp.left + x * z + 0.5),
			top = math.floor(bp.top + y * z + 0.5),
			w = w * z,
			h = h * z,
			vw = w,
			vh = h,
			tall = b.h > h + 0.5,
			b = b,
			ox = x,
			oy = y,
			base = bp,
		}
	end

	-- A Screen's part of the stage: its viewport.
	local function frame_of(pl: any): any
		return { left = pl.left, top = pl.top, w = pl.w, h = pl.h }
	end
	local function union(a: any, b: any): any
		local l, t = math.min(a.left, b.left), math.min(a.top, b.top)
		return { left = l, top = t, w = math.max(a.left + a.w, b.left + b.w) - l, h = math.max(a.top + a.h, b.top + b.h) - t }
	end
	local function set_vp(f: any)
		local now = vp:peek()
		if now.left ~= f.left or now.top ~= f.top or now.w ~= f.w or now.h ~= f.h then
			vp:set(f)
		end
	end
	-- (step 6 P2) The frame for the shown Screen's place `pl` (none when it
	-- isn't framed: no device, a custom size, or the frame hidden).
	function dev.set(pl: any)
		local dv = device()
		local d = nil
		if pl.inset and dv and dv.frame then
			local s = stage:peek()
			local bg = dv.bg or D.canvas
			d = {
				left = pl.left, top = pl.top, z = pl.z, vw = pl.vw, vh = pl.vh, sw = s.w, sh = s.h,
				frame = dv.frame, rotate = dv.rotate == true, model = dv.model, bg = bg,
			}
			d.k = string.format("%s|%s|%s|%s|%d,%d|%.4f|%.2f,%.2f|%d,%d", dv.frame, tostring(d.rotate), tostring(dv.model), bg, pl.left, pl.top, pl.z, pl.vw, pl.vh, s.w, s.h)
		end
		local now = dev.pl:peek()
		if (now and now.k) ~= (d and d.k) then
			dev.pl:set(d)
		end
	end

	local function set_z(key: string, z: number)
		zs:set_key({ key }, z)
	end

	-- ── scrolling (F2a; tab/scroll.luau) ─────────────────────────────────
	-- Each scroller's offset (Canvas units) is a pair of states, made by its
	-- element (`sd.pos[s] = { x, y }`); before it mounts, `sd.init[s]`.
	-- Offsets are remembered by Screen and name path (Figma's scroll memory).
	local memory: { [string]: { number } } = {}
	local function plan_of(sd: any): any
		return Scroll.plan(sd.root, Proto.of_root(sd.root).drivers)
	end
	local function pos_of(sd: any, s: number): (number, number)
		local st = sd.pos and sd.pos[s]
		if st then
			return st.x:peek(), st.y:peek()
		end
		local i = sd.init and sd.init[s]
		if i then
			return i[1], i[2]
		end
		return 0, 0
	end
	local function room_of(sd: any, s: number): (number, number)
		local pl = sd.place or place(sd.root)
		return Scroll.room(plan_of(sd), s, pl.vw, pl.vh)
	end
	local function set_pos(sd: any, s: number, x: number, y: number)
		local mx, my = room_of(sd, s)
		x, y = math.clamp(x, 0, mx), math.clamp(y, 0, my)
		local st = sd.pos and sd.pos[s]
		if st then
			if st.x:peek() ~= x then
				st.x:set(x)
			end
			if st.y:peek() ~= y then
				st.y:set(y)
			end
			if dev.cm then
				-- (step 7: comment pins on what scrolled move with it)
				dev.cm.moved()
			end
		else
			sd.init = sd.init or {}
			sd.init[s] = { x, y }
		end
		memory[Scroll.memory_key(plan_of(sd), s)] = { x, y }
	end
	-- Item i's offset as shown, for hit tests: (dx, dy, rank).
	local function shift_of(sd: any): (number) -> (number, number, number)
		local plan = plan_of(sd)
		local function pos(s: number): (number, number)
			return pos_of(sd, s)
		end
		return function(i: number): (number, number, number)
			return Scroll.shift(plan, i, pos)
		end
	end
	-- A glide in progress per slot and scroller: stopped by a new wheel,
	-- drag or press.
	local function stop_glides(sd: any?)
		if not sd or not sd.glides then
			return
		end
		for s, a in sd.glides do
			pcall(function()
				a:cancel()
			end)
			sd.glides[s] = nil
		end
	end
	-- Scroller `s` to (x, y) over `ms` with `ease` (an anime ease: a name or
	-- a function), on the frame clock; `done` when it lands (or is stopped).
	local function glide(sd: any, s: number, x: number, y: number, ms: number, ease: any, done: (() -> ())?)
		local x0, y0 = pos_of(sd, s)
		local mx, my = room_of(sd, s)
		x, y = math.clamp(x, 0, mx), math.clamp(y, 0, my)
		sd.glides = sd.glides or {}
		local was = sd.glides[s]
		if was then
			pcall(function()
				was:cancel()
			end)
			sd.glides[s] = nil
		end
		if ms <= 0 or (x == x0 and y == y0) then
			set_pos(sd, s, x, y)
			if done then
				done()
			end
			return
		end
		local t = { p = 0 }
		local a
		local function step()
			local k = t.p
			set_pos(sd, s, x0 + (x - x0) * k, y0 + (y - y0) * k)
		end
		local ok = pcall(function()
			a = anime.animate(t, {
				p = { 0, 1 },
				duration = ms,
				ease = ease,
				onUpdate = step,
				onComplete = function()
					t.p = 1
					step()
					if sd.glides and sd.glides[s] == a then
						sd.glides[s] = nil
					end
					if done then
						done()
					end
				end,
			})
		end)
		if ok and a then
			sd.glides[s] = a
		else
			set_pos(sd, s, x, y)
			if done then
				done()
			end
		end
	end
	-- A Screen about to show: its scrollers back where they were on a
	-- matching Screen (Figma's scroll memory), or at the top with `reset`.
	local function sync_scroll(key: string, reset: boolean?)
		local sd = slot_data[key]
		if not sd then
			return
		end
		stop_glides(sd)
		local plan = plan_of(sd)
		for _, s in plan.scrollers do
			local m = (not reset) and memory[Scroll.memory_key(plan, s)]
			set_pos(sd, s, if m then m[1] else 0, if m then m[2] else 0)
		end
	end
	-- A wheel or drag delta (Canvas units) at Canvas point (x, y) of the
	-- shown Screen: the innermost scroller that can still move takes it.
	local function scroll_by(sd: any, x: number, y: number, dx: number, dy: number, chain: { number }?)
		local plan = plan_of(sd)
		if not chain then
			local i = Proto.deepest(sd.root, x, y, shift_of(sd))
			chain = Scroll.chain(plan, if i > 0 then i else 1)
		end
		local moves = Scroll.route(chain :: { number }, dx, dy, function(s: number): (number, number)
			return pos_of(sd, s)
		end, function(s: number): (number, number)
			return room_of(sd, s)
		end)
		for s, p in moves do
			set_pos(sd, s, p[1], p[2])
		end
		return moves
	end

	local function add_slot(id: string, prefetch: boolean): string?
		local r = root_of(id)
		if not r then
			return nil
		end
		for _, s in slots:peek() do
			-- (a Change to's look mounted ahead isn't the Screen: step 4)
			local d = slot_data[s.key]
			if s.id == id and d and d.spare and not d.smart and not d.change_of then
				return s.key
			end
		end
		made += 1
		local key = `s{made}`
		slot_data[key] = { id = id, root = r, ver = 0, drivers = {}, spare = prefetch, mounted_at = ui.now() }
		set_z(key, if prefetch then -1 else 1)
		slots:push({ key = key, id = id })
		return key
	end

	local function drop_slot(key: string)
		local l = {}
		for _, s in slots:peek() do
			if s.key ~= key then
				table.insert(l, s)
			end
		end
		slot_data[key] = nil
		slots:set(l)
	end

	-- A slot's drivers back at rest.
	local function rest(key: string?)
		local sd = key and slot_data[key]
		if not sd then
			return
		end
		for _, st in sd.drivers do
			st.hover:set(false)
			st.press:set(false)
			st.scale:set(1)
		end
	end

	local function name_of(id: string): string
		local r = root_of(id)
		return if r then r.nodes[1].name or id else id
	end

	-- The navigate targets of the list of actions running (step 2).
	local pinned: { [string]: boolean } = {}
	-- (set below: a Screen's smart links get their bases mounted ahead)
	local prefetch_smart: ((sd: any) -> ())? = nil
	-- (set below, step 4: the Screens it links to get their remembered
	-- variants; Restart forgets them all)
	local prefetch_variants: ((sd: any, key: string) -> ())? = nil
	local forget_variants: (() -> ())? = nil
	local revert_variants: ((h: any, key: string) -> ())? = nil
	local ensure_hook: ((id: string, done: () -> ()) -> ())? = nil
	-- (set below, V3: a Change to on a bound Instance writes its variables;
	-- the looks one click on a variable action leads to, fetched ahead)
	local var_write_props: ((inst: any, act: any) -> ())? = nil
	local prefetch_vars: ((sd: any, key: string) -> ())? = nil
	-- (a navigate or Change to waits for a variable swap still drawing)
	local vsettle_hook: ((fn: () -> ()) -> boolean)? = nil
	-- A shown slot being swapped to a variable's new look: { patches = {
	-- slot keys }, next = the new look's slot, still drawing }
	local vveil: { [string]: any } = {}
	local var_reset_hook: ((look: boolean) -> ())? = nil

	-- The Screens the shown one links to, mounted ahead (and the rest let go).
	local function prefetch(key: string)
		local sd = slot_data[key]
		if not sd then
			return
		end
		local want: { [string]: boolean } = {}
		local n = 0
		local p = Proto.of_root(sd.root)
		-- (step 6 P6) the device pixels mounted: the shown Screen (twice: a
		-- re-place mounts a fresh copy under it), then each one ahead while
		-- they all fit zgx's raster cache (PlayPlace.fits)
		local used = 2 * PlayPlace.screen_px(sd.place or place(sd.root), dev.scale)
		for _, l in p.links do
			local go = l.a.go
			if go and go ~= "back" and not l.a.broken and go ~= sd.id and not want[go] and n < PREFETCH then
				local r = root_of(go)
				local px = if r then PlayPlace.screen_px(place(r), dev.scale) else 0
				if PlayPlace.fits(used, px) then
					want[go] = true
					n += 1
					used += px
				end
			end
		end
		dev.cap = { px = math.floor(used), scale = dev.scale, n = n + 1, measured = dev.scale_measured }
		local back = history[#history]
		if back and back.id ~= sd.id and not want[back.id] then
			want[back.id] = true
		end
		-- (the Screens a running list of actions goes on to stay mounted)
		for id in pinned do
			if id ~= sd.id and not want[id] then
				want[id] = true
			end
		end
		-- (spares no longer wanted go; one wanted and mounted stays)
		for _, s in slots:peek() do
			local d = slot_data[s.key]
			if s.key ~= key and d and d.change_of then
				-- (step 4: another Screen's Change to looks go; this one's stay)
				if d.change_of ~= key and d.spare then
					drop_slot(s.key)
				end
			elseif s.key ~= key and d and not d.smart and not d.keep then
				if d.spare and want[s.id] then
					want[s.id] = false
				elseif not want[s.id] then
					drop_slot(s.key)
				end
			end
		end
		for id, need in want do
			if need then
				add_slot(id, true)
			end
		end
		if prefetch_variants then
			prefetch_variants(sd, key)
		end
		if prefetch_smart then
			-- (a moment later: mounting two bases is a heavy Screen's raster
			-- twice, and it shouldn't land on a transition's last frame)
			local fn = prefetch_smart
			local function later()
				if current:peek() == key and slot_data[key] then
					-- (F4-int: not while a Change to's motion plays on)
					if busy or coast then
						ui.after(120, later)
						return
					end
					fn(sd)
				end
			end
			ui.after(120, later)
		end
	end

	-- (set below: a Screen shown starts its triggers' timers)
	local on_shown: ((key: string, scope: any?) -> ())? = nil
	-- (set below: leaving a Screen closes its overlays, over `ms`)
	local on_leave: ((ms: number?) -> ())? = nil
	-- (step 4) a slot shown by a Change to: only the timers inside the
	-- Instance that changed start (its new member's afterDelay)
	local show_scope: { [string]: any } = {}

	local function show(key: string)
		local sd = slot_data[key]
		local scope = show_scope[key]
		show_scope[key] = nil
		sd.spare = false
		sd.change_of = nil
		visited[sd.id] = true
		current:set(key)
		set_z(key, 1)
		local spl = place(sd.root)
		set_vp(frame_of(spl))
		dev.set(spl)
		title:set(name_of(sd.id))
		if props.on_shown then
			-- (step 6 P4: the Preview tells the shell, which follows it on the canvas)
			props.on_shown(sd.id, (sess:peek() or {}).follow == true)
		end
		local el = sd.el
		if el then
			anime.utils.set(el, { x = 0, y = 0, opacity = 1 })
		end
		prefetch(key)
		if on_shown then
			on_shown(key, scope)
		end
	end

	-- ── Smart Animate (step 3, figma-parity.md §3.1; tab/smart.luau) ────────
	-- Over a smart transition the two Screens are shown by their **bases**
	-- (slots like any Screen's, each drawn once with the movers left out),
	-- which dissolve (or push/slide, with "Smart animate matching layers");
	-- each **mover** is its own small canvas element over them, moved,
	-- scaled and faded on the compositor, or (a plate whose colour, radius
	-- or size changes) redrawn each frame. The Screens' own canvases aren't
	-- touched. Bases for the shown Screen's smart links are mounted ahead.
	-- One progress value drives it all, so a drag can scrub it.
	local smart_bases: { [string]: any } = {} -- "src>dst" → { src, dst, plan, rs, rd }
	local function is_smart(tr: any?): boolean
		return tr ~= nil and (tr.k == "smart" or tr.ml == true)
	end
	-- `patch` (a Change to, F4-perf): the base is drawn only inside that
	-- rect (Canvas units), over the Screen still shown (see `change_patch`).
	local function add_base(id: string, r: any, nodes: { any }, patch: any?, ov: any?): string
		if ov then
			-- (L1: a smart Change to or Swap on an overlay: its bases are overlay
			-- slots where it shows, over the overlays open (`ov_order`), no backdrop)
			made += 1
			local key = `o{made}`
			slot_data[key] = {
				id = id,
				root = { id = r.id, v = r.v, nodes = nodes },
				ver = 0,
				drivers = {},
				spare = true,
				smart = true,
				mounted_at = ui.now(),
				ov = { pos = ov.pos, ox = ov.ox, oy = ov.oy, tx = ov.tx, ty = ov.ty, gen = 0 },
			}
			ovs:push({ key = key, id = id })
			return key
		end
		made += 1
		local key = `s{made}`
		slot_data[key] = { id = id, root = { id = r.id, v = r.v, nodes = nodes }, ver = 0, drivers = {}, spare = true, smart = true, mounted_at = ui.now(), patch = patch }
		set_z(key, -1)
		slots:push({ key = key, id = id })
		return key
	end
	-- (F4-perf) What a Change to changes on its Screen: the rect (Canvas
	-- units) holding every item that differs between the two looks, each
	-- with what's inside and its shadow, or nil when the change can't be
	-- shown as a patch over the Screen (its box or layers change, it has no
	-- opaque fill under the patch, or the change covers most of it).
	-- Measured on the demo's Settings: the old route mounted every one-step
	-- look and its two bases ahead, 15 Screen-sized canvases after each
	-- toggle (60 + 95 ms frames); a patch is one small raster at the click.
	local PATCH_MAX = 0.6
	-- (not paint: reactions, states, the stored node, and `n`, which grows on
	-- every ancestor of a layer one look adds, as a ticked box's tick)
	local VISUAL_SKIP = { ia = true, st = true, sttr = true, src = true, n = true }
	local function same_item(a: any, b: any): boolean
		for k, v in a do
			if not VISUAL_SKIP[k] and not Smart.eq(v, b[k]) then
				return false
			end
		end
		for k in b do
			if not VISUAL_SKIP[k] and a[k] == nil then
				return false
			end
		end
		return true
	end
	-- (F4-int) Two roots that draw the same (a look fetched again)
	local function same_look(a: any?, b: any?): boolean
		if a == b then
			return true
		end
		if not a or not b or #a.nodes ~= #b.nodes then
			return false
		end
		for i, it in a.nodes do
			local o = b.nodes[i]
			if it.id ~= o.id or not same_item(it, o) then
				return false
			end
		end
		return true
	end
	local patch_memo: { [any]: { [any]: any } } = setmetatable({}, { __mode = "k" }) :: any
	local find_patch: (rs: any, rd: any) -> any?
	local cull_outside: (root: any, R: any) -> any
	local function change_patch(rs: any, rd: any): any?
		local by = patch_memo[rs]
		if not by then
			by = setmetatable({}, { __mode = "k" }) :: any
			patch_memo[rs] = by
		end
		local got = by[rd]
		if got == nil then
			got = find_patch(rs, rd) or false
			by[rd] = got
		end
		return got or nil
	end
	find_patch = function(rs: any, rd: any): any?
		local s, d = rs.nodes, rd.nodes
		local b = s[1].box
		if not Smart.eq(b, d[1].box) or not same_item(s[1], d[1]) then
			return nil
		end
		-- (the Screen alone is its own layer: no scrollers inside, nothing fixed)
		if #Scroll.plan(rs, Proto.of_root(rs).drivers).layers ~= 1 or #Scroll.plan(rd, Proto.of_root(rd).drivers).layers ~= 1 then
			return nil
		end
		-- (the patch is opaque only where the Screen paints: a solid fill)
		local f = s[1].fill and s[1].fill[1]
		if not f or f.k ~= "solid" or type(f.color) ~= "string" or (#f.color == 9 and string.sub(f.color, 8, 9) ~= "FF" and string.sub(f.color, 8, 9) ~= "ff") or (s[1].op and s[1].op < 1) then
			return nil
		end
		local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
		local function add(root: any, i: number)
			local it = root.nodes[i]
			if it.hidden then
				return
			end
			local e = Proto.extent(root, { i = i, n = it.n or 0, entries = {} })
			x0, y0 = math.min(x0, e[1]), math.min(y0, e[2])
			x1, y1 = math.max(x1, e[1] + e[3]), math.max(y1, e[2] + e[4])
		end
		local at: { [string]: number } = {}
		for j, it in d do
			at[it.id] = j
		end
		local seen: { [string]: boolean } = {}
		for i = 2, #s do
			local it = s[i]
			seen[it.id] = true
			local j = at[it.id]
			if not j then
				add(rs, i)
			elseif not same_item(it, d[j]) then
				add(rs, i)
				add(rd, j)
			end
		end
		for j = 2, #d do
			if not seen[d[j].id] then
				add(rd, j)
			end
		end
		if x0 >= x1 or y0 >= y1 then
			return nil
		end
		x0, y0 = math.max(x0, b.x), math.max(y0, b.y)
		x1, y1 = math.min(x1, b.x + b.w), math.min(y1, b.y + b.h)
		if x0 >= x1 or y0 >= y1 or (x1 - x0) * (y1 - y0) > PATCH_MAX * b.w * b.h then
			return nil
		end
		return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
	end
	-- (V3) `root` with every branch that can't paint inside rect `R`
	-- (Canvas units) left out (`hidden`, which the drawing skips whole): a
	-- patch's canvas then walks only what it shows. Bounds per branch, in one
	-- pass from the end; shadows get a wide margin.
	cull_outside = function(root: any, R: any): any
		local nodes = root.nodes
		local ext: { { number } } = {}
		for i = #nodes, 1, -1 do
			local it = nodes[i]
			local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
			local pad = if it.fx then 64 else 4
			local e = { x - pad, y - pad, x + w + pad, y + h + pad }
			local last = i + (it.n or 0)
			if not it.clip then
				local j = i + 1
				while j <= last and j <= #nodes do
					local c = ext[j]
					if c then
						e[1], e[2] = math.min(e[1], c[1]), math.min(e[2], c[2])
						e[3], e[4] = math.max(e[3], c[3]), math.max(e[4], c[4])
					end
					j += (nodes[j].n or 0) + 1
				end
			end
			ext[i] = e
		end
		local out = table.clone(nodes)
		local i = 2
		while i <= #nodes do
			local e = ext[i]
			local it = nodes[i]
			if e[3] < R.x or e[1] > R.x + R.w or e[4] < R.y or e[2] > R.y + R.h then
				local h = table.clone(it)
				h.hidden = true
				out[i] = h
				i += (it.n or 0) + 1
			else
				i += 1
			end
		end
		return { id = root.id, v = root.v, nodes = out }
	end
	local function same_sets(a: any, b: any): boolean
		for _, k in { "src_hide", "dst_hide", "src_strip", "dst_strip" } do
			if not Smart.eq(a[k], b[k]) then
				return false
			end
		end
		return true
	end
	local function drop_bases(k: string)
		local got = smart_bases[k]
		if got then
			smart_bases[k] = nil
			for _, bk in { got.src, got.dst } do
				local d = slot_data[bk]
				if d and d.ov then
					drop_ov(bk)
				else
					drop_slot(bk)
				end
			end
		end
	end
	-- The bases of src → dst, mounted (or made again when `plan`, the one
	-- about to play with the Screens' scroll, leaves out other layers).
	local function bases_for(src_id: string, dst_id: string, plan: any?, rs0: any?, rd0: any?, patch: any?, ov: any?): any?
		-- (step 4: a Change to plays between two looks of one Screen, its roots given)
		local rs, rd = rs0 or root_of(src_id), rd0 or root_of(dst_id)
		local k = src_id .. ">" .. dst_id .. (if src_id == dst_id then "#" .. tostring(rd) else "")
		if ov then
			-- (an overlay's: its own, never a Screen's; "#" keeps prefetch_smart off it)
			k = "ov#" .. k .. "#" .. tostring(rs)
		end
		if not rs or not rd then
			return nil
		end
		local got = smart_bases[k]
		if got and got.rs == rs and got.rd == rd and slot_data[got.src] and slot_data[got.dst] and (not plan or same_sets(plan, got.plan)) and Smart.eq(got.patch, patch) then
			return got
		end
		drop_bases(k)
		local p = plan or Smart.plan(rs.nodes, rd.nodes)
		got = {
			k = k,
			rs = rs,
			rd = rd,
			plan = p,
			patch = patch,
			src = add_base(src_id, rs, Smart.base(rs.nodes, p.src_hide, p.src_strip), patch, ov),
			dst = add_base(dst_id, rd, Smart.base(rd.nodes, p.dst_hide, p.dst_strip), patch, ov),
		}
		smart_bases[k] = got
		return got
	end
	prefetch_smart = function(sd: any)
		local want: { [string]: boolean } = {}
		local n = 0
		local function wish(to: string?)
			if to and to ~= sd.id and root_of(to) and n < 3 and not want[sd.id .. ">" .. to] then
				want[sd.id .. ">" .. to] = true
				n += 1
				bases_for(sd.id, to)
			end
		end
		for _, l in Proto.of_root(sd.root).links do
			for _, act in l.a.acts or { { k = "navigate", go = l.a.go, tr = l.a.tr } } do
				if act.k == "navigate" and not act.broken and is_smart(act.tr) then
					wish(act.go)
				end
			end
		end
		-- (and the way back, when it came in by smart animate)
		local back = history[#history]
		if back and is_smart(back.tr) then
			wish(back.id)
		end
		for k in smart_bases do
			-- (a Change to's bases, "id>id#…", are its own: step 4)
			if not want[k] and not string.find(k, "#", 1, true) then
				drop_bases(k)
			end
		end
	end

	-- The movers on show: { n, kind, canvases = { { root, view, w, h, origin, box, pad, el? } } }.
	local movers = ui.use_state({} :: { any })
	local smart_run: any = nil -- the smart transition playing: { apply, land, … }
	local smart_gen = 0
	local mover_specs: { [string]: any } = {}

	-- (F4-int) Drives a smart run's progress from p0 to p1 with its
	-- transition's spring, starting at velocity v0 (1/s, of the way p0 → p1),
	-- or its curve over `ms`. `run.vel()`: dp/dt (1/s) as it is now, which a
	-- motion taking it over carries on.
	local function drive(run: any, p0: number, p1: number, v0: number?, ms: number?)
		run.gen = (run.gen or 0) + 1
		local g = run.gen
		run.dead = false
		run.p = p0
		local tr = run.tr
		local sp = tr.sp
		local span = p1 - p0
		local x: ((number) -> number)? = nil
		local T: number
		if type(sp) == "table" then
			local f, settle = Proto.spring({ mass = sp.m or 1, stiffness = sp.k or 100, damping = sp.c or 10, velocity = if v0 ~= nil then v0 else (sp.v or 0) })
			x = f
			-- (as it was: a fresh one plays over the transition's own settle time)
			T = if v0 == nil and tr.ms then math.max(1, tr.ms) else math.max(16, settle * 1000)
		else
			T = math.max(1, ms or tr.ms or 300)
		end
		local t = { u = 0 }
		local last_t, last_p, last_v = ui.now(), p0, 0
		local function at(u: number): number
			if x then
				return p0 + span * x(u * T / 1000)
			end
			return p0 + span * u
		end
		run.vel = function(): number
			if x then
				local s = t.u * T / 1000
				local h = 0.004
				local a = math.max(0, s - h)
				return span * (x(s + h) - x(a)) / (s + h - a)
			end
			return last_v
		end
		local function done()
			run.p = p1
			run.apply(p1)
			if run.coasting then
				run.coast_end()
			else
				run.land(true)
			end
		end
		local ok = pcall(function()
			anime.animate(t, {
				u = { 0, 1 },
				duration = T,
				ease = if x then "linear" else Proto.ease(tr.ease),
				onUpdate = function()
					if run.dead or run.gen ~= g then
						return
					end
					local p = at(t.u)
					local now = ui.now()
					if now > last_t then
						last_v = (p - last_p) / ((now - last_t) / 1000)
						last_t, last_p = now, p
					end
					run.p = p
					run.apply(p)
				end,
				onComplete = function()
					if run.dead or run.gen ~= g then
						return
					end
					done()
				end,
			})
		end)
		if not ok then
			done()
		end
	end

	-- Plays a smart transition from slot `from` to slot `key` (both mounted).
	-- `mo`: how the bases move (dissolve, or a push/slide's); `box`: the
	-- viewport it plays in. `scrub`: driven by a drag (see `drag_smart`)
	-- rather than by time. Returns false when it can't (then it plays as
	-- `mo` alone).
	-- `opts` (F4-int): { src = the look it starts from (a snapshot of a
	-- Change to let go of, `coast`), coast = that run (its elements go when
	-- this one starts) }.
	local function smart_transition(from: string, key: string, tr: any, mo: any, box: any, finish: () -> (), scrub: any?, opts: any?): boolean
		local from_d, sd = slot_data[from], slot_data[key]
		if not from_d or not sd or not from_d.el then
			return false
		end
		local rs0 = if opts and opts.src then opts.src else from_d.root
		local pl_s, pl_d = from_d.place or place(from_d.root), sd.place or place(sd.root)
		local z = pl_d.z
		-- Where each item shows, in Canvas units from the viewport's top-left
		-- (scrolled as it is now)
		local function off(slot: any, pl: any): (number) -> (number, number)
			local sp = plan_of(slot)
			local rb = slot.root.nodes[1].box
			return function(i: number): (number, number)
				local dx, dy = Scroll.shift(sp, i, function(s: number): (number, number)
					return pos_of(slot, s)
				end)
				return dx - rb.x + (pl.left - box.left) / z, dy - rb.y + (pl.top - box.top) / z
			end
		end
		local t0 = os.clock()
		local od = off(sd, pl_d)
		local plan = Smart.plan(rs0.nodes, sd.root.nodes, { so = off(from_d, pl_s), sd = od })
		-- (F4-perf: a Change to whose change stays in a part of its Screen
		-- plays over the Screen shown, its bases only that part)
		-- (L1: `opts.ov`, two overlay slots, a Change to inside an overlay or a
		-- Swap: bases are overlay slots, movers over the overlays, no patch)
		local ov = opts and opts.ov
		local patch = if not ov and from_d.id == sd.id and mo.top == "to" and mo.from.b.opacity == 1 and mo.from.b.x == 0 and mo.from.b.y == 0 then change_patch(rs0, sd.root) else nil
		local bs = bases_for(from_d.id, sd.id, plan, rs0, sd.root, patch, ov)
		if not bs then
			return false
		end
		local sb, db = slot_data[bs.src], slot_data[bs.dst]
		-- (the bases scrolled as their Screens are)
		for _, s in plan_of(from_d).scrollers do
			local x, y = pos_of(from_d, s)
			set_pos(sb, s, x, y)
		end
		for _, s in plan_of(sd).scrollers do
			local x, y = pos_of(sd, s)
			set_pos(db, s, x, y)
		end
		-- The movers' canvases.
		smart_gen += 1
		local specs = {}
		local src_n, dst_n = rs0.nodes, sd.root.nodes
		for _, mv in plan.movers do
			local spec: any = { n = mv.n, key = `mv{smart_gen}-{mv.n}`, kind = mv.kind, mv = mv, canvases = {}, z = z }
			local function piece(nodes: { any }, i: number, own: boolean)
				local b = nodes[i].box
				local pad = mv.pad
				local vb = { x = b.x - pad, y = b.y - pad, w = b.w + 2 * pad, h = b.h + 2 * pad }
				local it = nodes[i]
				-- (the largest it's shown at: a raster scaled up past ~1.1× goes
				-- soft, so it's drawn that much finer and scaled down instead)
				local smax = 1
				for _, r in { mv.a, mv.b } do
					local s = 1
					if mv.kind == "xfade" then
						s = Smart.fit(b, r, it.text)
					elseif mv.kind == "group" then
						s = if b.w > 0 then r.w / b.w elseif b.h > 0 then r.h / b.h else 1
					end
					smax = math.max(smax, s)
				end
				local k = if smax > 1.1 then math.min(smax, 3) else 1
				table.insert(spec.canvases, {
					root = { id = `mv{mv.n}`, nodes = Smart.sub(nodes, i, own) },
					-- (view: where Canvas (0, 0) lands in the element)
					view = { x = -vb.x * z * k, y = -vb.y * z * k, zoom = z * k },
					w = vb.w * z * k,
					h = vb.h * z * k,
					k = k,
					origin = { pad / math.max(1e-6, vb.w), pad / math.max(1e-6, vb.h) },
					box = b,
					pad = pad,
					text = it.text,
				})
			end
			if mv.kind == "group" then
				piece(dst_n, mv.di, mv.own)
			elseif mv.kind == "fade" then
				if mv.side == "src" then
					piece(src_n, mv.si, false)
				else
					piece(dst_n, mv.di, false)
				end
			elseif mv.kind == "xfade" then
				piece(src_n, mv.si, mv.own)
				piece(dst_n, mv.di, mv.own)
			else
				-- (redraw: a still canvas over everywhere it goes, a spring's
				-- overshoot too, drawn at each frame's look)
				local a, b = mv.a, mv.b
				local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
				local x1, y1 = math.max(a.x + a.w, b.x + b.w), math.max(a.y + a.h, b.y + b.h)
				-- (a spring overshoots: room for it; a curve stays inside)
				local m = mv.pad + (if tr.sp then 0.12 * math.max(x1 - x0, y1 - y0) else 2)
				local U = { x = x0 - m, y = y0 - m, w = x1 - x0 + 2 * m, h = y1 - y0 + 2 * m }
				spec.U = U
				-- (a big plate redraws at a lower resolution, scaled up: its
				-- raster each frame stays small; the end frame is the Screen's own)
				-- (a blurred shadow is most of a redraw's cost (measured: the
				-- demo's card 18 → 6.6 ms a frame without it), and it's soft
				-- anyway: a plate with one redraws coarser still)
				local area = U.w * U.h * z * z
				local res = if area > 90000 then math.max(0.35, math.sqrt(90000 / area)) else 1
				spec.res = res
				-- (a drop shadow isn't blurred again each frame, the cost of a
				-- redraw (measured: the demo's card 18 → 6.6 ms a frame without
				-- it): as Figma does, the two shadows dissolve, each drawn once
				-- and stretched with the plate (element scaleX / scaleY))
				local function shadows(it: any): { any }?
					local l = {}
					for _, e in it.fx or {} do
						if e.k == "shadow" and not e.inner then
							table.insert(l, e)
						end
					end
					return if #l > 0 then l else nil
				end
				-- (not stretched: zgx rasters a scaled layer again in √2 steps,
				-- a blur each time (measured: 20–35 ms frames); each keeps its
				-- size, follows the plate's centre and dissolves. Figma keeps
				-- one shadow on the plate as it grows (filmed, pure/anim/
				-- f3-figma); redrawing it each frame on a coarse canvas of its
				-- own was measured at +10 ms a frame on the card (24.6 vs 14.7
				-- median): a raster a frame costs that much whatever its size)
				for side, it in { src_n[mv.si], dst_n[mv.di] } do
					local sh = shadows(it)
					if sh then
						spec.split_fx = true
						local c = table.clone(it)
						c.fill, c.stroke, c.text, c.icon, c.fx, c.xf, c.rot = nil, nil, nil, nil, sh, nil, nil
						c.p, c.d, c.n, c.op, c.ia, c.st, c.sttr, c.src = nil, 0, 0, nil, nil, nil, nil, nil
						local b, pad = c.box, mv.pad
						local vb = { x = b.x - pad, y = b.y - pad, w = b.w + 2 * pad, h = b.h + 2 * pad }
						table.insert(spec.canvases, {
							shadow = side,
							root = { id = `mv{mv.n}s{side}`, nodes = { c } },
							view = { x = -vb.x * z, y = -vb.y * z, zoom = z },
							w = vb.w * z,
							h = vb.h * z,
							origin = { pad / math.max(1e-6, vb.w), pad / math.max(1e-6, vb.h) },
							box = b,
							pad = pad,
						})
					end
				end
				table.insert(spec.canvases, {
					redraw = true,
					res = res,
					view = { x = -U.x * z * res, y = -U.y * z * res, zoom = z * res },
					w = U.w * z * res,
					h = U.h * z * res,
					origin = { 0, 0 },
					si = mv.si,
					di = mv.di,
				})
			end
			table.insert(specs, spec)
		end
		-- One progress value → every element.
		local function apply(p: number)
			local q = math.clamp(p, 0, 1)
			local function base_at(el: any, ends: any)
				if el then
					anime.utils.set(el, {
						x = ends.a.x + (ends.b.x - ends.a.x) * p,
						y = ends.a.y + (ends.b.y - ends.a.y) * p,
						opacity = ends.a.opacity + (ends.b.opacity - ends.a.opacity) * q,
					})
				end
			end
			base_at(sb.el, mo.from)
			base_at(db.el, mo.to)
			for _, spec in specs do
				local r, op = Smart.at(spec.mv, p)
				local cl = spec.mv.clip
				if cl and spec.clip_el and spec.inner_el then
					local cx, cy = cl.a.x + (cl.b.x - cl.a.x) * p, cl.a.y + (cl.b.y - cl.a.y) * p
					anime.utils.set(spec.clip_el, { x = cx * z, y = cy * z })
					anime.utils.set(spec.inner_el, { x = -cx * z, y = -cy * z })
				end
				if spec.kind == "redraw" then
					spec.p = p
					spec.op = op
					if spec.prog then
						spec.prog:set(p)
					end
					for _, cv in spec.canvases do
						if not cv.el then
							continue
						elseif cv.redraw then
							anime.utils.set(cv.el, { x = spec.U.x * z, y = spec.U.y * z, scale = 1 / (cv.res or spec.res or 1), opacity = 1 })
						else
							-- a shadow on the plate's centre; the old one out, the new one in
							local b = cv.box
							local out = if cv.shadow == 1 then (1 - q) * (1 - q) else q * q
							anime.utils.set(cv.el, {
								x = (r.x + (r.w - b.w) / 2 - cv.pad) * z,
								y = (r.y + (r.h - b.h) / 2 - cv.pad) * z,
								opacity = math.clamp(op * out * Smart.shadow_fit(b, r, cv.pad), 0, 1),
							})
						end
					end
					continue
				end
				for ci, cv in spec.canvases do
					if not cv.el then
						continue
					end
					local b = cv.box
					local s, x, y = 1, r.x, r.y
					local o = op
					if spec.kind == "xfade" then
						o = if ci == 1 then op * (1 - q) else op * q
						-- (both looks scaled to the box, text by its height: Figma's)
						s, x, y = Smart.fit(b, r, cv.text)
					else
						s = if b.w > 0 then r.w / b.w elseif b.h > 0 then r.h / b.h else 1
					end
					local k = cv.k or 1
					anime.utils.set(cv.el, { x = (x - cv.pad * k) * z, y = (y - cv.pad * k) * z, scale = s / k, opacity = math.clamp(o, 0, 1) })
				end
			end
		end
		local run: any = {
			apply = apply, plan = plan, specs = specs, p = 0, p1 = 1, src_nodes = src_n, dst_nodes = dst_n, change = from_d.id == sd.id and not ov, patch = patch,
			from = from, key = key, tr = tr, finish = finish, od = od, mo = mo, keys = {}, ov = ov ~= nil,
			ends = { [0] = rs0, [1] = sd.root },
			bkey = bs.k,
			interrupted = if opts and opts.coast then "snapshot" else nil,
			from_p = if opts and opts.coast then opts.coast.p else nil,
		}
		smart_run = run
		busy = true
		-- (the state holds keys only: what the elements write stays here; a
		-- Change to let go of keeps its own until this one starts)
		local mstate = if ov then ov_movers else movers
		local keys = table.clone(mstate:peek())
		for _, spec in specs do
			spec.run = run
			mover_specs[spec.key] = spec
			run.keys[spec.key] = true
			table.insert(keys, { key = spec.key })
		end
		mstate:set(keys)
		-- Before it starts: the bases ready and every mover drawn once.
		local function ready(): boolean
			if not (sb.el and sb.ready and db.el and db.ready) then
				return false
			end
			for _, spec in specs do
				for _, cv in spec.canvases do
					if not cv.el then
						return false
					end
				end
			end
			return true
		end
		-- (its elements go: movers and bases)
		run.cleanup = function()
			if run.clean then
				return
			end
			run.clean = true
			local l = {}
			for _, m in mstate:peek() do
				if not run.keys[m.key] then
					table.insert(l, m)
				end
			end
			mstate:set(l)
			for k in run.keys do
				mover_specs[k] = nil
			end
			if smart_run == run then
				smart_run = nil
			end
			if coast == run then
				coast = nil
			end
			drop_bases(run.bkey)
		end
		local function record()
			table.insert(perf.transitions, {
				k = run.tr.k, ml = run.tr.ml, ms = run.tr.ms, waited = run.waited, prefetched = slot_data[run.key] ~= nil and slot_data[run.key].ready == true, movers = #specs,
				redraws = plan.redraws, plan_ms = run.plan_ms, patch = patch ~= nil, interrupted = run.interrupted, from_p = run.from_p,
			})
		end
		-- Ends at p1 (shows `run.key`) or, when a scrub lets go short, back at
		-- p = 0 (the Screen it came from shows again).
		run.land = function(to_end: boolean)
			if run.landed then
				return
			end
			local nd = slot_data[run.key]
			-- (a patch: the Screen's new look, mounted under it at the click,
			-- takes over once drawn; until then the end frame holds)
			if to_end and nd and nd.mount then
				nd.mount()
			end
			if to_end and patch and nd and not nd.ready and not run.now and (run.held or 0) < 30 then
				run.held = (run.held or 0) + 1
				ui.after(16, function()
					run.land(true)
				end)
				return
			end
			run.landed = true
			run.dead = true
			busy = false
			if to_end and ov then
				-- (an overlay's: the caller's finish shows the new slot, parks the old)
				record()
				run.cleanup()
				run.finish()
			elseif to_end then
				record()
				if run.from and slot_data[run.from] then
					drop_slot(run.from)
				end
				if nd then
					show(run.key)
				end
				run.cleanup()
				run.finish()
			else
				anime.utils.set(from_d.el, { x = 0, y = 0, opacity = 1 })
				sd.spare = true
				if sd.el then
					anime.utils.set(sd.el, { x = 0, y = 0, opacity = 0.002 })
				end
				set_z(key, -1)
				set_z(from, 1)
				run.cleanup()
				if scrub and scrub.cancelled then
					scrub.cancelled()
				end
			end
		end
		-- (F4-perf) A Change to playing by time ends at once when asked
		-- (another kind of action comes, as a navigate).
		run.finish_now = function(): boolean
			if not run.change or not run.started or run.scrub or run.landed then
				return false
			end
			run.now = true
			run.dead = true
			apply(run.p1)
			run.land(true)
			return true
		end
		-- (F4-int) A click while a Change to plays: the Screen shows its new
		-- look from now on (state, hit tests, the next Change to), while the
		-- motion plays on over it (`coast`) until it ends or a Change to on
		-- that look takes it over from where it is. False while the new look
		-- isn't drawn yet (a patch's, mounted a few frames in): the click waits.
		run.let_go = function(): boolean
			if not run.change or not run.started or run.scrub or run.landed or run.coasting then
				return false
			end
			local nd = slot_data[run.key]
			if not nd then
				return false
			end
			if nd.mount then
				nd.mount()
			end
			if not nd.el then
				return false
			end
			run.coasting = true
			run.landed = true
			busy = false
			if smart_run == run then
				smart_run = nil
			end
			coast = run
			record()
			local old = run.from
			run.from = nil
			if old and slot_data[old] then
				if patch and not nd.ready then
					-- (a patch: the old look stays under the new one, outside the
					-- patch the same, until that's drawn)
					local od = slot_data[old]
					od.keep = true
					local bkey = run.key
					local tries = 0
					local function later()
						tries += 1
						if slot_data[old] ~= od then
							return
						end
						-- (drawn, or itself gone: what took over is drawn by then)
						if nd.ready or slot_data[bkey] ~= nd or tries > 60 then
							drop_slot(old)
						else
							ui.after(16, later)
						end
					end
					ui.after(16, later)
				else
					drop_slot(old)
				end
			end
			show(run.key)
			-- (under the motion still playing: a patch's bases cover their rect;
			-- whole bases cover the Screen, which stays out of sight till the end)
			if patch then
				set_z(run.key, 0)
			elseif nd.el then
				anime.utils.set(nd.el, { opacity = 0 })
			end
			run.finish()
			return true
		end
		-- (the motion let go of ends: its elements go, the look shown stays)
		run.coast_end = function()
			if run.clean then
				return
			end
			run.dead = true
			local k = current:peek()
			local nd = k and slot_data[k]
			if nd and k == run.key then
				set_z(k, 1)
				if nd.el then
					anime.utils.set(nd.el, { x = 0, y = 0, opacity = 1 })
				end
			end
			run.cleanup()
		end
		local function start()
			run.waited = (os.clock() - t0) * 1000
			run.started = true
			run.scrub = scrub ~= nil
			sd.spare = false
			set_z(bs.src, 1)
			set_z(bs.dst, if mo.top == "to" then 2 else 0)
			do
				-- (the base on top goes last among the slots: they draw in order)
				local top = if mo.top == "to" then bs.dst else bs.src
				local l, it = {}, nil
				for _, s0 in slots:peek() do
					if s0.key == top then
						it = s0
					else
						table.insert(l, s0)
					end
				end
				if it then
					table.insert(l, it)
					slots:set(l)
				end
			end
			set_vp(box)
			apply(0)
			-- (F4-int: the motion this one took over goes, on the same frame)
			if opts and opts.coast then
				opts.coast.coast_end()
				if not patch then
					anime.utils.set(from_d.el, { opacity = 0 })
				end
			end
			if patch then
				-- (a patch: the Screen shown stays, under its bases; the new
				-- look under it all draws meanwhile, as a spare does, mounted
				-- a few frames in, after the movers' first rasters)
				set_z(from, 0)
				if sd.mount then
					ui.after(50, function()
						if sd.mount and not run.landed then
							sd.mount()
						end
					end)
				end
			else
				-- (the Screens themselves step aside: the bases and movers show them)
				anime.utils.set(from_d.el, { opacity = 0 })
				if sd.el then
					anime.utils.set(sd.el, { opacity = 0 })
				end
			end
			if scrub then
				scrub.ready(run)
				return
			end
			drive(run, 0, 1, if opts then opts.v0 else nil)
		end
		run.plan_ms = (os.clock() - t0) * 1000
		if opts and opts.coast and opts.v0 == nil then
			-- (it carries on as the motion it takes over moved)
			opts.v0 = Smart.carry(opts.coast.plan, plan, opts.coast.dst_nodes, src_n, opts.pv or 0)
		end
		local tries = 0
		local function when_ready()
			tries += 1
			if ready() or tries > 40 then
				-- (one more frame: the movers' first raster lands. Measured: it
				-- doesn't, as a layer that shows ~nothing isn't rastered until it
				-- shows (mounted at 0.2%, or primed at its start scale: the
				-- card's first moving frame still has 7 rasters); that needs zgx
				-- to raster a layer ahead of showing it)
				ui.after(16, start)
			else
				ui.after(16, when_ready)
			end
		end
		when_ready()
		return true
	end

	-- One mover over the bases: each canvas in its own element (moved,
	-- scaled and faded by `apply`); a redraw canvas draws its frame's look.
	local function Mover(o: any): Node
		local spec = mover_specs[o.key]
		if not spec then
			return ui.div {}
		end
		local prog = ui.use_state(0)
		spec.prog = prog
		local kids: any = { absolute = true, left = 0, top = 0, w = 1, h = 1, pointer_events = "none" }
		for ci, cv in spec.canvases do
			local canvas = ui.canvas {
				id = `play-mv-{spec.n}-{ci}`,
				absolute = true,
				left = 0,
				top = 0,
				w = cv.w,
				h = cv.h,
				pointer_events = "none",
				view = function(): any
					return cv.view
				end,
				draw = function(c: Canvas)
					if cv.redraw then
						local p = prog:get()
						local run = spec.run
						local mv = spec.mv
						if not run then
							return
						end
						local r, op = Smart.at(mv, p)
						local a = run.src_nodes[mv.si]
						local b = run.dst_nodes[mv.di]
						local it = Smart.tween_item(a, b, r, p, op)
						if spec.split_fx and it.fx then
							-- (its drop shadows are their own pieces)
							local keep = {}
							for _, e in it.fx do
								if not (e.k == "shadow" and not e.inner) then
									table.insert(keep, e)
								end
							end
							it.fx = if #keep > 0 then keep else nil
						end
						Draw.draw_root(c, { id = `mv{spec.n}`, nodes = { it } })
						return
					end
					Draw.draw_root(c, cv.root)
				end,
			}
			table.insert(
				kids,
				ui.div {
					absolute = true,
					left = 0,
					top = 0,
					w = cv.w,
					h = cv.h,
					origin = cv.origin,
					opacity = 0,
					pointer_events = "none",
					on_mount = function(el: any)
						cv.el = el
					end,
					canvas,
				}
			)
		end
		local cl = spec.mv.clip
		if cl and not cl.resizes then
			-- (cut by the parent that clips it: a window the size of that parent,
			-- moved with it; the canvases inside stay in viewport units)
			local z0 = spec.z or 1
			kids.on_mount = function(el: any)
				spec.inner_el = el
			end
			return ui.div {
				absolute = true,
				left = 0,
				top = 0,
				w = cl.a.w * z0,
				h = cl.a.h * z0,
				overflow = "hidden",
				pointer_events = "none",
				on_mount = function(el: any)
					spec.clip_el = el
				end,
				ui.div(kids),
			}
		end
		return ui.div(kids)
	end

	-- Go to Screen `id` with `tr` (nil: instant); `back`: no history kept.
	-- `done` runs once the Screen shows (the next action of a list waits).
	-- `opts`: { reset = true } (the navigate's resetScroll; F2a).
	local function go_to(id: string, tr: any?, is_back: boolean, done: (() -> ())?, opts: any?)
		local function finish()
			if done then
				done()
			end
		end
		-- (V3: from the look a variable change is bringing in, once drawn)
		if vsettle_hook and vsettle_hook(function()
			go_to(id, tr, is_back, done, opts)
		end) then
			return
		end
		if coast then
			-- (F4-int: a Change to's motion still playing ends at once)
			coast.coast_end()
		end
		local from = current:peek()
		local from_d = from and slot_data[from]
		if from_d and from_d.id == id then
			finish()
			return
		end
		-- (a Screen not mounted ahead mounts as a spare does, all but
		-- invisible, and the transition waits until it's ready: a slot mounted
		-- and animated at once showed whole and never animated, zgx 1890c0555)
		local key = add_slot(id, from_d ~= nil and from_d.el ~= nil)
		if not key then
			say(`play: no Screen {id}`)
			finish()
			return
		end
		if from_d and not is_back then
			table.insert(history, { id = from_d.id, tr = tr })
			-- (step 6 P1: a link followed forgets the way forward; → keeps it)
			if not (opts and opts.fwd) then
				table.clear(forward)
			end
		end
		rest(from)
		hovered, pressed = nil, nil
		if on_leave then
			on_leave(if tr and tr.k ~= "instant" then tr.ms else nil)
		end
		local sd = slot_data[key]
		sync_scroll(key, opts and opts.reset)
		-- (it stays a spare until its transition starts, or `show`)
		-- Both Screens' frames (one size, mostly): the viewport while it plays,
		-- and how far a side is.
		local box = union(frame_of(place(from_d and from_d.root or sd.root)), frame_of(place(sd.root)))
		local mo = Proto.motion(tr, box.w, box.h)
		if tr and tr.k == "push" and not mo.instant then
			-- A push's two Screens meet edge to edge at a fraction of a pixel,
			-- and two half-covered edge pixels let the backdrop through: a grey
			-- line runs between them. The one arriving (on top) overlaps the
			-- other by a point instead, the whole way.
			local fx, fy = mo.from.b.x, mo.from.b.y
			local ox, oy = if fx > 0 then -1 elseif fx < 0 then 1 else 0, if fy > 0 then -1 elseif fy < 0 then 1 else 0
			mo.from.b = { x = fx + ox, y = fy + oy, opacity = 1 }
			mo.to.a = { x = mo.to.a.x - ox, y = mo.to.a.y - oy, opacity = 1 }
		end
		if mo.instant or not from or not from_d or not from_d.el then
			if from then
				drop_slot(from)
			end
			show(key)
			finish()
			return
		end
		busy = true
		local t0 = os.clock()
		local start = function()
			-- (step 3) Smart Animate, or a move with its matching layers smart
			if is_smart(tr) and sd.el and smart_transition(from :: string, key, tr, mo, box, finish, opts and opts.scrub) then
				return
			end
			if opts and opts.scrub then
				-- (nothing to scrub: it just plays)
				opts.scrub.cancelled = nil
			end
			sd.spare = false
			local a, b = sd.el, from_d.el
			if not a then
				busy = false
				show(key)
				finish()
				return
			end
			set_z(key, if mo.top == "to" then 2 else 0)
			set_z(from :: string, 1)
			-- (the Screen on top also goes last in the slots: drawn, the slots
			-- keep document order whatever their `z` (seen on zgx 1890c0555:
			-- a slide's dimmed Screen covered the one arriving whenever that
			-- one had been mounted ahead), so this is what puts it on top)
			do
				local top = if mo.top == "to" then key else from
				local l, it = {}, nil
				for _, s0 in slots:peek() do
					if s0.key == top then
						it = s0
					else
						table.insert(l, s0)
					end
				end
				if it and l[#l] ~= it then
					table.insert(l, it)
					slots:set(l)
				end
			end
			set_vp(box)
			local ms = (tr and tr.ms) or 300
			-- (a spring's `ms` is its own settle time: the tween is exactly it)
			local ease = Proto.ease_of(tr)
			anime.utils.set(a, mo.to.a)
			if b then
				anime.utils.set(b, mo.from.a)
				anime.animate(b, { x = { mo.from.a.x, mo.from.b.x }, y = { mo.from.a.y, mo.from.b.y }, opacity = { mo.from.a.opacity, mo.from.b.opacity }, duration = ms, ease = ease })
			end
			local waited = (os.clock() - t0) * 1000
			anime.animate(a, {
				x = { mo.to.a.x, mo.to.b.x },
				y = { mo.to.a.y, mo.to.b.y },
				opacity = { mo.to.a.opacity, mo.to.b.opacity },
				duration = ms,
				ease = ease,
				onComplete = function()
					busy = false
					table.insert(perf.transitions, { k = tr and tr.k or "instant", ms = ms, waited = waited, prefetched = sd.ready == true })
					if from then
						drop_slot(from)
					end
					show(key)
					finish()
				end,
			})
		end
		-- (a Screen not mounted ahead gets a moment to draw first: the
		-- transition would otherwise start on an empty canvas)
		if sd.el and sd.ready then
			start()
		else
			local tries = 0
			local function when_ready()
				tries += 1
				if (sd.el and sd.ready) or tries > 30 then
					start()
				else
					ui.after(16, when_ready)
				end
			end
			ui.after(16, when_ready)
		end
	end

	-- ── overlays (step 2, figma-parity.md §1.4, §3.3) ──────────────────────
	-- An overlay slot's `sd.ov` = { pos, ox?, oy?, tx?, ty? (the trigger in
	-- the viewport, manual), bg?, co, tr (how it opened), gen (its timers) }.
	-- (set below: an overlay shown starts its timers)
	local on_ov_shown: ((key: string) -> ())? = nil

	local function ov_settings(id: string): any
		local r = root_of(id)
		return (r and r.nodes[1].ovl) or Proto.OVERLAY_DEFAULT
	end
	local function ov_index(key: string): number?
		return table.find(ov_stack, key)
	end
	-- Paint `key` last among the overlays (on top), and the open ones in stack order.
	local function ov_order(top: string?)
		local l, open, rest_, bases = {}, {}, {}, {}
		for _, s in ovs:peek() do
			local i = ov_index(s.key)
			local d = slot_data[s.key]
			if s.key == top then
				continue
			elseif d and d.smart then
				-- (L1: a smart transition's bases are over every overlay open)
				table.insert(bases, s)
			elseif i then
				open[i] = s
			else
				table.insert(rest_, s)
			end
		end
		for _, s in rest_ do
			table.insert(l, s)
		end
		for i = 1, #ov_stack do
			if open[i] then
				table.insert(l, open[i])
			end
		end
		if top then
			for _, s in ovs:peek() do
				if s.key == top then
					table.insert(l, s)
				end
			end
		end
		for _, s in bases do
			table.insert(l, s)
		end
		local same = #l == #ovs:peek()
		if same then
			for i, s in ovs:peek() do
				if l[i] ~= s then
					same = false
				end
			end
		end
		if not same then
			ovs:set(l)
		end
	end
	local function add_ov_slot(id: string, ov: any): string
		made += 1
		local key = `o{made}`
		slot_data[key] = { id = id, root = root_of(id), ver = 0, drivers = {}, spare = true, mounted_at = ui.now(), ov = ov }
		ovs:push({ key = key, id = id })
		return key
	end
	drop_ov = function(key: string)
		local l = {}
		for _, s in ovs:peek() do
			if s.key ~= key then
				table.insert(l, s)
			end
		end
		slot_data[key] = nil
		ovs:set(l)
	end
	-- An overlay slot back to a spare (closed): invisible, at rest.
	local function ov_park(key: string)
		local sd = slot_data[key]
		if not sd then
			return
		end
		sd.spare = true
		sd.ov.gen = (sd.ov.gen or 0) + 1
		rest(key)
		if hovered and hovered.key == key then
			hovered = nil
		end
		if sd.el then
			anime.utils.set(sd.el, { x = 0, y = 0, opacity = OV_SPARE })
		end
		if sd.bd_el then
			anime.utils.set(sd.bd_el, { opacity = 0 })
		end
	end
	-- The overlay frames the shown Screen (and the overlays it opens) can
	-- open or swap to, mounted ahead as spares; the rest let go.
	local function prefetch_ov()
		local want: { [string]: boolean } = {}
		local n = 0
		local function from(root: any, depth: number)
			for _, l in Proto.of_root(root).links do
				for _, act in l.a.acts or {} do
					if (act.k == "overlay" or act.k == "swap") and act.go and not act.broken and not want[act.go] and n < PREFETCH + 2 then
						local r = root_of(act.go)
						if r then
							want[act.go] = true
							n += 1
							if depth < 1 then
								from(r, depth + 1)
							end
						end
					end
				end
			end
		end
		local cur = current:peek()
		local sd = cur and slot_data[cur]
		if not sd then
			return
		end
		from(sd.root, 0)
		local bp = sd.place
		for _, s in ovs:peek() do
			local d = slot_data[s.key]
			if d and not ov_index(s.key) and not d.smart then
				-- (a spare placed for another Screen's viewport goes)
				local stale = not d.ov.bp or not bp or d.ov.bp.left ~= bp.left or d.ov.bp.top ~= bp.top or d.ov.bp.w ~= bp.w or d.ov.bp.z ~= bp.z
				if want[s.id] and not stale then
					want[s.id] = false
				else
					drop_ov(s.key)
				end
			end
		end
		for id, need in want do
			if need then
				local set = ov_settings(id)
				add_ov_slot(id, { pos = set.pos, bg = set.bg, co = set.co ~= false })
			end
		end
	end
	-- A spare of `id` (or a new slot) set up as `ov`, placed; its key.
	local function take_ov(id: string, ov: any): string
		local cur = current:peek()
		local bp = cur and slot_data[cur] and slot_data[cur].place
		local key = nil
		for _, s in ovs:peek() do
			local d = slot_data[s.key]
			if s.id == id and d and d.spare and not d.smart and not ov_index(s.key) and d.ov.bp and bp and d.ov.bp.left == bp.left and d.ov.bp.top == bp.top and d.ov.bp.z == bp.z and (d.ov.bg or "") == (ov.bg or "") then
				key = s.key
				break
			end
		end
		if not key then
			key = add_ov_slot(id, ov)
		end
		local sd = slot_data[key]
		local was = sd.ov
		ov.gen = (was and was.gen) or 0
		ov.bp = was and was.bp
		sd.ov = ov
		if sd.el then
			-- (mounted: moved to where it opens now)
			local pl = ov_place(sd)
			sd.place = pl
			ov_at:set_key({ key }, { left = pl.left, top = pl.top })
		end
		return key
	end
	-- The trigger layer of a running reaction, in the shown Screen's viewport
	-- (points): its top-left as shown (scrolled), for a manual overlay.
	local function trigger_at(origin: any?): (number?, number?)
		if not origin or not origin.id then
			return nil, nil
		end
		local keys = {}
		for k = #ov_stack, 1, -1 do
			table.insert(keys, ov_stack[k])
		end
		table.insert(keys, current:peek())
		local cur = current:peek()
		local bp = cur and slot_data[cur] and slot_data[cur].place
		for _, key in keys do
			local sd = key and slot_data[key]
			local i = sd and Proto.of_root(sd.root).at[origin.id]
			local pl = sd and sd.place
			if sd and i and bp and pl then
				-- (its box on the stage, scrolled: as stage_rect below)
				local it = sd.root.nodes[i]
				local x, y = Draw.canvas_bounds(it, Draw.local_map(it))
				local dx, dy = shift_of(sd)(i)
				local sx, sy = pl.left + (x + dx - pl.b.x) * pl.z, pl.top + (y + dy - pl.b.y) * pl.z
				return (sx - bp.left) / bp.z, (sy - bp.top) / bp.z
			end
		end
		return nil, nil
	end
	-- Plays an open (`leaving` false) or a close of overlay `key` with `tr`
	-- (a played transition), its backdrop with it; then `done`.
	local function ov_motion(key: string, tr: any?, leaving: boolean, done: () -> ())
		local sd = slot_data[key]
		local pl = sd and sd.place
		if not sd or not sd.el or not pl then
			done()
			return
		end
		local bp = pl.base or pl
		local off = Proto.overlay_off(tr, bp.vw or pl.vw, bp.vh or pl.vh, pl.ox or 0, pl.oy or 0, pl.vw, pl.vh, leaving)
		local z = pl.z
		local rest_ = { x = 0, y = 0, opacity = 1 }
		local away = { x = off.x * z, y = off.y * z, opacity = off.opacity }
		local ms = (tr and tr.ms) or 0
		if off.instant or ms <= 0 then
			if leaving then
				done()
			else
				anime.utils.set(sd.el, rest_)
				if sd.bd_el then
					anime.utils.set(sd.bd_el, { opacity = 1 })
				end
				done()
			end
			return
		end
		local a, b = if leaving then rest_ else away, if leaving then away else rest_
		local ease = Proto.ease_of(tr)
		anime.utils.set(sd.el, a)
		if sd.bd_el then
			anime.utils.set(sd.bd_el, { opacity = if leaving then 1 else 0 })
			anime.animate(sd.bd_el, { opacity = if leaving then { 1, 0 } else { 0, 1 }, duration = ms, ease = ease })
		end
		busy = true
		local t0 = os.clock()
		anime.animate(sd.el, {
			x = { a.x, b.x },
			y = { a.y, b.y },
			opacity = { a.opacity, b.opacity },
			duration = ms,
			ease = ease,
			onComplete = function()
				busy = false
				table.insert(perf.overlays, { k = tr and tr.k or "instant", ms = ms, leaving = leaving, script = (os.clock() - t0) * 1000 })
				done()
			end,
		})
	end
	-- Shows the overlay slot `key` (on top of the stack) once it's drawn.
	local function ov_open(key: string, done: () -> ())
		local sd = slot_data[key]
		local t0 = os.clock()
		local function start()
			sd.spare = false
			ov_order(key)
			sync_scroll(key, true)
			local waited = (os.clock() - t0) * 1000
			table.insert(perf.overlays, { k = "open", waited = waited, prefetched = sd.ready == true })
			ov_motion(key, sd.ov.tr, false, function()
				if on_ov_shown then
					on_ov_shown(key)
				end
				done()
			end)
		end
		if sd.el and sd.ready then
			start()
		else
			-- (not mounted ahead: a moment to draw first, as go_to waits)
			local tries = 0
			local function when_ready()
				tries += 1
				if not slot_data[key] then
					done()
				elseif (sd.el and sd.ready) or tries > 30 then
					if not sd.place or sd.place.base == nil then
						sd.place = ov_place(sd)
					end
					ov_at:set_key({ key }, { left = sd.place.left, top = sd.place.top })
					start()
				else
					ui.after(16, when_ready)
				end
			end
			ui.after(16, when_ready)
		end
	end
	-- Closes the top overlay with `tr` (nil: the reverse of how it opened).
	local function close_top(tr: any?, done: (() -> ())?)
		local key = table.remove(ov_stack)
		local fin = done or function() end
		if not key then
			fin()
			return
		end
		local sd = slot_data[key]
		if not sd then
			fin()
			return
		end
		sd.ov.gen = (sd.ov.gen or 0) + 1
		ov_motion(key, tr or Proto.reverse(sd.ov.tr), true, function()
			ov_park(key)
			if #ov_stack == 0 and ov_closed then
				ov_closed(fin)
			else
				fin()
			end
		end)
	end
	-- Closes every overlay above depth `n`, at once (the top one animated
	-- with `animate`).
	local function close_to(n: number, animate: boolean?)
		while #ov_stack > n + (if animate then 1 else 0) do
			local key = table.remove(ov_stack) :: string
			ov_park(key)
		end
		if animate and #ov_stack > n then
			close_top(nil)
		elseif #ov_stack == 0 and ov_closed then
			ov_closed(function() end)
		end
	end
	-- A Screen change closes the stack (fading with the transition's time).
	local function close_all(ms: number?)
		if #ov_stack == 0 then
			return
		end
		local keys = table.clone(ov_stack)
		table.clear(ov_stack)
		for _, key in keys do
			local sd = slot_data[key]
			if sd then
				sd.ov.gen = (sd.ov.gen or 0) + 1
				if sd.el and ms and ms > 0 then
					anime.animate(sd.el, { opacity = { 1, 0 }, duration = math.min(ms, 250), ease = "outQuad" })
					if sd.bd_el then
						anime.animate(sd.bd_el, { opacity = { 1, 0 }, duration = math.min(ms, 250), ease = "outQuad" })
					end
					ui.after(math.min(ms, 250) + 20, function()
						if slot_data[key] and not ov_index(key) then
							ov_park(key)
						end
					end)
				else
					ov_park(key)
				end
			end
		end
	end

	on_leave = close_all

	local function restart()
		if coast then
			coast.coast_end()
		end
		close_all()
		table.clear(history)
		table.clear(forward)
		table.clear(visited)
		local start = dev.cur:peek().start
		visited[start] = true
		-- (a restart forgets where every Screen was scrolled)
		table.clear(memory)
		-- (V3: and the variables and mode: Figma's only reset of them)
		if var_reset_hook then
			var_reset_hook(false)
		end
		-- (and every component's state, step 4)
		if forget_variants then
			forget_variants()
		end
		local cur = current:peek()
		if cur and slot_data[cur] and slot_data[cur].id == start then
			sync_scroll(cur, true)
			return
		end
		go_to(start, nil, true, nil, { reset = true })
	end

	-- (step 6 P3) The flows of the Design, and one picked in the sidebar:
	-- it plays from its start, as a Restart does (history, forward, scroll,
	-- variables and component states forgotten), as Figma's.
	function dev.flows(): { any }
		return if source.flows then source.flows:peek() or {} else {}
	end
	function dev.pick(i: number)
		local f = dev.flows()[i]
		if not (f and f.start and root_of(f.start)) then
			return
		end
		dev.cur:set({ start = f.start, flow = f.name })
		restart()
	end
	-- (step 6 P4) The Preview jumps to a Screen clicked on the canvas: played
	-- from there, as a Restart (no transition); its flow when one starts there.
	function dev.jump(id: string): boolean
		if not root_of(id) then
			return false
		end
		local fname = nil
		for _, f in dev.flows() do
			if f.start == id then
				fname = f.name
			end
		end
		dev.cur:set({ start = id, flow = fname })
		if current:peek() then
			restart()
		end
		return true
	end

	local function back()
		-- (Back closes the top overlay first, as Figma)
		if #ov_stack > 0 then
			if not busy then
				close_top(nil)
			end
			return
		end
		local h = table.remove(history)
		-- (a Screen deleted meanwhile is skipped)
		while h and not root_of(h.id) do
			h = table.remove(history)
		end
		if not h then
			return
		end
		local hh = h
		do
			-- (step 6 P1: → goes back where Back left)
			local cur = current:peek()
			local cd = cur and slot_data[cur]
			if cd then
				table.insert(forward, { id = cd.id, tr = h.tr })
			end
		end
		if ensure_hook then
			-- (step 4: it shows the variants its Instances last had)
			ensure_hook(hh.id, function()
				go_to(hh.id, Proto.reverse(hh.tr), true)
			end)
			return
		end
		go_to(h.id, Proto.reverse(h.tr), true)
	end

	-- The Screens on the page in →'s order: by x, then y. Screens only: a
	-- Component or a variant set isn't one. (step 6 P6: also the bar's "1 / N")
	function dev.order(): { any }
		local list = {}
		for _, r in roots:peek() do
			local n = r.nodes and r.nodes[1]
			if n and n.t == "frame" and n.box and not n.comp and not n.vset then
				table.insert(list, { id = r.id, x = n.box.x, y = n.box.y })
			end
		end
		table.sort(list, function(a: any, b: any): boolean
			if a.x ~= b.x then
				return a.x < b.x
			end
			return a.y < b.y
		end)
		return list
	end
	-- (step 6 P6) Figma's "1 / 36" between ‹ and ›, shown when the Design has
	-- no flows (with flows Figma's bar has none): the shown Screen's place in
	-- →'s order, of every Screen on the page. "" when it isn't one of them.
	function dev.counter(): string
		local key = current:get()
		local _ = title:get()
		local fl = if source.flows then source.flows:get() or {} else {}
		local sd = key and slot_data[key]
		if dev.pre or #fl > 0 or not sd then
			return ""
		end
		local list = dev.order()
		for k, e in list do
			if e.id == sd.id then
				return `{k} / {#list}`
			end
		end
		return ""
	end

	-- (step 6 P1, Figma's →) Forward history first; else the shown Screen's
	-- first link (in layer order) to a Screen not visited yet; else the next
	-- Screen on the page by x, then y. Nothing past the last one.
	local function next_screen(): string?
		if busy then
			return nil
		end
		if #ov_stack > 0 then
			close_all()
		end
		while #forward > 0 do
			local f = table.remove(forward) :: any
			if root_of(f.id) then
				go_to(f.id, f.tr, false, nil, { fwd = true })
				return f.id
			end
		end
		local cur = current:peek()
		local sd = cur and slot_data[cur]
		if not sd then
			return nil
		end
		for _, l in Proto.of_root(sd.root).links do
			for _, act in l.a.acts or { { k = "navigate", go = l.a.go, tr = l.a.tr } } do
				local go = act.k == "navigate" and not act.broken and act.go
				if go and go ~= sd.id and not visited[go] and root_of(go) then
					go_to(go, act.tr, false, nil, { fwd = true })
					return go
				end
			end
		end
		local list = dev.order()
		for k, e in list do
			if e.id == sd.id and list[k + 1] then
				local id = list[k + 1].id
				go_to(id, nil, false, nil, { fwd = true })
				return id
			end
		end
		return nil
	end

	-- Actions (step 2): a reaction runs every action in order, each after
	-- the one before it has finished animating, as Figma runs several
	-- animations one after another. One runner per kind (the scene's
	-- `acts[i].k`): fn(act, done), calling done() when it's over.
	-- (fn(act, done, origin?): origin = the reaction's layer, for overlays)
	local act_runners: { [string]: any } = {}
	act_runners.navigate = function(act: any, done: () -> ())
		if act.broken or not act.go then
			done()
			return
		end
		go_to(act.go, act.tr, false, done, { reset = act.rs == true })
	end
	act_runners.back = function(act: any, done: () -> ())
		if #ov_stack > 0 then
			close_top(act.tr, done)
			return
		end
		local h = table.remove(history)
		-- (a Screen deleted meanwhile is skipped)
		while h and not root_of(h.id) do
			h = table.remove(history)
		end
		if not h then
			done()
			return
		end
		local cur = current:peek()
		local cd = cur and slot_data[cur]
		if cd then
			table.insert(forward, { id = cd.id, tr = h.tr })
		end
		go_to(h.id, act.tr or Proto.reverse(h.tr), true, done)
	end
	act_runners.url = function(act: any, done: () -> ())
		say(`play: open {act.url}`)
		if source.open_url then
			source.open_url(act.url)
		end
		done()
	end
	-- ── interactive components (step 4, figma-parity.md §3.4) ──────────────
	-- A Screen with variants changed is that Screen resolved again by the
	-- service with the new members (so a member of another size reflows its
	-- parent, as in Figma), shown in a new slot over the old one: the Smart
	-- Animate planner (step 3) moves what matches, or it dissolves.
	local vcache: { [string]: any } = {} -- id .. "|" .. signature → { base, root }
	-- (F4-perf) Work mounted ahead, one job every AHEAD_MS, never on a
	-- busy frame (a transition running): mounting a Screen-sized canvas is a
	-- raster, and several on one frame was the hitch after each toggle.
	local AHEAD_MS = 50
	local ahead_q: { () -> () } = {}
	local ahead_on = false
	local function ahead(job: () -> ())
		table.insert(ahead_q, job)
		if ahead_on then
			return
		end
		ahead_on = true
		local function pump()
			if #ahead_q == 0 then
				ahead_on = false
				return
			end
			if not busy and not coast then
				local j = table.remove(ahead_q, 1)
				j()
			end
			ui.after(AHEAD_MS, pump)
		end
		ui.after(AHEAD_MS, pump)
	end
	-- (V3) `st` = { vars, mode }: that run state's look, not the session's
	local vcache_n = 0
	local function fetch_variant(id: string, vmap: { [string]: string }, done: (root: any?) -> (), st: any?)
		local b = base_root(id)
		if not b then
			done(nil)
			return
		end
		local rs = rsig_of(id, st)
		if next(vmap) == nil and rs == "" then
			done(b)
			return
		end
		-- (step 6 P5: a Responsive Screen's look at its size; `b` is that size's)
		local rz = dev.rz
		local size = if rz.on and rz.roots[id] and rz.roots[id].root == b then { w = rz.w, h = rz.h } else nil
		local ck = id .. "|" .. Variants.signature(vmap) .. "|" .. rs .. (if size then `|{size.w}x{size.h}` else "")
		local got = vcache[ck]
		if got and got.base == b then
			done(got.root)
			return
		end
		if not source.variant_root then
			done(nil)
			return
		end
		local run = nil
		if rs ~= "" then
			run = { vars = if st then st.vars else pv.vars, mode = if st then st.mode else pv.mode, sig = rs }
		end
		source.variant_root(id, vmap, function(r: any?)
			if r then
				-- (a stepper makes a look per value: the cache starts again past 400)
				vcache_n += 1
				if vcache_n > 400 then
					table.clear(vcache)
					vcache_n = 0
				end
				vcache[ck] = { base = b, root = r }
			end
			done(r)
		end, run, size)
	end
	-- Slots showing Screen `id` (not a smart base) take its root as it is now.
	local function refresh_slots(id: string)
		local r = root_of(id)
		-- (overlay slots too: an overlay shows its remembered variants, F4b)
		for _, list in { slots:peek(), ovs:peek() } do
			for _, s in list do
				local d = slot_data[s.key]
				if d and s.id == id and not d.smart and not (d.spare and d.change_of) and r and d.root ~= r then
					d.root = r
					if d.ver_state then
						d.ver_state:set(d.ver_state:peek() + 1)
					end
					if d.spare and d.ready then
						-- (V3: a spare drawn again isn't ready until it's drawn:
						-- a link to it waits rather than start on the old look)
						d.ready = false
						ui.after(64, function()
							if slot_data[s.key] == d then
								d.ready = true
							end
						end)
					end
				end
			end
		end
	end
	-- Screen `id`'s variant state as the memory has it (two levels: an
	-- Instance inside a member that changed), fetched; then `done`.
	local function ensure_variants(id: string, done: (() -> ())?)
		local function fin()
			if done then
				done()
			end
		end
		local b = base_root(id)
		if not b then
			fin()
			return
		end
		local v = vroots[id]
		local have = if v and v.base == b then v.vmap else {}
		local vmap, added = Variants.from_memory(b.nodes, vmem, have)
		-- (V3: and the variables it reads as they are now)
		local rs = rsig_of(id)
		if not added and v and v.base == b and (v.rs or "") == rs then
			fin()
			return
		end
		if not added and next(vmap) == nil and rs == "" then
			if v then
				vroots[id] = nil
				refresh_slots(id)
			end
			fin()
			return
		end
		fetch_variant(id, vmap, function(r: any?)
			if not r then
				fin()
				return
			end
			local vmap2, more = Variants.from_memory(r.nodes, vmem, vmap)
			local function take(root: any, m: any)
				vroots[id] = { base = b, vmap = m, root = root, rs = rs }
				refresh_slots(id)
				fin()
			end
			if more then
				fetch_variant(id, vmap2, function(r2: any?)
					if r2 then
						take(r2, vmap2)
					else
						take(r, vmap)
					end
				end)
			else
				take(r, vmap)
			end
		end)
	end
	ov_closed = function(done: () -> ())
		local c = current:peek()
		local d = c and slot_data[c]
		if d then
			ensure_variants(d.id, done)
		else
			done()
		end
	end
	-- Navigate's "Reset component state": Screen `id`'s Instances forget.
	local function reset_variants(id: string)
		local b = base_root(id)
		if b then
			Variants.forget(vmem, b.nodes)
		end
		vroots[id] = nil
		refresh_slots(id)
	end
	-- Shows `root` (Screen `from`'s, changed) in a new slot over `from`.
	-- (L1) Smart Animate between two overlay slots in one place: a Change to
	-- inside an overlay (two looks of it) or a Swap overlay (two frames). As
	-- a Change to on a Screen: the bases dissolve under the movers. `finish`
	-- runs once it lands, the new slot shown; false: it can't (the caller
	-- dissolves instead).
	local function ov_smart(from_key: string, to_key: string, tr: any, finish: () -> ()): boolean
		local a, b = slot_data[from_key], slot_data[to_key]
		if not a or not b or not a.el or not b.el or not b.ov then
			return false
		end
		local pl = b.place or ov_place(b)
		local mo = Proto.motion({ k = "dissolve", ms = tr.ms or 300, ease = tr.ease }, pl.w, pl.h)
		return smart_transition(from_key, to_key, tr, mo, vp:peek(), function()
			if slot_data[to_key] == b and b.el then
				anime.utils.set(b.el, { x = 0, y = 0, opacity = 1 })
			end
			finish()
		end, nil, { ov = b.ov })
	end

	local function change_screen(from: string, root: any, tr: any?, scope: any, done: () -> (), scrub: any?)
		if vveil[from] and vsettle_hook and vsettle_hook(function()
			-- (V3: the swap landed in a new slot: the Change to starts from it)
			local c = current:peek()
			if c and slot_data[c] and slot_data[from] == nil and slot_data[c].id == root.id then
				from = c
			end
			change_screen(from, root, tr, scope, done, scrub)
		end) then
			return
		end
		local from_d = slot_data[from]
		-- (F4-int) A Change to let go of on this look is taken over from where
		-- it is (below); anything else lets it end at once.
		local c = coast
		if c and (scrub or c.key ~= from or not is_smart(tr) or c.clean) then
			c.coast_end()
			c = nil
		end
		-- (mounted ahead already: prefetch_variants)
		local key: string? = nil
		for _, s in slots:peek() do
			local d = slot_data[s.key]
			if d and d.change_of == from and d.root == root and d.spare then
				key = s.key
			end
		end
		-- (F4-perf: a patch plays at once, over the Screen shown; the new look
		-- mounts under it during the motion (`sd.mount`, called by the smart
		-- transition), not on the click's frame: a Screen's raster there was
		-- most of that frame)
		local patchable = is_smart(tr) and from_d.el ~= nil and change_patch(from_d.root, root) ~= nil
		if not key then
			made += 1
			local k = `s{made}`
			key = k
			local nd: any = { id = from_d.id, root = root, ver = 0, drivers = {}, spare = true, mounted_at = ui.now(), change_of = from }
			slot_data[k] = nd
			set_z(k, -1)
			if patchable then
				nd.mount = function()
					nd.mount = nil
					if slot_data[k] == nd then
						nd.mounted_at = ui.now()
						slots:push({ key = k, id = nd.id })
					end
				end
			else
				slots:push({ key = k, id = from_d.id })
			end
		end
		local key = key :: string
		-- (scrolled as the Screen is: the memory has its offsets)
		sync_scroll(key)
		rest(from)
		hovered, pressed = nil, nil
		busy = true
		local t0 = os.clock()
		local function landed()
			busy = false
			table.insert(perf.transitions, { k = if tr then tr.k else "instant", ms = if tr then tr.ms else 0, change = true, waited = (os.clock() - t0) * 1000 })
			if slot_data[from] then
				drop_slot(from)
			end
			show_scope[key] = scope
			show(key)
			done()
		end
		local function start()
			local sd = slot_data[key]
			if not sd then
				busy = false
				done()
				return
			end
			local ms = if tr then tr.ms or 0 else 0
			if not tr or tr.k == "instant" or ms <= 0 or (not sd.el and not sd.mount) or not from_d.el then
				if sd.mount then
					sd.mount()
				end
				landed()
				return
			end
			local box = frame_of(place(root))
			local mo = Proto.motion({ k = "dissolve", ms = ms, ease = tr.ease }, box.w, box.h)
			if c and coast == c and not c.clean then
				-- (F4-int) Taken over from where it is, CSS's rule. Back to the
				-- look it came from: the same motion turns round, its velocity
				-- kept (a curve takes as long as the way back is, CSS's
				-- shortening). Another look: a new one from a snapshot of
				-- this frame, carrying on its velocity.
				local back = same_look(root, c.ends[1 - c.p1])
				if back then
					coast = nil
					smart_run = c
					busy = true
					c.coasting, c.landed, c.dead = false, false, false
					c.from, c.key, c.tr, c.interrupted = from, key, tr, "reverse"
					c.finish = function()
						done()
					end
					sd.spare = false
					show_scope[key] = scope
					if c.patch then
						set_z(from, 0)
						if sd.mount then
							ui.after(50, function()
								if sd.mount and not c.landed then
									sd.mount()
								end
							end)
						end
					elseif sd.el then
						anime.utils.set(sd.el, { opacity = 0 })
					end
					local p0, p1 = c.p, 1 - c.p1
					c.p1 = p1
					c.from_p = p0
					local span = p1 - p0
					local pv = c.vel()
					drive(c, p0, p1, if math.abs(span) > 1e-3 then pv / span else 0, ms * math.abs(span))
					return
				end
				-- (the snapshot has the items of the look it was heading to: the
				-- one shown, unless it was turning back, then only with no
				-- scroller inside to place them by)
				if c.p1 == 1 or #plan_of(from_d).layers == 1 then
					c.dead = true -- (held where it is until the new one starts)
					local pv = c.vel()
					local s = Smart.snapshot(c.plan, c.src_nodes, c.dst_nodes, c.p, c.od)
					local sroot = { id = c.ends[1].id, v = c.ends[1].v, nodes = s }
					show_scope[key] = scope
					if smart_transition(from, key, tr, mo, box, function()
						done()
					end, nil, { src = sroot, coast = c, pv = pv }) then
						return
					end
					show_scope[key] = nil
				end
				c.coast_end()
			end
			if is_smart(tr) then
				show_scope[key] = scope
				if smart_transition(from, key, tr, mo, box, function()
					done()
				end, scrub) then
					return
				end
				show_scope[key] = nil
			end
			if sd.mount then
				-- (not played as a patch after all: it shows at once)
				sd.mount()
				landed()
				return
			end
			if scrub then
				-- (nothing to scrub: it just plays)
				scrub.cancelled = nil
			end
			sd.spare = false
			set_z(key, 2)
			set_z(from, 1)
			anime.utils.set(sd.el, { x = 0, y = 0, opacity = 0 })
			anime.animate(sd.el, { opacity = { 0, 1 }, duration = ms, ease = Proto.ease_of(tr), onComplete = landed })
		end
		-- (F4-perf: a patch plays as soon as the new look is mounted; it draws
		-- under the patch while the motion runs)
		local tries = 0
		local function when_ready()
			tries += 1
			local sd = slot_data[key]
			if (sd and sd.el and (sd.ready or patchable)) or tries > 30 then
				start()
			else
				ui.after(16, when_ready)
			end
		end
		if patchable and (slot_data[key].el or slot_data[key].mount) then
			start()
		else
			ui.after(16, when_ready)
		end
	end
	-- Change to: the closest Instance of the target's set around the layer
	-- (on the top overlay that holds it, else the Screen) shows `act.to`.
	act_runners.changeTo = function(act: any, done: () -> (), origin: any?)
		if act.broken or not origin or not origin.id then
			done()
			return
		end
		local key: string? = nil
		local i: number? = nil
		local function find_in(k: string?): number?
			local d = k and slot_data[k]
			if not d then
				return nil
			end
			for j, it in d.root.nodes do
				if it.id == origin.id then
					return j
				end
			end
			return nil
		end
		for k = #ov_stack, 1, -1 do
			i = find_in(ov_stack[k])
			if i then
				key = ov_stack[k]
				break
			end
		end
		if not key then
			key = current:peek()
			i = find_in(key)
		end
		local sd = key and slot_data[key]
		if not sd or not i then
			done()
			return
		end
		local b = base_root(sd.id)
		local v = vroots[sd.id]
		local cur = if v and v.base == b then v.vmap else {}
		local vmap, t = Variants.change(sd.root.nodes, cur, i, act)
		if not vmap or not t then
			say(if t then "play: changeTo: it shows that variant already" else "play: changeTo: no Instance of that set around it")
			done()
			return
		end
		-- (V3) An Instance whose variant props are bound to variables: the
		-- Change to writes them (Figma's two-way binding), and the variables
		-- pick the member. With a transition it animates as any Change to and
		-- the next action waits for it (V7's leftover: `dev.vb_change`, below);
		-- instant otherwise, as every variable change in Figma.
		local inst = sd.root.nodes[t]
		if inst and inst.vb then
			if dev.vb_change and dev.vb_change(sd, key :: string, t, act, done) then
				return
			end
			if var_write_props then
				var_write_props(inst, act)
			end
			done()
			return
		end
		Variants.remember(vmem, sd.root.nodes, t, act.to, act.set)
		local skey = key :: string
		vpending += 1
		fetch_variant(sd.id, vmap, function(r: any?)
			vpending -= 1
			if not r or slot_data[skey] ~= sd then
				done()
				return
			end
			vroots[sd.id] = { base = b, vmap = vmap, root = r, rs = rsig_of(sd.id) }
			-- (the scope: the changed Instance's items as they are now)
			local sc: { [string]: boolean } = {}
			local root_id = sd.root.nodes[t].id
			for _, it in r.nodes do
				if it.id == root_id or string.sub(it.id, 1, #root_id + 1) == root_id .. "/" then
					sc[it.id] = true
				end
			end
			if sd.ov then
				local tr = act.tr
				local ms = if tr then tr.ms or 0 else 0
				local at = ov_index(skey)
				if not tr or tr.k == "instant" or ms <= 0 or not sd.el or not at then
					-- (an instant one changes in place)
					sd.root = r
					if sd.ver_state then
						sd.ver_state:set(sd.ver_state:peek() + 1)
					end
					done()
					return
				end
				-- (F4b: Figma animates a Change to inside an overlay. Here a
				-- second overlay slot in the same place shows the new look and
				-- fades in over the old one; smart plays as this dissolve)
				local o = sd.ov
				local nkey = take_ov(sd.id, { pos = o.pos, ox = o.ox, oy = o.oy, tx = o.tx, ty = o.ty, bg = o.bg, co = o.co, tr = o.tr })
				local nd = slot_data[nkey]
				if nd.root ~= r then
					nd.root = r
					if nd.ver_state then
						nd.ver_state:set(nd.ver_state:peek() + 1)
					end
				end
				ov_stack[at :: number] = nkey
				o.gen = (o.gen or 0) + 1
				local function start()
					nd.spare = false
					sync_scroll(nkey, true)
					ov_order(nkey)
					if nd.bd_el then
						anime.utils.set(nd.bd_el, { opacity = 1 })
					end
					if sd.bd_el then
						anime.utils.set(sd.bd_el, { opacity = 0 })
					end
					local function finish()
						busy = false
						ov_park(skey)
						ov_order(nil)
						if on_ov_shown then
							on_ov_shown(nkey)
						end
						done()
					end
					if not nd.el then
						finish()
						return
					end
					-- (L1: smart, as Figma: step 3's planner between the two
					-- overlay slots, its bases and movers over the overlays)
					if is_smart(tr) and sd.el and ov_smart(skey, nkey, tr, finish) then
						return
					end
					busy = true
					anime.utils.set(nd.el, { x = 0, y = 0, opacity = 0 })
					anime.animate(nd.el, { opacity = { 0, 1 }, duration = ms, ease = Proto.ease_of(tr), onComplete = finish })
				end
				local tries = 0
				local function when_ready()
					tries += 1
					if (nd.el and nd.ready) or tries > 30 then
						start()
					else
						ui.after(16, when_ready)
					end
				end
				when_ready()
				return
			end
			change_screen(skey, r, act.tr, sc, done)
		end)
	end

	-- (a Screen reached by a link or Back shows its remembered variants;
	-- "Reset component state" forgets them first)
	do
		local nav, bk = act_runners.navigate, act_runners.back
		act_runners.navigate = function(act: any, done: () -> ())
			if act.go and not act.broken and base_root(act.go) then
				if act.rc then
					reset_variants(act.go)
				end
				ensure_variants(act.go, function()
					nav(act, done)
				end)
			else
				nav(act, done)
			end
		end
		act_runners.back = function(act: any, done: () -> ())
			local h = history[#history]
			if h and #ov_stack == 0 then
				ensure_variants(h.id, function()
					bk(act, done)
				end)
			else
				bk(act, done)
			end
		end
	end
	ensure_hook = ensure_variants
	prefetch_variants = function(sd: any, key: string)
		-- The looks the shown Screen's Change to links lead to (one step
		-- each, at most 6), mounted ahead as spares, with their smart bases:
		-- a click then plays at once, as a link to a Screen mounted ahead.
		for k in table.clone(smart_bases) do
			-- (F4-int: not those of a Change to whose motion still plays)
			local live = (coast and coast.bkey == k) or (smart_run and smart_run.bkey == k)
			if string.find(k, "#", 1, true) and not live then
				drop_bases(k)
			end
		end
		if not sd.ov then
			local b = base_root(sd.id)
			local v = vroots[sd.id]
			local cur = if v and v.base == b then v.vmap else {}
			local at: { [string]: number } = {}
			for i, it in sd.root.nodes do
				at[it.id] = i
			end
			local n = 0
			local seen: { [string]: boolean } = {}
			for _, l in Proto.of_root(sd.root).links do
				for _, act in l.a.acts or {} do
					if act.k ~= "changeTo" then
						continue
					end
					local i = at[l.id]
					local vmap, ti = nil, nil
					if i and not act.broken then
						vmap, ti = Variants.change(sd.root.nodes, cur, i, act)
					end
					-- (V3: a bound Instance's look is a variable's: prefetch_vars)
					if ti and sd.root.nodes[ti] and sd.root.nodes[ti].vb then
						vmap = nil
					end
					local sig = vmap and Variants.signature(vmap)
					if vmap and sig and not seen[sig] and n < 6 then
						seen[sig] = true
						n += 1
						local tr = act.tr
						fetch_variant(sd.id, vmap, function(r: any?)
							if not r or current:peek() ~= key or slot_data[key] ~= sd then
								return
							end
							-- (F4-perf: a smart one that plays as a patch needs only
							-- its look, fetched now; nothing is mounted ahead)
							if is_smart(tr) and change_patch(sd.root, r) then
								return
							end
							-- (the others: mounted ahead, one look at a time, so
							-- the rasters don't land on one frame)
							ahead(function()
								if current:peek() ~= key or slot_data[key] ~= sd then
									return
								end
								made += 1
								local k2 = `s{made}`
								slot_data[k2] = { id = sd.id, root = r, ver = 0, drivers = {}, spare = true, mounted_at = ui.now(), change_of = key }
								set_z(k2, -1)
								slots:push({ key = k2, id = sd.id })
								if is_smart(tr) then
									ahead(function()
										if current:peek() == key and slot_data[k2] then
											bases_for(sd.id, sd.id, nil, sd.root, r)
										end
									end)
								end
							end)
						end)
					end
					break
				end
			end
		end
		for _, l in Proto.of_root(sd.root).links do
			for _, act in l.a.acts or {} do
				if act.k == "navigate" and act.go and not act.broken and not act.rc then
					ensure_variants(act.go)
				end
			end
		end
		local h = history[#history]
		if h then
			ensure_variants(h.id)
		end
		if prefetch_vars then
			prefetch_vars(sd, key)
		end
	end
	revert_variants = function(h: any, key: string)
		local sd = slot_data[key]
		if not sd then
			return
		end
		table.clear(vmem)
		for k, x in h.vmem do
			vmem[k] = x
		end
		if Variants.signature(h.vmap) == Variants.signature((vroots[sd.id] or {}).vmap or {}) then
			return
		end
		local b = base_root(sd.id)
		fetch_variant(sd.id, h.vmap, function(r: any?)
			if not r or slot_data[key] ~= sd or busy then
				return
			end
			local rs = rsig_of(sd.id)
			vroots[sd.id] = if next(h.vmap) ~= nil or rs ~= "" then { base = b, vmap = h.vmap, root = r, rs = rs } else nil
			change_screen(key, r, h.vtr, {}, function() end)
		end)
	end
	forget_variants = function()
		table.clear(vmem)
		local ids = {}
		for id in vroots do
			table.insert(ids, id)
		end
		table.clear(vroots)
		for _, id in ids do
			refresh_slots(id)
		end
	end

	-- ── variables (step 5, V3; pure/anim/f5/PLAN.md, f5/figma/README.md) ────
	-- Set, toggle and mode switch are instant: Figma never animates them.
	-- The shown Screen takes its new look as F4-perf's patch, a canvas the
	-- size of what changed drawn over it on the next frame; the new look's
	-- full slot mounts under it a moment later (`VNEXT_MS`) and shows once
	-- drawn, and the patches and the old slot go (`vland`). A change that
	-- can't be a patch (a mode switch, most of the Screen) holds the old look
	-- until the new one is drawn, unless that look was mounted ahead
	-- (`prefetch_vars`): then it shows in one frame. Open overlays change in
	-- place; Screens mounted ahead pick the change up one at a time (`ahead`).
	-- Nothing rewrites the board canvas (M0).
	local VIDLE_MS = 300
	local pv_gen = 0 -- (grows with each variable change)
	local pv_last = -1e9 -- (when the last one was, ui.now())
	local VAR_AHEAD = 6 -- looks one variable action away, fetched per Screen
	local VAR_MOUNTS = 2 -- of those, mounted ahead (a mode switch's, mostly)
	local function warn(code: string, msg: string)
		say(`play: {code}: {msg}`)
	end
	-- The item of `origin` (a reaction's layer) as it shows: in the top
	-- overlay holding it, else the Screen.
	local function origin_item(origin: any?): any?
		if not origin or not origin.id then
			return nil
		end
		local keys = {}
		for k = #ov_stack, 1, -1 do
			table.insert(keys, ov_stack[k])
		end
		table.insert(keys, current:peek())
		for _, k in keys do
			local d = k and slot_data[k]
			if d then
				for _, it in d.root.nodes do
					if it.id == origin.id then
						return it
					end
				end
			end
		end
		return nil
	end
	-- A run context for engine/vars.luau's runners: the clicked layer's
	-- pinned modes (`pin`) over the page mode, so a write is per mode.
	-- `st` = { vars, mode }: a copy being predicted (no warnings).
	local function var_ctx(pin: any?, st: any?): any
		local mode = if st then st.mode else pv.mode
		return {
			toks = pv.toks,
			vars = if st then st.vars else pv.vars,
			themes = pv.themes,
			theme = PV.theme(pv.themes, view_theme(), mode, pin),
			warn = if st then nil else warn,
		}
	end
	-- A Change to on an Instance with bound variant props: each bound
	-- variable takes the target member's value, typed for it (two-way).
	local function bound_write(inst: any, act: any, st: any?): boolean
		local wrote = false
		local vars = if st then st.vars else pv.vars
		local theme = PV.theme(pv.themes, view_theme(), if st then st.mode else pv.mode, inst.th)
		for prop, tok in inst.vb do
			local tk = pv.toks[tok]
			local val = if tk and act.vp then PV.prop_value(tk.kind, act.vp[prop]) else nil
			if val ~= nil then
				PV.write(pv.toks, vars, tok, val, theme)
				wrote = true
			end
		end
		return wrote
	end

	-- The swap lands: the new look's slot shows, the old one and its
	-- patches go. Timers keep counting (a set doesn't show the Screen anew).
	local function vland(key: string, nk: string, how: string, t0: number)
		local veil = vveil[key]
		vveil[key] = nil
		local nd = slot_data[nk]
		if not nd or not slot_data[key] then
			return
		end
		nd.vnext, nd.vlook_of, nd.vrs = nil, nil, nil
		show_scope[nk] = {}
		rest(key)
		if hovered and hovered.key == key then
			hovered = nil
		end
		-- (a press on the old look is released on the new one)
		if pressed and pressed.key == key then
			pressed.key, pressed.d = nk, nil
		end
		show(nk)
		drop_slot(key)
		for _, pk in (if veil then veil.patches else {}) do
			drop_slot(pk)
		end
		table.insert(perf.vars, { how = how, ms = (os.clock() - t0) * 1000, patches = if veil then #veil.patches else 0 })
		if #perf.vars > 50 then
			table.remove(perf.vars, 1)
		end
	end
	-- The shown slot `key` takes look `r` (see above). Its `root` is `r` at
	-- once, for hit tests and the next change, while its canvas still holds
	-- the old look under the patches.
	local function vswap(key: string, r: any, t0: number)
		local sd = slot_data[key]
		if not sd or same_look(sd.root, r) then
			return
		end
		local veil = vveil[key]
		-- (mounted ahead and drawn: it shows on this frame)
		for _, s in slots:peek() do
			local d = slot_data[s.key]
			if d and d.vlook_of == key and d.spare and d.ready and d.el and d.root == r then
				if veil and veil.next and veil.next ~= s.key then
					drop_slot(veil.next)
					veil.next = nil
				end
				sd.root = r
				vland(key, s.key, "ahead", t0)
				return
			end
		end
		if not veil then
			veil = { patches = {} }
			vveil[key] = veil
		end
		local v = veil :: any
		local patch = if sd.el then change_patch(sd.root, r) else nil
		local how = if patch then "patch" else "full"
		if patch then
			made += 1
			local pk = `s{made}`
			slot_data[pk] = { id = sd.id, root = { id = r.id, v = r.v, nodes = r.nodes }, ver = 0, drivers = {}, spare = false, smart = true, vpatch = true, mounted_at = ui.now(), patch = patch }
			set_z(pk, 3)
			sync_scroll(pk)
			slots:push({ key = pk, id = sd.id })
			-- (an older patch inside this one is covered by it: it goes once
			-- this one is drawn, so a stepper keeps one patch)
			local keep = {}
			for _, ok in v.patches do
				local o = slot_data[ok]
				local R = o and o.patch
				if R and R.x >= patch.x and R.y >= patch.y and R.x + R.w <= patch.x + patch.w and R.y + R.h <= patch.y + patch.h then
					ui.after(48, function()
						drop_slot(ok)
					end)
				else
					table.insert(keep, ok)
				end
			end
			table.insert(keep, pk)
			v.patches = keep
		end
		sd.root = r
		if v.next then
			-- (a look still drawing for an older value: this one replaces it)
			drop_slot(v.next)
			v.next = nil
		end
		made += 1
		local nk = `s{made}`
		local nd: any = { id = sd.id, root = r, ver = 0, drivers = {}, spare = true, mounted_at = ui.now(), change_of = key, vnext = true }
		slot_data[nk] = nd
		set_z(nk, -1)
		v.next = nk
		sync_scroll(nk)
		local function mount()
			if slot_data[nk] ~= nd or v.mounted == nk then
				return
			end
			v.mounted = nk
			nd.mounted_at = ui.now()
			slots:push({ key = nk, id = nd.id })
			local tries = 0
			local function when_ready()
				if slot_data[nk] ~= nd or vveil[key] ~= v or v.next ~= nk then
					return
				end
				tries += 1
				if (nd.el and nd.ready) or tries > 60 then
					vland(key, nk, how, t0)
				else
					ui.after(16, when_ready)
				end
			end
			ui.after(16, when_ready)
		end
		v.mount = mount
		if patch then
			-- (the patches show the change; the whole new look, a raster of
			-- the whole Screen, mounts once the clicks stop: VIDLE_MS after the
			-- last change, never while a transition plays. A navigate or
			-- Change to mounts it at once: vsettle)
			v.due = ui.now() + VIDLE_MS
			local function wait_idle()
				if vveil[key] ~= v or v.next ~= nk or v.mounted == nk then
					return
				end
				if ui.now() < v.due or busy or coast then
					ui.after(50, wait_idle)
					return
				end
				ahead(mount)
			end
			ui.after(VIDLE_MS, wait_idle)
		else
			mount()
		end
	end
	-- Ends every swap now (Restart, or a navigate that can't wait longer):
	-- the patches and looks still drawing go, the old slot draws its root.
	local function vflush()
		for key, veil in vveil do
			for _, pk in veil.patches do
				drop_slot(pk)
			end
			if veil.next then
				drop_slot(veil.next)
			end
			local sd = slot_data[key]
			if sd and sd.ver_state then
				sd.ver_state:set(sd.ver_state:peek() + 1)
			end
		end
		table.clear(vveil)
	end
	-- `fn` once no swap is drawing (at most ~1 s, then they end at once):
	-- a navigate, Back or Change to starts from the look shown.
	local function vsettle(fn: () -> ()): boolean
		if next(vveil) == nil and vpending == 0 then
			return false
		end
		-- (a new look still waiting for the clicks to stop mounts now)
		for _, v in vveil do
			if v.mount then
				v.mount()
			end
		end
		local tries = 0
		local function again()
			tries += 1
			if (next(vveil) == nil and vpending == 0) or tries > 60 then
				vflush()
				fn()
			else
				ui.after(16, again)
			end
		end
		ui.after(16, again)
		return true
	end
	vsettle_hook = vsettle

	-- After a variable change: the shown Screen, open overlays and Screens
	-- mounted ahead that read a changed variable take their new looks.
	-- (only those: a look's key has only the variables its root `uses`)
	local function relook()
		pv_ver:set(pv_ver:peek() + 1)
		local t0 = os.clock()
		local function look_of(id: string, got: (r: any, rs: string) -> ())
			local b = base_root(id)
			local v = vroots[id]
			local rs = rsig_of(id)
			local have = if v and v.base == b then (v.rs or "") else ""
			if not b or have == rs then
				return
			end
			local vmap = if v and v.base == b then v.vmap else {}
			vpending += 1
			fetch_variant(id, vmap, function(r: any?)
				vpending -= 1
				-- (a later change took over: its own fetch brings its look)
				if not r or rsig_of(id) ~= rs then
					return
				end
				vroots[id] = if next(vmap) ~= nil or rs ~= "" then { base = b, vmap = vmap, root = r, rs = rs } else nil
				got(r, rs)
			end)
		end
		local c = current:peek()
		local sd = c and slot_data[c]
		local cur_id = sd and sd.id
		if cur_id then
			look_of(cur_id, function(r: any)
				-- (the slot shown now: a swap may have landed meanwhile)
				local c2 = current:peek()
				local sd2 = c2 and slot_data[c2]
				if sd2 and sd2.id == cur_id then
					vswap(c2 :: string, r, t0)
				end
			end)
		end
		for _, ok in table.clone(ov_stack) do
			local od = slot_data[ok]
			if od and od.id ~= cur_id then
				local oid = od.id
				look_of(oid, function()
					refresh_slots(oid)
				end)
			end
		end
		-- (Screens mounted ahead, and the looks one more click away: once the
		-- clicks stop, one job at a time, their rasters apart; a stepper
		-- clicked fast would otherwise raster them again after every click)
		pv_gen += 1
		pv_last = ui.now()
		local g = pv_gen
		ui.after(VIDLE_MS, function()
			if g ~= pv_gen then
				return
			end
			local seen: { [string]: boolean } = {}
			local c3 = current:peek()
			local sd3 = c3 and slot_data[c3]
			if sd3 then
				seen[sd3.id] = true
			end
			for _, s in slots:peek() do
				local d = slot_data[s.key]
				if d and d.spare and not d.smart and not d.change_of and not seen[s.id] then
					seen[s.id] = true
					local sid = s.id
					ahead(function()
						ensure_variants(sid)
					end)
				end
			end
			ahead(function()
				local c4 = current:peek()
				local sd4 = c4 and slot_data[c4]
				if sd4 and prefetch_vars and g == pv_gen then
					prefetch_vars(sd4, c4 :: string)
				end
			end)
		end)
	end

	-- Runs the variable actions a list starts with on `st` (a copy of the
	-- run state), as a click would: true when it ran them all, false at the
	-- first one that isn't (it'd wait for an animation, or leave).
	local function predict(acts: { any }, st: any, it: any?, pc: any): boolean
		for _, a in acts do
			if a.k == "set" then
				PV.run_set(var_ctx(it and it.th, st), a)
			elseif a.k == "mode" then
				PV.run_mode(pv.themes, st.mode, a)
			elseif a.k == "if" then
				local ok = PV.test(var_ctx(it and it.th, st), a.cond)
				if not predict(if ok then a.th or {} else a.el or {}, st, it, pc) then
					return false
				end
			elseif a.k == "changeTo" and not a.broken and pc.i then
				local _, t = Variants.change(pc.nodes, pc.cur, pc.i, a)
				local inst = t and pc.nodes[t]
				if not (inst and inst.vb and bound_write(inst, a, st)) then
					return false
				end
			else
				return false
			end
		end
		return true
	end
	prefetch_vars = function(sd: any, key: string)
		if sd.ov or not pv.loaded or next(pv.toks) == nil then
			return
		end
		local b = base_root(sd.id)
		local v = vroots[sd.id]
		local vmap = if v and v.base == b then v.vmap else {}
		local at: { [string]: number } = {}
		for i, it in sd.root.nodes do
			at[it.id] = i
		end
		local cur_rs = rsig_of(sd.id)
		local looks: { [string]: any } = {}
		local n = 0
		for _, l in Proto.of_root(sd.root).links do
			local acts = l.a.acts
			local first = acts and acts[1]
			if not first or n >= VAR_AHEAD then
				continue
			end
			if first.k ~= "set" and first.k ~= "mode" and first.k ~= "if" and first.k ~= "changeTo" then
				continue
			end
			local vars, mode = PV.clone(pv.vars, pv.mode)
			local st = { vars = vars, mode = mode }
			local i = at[l.id]
			predict(acts, st, if i then sd.root.nodes[i] else nil, { nodes = sd.root.nodes, cur = vmap, i = i })
			local rs = rsig_of(sd.id, st)
			if rs ~= cur_rs and not looks[rs] then
				looks[rs] = st
				n += 1
			end
		end
		-- (looks mounted ahead for an older state go)
		for _, s in slots:peek() do
			local d = slot_data[s.key]
			if d and d.vlook_of == key and d.spare and not looks[d.vrs] then
				drop_slot(s.key)
			end
		end
		local mounts = 0
		for rs, st in looks do
			fetch_variant(sd.id, vmap, function(r: any?)
				if not r or current:peek() ~= key or slot_data[key] ~= sd then
					return
				end
				-- (a patch shows on the next frame: its look as data is enough;
				-- a look the Screen shows already needs nothing)
				if same_look(sd.root, r) or change_patch(sd.root, r) then
					return
				end
				for _, s in slots:peek() do
					local d = slot_data[s.key]
					if d and d.vlook_of == key and d.vrs == rs then
						return
					end
				end
				if mounts >= VAR_MOUNTS then
					return
				end
				mounts += 1
				local job: () -> ()
				job = function()
					if current:peek() ~= key or slot_data[key] ~= sd or rsig_of(sd.id) ~= cur_rs then
						return
					end
					-- (a Screen-sized raster: not while the clicks still come)
					if ui.now() - pv_last < VIDLE_MS then
						ui.after(VIDLE_MS, function()
							ahead(job)
						end)
						return
					end
					-- (one per look, VAR_MOUNTS in all: an earlier call's job may have mounted it)
					local have = 0
					for _, d in slot_data do
						if d.vlook_of == key and d.spare then
							if d.vrs == rs then
								return
							end
							have += 1
						end
					end
					if have >= VAR_MOUNTS then
						return
					end
					made += 1
					local k2 = `s{made}`
					slot_data[k2] = { id = sd.id, root = r, ver = 0, drivers = {}, spare = true, mounted_at = ui.now(), change_of = key, vlook_of = key, vrs = rs }
					set_z(k2, -1)
					sync_scroll(k2)
					slots:push({ key = k2, id = sd.id })
				end
				ahead(job)
			end, st)
		end
	end

	act_runners.set = function(act: any, done: () -> (), origin: any?)
		local it = origin_item(origin)
		PV.run_set(var_ctx(it and it.th), act)
		relook()
		done()
	end
	act_runners.mode = function(act: any, done: () -> ())
		local changed, why = PV.run_mode(pv.themes, pv.mode, act)
		if why then
			say(`play: {why}`)
		end
		if changed then
			dev.vtime("mode")
			relook()
		end
		done()
	end
	-- (V7's leftover) when variables were committed and modes switched
	-- (ui.now()), the last 20, for tests: the mode after a bound Change to
	-- lands once its transition ends, as Figma's 317 ms
	dev.vtimes = {}
	function dev.vtime(what: string)
		table.insert(dev.vtimes, { what = what, at = ui.now() })
		if #dev.vtimes > 20 then
			table.remove(dev.vtimes, 1)
		end
	end
	var_write_props = function(inst: any, act: any)
		if not act.vp then
			say("play: changeTo: no props for the bound Instance's target (scene `vp`)")
		end
		if bound_write(inst, act, nil) then
			relook()
		end
	end
	-- (V7's leftover, pure/anim/f5/PLAN.md) A Change to with a transition on
	-- an Instance bound to variables (item `t` of slot `key`): Figma animates
	-- it and holds the next action until it ends (its `mode` film: the knob
	-- slides 0–283 ms, the mode flips at 317 ms). The Screen's look with the
	-- variables written is fetched (on a copy of the run state), played as an
	-- unbound Change to plays (smart, scoped to that Instance), and then the
	-- variables are committed and the other looks follow (`relook`), and
	-- `done` runs, as Simulate. False: not this case (instant, an overlay,
	-- nothing written); the caller writes at once.
	function dev.vb_change(sd: any, key: string, t: number, act: any, done: () -> ()): boolean
		local tr = act.tr
		local ms = if tr then tr.ms or 0 else 0
		local inst = sd.root.nodes[t]
		if sd.ov or not tr or tr.k == "instant" or ms <= 0 or not sd.el or not inst or not act.vp then
			return false
		end
		local vars, mode = PV.clone(pv.vars, pv.mode)
		local st = { vars = vars, mode = mode }
		if not bound_write(inst, act, st) then
			return false
		end
		local id = sd.id
		local b = base_root(id)
		local v = vroots[id]
		local vmap = if v and v.base == b then v.vmap else {}
		local rs = rsig_of(id, st)
		local root_id = inst.id
		vpending += 1
		fetch_variant(id, vmap, function(r: any?)
			vpending -= 1
			local committed = false
			local function commit()
				if committed then
					return
				end
				committed = true
				dev.vtime("commit")
				table.clear(pv.vars)
				for k2, x in st.vars do
					pv.vars[k2] = x
				end
				table.clear(pv.mode)
				for k2, x in st.mode do
					pv.mode[k2] = x
				end
				-- (the look shown is this state's already: relook leaves it)
				if r and base_root(id) == b then
					vroots[id] = if next(vmap) ~= nil or rs ~= "" then { base = b, vmap = vmap, root = r, rs = rs } else nil
				end
				relook()
			end
			if not r or slot_data[key] ~= sd or same_look(sd.root, r) then
				commit()
				done()
				return
			end
			local sc: { [string]: boolean } = {}
			for _, it in r.nodes do
				if it.id == root_id or string.sub(it.id, 1, #root_id + 1) == root_id .. "/" then
					sc[it.id] = true
				end
			end
			dev.vb_n = (dev.vb_n or 0) + 1
			change_screen(key, r, tr, sc, function()
				commit()
				done()
			end)
		end, st)
		return true
	end
	-- The values back to the Design's, the mode too (Restart's, or the
	-- popover's Reset: then `look` shows them at once, without navigating).
	local function var_reset(look: boolean)
		table.clear(pv.vars)
		table.clear(pv.mode)
		if look then
			relook()
		else
			vflush()
			pv_ver:set(pv_ver:peek() + 1)
		end
	end
	var_reset_hook = var_reset
	local function load_vars()
		if not source.tokens then
			return
		end
		source.tokens(function(t: any)
			if type(t) ~= "table" then
				return
			end
			pv.toks = PV.tokens(t.tokens)
			pv.themes = if type(t.themes) == "table" then t.themes else {}
			local first = not pv.loaded
			pv.loaded = true
			pv_ver:set(pv_ver:peek() + 1)
			local c = current:peek()
			if first and c and slot_data[c] and prefetch_vars then
				prefetch_vars(slot_data[c], c)
			end
		end)
	end

	-- (reserved: timeline motion isn't played yet)
	act_runners.motion = function(act: any, done: () -> ())
		say(`play: motion {tostring(act.play)} isn't played yet`)
		done()
	end
	-- Scroll to (F2a): the nearest scroller around the layer brings it to its
	-- top-left, less the offset; animated with the act's time and curve.
	act_runners.scrollTo = function(act: any, done: () -> ())
		-- (the overlay that holds the layer, top first, else the Screen)
		local key = current:peek()
		for k = #ov_stack, 1, -1 do
			local d = slot_data[ov_stack[k]]
			if d and plan_of(d).at[act.to] then
				key = ov_stack[k]
				break
			end
		end
		local sd = key and slot_data[key]
		local plan = sd and plan_of(sd)
		local i = plan and plan.at[act.to]
		if not sd or not i then
			say(`play: scrollTo {tostring(act.to)}: not on this Screen`)
			done()
			return
		end
		-- (the scroller and where: Scroll.scroll_target, shared with Simulate)
		local s, tx, ty = Scroll.scroll_target(plan, i, act.ox or 0, act.oy or 0, function(k: number): (number, number)
			return pos_of(sd, k)
		end, function(k: number): (number, number)
			return room_of(sd, k)
		end)
		local tr = act.tr
		glide(sd, s, tx, ty, if tr then tr.ms or 300 else 0, Proto.ease(tr and tr.ease), done)
	end

	-- Overlays (step 2): open over the Screen (its place from the frame's
	-- settings, or manual from the trigger), swap the top one, close it.
	act_runners.overlay = function(act: any, done: () -> (), origin: any?)
		if act.broken or not act.go or not root_of(act.go) or not current:peek() then
			done()
			return
		end
		for _, k in ov_stack do
			if slot_data[k] and slot_data[k].id == act.go then
				-- (open already: nothing, as Figma)
				done()
				return
			end
		end
		local set = ov_settings(act.go)
		local ov: any = { pos = act.pos or set.pos, bg = set.bg, co = set.co ~= false, tr = act.tr }
		if ov.pos == "manual" then
			ov.ox, ov.oy = act.ox or 0, act.oy or 0
			ov.tx, ov.ty = trigger_at(origin)
		end
		local key = take_ov(act.go, ov)
		table.insert(ov_stack, key)
		ov_open(key, done)
	end
	act_runners.close = function(act: any, done: () -> ())
		close_top(act.tr, done)
	end
	do
		-- (F4b, filmed in Figma: an overlay opens in the variants the memory
		-- holds, and the Screen under it picks up a change made in the overlay
		-- once it closes)
		local open, close = act_runners.overlay, act_runners.close
		act_runners.overlay = function(act: any, done: () -> (), origin: any?)
			if act.go and not act.broken and base_root(act.go) then
				ensure_variants(act.go, function()
					open(act, done, origin)
				end)
			else
				open(act, done, origin)
			end
		end
		act_runners.close = function(act: any, done: () -> ())
			close(act, function()
				local c = current:peek()
				local d = c and slot_data[c]
				if d and #ov_stack == 0 then
					ensure_variants(d.id, done)
				else
					done()
				end
			end)
		end
	end
	act_runners.swap = function(act: any, done: () -> ())
		if act.broken or not act.go or not root_of(act.go) then
			done()
			return
		end
		local old_key = ov_stack[#ov_stack]
		if not old_key then
			-- (no overlay open: a navigate with no history entry, as Figma)
			go_to(act.go, act.tr, true, done)
			return
		end
		local old = slot_data[old_key]
		if old.id == act.go then
			done()
			return
		end
		local set = ov_settings(act.go)
		-- (it keeps the top one's place and the way it opened)
		local ov: any = { pos = old.ov.pos, ox = old.ov.ox, oy = old.ov.oy, tx = old.ov.tx, ty = old.ov.ty, bg = set.bg, co = set.co ~= false, tr = old.ov.tr }
		local key = take_ov(act.go, ov)
		ov_stack[#ov_stack] = key
		old.ov.gen = (old.ov.gen or 0) + 1
		local sd = slot_data[key]
		local function start()
			sd.spare = false
			sync_scroll(key, true)
			local tr = act.tr
			local pl = sd.place
			local mo = Proto.motion(tr, pl.w, pl.h)
			ov_order(if mo.top == "from" then old_key else key)
			if sd.bd_el then
				anime.utils.set(sd.bd_el, { opacity = 1 })
			end
			if old.bd_el then
				anime.utils.set(old.bd_el, { opacity = 0 })
			end
			local function finish()
				busy = false
				ov_park(old_key)
				ov_order(nil)
				if on_ov_shown then
					on_ov_shown(key)
				end
				done()
			end
			if mo.instant or not old.el or not sd.el then
				if sd.el then
					anime.utils.set(sd.el, { x = 0, y = 0, opacity = 1 })
				end
				finish()
				return
			end
			-- (L1: Smart Animate applies to Swap overlay, Figma's rule; Simulate
			-- and the export already did)
			if is_smart(tr) and ov_smart(old_key, key, tr, finish) then
				return
			end
			busy = true
			local ms, ease = (tr and tr.ms) or 300, Proto.ease_of(tr)
			anime.utils.set(sd.el, mo.to.a)
			anime.utils.set(old.el, mo.from.a)
			anime.animate(old.el, { x = { mo.from.a.x, mo.from.b.x }, y = { mo.from.a.y, mo.from.b.y }, opacity = { mo.from.a.opacity, mo.from.b.opacity }, duration = ms, ease = ease })
			anime.animate(sd.el, {
				x = { mo.to.a.x, mo.to.b.x },
				y = { mo.to.a.y, mo.to.b.y },
				opacity = { mo.to.a.opacity, mo.to.b.opacity },
				duration = ms,
				ease = ease,
				onComplete = finish,
			})
		end
		if sd.el and sd.ready then
			start()
		else
			local tries = 0
			local function when_ready()
				tries += 1
				if (sd.el and sd.ready) or tries > 30 then
					start()
				else
					ui.after(16, when_ready)
				end
			end
			ui.after(16, when_ready)
		end
	end

	do
		-- (L1: a swapped-in overlay opens in the remembered variants too, as an
		-- opened one does; Simulate's overlay_surface already did)
		local sw = act_runners.swap
		act_runners.swap = function(act: any, done: () -> ())
			if act.go and not act.broken and base_root(act.go) and #ov_stack > 0 then
				ensure_variants(act.go, function()
					sw(act, done)
				end)
			else
				sw(act, done)
			end
		end
	end

	-- `origin`: the reaction running ({ id = its layer }), for a manual overlay.
	local function run_acts(acts: { any }, i: number, done: (() -> ())?, origin: any?)
		local act = acts[i]
		if not act then
			if done then
				done()
			end
			return
		end
		local runner: any = act_runners[act.k]
		if not runner then
			say(`play: can't run {tostring(act.k)} yet`)
			run_acts(acts, i + 1, done, origin)
			return
		end
		runner(act, function()
			run_acts(acts, i + 1, done, origin)
		end, origin)
	end
	-- (V3) Conditional: its Then or Else list runs, then the actions after
	-- it (Figma's order; an animated act in a branch blocks the rest).
	act_runners["if"] = function(act: any, done: () -> (), origin: any?)
		local it = origin_item(origin)
		local ok = PV.test(var_ctx(it and it.th), act.cond)
		run_acts(if ok then act.th or {} else act.el or {}, 1, done, origin)
	end

	local function run(link: any, done: (() -> ())?)
		local a = link.a
		local acts = a.acts
		if not acts then
			-- (a scene from before step 2: its first move only)
			acts = {
				if a.url then { k = "url", url = a.url, nt = a.nt } elseif a.go == "back" then { k = "back", tr = a.tr } else { k = "navigate", go = a.go, tr = a.tr },
			}
		end
		-- (the later Screens of a list mount now, and stay while it runs, so
		-- each of its transitions starts on a Screen drawn already)
		local pins = {}
		local cur_key = current:peek()
		local cur_id = cur_key and slot_data[cur_key] and slot_data[cur_key].id
		for i, act in acts do
			if i > 1 and act.k == "navigate" and act.go and act.go ~= cur_id and not act.broken and not pinned[act.go] then
				pinned[act.go] = true
				table.insert(pins, act.go)
				add_slot(act.go, true)
			end
		end
		run_acts(acts, 1, function()
			for _, id in pins do
				pinned[id] = nil
			end
			if done then
				done()
			end
		end, { id = link.id })
	end

	-- The pointer: stage points → the shown Screen's Canvas units, as laid
	-- out (scrolling is in the hit tests' `shift_of`). Past the viewport,
	-- nothing is hit. Overlays first, top down (step 2): inside one, its slot;
	-- outside one that closes on outside clicks or has a background, nothing
	-- under it is reached (4th value: that overlay's key); past one without
	-- either, on to the one under it, then the Screen.
	local function to_screen(lx: number, ly: number): (string?, number, number, string?)
		for k = #ov_stack, 1, -1 do
			local okey = ov_stack[k]
			local od = slot_data[okey]
			local opl = od and od.place
			if od and opl and not od.spare then
				if lx >= opl.left and ly >= opl.top and lx <= opl.left + opl.w and ly <= opl.top + opl.h then
					return okey, (lx - opl.left) / opl.z + opl.b.x, (ly - opl.top) / opl.z + opl.b.y
				end
				if od.ov.co or od.ov.bg then
					return nil, 0, 0, okey
				end
			end
		end
		local key = current:peek()
		local sd = key and slot_data[key]
		if not sd or not sd.place then
			return nil, 0, 0
		end
		local pl = sd.place
		if lx < pl.left or ly < pl.top or lx > pl.left + pl.w or ly > pl.top + pl.h then
			return key, -1e9, -1e9
		end
		return key, (lx - pl.left) / pl.z + pl.b.x, (ly - pl.top) / pl.z + pl.b.y
	end

	local function set_hover(key: string?, d: any?)
		local was = hovered
		if was and (was.key ~= key or was.d ~= d) then
			local sd = slot_data[was.key]
			local st = sd and sd.drivers[was.d.id]
			if st then
				st.hover:set(false)
				st.press:set(false)
				st.scale:set(1)
			end
			hovered = nil
		end
		if key and d and not hovered then
			local t0 = os.clock()
			local st = slot_data[key].drivers[d.id]
			if st then
				st.hover:set(true)
				st.scale:set(d.scale.hover)
			end
			hovered = { key = key, d = d }
			table.insert(perf.hovers, (os.clock() - t0) * 1000)
		end
	end

	-- ── triggers besides click (step 2, Figma's) ────────────────────────────
	-- hover / press: run while they last, and revert when they end (a
	-- Screen they went to goes back the reverse way). mouseEnter /
	-- mouseLeave / mouseDown / mouseUp: one-off, after `ms` if the pointer
	-- stayed (or stayed away). drag: a press that moves DRAG_PT. afterDelay:
	-- `ms` after its Screen shows. key: its combo while its Screen shows.
	local DRAG_PT = 4
	local gen = 0 -- grows with each Screen shown: an older one's timers stop
	local under: { [string]: any } = {} -- layers with enter/leave/hover under the pointer: id → { key, ls }
	local held: any = nil -- the hover / press reaction running: { kind, origin, depth, rect }

	-- A layer's box on the stage (stage points), for "has the pointer left it".
	local function stage_rect(key: string, i: number): { number }?
		local sd = slot_data[key]
		local it = sd and sd.root.nodes[i]
		local pl = sd and sd.place
		if not it or not pl then
			return nil
		end
		local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
		local dx, dy = shift_of(sd)(i)
		return { pl.left + (x + dx - pl.b.x) * pl.z, pl.top + (y + dy - pl.b.y) * pl.z, w * pl.z, h * pl.z }
	end
	local function in_rect(r: { number }?, x: number, y: number): boolean
		return r ~= nil and x >= r[1] and y >= r[2] and x <= r[1] + r[3] and y <= r[2] + r[4]
	end

	-- Runs `l`'s actions now, or after `ms` if `still()` says so then (and
	-- the same Screen still shows).
	local function fire(l: any, ms: number?, still: (() -> boolean)?)
		if not ms or ms <= 0 then
			if not busy then
				run(l)
			end
			return
		end
		local g = gen
		ui.after(ms, function()
			if g == gen and not busy and (not still or still()) then
				run(l)
			end
		end)
	end

	-- The hover / press reaction held ends: back to where it started.
	local function revert()
		local h = held
		if not h then
			return
		end
		if busy then
			-- (still arriving: undo once there)
			ui.after(40, revert)
			return
		end
		held = nil
		-- (the overlays it opened close: a tooltip, a hover menu)
		if #ov_stack > (h.ovd or 0) then
			close_to(h.ovd or 0, true)
		end
		local cur = current:peek()
		local sd = cur and slot_data[cur]
		if sd and sd.id ~= h.origin and #history > h.depth then
			while #history > h.depth + 1 do
				table.remove(history)
			end
			local last = table.remove(history) :: any
			go_to(last.id, Proto.reverse(last.tr), true)
		elseif sd and sd.id == h.origin and h.vmem and revert_variants then
			-- (step 4: while hovering / pressing → Change to goes back)
			revert_variants(h, cur :: string)
		end
	end
	local function hold(kind: string, l: any, key: string, lx: number, ly: number)
		if held or busy then
			return
		end
		local sd = slot_data[key]
		held = { kind = kind, origin = sd.id, depth = #history, rect = stage_rect(key, l.i), id = l.id, ovd = #ov_stack }
		for _, act in l.a.acts or {} do
			if act.k == "changeTo" then
				local v = vroots[sd.id]
				held.vmap = if v and v.base == base_root(sd.id) then v.vmap else {}
				held.vmem = table.clone(vmem)
				held.vtr = act.tr
				break
			end
		end
		run(l)
	end

	-- A hover held: has the pointer left it? Past the trigger, an overlay it
	-- opened keeps it while the pointer is in that overlay, with 100 ms to
	-- get there from the trigger (figma-parity.md §3.3; Figma's exact grace
	-- is unverified).
	local last_pt = { -1e9, -1e9 }
	local function in_held_overlay(h: any, lx: number, ly: number): boolean
		for k = (h.ovd or 0) + 1, #ov_stack do
			local od = slot_data[ov_stack[k]]
			local opl = od and od.place
			if opl and lx >= opl.left and ly >= opl.top and lx <= opl.left + opl.w and ly <= opl.top + opl.h then
				return true
			end
		end
		return false
	end
	local function hover_left(lx: number, ly: number)
		local h = held
		if not h or h.kind ~= "hover" or in_rect(h.rect, lx, ly) or in_held_overlay(h, lx, ly) then
			return
		end
		if #ov_stack > (h.ovd or 0) then
			if h.grace then
				return
			end
			h.grace = true
			ui.after(100, function()
				if held == h then
					h.grace = nil
					if not in_rect(h.rect, last_pt[1], last_pt[2]) and not in_held_overlay(h, last_pt[1], last_pt[2]) then
						revert()
					end
				end
			end)
			return
		end
		revert()
	end

	-- The pointer moved to stage (lx, ly), over (x, y) of Screen `key`.
	local function triggers_move(key: string?, x: number, y: number, lx: number, ly: number)
		last_pt[1], last_pt[2] = lx, ly
		hover_left(lx, ly)
		local now: { [string]: { any } } = {}
		if key then
			for _, l in Proto.reactions_at(slot_data[key].root, x, y, shift_of(slot_data[key])) do
				local on = l.a.on
				if on == "mouseEnter" or on == "mouseLeave" or on == "hover" then
					local ls = now[l.id]
					if not ls then
						ls = {}
						now[l.id] = ls
					end
					table.insert(ls, l)
				end
			end
		end
		for id, u in under do
			if not now[id] then
				under[id] = nil
				for _, l in u.ls do
					if l.a.on == "mouseLeave" then
						fire(l, l.a.ms, function()
							return under[id] == nil
						end)
					end
				end
			end
		end
		for id, ls in now do
			if not under[id] then
				local u = { key = key, ls = ls }
				under[id] = u
				for _, l in ls do
					if l.a.on == "mouseEnter" then
						fire(l, l.a.ms, function()
							return under[id] == u
						end)
					elseif l.a.on == "hover" then
						hold("hover", l, key :: string, lx, ly)
					end
				end
			end
		end
	end

	-- A Screen shows: its afterDelay reactions start counting.
	local function start_timers(key: string, scope: any?)
		-- (a Change to keeps the Screen's own timers running: only those
		-- inside the Instance that changed start)
		if not scope then
			gen += 1
			table.clear(under)
		end
		local sd = slot_data[key]
		if not sd then
			return
		end
		local function still(): boolean
			local cur = current:peek()
			local cd = cur and slot_data[cur]
			return cd ~= nil and cd.id == sd.id and (cur == key or cd.root ~= nil)
		end
		for _, l in Proto.of_root(sd.root).links do
			if l.a.on == "afterDelay" and Proto.live(l.a) and (not scope or scope[l.id]) then
				local g = gen
				ui.after(math.max(0, l.a.ms or 0), function()
					if g == gen and still() then
						if busy then
							-- (a transition still running: once it's over)
							local function retry()
								if g ~= gen then
									return
								end
								if busy then
									ui.after(30, retry)
								else
									run(l)
								end
							end
							ui.after(30, retry)
						else
							run(l)
						end
					end
				end)
			end
		end
	end

	on_shown = function(key: string, scope: any?)
		start_timers(key, scope)
		-- (overlays: those this Screen can open are mounted ahead)
		prefetch_ov()
	end

	-- An overlay shows (step 2): its afterDelay reactions count from now
	-- (a toast that closes itself), until it closes.
	on_ov_shown = function(key: string)
		local sd = slot_data[key]
		if not sd then
			return
		end
		local g = sd.ov.gen or 0
		local function alive(): boolean
			return slot_data[key] == sd and (sd.ov.gen or 0) == g and ov_index(key) ~= nil
		end
		for _, l in Proto.of_root(sd.root).links do
			if l.a.on == "afterDelay" and Proto.live(l.a) then
				ui.after(math.max(0, l.a.ms or 0), function()
					local function go()
						if not alive() then
							return
						end
						if busy then
							ui.after(30, go)
						else
							run(l)
						end
					end
					go()
				end)
			end
		end
	end

	-- A key: the top overlay's key reactions, then the shown Screen's
	-- (Figma: they win over the player's keys; Esc and Ctrl+Enter still close).
	local function key_trigger(k: any): boolean
		local cur = current:peek()
		local sd = cur and slot_data[cur]
		if not sd or k["repeat"] then
			return false
		end
		local list = { sd }
		if #ov_stack > 0 and slot_data[ov_stack[#ov_stack]] then
			table.insert(list, 1, slot_data[ov_stack[#ov_stack]])
		end
		for _, s in list do
			for _, l in Proto.of_root(s.root).links do
				if l.a.on == "key" and Proto.live(l.a) and Proto.key_match(l.a.keys, k) then
					if not busy then
						run(l)
					end
					return true
				end
			end
		end
		return false
	end

	-- Dragging scrolls (F2a), as a finger does in Figma's player: a press
	-- that moves past the slop, where something can scroll, stops being a
	-- click; the release glides on with the pointer's speed (momentum).
	local function drag_scroll(e: any): boolean
		local p = pressed
		if not p or p.drag or busy then
			return false
		end
		local sd = slot_data[p.key]
		if not sd or not sd.place then
			return false
		end
		local z = sd.place.z
		if not p.sc then
			local dx, dy = e.local_x - p.lx, e.local_y - p.ly
			if dx * dx + dy * dy < Scroll.DRAG_SLOP * Scroll.DRAG_SLOP then
				return false
			end
			local _, x, y = to_screen(p.lx, p.ly)
			local i = Proto.deepest(sd.root, x, y, shift_of(sd))
			local chain = Scroll.chain(plan_of(sd), if i > 0 then i else 1)
			local can = false
			for _, s in chain do
				local mx, my = room_of(sd, s)
				if mx > 0 or my > 0 then
					can = true
				end
			end
			if not can then
				p.sc = false
				return false
			end
			p.sc = { chain = chain, x = p.lx, y = p.ly, samples = {} }
			p.link = nil -- (a drag isn't a click)
			p.acted = true
			if p.d then
				local st = sd.drivers[p.d.id]
				if st then
					st.press:set(false)
					st.scale:set(1)
				end
			end
			stop_glides(sd)
		end
		local sc = p.sc
		if not sc then
			return false
		end
		scroll_by(sd, 0, 0, (sc.x - e.local_x) / z, (sc.y - e.local_y) / z, sc.chain)
		sc.x, sc.y = e.local_x, e.local_y
		table.insert(sc.samples, { ui.now(), e.local_x, e.local_y })
		if #sc.samples > 12 then
			table.remove(sc.samples, 1)
		end
		return true
	end
	-- The release of a drag-scroll: the glide on (momentum, v·e^(−t/τ)).
	local function fling(p: any)
		local sd = slot_data[p.key]
		if not sd or not sd.place then
			return
		end
		local z = sd.place.z
		local vx, vy = Scroll.velocity(p.sc.samples, ui.now())
		vx, vy = -vx / z, -vy / z
		local main = if math.abs(vy) >= math.abs(vx) then vy else vx
		if math.abs(main) * z < Scroll.MIN_FLING then
			return
		end
		-- the innermost scroller that can still go that way takes it
		for _, s in p.sc.chain do
			local x, y = pos_of(sd, s)
			local mx, my = room_of(sd, s)
			local can_x = (vx > 0 and x < mx) or (vx < 0 and x > 0)
			local can_y = (vy > 0 and y < my) or (vy < 0 and y > 0)
			if (math.abs(vy) >= math.abs(vx) and can_y) or (math.abs(vx) > math.abs(vy) and can_x) then
				local dx, ms_x, ease_x = Scroll.fling(vx)
				local dy, ms_y, ease_y = Scroll.fling(vy)
				local ease = if math.abs(vy) >= math.abs(vx) then ease_y else ease_x
				glide(sd, s, x + dx, y + dy, math.max(ms_x, ms_y), ease)
				return
			end
		end
	end

	-- (step 3) A drag whose reaction smart-animates to a Screen scrubs it:
	-- the transition follows the pointer along the way the dragged layer
	-- moves (or across the viewport when it doesn't), and on release it
	-- finishes from there, or goes back when let go short of half way (or
	-- flung back).
	local function scrub_p(sc: any, lx: number, ly: number): number
		local run = sc.run
		if not run then
			return 0
		end
		local dx, dy = lx - sc.lx0, ly - sc.ly0
		if not sc.v then
			-- The way to drag: the dragged layer's own travel; else (it stays,
			-- as a switch's track) the layer that travels most (its knob);
			-- else across the viewport, the way the drag first went.
			local z = (sc.z or 1)
			local vx, vy, best = 0, 0, 0
			for _, mv in run.plan.movers do
				local tx, ty = (mv.b.x - mv.a.x) * z, (mv.b.y - mv.a.y) * z
				local it = mv.si and run.src_nodes[mv.si]
				if it and it.id == sc.layer and tx * tx + ty * ty >= 64 then
					vx, vy, best = tx, ty, math.huge
				elseif mv.kind ~= "fade" and tx * tx + ty * ty > best then
					vx, vy, best = tx, ty, tx * tx + ty * ty
				end
			end
			if best < 64 then
				if dx * dx + dy * dy < 16 then
					return 0
				end
				local w, h = vp:peek().w, vp:peek().h
				if math.abs(dx) >= math.abs(dy) then
					vx, vy = if dx < 0 then -w else w, 0
				else
					vx, vy = 0, if dy < 0 then -h else h
				end
			end
			sc.v = { vx, vy }
		end
		local vx, vy = sc.v[1], sc.v[2]
		return math.clamp((dx * vx + dy * vy) / (vx * vx + vy * vy), 0, 1)
	end
	local function scrub_land(sc: any)
		local run = sc.run
		if not run then
			return
		end
		local p0 = run.p or 0
		local forward = p0 >= 0.5
		if sc.vel then
			-- (a fling decides over the half-way mark)
			if sc.vel > 0.4 then
				forward = true
			elseif sc.vel < -0.4 then
				forward = false
			end
		end
		local target = if forward then 1 else 0
		local ms = math.max(60, (sc.ms or 300) * math.abs(target - p0))
		local t = { p = p0 }
		local ok = pcall(function()
			anime.animate(t, {
				p = { p0, target },
				duration = ms,
				ease = "outCubic",
				onUpdate = function()
					run.p = t.p
					run.apply(t.p)
				end,
				onComplete = function()
					run.apply(target)
					run.land(forward)
				end,
			})
		end)
		if not ok then
			run.apply(target)
			run.land(forward)
		end
	end
	local function drag_smart(l: any, lx: number, ly: number): any?
		local act = nil
		for _, a in l.a.acts or {} do
			if a.k == "navigate" or a.k == "changeTo" then
				act = a
				break
			end
		end
		if not act or act.broken or not is_smart(act.tr) then
			return nil
		end
		local cur = current:peek()
		local cd = cur and slot_data[cur]
		if not cd then
			return nil
		end
		-- (step 4) a Change to that smart-animates: the Screen's new look is
		-- fetched, then scrubbed like a navigate's
		local change: any = nil
		if act.k == "changeTo" then
			if #ov_stack > 0 then
				return nil
			end
			local i = nil
			for j, it in cd.root.nodes do
				if it.id == l.id then
					i = j
				end
			end
			local b = base_root(cd.id)
			local v = vroots[cd.id]
			local before = if v and v.base == b then v.vmap else {}
			local vmap, t = if i then Variants.change(cd.root.nodes, before, i, act) else nil, nil
			if not vmap or not t then
				return nil
			end
			change = { b = b, before = before, vmap = vmap, t = t, mem = table.clone(vmem) }
		elseif not root_of(act.go) or cd.id == act.go then
			return nil
		end
		local sc: any = { lx0 = lx, ly0 = ly, layer = l.id, ms = act.tr.ms, z = cd.place and cd.place.z or 1, samples = {} }
		sc.ready = function(run: any)
			sc.run = run
			-- (a dragged layer that doesn't travel itself, as a switch's track:
			-- Figma plays the transition through once the drag starts, the
			-- pointer held still or not (filmed, pure/anim/f3-figma
			-- raw-figma-f3c/switch-hold): no scrub)
			if not Smart.drag_follows(run.plan, run.src_nodes, sc.layer) then
				sc.play = true
				local t = { p = 0 }
				local ok = pcall(function()
					anime.animate(t, {
						p = { 0, 1 },
						duration = math.max(1, act.tr.ms or 300),
						ease = Proto.ease_of(act.tr),
						onUpdate = function()
							run.p = t.p
							run.apply(t.p)
						end,
						onComplete = function()
							run.apply(1)
							run.land(true)
						end,
					})
				end)
				if not ok then
					run.apply(1)
					run.land(true)
				end
				return
			end
			run.p = scrub_p(sc, sc.lx or lx, sc.ly or ly)
			run.apply(run.p)
			if sc.released then
				scrub_land(sc)
			end
		end
		if change then
			local cd_key = cur :: string
			sc.cancelled = function()
				-- (let go short: the Instance keeps the variant it had)
				table.clear(vmem)
				for k, x in change.mem do
					vmem[k] = x
				end
				vroots[cd.id] = if next(change.before) ~= nil then { base = change.b, vmap = change.before, root = cd.root } else nil
				for _, s in slots:peek() do
					local d = slot_data[s.key]
					if d and s.key ~= cd_key and s.id == cd.id and d.change_of == cd_key then
						drop_slot(s.key)
					end
				end
				busy = false
				show(cd_key)
			end
			Variants.remember(vmem, cd.root.nodes, change.t, act.to, act.set)
			fetch_variant(cd.id, change.vmap, function(r: any?)
				if not r or slot_data[cd_key] ~= cd then
					return
				end
				vroots[cd.id] = { base = change.b, vmap = change.vmap, root = r }
				local sc_ids: { [string]: boolean } = {}
				local root_id = cd.root.nodes[change.t].id
				for _, it in r.nodes do
					if it.id == root_id or string.sub(it.id, 1, #root_id + 1) == root_id .. "/" then
						sc_ids[it.id] = true
					end
				end
				change_screen(cd_key, r, act.tr, sc_ids, function() end, sc)
			end)
			return sc
		end
		sc.cancelled = function()
			-- (let go short: back where it was, no history)
			table.remove(history)
			local key = current:peek()
			if key then
				show(key)
			end
		end
		go_to(act.go, act.tr, false, nil, { scrub = sc })
		return sc
	end

	local function on_move(e: any)
		local sc = pressed and pressed.scrub
		if sc then
			sc.lx, sc.ly = e.local_x, e.local_y
			table.insert(sc.samples, { ui.now(), e.local_x, e.local_y })
			if sc.run and not sc.play then
				sc.run.p = scrub_p(sc, e.local_x, e.local_y)
				sc.run.apply(sc.run.p)
			end
			return
		end
		if drag_scroll(e) then
			return
		end
		if pressed and pressed.drag and not busy then
			local dx, dy = e.local_x - pressed.lx, e.local_y - pressed.ly
			if dx * dx + dy * dy >= DRAG_PT * DRAG_PT then
				local l = pressed.drag
				pressed.drag = nil
				pressed.link = nil -- (a drag isn't a click)
				pressed.acted = true
				local held_p = pressed
				local sc2 = drag_smart(l, held_p.lx, held_p.ly)
				if sc2 then
					-- (go_to let go of the press: the drag holds on to it)
					sc2.lx, sc2.ly = e.local_x, e.local_y
					held_p.scrub = sc2
					pressed = held_p
					return
				end
				run(l)
			end
		end
		if busy then
			last_pt[1], last_pt[2] = e.local_x, e.local_y
			hover_left(e.local_x, e.local_y)
			return
		end
		local key, x, y = to_screen(e.local_x, e.local_y)
		triggers_move(key, x, y, e.local_x, e.local_y)
		if not key then
			-- (over an overlay's backdrop: nothing under it is hovered)
			if not pressed then
				set_hover(nil, nil)
			end
			if cursor:peek() ~= "default" then
				cursor:set("default")
			end
			return
		end
		local link, d = Proto.hit(slot_data[key].root, x, y, shift_of(slot_data[key]))
		local c = if link then "pointer" else "default"
		if not link then
			for _, l in Proto.reactions_at(slot_data[key].root, x, y, shift_of(slot_data[key])) do
				local on = l.a.on
				if on == "press" or on == "mouseDown" or on == "mouseUp" or on == "drag" then
					c = "pointer"
					break
				end
			end
		end
		if cursor:peek() ~= c then
			cursor:set(c)
		end
		if not pressed then
			set_hover(key, if d and d.has.hover or (d and d.has.press) then d else nil)
		end
	end

	-- (F4-int) A click while a Change to gets ready (its look being fetched,
	-- or its motion not started yet) waits for it, then runs: none is dropped.
	-- One while its motion plays runs at once, the motion let go of (`let_go`).
	local held_input: { any } = {}
	local on_press_fn: (e: any) -> () = nil :: any
	local on_release_fn: (e: any) -> () = nil :: any
	local function pump_input()
		if #held_input == 0 then
			return
		end
		local r = smart_run
		local waiting = vpending > 0
		if r and r.change and not r.scrub and not r.landed then
			if not r.started or not r.let_go() then
				waiting = true
			end
		end
		if waiting and ui.now() - held_input[1].at < 1500 then
			ui.after(16, pump_input)
			return
		end
		local l = held_input
		held_input = {}
		for _, it in l do
			if it.kind == "press" then
				on_press_fn(it.e)
			else
				on_release_fn(it.e)
			end
		end
	end
	local function hold_input(kind: string, e: any)
		table.insert(held_input, { kind = kind, e = { local_x = e.local_x, local_y = e.local_y }, at = ui.now() })
		if #held_input == 1 then
			ui.after(16, pump_input)
		end
	end
	local function change_waits(): boolean
		if #held_input > 0 or vpending > 0 then
			return true
		end
		local r = smart_run
		if r and r.change and not r.scrub and not r.landed then
			return not r.let_go()
		end
		return false
	end

	local function on_press(e: any)
		if change_waits() then
			hold_input("press", e)
			return
		end
		if busy then
			return
		end
		do
			-- (a press stops a glide)
			local ck = current:peek()
			stop_glides(ck and slot_data[ck])
		end
		local key, x, y, outside = to_screen(e.local_x, e.local_y)
		if not key then
			-- (outside the top overlay: its release may close it)
			if outside then
				pressed = { outside = outside, lx = e.local_x, ly = e.local_y }
			end
			return
		end
		stop_glides(slot_data[key])
		local link, d = Proto.hit(slot_data[key].root, x, y, shift_of(slot_data[key]))
		pressed = { key = key, link = link, d = d, lx = e.local_x, ly = e.local_y }
		do
			local list = Proto.reactions_at(slot_data[key].root, x, y, shift_of(slot_data[key]))
			pressed.drag = Proto.first_on(list, "drag")
			local down = Proto.first_on(list, "mouseDown")
			local pr = Proto.first_on(list, "press")
			if pr then
				pressed.acted = true
				hold("press", pr, key, e.local_x, e.local_y)
			end
			if down then
				pressed.acted = true
				fire(down, down.a.ms)
			end
		end
		if d then
			set_hover(key, d)
			local st = slot_data[key].drivers[d.id]
			if st and d.has.press then
				st.press:set(true)
				st.scale:set(d.scale.press)
			end
		end
	end

	local function on_release(e: any)
		if #held_input > 0 then
			hold_input("release", e)
			return
		end
		local p = pressed
		pressed = nil
		if p and p.scrub then
			-- (step 3) a scrubbed smart transition: on from here, or back
			local sc = p.scrub
			sc.released = true
			if sc.play then
				return -- (it plays through on its own)
			end
			local n = #sc.samples
			if sc.run and n >= 2 then
				local last_s = sc.samples[n]
				local first_s = last_s
				for k = n, 1, -1 do
					if last_s[1] - sc.samples[k][1] <= 100 then
						first_s = sc.samples[k]
					end
				end
				local dt = last_s[1] - first_s[1]
				if dt > 0 then
					local p1 = scrub_p(sc, last_s[2], last_s[3])
					local p0 = scrub_p(sc, first_s[2], first_s[3])
					sc.vel = (p1 - p0) / dt * 100
				end
			end
			if sc.run then
				scrub_land(sc)
			end
			return
		end
		if held and held.kind == "press" then
			revert()
		end
		if p and p.sc then
			fling(p)
			return
		end
		if not p or busy then
			return
		end
		local key, x, y, outside = to_screen(e.local_x, e.local_y)
		if p.outside then
			-- (a click outside the top overlay closes it when it says so)
			local top = ov_stack[#ov_stack]
			if outside == p.outside and top == p.outside and slot_data[top] and slot_data[top].ov.co then
				close_top(nil)
			end
			return
		end
		if key then
			local up = Proto.first_on(Proto.reactions_at(slot_data[key].root, x, y, shift_of(slot_data[key])), "mouseUp")
			if up then
				p.acted = true
				fire(up, up.a.ms)
			end
		end
		local sd = p.key and slot_data[p.key]
		if sd and p.d then
			local st = sd.drivers[p.d.id]
			if st then
				st.press:set(false)
				st.scale:set(if hovered and hovered.d == p.d then p.d.scale.hover else 1)
			end
		end
		if not key or key ~= p.key then
			return
		end
		local link = Proto.hit(sd.root, x, y, shift_of(sd))
		if p.link and link and link.id == p.link.id then
			run(link)
		elseif not p.link and not p.acted and settings().hints then
			-- Nowhere to go: every link's spot flashes (Figma's hint; step 6
			-- P1: drawn once, then the hint element fades on the compositor,
			-- no Screen redrawn). Off with Options › Show hints on click.
			local rects = Proto.hotspots(sd.root, shift_of(sd))
			local at = ui.now()
			hint:set({ key = key, rects = rects, at = at })
			perf.hints += 1
			local el = sd.hint_el
			if el then
				pcall(function()
					-- (a misclick again restarts it at full strength)
					if sd.hint_anim then
						sd.hint_anim:cancel()
					end
					anime.utils.set(el, { opacity = 1 })
					sd.hint_anim = anime.animate(el, { opacity = { 1, 0 }, duration = hint_ms, ease = "inQuad" })
				end)
			end
			ui.after(hint_ms + 40, function()
				local h = hint:peek()
				if h and h.key == key and h.at == at then
					hint:set(nil)
				end
			end)
		end
	end

	-- Live edits: a Screen on show changed by an agent or the person draws
	-- again (its slot's `ver`).
	-- (step 6 P4) `spares`: false while edits come quickly in the Preview, so
	-- only the Screen on show (and its open overlays) draws again; the spares
	-- mounted ahead catch up once the edits stop.
	function dev.edited(spares: boolean)
		-- (V3: the Design's variables, at the start and after an edit)
		ui.after(0, load_vars)
		-- (step 6 P5: Responsive Screens edited are laid out again at the
		-- size shown; this runs again once they land)
		if dev.rz.on and dev.rz.k and dev.rz_refresh then
			dev.rz_refresh()
		end
		-- (step 4: a Screen whose variants were showing is resolved again)
		for id, v in vroots do
			if v.base ~= base_root(id) then
				ui.after(0, function()
					ensure_variants(id)
				end)
			end
		end
		local stale = false
		for key, sd in slot_data do
			local r = root_of(sd.id)
			-- (a Smart Animate base is its Screen less its movers: it's made again)
			if r and r ~= sd.root and not sd.smart and not (sd.spare and sd.change_of) then
				if sd.spare and not spares then
					stale = true
				else
					sd.root = r
					if sd.ver_state then
						sd.ver_state:set(sd.ver_state:peek() + 1)
					end
				end
			end
		end
		return stale
	end
	dev.edit = { rev = -1, last = -1e9, first = 0, due = false, stale = false, draws = 0 }
	-- (step 6 P4) The Preview's redraw of the Screen on show (its spares later)
	function dev.redraw()
		local e = dev.edit
		e.due = false
		e.draws += 1
		if dev.edited(false) then
			e.stale = true
		end
	end
	if dev.pre then
		-- (timers an effect starts go when it runs again, so the waits are
		-- `ui.debounced` states, owned by Play: 150 ms after the last edit the
		-- Screen on show, 400 ms after it the spares)
		dev.edit_n = ui.use_state(0)
		dev.rest = ui.debounced(dev.edit_n, 150)
		dev.calm = ui.debounced(dev.edit_n, 400)
		ui.effect(function()
			local _ = dev.rest:get()
			if dev.edit.due then
				dev.redraw()
			end
		end)
		ui.effect(function()
			local _ = dev.calm:get()
			if dev.edit.stale then
				dev.edit.stale = false
				dev.edited(true)
			end
		end)
	end
	ui.effect(function()
		local _ = roots:get()
		-- (a drag on the canvas writes `live` beside a root on every move: only
		-- a real edit, a new root, counts; step 6 P4)
		local rev = roots.rev
		if rev ~= nil and rev == dev.edit.rev then
			return
		end
		dev.edit.rev = rev or -1
		if not dev.pre then
			dev.edited(true)
			return
		end
		-- (step 6 P4) the Preview: an edit after a pause (300 ms) shows at once;
		-- during a run of edits (an arrow held, a slider dragged) it draws again
		-- once they pause for 150 ms, or every 400 ms while they go on. On a
		-- heavy Screen each redraw is a full raster beside the board's, so
		-- once per edit would double the editor's cost (film: pure/anim/f6/p4).
		-- The spares mounted ahead catch up 400 ms after the last edit.
		local e = dev.edit
		local now = ui.now()
		local idle = now - e.last >= 300
		e.last = now
		if idle and not e.due then
			-- (two frames on: not in the frame the board draws the edit in. If
			-- another edit comes first this timer goes, and `rest` draws it)
			e.due, e.first = true, now
			ui.after(34, function()
				if e.due then
					dev.redraw()
				end
			end)
		elseif not e.due then
			e.due, e.first = true, now
		elseif now - e.first >= 400 then
			dev.redraw()
		end
		dev.edit_n:set(dev.edit_n:peek() + 1)
	end)

	on_press_fn, on_release_fn = on_press, on_release

	-- One driver lifted out of its Screen: its three looks, stacked.
	-- (`org`: the Canvas point its layer's element starts at; the Screen's
	-- top-left unless it's in a scroller, a fixed or a sticky layer)
	local function Driver(o: { key: string, d: any, root: any, pl: any, org: any? }): Node
		local d, pl = o.d, o.pl
		local org = o.org or pl.b
		local hover = ui.use_state(false)
		local press = ui.use_state(false)
		local scale = ui.use_state(1)
		local sd = slot_data[o.key]
		if sd then
			sd.drivers[d.id] = { hover = hover, press = press, scale = scale }
		end
		local ext = Proto.extent(o.root, d)
		local db = o.root.nodes[d.i].box
		local z = pl.z
		local tw = { duration = math.max(1, d.tr.ms or 150), ease = Proto.ease_of(d.tr) }
		local function look(which: string?): Node
			local sub = Proto.subtree(o.root, d, which)
			-- (GIFs in a look play over it, followups README)
			local gl = PlayGifs.layer(sub, nil)
			local opacity = if which == "hover" then ui.tween(hover, tw) elseif which == "press" then ui.tween(press, tw) else nil
			local cv = ui.canvas {
				id = `play-{d.id}-{which or "rest"}`,
				absolute = true,
				left = 0,
				top = 0,
				w = ext[3] * z,
				h = ext[4] * z,
				pointer_events = "none",
				opacity = if gl.any then nil else opacity,
				view = function(): any
					return { x = -ext[1] * z, y = -ext[2] * z, zoom = z }
				end,
				draw = function(c: Canvas)
					local _ = gl.ver:get()
					Draw.draw_root(c, sub, if gl.ids then { gifs = gl.ids } else nil)
				end,
			}
			return PlayGifs.look(cv, gl, `{d.id}-{which or "rest"}`, { x = ext[1], y = ext[2] }, z, sub, ext, opacity)
		end
		local kids: any = {
			absolute = true,
			left = (ext[1] - org.x) * z,
			top = (ext[2] - org.y) * z,
			w = ext[3] * z,
			h = ext[4] * z,
			pointer_events = "none",
			origin = { (db.x + db.w / 2 - ext[1]) / ext[3], (db.y + db.h / 2 - ext[2]) / ext[4] },
			scale = ui.tween(scale, tw),
			look(nil),
		}
		if d.has.hover then
			table.insert(kids, look("hover"))
		end
		if d.has.press then
			table.insert(kids, look("press"))
		end
		return ui.div(kids)
	end

	-- One layer of a Screen (F2a, tab/scroll.luau): its canvas, drawn once
	-- with what other layers and the lifted drivers hold left out, its
	-- drivers, and the layers inside it. A scroller's content moves by the
	-- scroller's offset (element x/y, on the compositor); a fixed layer sits
	-- over it, still; a sticky one moves with it and is pushed to stay at
	-- its top. `host_org`: the Canvas point the element around starts at.
	local Layer: any
	local function layer_org(sd: any, plan: any, li: number): any
		local l = plan.layers[li]
		local it = sd.root.nodes[l.i]
		if l.k == "content" then
			local w, h = it.box.w, it.box.h
			if l.i ~= 1 and it.cx then
				w, h = math.max(w, it.cx.w), math.max(h, it.cx.h)
			end
			-- (an overlay's own shadow draws past its box: its slot grows by it)
			local p = if l.i == 1 then (sd.ov_pad or 0) else 0
			return { x = it.box.x - p, y = it.box.y - p, w = w + 2 * p, h = h + 2 * p }
		end
		local ext = Proto.extent(sd.root, { i = l.i, n = it.n or 0, entries = {} })
		return { x = ext[1], y = ext[2], w = ext[3], h = ext[4] }
	end
	Layer = function(o: { key: string, li: number, pl: any, host_org: any }): Node
		local sd = slot_data[o.key]
		if not sd then
			return ui.div {}
		end
		local plan = plan_of(sd)
		local pl, li = o.pl, o.li
		local z = pl.z
		local l = plan.layers[li]
		local it = sd.root.nodes[l.i]
		local org = layer_org(sd, plan, li)
		do
			-- (whole points on the stage: an element at a fraction of a point
			-- is resampled, and its edge row lets what's under it through)
			local fx = (org.x - o.host_org.x) * z
			local fy = (org.y - o.host_org.y) * z
			local dx, dy = fx - math.floor(fx), fy - math.floor(fy)
			if dx > 1e-6 or dy > 1e-6 then
				org = { x = org.x - dx / z, y = org.y - dy / z, w = org.w + dx / z, h = org.h + dy / z }
			end
		end
		local hide = plan.hide[li]
		local ver = sd.ver_state
		-- (GIF layers) the GIFs that play in this layer, left out of its canvas;
		-- one whose picture decodes later is added then (`gl`, followups)
		local lroot = Scroll.layer_root(plan, li)
		sd.gifs = sd.gifs or {}
		local gl = PlayGifs.layer(lroot, hide, function(n: number)
			sd.gifs[li] = n
		end)
		local px, py
		if l.k == "content" then
			local x0, y0 = pos_of(sd, l.i)
			px, py = ui.use_state(x0), ui.use_state(y0)
			sd.pos = sd.pos or {}
			sd.pos[l.i] = { x = px, y = py }
		end
		local kids: any = {
			ui.canvas {
				id = `play-layer-{sd.id}-{li}`,
				absolute = true,
				left = 0,
				top = 0,
				w = org.w * z,
				h = org.h * z,
				pointer_events = "none",
				view = function(): any
					return { x = -org.x * z, y = -org.y * z, zoom = z }
				end,
				draw = function(c: Canvas)
					local _ = ver and ver:get()
					local _ = gl.ver:get()
					local t0 = os.clock()
					local now = plan_of(sd)
					Draw.draw_root(c, Scroll.layer_root(now, li), { hide = now.hide[li] or hide, gifs = gl.ids })
					table.insert(perf.draw, (os.clock() - t0) * 1000)
					if #perf.draw > 200 then
						table.remove(perf.draw, 1)
					end
				end,
			},
		}
		PlayGifs.add(kids, gl, sd.id, org, z, lroot, hide)
		for lj, lay in plan.layers do
			if lay.host == li and not (lay.k == "fixed" and lay.inside) then
				table.insert(kids, ui.component(Layer)({ key = o.key, li = lj, pl = pl, host_org = org }))
			end
		end
		local count = 0
		for _, d in Proto.of_root(sd.root).drivers do
			if plan.drivers[d.id] and plan.owner[d.i] == li and count < 60 then
				count += 1
				table.insert(kids, ui.component(Driver)({ key = o.key, d = d, root = sd.root, pl = pl, org = org }))
			end
		end
		local left, top = (org.x - o.host_org.x) * z, (org.y - o.host_org.y) * z
		if l.k == "content" then
			kids.absolute = true
			kids.w = org.w * z
			kids.h = org.h * z
			kids.pointer_events = "none"
			kids.x = function(): number
				return -px:get() * z
			end
			kids.y = function(): number
				return -py:get() * z
			end
			if l.i == 1 then
				kids.id = `play-content-{sd.id}`
				kids.left, kids.top = left, top
				return ui.div(kids)
			end
			kids.left, kids.top = 0, 0
			-- the scroller: its box clips; its fixed layers sit over the content
			local frame: any = {
				id = `play-scroller-{it.id}`,
				absolute = true,
				left = left,
				top = top,
				w = it.box.w * z,
				h = it.box.h * z,
				overflow = "hidden",
				pointer_events = "none",
				ui.div(kids),
			}
			for lj, lay in plan.layers do
				if lay.k == "fixed" and lay.inside and lay.s == l.i then
					table.insert(frame, ui.component(Layer)({ key = o.key, li = lj, pl = pl, host_org = { x = it.box.x, y = it.box.y } }))
				end
			end
			return ui.div(frame)
		end
		kids.id = `play-{l.k}-{it.id}`
		kids.absolute = true
		kids.left = left
		kids.top = top
		kids.w = org.w * z
		kids.h = org.h * z
		kids.pointer_events = "none"
		if l.k == "sticky" then
			local sp = sd.pos and sd.pos[l.s]
			kids.y = function(): number
				local y = if sp then sp.y:get() else 0
				return Scroll.sticky_push(plan, l.i, y) * z
			end
		end
		return ui.div(kids)
	end

	-- One Screen: its layers (the Screen's content, which scrolls in the
	-- viewport, and its fixed layers over it) and the hotspot flash.
	local function Screen(slot: any): Node
		local key = slot.key
		local sd = slot_data[key]
		if not sd then
			return ui.div {}
		end
		local ver = ui.use_state(0)
		sd.ver_state = ver
		if sd.patch then
			-- (F4-perf) a Change to's base as a patch: one canvas the size of
			-- the part that changes, where it shows on the Screen (scrolled as
			-- the Screen is), so its raster is small and made on the frame
			local pl = place(sd.root)
			sd.place = pl
			local R, z, b = sd.patch, pl.z, pl.b
			local sx, sy = pos_of(sd, 1)
			-- (whole pixels on the stage, outward)
			local l0, t0 = math.floor((R.x - b.x - sx) * z), math.floor((R.y - b.y - sy) * z)
			local l1, t1 = math.ceil((R.x + R.w - b.x - sx) * z), math.ceil((R.y + R.h - b.y - sy) * z)
			local vx, vy = (b.x + sx) * z + l0, (b.y + sy) * z + t0
			return ui.div {
				id = `play-slot-{key}`,
				absolute = true,
				left = function(): number
					return pl.left - vp:get().left
				end,
				top = function(): number
					return pl.top - vp:get().top
				end,
				w = pl.w,
				h = pl.h,
				overflow = "hidden",
				pointer_events = "none",
				opacity = if sd.spare then 0.002 else 1,
				z = function(): number
					return zs:get()[key] or 0
				end,
				on_mount = function(el: any)
					sd.el = el
					ui.after(16, function()
						sd.ready = true
					end)
				end,
				ui.canvas {
					id = `play-patch-{key}`,
					absolute = true,
					left = l0,
					top = t0,
					w = l1 - l0,
					h = t1 - t0,
					pointer_events = "none",
					view = function(): any
					return { x = -vx, y = -vy, zoom = z }
				end,
					draw = function(c: Canvas)
						local t = os.clock()
						-- (V3: only what reaches the patch is drawn: on a heavy
						-- Screen walking every item was most of the frame)
						sd.culled = sd.culled or cull_outside(sd.root, R)
						Draw.draw_root(c, sd.culled)
						table.insert(perf.draw, (os.clock() - t) * 1000)
						if #perf.draw > 200 then
							table.remove(perf.draw, 1)
						end
					end,
				},
			}
		end
		-- (an overlay: in the shown Screen's viewport, per its position)
		local pl = if sd.ov then ov_place(sd) else place(sd.root)
		sd.place = pl
		local plan = plan_of(sd)
		-- (an overlay that doesn't scroll: room for its root's shadow around it)
		local pad = 0
		if sd.ov and not pl.tall then
			local ext = Proto.extent(sd.root, { i = 1, n = 0, entries = {} })
			pad = math.max(0, math.ceil(math.max(pl.b.x - ext[1], pl.b.y - ext[2], ext[1] + ext[3] - pl.b.x - pl.b.w, ext[2] + ext[4] - pl.b.y - pl.b.h) - 2))
		end
		sd.ov_pad = pad
		local pz = pad * pl.z
		local layer: any = {
			absolute = true,
			left = pz,
			top = pz,
			w = pl.w,
			h = pl.h,
			ui.component(Layer)({ key = key, li = 1, pl = pl, host_org = pl.b }),
		}
		for lj, lay in plan.layers do
			if lay.k == "fixed" and lay.host == nil then
				table.insert(layer, ui.component(Layer)({ key = key, li = lj, pl = pl, host_org = pl.b }))
			end
		end
		-- The "where can I click" flash (its spots as shown, scrolled).
		table.insert(
			layer,
			ui.canvas {
				absolute = true,
				left = 0,
				top = 0,
				w = pl.w,
				h = pl.h,
				pointer_events = "none",
				opacity = 0,
				on_mount = function(el: any)
					sd.hint_el = el
				end,
				draw = function(c: Canvas)
					local h = hint:get()
					if not h or h.key ~= key then
						return
					end
					-- (Figma's light blue at 85% and a 1.5 px outline inside the
					-- spot, square as the hotspot is: step 6 P6)
					for _, r in h.rects do
						local x, y = (r[1] - pl.b.x) * pl.z, (r[2] - pl.b.y) * pl.z
						local w, hh = r[3] * pl.z, r[4] * pl.z
						c:rect(x, y, w, hh, HINT_FILL)
						c:stroke(ui.path():rect(x + 0.75, y + 0.75, math.max(0, w - 1.5), math.max(0, hh - 1.5)), HINT_BLUE, 1.5)
					end
				end,
			}
		)
		return ui.div {
			id = `play-slot-{key}`,
			absolute = true,
			-- (inside the viewport, which is at a Screen's place on the stage)
			left = function(): number
				-- (an overlay moves when it opens at another trigger)
				local at = sd.ov and ov_at:get()[key]
				return (if at then at.left else pl.left) - vp:get().left - pz
			end,
			top = function(): number
				local at = sd.ov and ov_at:get()[key]
				return (if at then at.top else pl.top) - vp:get().top - pz
			end,
			w = pl.w + 2 * pz,
			h = pl.h + 2 * pz,
			overflow = "hidden",
			pointer_events = "none",
			-- (a spare waits under the shown one, all but invisible: drawn, so
			-- its raster is ready when a link brings it in; an overlay's spare
			-- is over the Screen, so fainter still: it rounds to nothing)
			opacity = if sd.spare then (if sd.ov then OV_SPARE else 0.002) else 1,
			z = function(): number
				return zs:get()[key] or 0
			end,
			on_mount = function(el: any)
				sd.el = el
				-- (V3: a variable's new look shows as soon as it's drawn)
				ui.after(if sd.vnext then 48 elseif sd.spare then 120 else 0, function()
					sd.ready = true
				end)
			end,
			ui.div(layer),
		}
	end

	-- One overlay slot (step 2): its backdrop over the Screen's viewport (its
	-- colour, faded in and out on the compositor), then its Screen-like slot.
	local function OverlayView(o: any): Node
		local key = o.key
		local sd = slot_data[key]
		if not sd or not sd.ov then
			return ui.div {}
		end
		local cur = current:peek()
		local bp = (cur and slot_data[cur] and slot_data[cur].place) or { left = 0, top = 0, w = 0, h = 0 }
		sd.ov.bp = bp
		return ui.div {
			id = `play-ov-{key}`,
			absolute = true,
			left = 0,
			top = 0,
			w = function(): number
				return vp:get().w
			end,
			h = function(): number
				return vp:get().h
			end,
			pointer_events = "none",
			ui.div {
				id = `play-ov-bg-{key}`,
				absolute = true,
				left = function(): number
					return bp.left - vp:get().left
				end,
				top = function(): number
					return bp.top - vp:get().top
				end,
				w = bp.w,
				h = bp.h,
				bg = sd.ov.bg or "#00000000",
				opacity = 0,
				pointer_events = "none",
				on_mount = function(el: any)
					sd.bd_el = el
				end,
			},
			ui.component(Screen)({ key = key, screen = sd.id }),
		}
	end

	-- Start: the first Screen.
	local started = false
	ui.effect(function()
		local s = stage:get()
		if started or s.w <= 0 then
			return
		end
		started = true
		local function first()
			if current:peek() then
				return
			end
			local start = dev.cur:peek().start
			local key = add_slot(start, false)
			if key then
				show(key)
			else
				say(`play: no Screen {start}`)
			end
		end
		-- (step 6 P5) Responsive: the first Screen waits for its size's
		-- layout (at most 1.5 s), so it doesn't show as designed first
		dev.rz_sync()
		if dev.rz.on and source.sized_roots then
			dev.rz_fetch(nil, first)
			ui.after(1500, first)
		else
			first()
		end
	end)

	-- (step 6 P1) The scaling changed (Options, Z, the Design's device) or the
	-- stage did (Hide UI, a window resize): the shown Screen mounts again at
	-- its new place, in a fresh slot under the old one, shown once it's drawn
	-- (so no blank frame). Overlays close and the spares mounted ahead for the
	-- old place go (show() mounts them again). It waits while a transition,
	-- a press or a variable swap is running.
	local relayout_due = false
	local function relayout()
		relayout_due = false
		local cur = current:peek()
		local sd = cur and slot_data[cur]
		if not cur or not sd or not sd.place or sd.patch then
			return
		end
		if busy or coast or pressed or vpending > 0 or next(vveil) ~= nil then
			relayout_due = true
			ui.after(100, function()
				if relayout_due then
					relayout()
				end
			end)
			return
		end
		-- (step 6 P5) Responsive: the new size's Screens first, and the shown
		-- one's variants and variables at that size; this runs again then
		if dev.rz_gate(sd) then
			return
		end
		local r = root_of(sd.id) or sd.root
		local np, op = place(r), sd.place
		if r == sd.root and np.z == op.z and np.left == op.left and np.top == op.top and np.w == op.w and np.h == op.h then
			return
		end
		close_all()
		for _, o in table.clone(ovs:peek()) do
			drop_ov(o.key)
		end
		local bk = {}
		for k in smart_bases do
			table.insert(bk, k)
		end
		for _, k in bk do
			drop_bases(k)
		end
		for _, s in table.clone(slots:peek()) do
			if s.key ~= cur then
				drop_slot(s.key)
			end
		end
		made += 1
		local key = `s{made}`
		slot_data[key] = { id = sd.id, root = r, ver = 0, drivers = {}, spare = true, mounted_at = ui.now() }
		set_z(key, -1)
		slots:push({ key = key, id = sd.id })
		sync_scroll(key)
		local t0 = ui.now()
		local function land()
			local nd = slot_data[key]
			if not nd then
				return
			end
			if current:peek() ~= cur or not slot_data[cur] then
				-- (it went elsewhere meanwhile: that Screen was placed anew)
				drop_slot(key)
				return
			end
			if (not nd.ready or busy or pressed) and ui.now() - t0 < 1500 then
				ui.after(16, land)
				return
			end
			rest(cur)
			hovered = nil
			drop_slot(cur)
			show(key)
			perf.relayouts += 1
		end
		ui.after(16, land)
	end

	-- ── (step 6 P5) Responsive ───────────────────────────────────────────
	-- `dev.rz` (above, by base_root). Responsive turned on or off: off forgets
	-- the sized Screens (the Design's come back).
	function dev.rz_sync()
		local rz = dev.rz
		local on = settings().responsive == true
		if on ~= rz.on then
			rz.on = on
			if not on then
				rz.roots, rz.k, rz.want = {}, nil, nil
				rz.fgen += 1
			end
		end
	end
	-- The frames played as Screens: not Components or variant sets, and not
	-- a frame only ever opened as an overlay (an overlay keeps its size).
	function dev.rz_ids(): { string }
		local nav, ovl = {}, {}
		local function walk(acts: any)
			for _, a in (if type(acts) == "table" then acts else {}) do
				if type(a) == "table" then
					if (a.k == "overlay" or a.k == "swap") and a.go then
						ovl[a.go] = true
					elseif a.k == "navigate" and a.go then
						nav[a.go] = true
					elseif a.k == "if" then
						walk(a.th)
						walk(a.el)
					end
				end
			end
		end
		local list = roots:peek()
		for _, r in list do
			for _, it in r.nodes or {} do
				for _, l in it.ia or {} do
					walk(l.acts)
				end
			end
		end
		local out = {}
		for _, r in list do
			local n = r.nodes and r.nodes[1]
			if n and n.t == "frame" and n.box and not n.comp and not n.vset and (nav[r.id] or not ovl[r.id]) then
				table.insert(out, r.id)
			end
		end
		return out
	end
	-- Fetches the Screens at the size Responsive gives now: all of them
	-- (`only` nil, or a new size), else just `only` (edited) at the size
	-- shown. A whole size lands at once and the shown Screen is placed anew
	-- (or `after` runs: the first Screen); an edited one draws as an edit.
	function dev.rz_fetch(only: { string }?, after: (() -> ())?)
		local rz = dev.rz
		local s = stage:peek()
		local w, h = PlayPlace.responsive_size(s.w, s.h, device(), settings())
		if not w or not h or not source.sized_roots then
			if after then
				after()
			end
			return
		end
		local k = `{w}x{h}`
		local full = only == nil or k ~= rz.k
		local ids = if full then dev.rz_ids() else only :: { string }
		if #ids == 0 then
			-- (no Screens: an empty ask would be read as "all roots")
			if full then
				rz.roots, rz.k, rz.w, rz.h, rz.want = {}, k, w, h, nil
			end
			if after then
				after()
			end
			return
		end
		local srcs: { [string]: any } = {}
		for _, id in ids do
			srcs[id] = dev.root0(id)
		end
		local g = rz.fgen
		if full then
			rz.fgen += 1
			g = rz.fgen
			rz.want = k
		end
		rz.pending += 1
		rz.fetches += 1
		local t0 = os.clock()
		source.sized_roots(ids, { w = w, h = h }, function(list: { any }?)
			rz.pending -= 1
			if full and rz.fgen ~= g then
				return -- (a newer size, or Responsive off, took over)
			end
			if not full and rz.k ~= k then
				return
			end
			local got: { [string]: any } = {}
			for _, r in (list or {}) :: { any } do
				got[r.id] = { root = r, src = srcs[r.id] }
			end
			-- (one that didn't come stays as designed, not asked for again)
			for _, id in ids do
				if not got[id] and srcs[id] then
					got[id] = { root = srcs[id], src = srcs[id] }
				end
			end
			if full then
				rz.roots, rz.k, rz.w, rz.h, rz.want = got, k, w, h, nil
				rz.ms = (os.clock() - t0) * 1000
				if after then
					after()
				else
					relayout()
				end
			else
				for id, e in got do
					rz.roots[id] = e
				end
				dev.edited(true)
			end
		end)
	end
	-- Edited Screens (or new ones) laid out again at the size shown.
	function dev.rz_refresh()
		local rz = dev.rz
		local stale = {}
		for _, id in dev.rz_ids() do
			local e = rz.roots[id]
			if not e or e.src ~= dev.root0(id) then
				table.insert(stale, id)
			end
		end
		if #stale > 0 then
			dev.rz_fetch(stale)
		end
	end
	-- relayout()'s gate: true while it must wait (this size's Screens being
	-- fetched, or the shown Screen's look at its new base), then it runs again.
	function dev.rz_gate(sd: any): boolean
		local rz = dev.rz
		dev.rz_sync()
		if rz.on then
			local s = stage:peek()
			local w, h = PlayPlace.responsive_size(s.w, s.h, device(), settings())
			if w and h and `{w}x{h}` ~= rz.k then
				if rz.want ~= `{w}x{h}` then
					dev.rz_fetch(nil)
				end
				return true
			end
		end
		-- (its variants and variables, as they were, at the new base)
		local id = sd.id
		local v = vroots[id]
		local b = base_root(id)
		if v and b and v.base ~= b then
			if rz.vfix == id then
				return true
			end
			rz.vfix = id
			vpending += 1
			fetch_variant(id, v.vmap, function(r: any?)
				vpending -= 1
				rz.vfix = nil
				if vroots[id] == v then
					vroots[id] = if r then { base = b, vmap = v.vmap, root = r, rs = rsig_of(id) } else nil
				end
				relayout()
			end)
			return true
		end
		return false
	end

	-- The session's choice: `patch` over it (kept per Design), then placed anew.
	local function choose(patch: { [string]: any })
		local s = table.clone(sess:peek() or {})
		for k, v in patch do
			s[k] = v
		end
		sess:set(s)
		relayout()
	end
	-- Z: the next of the menu's scaling choices (round).
	local function cycle_fit(): string
		local st = settings()
		local list, cur = PlayPlace.choices(st)
		local nx = PlayPlace.cycle(list, cur)
		choose(if st.framed then { dfit = nx } else { fit = nx })
		-- (step 6 P6) Figma's toast at the device's bottom left, each time Z
		-- changes the scale: "Device scale: Actual size (100%)"
		for _, c in list do
			if c.name == nx then
				dev.say_scale(`Device scale: {c.label}`)
			end
		end
		return nx
	end
	-- (step 6 P6) The display's scale: a snapshot of the 32-point probe is
	-- 32 × scale pixels wide (the window's zoom counted too). Tried for a
	-- second (the window may not have shown it yet); a new scale places the
	-- Screen anew under the new cap.
	function dev.measure_scale(el: any, tries: number)
		ui.after(if tries == 0 then 50 else 100, function()
			if dev.scale_measured or dev.scale_why == "set" or not el.mounted then
				return
			end
			local ok, w = pcall(function(): number?
				local src = el:snapshot(1024)
				local pw = el.width
				if not (src and pw and pw > 0) then
					dev.scale_why = if src then "no width" else "no snapshot"
					return nil
				end
				local iw = ui.image_size(src)
				dev.scale_why = if iw then "ok" else `no size ({string.sub(src, 1, 24)})`
				return if iw then iw / pw else nil
			end)
			if not ok then
				dev.scale_why = tostring(w)
			end
			if ok and w and w >= 0.5 and w <= 8 then
				dev.scale_measured = true
				local s = math.floor(w * 4 + 0.5) / 4 -- (to a quarter: 1, 1.25, 1.5 …)
				say(`Play: display scale {s}`)
				if math.abs(s - dev.scale) > 0.01 then
					dev.scale = s
					if started then
						relayout()
					end
				end
			elseif tries < 10 then
				dev.measure_scale(el, tries + 1)
			end
		end)
	end
	-- (step 6 P6) The scale toast: one at a time, gone after 1.5 s.
	dev.toast = ui.use_state({} :: { any })
	dev.toast_n = 0
	function dev.say_scale(text: string)
		dev.toast_n += 1
		local n = dev.toast_n
		dev.toast_text = text
		dev.toast:set({ { n = n, text = text } })
		ui.after(1500, function()
			local t = dev.toast:peek()
			if t[1] and t[1].n == n then
				dev.toast:set({})
			end
		end)
	end
	local function toggle_ui()
		hide_ui:set(not hide_ui:peek())
	end
	-- (step 6 P3) The flows sidebar: shown when the viewer opened it (or, by
	-- default, with 2+ flows), there are flows, and the UI isn't hidden. `get`:
	-- read the states tracked (a reactive prop) or not (a handler).
	function dev.side_on(get: boolean?): boolean
		if dev.pre then
			return false -- (step 6 P4: the Preview has no sidebar)
		end
		local fl = if source.flows then (if get then source.flows:get() else source.flows:peek()) or {} else {}
		local saved = if get then dev.side:get() else dev.side:peek()
		return #fl > 0 and PlayFlows.open(type(saved) == "table" and saved.open, #fl)
	end
	function dev.side_toggle()
		-- (placed anew at once, not after the resize's debounce)
		dev.side_now = true
		dev.side:set({ open = not dev.side_on() })
	end
	-- (step 7) Local comments: comment mode (C), pins, the sidebar on the
	-- right (tab/comments_ui.luau; in `dev` for the locals limit). Not in the
	-- inline Preview.
	dev.cm = if dev.pre then nil else CommentsUI.play({
		D = D,
		L = L,
		source = source,
		current = current,
		slot = function(key: string): any
			return slot_data[key]
		end,
		overlays = function(): { string }
			local out = {}
			for _, k in ov_stack do
				local od = slot_data[k]
				if od and not od.spare then
					table.insert(out, k)
				end
			end
			return out
		end,
		to_screen = to_screen,
		shift_of = shift_of,
		deepest = Proto.deepest,
		go = function(id: string)
			if not busy and root_of(id) then
				go_to(id, nil, false)
			end
		end,
		hidden = function(): boolean
			return hide_ui:get()
		end,
		stage = function(): any
			return stage:get()
		end,
		stage_v = function(): any
			return vp:get()
		end,
		resized = function()
			dev.side_now = true
		end,
		focus = function()
			if dev.root_el then
				dev.root_el:focus()
			end
		end,
	})
	-- (the Design's device edited while playing: placed anew)
	ui.effect(function()
		local _ = source.device and source.device:get()
		if started then
			ui.after(0, relayout)
		end
	end)
	local resize_at = 0
	local function stage_resized()
		if not started then
			return
		end
		if dev.side_now then
			-- (the flows sidebar opened or closed: one resize, placed anew now)
			dev.side_now = false
			resize_at = ui.now()
			relayout()
			return
		end
		-- (debounced: a window drag sends many)
		local at = ui.now()
		resize_at = at
		ui.after(150, function()
			if resize_at == at then
				relayout()
			end
		end)
	end

	if props.expose then
		props.expose({
			back = back,
			restart = restart,
			perf = perf,
			-- (step 6 P1) → , Z, the session's choices, Hide UI, the hint
			next = next_screen,
			cycle_fit = cycle_fit,
			choose = choose,
			toggle_ui = toggle_ui,
			-- (step 6 P3) the flows sidebar: open, the playing flow, picking one
			toggle_flows = dev.side_toggle,
			pick_flow = dev.pick,
			-- (step 6 P4) the Preview: jump to a Screen; its state; the menu
			jump = dev.jump,
			preview = function(): any
				local s = sess:peek() or {}
				local st = settings()
				return { on = dev.pre, follow = s.follow == true, fit = st.fit, framed = st.framed, edits = dev.edit.draws, stage_w = stage:peek().w, stage_h = stage:peek().h }
			end,
			pre_menu = function(what: string)
				if dev.pre_do then
					dev.pre_do(what)
				end
			end,
			focused_keys = function(k: any): boolean?
				return dev.on_key and dev.on_key(k)
			end,
			flows = function(): any
				local fl = dev.flows()
				local c = dev.cur:peek()
				local i = PlayFlows.current(fl, c.start, c.flow)
				return { open = dev.side_on(), n = #fl, cur = i, start = c.start, flow = c.flow, stage_w = stage:peek().w, desc = i and fl[i].description or "" }
			end,
			forward = function(): number
				return #forward
			end,
			-- (step 7) comment mode, the card open, the pins as placed on the stage
			comments = function(): any
				return if dev.cm then dev.cm.state() else nil
			end,
			-- (for tests) a press on the stage at (x, y), as comment mode takes it
			comment_press = function(x: number, y: number): boolean
				return dev.cm ~= nil and dev.cm.press({ local_x = x, local_y = y })
			end,
			-- (step 6 P5) Responsive: on, the size laid out, the size being
			-- fetched, Screens held at it, fetches so far, still pending
			responsive = function(): any
				local rz = dev.rz
				local n = 0
				for _ in rz.roots do
					n += 1
				end
				return { on = rz.on, k = rz.k or "-", want = rz.want or "-", n = n, fetches = rz.fetches, pending = rz.pending, ms = rz.ms or 0 }
			end,
			options = function(): any
				local st = settings()
				local _, cur = PlayPlace.choices(st)
				-- (step 6 P6) Z's toast on show ("" when none) and the bar's "1 / N"
				local t = dev.toast:peek()[1]
				return { fit = st.fit, dfit = st.dfit, framed = st.framed, hints = st.hints, choice = cur, hidden = hide_ui:peek(), relayouts = perf.relayouts, hints_shown = perf.hints, toast = if t then t.text else "", counter = dev.counter(), cap = { px = dev.cap.px, n = dev.cap.n, scale = dev.scale, measured = dev.scale_measured or dev.scale_why } }
			end,
			-- (step 6 P2) the frame drawn: its box on the stage (frame and all),
			-- how many canvases, how many draws so far (drawn once per size)
			device_frame = function(): any
				local d = dev.pl:peek()
				local f = d and DeviceFrame.shapes(d.frame, d.vw, d.vh, d.rotate, d.model)
				if not (d and f) then
					return { on = false, draws = perf.frame_draws }
				end
				local parts = PlayPlace.frame_parts(f, d, d.sw, d.sh)
				local i = f.inset
				return {
					on = true,
					kind = d.frame,
					model = d.model,
					rotate = d.rotate,
					color = f.color,
					left = math.floor(d.left - i[1] * d.z + 0.5),
					top = math.floor(d.top - i[2] * d.z + 0.5),
					w = math.floor((f.w + i[1] + i[3]) * d.z + 0.5),
					h = math.floor((f.h + i[2] + i[4]) * d.z + 0.5),
					parts = #parts.body + #parts.over,
					draws = perf.frame_draws,
				}
			end,
			-- the hint on show: how many spots, how long ago (ms), whether its
			-- element is mounted (the fade is on it)
			hint = function(): any
				local h = hint:peek()
				local sd = h and slot_data[h.key]
				return { on = h ~= nil, n = if h then #h.rects else 0, age = if h then ui.now() - h.at else -1, el = sd ~= nil and sd.hint_el ~= nil }
			end,
			-- (tests) the fade's length, ms (nil: Figma's, HINT_MS)
			hint_ms = function(ms: number?)
				hint_ms = ms or HINT_MS
			end,
			-- (for benches and tests: what a click or a hover would do)
			go = function(id: string, tr: any?)
				go_to(id, tr, false)
			end,
			hover = function(driver: string?, press: boolean?)
				local key = current:peek()
				local sd = key and slot_data[key]
				if not sd then
					return
				end
				local d = if driver then Proto.of_root(sd.root).by_driver[driver] else nil
				set_hover(if d then key else nil, d)
				local st = d and sd.drivers[d.id]
				if st then
					st.press:set(press == true)
					st.scale:set(if press then d.scale.press else d.scale.hover)
				end
			end,
			busy = function(): boolean
				return busy
			end,
			slots = function(): number
				return #slots:peek()
			end,
			current = function(): string?
				local k = current:peek()
				return if k and slot_data[k] then slot_data[k].id else nil
			end,
			history = function(): number
				return #history
			end,
			hovered = function(): string?
				return if hovered then hovered.d.id else nil
			end,
			-- (F2a, scrolling) a scroller of the shown Screen (its id; nil: the
			-- Screen): where it is, how far it goes, and setting it
			scroll_of = function(id: string?): (number, number, number, number)
				local key = current:peek()
				local sd = key and slot_data[key]
				if not sd then
					return 0, 0, 0, 0
				end
				local s = if id then plan_of(sd).at[id] else 1
				if not s then
					return 0, 0, 0, 0
				end
				local x, y = pos_of(sd, s)
				local mx, my = room_of(sd, s)
				return x, y, mx, my
			end,
			-- the shown Screen's lifted layers: { { id, name, k } } (fixed, sticky)
			layers = function(): { any }
				local key = current:peek()
				local sd = key and slot_data[key]
				local out = {}
				if sd then
					for _, l in plan_of(sd).layers do
						if l.k ~= "content" then
							local it = sd.root.nodes[l.i]
							table.insert(out, { id = it.id, name = it.name, k = l.k })
						end
					end
				end
				return out
			end,
			-- every scroller of the shown Screen: { { id, name, x, y, mx, my } }
			scrollers = function(): { any }
				local key = current:peek()
				local sd = key and slot_data[key]
				local out = {}
				if sd then
					local plan = plan_of(sd)
					for _, s in plan.scrollers do
						local x, y = pos_of(sd, s)
						local mx, my = room_of(sd, s)
						local it = sd.root.nodes[s]
						table.insert(out, { id = it.id, name = it.name, x = x, y = y, mx = mx, my = my })
					end
				end
				return out
			end,
			scroll_set = function(id: string?, x: number, y: number)
				local key = current:peek()
				local sd = key and slot_data[key]
				local s = sd and (if id then plan_of(sd).at[id] else 1)
				if sd and s then
					set_pos(sd, s, x, y)
				end
			end,
			-- a wheel at stage point (lx, ly), in points, as the stage gets it
			wheel = function(lx: number, ly: number, dx: number, dy: number)
				-- (an overlay under the point takes it, as the stage's wheel)
				local key, x, y = to_screen(lx, ly)
				local sd = key and slot_data[key]
				if sd and sd.place then
					scroll_by(sd, x, y, dx / sd.place.z, dy / sd.place.z)
				end
			end,
			-- a drag from (x0, y0) to (x1, y1) over `ms` in `steps`, then let go
			drag = function(x0: number, y0: number, x1: number, y1: number, steps: number?)
				on_press({ local_x = x0, local_y = y0 })
				local n = steps or 6
				for k = 1, n do
					local t = k / n
					on_move({ local_x = x0 + (x1 - x0) * t, local_y = y0 + (y1 - y0) * t })
				end
				on_release({ local_x = x1, local_y = y1 })
			end,
			place = function(): any
				local key = current:peek()
				local sd = key and slot_data[key]
				return sd and sd.place
			end,
			-- a release with velocity (points per ms, up and down): the glide
			fling = function(id: string?, vy: number)
				local key = current:peek()
				local sd = key and slot_data[key]
				local s = sd and (if id then plan_of(sd).at[id] else 1)
				if sd and s then
					local x, y = pos_of(sd, s)
					local d, ms, ease = Scroll.fling(vy / sd.place.z)
					glide(sd, s, x, y + d, ms, ease)
				end
			end,
			run_acts = function(acts: { any }, done: (() -> ())?)
				run_acts(acts, 1, done)
			end,
			-- (step 2) a layer of the shown Screen on the stage: { x, y, w, h }
			rect_of = function(id: string): { number }?
				local key = current:peek()
				local sd = key and slot_data[key]
				if not sd then
					return nil
				end
				for i, it in sd.root.nodes do
					if it.id == id then
						return stage_rect(key :: string, i)
					end
				end
				return nil
			end,
			-- the hover / press reaction holding, as "hover:<id>"
			held = function(): string?
				return if held then `{held.kind}:{held.id}` else nil
			end,
			-- (overlays, step 2) the open ones, bottom → top: { { id, name, key, rect = { x, y, w, h } (stage) } }
			overlays = function(): { any }
				local out = {}
				for _, key in ov_stack do
					local sd = slot_data[key]
					local pl = sd and sd.place
					if sd then
						local at = ov_at:peek()[key]
						table.insert(out, {
							id = sd.id,
							name = sd.root.nodes[1].name,
							key = key,
							rect = pl and { if at then at.left else pl.left, if at then at.top else pl.top, pl.w, pl.h },
						})
					end
				end
				return out
			end,
			-- every overlay slot mounted (open or spare): { { id, spare } }
			overlay_slots = function(): { any }
				local out = {}
				for _, s in ovs:peek() do
					local sd = slot_data[s.key]
					table.insert(out, { id = s.id, spare = sd and sd.spare, ready = sd and sd.ready })
				end
				return out
			end,
			-- a click (press and release) at stage point (lx, ly); a pointer move
			click = function(lx: number, ly: number)
				on_press({ local_x = lx, local_y = ly })
				on_release({ local_x = lx, local_y = ly })
			end,
			move = function(lx: number, ly: number)
				on_move({ local_x = lx, local_y = ly })
			end,
			-- a key's triggers (benches: no focus needed)
			key = function(name: string)
				key_trigger({ key = name })
			end,
			-- (step 3) a press and a release apart: a drag held across frames
			press = function(lx: number, ly: number)
				on_press({ local_x = lx, local_y = ly })
			end,
			release = function(lx: number, ly: number)
				on_release({ local_x = lx, local_y = ly })
			end,
			-- a layer of an open overlay (top first) or the Screen, on the stage
			layer_rect = function(id: string): { number }?
				local keys = {}
				for k = #ov_stack, 1, -1 do
					table.insert(keys, ov_stack[k])
				end
				table.insert(keys, current:peek())
				for _, key in keys do
					local sd = key and slot_data[key]
					local i = sd and Proto.of_root(sd.root).at[id]
					if i then
						return stage_rect(key, i)
					end
				end
				return nil
			end,
			viewport = function(): any
				return vp:peek()
			end,
			-- (step 3) the smart transition playing: { p, movers, kinds, plan_ms }
			smart = function(): any?
				local r = smart_run or coast
				if not r then
					return nil
				end
				local kinds = {}
				for _, s in r.specs do
					kinds[s.kind] = (kinds[s.kind] or 0) + 1
				end
				return { p = r.p, movers = #r.specs, kinds = kinds, plan_ms = r.plan_ms, started = r.started == true, scrub = r.scrub == true, coasting = r.coasting == true, interrupted = r.interrupted }
			end,
			-- the Smart Animate bases mounted ahead: { "src>dst" }
			-- (step 4) the shown Screen's interactive components: "path=member,…",
			-- and the spares mounted ahead for its Change to links
			variants = function(): string
				local k = current:peek()
				local sd = k and slot_data[k]
				if not sd then
					return "-"
				end
				local out = {}
				for i, it in sd.root.nodes do
					if it.vset then
						table.insert(out, Variants.path(sd.root.nodes, i) .. "=" .. tostring(it.inst))
					end
				end
				-- (L1: the open overlays' too, as "ov:path=member")
				for _, ok in ov_stack do
					local od = slot_data[ok]
					if od then
						for i, it in od.root.nodes do
							if it.vset then
								table.insert(out, "ov:" .. Variants.path(od.root.nodes, i) .. "=" .. tostring(it.inst))
							end
						end
					end
				end
				local spares = 0
				for _, d in slot_data do
					if d.change_of == k and d.spare then
						spares += 1
					end
				end
				return table.concat(out, ",") .. " spares=" .. spares
			end,
			smart_bases = function(): { string }
				local out = {}
				for k, got in smart_bases do
					local a, b = slot_data[got.src], slot_data[got.dst]
					table.insert(out, k .. (if a and b and a.ready and b.ready then "" else " (drawing)"))
				end
				table.sort(out)
				return out
			end,
			-- (F4-int) the mover of layer `name` (the smart run's, or a Change
			-- to's playing on), its first canvas on the stage: { x, y, w, h }
			mover_named = function(name: string): { number }?
				local r = smart_run or coast
				for _, spec in (r and r.specs or {}) do
					local cv = spec.mv.name == name and spec.canvases[1]
					if cv and cv.el then
						local ok, rect = pcall(function()
							return cv.el:rect()
						end)
						return if ok then rect else nil
					end
				end
				return nil
			end,
			-- a mover's element on the stage: { x, y, w, h } (its canvas)
			mover_rect = function(n: number, ci: number?): { number }?
				local r = smart_run or coast
				local spec = r and r.specs[n]
				local cv = spec and spec.canvases[ci or 1]
				if not cv or not cv.el then
					return nil
				end
				local ok, rect = pcall(function()
					return cv.el:rect()
				end)
				return if ok then rect else nil
			end,
			escape = function()
				if #ov_stack > 0 and not busy then
					close_top(nil)
				end
			end,
			-- (V3) variables: { changed = "name=value[@sig];…", mode = "axis=v;…",
			-- veils = swaps still drawing, pending = looks being fetched,
			-- last = the last swap { how, ms, patches }, ahead = looks mounted
			-- ahead for the shown Screen, patches = patch slots on show }
			vars = function(): any
				local ch = {}
				for _, c in PV.changed(pv.toks, pv.vars) do
					table.insert(ch, c.name .. "=" .. PV.show(c.value) .. (if c.sig ~= "" then "@" .. c.sig else ""))
				end
				local ms = {}
				for axis, v in pv.mode do
					table.insert(ms, `{axis}={v}`)
				end
				table.sort(ms)
				local veils, patches = 0, 0
				for _, v in vveil do
					veils += 1
					patches += #v.patches
				end
				local k = current:peek()
				local n_ahead = 0
				for _, d in slot_data do
					if d.vlook_of == k and d.spare then
						n_ahead += 1
					end
				end
				return { changed = table.concat(ch, ";"), mode = table.concat(ms, ";"), veils = veils, pending = vpending, last = perf.vars[#perf.vars], ahead = n_ahead, patches = patches, loaded = pv.loaded, vb = dev.vb_n or 0, times = dev.vtimes }
			end,
			-- the text a layer of the shown Screen (or an open overlay) shows,
			-- and whether it's there at all (a hidden layer isn't)
			text_of = function(id: string): string?
				local keys = {}
				for k = #ov_stack, 1, -1 do
					table.insert(keys, ov_stack[k])
				end
				table.insert(keys, current:peek())
				for _, key in keys do
					local sd = key and slot_data[key]
					for _, it in (if sd then sd.root.nodes else {}) do
						if it.id == id then
							return if it.text then it.text.s else ""
						end
					end
				end
				return nil
			end,
			var_reset = function()
				var_reset(true)
			end,
		})
	end

	local function bar_btn(id: string, label: string, icon: string, fn: () -> (), key: string): Node
		return ui.button {
			id = id,
			label = label,
			tooltip = Kit.tip(L, `{label}  {key}`),
			tooltip_placement = { side = "bottom", offset = 8 },
			h = 28,
			px = 8,
			gap = 6,
			rounded = 8,
			border = 0,
			items = "center",
			bg = "#00000000",
			hover = { bg = D.hover },
			focus = { outline = 0 },
			color = D.muted,
			on_click = fn,
			Kit.icon(icon, 14),
			ui.text { label, text_size = 12, weight = 500, font = Look.UI, color = D.fg },
		}
	end

	-- (step 6 P1) a square icon button (‹ ›)
	local function icon_btn(id: string, label: string, icon: string, fn: () -> (), key: string): Node
		return ui.button {
			id = id,
			label = label,
			tooltip = Kit.tip(L, `{label}  {key}`),
			tooltip_placement = { side = "bottom", offset = 8 },
			w = 28,
			h = 28,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			bg = "#00000000",
			hover = { bg = D.hover },
			focus = { outline = 0 },
			color = D.muted,
			on_click = fn,
			Kit.icon(icon, 14),
		}
	end

	-- (V3, ours: Figma shows no values while playing) The variables popover:
	-- each variable's value now, per mode when it has several (the one the
	-- page's mode picks marked), changed ones in the accent with a dot; the
	-- modes; Reset puts back the Design's values and modes without leaving
	-- the Screen (Restart does that and goes to the start).
	local vars_open = ui.use_state(false)
	local function value_cell(kind: string, v: any, changed: boolean, id: string): Node
		local row: any = { gap = 6, items = "center", min_w = 0 }
		if kind == "color" and type(v) == "string" then
			table.insert(row, ui.div { w = 12, h = 12, rounded = 3, bg = v, border = 1, border_color = D.border, shrink = 0 })
		end
		table.insert(row, ui.text {
			PV.show(v),
			id = id,
			text_size = 12,
			font = Look.UI,
			color = if changed then D.accent_fg else D.fg,
			weight = if changed then 600 else 400,
			truncate = true,
			min_w = 0,
		})
		if changed then
			table.insert(row, ui.div { w = 6, h = 6, rounded = 3, bg = D.accent, shrink = 0 })
		end
		return ui.row(row)
	end
	local function vars_rows(): Node
		local names = {}
		for name in pv.toks do
			table.insert(names, name)
		end
		table.sort(names)
		local page = PV.theme(pv.themes, view_theme(), pv.mode, nil)
		local col: any = { w_full = true, gap = 2 }
		-- the modes
		local axes = {}
		for axis in pv.themes do
			table.insert(axes, axis)
		end
		table.sort(axes)
		for _, axis in axes do
			local changed = pv.mode[axis] ~= nil and pv.mode[axis] ~= PV.theme(pv.themes, view_theme(), nil, nil)[axis]
			table.insert(col, ui.row {
				id = `play-vars-mode-{axis}`,
				w_full = true,
				h = 26,
				gap = 8,
				items = "center",
				Kit.icon("sun", 12, D.muted),
				ui.text { axis, text_size = 12, font = Look.UI, color = D.muted, grow = 1, truncate = true, min_w = 0 },
				value_cell("string", page[axis], changed, `play-vars-modev-{axis}`),
			})
		end
		if #axes > 0 and #names > 0 then
			table.insert(col, ui.div { w_full = true, h = 1, bg = D.border, my = 4 })
		end
		for _, name in names do
			local tok = pv.toks[name]
			local o = pv.vars[name]
			local _, pick = PV.value_in(tok, page)
			local block: any = { id = `play-var-{name}`, w_full = true, gap = 2, py = 3 }
			local head: any = { w_full = true, gap = 8, items = "center" }
			table.insert(head, ui.text { name, text_size = 12, weight = 500, font = Look.UI, color = D.fg, grow = 1, truncate = true, min_w = 0 })
			if #tok.values == 1 then
				local c = tok.values[1]
				local v = if type(o) == "table" then o[""] else o
				local changed = v ~= nil and not PV.equal(v, c.value)
				table.insert(head, value_cell(tok.kind, if v ~= nil then v else c.value, changed, `play-var-v-{name}`))
				table.insert(block, ui.row(head))
			else
				table.insert(head, ui.text { tok.kind, text_size = 11, font = Look.UI, color = D.muted })
				table.insert(block, ui.row(head))
				for _, c in tok.values do
					local s = PV.sig(c.theme)
					local v = if type(o) == "table" then o[s] else o
					local changed = v ~= nil and not PV.equal(v, c.value)
					local label = {}
					for _, x in c.theme do
						table.insert(label, tostring(x))
					end
					table.sort(label)
					local here = c == pick
					table.insert(block, ui.row {
						w_full = true,
						gap = 8,
						pl = 10,
						items = "center",
						ui.div { w = 4, h = 4, rounded = 2, bg = if here then D.fg else "#00000000", shrink = 0 },
						ui.text { if #label > 0 then table.concat(label, " · ") else "default", text_size = 12, font = Look.UI, color = if here then D.fg else D.muted, grow = 1, truncate = true, min_w = 0 },
						value_cell(tok.kind, if v ~= nil then v else c.value, changed, `play-var-v-{name}-{if s == "" then "default" else s}`),
					})
				end
			end
			table.insert(col, ui.column(block))
		end
		if #names == 0 and #axes == 0 then
			table.insert(col, ui.text { "This Design has no variables.", text_size = 12, font = Look.UI, color = D.muted })
		end
		return ui.column(col)
	end
	local function vars_btn(): Node
		return ui.popover {
			open = vars_open,
			label = "Variables",
			placement = { side = "bottom", align = "end", offset = 6 },
			anchor = ui.button {
				id = "play-vars",
				label = "Variables",
				tooltip = Kit.tip(L, "Variables: their values while playing"),
				tooltip_placement = { side = "bottom", offset = 8 },
				h = 28,
				px = 8,
				gap = 6,
				rounded = 8,
				border = 0,
				items = "center",
				bg = function(): string
					return if vars_open:get() then D.field_active else "#00000000"
				end,
				hover = { bg = D.hover },
				focus = { outline = 0 },
				color = D.muted,
				on_click = function()
					vars_open:set(not vars_open:peek())
				end,
				Kit.icon("braces", 14),
				ui.text {
					function(): string
						local _ = pv_ver:get()
						local n = #PV.changed(pv.toks, pv.vars)
						return if n > 0 then `Variables · {n}` else "Variables"
					end,
					id = "play-vars-label",
					text_size = 12,
					weight = 500,
					font = Look.UI,
					color = D.fg,
				},
			},
			w = 300,
			p = 10,
			gap = 8,
			rounded = 10,
			bg = D.pop or D.panel_solid,
			border = 1,
			border_color = D.border,
			shadow = D.pop_shadow,
			build = function(): Node
				return ui.column {
					id = "play-vars-pop",
					w_full = true,
					gap = 8,
					ui.row {
						w_full = true,
						items = "center",
						gap = 8,
						ui.text { "Variables", text_size = 12, weight = 600, font = Look.UI, color = D.fg, grow = 1 },
						ui.button {
							id = "play-vars-reset",
							label = "Reset",
							tooltip = Kit.tip(L, "Back to the Design's values and modes, on this Screen"),
							h = 24,
							px = 8,
							rounded = 6,
							border = 0,
							bg = D.field,
							hover = { bg = D.hover },
							focus = { outline = 0 },
							on_click = function()
								var_reset(true)
							end,
							ui.text { "Reset", text_size = 12, font = Look.UI, color = D.fg },
						},
					},
					ui.column {
						w_full = true,
						max_h = 360,
						overflow_y = "auto",
						ui.presence(function(): string
							return tostring(pv_ver:get())
						end, function(_: any): Node
							return vars_rows()
						end, { w_full = true }),
					},
				}
			end,
		}
	end

	-- (step 6 P1) Options (Figma's sliders menu): the scaling choices grouped
	-- as Figma's, a ✓ on the one in force and "Z" on the one Z goes to; Show
	-- hints on click; Hide UI. Built again when a choice changes.
	local opts_open = ui.use_state(false)
	local opts_ver = ui.use_state(0)
	local function opt_row(id: string, label: string, on: boolean, shortcut: string?, fn: () -> ()): Node
		return ui.menu_item {
			id = id,
			label = label,
			on_click = fn,
			h = 28,
			px = 8,
			rounded = 6,
			hover = { bg = D.pop_hl },
			ui.row {
				w_full = true,
				h = 28,
				gap = 8,
				items = "center",
				ui.div { w = 14, shrink = 0, color = D.fg_strong, if on then Kit.icon("check", 13) else ui.div {} },
				ui.text { label, text_size = 12, color = D.fg_strong, font = Look.UI, grow = 1, truncate = true, min_w = 0 },
				if shortcut then ui.text { shortcut, text_size = 12, color = D.faint, font = Look.UI } else ui.div {},
			},
		}
	end
	local function options_btn(): Node
		local st = settings()
		local list, cur = PlayPlace.choices(st)
		local nx = PlayPlace.cycle(list, cur)
		local mp: any = {
			open = opts_open,
			label = "Options",
			placement = { side = "bottom", align = "end", offset = 6 },
			anchor = ui.button {
				id = "play-options",
				label = "Options",
				tooltip = Kit.tip(L, "Options: scaling, hints, Hide UI"),
				tooltip_placement = { side = "bottom", offset = 8 },
				w = 28,
				h = 28,
				p = 0,
				rounded = 8,
				border = 0,
				items = "center",
				justify = "center",
				bg = function(): string
					return if opts_open:get() then D.field_active else "#00000000"
				end,
				hover = { bg = D.hover },
				focus = { outline = 0 },
				color = D.muted,
				on_click = function()
					opts_open:set(not opts_open:peek())
				end,
				Kit.icon("sliders", 14),
			},
		}
		if st.framed then
			-- (step 6 P2: with a device frame the device's choices are in the
			-- device switcher, as Figma's; here only the content's scaling:
			-- Fixed size, or Responsive (step 6 P5: laid out at the device's size)
			table.insert(mp, Kit.menu_head(D, "Recommended"))
			for _, c in PlayPlace.CONTENT do
				local name = c.name
				local on = (name == "responsive") == (st.responsive == true)
				table.insert(mp, opt_row(if name == "fit" then "play-opt-fixed" else "play-opt-responsive", c.label, on, nil, function()
					if not on then
						choose({ fit = name })
						opts_ver:set(opts_ver:peek() + 1)
					end
					opts_open:set(false)
				end))
			end
		else
			local group = nil
			for _, c in list do
				if c.group ~= group then
					group = c.group
					table.insert(mp, Kit.menu_head(D, c.group))
				end
				local name = c.name
				table.insert(mp, opt_row(`play-opt-{name}`, c.label, name == cur, if name == nx then "Z" else nil, function()
					choose({ fit = name })
					opts_ver:set(opts_ver:peek() + 1)
				end))
			end
		end
		table.insert(mp, Kit.menu_sep(D))
		table.insert(mp, opt_row("play-opt-hints", "Show hints on click", st.hints, nil, function()
			choose({ hints = not settings().hints })
			opts_ver:set(opts_ver:peek() + 1)
		end))
		table.insert(mp, opt_row("play-opt-hide", "Hide UI", false, "Ctrl \\", toggle_ui))
		for k2, v2 in Kit.pop_style(D) do
			mp[k2] = v2
		end
		mp.w = 240
		return ui.menu(mp)
	end

	-- (step 6 P2) The device switcher (Figma's "iPhone 16 ⌄" in the bar), for
	-- a preset with a frame: Fit device on screen, Zoom device to fill screen,
	-- Show device at 100% (a ✓ on the one in force, "Z" on the next), and
	-- Show device frame. A device choice with the frame hidden shows it again.
	function dev.button(): Node
		local dv = device()
		if not (dv and dv.frame) then
			return ui.div {}
		end
		local pre = dv.device and Scroll.DEVICES[dv.device]
		local name = if pre and pre.label then pre.label else "Device"
		local st = settings()
		local nx = PlayPlace.cycle(PlayPlace.FRAMED, st.dfit)
		local mp: any = {
			open = dev.open,
			label = name,
			placement = { side = "bottom", align = "end", offset = 6 },
			anchor = ui.button {
				id = "play-device-switch",
				label = name,
				tooltip = Kit.tip(L, "Device: fit, zoom, 100%, frame"),
				tooltip_placement = { side = "bottom", offset = 8 },
				h = 28,
				px = 8,
				gap = 4,
				rounded = 8,
				border = 0,
				items = "center",
				bg = function(): string
					return if dev.open:get() then D.field_active else "#00000000"
				end,
				hover = { bg = D.hover },
				focus = { outline = 0 },
				color = D.muted,
				on_click = function()
					dev.open:set(not dev.open:peek())
				end,
				ui.text { name, text_size = 12, weight = 500, font = Look.UI, color = D.fg },
				Kit.icon("chevDown", 13),
			},
		}
		for _, c in PlayPlace.FRAMED do
			local fit = c.name
			table.insert(mp, opt_row(`play-dev-{fit}`, c.label, st.framed and fit == st.dfit, if st.framed and fit == nx then "Z" else nil, function()
				choose(if st.framed then { dfit = fit } else { dfit = fit, frame = true })
				opts_ver:set(opts_ver:peek() + 1)
			end))
		end
		table.insert(mp, Kit.menu_sep(D))
		table.insert(mp, opt_row("play-dev-frame", "Show device frame", st.framed, nil, function()
			choose({ frame = not settings().framed })
			opts_ver:set(opts_ver:peek() + 1)
		end))
		for k2, v2 in Kit.pop_style(D) do
			mp[k2] = v2
		end
		mp.w = 240
		return ui.menu(mp)
	end

	-- (step 6 P2) The device frame's canvases (`which` = "body", under the
	-- viewport, or "over", above it): made once per `devpl` (size, model,
	-- rotation, stage); nothing in them reads a state, so they never redraw
	-- while playing (M0: no raster per frame).
	function dev.layer(which: string): Node
		local d = dev.pl:peek()
		local f = d and DeviceFrame.shapes(d.frame, d.vw, d.vh, d.rotate, d.model)
		local box: any = {
			id = `play-device{if which == "over" then "-over" else ""}`,
			absolute = true,
			left = 0,
			top = 0,
			right = 0,
			bottom = 0,
			pointer_events = "none",
		}
		if not (d and f) then
			return ui.div(box)
		end
		local parts = PlayPlace.frame_parts(f, d, d.sw, d.sh)[which]
		local list = f[which]
		for k, p in parts do
			table.insert(box, ui.canvas {
				id = `play-device-{which}-{k}`,
				absolute = true,
				left = p.left,
				top = p.top,
				w = p.w,
				h = p.h,
				pointer_events = "none",
				draw = function(c: Canvas)
					perf.frame_draws += 1
					paint_frame(c, list, p.ox, p.oy, d.z, d.bg)
				end,
			})
		end
		return ui.div(box)
	end

	-- (step 6 P3) The flows sidebar (Figma's: 240 px on the left): "Flows"
	-- and ✕, the Design's flows with a ✓ on the one playing (a pick restarts
	-- there), and the playing flow's description below ("No description"),
	-- its `- ` / `1. ` lines as lists and its URLs as links. Built again only
	-- when the flows or the flow playing change.
	function dev.toggle_btn(): Node
		return ui.show(function(): boolean
			local fl = source.flows and source.flows:get() or {}
			return #fl > 0
		end, ui.button {
			id = "play-flows-toggle",
			label = "Flows",
			tooltip = Kit.tip(L, "Flows"),
			tooltip_placement = { side = "bottom", offset = 8 },
			w = 28,
			h = 28,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			bg = function(): string
				return if dev.side_on(true) then D.field_active else "#00000000"
			end,
			hover = { bg = D.hover },
			focus = { outline = 0 },
			color = D.muted,
			on_click = dev.side_toggle,
			Kit.icon("panelLeft", 14),
		})
	end
	-- A line's runs as a wrapped paragraph; a URL is a link (opened by the
	-- host, as a Design's Open link action).
	function dev.rich(runs: { any }, color: string): Node
		local p: any = { wrap = true, grow = 1, min_w = 0, text_size = 12, line_height = 18, font = Look.UI, color = color }
		for _, r in runs do
			if r.url then
				local url = r.url
				table.insert(p, ui.span {
					r.x,
					literal = true,
					color = D.accent,
					underline = true,
					on_click = function(): boolean
						if source.open_url then
							source.open_url(url)
						end
						return true
					end,
				})
			else
				table.insert(p, ui.span { r.x, literal = true })
			end
		end
		return ui.rich(p)
	end
	function dev.desc(text: string?): Node
		local blocks = PlayFlows.blocks(text)
		local col: any = { id = "play-flow-desc-body", w_full = true, gap = 8 }
		if #blocks == 0 then
			table.insert(col, ui.text { "No description", id = "play-flow-desc-none", text_size = 12, color = D.faint, font = Look.UI })
		end
		for _, b in blocks do
			if b.t == "p" then
				table.insert(col, ui.row { w_full = true, dev.rich(b.runs, D.muted) })
			else
				local list: any = { w_full = true, gap = 4 }
				for k, item in b.items do
					table.insert(list, ui.row {
						w_full = true,
						gap = 6,
						items = "start",
						ui.text { if b.t == "ol" then `{b.start + k - 1}.` else "•", w = 16, shrink = 0, align = "right", text_size = 12, line_height = 18, color = D.faint, font = Look.UI },
						dev.rich(item, D.muted),
					})
				end
				table.insert(col, ui.column(list))
			end
		end
		return ui.column(col)
	end
	function dev.sidebar(): Node
		-- (the flows and the one playing, as a key: rows are built again on a change)
		local function key(): string
			local fl = source.flows and source.flows:get() or {}
			local c = dev.cur:get()
			local parts = { tostring(PlayFlows.current(fl, c.start, c.flow)) }
			for _, f in fl do
				table.insert(parts, `{f.name}\0{f.start}\0{f.description or ""}`)
			end
			return table.concat(parts, "\1")
		end
		return ui.show(function(): boolean
			return not hide_ui:get() and dev.side_on(true)
		end, ui.column {
			id = "play-flows",
			role = "group",
			label = "Flows",
			w = PlayFlows.W,
			h_full = true,
			shrink = 0,
			bg = D.panel_solid or D.canvas,
			border_sides = { 0, 1, 0, 0 },
			border_color = D.border,
			ui.row {
				w_full = true,
				h = 40,
				shrink = 0,
				pl = 16,
				pr = 8,
				items = "center",
				ui.text { "Flows", text_size = 12, weight = 600, font = Look.UI, color = D.fg, grow = 1 },
				ui.button {
					id = "play-flows-close",
					label = "Close flows",
					tooltip = Kit.tip(L, "Close"),
					tooltip_placement = { side = "bottom", offset = 8 },
					w = 24,
					h = 24,
					p = 0,
					rounded = 6,
					border = 0,
					items = "center",
					justify = "center",
					bg = "#00000000",
					hover = { bg = D.hover },
					focus = { outline = 0 },
					color = D.muted,
					on_click = dev.side_toggle,
					Kit.icon("x", 13),
				},
			},
			ui.presence(key, function(_: string): Node
				local fl = dev.flows()
				local c = dev.cur:peek()
				local cur = PlayFlows.current(fl, c.start, c.flow)
				local list: any = { w_full = true, px = 8, pb = 8, gap = 2 }
				for i, f in fl do
					local on = i == cur
					local name = if type(f.name) == "string" and f.name ~= "" then f.name else `Flow {i}`
					table.insert(list, ui.button {
						id = `play-flow-{i}`,
						label = name,
						w_full = true,
						h = 30,
						px = 8,
						gap = 8,
						rounded = 6,
						border = 0,
						items = "center",
						bg = if on then D.field_active else "#00000000",
						hover = { bg = D.hover },
						focus = { outline = 0 },
						on_click = function()
							dev.pick(i)
						end,
						ui.div { w = 14, shrink = 0, color = D.fg_strong or D.fg, if on then Kit.icon("check", 13) else ui.div {} },
						ui.text { name, literal = true, text_size = 12, weight = if on then 600 else 400, font = Look.UI, color = if on then D.fg else D.muted, grow = 1, truncate = true, min_w = 0 },
					})
				end
				local desc = if cur then fl[cur].description else nil
				return ui.column {
					w_full = true,
					grow = 1,
					min_h = 0,
					-- the list: up to 10 rows, then it scrolls (30 a row, 2 apart, 8 under)
					ui.scroll { id = "play-flows-list", w_full = true, shrink = 0, h = math.min(#fl, 10) * 32 + 8, ui.column(list) },
					-- the description pane, under the list (it scrolls)
					ui.scroll {
						id = "play-flow-desc",
						w_full = true,
						grow = 1,
						min_h = 0,
						border_sides = { 1, 0, 0, 0 },
						border_color = D.border,
						ui.column {
							w_full = true,
							px = 16,
							pt = 12,
							pb = 16,
							gap = 8,
							-- (step 6 P6: only the description, no flow name over it, as Figma's)
							dev.desc(desc),
						},
					},
				}
			end, { w_full = true, grow = 1, min_h = 0 }),
		})
	end

	-- (step 6 P4) The Preview's menu (⋯): Fit width, Show device frame, Follow
	-- prototype, Resize to 100%, Open in Play, Close. `dev.pre_do` runs one by
	-- name (the menu, and tests through `expose.pre_menu`).
	dev.pre_open = ui.use_state(false)
	function dev.pre_do(what: string)
		dev.pre_open:set(false)
		local st = settings()
		if what == "width" then
			choose({ fit = if st.fit == "width" then "fit" else "width" })
		elseif what == "responsive" then
			-- (step 6 P5, Figma's Preview menu: the Screen laid out at the
			-- Preview's size, 8 pt in, or the device's)
			choose({ fit = if st.fit == "responsive" then "fit" else "responsive" })
		elseif what == "frame" then
			choose({ frame = not st.framed })
		elseif what == "follow" then
			local s = table.clone(sess:peek() or {})
			s.follow = not (s.follow == true)
			sess:set(s)
			local cur = current:peek()
			if s.follow and cur and slot_data[cur] and props.on_shown then
				props.on_shown(slot_data[cur].id, true)
			end
		elseif what == "100" then
			local cur = current:peek()
			local sd = cur and slot_data[cur]
			if sd and props.on_100 then
				local s = PlayPlace.preview_100(sd.root.nodes[1].box, device(), st)
				props.on_100(s.w, s.h)
			end
		elseif what == "play" then
			local cur = current:peek()
			if props.on_play then
				props.on_play(if cur and slot_data[cur] then slot_data[cur].id else dev.cur:peek().start)
			end
		elseif what == "close" then
			props.on_close()
		end
		opts_ver:set(opts_ver:peek() + 1)
	end
	function dev.pre_menu(): Node
		local st = settings()
		local dv = device()
		local s = sess:peek() or {}
		local mp: any = {
			open = dev.pre_open,
			label = "Preview options",
			placement = { side = "bottom", align = "end", offset = 6 },
			anchor = ui.button {
				id = "preview-more",
				label = "Preview options",
				tooltip = Kit.tip(L, "Options"),
				tooltip_placement = { side = "bottom", offset = 8 },
				w = 26,
				h = 26,
				p = 0,
				rounded = 7,
				border = 0,
				items = "center",
				justify = "center",
				bg = function(): string
					return if dev.pre_open:get() then D.field_active else "#00000000"
				end,
				hover = { bg = D.hover },
				focus = { outline = 0 },
				color = D.muted,
				on_click = function()
					dev.pre_open:set(not dev.pre_open:peek())
				end,
				Kit.icon("dots", 14),
			},
		}
		if not st.framed then
			table.insert(mp, opt_row("preview-opt-width", "Fit width", st.fit == "width", nil, function()
				dev.pre_do("width")
			end))
		end
		table.insert(mp, opt_row("preview-opt-responsive", "Responsive", st.responsive == true, nil, function()
			dev.pre_do("responsive")
		end))
		if dv and dv.frame then
			table.insert(mp, opt_row("preview-opt-frame", "Show device frame", st.framed, nil, function()
				dev.pre_do("frame")
			end))
		end
		table.insert(mp, opt_row("preview-opt-follow", "Follow prototype", s.follow == true, nil, function()
			dev.pre_do("follow")
		end))
		table.insert(mp, Kit.menu_sep(D))
		table.insert(mp, opt_row("preview-opt-100", "Resize to 100%", false, nil, function()
			dev.pre_do("100")
		end))
		table.insert(mp, opt_row("preview-opt-play", "Open in Play", false, "Ctrl Enter", function()
			dev.pre_do("play")
		end))
		for k2, v2 in Kit.pop_style(D) do
			mp[k2] = v2
		end
		mp.w = 220
		return ui.menu(mp)
	end
	function dev.pre_btn(id: string, label: string, icon: string, key: string, fn: () -> ()): Node
		return ui.button {
			id = id,
			label = label,
			tooltip = Kit.tip(L, `{label}  {key}`),
			tooltip_placement = { side = "bottom", offset = 8 },
			w = 26,
			h = 26,
			p = 0,
			rounded = 7,
			border = 0,
			items = "center",
			justify = "center",
			bg = "#00000000",
			hover = { bg = D.hover },
			focus = { outline = 0 },
			color = D.muted,
			on_click = fn,
			Kit.icon(icon, 14),
		}
	end
	-- The Preview's bar (36 high): the Screen's name, ‹ › Restart, ⋯, ✕.
	function dev.pre_bar(): Node
		return ui.row {
			id = "preview-bar",
			w_full = true,
			h = PlayPlace.PREVIEW_BAR,
			shrink = 0,
			pl = 10,
			pr = 4,
			gap = 2,
			items = "center",
			border_sides = { 0, 0, 1, 0 },
			border_color = D.border,
			ui.text {
				function(): string
					return title:get()
				end,
				id = "preview-title",
				literal = true,
				text_size = 12,
				weight = 500,
				font = Look.UI,
				color = D.fg,
				grow = 1,
				truncate = true,
				min_w = 0,
			},
			dev.pre_btn("preview-back", "Back", "chevLeft", "←", back),
			dev.pre_btn("preview-next", "Next", "chevRight", "→", function()
				next_screen()
			end),
			dev.pre_btn("preview-restart", "Restart", "undo", "R", restart),
			ui.presence(function(): string
				local _ = opts_ver:get()
				local _ = source.device and source.device:get()
				local st = settings()
				return `{st.framed}|{st.fit}|{(sess:peek() or {}).follow}`
			end, function(_: string): Node
				return dev.pre_menu()
			end),
			dev.pre_btn("preview-close", "Close preview", "x", "⇧ Space", props.on_close),
		}
	end

	-- Play's keys (while it has focus). (step 6 P4) The Preview lets every
	-- key it doesn't use through to the editor: Ctrl+Enter (Play), Shift+Space
	-- (close it), undo, and the rest; Esc hands keys back to the canvas.
	function dev.on_key(k: any): boolean?
		local key = k.key
		local pre = dev.pre
		local space = key == " " or key == "Space"
		if k.editing then
			-- (step 7: words typed in a comment box are its own)
			return nil
		end
		if dev.cm and key == "Escape" and dev.cm.on:peek() then
			-- (step 7) Esc closes a comment's card, then leaves comment mode
			return dev.cm.key(k)
		end
		if key == "Escape" and #ov_stack > 0 then
			-- (an overlay open: Esc closes it first)
			if not busy then
				close_top(nil)
			end
			return true
		elseif pre and key == "Escape" then
			if props.on_escape then
				props.on_escape()
			end
			return true
		elseif pre and (k.cmd or k.alt or (k.shift and space)) then
			return nil
		elseif key == "Escape" or (k.cmd and key == "Enter") then
			props.on_close()
			return true
		elseif k.cmd and (key == "\\" or key == "Backslash") then
			-- (step 6 P1: Figma's Hide UI)
			toggle_ui()
			return true
		elseif key_trigger(k) then
			-- (the Design's own key links win over Play's keys)
			return true
		elseif dev.cm and (key == "c" or key == "C") and not k.cmd and not k.alt and not k.shift then
			-- (step 7, Figma's C) comment mode
			dev.cm.key(k)
			return true
		elseif key == "ArrowLeft" or key == "Backspace" then
			back()
			return true
		elseif (key == "ArrowRight" or space or key == "n" or key == "N") and not k.cmd then
			next_screen()
			return true
		elseif (key == "z" or key == "Z") and not k.cmd and not pre then
			cycle_fit()
			opts_ver:set(opts_ver:peek() + 1)
			return true
		elseif (key == "r" or key == "R") and not k.cmd then
			restart()
			return true
		end
		-- (the editor's keys wait while playing; the Preview lets them through)
		return if pre then nil else true
	end

	-- (Play's root element, for focus: in `dev`, as Play is at Luau's 200-locals limit)
	dev.root_el = nil
	return ui.column {
		id = if dev.pre then "preview-play" else "play",
		role = if dev.pre then "group" else "dialog",
		label = if dev.pre then "Preview" else "Prototype",
		absolute = true,
		left = 0,
		top = 0,
		right = 0,
		bottom = 0,
		z = if dev.pre then nil else 50, -- (the Preview: under its island's resize edges)
		-- (step 6 P6: the Preview's island clips square, so Play rounds its own
		-- background to the island's 12 (11 inside its 1 px rim); a rounded
		-- clip costs a mask a frame)
		rounded = if dev.pre then 11 else nil,
		-- (the Design's prototype background, else the dark stage)
		bg = function(): string
			local dv = source.device and source.device:get()
			return if type(dv) == "table" and dv.bg then dv.bg else D.canvas
		end,
		color = D.fg,
		font = Look.UI,
		focusable = true,
		focus = { outline = 0 },
		on_mount = function(el: any)
			dev.root_el = el
			-- (step 6 P4: the Preview takes keys once clicked; the canvas keeps them)
			if not dev.pre then
				el:focus()
			end
		end,
		on_key = dev.on_key,
		-- (step 6 P4) the Preview's compact bar
		if dev.pre then dev.pre_bar() else ui.div {},
		-- The bar: flow · Screen, then ‹ (Back) ›, Restart, Options, Close.
		-- (step 6 P1: Hide UI takes it away; Ctrl+\ or the chip brings it back)
		ui.show(function(): boolean
			return not dev.pre and not hide_ui:get()
		end, ui.row {
			id = "play-bar",
			w_full = true,
			h = BAR_H,
			shrink = 0,
			px = 12,
			gap = 8,
			items = "center",
			border_sides = { 0, 0, 1, 0 },
			border_color = D.border,
			-- (step 6 P3) the flows sidebar's toggle, at the bar's left
			dev.toggle_btn(),
			Kit.icon("play", 14, D.accent),
			ui.text {
				function(): string
					local t = title:get()
					local fname = dev.cur:get().flow
					return if fname then `{fname}  ·  {t}` else t
				end,
				id = "play-title",
				text_size = 12,
				weight = 500,
				font = Look.UI,
				color = D.fg,
				grow = 1,
				truncate = true,
				min_w = 0,
			},
			-- (V3) the variables popover, when the Design has any
			ui.presence(function(): string
				local _ = pv_ver:get()
				return if next(pv.toks) ~= nil or next(pv.themes) ~= nil then "vars" else "none"
			end, function(which: string): Node
				return if which == "vars" then vars_btn() else ui.div {}
			end),
			-- (step 7) comment mode
			if dev.cm then dev.cm.button() else ui.div {},
			icon_btn("play-back", "Back", "chevLeft", back, "←"),
			-- (step 6 P6) "1 / N", as Figma's bar without flows
			ui.show(function(): boolean
				return dev.counter() ~= ""
			end, ui.text {
				dev.counter,
				id = "play-counter",
				text_size = 12,
				font = Look.UI,
				color = D.muted,
				tabular = true,
				shrink = 0,
			}),
			icon_btn("play-next", "Next", "chevRight", function()
				next_screen()
			end, "→"),
			bar_btn("play-restart", "Restart", "undo", restart, "R"),
			-- (step 6 P2) the device switcher, for a preset with a frame
			ui.presence(function(): string
				local _ = opts_ver:get()
				local dv = source.device and source.device:get()
				local st = settings()
				return if type(dv) == "table" and dv.frame then `{dv.device}|{st.framed}|{st.dfit}` else "none"
			end, function(_: string): Node
				return dev.button()
			end),
			ui.presence(function(): string
				local _ = opts_ver:get()
				local _ = source.device and source.device:get()
				local st = settings()
				return `{st.framed}|{st.fit}|{st.dfit}|{st.hints}`
			end, function(_: string): Node
				return options_btn()
			end),
			bar_btn("play-close", "Close", "x", props.on_close, "Esc"),
		}),
		-- (step 6 P3) the flows sidebar on the left, then the stage
		ui.row {
			id = "play-body",
			w_full = true,
			grow = 1,
			min_h = 0,
			dev.sidebar(),
			-- The stage.
			ui.overlay {
				id = "play-stage",
				grow = 1,
				min_w = 0,
				h_full = true,
				overflow = "hidden",
				cursor = function(): any
					if dev.cm and dev.cm.on:get() then
						return "crosshair" -- (step 7: a click leaves a comment)
					end
					return cursor:get()
				end,
				on_resize = function(s: { w: number, h: number })
					local now = stage:peek()
					if now.w ~= s.w or now.h ~= s.h then
						stage:set({ w = s.w, h = s.h })
						stage_resized()
					end
				end,
				on_pointer_move = function(e: any)
					if dev.cm and dev.cm.on:peek() then
						return -- (step 7: in comment mode the prototype doesn't react)
					end
					on_move(e)
				end,
				on_press = function(e: any)
					if dev.cm and dev.cm.press(e) then
						return
					end
					if dev.root_el then
						dev.root_el:focus()
					end
					on_press(e)
				end,
				on_release = function(e: any)
					if dev.cm and dev.cm.on:peek() then
						return
					end
					on_release(e)
				end,
				on_hover = function(on: boolean)
					if not on and not pressed then
						set_hover(nil, nil)
						-- (the pointer left the stage: every layer under it is left)
						triggers_move(nil, 0, 0, -1e9, -1e9)
					end
				end,
				on_wheel = function(e: any): boolean
					-- (F2a) the innermost scroller under the pointer that can still
					-- move that way takes the wheel, then the ones around it
					-- (an overlay under the pointer takes it; outside a modal one, nothing)
					local key, x, y = to_screen(e.local_x or 0, e.local_y or 0)
					local sd = key and slot_data[key]
					if coast and not busy then
						-- (F4-int: a Change to's motion still playing ends first)
						coast.coast_end()
					end
					if sd and sd.place and not busy then
						stop_glides(sd)
						local z = sd.place.z
						local dx, dy = (e.dx or 0) / z, (e.dy or 0) / z
						if e.shift and dx == 0 then
							-- (Shift turns the wheel sideways)
							dx, dy = dy, 0
						end
						scroll_by(sd, x, y, dx, dy)
					end
					return true
				end,
				-- (step 6 P2) the device's body, under the Screen
				ui.presence(function(): string
					local d = dev.pl:get()
					return if d then d.k else "none"
				end, function(_: string): Node
					return dev.layer("body")
				end),
				ui.div {
					id = "play-viewport",
					absolute = true,
					left = function(): number
						return vp:get().left
					end,
					top = function(): number
						return vp:get().top
					end,
					w = function(): number
						return vp:get().w
					end,
					h = function(): number
						return vp:get().h
					end,
					overflow = "hidden",
					pointer_events = "none",
					ui.each(slots, function(slot: any): Node
						-- (a copy: a state's value is read-only, and a component's props aren't)
						-- (not `id`: a component's `id` prop names its element)
						return ui.component(Screen)({ key = slot.key, screen = slot.id })
					end, {
						key = function(slot: any): string
							return slot.key
						end,
					}),
					-- (Smart Animate's movers, step 3: over the Screens' bases)
					ui.each(movers, function(spec: any): Node
						return ui.component(Mover)({ key = spec.key })
					end, {
						key = function(spec: any): string
							return spec.key
						end,
					}),
					-- (overlays, step 2: over the Screens, in stack order)
					ui.each(ovs, function(slot: any): Node
						return ui.component(OverlayView)({ key = slot.key, screen = slot.id })
					end, {
						key = function(slot: any): string
							return slot.key
						end,
					}),
					-- (L1: an overlay's Smart Animate movers, over the overlays)
					ui.each(ov_movers, function(spec: any): Node
						return ui.component(Mover)({ key = spec.key })
					end, {
						key = function(spec: any): string
							return spec.key
						end,
					}),
				},
				-- (step 6 P2) the corner mask and the island, over the Screen
				ui.presence(function(): string
					local d = dev.pl:get()
					return if d then d.k else "none"
				end, function(_: string): Node
					return dev.layer("over")
				end),
				-- (step 6 P6) the display's scale, measured once (see dev.scale)
				ui.div {
					id = "play-scale-probe",
					absolute = true,
					left = 0,
					top = 0,
					w = 32,
					h = 32,
					pointer_events = "none",
					on_mount = function(el: any)
						dev.measure_scale(el, 0)
					end,
				},
				-- (step 6 P6) Z's toast, at the device's bottom left as Figma's
				ui.column {
					id = "play-toast-at",
					absolute = true,
					bottom = 16,
					left = function(): number
						return math.max(16, math.floor(vp:get().left))
					end,
					pointer_events = "none",
					ui.each(dev.toast, function(t: any): Node
						return ui.row {
							id = "play-toast",
							role = "status",
							h = 26,
							px = 10,
							items = "center",
							rounded = 6,
							bg = "#2C2C2C",
							border = 1,
							border_color = D.border,
							ui.text { t.text, text_size = 11, weight = 500, font = Look.UI, color = D.fg },
						}
					end, {
						key = function(t: any): number
							return t.n
						end,
						enter = { opacity = { 0, 1 }, duration = 120 },
						exit = { opacity = { 1, 0 }, duration = 200 },
						pointer_events = "none",
					}),
				},
				-- (step 7) comment pins and their card, over the Screen
				if dev.cm then dev.cm.layer() else ui.div {},
				-- (step 6 P1) the bar hidden: a faint chip at the top right brings it back
				ui.show(function(): boolean
					return hide_ui:get()
				end, ui.button {
					id = "play-show-ui",
					label = "Show UI",
					tooltip = Kit.tip(L, "Show UI  Ctrl \\"),
					tooltip_placement = { side = "bottom", align = "end", offset = 8 },
					absolute = true,
					top = 8,
					right = 8,
					h = 26,
					px = 8,
					gap = 6,
					rounded = 8,
					border = 0,
					items = "center",
					bg = D.panel_solid or D.canvas,
					opacity = 0.55,
					hover = { opacity = 1 },
					focus = { outline = 0 },
					color = D.muted,
					on_click = toggle_ui,
					Kit.icon("eye", 13),
					ui.text { "Show UI", text_size = 12, weight = 500, font = Look.UI, color = D.fg },
				}),
			},
			-- (step 7) the comments sidebar, on the right
			if dev.cm then dev.cm.side() else ui.div {},
		},
	}
end

return M
