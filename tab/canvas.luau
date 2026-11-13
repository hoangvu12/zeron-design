--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The Design tab's Canvas, as pen.dev's: the Design drawn natively (draw.luau)
-- on a zgx canvas that pans and zooms with no script, and everything the
-- person does on it, from port/web/canvas.js:
--
-- - the view: the wheel pans (Shift: sideways), Ctrl+wheel or a pinch zooms
--   about the pointer, Space-drag or the middle button pans; Ctrl+0 is 100 %,
--   Shift+1 fits, Shift+2 zooms to the selection, Ctrl +/- step;
-- - selection: hover outline, click (a Screen's direct child first, deeper
--   inside the selection's branch, Ctrl the innermost), Shift adds or takes
--   away, a marquee from nothing or a Screen's background, Enter into the
--   children, Shift+Enter / Esc to the parent, a Screen's name picks it;
-- - hand edits, live as the pointer moves and one undo step on release:
--   move (snapping to siblings and the parent with smart guides and equal
--   spacing, reorder in auto layout, into another frame, Alt duplicates),
--   resize on 4 corners and 4 edges (Shift keeps the ratio, Alt from the
--   centre), rotate just outside a corner (Shift by 15°), arrows nudge
--   (Shift 10), Delete, Ctrl+D, Ctrl+Z / Ctrl+Shift+Z;
-- - double-click into groups, and into a text to edit it in place (a hidden
--   `ui.textarea` holds the words, as native's tab: IME-safe).
--
-- The Design comes from `source` (pure/CONTRACT.md: the service, or a fixture
-- for the harness): `roots` (roots.luau), the scene roots in paint order,
-- each `{ id, v, nodes }`, kept in Luau; the Canvas writes `live` beside a
-- root (`set_live`) while a drag shows it. Edits go out as `source.edit(ops, label, opts)`.

local Draw = require("./draw")
local Model = require("./model")
local Look = require("./look")

local ZOOM_MIN, ZOOM_MAX = 0.02, 25
local BOARD_STEP = 256
local BOARD_SETTLE_MS = 400
local CLICK_SLOP = 3
local DOUBLE_MS = 500
local SNAP_PX = 5
local FLASH_MS = 1400
local ZOOM_STEPS = { 0.02, 0.05, 0.1, 0.125, 0.25, 0.33, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 25 }

-- The overlay's colours, on the redesign's tokens (look.luau; its Board ·
-- Canvas): the person's accent, red guides, the agent's orange.
local function canvas_look(dark: boolean): any
	local T = Look.of(dark)
	return {
		board = T.canvas,
		accent = T.accent,
		accent_fg = T.accent_fg,
		on_accent = T.on_accent,
		component = T.component,
		instance = T.instance,
		guide = T.guide,
		name = T.faint,
		name_hover = T.fg,
		marquee = T.accent_soft,
		handle = "#ffffff",
		agent = T.agent, -- an agent building (inProgress)
		agent_soft = T.agent_soft,
		agent_text = T.agent_fg,
		flash_bg = T.fg, -- the "just changed" pill: the fg colour, canvas text
		flash_fg = T.canvas,
	}
end
local LOOK = { light = canvas_look(false), dark = canvas_look(true) }

export type Source = {
	roots: any, -- Roots (roots.luau): the roots in Luau, a light list in state
	selection: any, -- State<{ string }>
	edit: (ops: { any }, label: string?, opts: { join: boolean?, done: ((ok: boolean, res: any) -> ())? }?) -> (),
	undo: () -> (),
	redo: () -> (),
	select: ((ids: { string }) -> ())?,
	copy: ((ids: { string }, cut: boolean?, done: ((ok: boolean) -> ())?) -> ())?,
	flashes: any?, -- State<{ { id, chat, label?, at } }>
	dark: any?, -- State<boolean>
}

type Drag = {
	kind: string,
	from_x: number,
	from_y: number, -- tab points at the press
	at_x: number,
	at_y: number,
	px: number,
	py: number, -- Canvas point at the press
	shift: boolean,
	alt: boolean,
	deep: boolean,
	moved: boolean,
	[string]: any,
}

local function round(v: number): number
	return math.floor(v + 0.5)
end

local function fmt(v: number): string
	local r = round(v * 100) / 100
	if r == math.floor(r) then
		return tostring(math.floor(r))
	end
	return tostring(r)
end

return function(props: { source: Source, id: string?, expose: ((api: any) -> ())?, log: ((string) -> ())?, hover: any?, tool: any?, chrome: boolean?, context_menu: ((ids: { string }, x: number, y: number) -> { Node }?)?, menu_style: any?, insets: (() -> { l: number, t: number, r: number, b: number })?, on_find: (() -> ())?, on_palette: (() -> ())?, on_shortcuts: (() -> ())? }): Node
	local source = props.source
	local roots = source.roots
	local selection = source.selection
	local tab_id = props.id or "design"

	local view = ui.use_state(nil :: { x: number, y: number, zoom: number }?)
	local size = ui.use_state({ w = 0, h = 0 })
	-- The board canvas's own size: the panel's, in steps of BOARD_STEP, and
	-- only growing while the panel is being resized (settling to the
	-- tightest step once it stops). A canvas of a new size is rasterized and
	-- drawn again whole, so a resize that changed it every frame (dragging a
	-- splitter, a sidebar sliding shut) redrew the whole Design every frame;
	-- the overlay's `overflow = "hidden"` cuts what's past the panel.
	local board_size = ui.use_state({ w = 0, h = 0 })
	local resize_n = 0
	local hover = props.hover or ui.use_state(nil :: string?)
	-- The tool (pen.dev's rail): "move", "hand", "frame", "rectangle",
	-- "ellipse", "line", "text", "pen".
	local tool = props.tool or ui.use_state("move")
	-- The pen tool's points so far (Canvas units).
	local pen_pts = ui.use_state({} :: { { number } })
	-- What the overlay shows of a drag: guides, the marquee, the drop target,
	-- the live boxes of what's dragged (for outlines and handles).
	local shown = ui.use_state(nil :: any)
	local cursor = ui.use_state("default")
	local editing = ui.use_state(nil :: { id: string, content: string, anchor: number, focus: number }?)
	local alt_held = ui.use_state(false)
	-- What a move drags, lifted out of its Screen while it moves: each
	-- dragged subtree an item of its own (drawn over the board), so a move
	-- draws what moves alone, not its whole Screen.
	local lifted = ui.use_state({} :: { any })
	-- How far what's lifted has moved (Canvas units): its canvas's view is
	-- the board's moved by it, so a move translates what's drawn (zgx #2100)
	-- and draws nothing again.
	local lift_offset = ui.use_state({ dx = 0, dy = 0 })
	local space = false
	local drag: Drag? = nil
	local field = ui.ref()
	local surface = ui.ref()
	local field_focused = false
	local draw_done: (d: any) -> ()
	local eyedrop_done: ((hex: string) -> ())? = nil
	local color_at: (x: number, y: number) -> string?
	local finish_pen: (closed: boolean) -> ()
	local last_press: { at: number, x: number, y: number }? = nil

	-- The index of what's drawn, in Luau (a state would copy it to Rust and
	-- back): made again when the roots change, a root at a time
	-- (`ix_parts`: an agent's edit rewrites one root).
	local ix_parts = setmetatable({}, { __mode = "k" }) :: any
	local ix_cur: any = nil
	local ix_rev = -1
	local function ix_now(): any
		if ix_rev ~= roots.rev or not ix_cur then
			ix_cur = Model.index(roots:peek(), ix_parts)
			ix_rev = roots.rev
		end
		return ix_cur
	end
	local ix = {
		get = function(_self: any): any
			local _ = roots:get()
			return ix_now()
		end,
		peek = function(_self: any): any
			return ix_now()
		end,
	}

	local function look(): any
		local d = source.dark and source.dark:get()
		return if d then LOOK.dark else LOOK.light
	end

	-- View ---------------------------------------------------------------------------
	local function to_canvas(lx: number, ly: number): (number, number)
		local v = view:peek()
		if not v then
			return lx, ly
		end
		return (lx - v.x) / v.zoom, (ly - v.y) / v.zoom
	end

	local function set_view(x: number, y: number, zoom: number)
		view:set({ x = x, y = y, zoom = zoom })
	end

	local function pan(dx: number, dy: number)
		local v = view:peek()
		if v then
			set_view(v.x + dx, v.y + dy, v.zoom)
		end
	end

	local function zoom_at(zoom: number, ax: number, ay: number)
		local v = view:peek()
		if not v then
			return
		end
		zoom = math.clamp(zoom, ZOOM_MIN, ZOOM_MAX)
		local wx, wy = (ax - v.x) / v.zoom, (ay - v.y) / v.zoom
		set_view(ax - wx * zoom, ay - wy * zoom, zoom)
	end

	local function fit_rect(r: { number }?, max_zoom: number, whole: boolean?)
		local s = size:peek()
		if not r or s.w <= 0 or s.h <= 0 then
			return
		end
		-- (Within what the floating panels leave of it: `insets`; `whole`, as
		-- pen's zoom to fit, the whole board with a 12% margin, under the panels.)
		local ins = if props.insets and not whole then props.insets() else { l = 0, t = 0, r = 0, b = 0 }
		local aw, ah = math.max(40, s.w - ins.l - ins.r), math.max(40, s.h - ins.t - ins.b)
		local margin = if whole then math.floor(math.min(aw, ah) * 0.12) else 40
		local zoom = 1
		if r[3] > 0 and r[4] > 0 then
			zoom = math.clamp(math.min((aw - 2 * margin) / r[3], (ah - 2 * margin) / r[4], max_zoom), ZOOM_MIN, ZOOM_MAX)
		end
		set_view(ins.l + aw / 2 - (r[1] + r[3] / 2) * zoom, ins.t + ah / 2 - (r[2] + r[4] / 2) * zoom, zoom)
	end

	local function extent(): { number }?
		local i = ix:peek()
		local boxes = {}
		for _, id in i.kids[""] or {} do
			table.insert(boxes, i.by[id].bounds)
		end
		return Model.union(boxes)
	end

	local function fit()
		fit_rect(extent(), 1, true)
	end
	-- Dev only: scripted pans and zooms for measuring (dev/canvas_driver.luau,
	-- which isn't shipped; without it this does nothing).
	do
		local ok, Driver = pcall(function(): any
			return require("../dev/canvas_driver")
		end)
		if ok and type(Driver) == "table" then
			Driver.attach(tab_id, { view = view, zoom_at = zoom_at, pan = pan, fit = fit })
		end
	end

	local function zoom_step(dir: number)
		local v = view:peek()
		if not v then
			return
		end
		local s = size:peek()
		local z = v.zoom
		local nextz = z
		if dir > 0 then
			for _, step in ZOOM_STEPS do
				if step > z * 1.001 then
					nextz = step
					break
				end
			end
		else
			for i = #ZOOM_STEPS, 1, -1 do
				if ZOOM_STEPS[i] < z * 0.999 then
					nextz = ZOOM_STEPS[i]
					break
				end
			end
		end
		zoom_at(nextz, s.w / 2, s.h / 2)
	end

	-- The first sight of a Design: all of it, at most 100 %.
	ui.effect(function()
		local s = size:get()
		local list = roots:get()
		if view:peek() or s.w <= 0 or #list == 0 then
			return
		end
		fit()
	end)

	-- Selection ----------------------------------------------------------------------
	local function sel(): { string }
		return selection:peek() or {}
	end
	local function select(ids: { string })
		local i = ix:peek()
		local out = {}
		for _, id in ids do
			if i.by[id] then
				table.insert(out, id)
			end
		end
		selection:set(out)
		if source.select then
			source.select(out)
		end
	end
	local function has(list: { string }, id: string): boolean
		return table.find(list, id) ~= nil
	end

	-- A node's kind for its colour: a Component, an Instance (or inside one).
	local function kind(n: any): string
		if not n then
			return ""
		end
		if n.it.comp then
			return "component"
		end
		if n.it.inst or Model.is_inside_instance(n.id) then
			return "instance"
		end
		return ""
	end

	-- The parent lays the node out (its x and y don't count).
	local function laid_out(id: string): string?
		local i = ix:peek()
		local n = i.by[id]
		if not n or n.parent == "" or n.it.abs then
			return nil
		end
		local p = i.by[n.parent]
		return if p then p.it.lay else nil
	end

	-- Where the selection's handles go: one node (turned), or the union.
	local function frame_of(ids: { string }, boxes: { [string]: any }?): any?
		local i = ix:peek()
		local list = {}
		for _, id in ids do
			local n = i.by[id]
			if n then
				table.insert(list, n)
			end
		end
		if #list == 0 then
			return nil
		end
		if #list == 1 then
			local n = list[1]
			local live = boxes and boxes[n.id]
			local m = if live then live.m else n.m
			local w = if live then live.w else n.it.box.w
			local h = if live then live.h else n.it.box.h
			return { one = true, n = n, m = m, w = w, h = h }
		end
		local bs = {}
		for _, n in list do
			local live = boxes and boxes[n.id]
			table.insert(bs, if live then live.bounds else n.bounds)
		end
		local u = Model.union(bs) :: { number }
		return { one = false, m = Draw.translate(u[1], u[2]), w = u[3], h = u[4], u = u }
	end

	-- Live drags ------------------------------------------------------------------------
	-- Which roots a drag touches, and its live maps per root.
	local live_roots: { [number]: boolean } = {}
	local function set_live(per_root: { [number]: any })
		local list = roots:peek()
		for ri in live_roots do
			if not per_root[ri] and list[ri] and roots:live_at(ri) then
				roots:set_live(ri, false)
			end
		end
		table.clear(live_roots)
		for ri, live in per_root do
			live_roots[ri] = true
			-- (Tagged with the root's version: once the service answers with
			-- a newer root, what the drag showed is ignored, whatever order
			-- the writes land in.)
			live.v = if list[ri] then list[ri].v else nil
			roots:set_live(ri, live)
		end
	end
	local function clear_live()
		set_live({})
	end
	local function live_for(ids: { string }, make: (id: string) -> (any?, { w: number, h: number }?))
		local i = ix:peek()
		local per: { [number]: any } = {}
		for _, id in ids do
			local n = i.by[id]
			if n then
				local map, box = make(id)
				local l = per[n.root] or { maps = {}, boxes = {} }
				if map then
					l.maps[id] = map
				end
				if box then
					l.boxes[id] = box
				end
				per[n.root] = l
			end
		end
		set_live(per)
	end

	-- Edits -------------------------------------------------------------------------------
	local drop_lifted_ref: () -> () = function() end
	local canvas_el: any = nil
	local function send(ops: { any }, label: string, opts: any?)
		if #ops == 0 then
			clear_live()
			drop_lifted_ref()
			return
		end
		local o = opts or {}
		local done = o.done
		o.done = function(ok: boolean, res: any)
			if not ok then
				clear_live()
				drop_lifted_ref()
			end
			if done then
				done(ok, res)
			end
		end
		source.edit(ops, label, o)
	end

	-- Hit testing ------------------------------------------------------------------------
	local function screen_rect(n: any): { number }?
		local v = view:peek()
		if not v then
			return nil
		end
		local b = n.bounds
		return { v.x + b[1] * v.zoom, v.y + b[2] * v.zoom, b[3] * v.zoom, b[4] * v.zoom }
	end
	-- A Screen's name above it (where a press picks the Screen).
	local function label_at(lx: number, ly: number): string?
		local i = ix:peek()
		local top = i.kids[""] or {}
		for k = #top, 1, -1 do
			local n = i.by[top[k]]
			if n and n.it.t == "frame" then
				local r = screen_rect(n)
				if r and r[3] >= 24 then
					local w = math.min(r[3], 8 + 6.5 * #(n.it.name or ""))
					if lx >= r[1] and lx <= r[1] + w and ly >= r[2] - 20 and ly <= r[2] - 2 then
						return n.id
					end
				end
			end
		end
		return nil
	end

	-- The handle zone at tab point (lx, ly), for the selection.
	local function zone_at(lx: number, ly: number): any?
		if editing:peek() then
			return nil
		end
		local v = view:peek()
		local f = frame_of(sel())
		if not v or not f then
			return nil
		end
		-- In the frame's own space, in tab points.
		local inv = Draw.invert(f.m)
		local cx, cy = to_canvas(lx, ly)
		local fx, fy = Draw.apply(inv, cx, cy)
		local px, py = fx * v.zoom, fy * v.zoom
		local W, H = f.w * v.zoom, f.h * v.zoom
		for _, h in { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } } do
			local ex, ey = px - h[1] * W, py - h[2] * H
			if math.abs(ex) <= 6 and math.abs(ey) <= 6 then
				return { hx = h[1], hy = h[2], f = f }
			end
			local out_x = if h[1] == 1 then ex > 0 else ex < 0
			local out_y = if h[2] == 1 then ey > 0 else ey < 0
			local inside = px > 0 and px < W and py > 0 and py < H
			if f.one and math.sqrt(ex * ex + ey * ey) <= 22 and (out_x or out_y) and not inside and not label_at(lx, ly) then
				return { rotate = true, hx = h[1], hy = h[2], f = f }
			end
		end
		if W < 18 or H < 18 then
			return nil
		end
		if px > 6 and px < W - 6 then
			if math.abs(py) <= 4 then
				return { hx = 0.5, hy = 0, f = f }
			end
			if math.abs(py - H) <= 4 then
				return { hx = 0.5, hy = 1, f = f }
			end
		end
		if py > 6 and py < H - 6 then
			if math.abs(px) <= 4 then
				return { hx = 0, hy = 0.5, f = f }
			end
			if math.abs(px - W) <= 4 then
				return { hx = 1, hy = 0.5, f = f }
			end
		end
		return nil
	end

	local RESIZE_CURSORS = { "ew_resize", "nwse_resize", "ns_resize", "nesw_resize" }
	local function zone_cursor(z: any): string
		if z.rotate then
			return "crosshair"
		end
		local ang
		if z.hx ~= 0.5 and z.hy ~= 0.5 then
			ang = math.atan2(z.hy - 0.5, z.hx - 0.5)
		else
			ang = math.atan2((z.hy - 0.5) * math.max(z.f.h, 1), (z.hx - 0.5) * math.max(z.f.w, 1))
		end
		ang += math.atan2(z.f.m.b, z.f.m.a)
		local k = (round(ang / (math.pi / 4)) % 4 + 4) % 4
		return RESIZE_CURSORS[k + 1]
	end

	-- Text editing ------------------------------------------------------------------------
	local text_queue: { any } = {}
	local text_sending = false
	local function send_text()
		if text_sending or #text_queue == 0 then
			return
		end
		local change = table.remove(text_queue, 1)
		text_sending = true
		source.edit({ { op = "text", id = change.id, text = change.text } }, "Edit text", {
			join = change.join,
			done = function()
				text_sending = false
				send_text()
			end,
		})
	end
	local function queue_text(id: string, text: string, join: boolean)
		local last = text_queue[#text_queue]
		if last and join and last.id == id then
			last.text = text
		else
			table.insert(text_queue, { id = id, text = text, join = join })
		end
		send_text()
	end
	local typed_once = false
	local function text_live(id: string, content: string?)
		local n = ix:peek().by[id]
		if not n then
			return
		end
		local per: { [number]: any } = {}
		if content then
			per[n.root] = { texts = { [id] = content } }
		end
		set_live(per)
	end
	local function start_editing(id: string)
		local n = ix:peek().by[id]
		if not n or not n.it.text then
			return
		end
		local content = n.it.text.s or ""
		typed_once = false
		select({ id })
		editing:set({ id = id, content = content, anchor = #content, focus = #content })
	end
	local function finish_editing()
		local e = editing:peek()
		if not e then
			return
		end
		editing:set(nil)
		local el = surface:peek()
		if el then
			el:focus()
		end
		-- (The words stay drawn as typed until the service's scene comes.)
	end

	-- Pointer ---------------------------------------------------------------------------
	local function begin_move(d: Drag)
		local i = ix:peek()
		local ids = Model.topmost(i, sel())
		if #ids == 0 then
			d.kind = "noop"
			return
		end
		local bs = {}
		for _, id in ids do
			table.insert(bs, i.by[id].bounds)
		end
		local first = i.by[ids[1]]
		d.kind = "move"
		d.ids = ids
		d.union0 = Model.union(bs)
		local v = view:peek() :: any
		local s = size:peek()
		local x0, y0 = to_canvas(0, 0)
		d.T = Model.snap_targets(i, ids, { x0 - s.w / v.zoom, y0 - s.h / v.zoom, 3 * s.w / v.zoom, 3 * s.h / v.zoom })
		d.parent = first.parent
		d.can_reparent = not (first.depth == 0 and first.it.t == "frame")
		for _, id in ids do
			if Model.is_inside_instance(id) then
				d.can_reparent = false
			end
		end
		d.dup = d.alt
		d.dx, d.dy = 0, 0
		-- Lifted: each subtree drawn on its own; its Screen leaves it out
		-- (one draw of that Screen now, and one when the answer comes).
		local list = roots:peek()
		local items = {}
		local hide: { [number]: any } = {}
		for _, id in ids do
			local n = i.by[id]
			local root = list[n.root]
			local count = (n.it.n or 0)
			local slice = table.move(root.nodes, n.at, n.at + count, 1, {})
			local op0 = 1
			local p = i.by[n.parent]
			while p do
				op0 *= p.it.op or 1
				p = i.by[p.parent]
			end
			table.insert(items, { id = id, root = root.id, src_v = root.v, nodes = slice, op0 = op0, live = false })
			local h = hide[n.root] or { hide = {} }
			h.hide[id] = true
			hide[n.root] = h
		end
		set_live(hide)
		lifted:set(items)
		d.lifted = true
	end

	-- The innermost frame under (x, y) that doesn't move; "" is the Canvas.
	local function drop_target(x: number, y: number, ids: { string }): string
		local i = ix:peek()
		local s = Model.stack_at(i, x, y, false)
		for k = #s, 1, -1 do
			local n = s[k]
			local moving = has(ids, n.id)
			for _, id in ids do
				if Model.under(i, n.id, id) then
					moving = true
				end
			end
			if n.it.t == "frame" and not moving and not Model.is_inside_instance(n.id) then
				return n.id
			end
		end
		return ""
	end

	local function move_to(d: Drag, x: number, y: number, e: any)
		local i = ix:peek()
		local v = view:peek() :: any
		local dx, dy = x - d.px, y - d.py
		if e.shift then
			if math.abs(dx) > math.abs(dy) then
				dy = 0
			else
				dx = 0
			end
		end
		d.target = nil
		d.insertion = nil
		d.index = nil
		local own = if d.parent ~= "" and laid_out(d.ids[1]) then i.by[d.parent] else nil
		local target = d.parent
		if d.can_reparent and not e.ctrl and not (own and Model.inside(own, x, y)) then
			target = drop_target(x, y, d.ids)
		end
		local reparent = target ~= d.parent
		local tn = if target ~= "" then i.by[target] else nil
		local lay = if tn then tn.it.lay else nil
		local in_layout = lay ~= nil and (reparent or laid_out(d.ids[1]) ~= nil)
		if reparent then
			d.target = target
		end
		local m = { d.union0[1] + dx, d.union0[2] + dy, d.union0[3], d.union0[4] }
		local guides = nil
		if not in_layout and not reparent and not e.ctrl then
			local sx, sy = Model.snap_box(m, d.T, SNAP_PX / v.zoom, e.shift and dx == 0, e.shift and dy == 0)
			dx += sx
			dy += sy
			m = { d.union0[1] + dx, d.union0[2] + dy, d.union0[3], d.union0[4] }
			guides = Model.guides_for(m, d.T, v.zoom)
		end
		dx, dy = round(dx), round(dy)
		d.dx, d.dy = dx, dy
		if in_layout and tn then
			-- Auto layout: where among the siblings it goes, shown as a line.
			local hor = lay == "horizontal"
			local sib = {}
			for _, id in i.kids[tn.id] or {} do
				local n = i.by[id]
				if not has(d.ids, id) and not n.it.abs then
					table.insert(sib, n)
				end
			end
			local pos = if hor then x else y
			local k = #sib + 1
			for j, n in sib do
				local b = n.bounds
				if pos < (if hor then b[1] + b[3] / 2 else b[2] + b[4] / 2) then
					k = j
					break
				end
			end
			local full = {}
			for _, id in i.kids[tn.id] or {} do
				if not has(d.ids, id) then
					table.insert(full, id)
				end
			end
			d.index = if k <= #sib then (table.find(full, sib[k].id) :: number) - 1 else #full
			local pb = tn.bounds
			local at
			if k <= #sib then
				at = if hor then sib[k].bounds[1] - 2 else sib[k].bounds[2] - 2
			elseif #sib > 0 then
				local b = sib[#sib].bounds
				at = if hor then b[1] + b[3] + 2 else b[2] + b[4] + 2
			else
				at = if hor then pb[1] + 4 else pb[2] + 4
			end
			d.insertion = if hor then { at, pb[2] + 2, at, pb[2] + pb[4] - 2 } else { pb[1] + 2, at, pb[1] + pb[3] - 2, at }
		end
		-- Live: what moves follows the pointer (in auto layout, too: the
		-- layout places it on release).
		local boxes = {}
		local o = lift_offset:peek()
		if o.dx ~= dx or o.dy ~= dy then
			lift_offset:set({ dx = dx, dy = dy })
		end
		for _, id in d.ids do
			local n = i.by[id]
			local b = n.bounds
			boxes[id] = { m = Draw.compose(Draw.translate(dx, dy), n.m), w = n.it.box.w, h = n.it.box.h, bounds = { b[1] + dx, b[2] + dy, b[3], b[4] } }
		end
		shown:set({ kind = "move", guides = guides, boxes = boxes, target = d.target, insertion = d.insertion, ids = d.ids })
	end

	local function resize_to(d: Drag, x: number, y: number, e: any)
		local i = ix:peek()
		local v = view:peek() :: any
		local f = d.frame
		local inv = Draw.invert(f.m)
		local lx, ly = Draw.apply(inv, x, y)
		local w, h = f.w, f.h
		local from_centre, keep = e.alt, e.shift
		local x0, y0, x1, y1 = 0, 0, w, h
		local thr = SNAP_PX / v.zoom
		local up = Draw.upright(f.m)
		local guides = nil
		if up and d.T and not e.ctrl then
			local lines_x, lines_y = {}, {}
			local all = table.clone(d.T.boxes)
			if d.T.parent then
				table.insert(all, d.T.parent)
			end
			for _, b in all do
				for _, q in Model.xs_of(b) do
					table.insert(lines_x, q)
				end
				for _, q in Model.ys_of(b) do
					table.insert(lines_y, q)
				end
			end
			if d.hx ~= 0.5 then
				local sn = Model.snap1({ f.m.e + lx }, lines_x, thr)
				if sn then
					lx += sn
				end
			end
			if d.hy ~= 0.5 then
				local sn = Model.snap1({ f.m.f + ly }, lines_y, thr)
				if sn then
					ly += sn
				end
			end
		end
		if d.hx == 0 then
			x0 = lx
		elseif d.hx == 1 then
			x1 = lx
		end
		if d.hy == 0 then
			y0 = ly
		elseif d.hy == 1 then
			y1 = ly
		end
		if from_centre then
			if d.hx == 0 then
				x1 = w - x0
			elseif d.hx == 1 then
				x0 = w - x1
			end
			if d.hy == 0 then
				y1 = h - y0
			elseif d.hy == 1 then
				y0 = h - y1
			end
		end
		local nw, nh = x1 - x0, y1 - y0
		if nw < 1 then
			if d.hx == 0 then
				x0 = x1 - 1
			else
				x1 = x0 + 1
			end
			nw = 1
		end
		if nh < 1 then
			if d.hy == 0 then
				y0 = y1 - 1
			else
				y1 = y0 + 1
			end
			nh = 1
		end
		if keep and w > 0 and h > 0 then
			local r = w / h
			if d.hx == 0.5 then
				nw = nh * r
				x0, x1 = w / 2 - nw / 2, w / 2 + nw / 2
			elseif d.hy == 0.5 then
				nh = nw / r
				y0, y1 = h / 2 - nh / 2, h / 2 + nh / 2
			else
				if nw / w > nh / h then
					nh = nw / r
				else
					nw = nh * r
				end
				if from_centre then
					x0, y0 = (w - nw) / 2, (h - nh) / 2
					x1, y1 = x0 + nw, y0 + nh
				else
					if d.hx == 0 then
						x0 = x1 - nw
					else
						x1 = x0 + nw
					end
					if d.hy == 0 then
						y0 = y1 - nh
					else
						y1 = y0 + nh
					end
				end
			end
		end
		x0, y0 = round(x0), round(y0)
		x1, y1 = math.max(x0 + 1, round(x1)), math.max(y0 + 1, round(y1))
		local ntlx, ntly = Draw.apply(f.m, x0, y0)
		local nb = { ntlx, ntly, x1 - x0, y1 - y0 }
		local boxes = {}
		local results: { [string]: any } = {}
		if d.one then
			local id = d.ids[1]
			local n = i.by[id]
			local ox, oy = Draw.apply(n.m, 0, 0)
			local tm = Draw.translate(ntlx - ox, ntly - oy)
			results[id] = { map = tm, w = x1 - x0, h = y1 - y0, dx = ntlx - ox, dy = ntly - oy }
			local m2 = Draw.compose(tm, n.m)
			local bx, by, bw, bh = Draw.canvas_bounds({ box = { w = x1 - x0, h = y1 - y0 } }, m2)
			boxes[id] = { m = m2, w = x1 - x0, h = y1 - y0, bounds = { bx, by, bw, bh } }
		else
			local kx, ky = nb[3] / math.max(w, 1), nb[4] / math.max(h, 1)
			for _, id in d.ids do
				local n = i.by[id]
				local b = n.bounds
				local nx, ny = round(nb[1] + (b[1] - f.m.e) * kx), round(nb[2] + (b[2] - f.m.f) * ky)
				local ww, hh = math.max(1, round(n.it.box.w * kx)), math.max(1, round(n.it.box.h * ky))
				results[id] = { map = Draw.translate(nx - b[1], ny - b[2]), w = ww, h = hh, dx = nx - b[1], dy = ny - b[2] }
				boxes[id] = { m = Draw.compose(results[id].map, n.m), w = ww, h = hh, bounds = { nx, ny, ww, hh } }
			end
		end
		d.results = results
		live_for(d.ids, function(id: string): (any?, any?)
			local r = results[id]
			return r.map, { w = r.w, h = r.h }
		end)
		if up and d.T then
			guides = Model.guides_for(nb, d.T, v.zoom)
			guides.gaps = {}
		end
		shown:set({ kind = "resize", guides = guides, boxes = boxes, ids = d.ids })
	end

	local function rotate_to(d: Drag, x: number, y: number, e: any)
		local i = ix:peek()
		local n = i.by[d.ids[1]]
		local da = math.atan2(y - d.cy, x - d.cx) - d.from0
		-- (Screen angle clockwise; the file's counter-clockwise.)
		local deg = d.rot0 - math.deg(da)
		deg = if e.shift then round(deg / 15) * 15 else round(deg)
		deg = ((deg + 180) % 360 + 360) % 360 - 180
		if deg == -180 then
			deg = 180
		end
		d.rotation = deg
		local delta = deg - d.rot0
		local map = Draw.rotation(delta, d.cx, d.cy)
		live_for({ n.id }, function(): (any?, any?)
			return map, nil
		end)
		local m2 = Draw.compose(map, n.m)
		local bx, by, bw, bh = Draw.canvas_bounds(n.it, m2)
		d.map = map
		shown:set({
			kind = "rotate",
			boxes = { [n.id] = { m = m2, w = n.it.box.w, h = n.it.box.h, bounds = { bx, by, bw, bh } } },
			ids = { n.id },
			angle = deg,
		})
	end

	local function marquee_to(d: Drag, x: number, y: number, e: any)
		local i = ix:peek()
		local r = { math.min(d.px, x), math.min(d.py, y), math.abs(x - d.px), math.abs(y - d.py) }
		local found = {}
		if e.ctrl or e.cmd then
			for _, id in i.order do
				local n = i.by[id]
				local in_scope = d.scope == "" or Model.under(i, id, d.scope)
				if in_scope and not n.it.lock and not Model.is_inside_instance(id) and (n.it.n or 0) == 0 and Model.meets(n.bounds, r) then
					table.insert(found, id)
				end
			end
		else
			local scope = d.scope
			if d.screen and not Model.contains(i.by[d.screen].bounds, r) then
				scope = ""
			end
			for _, id in i.kids[scope] or {} do
				local n = i.by[id]
				if not n.it.lock and Model.meets(n.bounds, r) then
					local kids = i.kids[id]
					-- pen, on the board: a Screen the box only partly covers
					-- gives its children the box touches; a whole one, itself.
					if scope == "" and kids and #kids > 0 and n.it.t ~= "instance" and not Model.contains(r, n.bounds) then
						for _, kid in kids do
							local k = i.by[kid]
							if k and not k.it.lock and Model.meets(k.bounds, r) then
								table.insert(found, kid)
							end
						end
					else
						table.insert(found, id)
					end
				end
			end
		end
		if d.shift then
			local out = {}
			for _, id in d.start do
				if not has(found, id) then
					table.insert(out, id)
				end
			end
			for _, id in found do
				if not has(d.start, id) then
					table.insert(out, id)
				end
			end
			found = out
		end
		select(found)
		shown:set({ kind = "marquee", rect = r })
	end

	-- The lifted layer goes once every Screen it came from has been answered
	-- (a newer `v`), or at once when nothing was sent.
	ui.effect(function()
		local list = roots:get()
		local items = lifted:peek()
		if #items == 0 then
			return
		end
		for _, item in items do
			local still = false
			for _, r in list do
				if r.id == item.root then
					still = r.v == item.src_v
				end
			end
			if still and not item.done then
				return
			end
		end
		lifted:set({})
		lift_offset:set({ dx = 0, dy = 0 })
	end)
	local function drop_lifted()
		if #lifted:peek() > 0 then
			lifted:set({})
		lift_offset:set({ dx = 0, dy = 0 })
		end
	end
	drop_lifted_ref = drop_lifted

	-- What a tool makes (pen.dev's defaults), at a rectangle on the Canvas.
	local function make_node(t: string, w: number, h: number): any
		if t == "frame" then
			return { type = "frame", name = "Frame", width = w, height = h, fill = "#FFFFFF" }
		elseif t == "rectangle" then
			return { type = "rectangle", name = "Rectangle", width = w, height = h, fill = "#D9D9D9" }
		elseif t == "ellipse" then
			return { type = "ellipse", name = "Ellipse", width = w, height = h, fill = "#D9D9D9" }
		elseif t == "text" then
			return { type = "text", name = "Text", content = "Text", fontSize = 16, fill = "#000000" }
		elseif t == "line" then
			return { type = "path", name = "Line", width = w, height = h, geometry = `M0 0 L{w} {h}`, stroke = { fill = "#000000", thickness = 1, align = "center" } }
		end
		return { type = "frame", name = "Frame", width = w, height = h }
	end
	local function insert(node: any, parent: string, x: number, y: number, label: string, after: ((ids: { string }) -> ())?)
		local op: any = { op = "insert", node = node, at = { x = x, y = y } }
		if parent ~= "" then
			op.parent = parent
		end
		source.edit({ op }, label, {
			done = function(ok: boolean, res: any)
				if ok and type(res) == "table" and res.ids and #res.ids > 0 then
					select(res.ids)
					if after then
						after(res.ids)
					end
				end
			end,
		})
	end
	function draw_done(d: Drag)
		local t = d.tool
		tool:set("move")
		local r = d.rect
		local x, y, w, h = d.px, d.py, 100, 100
		if d.moved and r and t ~= "text" then
			x, y, w, h = r[1], r[2], math.max(1, r[3]), math.max(1, r[4])
		end
		if t == "line" and d.moved and d.line then
			local l = d.line
			x, y = math.min(l[1], l[3]), math.min(l[2], l[4])
			w, h = math.abs(l[3] - l[1]), math.abs(l[4] - l[2])
			local ax, ay, bx, by = l[1] - x, l[2] - y, l[3] - x, l[4] - y
			local node = make_node("line", math.max(w, 1), math.max(h, 1))
			node.geometry = `M{round(ax)} {round(ay)} L{round(bx)} {round(by)}`
			insert(node, d.parent or "", round(x), round(y), "Draw line")
			return
		end
		local node = make_node(t, w, h)
		insert(node, d.parent or "", round(x), round(y), "Draw " .. t, if t == "text" then function(ids: { string })
			ui.after(0, function()
				start_editing(ids[1])
			end)
		end else nil)
	end
	-- The pen's points as a path (closed, or open).
	function finish_pen(closed: boolean)
		local pts = pen_pts:peek()
		pen_pts:set({})
		tool:set("move")
		if #pts < 2 then
			return
		end
		local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
		for _, q in pts do
			x0, y0, x1, y1 = math.min(x0, q[1]), math.min(y0, q[2]), math.max(x1, q[1]), math.max(y1, q[2])
		end
		local w, h = math.max(1, round(x1 - x0)), math.max(1, round(y1 - y0))
		local parts = {}
		for k, q in pts do
			table.insert(parts, `{if k == 1 then "M" else "L"}{round(q[1] - x0)} {round(q[2] - y0)}`)
		end
		if closed then
			table.insert(parts, "Z")
		end
		local node: any = { type = "path", name = "Path", width = w, height = h, geometry = table.concat(parts, " "), viewBox = { 0, 0, w, h }, stroke = { fill = "#000000", thickness = 1.5, align = "center" } }
		if closed then
			node.fill = "#D9D9D9"
		end
		insert(node, drop_target(pts[1][1], pts[1][2], {}), round(x0), round(y0), "Draw path")
	end

	-- The Design's colour at a Canvas point: the topmost node there that
	-- paints one (a solid fill, a text's or an icon's colour; a gradient's
	-- first stop).
	function color_at(x: number, y: number): string?
		local i = ix:peek()
		for k = #i.order, 1, -1 do
			local n = i.by[i.order[k]]
			if n and not n.it.hidden and Model.inside(n, x, y) then
				local it = n.it
				if it.icon and it.icon.color then
					return it.icon.color
				end
				for f = #(it.fill or {}), 1, -1 do
					local paint = it.fill[f]
					if paint.k == "solid" then
						return paint.color
					elseif paint.stops and paint.stops[1] then
						return paint.stops[1].color
					end
				end
			end
		end
		return nil
	end
	-- A node alone (its subtree), drawn as the Canvas draws it, as a PNG.
	-- One layer drawn alone (Export): a promise of its picture in base64,
	-- PNG unless `opts.format` ("jpeg", "webp": zgx #2116) says otherwise;
	-- and its size in points. Nil and why when it can't be drawn.
	-- (`opts.measure`: only the layer's size, nothing drawn: `true, {w, h}`.)
	local function render_layer(id: string, scale: number, opts: { format: string?, quality: number?, measure: boolean?, file: any? }?): (any, string | { w: number, h: number })
		local i = ix:peek()
		local n = i.by[id]
		if not n then
			return nil, "not found"
		end
		local b = n.bounds
		if opts and opts.measure then
			return true, { w = math.max(1, b[3]), h = math.max(1, b[4]) }
		end
		local root = roots:peek()[n.root]
		local slice = table.move(root.nodes, n.at, n.at + (n.it.n or 0), 1, {})
		local o: any = { width = math.max(1, b[3]), height = math.max(1, b[4]), scale = scale, x = b[1], y = b[2] }
		if opts and opts.format and opts.format ~= "png" then
			o.format = opts.format
			o.quality = opts.quality
		end
		-- (`opts.file`: written there by zgx at full size, zgx#2118; the
		-- promise then gives nil)
		if opts and opts.file then
			o.file = opts.file
		end
		local ok, promise = pcall(ui.render_canvas, function(c: Canvas)
			Draw.draw_root(c, { nodes = slice })
		end, o)
		if not ok then
			return nil, tostring(promise)
		end
		return promise, { w = o.width, h = o.height }
	end

	local function render_png(id: string, scale: number, done: (b64: string?, err: string?) -> ())
		local promise, why = render_layer(id, scale)
		if not promise then
			done(nil, tostring(why))
			return
		end
		promise:after(function(png: string)
			done(png, nil)
		end, function(err: any)
			done(nil, tostring(err))
		end)
	end

	local function finish(d: Drag, cancel: boolean)
		if props.log then
			props.log(`drop {d.kind} moved={d.moved} dx={d.dx} dy={d.dy} ids={if d.ids then #d.ids else 0} target={d.target} index={d.index}`)
		end
		shown:set(nil)
		cursor:set(if space then "grab" else "default")
		if cancel then
			if d.kind == "marquee" then
				select(d.start)
			end
			clear_live()
			drop_lifted()
			return
		end
		local i = ix:peek()
		if d.kind == "draw" then
			draw_done(d)
			return
		end
		if d.kind == "press" and not d.moved and d.click and not d.shift then
			local s = sel()
			if not (#s == 1 and s[1] == d.click) then
				select({ d.click })
			end
		elseif d.kind == "marquee" and not d.moved and not d.shift then
			select(if d.screen then { d.screen } else {})
		elseif d.kind == "move" and d.moved then
			local ops = {}
			local label = "Move"
			if d.dup then
				table.insert(ops, { op = "duplicate", ids = d.ids, dx = d.dx, dy = d.dy })
				label = "Duplicate"
			elseif d.target ~= nil then
				local op: any = { op = "reparent", ids = d.ids, parent = if d.target == "" then "__null" else d.target }
				if d.index then
					op.index = d.index
				end
				table.insert(ops, op)
				local tn = i.by[d.target]
				if not (tn and tn.it.lay) then
					for _, id in d.ids do
						table.insert(ops, { op = "move", id = id, dx = d.dx, dy = d.dy })
					end
				end
			elseif d.index then
				for k, id in d.ids do
					table.insert(ops, { op = "reorder", id = id, index = d.index + k - 1 })
				end
				label = "Reorder"
			elseif d.dx ~= 0 or d.dy ~= 0 then
				for _, id in d.ids do
					if not laid_out(id) then
						table.insert(ops, { op = "move", id = id, dx = d.dx, dy = d.dy })
					end
				end
			end
			send(ops, label)
		elseif d.kind == "resize" and d.moved and d.results then
			local ops = {}
			for _, id in d.ids do
				local r = d.results[id]
				local n = i.by[id]
				if (math.abs(r.dx) > 0.01 or math.abs(r.dy) > 0.01) and not laid_out(id) then
					table.insert(ops, { op = "move", id = id, dx = round(r.dx * 100) / 100, dy = round(r.dy * 100) / 100 })
				end
				if r.w ~= n.it.box.w or r.h ~= n.it.box.h then
					table.insert(ops, { op = "resize", id = id, w = r.w, h = r.h })
				end
			end
			send(ops, "Resize")
		elseif d.kind == "rotate" and d.moved and d.rotation ~= nil then
			local id = d.ids[1]
			local n = i.by[id]
			if d.rotation == d.rot0 then
				clear_live()
			drop_lifted()
				return
			end
			-- The node turns about its centre: its top-left moves.
			local ox, oy = Draw.apply(n.m, 0, 0)
			local nx, ny = Draw.apply(d.map, ox, oy)
			local ops: { any } = { { op = "update", id = id, props = { rotation = if d.rotation == 0 then "__null" else d.rotation } } }
			if not laid_out(id) then
				-- (Moved in its parent's space: the file's x, y are before rotation.)
				local p = i.by[n.parent]
				local pinv = if p then Draw.invert(p.m) else Draw.translate(0, 0)
				local ax, ay = Draw.apply(pinv, ox, oy)
				local bx, by = Draw.apply(pinv, nx, ny)
				table.insert(ops, { op = "move", id = id, dx = round((bx - ax) * 100) / 100, dy = round((by - ay) * 100) / 100 })
			end
			send(ops, "Rotate")
		else
			clear_live()
			drop_lifted()
		end
	end

	local function press_on(id: string?, d: Drag, is_label: boolean)
		local i = ix:peek()
		local s = sel()
		local f = if not is_label and #s > 0 then frame_of(s) else nil
		local on_sel = (id ~= nil and has(s, id))
		if not on_sel and f then
			local inv = Draw.invert(f.m)
			local fx, fy = Draw.apply(inv, d.px, d.py)
			on_sel = fx >= 0 and fy >= 0 and fx <= f.w and fy <= f.h
		end
		if on_sel and not d.shift then
			d.kind, d.id, d.click = "press", id, id
			return
		end
		local n = if id then i.by[id] else nil
		local kids = if n then i.kids[n.id] else nil
		if not is_label and (not n or (n.depth == 0 and n.it.t == "frame" and not has(s, n.id) and kids and #kids > 0 and not d.deep)) then
			d.kind = "marquee"
			d.scope = if n then n.id else ""
			d.screen = if n then n.id else nil
			d.start = table.clone(s)
			return
		end
		if d.shift and id then
			local out = {}
			if has(s, id) then
				for _, o in s do
					if o ~= id then
						table.insert(out, o)
					end
				end
			else
				for _, o in s do
					if not Model.under(i, id, o) and not Model.under(i, o, id) then
						table.insert(out, o)
					end
				end
				table.insert(out, id)
			end
			select(out)
			d.kind, d.id = "press", nil
			return
		end
		if id then
			select({ id })
		end
		d.kind, d.id = "press", id
	end

	local function on_press(e: any)
		local v = view:peek()
		if not v then
			return
		end
		local el = surface:peek()
		local ed = editing:peek()
		local cx, cy = to_canvas(e.local_x, e.local_y)
		if ed then
			local n = ix:peek().by[ed.id]
			if n and Model.inside(n, cx, cy) then
				return -- (the field keeps the caret; clicks inside place it on release)
			end
			finish_editing()
		elseif el then
			el:focus()
		end
		local d: Drag = {
			kind = "none",
			from_x = e.local_x,
			from_y = e.local_y,
			at_x = e.local_x,
			at_y = e.local_y,
			px = cx,
			py = cy,
			shift = e.shift,
			alt = e.alt,
			deep = e.ctrl or e.meta,
			moved = false,
		}
		drag = d
		local t = tool:peek()
		if space or t == "hand" then
			d.kind = "pan"
			cursor:set("grabbing")
			return
		end
		if t == "eyedrop" then
			d.kind = "noop"
			tool:set("move")
			local done = eyedrop_done
			eyedrop_done = nil
			local hex = color_at(cx, cy)
			if props.log then
				props.log(`eyedrop {math.floor(cx)},{math.floor(cy)}: {hex or "nothing"} {if done then "" else "(no picker)"}`)
			end
			if done and hex then
				done(hex)
			end
			return
		end
		if t == "pen" then
			d.kind = "noop"
			local pts = table.clone(pen_pts:peek())
			local first = pts[1]
			local v0 = view:peek() :: any
			-- (A press on the first point closes it.)
			if first and #pts > 2 and math.abs(first[1] - cx) * v0.zoom < 6 and math.abs(first[2] - cy) * v0.zoom < 6 then
				finish_pen(true)
				return
			end
			table.insert(pts, { cx, cy })
			pen_pts:set(pts)
			return
		end
		if t ~= "move" then
			d.kind = "draw"
			d.tool = t
			d.parent = drop_target(cx, cy, {})
			return
		end
		-- A second press on one spot (the system's count, or ours: inspect's
		-- replays count each press alone): into the group under the pointer,
		-- or into a text to edit it.
		local now = ui.now()
		local lp = last_press
		local again = (e.clicks or 1) >= 2
			or (lp ~= nil and now - lp.at < DOUBLE_MS and math.abs(lp.x - e.local_x) <= 4 and math.abs(lp.y - e.local_y) <= 4)
		last_press = if again then nil else { at = now, x = e.local_x, y = e.local_y }
		if again then
			d.kind = "noop"
			local s = sel()
			local one = if #s == 1 then ix:peek().by[s[1]] else nil
			if one and one.it.t == "text" and Model.inside(one, cx, cy) then
				start_editing(one.id)
				return
			end
			local deeper = Model.hit(ix:peek(), cx, cy, s, false, if one then one.id else nil)
			if deeper then
				select({ deeper })
				local dn = ix:peek().by[deeper]
				if dn and dn.it.t == "text" and one and deeper == one.id then
					start_editing(deeper)
				end
			end
			return
		end
		local z = zone_at(e.local_x, e.local_y)
		if z then
			local s = sel()
			local i = ix:peek()
			d.ids = Model.topmost(i, s)
			d.one = z.f.one
			d.frame = z.f
			d.hx, d.hy = z.hx, z.hy
			if z.rotate then
				local n = z.f.n
				local cx2, cy2 = Draw.apply(n.m, n.it.box.w / 2, n.it.box.h / 2)
				d.kind = "rotate"
				d.cx, d.cy = cx2, cy2
				d.from0 = math.atan2(cy - cy2, cx - cx2)
				d.rot0 = n.it.rot or 0
				-- (A turned ancestor: the node's own angle on screen.)
				local own = -math.deg(math.atan2(n.m.b, n.m.a))
				d.rot0 = if n.it.rot then n.it.rot else own
				d.ids = { n.id }
			else
				d.kind = "resize"
				d.T = Model.snap_targets(i, d.ids, nil)
			end
			return
		end
		local label = label_at(e.local_x, e.local_y)
		if label then
			press_on(label, d, true)
			return
		end
		local id = Model.hit(ix:peek(), cx, cy, sel(), d.deep, nil)
		press_on(id, d, false)
	end

	-- Script time of each pointer move and each overlay draw (ms), the last
	-- 600 of each, for the harness's perf numbers.
	local perf = { move = {} :: { number }, overlay = {} :: { number }, items = {} :: { number } }
	local function note(list: { number }, ms: number)
		table.insert(list, ms)
		if #list > 600 then
			table.remove(list, 1)
		end
	end

	local on_move_inner: (e: any) -> ()
	local function on_move(e: any)
		local t0 = os.clock()
		on_move_inner(e)
		note(perf.move, (os.clock() - t0) * 1000)
	end
	function on_move_inner(e: any)
		local v = view:peek()
		if not v then
			return
		end
		local d = drag
		if not d then
			if editing:peek() then
				return
			end
			local z = if not space then zone_at(e.local_x, e.local_y) else nil
			local t = tool:peek()
			cursor:set(if space or t == "hand" then "grab" elseif t == "eyedrop" then "crosshair" elseif t ~= "move" then "crosshair" elseif z then zone_cursor(z) else "default")
			local cx, cy = to_canvas(e.local_x, e.local_y)
			local held = ui.modifiers
			local h = label_at(e.local_x, e.local_y) or Model.hit(ix:peek(), cx, cy, sel(), held.control:peek() or held.meta:peek(), nil)
			if hover:peek() ~= h then
				hover:set(h)
			end
			return
		end
		local mx, my = e.local_x - d.at_x, e.local_y - d.at_y
		d.at_x, d.at_y = e.local_x, e.local_y
		if not d.moved and math.abs(e.local_x - d.from_x) + math.abs(e.local_y - d.from_y) <= CLICK_SLOP then
			return
		end
		local first = not d.moved
		d.moved = true
		if d.kind == "pan" then
			pan(mx, my)
			return
		end
		local held = ui.modifiers
		local mods = {
			shift = held.shift:peek(),
			alt = held.alt:peek(),
			ctrl = held.control:peek(),
			cmd = held.control:peek() or held.meta:peek(),
		}
		local cx, cy = to_canvas(e.local_x, e.local_y)
		if d.kind == "press" then
			if not d.id and #sel() == 0 then
				d.kind = "noop"
				return
			end
			begin_move(d)
		end
		if d.kind == "move" then
			move_to(d, cx, cy, mods)
		elseif d.kind == "resize" then
			resize_to(d, cx, cy, mods)
		elseif d.kind == "rotate" then
			rotate_to(d, cx, cy, mods)
		elseif d.kind == "marquee" then
			marquee_to(d, cx, cy, mods)
		elseif d.kind == "draw" then
			local w, h = cx - d.px, cy - d.py
			if mods.shift then
				local m = math.max(math.abs(w), math.abs(h))
				w, h = (if w < 0 then -m else m), (if h < 0 then -m else m)
			end
			local x0, y0 = d.px, d.py
			if mods.alt then
				x0, y0, w, h = x0 - w, y0 - h, w * 2, h * 2
			end
			d.rect = { round(math.min(x0, x0 + w)), round(math.min(y0, y0 + h)), round(math.abs(w)), round(math.abs(h)) }
			d.line = { d.px, d.py, cx, cy }
			shown:set({ kind = "draw", rect = d.rect, line = if d.tool == "line" then d.line else nil })
		end
		if first then
			hover:set(nil)
		end
	end

	local function on_release(_e: any)
		local d = drag
		drag = nil
		if d then
			finish(d, false)
		end
	end

	-- Keys -------------------------------------------------------------------------------
	local nudge = { dx = 0, dy = 0, ids = {} :: { string }, gen = 0 }
	local function flush_nudge()
		if nudge.dx == 0 and nudge.dy == 0 then
			return
		end
		local ops = {}
		for _, id in nudge.ids do
			table.insert(ops, { op = "move", id = id, dx = nudge.dx, dy = nudge.dy })
		end
		nudge.dx, nudge.dy = 0, 0
		send(ops, "Move")
	end

	local function on_key(k: any): boolean?
		if k.editing then
			return nil
		end
		local key = k.key
		local s = sel()
		local i = ix:peek()
		if key == " " then
			if not space then
				space = true
				cursor:set("grab")
			end
			return true
		end
		if k.cmd and (key == "z" or key == "Z") then
			if k.shift then
				source.redo()
			else
				source.undo()
			end
			return true
		end
		if k.cmd and (key == "y" or key == "Y") then
			source.redo()
			return true
		end
		if k.cmd and key == "0" then
			local sz = size:peek()
			zoom_at(1, sz.w / 2, sz.h / 2)
			return true
		end
		if k.cmd and (key == "=" or key == "+") then
			zoom_step(1)
			return true
		end
		if k.cmd and key == "-" then
			zoom_step(-1)
			return true
		end
		if k.shift and (key == "!" or key == "1" or k.code == "Digit1") then
			fit()
			return true
		end
		if k.shift and (key == "@" or key == "2" or k.code == "Digit2") then
			local bs = {}
			for _, id in s do
				if i.by[id] then
					table.insert(bs, i.by[id].bounds)
				end
			end
			fit_rect(Model.union(bs), ZOOM_MAX)
			return true
		end
		if k.cmd and (key == "a" or key == "A") then
			local parent = if #s > 0 and i.by[s[1]] then i.by[s[1]].parent else ""
			select(table.clone(i.kids[parent] or {}))
			return true
		end
		-- Copy, cut, paste (the service's clipboard): a paste goes into the
		-- selected frame, or beside the selection, or where it was copied.
		if k.cmd and not k.shift and (key == "c" or key == "C" or key == "x" or key == "X") and #s > 0 and source.copy then
			local cut = key == "x" or key == "X"
			source.copy(Model.topmost(i, s), cut)
			if cut then
				select({})
			end
			return true
		end
		if k.cmd and not k.shift and (key == "v" or key == "V") then
			send({ { op = "paste", into = if #s == 1 then s[1] else nil } }, "Paste")
			return true
		end
		if k.cmd and (key == "d" or key == "D") and #s > 0 then
			send({ { op = "duplicate", ids = Model.topmost(i, s) } }, "Duplicate")
			return true
		end
		if (key == "Delete" or key == "Backspace") and #s > 0 then
			local ids = {}
			for _, id in Model.topmost(i, s) do
				if not Model.is_inside_instance(id) then
					table.insert(ids, id)
				end
			end
			if #ids > 0 then
				send({ { op = "delete", ids = ids } }, "Delete")
				select({})
			end
			return true
		end
		-- Ctrl+P: the command palette; ?: the keyboard shortcuts.
		if k.cmd and not k.shift and (key == "p" or key == "P") and props.on_palette then
			props.on_palette()
			return true
		end
		if key == "?" and props.on_shortcuts then
			props.on_shortcuts()
			return true
		end
		-- Ctrl+F: the shell's Find.
		if k.cmd and not k.shift and (key == "f" or key == "F") and props.on_find then
			props.on_find()
			return true
		end
		if #pen_pts:peek() > 0 and (key == "Escape" or key == "Enter") then
			finish_pen(false)
			return true
		end
		if not k.cmd and not k.alt then
			local tools = { v = "move", h = "hand", f = "frame", r = "rectangle", o = "ellipse", l = "line", t = "text", p = "pen" }
			local tk = tools[string.lower(key)]
			if tk and not (k.shift and (key == "H" or key == "V")) then
				tool:set(tk)
				return true
			end
		end
		if key == "Escape" and tool:peek() ~= "move" then
			tool:set("move")
			return true
		end
		-- (pen: Escape clears the selection; Shift+Enter is the parent.)
		if key == "Escape" then
			select({})
			return true
		end
		if key == "Enter" and #s > 0 then
			if k.shift then
				local n = i.by[s[1]]
				if n and n.parent ~= "" then
					select({ n.parent })
				end
			else
				local one = i.by[s[1]]
				if #s == 1 and one and one.it.t == "text" then
					start_editing(one.id)
				else
					local out = {}
					for _, id in s do
						for _, c in i.kids[id] or {} do
							table.insert(out, c)
						end
					end
					if #out > 0 then
						select(out)
					end
				end
			end
			return true
		end
		local arrows = { ArrowLeft = { -1, 0 }, ArrowRight = { 1, 0 }, ArrowUp = { 0, -1 }, ArrowDown = { 0, 1 } }
		local a = arrows[key]
		if a and #s > 0 then
			local step = if k.shift then 10 else 1
			local ids = Model.topmost(i, s)
			-- In auto layout, arrows along it change places.
			local lay = laid_out(ids[1])
			if #ids == 1 and lay then
				local n = i.by[ids[1]]
				local along = (lay == "horizontal" and a[1] ~= 0) or (lay == "vertical" and a[2] ~= 0)
				if along then
					local sibs = i.kids[n.parent] or {}
					local at = table.find(sibs, n.id) :: number
					local to = at - 1 + a[1] + a[2]
					if to >= 0 and to < #sibs then
						send({ { op = "reorder", id = n.id, index = to } }, "Reorder")
					end
				end
				return true
			end
			local movable = {}
			for _, id in ids do
				if not laid_out(id) then
					table.insert(movable, id)
				end
			end
			if #movable == 0 then
				return true
			end
			nudge.ids = movable
			nudge.dx += a[1] * step
			nudge.dy += a[2] * step
			live_for(movable, function(): (any?, any?)
				return Draw.translate(nudge.dx, nudge.dy), nil
			end)
			nudge.gen += 1
			local mine = nudge.gen
			ui.after(250, function()
				if nudge.gen == mine then
					flush_nudge()
				end
			end)
			return true
		end
		return nil
	end

	local function on_key_up(key: any)
		local name = if type(key) == "table" then key.key else key
		if name == " " then
			space = false
			if not drag then
				cursor:set("default")
			end
		end
	end

	-- Agents' flashes: each changed node outlined, fading out.
	local flashes = source.flashes
	local clock = ui.use_state(0)
	if flashes then
		ui.effect(function()
			local list = flashes:get()
			if #list > 0 then
				ui.after(FLASH_MS + 50, function()
					local now = ui.now()
					local keep = {}
					for _, f in flashes:peek() do
						if now - f.at < FLASH_MS then
							table.insert(keep, f)
						end
					end
					flashes:set(keep)
				end)
			end
		end)
	end

	-- The overlay: what keeps its size as the view zooms ----------------------------
	local draw_overlay_inner: (c: Canvas, w: number, h: number) -> ()
	local function draw_overlay(c: Canvas, w: number, h: number)
		local t0 = os.clock()
		draw_overlay_inner(c, w, h)
		note(perf.overlay, (os.clock() - t0) * 1000)
	end
	function draw_overlay_inner(c: Canvas, _w: number, _h: number)
		local v = view:get()
		if not v then
			return
		end
		local L = look()
		local i = ix:get()
		local s = selection:get() or {}
		local h = hover:get()
		local sh = shown:get()
		local ed = editing:get()
		local measuring = alt_held:get()
		local function sx(x: number): number
			return v.x + x * v.zoom
		end
		local function sy(y: number): number
			return v.y + y * v.zoom
		end
		local function color_of(k: string): string
			return if k == "component" then L.component elseif k == "instance" then L.instance else L.accent
		end
		local function outline(m: any, w: number, hh: number, color: string, width: number, fill: string?)
			if Draw.upright(m) or (math.abs(m.b) < 1e-9 and math.abs(m.c) < 1e-9) then
				local x0, y0 = Draw.apply(m, 0, 0)
				local x1, y1 = Draw.apply(m, w, hh)
				local ax, ay = math.floor(sx(math.min(x0, x1))) + 0.5, math.floor(sy(math.min(y0, y1))) + 0.5
				local bx, by = math.floor(sx(math.max(x0, x1))) + 0.5, math.floor(sy(math.max(y0, y1))) + 0.5
				if fill then
					c:rect(ax, ay, math.max(0, bx - ax), math.max(0, by - ay), fill)
				end
				c:stroke(ui.path():rect(ax, ay, math.max(0, bx - ax), math.max(0, by - ay)), color, width)
				return
			end
			local p = ui.path()
			for k, q in { { 0, 0 }, { w, 0 }, { w, hh }, { 0, hh } } do
				local x, y = Draw.apply(m, q[1], q[2])
				if k == 1 then
					p = p:move(sx(x), sy(y))
				else
					p = p:line(sx(x), sy(y))
				end
			end
			p = p:close()
			if fill then
				c:fill(p, fill)
			end
			c:stroke(p, color, width)
		end
		-- The board's pills: 12px semibold, 18 high, r5; an agent's (`big`) are
		-- 20 high, r6, with a 12px glyph before the text (`glyph` draws it).
		local function pill(x: number, y: number, text: string, bg: string, fg: string, anchor: string, big: boolean, glyph: ((gx: number, gy: number, color: string) -> ())?)
			local opts = { size = 12, weight = 600, font = Look.UI }
			local tw = c:measure_text(text, opts)
			local lead = if glyph then 17 else 0
			local w, hh = tw + lead + (if big then 14 else 12), if big then 20 else 18
			local left = round(if anchor == "middle" then x - w / 2 elseif anchor == "end" then x - w else x)
			local top = round(y)
			c:rect(left, top, w, hh, bg, if big then 6 else 5)
			if glyph then
				glyph(left + 7, top + (hh - 12) / 2, fg)
			end
			local tx = left + lead + (if big then 7 else 6)
			c:text(text, tx + tw / 2, top + hh / 2, { size = 12, weight = 600, font = Look.UI, color = fg, align = "center", baseline = "middle", tabular = true })
		end
		-- 12px glyphs, drawn with lines: a frame (#), a spark (an agent's edit)
		-- and a loader's dots (an agent at work).
		local function glyph_frame(gx: number, gy: number, color: string)
			c:line(gx + 1, gy + 3.5, gx + 11, gy + 3.5, color, 1)
			c:line(gx + 1, gy + 8.5, gx + 11, gy + 8.5, color, 1)
			c:line(gx + 3.5, gy + 1, gx + 3.5, gy + 11, color, 1)
			c:line(gx + 8.5, gy + 1, gx + 8.5, gy + 11, color, 1)
		end
		local function glyph_spark(gx: number, gy: number, color: string)
			c:fill(ui.path():move(gx + 6, gy + 0.5):line(gx + 7.4, gy + 4.6):line(gx + 11.5, gy + 6):line(gx + 7.4, gy + 7.4):line(gx + 6, gy + 11.5):line(gx + 4.6, gy + 7.4):line(gx + 0.5, gy + 6):line(gx + 4.6, gy + 4.6):close(), color)
		end
		local function glyph_busy(gx: number, gy: number, color: string)
			c:stroke(ui.path():ellipse(gx + 1.5, gy + 1.5, 9, 9), Draw.fade(color .. "ff", 0.35), 1.5)
			c:stroke(ui.path():move(gx + 6, gy + 1.5):cubic(gx + 8.5, gy + 1.5, gx + 10.5, gy + 3.5, gx + 10.5, gy + 6), color, 1.5)
		end

		-- Screens' names above them.
		for _, id in i.kids[""] or {} do
			local n = i.by[id]
			if n and n.it.t == "frame" then
				local b = n.bounds
				local live = sh and sh.boxes and sh.boxes[id]
				if live then
					b = live.bounds
				end
				local w = b[3] * v.zoom
				if w >= 24 and sx(b[1]) < _w and sy(b[2]) > 0 and sx(b[1]) + w > 0 then
					-- (icon, text): the accent when selected, magenta for a Component,
					-- the agent's orange while one builds it, brighter on hover.
					local icon, color = L.name, L.name
					if has(s, id) then
						icon, color = L.accent, L.accent_fg
					elseif n.it.comp then
						icon, color = L.component, L.component
					elseif n.it.wip then
						icon, color = L.agent, L.agent_text
					elseif h == id then
						icon, color = L.name_hover, L.name_hover
					end
					local name = n.it.name or ""
					local max = math.max(1, math.floor((w - 22) / 6.6))
					if (utf8.len(name) or #name) > max then
						-- Cut on a character boundary: a byte cut can split a multi-byte
						-- character, and zgx rejects text that isn't valid UTF-8.
						local cut = utf8.offset(name, math.max(1, max - 1) + 1) or (#name + 1)
						name = string.sub(name, 1, cut - 1) .. "…"
					end
					local nx, ny = round(sx(b[1])), round(sy(b[2]))
					glyph_frame(nx, ny - 19, icon)
					c:text(name, nx + 18, ny - 6, { size = 12, weight = 500, font = Look.UI, color = color, baseline = "bottom" })
				end
			end
		end
		-- Agents at work: agent orange, and the pill names who is building
		-- (`inProgressBy`, the chat that set inProgress) when it's known.
		for _, id in i.order do
			local n = i.by[id]
			if n.it.wip then
				outline(n.m, n.it.box.w, n.it.box.h, L.agent, 1.5, L.agent_soft)
				local b = n.bounds
				local who = if n.it.by and source.chat_title then source.chat_title(n.it.by) else nil
				pill(sx(b[1] + b[3]), sy(b[2]) - 26, if who then `{who} · In progress` else "In progress", L.agent, L.on_accent, "end", true, glyph_busy)
			end
		end
		-- Flashes.
		if flashes then
			local _ = clock:get()
			local now = ui.now()
			for _, f in flashes:get() do
				local n = i.by[f.id]
				local age = now - f.at
				if n and age < FLASH_MS then
					local o = (1 - age / FLASH_MS) ^ 1.6
					outline(n.m, n.it.box.w, n.it.box.h, Draw.fade(L.accent .. "ff", o), 2)
					if f.label then
						local b = n.bounds
						-- (At its top right: a Screen's name is at its top left.)
						pill(sx(b[1] + b[3]), sy(b[2]) - 26, f.label, Draw.fade(L.flash_bg .. "ff", o), Draw.fade(L.flash_fg .. "ff", o), "end", true, glyph_spark)
					end
				end
			end
		end
		-- Hover.
		if h and not has(s, h) and i.by[h] and (not sh or sh.kind == "marquee") then
			local n = i.by[h]
			outline(n.m, n.it.box.w, n.it.box.h, color_of(kind(n)), 1.5)
		end
		-- A move's drop target and auto-layout place.
		if sh and sh.target and sh.target ~= "" and i.by[sh.target] then
			local n = i.by[sh.target]
			outline(n.m, n.it.box.w, n.it.box.h, L.accent, 2)
		end
		if sh and sh.insertion then
			local q = sh.insertion
			c:line(sx(q[1]), sy(q[2]), sx(q[3]), sy(q[4]), L.accent, 3, { cap = "round" })
		end
		-- Selection.
		local boxes = if sh then sh.boxes else nil
		local f = if #s > 0 then frame_of(s, boxes) else nil
		local quiet = sh and (sh.kind == "move" or sh.kind == "rotate")
		for _, id in s do
			local n = i.by[id]
			if n and not (ed and ed.id == id) then
				local live = boxes and boxes[id]
				outline(if live then live.m else n.m, if live then live.w else n.it.box.w, if live then live.h else n.it.box.h, color_of(kind(n)), 1)
			end
		end
		if f and not ed then
			local k = if f.one then kind(f.n) else ""
			local col = color_of(k)
			if not f.one then
				outline(f.m, f.w, f.h, col, 1)
			end
			if not quiet then
				for _, q in { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } } do
					local x, y = Draw.apply(f.m, q[1] * f.w, q[2] * f.h)
					local hx, hy = math.floor(sx(x)) + 0.5, math.floor(sy(y)) + 0.5
					c:rect(hx - 4, hy - 4, 8, 8, L.handle, 1)
					c:stroke(ui.path():rect(hx - 4, hy - 4, 8, 8, 1), col, 1.5)
				end
			end
			local bx, by, bw, bh = Draw.canvas_bounds({ box = { w = f.w, h = f.h } }, f.m)
			local label = if sh and sh.kind == "rotate" and sh.angle then `{sh.angle}°` else `{fmt(f.w)} × {fmt(f.h)}`
			pill(sx(bx + bw / 2), sy(by + bh) + 8, label, col, L.on_accent, "middle", false)
		end
		-- Guides, and Alt's measurements.
		local g = if sh then sh.guides else nil
		if not g and measuring and #s > 0 and not sh then
			local bs = {}
			for _, id in s do
				if i.by[id] then
					table.insert(bs, i.by[id].bounds)
				end
			end
			local a = Model.union(bs)
			local other = if h and not has(s, h) then i.by[h] else nil
			if not other and i.by[s[1]] then
				other = i.by[i.by[s[1]].parent]
			end
			if a and other then
				g = Model.distances(a, other.bounds)
			end
		end
		if g then
			for _, l in g.lines or {} do
				c:line(math.floor(sx(l[1])) + 0.5, math.floor(sy(l[2])) + 0.5, math.floor(sx(l[3])) + 0.5, math.floor(sy(l[4])) + 0.5, L.guide, 1)
			end
			for _, q in g.gaps or {} do
				c:line(sx(q[1]), sy(q[2]), sx(q[3]), sy(q[4]), L.guide, 1)
				local d = math.abs(q[3] - q[1]) + math.abs(q[4] - q[2])
				if d >= 0.5 then
					local mx, my = (sx(q[1]) + sx(q[3])) / 2, (sy(q[2]) + sy(q[4])) / 2
					if q[1] == q[3] then
						pill(mx + 4, my - 9, fmt(d), L.guide, "#ffffff", "start", false)
					else
						pill(mx, my + 4, fmt(d), L.guide, "#ffffff", "middle", false)
					end
				end
			end
			for _, o in g.outlines or {} do
				c:stroke(ui.path():rect(sx(o[1]), sy(o[2]), o[3] * v.zoom, o[4] * v.zoom), L.guide, 1)
			end
		end
		-- What a tool draws, and the pen's points.
		if sh and sh.kind == "draw" and sh.rect then
			local r = sh.rect
			if sh.line then
				local q = sh.line
				c:line(sx(q[1]), sy(q[2]), sx(q[3]), sy(q[4]), L.accent, 1.5)
			else
				c:stroke(ui.path():rect(math.floor(sx(r[1])) + 0.5, math.floor(sy(r[2])) + 0.5, round(r[3] * v.zoom), round(r[4] * v.zoom)), L.accent, 1)
				-- The draft's W × H under it.
				if r[3] > 0 or r[4] > 0 then
					pill(sx(r[1] + r[3] / 2), sy(r[2] + r[4]) + 8, `{fmt(r[3])} × {fmt(r[4])}`, L.accent, L.on_accent, "middle", false)
				end
			end
		end
		local pts = pen_pts:get()
		if #pts > 0 then
			for k = 2, #pts do
				c:line(sx(pts[k - 1][1]), sy(pts[k - 1][2]), sx(pts[k][1]), sy(pts[k][2]), L.accent, 1.5)
			end
			for _, q in pts do
				c:rect(sx(q[1]) - 4, sy(q[2]) - 4, 8, 8, L.handle, 4)
				c:stroke(ui.path():ellipse(sx(q[1]) - 4, sy(q[2]) - 4, 8, 8), L.accent, 1.5)
			end
		end
		-- The marquee.
		if sh and sh.kind == "marquee" and sh.rect then
			local r = sh.rect
			local x, y = math.floor(sx(r[1])) + 0.5, math.floor(sy(r[2])) + 0.5
			c:rect(x, y, r[3] * v.zoom, r[4] * v.zoom, L.marquee)
			c:stroke(ui.path():rect(x, y, round(r[3] * v.zoom), round(r[4] * v.zoom)), L.accent, 1)
		end
		-- Text being edited: its box, what's selected of it, the caret.
		if ed then
			local n = i.by[ed.id]
			if n then
				outline(n.m, n.it.box.w, n.it.box.h, L.accent, 1)
				local t = n.it.text
				local opts = { font = t.font, size = t.size, weight = t.weight, italic = t.italic, letter_spacing = if t.ls ~= 0 then t.ls else nil }
				local lh = t.lh or (t.size or 14) * 1.2
				-- (Explicit lines only: a wrapped paragraph's breaks aren't known here.)
				-- Its lines as drawn: explicit breaks, and a wrapped paragraph's
				-- greedy word breaks at its width (as the shaper breaks them,
				-- near enough for a caret). Each: first byte (0-based), text.
				local lines: { { from: number, s: string } } = {}
				local content = ed.content
				local pos = 0
				for para in string.gmatch(content .. "\n", "([^\n]*)\n") do
					if t.wrap and t.wrap > 0 then
						local cur, cur_from = "", pos
						local i = 1
						while i <= #para do
							local ws, we = string.find(para, "^%s*%S*", i)
							local word = string.sub(para, ws :: number, we :: number)
							if cur ~= "" and c:measure_text(cur .. word, opts) > t.wrap + 0.5 then
								table.insert(lines, { from = cur_from, s = cur })
								local lead = string.match(word, "^%s*") or ""
								cur_from = pos + (ws :: number) - 1 + #lead
								cur = string.sub(word, #lead + 1)
							else
								cur ..= word
							end
							i = (we :: number) + 1
							if we == nil or (we :: number) < (ws :: number) then
								break
							end
						end
						table.insert(lines, { from = cur_from, s = cur })
					else
						table.insert(lines, { from = pos, s = para })
					end
					pos += #para + 1
				end
				local function line_x(l: { from: number, s: string }): number
					if t.align == "center" then
						return (n.it.box.w - c:measure_text(l.s, opts)) / 2
					elseif t.align == "right" then
						return n.it.box.w - c:measure_text(l.s, opts)
					end
					return 0
				end
				local function caret_at(byte: number): (number, number, number)
					local k = 1
					for j, l in lines do
						if l.from <= byte then
							k = j
						end
					end
					local l = lines[k]
					local into = math.clamp(byte - l.from, 0, #l.s)
					return line_x(l) + c:measure_text(string.sub(l.s, 1, into), opts), (k - 1) * lh, lh
				end
				local a, b = math.min(ed.anchor, ed.focus), math.max(ed.anchor, ed.focus)
				if a ~= b then
					for k, l in lines do
						local l_end = l.from + #l.s
						if l_end >= a and l.from <= b then
							local x1 = caret_at(math.max(a, l.from))
							local x2 = line_x(l) + c:measure_text(string.sub(l.s, 1, math.min(b, l_end) - l.from), opts)
							local p0x, p0y = Draw.apply(n.m, x1, (k - 1) * lh)
							c:rect(sx(p0x), sy(p0y), math.max(1, x2 - x1) * v.zoom, lh * v.zoom, Draw.fade(L.accent .. "ff", 0.25))
						end
					end
				end
				local cxl, cyl, ch = caret_at(ed.focus)
				local px, py = Draw.apply(n.m, cxl, cyl)
				c:rect(sx(px) - 0.75, sy(py), 1.5, ch * v.zoom, L.accent)
			end
		end
	end

	-- For tests and the harness: pictures of what the Canvas shows now, drawn
	-- as it draws them (the Design at the view, and the marks over it).
	if props.expose then
		props.expose({
			view = view,
			hover = hover,
			tool = tool,
			index = ix,
			select = select,
			render_png = render_png,
			render_layer = render_layer,
			eyedrop = function(done: (hex: string) -> ())
				eyedrop_done = done
				tool:set("eyedrop")
			end,
			zoom_step = zoom_step,
			zoom_to_selection = function()
				local i = ix:peek()
				local bs = {}
				for _, id in sel() do
					if i.by[id] then
						table.insert(bs, i.by[id].bounds)
					end
				end
				fit_rect(Model.union(bs), ZOOM_MAX)
			end,
			-- Fit the Screen (top-level layer) holding `id`, at most 100%: how
			-- pen's Find shows a result.
			zoom_to_root = function(id: string)
				local i = ix:peek()
				local n = i.by[id]
				while n and n.parent and n.parent ~= "" and i.by[n.parent] do
					n = i.by[n.parent]
				end
				if n then
					fit_rect(n.bounds, 1)
				end
			end,
			-- The Canvas's keys, for keys pressed elsewhere in the editor (a
			-- panel's button holding focus), as pen's work wherever focus is.
			key = function(k: any): boolean?
				return on_key(k)
			end,
			-- Keys back to the Canvas (after Find or the palette closes).
			focus = function()
				if canvas_el then
					canvas_el:focus()
				end
			end,
			start_editing = start_editing,
			fit = fit,
			perf = perf,
			zoom_at = zoom_at,
			shot = function(done: (content: string?, marks: string?, err: string?) -> ())
				local v = view:peek()
				local s = size:peek()
				if not v or s.w <= 0 then
					done(nil, nil, "no view yet")
					return
				end
				local list = roots:peek()
				local board = look().board
				local content = ui.render_canvas(function(c: Canvas)
					for ri, root in list do
						Draw.draw_root(c, root, roots:live_at(ri) or false)
					end
				end, { width = s.w / v.zoom, height = s.h / v.zoom, scale = v.zoom, x = -v.x / v.zoom, y = -v.y / v.zoom, background = board })
				local marks = ui.render_canvas(function(c: Canvas, w: number, h: number)
					draw_overlay(c, w, h)
				end, { width = s.w, height = s.h, scale = 1 })
				content:after(function(a: string)
					marks:after(function(b: string)
						done(a, b, nil)
					end, function(err: any)
						done(a, nil, tostring(err))
					end)
				end, function(err: any)
					done(nil, nil, tostring(err))
				end)
			end,
		})
	end

	-- The tree ----------------------------------------------------------------------------
	return ui.overlay {
		id = `design-canvas-{tab_id}`,
		role = "group",
		label = "Design canvas",
		w_full = true,
		h_full = true,
		grow = 1,
		min_h = 0,
		overflow = "hidden",
		bg = function(): string
			return look().board
		end,
		ref = surface,
		focusable = true,
		focus_on_press = false,
		focus = { outline = 0 },
		cursor = function(): any
			return cursor:get()
		end,
		on_resize = function(s: { w: number, h: number })
			local now = size:peek()
			if now.w ~= s.w or now.h ~= s.h then
				size:set({ w = s.w, h = s.h })
			end
			local function step(v: number): number
				return math.max(BOARD_STEP, math.ceil(v / BOARD_STEP) * BOARD_STEP)
			end
			local b = board_size:peek()
			local w, h = step(s.w), step(s.h)
			if b.w == 0 then
				board_size:set({ w = w, h = h })
				return
			end
			if w > b.w or h > b.h then
				board_size:set({ w = math.max(w, b.w), h = math.max(h, b.h) })
			end
			resize_n += 1
			local mine = resize_n
			ui.after(BOARD_SETTLE_MS, function()
				if mine ~= resize_n then
					return
				end
				local now2 = size:peek()
				local tight = { w = step(now2.w), h = step(now2.h) }
				local b2 = board_size:peek()
				if tight.w ~= b2.w or tight.h ~= b2.h then
					board_size:set(tight)
				end
			end)
		end,
		on_wheel = function(e: any): boolean
			if e.ctrl or e.meta then
				local f = math.clamp(math.exp(-e.dy * 0.01), 0.5, 2)
				local v = view:peek()
				if v then
					zoom_at(v.zoom * f, e.local_x, e.local_y)
				end
			else
				pan(-e.dx, -e.dy)
			end
			return true
		end,
		on_pinch = function(e: any): boolean
			local v = view:peek()
			if v then
				zoom_at(v.zoom * (1 + e.scale), e.local_x, e.local_y)
			end
			return true
		end,
		on_press = on_press,
		on_pointer_move = on_move,
		on_release = on_release,
		on_aux_click = function(_e: any) end,
		-- Right click: what's under the pointer selected first (unless it's
		-- in the selection), then the shell's menu for the selection.
		context_menu_style = props.menu_style,
		context_menu = if props.context_menu then function(e: any): { Node }?
			local cx, cy = to_canvas(e.local_x, e.local_y)
			local s = sel()
			local inside = false
			local f = frame_of(s)
			if f then
				local fx, fy = Draw.apply(Draw.invert(f.m), cx, cy)
				inside = fx >= 0 and fy >= 0 and fx <= f.w and fy <= f.h
			end
			if not inside then
				local id = Model.hit(ix:peek(), cx, cy, s, false, nil)
				select(if id then { id } else {})
			end
			return (props.context_menu :: any)(sel(), cx, cy)
		end else nil,
		on_hover = function(on: boolean)
			if not on and not drag then
				hover:set(nil)
			end
		end,
		on_key = function(k: any): boolean?
			if k.key == "Alt" then
				return nil
			end
			return on_key(k)
		end,
		on_key_up = on_key_up,
		on_blur = function()
			space = false
		end,
		on_mount = function(el: any)
			el:focus()
			canvas_el = el
			-- Alt held: measurements (a modifier alone reaches no on_key).
			ui.effect(function()
				alt_held:set(ui.modifiers.alt:get())
			end)
		end,
		-- The Design.
		ui.canvas {
			id = `design-board-{tab_id}`,
			label = "Design",
			w = function(): number
				return board_size:get().w
			end,
			h = function(): number
				return board_size:get().h
			end,
			absolute = true,
			left = 0,
			top = 0,
			view = view,
			each = roots.items,
			draw_item = function(c: Canvas, item: any)
				local root = roots:full(item)
				if not root then
					return
				end
				local t0 = os.clock()
				Draw.draw_root(c, root, item.live or false)
				note(perf.items, (os.clock() - t0) * 1000)
			end,
		},
		-- What a move drags, over the board.
		ui.canvas {
			id = `design-lifted-{tab_id}`,
			w_full = true,
			h_full = true,
			absolute = true,
			left = 0,
			top = 0,
			pointer_events = "none",
			view = function(): any
				local v = view:get()
				local o = lift_offset:get()
				if not v then
					return { x = 0, y = 0, zoom = 1 }
				end
				return { x = v.x + o.dx * v.zoom, y = v.y + o.dy * v.zoom, zoom = v.zoom }
			end,
			each = lifted,
			draw_item = function(c: Canvas, item: any)
				local t0 = os.clock()
				Draw.draw_root(c, item)
				note(perf.items, (os.clock() - t0) * 1000)
			end,
		},
		-- Selection, hover, handles, guides: crisp at any zoom (screen points:
		-- few marks, drawn again as the view moves).
		-- zgx-lint: allow(canvas-view)
		ui.canvas {
			id = `design-marks-{tab_id}`,
			w_full = true,
			h_full = true,
			absolute = true,
			left = 0,
			top = 0,
			pointer_events = "none",
			draw = draw_overlay,
		},
		-- The words of a text being edited, held by a real field out of sight
		-- over it (an input method puts its window there).
		ui.show(function(): boolean
			return editing:get() ~= nil
		end, ui.component(function(): Node
			local function box(): { number }
				local e = editing:get()
				local v = view:get()
				local n = if e then ix:get().by[e.id] else nil
				if not n or not v then
					return { 0, 0, 1, 1 }
				end
				local b = n.bounds
				return { v.x + b[1] * v.zoom, v.y + b[2] * v.zoom, math.max(1, b[3] * v.zoom), math.max(1, b[4] * v.zoom) }
			end
			return ui.textarea {
				id = `design-text-field-{tab_id}`,
				label = "Edit text",
				ref = field,
				absolute = true,
				left = function(): number
					return box()[1]
				end,
				top = function(): number
					return box()[2]
				end,
				w = function(): number
					return box()[3]
				end,
				h = function(): number
					return box()[4]
				end,
				value = function(): string
					local e = editing:get()
					return if e then e.content else ""
				end,
				on_change = function(content: string)
					local e = editing:peek()
					if not e or content == e.content then
						return
					end
					local el = field:peek()
					local a, f = #content, #content
					if el then
						local sa, sf = el:selection_bytes()
						if sa and sf then
							a, f = sa, sf
						end
					end
					editing:set({ id = e.id, content = content, anchor = a, focus = f })
					text_live(e.id, content)
					queue_text(e.id, content, typed_once)
					typed_once = true
				end,
				on_caret = function(_line: number, _col: number, anchor: number, focus: number)
					local e = editing:peek()
					if e and (e.anchor ~= anchor or e.focus ~= focus) then
						editing:set({ id = e.id, content = e.content, anchor = anchor, focus = focus })
					end
				end,
				on_key = function(k: any): boolean?
					if k.key == "Escape" or (k.key == "Enter" and not k.shift) then
						finish_editing()
						return true
					end
					if k.cmd and (k.key == "z" or k.key == "Z" or k.key == "y" or k.key == "Y") then
						finish_editing()
						if k.shift or k.key == "y" or k.key == "Y" then
							source.redo()
						else
							source.undo()
						end
						return true
					end
					return nil
				end,
				on_focus = function()
					field_focused = true
				end,
				on_blur = function()
					field_focused = false
					ui.after(0, function()
						if editing:peek() and not field_focused then
							editing:set(nil)
						end
					end)
				end,
				on_mount = function(el: any)
					el:focus()
					el:select_all()
				end,
				wrap = false,
				pointer_events = "none",
				color = "#00000000",
				caret_color = "#00000000",
				selection_color = "#00000000",
				bg = "#00000000",
				border = 0,
				focus = { outline = 0 },
				px = 0,
				py = 0,
			}
		end)({})),
		-- The zoom, bottom right, as pen.dev's (the shell has its own pill).
		if props.chrome == false then ui.div {} else ui.row {
			id = `design-zoom-{tab_id}`,
			absolute = true,
			right = 12,
			bottom = 12,
			gap = 2,
			items = "center",
			px = 4,
			py = 2,
			rounded = 8,
			bg = "$surface.raised",
			border = 1,
			border_color = "$border",
			ui.button {
				"−",
				id = `design-zoom-out-{tab_id}`,
				variant = "ghost",
				on_click = function()
					zoom_step(-1)
				end,
			},
			ui.button {
				id = `design-zoom-fit-{tab_id}`,
				variant = "ghost",
				label = "Zoom to fit",
				on_click = fit,
				ui.text {
					function(): string
						local v = view:get()
						return if v then `{round(v.zoom * 100)}%` else ""
					end,
					text_size = 12,
					tabular = true,
				},
			},
			ui.button {
				"+",
				id = `design-zoom-in-{tab_id}`,
				variant = "ghost",
				on_click = function()
					zoom_step(1)
				end,
			},
		},
	}
end
