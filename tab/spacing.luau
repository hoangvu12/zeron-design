--!strict
-- (N7) Figma's spacing handles on the board: an auto layout frame's gap
-- between children and its padding on each side, shown as hatched pink
-- areas with a small bar handle in each; dragging a bar changes that value.
-- Pure: geometry, hit testing, the live preview (the children placed again
-- in the tab, with their sizes as drawn) and the overlay drawing. The
-- Canvas (canvas.luau) holds the state, lifts the frame while dragging (as a
-- resize does, D6) and sends one edit on release.
--
-- A scene item with a layout carries `flow` (engine/scene.luau): `g` gap,
-- `p` {t, r, b, l}, `j` justify, `a` align, `hug` bits (1 width, 2 height);
-- a child that fills carries `fl` bits. (The layout has no wrap.)

local Draw = require("./draw")

local M = {}

M.COLOR = "#EC4899" -- Figma's spacing pink
M.SNAP = 8 -- Shift: values in steps of 8
local HANDLE_LONG, HANDLE_THICK = 14, 4
local HIT = 6 -- px around a handle
local MIN_PX = 28 -- smaller frames on screen get no handles

export type Geom = {
	id: string,
	lay: string, -- "horizontal" | "vertical"
	b: { number }, -- the frame's box on the Canvas
	g: number,
	p: { number }, -- t, r, b, l
	j: string?,
	a: string?,
	hug: number,
	auto: boolean, -- space_between / space_around: the gap is "Auto"
	kids: { { id: string, b: { number }, fl: number } }, -- in flow, in order
}

export type Part = { kind: string, side: number?, k: number? } -- "pad" side 1..4 (t r b l), "gap" k (after kid k)

-- The frame's geometry from the Canvas's index, or nil (no layout, turned).
function M.geom(ix: any, id: string): Geom?
	local n = ix.by[id]
	if not n or n.turned or n.it.xf then
		return nil
	end
	local it = n.it
	local f = it.flow
	if not f or not it.lay or it.hidden then
		return nil
	end
	local kids = {}
	for _, kid in ix.kids[id] or {} do
		local k = ix.by[kid]
		if k and not k.it.abs and not k.it.hidden then
			table.insert(kids, { id = kid, b = k.bounds, fl = k.it.fl or 0 })
		end
	end
	local j = f.j
	return {
		id = id,
		lay = it.lay,
		b = n.bounds,
		g = f.g or 0,
		p = f.p or { 0, 0, 0, 0 },
		j = j,
		a = f.a,
		hug = f.hug or 0,
		auto = j == "space_between" or j == "space_around",
		kids = kids,
	}
end

-- The hatched areas and handles, in Canvas units (handles placed with the
-- zoom, so they keep their screen size and stay off the frame's edge).
-- Each: { part, rect = {x,y,w,h}, hx, hy (handle centre), along = "x"|"y"
-- (the handle bar's long side), value, label }.
function M.zones(g: Geom, zoom: number): { any }
	local out = {}
	local x, y, w, h = g.b[1], g.b[2], g.b[3], g.b[4]
	if w * zoom < MIN_PX or h * zoom < MIN_PX then
		return out
	end
	local p = g.p
	local inset = 9 / zoom -- a 0 padding's handle sits this far in (off the resize edge)
	local function at(v: number): number
		return math.max(v / 2, inset)
	end
	-- (top, right, bottom, left)
	table.insert(out, { part = { kind = "pad", side = 1 }, rect = { x, y, w, p[1] }, hx = x + w / 2, hy = y + at(p[1]), along = "x", value = p[1] })
	table.insert(out, { part = { kind = "pad", side = 2 }, rect = { x + w - p[2], y, p[2], h }, hx = x + w - at(p[2]), hy = y + h / 2, along = "y", value = p[2] })
	table.insert(out, { part = { kind = "pad", side = 3 }, rect = { x, y + h - p[3], w, p[3] }, hx = x + w / 2, hy = y + h - at(p[3]), along = "x", value = p[3] })
	table.insert(out, { part = { kind = "pad", side = 4 }, rect = { x, y, p[4], h }, hx = x + at(p[4]), hy = y + h / 2, along = "y", value = p[4] })
	local hor = g.lay == "horizontal"
	local c0 = if hor then y + p[1] else x + p[4]
	local c1 = if hor then y + h - p[3] else x + w - p[2]
	for k = 1, #g.kids - 1 do
		local a, b = g.kids[k].b, g.kids[k + 1].b
		local s0 = if hor then a[1] + a[3] else a[2] + a[4]
		local s1 = if hor then b[1] else b[2]
		local mid = (s0 + s1) / 2
		local cm = (c0 + c1) / 2
		local rect = if hor then { s0, c0, math.max(0, s1 - s0), math.max(0, c1 - c0) } else { c0, s0, math.max(0, c1 - c0), math.max(0, s1 - s0) }
		table.insert(out, {
			part = { kind = "gap", k = k },
			rect = rect,
			hx = if hor then mid else cm,
			hy = if hor then cm else mid,
			along = if hor then "y" else "x",
			value = g.g,
			auto = g.auto,
		})
	end
	return out
end

local function in_rect(r: { number }, x: number, y: number, pad: number): boolean
	return x >= r[1] - pad and x <= r[1] + r[3] + pad and y >= r[2] - pad and y <= r[2] + r[4] + pad
end

-- What's at Canvas point (x, y): the handle (`grab` true, draggable unless
-- the gap is Auto) or the hatched area under it, or nil.
function M.hit(zones: { any }, x: number, y: number, zoom: number): (any?, boolean)
	local tol = HIT / zoom
	-- (gaps first: they sit between children, the pads along the edges)
	for pass = 1, 2 do
		for k = #zones, 1, -1 do
			local z = zones[k]
			local long = (HANDLE_LONG / 2) / zoom + tol
			local thick = (HANDLE_THICK / 2) / zoom + tol
			local dx, dy = math.abs(x - z.hx), math.abs(y - z.hy)
			local on = if z.along == "x" then dx <= long and dy <= thick else dx <= thick and dy <= long
			if pass == 1 and on then
				return z, not z.auto
			elseif pass == 2 and z.rect[3] > 0 and z.rect[4] > 0 and in_rect(z.rect, x, y, 0) then
				return z, false
			end
		end
	end
	return nil, false
end

local function same(a: Part?, b: Part?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.kind == b.kind and a.side == b.side and a.k == b.k
end
M.same = same

-- A drag's new values: `d` the pointer's move on the Canvas since the
-- press; Shift steps of 8; Alt: every padding side alike.
function M.values(g: Geom, part: Part, dx: number, dy: number, shift: boolean, alt: boolean): (number, { number })
	local gap, pad = g.g, table.clone(g.p)
	local function fix(v: number): number
		v = math.max(0, v)
		if shift then
			return math.floor(v / M.SNAP + 0.5) * M.SNAP
		end
		return math.floor(v + 0.5)
	end
	if part.kind == "gap" then
		gap = fix(g.g + (if g.lay == "horizontal" then dx else dy))
	else
		local s = part.side :: number
		local d = if s == 1 then dy elseif s == 2 then -dx elseif s == 3 then -dy else dx
		local v = fix(g.p[s] + d)
		if alt then
			pad = { v, v, v, v }
		else
			pad[s] = v
		end
	end
	return gap, pad
end

-- The frame laid out again with a new gap and padding, the children's
-- sizes as drawn (fill children share what's left; a hug side follows its
-- children), as engine/layout.luau's flow does. The frame's top-left stays.
-- Gives the new geometry and the `live` for draw.luau: maps (each child
-- moved) and boxes (the frame's and fill children's new sizes).
function M.relayout(g: Geom, gap: number, pad: { number }): (Geom, any)
	local hor = g.lay == "horizontal"
	local main = if hor then 1 else 2
	local cross = 3 - main
	local n = #g.kids
	local x, y = g.b[1], g.b[2]
	local size = { g.b[3], g.b[4] }
	local padm = if hor then { pad[4], pad[2] } else { pad[1], pad[3] } -- start, end on the main axis
	local padc = if hor then { pad[1], pad[3] } else { pad[4], pad[2] }
	local sizes = {}
	for k, kid in g.kids do
		sizes[k] = { kid.b[3], kid.b[4] }
	end
	local fill_main = if main == 1 then 1 else 2
	local fill_cross = if cross == 1 then 1 else 2
	local hug_main = bit32.band(g.hug, fill_main) ~= 0
	local hug_cross = bit32.band(g.hug, fill_cross) ~= 0
	local gaps = gap * math.max(n - 1, 0)
	-- main axis
	local fixed, fills = 0, {}
	for k, kid in g.kids do
		if bit32.band(kid.fl, fill_main) ~= 0 and not hug_main then
			table.insert(fills, k)
		else
			fixed += sizes[k][main]
		end
	end
	if hug_main then
		size[main] = padm[1] + padm[2] + fixed + gaps
	end
	local inner_main = math.max(size[main] - padm[1] - padm[2], 0)
	if #fills > 0 then
		local share = math.max(inner_main - fixed - gaps, 0) / #fills
		for _, k in fills do
			sizes[k][main] = share
		end
	end
	-- cross axis
	if hug_cross then
		local m = 0
		for k, kid in g.kids do
			if bit32.band(kid.fl, fill_cross) == 0 then
				m = math.max(m, sizes[k][cross])
			end
		end
		size[cross] = padc[1] + padc[2] + m
	end
	local inner_cross = math.max(size[cross] - padc[1] - padc[2], 0)
	for k, kid in g.kids do
		if bit32.band(kid.fl, fill_cross) ~= 0 then
			sizes[k][cross] = inner_cross
		end
	end
	-- place
	local used = gaps
	for k = 1, n do
		used += sizes[k][main]
	end
	local left = inner_main - used
	local at, between = 0, gap
	local j = g.j
	if j == "center" then
		at = left / 2
	elseif j == "end" then
		at = left
	elseif j == "space_between" then
		if n > 1 and left > 0 then
			between = gap + left / (n - 1)
		end
	elseif j == "space_around" then
		if left > 0 then
			at, between = left / n / 2, gap + left / n
		else
			at = left / 2
		end
	end
	local origin = { x + (if hor then padm[1] else padc[1]), y + (if hor then padc[1] else padm[1]) }
	local maps, boxes = {}, {}
	local kids2 = {}
	for k, kid in g.kids do
		local cs = sizes[k]
		local pos = { origin[1], origin[2] }
		pos[main] += at
		local free = inner_cross - cs[cross]
		if g.a == "center" then
			pos[cross] += free / 2
		elseif g.a == "end" then
			pos[cross] += free
		end
		at += cs[main] + between
		local dx, dy = pos[1] - kid.b[1], pos[2] - kid.b[2]
		if math.abs(dx) > 1e-6 or math.abs(dy) > 1e-6 then
			maps[kid.id] = Draw.translate(dx, dy)
		end
		if math.abs(cs[1] - kid.b[3]) > 1e-6 or math.abs(cs[2] - kid.b[4]) > 1e-6 then
			boxes[kid.id] = { w = cs[1], h = cs[2] }
		end
		table.insert(kids2, { id = kid.id, b = { pos[1], pos[2], cs[1], cs[2] }, fl = kid.fl })
	end
	if size[1] ~= g.b[3] or size[2] ~= g.b[4] then
		boxes[g.id] = { w = size[1], h = size[2] }
	end
	local g2 = table.clone(g)
	g2.b = { x, y, size[1], size[2] }
	g2.g = gap
	g2.p = pad
	g2.kids = kids2
	return g2, { maps = maps, boxes = boxes }
end

-- The ops for the new values (one edit, one undo step): the file's own
-- shapes (a number, {v, h}, {t, r, b, l}), 0 as no value.
function M.ops(g: Geom, gap: number, pad: { number }): { any }
	local props: { [string]: any } = {}
	if gap ~= g.g then
		props.gap = if gap == 0 then "__null" else gap
	end
	local changed = false
	for s = 1, 4 do
		if pad[s] ~= g.p[s] then
			changed = true
		end
	end
	if changed then
		local t, r, b, l = pad[1], pad[2], pad[3], pad[4]
		if t == r and r == b and b == l then
			props.padding = if t == 0 then "__null" else t
		elseif t == b and r == l then
			props.padding = { t, r }
		else
			props.padding = { t, r, b, l }
		end
	end
	if next(props) == nil then
		return {}
	end
	return { { op = "update", id = g.id, props = props } }
end

local function fmt(v: number): string
	local r = math.floor(v * 100 + 0.5) / 100
	if r == math.floor(r) then
		return tostring(math.floor(r))
	end
	return tostring(r)
end
M.fmt = fmt

-- Diagonal hatch lines (45°, every `step` px on screen) inside a screen rect.
local function hatch(c: any, x: number, y: number, w: number, h: number, col: string, step: number)
	if w <= 0 or h <= 0 then
		return
	end
	-- lines x - y = k, k from x - (y + h) to x + w - y
	local k0 = x - (y + h)
	local k1 = x + w - y
	local k = math.ceil(k0 / step) * step
	while k <= k1 do
		-- the line's ends inside the rect
		local ax = math.max(x, k + y)
		local ay = ax - k
		local bx = math.min(x + w, k + y + h)
		local by = bx - k
		if bx > ax then
			c:line(ax, ay, bx, by, col, 1)
		end
		k += step
	end
end

-- Draws the zones on the overlay. `sx`, `sy`: Canvas → screen; `hot` the
-- part under the pointer or dragged (strong, with its value), `all` every
-- zone faintly too (the pointer inside the frame, or a drag).
function M.draw(c: any, zones: { any }, zoom: number, sx: (number) -> number, sy: (number) -> number, hot: Part?, dragging: boolean, pill: (x: number, y: number, text: string, bg: string, fg: string, anchor: string) -> ())
	local col = M.COLOR
	for _, z in zones do
		local is_hot = same(z.part, hot)
		local r = z.rect
		local x0, y0 = sx(r[1]), sy(r[2])
		local w, h = r[3] * zoom, r[4] * zoom
		if is_hot then
			c:rect(x0, y0, w, h, col .. "26")
			hatch(c, x0, y0, w, h, col .. "99", 6)
		end
		-- the handle: a white-edged pink bar (not for an Auto gap)
		if not z.auto and (not dragging or is_hot) then
			local hx, hy = sx(z.hx), sy(z.hy)
			local bw = if z.along == "x" then HANDLE_LONG else HANDLE_THICK
			local bh = if z.along == "x" then HANDLE_THICK else HANDLE_LONG
			c:rect(hx - bw / 2 - 1, hy - bh / 2 - 1, bw + 2, bh + 2, "#FFFFFF", 3)
			c:rect(hx - bw / 2, hy - bh / 2, bw, bh, col, 2)
		end
		if is_hot then
			local text = if z.auto then "Auto" else fmt(z.value)
			local hx, hy = sx(z.hx), sy(z.hy)
			-- (beside the bar, out of the pointer's way)
			if z.along == "x" then
				pill(hx, hy + 8, text, col, "#FFFFFF", "middle")
			else
				pill(hx + 9, hy - 9, text, col, "#FFFFFF", "start")
			end
		end
	end
end

return M
