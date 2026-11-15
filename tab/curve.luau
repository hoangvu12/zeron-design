--!strict
local ui = require("./pointer").ui
-- The Prototype panel's curve editors (prototyping step 2), the panel's full
-- width. A custom bézier: its curve and two handles to drag (x within 0–1, y
-- free, as CSS). A custom spring: drag the graph itself, as Framer's and
-- SwiftUI's time and bounce, sideways for its time (the curve stretches on a
-- fixed time axis) and up and down for its bounce; the peak's dot follows the
-- pointer. The exact numbers, labelled, sit under "Advanced". Either drag
-- previews live and commits once, on release (one undo step); the spring's
-- settle time also goes to `live_ms` as it changes (the panel's duration).

local Kit = require("./kit")
local Look = require("./look")
local Proto = require("./proto")

local M = {}

local H = 148 -- (the graph's height; its width is the panel's)
local PAD_X, PAD_TOP, PAD_BOTTOM = 12, 28, 22
local BOUNCE_PX = 120 -- (points of vertical drag per whole bounce)
local DEFAULT = { mass = 1, stiffness = 100, damping = 15 }

-- A plot's mapping: x (0–1 of `w`) and y (lo–hi, up) to points.
type Plot = { w: number, lo: number, hi: number }
local function to_px(pl: Plot, x: number, y: number): (number, number)
	local pw, ph = pl.w - 2 * PAD_X, H - PAD_TOP - PAD_BOTTOM
	return PAD_X + x * pw, PAD_TOP + (pl.hi - y) / (pl.hi - pl.lo) * ph
end
local function from_px(pl: Plot, px: number, py: number): (number, number)
	local pw, ph = pl.w - 2 * PAD_X, H - PAD_TOP - PAD_BOTTOM
	return (px - PAD_X) / pw, pl.hi - (py - PAD_TOP) / ph * (pl.hi - pl.lo)
end

-- The graph's ground: its fill, the start and end levels, the linear diagonal.
local function frame(c: Canvas, L: any, pl: Plot, diagonal: boolean)
	c:rect(0, 0, pl.w, H, L.field, 8)
	local x0, y0 = to_px(pl, 0, 0)
	local x1, y1 = to_px(pl, 1, 1)
	c:line(x0, y0, x1, y0, L.border, 1)
	c:line(x0, y1, x1, y1, L.border, 1)
	if diagonal then
		c:line(x0, y0, x1, y1, L.border, 1)
	end
end

local function round(v: number, unit: number?): number
	local u = unit or 0.01
	return math.floor(v / u + 0.5) * u
end

-- A line of text at x (its start, end or centre), measured to place it.
local function text(c: Canvas, s: string, x: number, y: number, color: any, align: string, size: number?)
	local o: any = { font = Look.UI, size = size or 11, color = color, tabular = true }
	local tw = if align == "start" then 0 else c:measure_text(s, o)
	c:text(s, if align == "end" then x - tw elseif align == "center" then x - tw / 2 else x, y, o)
end

-- "Advanced": a disclosure row and, open, labelled rows. Open or shut is one
-- choice for every curve editor, kept as the panel rebuilds after an edit.
local advanced_open: any = nil
local function advanced(L: any, id: string, rows: { Node }): { Node }
	advanced_open = advanced_open or ui.state("design-pure.proto.curve-advanced", false) -- zgx-lint: allow(state-in-component)
	local open = advanced_open
	local body: any = { id = `{id}-advanced-body`, w_full = true, gap = 6 }
	for _, r in rows do
		table.insert(body, r)
	end
	return {
		ui.button {
			id = `{id}-advanced`,
			label = "Advanced",
			w_full = true,
			h = 20,
			p = 0,
			gap = 4,
			border = 0,
			bg = "#00000000",
			items = "center",
			color = L.muted,
			hover = { color = L.fg },
			focus = { outline = 0 },
			on_click = ui.toggle(open),
			ui.show(function(): boolean
				return open:get()
			end, ui.div { shrink = 0, Kit.icon("chevDown", 12) }),
			ui.show(function(): boolean
				return not open:get()
			end, ui.div { shrink = 0, Kit.icon("chev", 12) }),
			ui.text { "Advanced", text_size = 11, font = Look.UI, color = L.muted },
			ui.div { grow = 1 },
		},
		ui.show(function(): boolean
			return open:get()
		end, ui.column(body)),
	}
end

-- A field with its name in front (Mass, Stiffness…), as the panel's rows.
local function labelled(L: any, name: string, field: Node): Node
	return ui.row {
		w_full = true,
		h = 28,
		gap = 8,
		items = "center",
		ui.div { w = 64, shrink = 0, Kit.text(L, name, { color = L.muted }) },
		ui.div { grow = 1, min_w = 0, field },
	}
end

export type BezierProps = { L: any, id: string, value: { number }, commit: (b: { number }) -> () }

-- A custom bézier: its curve, the two handles to drag, its numbers (Advanced).
function M.Bezier(p: BezierProps): Node
	local L = p.L
	local live = ui.use_state(table.clone(p.value))
	local hot = ui.use_state(0) -- (the handle under the pointer or held)
	local drag: any = nil -- 1 or 2: the handle held
	local pl: Plot = { w = 248, lo = -0.35, hi = 1.35 }
	local function at(e: any): (number, number)
		local x, y = from_px(pl, e.local_x, e.local_y)
		return round(math.clamp(x, 0, 1)), round(math.clamp(y, -1, 2))
	end
	local function nearest(e: any, reach: number): number?
		local b = live:peek()
		local best, d = nil, reach * reach
		for k = 1, 2 do
			local hx, hy = to_px(pl, b[k * 2 - 1], b[k * 2])
			local dd = (hx - e.local_x) ^ 2 + (hy - e.local_y) ^ 2
			if dd < d then
				best, d = k, dd
			end
		end
		return best
	end
	local function field(k: number, name: string): Node
		return Kit.num(L, {
			id = `{p.id}-{k}`,
			label = name,
			tip = name,
			step = 0.01,
			min = if k % 2 == 1 then 0 else -1,
			max = if k % 2 == 1 then 1 else 2,
			get = function(): number?
				return live:get()[k]
			end,
			set = function(v: number)
				local b = table.clone(live:peek())
				b[k] = round(if k % 2 == 1 then math.clamp(v, 0, 1) else math.clamp(v, -1, 2))
				live:set(b)
				p.commit(b)
			end,
		})
	end
	local kids: any = {
		id = p.id,
		w_full = true,
		gap = 6,
		ui.div {
			id = `{p.id}-graph`,
			label = "Curve: drag a handle",
			w_full = true,
			h = H,
			cursor = "grab",
			on_resize = function(s: any)
				pl.w = math.max(2 * PAD_X + 10, s.w)
			end,
			on_press = function(e: any)
				drag = nearest(e, 28)
				hot:set(drag or 0)
			end,
			on_pointer_move = function(e: any)
				if drag then
					local x, y = at(e)
					local b = table.clone(live:peek())
					if b[drag * 2 - 1] ~= x or b[drag * 2] ~= y then
						b[drag * 2 - 1], b[drag * 2] = x, y
						live:set(b)
					end
				else
					local h = nearest(e, 14) or 0
					if h ~= hot:peek() then
						hot:set(h)
					end
				end
			end,
			on_release = function()
				if drag then
					drag = nil
					local b = live:peek()
					local v = p.value
					if b[1] ~= v[1] or b[2] ~= v[2] or b[3] ~= v[3] or b[4] ~= v[4] then
						p.commit(table.clone(b))
					end
				end
			end,
			on_hover = function(inside: boolean)
				if not inside and not drag and hot:peek() ~= 0 then
					hot:set(0)
				end
			end,
			ui.canvas {
				w_full = true,
				h = H,
				pointer_events = "none",
				draw = function(c: Canvas, cw: number)
					local b = live:get()
					local h = hot:get()
					local g: Plot = { w = cw, lo = pl.lo, hi = pl.hi }
					frame(c, L, g, true)
					local x0, y0 = to_px(g, 0, 0)
					local x1, y1 = to_px(g, 1, 1)
					local ax, ay = to_px(g, b[1], b[2])
					local bx, by = to_px(g, b[3], b[4])
					c:line(x0, y0, ax, ay, L.faint, 1)
					c:line(x1, y1, bx, by, L.faint, 1)
					c:stroke(ui.path():move(x0, y0):cubic(ax, ay, bx, by, x1, y1), L.accent, 2)
					for k, hp in { { ax, ay }, { bx, by } } do
						local r = if h == k then 6.5 else 5
						c:circle(hp[1], hp[2], r, if h == k then L.accent else L.panel_solid)
						c:stroke(ui.path():ellipse(hp[1] - r, hp[2] - r, 2 * r, 2 * r), L.accent, 2)
					end
					local function f(v: number): string
						return string.format("%g", round(v))
					end
					text(c, `{f(b[1])}, {f(b[2])}, {f(b[3])}, {f(b[4])}`, PAD_X, 9, L.muted, "start")
					text(c, "Drag a handle", cw / 2, H - 17, L.faint, "center", 10.5)
				end,
			},
		},
	}
	for _, n in advanced(L, p.id, { Kit.pair(field(1, "X1"), field(2, "Y1")), Kit.pair(field(3, "X2"), field(4, "Y2")) }) do
		table.insert(kids, n)
	end
	return ui.column(kids)
end

export type SpringProps = { L: any, id: string, value: any?, preset: string?, commit: ((sp: any) -> ())?, live_ms: any? }

-- The time axis for a settle time: room after it, in half seconds (quarters
-- under one second), so small changes keep the axis still.
local function fit_axis(settle: number): number
	local s = settle * 1.2
	return if s <= 1 then math.max(0.25, math.ceil(s / 0.25) * 0.25) else math.ceil(s / 0.5) * 0.5
end

-- Where a spring peaks (its first overshoot), in seconds, and how high; nil
-- when it doesn't overshoot.
local function peak(sp: any, x: (number) -> number): (number?, number?)
	local m = math.max(sp.mass or 1, 1e-3)
	local k = math.max(sp.stiffness or 100, 1e-3)
	local c = math.max(sp.damping or 10, 1e-3)
	local w0 = math.sqrt(k / m)
	local zeta = c / (2 * math.sqrt(k * m))
	if zeta >= 0.999 or (sp.velocity or 0) ~= 0 then
		return nil, nil
	end
	local t = math.pi / (w0 * math.sqrt(1 - zeta * zeta))
	return t, x(t)
end

-- The top of the y range: room over the peak, in tenths, so a calm spring's
-- rise fills the graph and a bouncy one's overshoot shows.
local function fit_top(sp: any): number
	local x = Proto.spring(sp)
	local _, yp = peak(sp, x)
	return math.max(1.2, math.ceil(((yp or 1) + 0.12) * 10) / 10)
end

-- A spring's curve over a time axis (its settle time marked); with `commit`
-- (a custom spring), dragged as time and bounce, its numbers under Advanced.
function M.Spring(p: SpringProps): Node
	local L = p.L
	local live = ui.use_state(table.clone(p.value or DEFAULT))
	local _, settle0 = Proto.spring(live:peek())
	local axis = ui.use_state(fit_axis(settle0))
	local top = ui.use_state(fit_top(live:peek())) -- (as the axis: still while dragging unless it must grow)
	local held = ui.use_state(false)
	local grab: any = nil -- { x, y, bounce, duration, settle, axis } at the press
	local pl: Plot = { w = 248, lo = -0.08, hi = 1.2 }
	local commit = p.commit
	local function show_ms(settle: number)
		if p.live_ms then
			p.live_ms:set(math.floor(settle * 1000 + 0.5))
		end
	end
	local graph: any = {
		id = `{p.id}-graph`,
		label = if commit then "Spring: drag sideways for time, up and down for bounce" else "Spring curve",
		w_full = true,
		h = H,
		on_resize = function(s: any)
			pl.w = math.max(2 * PAD_X + 10, s.w)
		end,
		ui.canvas {
			w_full = true,
			h = H,
			pointer_events = "none",
			draw = function(c: Canvas, cw: number)
				local sp = live:get()
				local T = axis:get()
				local g: Plot = { w = cw, lo = pl.lo, hi = top:get() }
				frame(c, L, g, false)
				local x, settle = Proto.spring(sp)
				-- the curve to the axis's end (at rest after it settles)
				local path = ui.path()
				local n = 96
				for i = 0, n do
					local t = T * i / n
					local px, py = to_px(g, i / n, math.clamp(x(t), g.lo, g.hi))
					path = if i == 0 then path:move(px, py) else path:line(px, py)
				end
				c:stroke(path, L.accent, 2, { join = "round", cap = "round" })
				-- the settle time: a dashed line down from the rest level
				local sx = math.min(settle / T, 1)
				local lx, ly = to_px(g, sx, 1)
				local _, by = to_px(g, sx, 0)
				c:line(lx, ly, lx, by, L.faint, 1, { dash = { 3, 3 } })
				c:circle(lx, ly, 2.5, L.faint)
				-- the dot to drag: the peak (the rest point without one)
				local tp, yp = peak(sp, x)
				local dx, dy = lx, ly
				if tp and yp and tp < T then
					dx, dy = to_px(g, tp / T, math.clamp(yp, g.lo, g.hi))
				end
				if commit then
					local r = if held:get() then 6.5 else 5
					c:circle(dx, dy, r, if held:get() then L.accent else L.panel_solid)
					c:stroke(ui.path():ellipse(dx - r, dy - r, 2 * r, 2 * r), L.accent, 2)
				end
				local bounce = Proto.spring_feel(sp)
				text(c, `Bounce {math.floor(bounce * 100 + 0.5)}%`, PAD_X, 9, L.muted, "start")
				text(c, `{math.floor(settle * 1000 + 0.5)} ms`, cw - PAD_X, 9, L.fg or L.muted, "end")
				if commit then
					text(c, "Drag sideways for time, up or down for bounce", cw / 2, H - 17, L.faint, "center", 10.5)
				end
			end,
		},
	}
	if commit then
		graph.cursor = "grab"
		graph.on_press = function(e: any)
			local sp = live:peek()
			local b, d = Proto.spring_feel(sp)
			local _, s = Proto.spring(sp)
			grab = { x = e.local_x, y = e.local_y, bounce = b, duration = d, settle = s, axis = axis:peek() }
			held:set(true)
		end
		graph.on_pointer_move = function(e: any)
			local g = grab
			if not g then
				return
			end
			local pw = math.max(10, pl.w - 2 * PAD_X)
			-- sideways: the settle time follows the pointer on the axis as pressed
			local settle = math.clamp(g.settle + (e.local_x - g.x) * g.axis / pw, 0.05, 10)
			local duration = round(math.clamp(g.duration * settle / g.settle, 0.05, 4), 0.001)
			local bounce = round(math.clamp(g.bounce - (e.local_y - g.y) / BOUNCE_PX, -0.5, 0.9))
			local sp = Proto.spring_from_feel(bounce, duration, live:peek())
			local was = live:peek()
			if sp.stiffness == was.stiffness and sp.damping == was.damping then
				return
			end
			live:set(sp)
			local x, s = Proto.spring(sp)
			local _, yp = peak(sp, x)
			if yp and yp + 0.04 > top:peek() then
				top:set(fit_top(sp))
			end
			if s > axis:peek() * 0.95 then
				axis:set(fit_axis(s)) -- (the axis grows to keep the end in view)
			end
			show_ms(s)
		end
		graph.on_release = function()
			if grab then
				grab = nil
				held:set(false)
				local sp, v = live:peek(), p.value or DEFAULT
				if sp.stiffness ~= v.stiffness or sp.damping ~= v.damping or sp.mass ~= v.mass then
					commit(table.clone(sp))
				end
			end
		end
	end
	local kids: any = { id = p.id, w_full = true, gap = 6, ui.div(graph) }
	if commit then
		local function field(key: string, name: string, step: number, lo: number, hi: number): Node
			return Kit.num(L, {
				id = `{p.id}-{key}`,
				tip = name,
				step = step,
				min = lo,
				max = hi,
				get = function(): number?
					return live:get()[key]
				end,
				set = function(v: number)
					local sp = table.clone(live:peek())
					sp[key] = math.clamp(v, lo, hi)
					live:set(sp)
					show_ms(select(2, Proto.spring(sp)))
					commit(sp)
				end,
			})
		end
		for _, n in
			advanced(L, p.id, {
				labelled(L, "Mass", field("mass", "Mass", 0.1, 0.1, 100)),
				labelled(L, "Stiffness", field("stiffness", "Stiffness", 10, 1, 10000)),
				labelled(L, "Damping", field("damping", "Damping", 1, 0, 1000)),
			})
		do
			table.insert(kids, n)
		end
	end
	return ui.column(kids)
end

return M
