--!strict
-- Drawing a Design's scene (pure/CONTRACT.md §4) on a zgx canvas: one root
-- (a Screen, a Component) at a time, its items in paint order. The Canvas
-- (canvas.luau) draws each root as one `each` item of its board, so a change
-- to one Screen draws that Screen alone; `ui.render_canvas` draws with the
-- same function for agents' screenshots.
--
-- What zgx's canvas can't do yet, and what this does instead:
--   - no transforms: rotated/flipped shapes are drawn as transformed paths
--     (curves through their control points, exact under an affine map);
--     text stays upright (placed at its rotated top-left);
--   - no layers: a node's opacity multiplies the alpha of its own and its
--     descendants' colours (overlaps inside it show through each other);
--   - text sits over every shape of the canvas and isn't clipped by
--     `c:clip`: text wholly outside its clip is left out;
--   - `ui.linear` spaces its colours evenly: stops at other places are
--     resampled to 9 even ones; radial and angular are drawn as linear.

local M = {}

-- Pictures kept in zeron.db, by key: a Bitmap once decoded, `false` while
-- it can't be. `M.want(key)` asks for one (the source that knows how sets
-- `M.fetch`); each decoded picture tells `M.on_image` listeners.
M.images = {} :: { [string]: any }
M.fetch = nil :: ((key: string, done: (base64: string?) -> ()) -> ())?
M.listeners = {} :: { (key: string) -> () }
local asked: { [string]: boolean } = {}
-- Who waits for a picture (a screenshot): called once it's there or failed.
local waiters: { [string]: { () -> () } } = {}
local function settled(key: string)
	local w = waiters[key]
	waiters[key] = nil
	for _, f in w or {} do
		f()
	end
end
function M.want(key: string)
	if asked[key] or not M.fetch then
		return
	end
	asked[key] = true
	-- (Out of the drawing: a canvas's draw writes no state.)
	ui.after(0, function()
		local fetch = M.fetch :: any
		fetch(key, function(b64: string?)
			if not b64 then
				M.images[key] = false
				settled(key)
				return
			end
			-- (zgx before nightly-design 066f3c583 has no decode_image.)
			if not (ui :: any).decode_image then
				M.images[key] = false
				settled(key)
				return
			end
			ui.decode_image(b64):after(function(bitmap: any)
				M.images[key] = bitmap
				for _, l in M.listeners do
					l(key)
				end
				settled(key)
			end, function()
				M.images[key] = false
				settled(key)
			end)
		end)
	end)
end

-- The `img:` keys a root's items show.
function M.picture_keys(nodes: { any }): { string }
	local out, seen = {}, {}
	for _, it in nodes do
		for _, p in it.fill or {} do
			if type(p.src) == "string" and string.sub(p.src, 1, 4) == "img:" then
				local key = string.sub(p.src, 5)
				if not seen[key] then
					seen[key] = true
					table.insert(out, key)
				end
			end
		end
	end
	return out
end

-- `done` once every one of `keys` is decoded (or can't be).
function M.ensure(keys: { string }, done: () -> ())
	local left = 0
	local finished = false
	local function one()
		left -= 1
		if left <= 0 and not finished then
			finished = true
			done()
		end
	end
	for _, key in keys do
		if M.images[key] == nil then
			left += 1
			waiters[key] = waiters[key] or {}
			table.insert(waiters[key], one)
			M.want(key)
		end
	end
	if left == 0 then
		finished = true
		done()
	end
end

-- Things that draw every root again (a font arrived): the sources add one.
M.redrawers = {} :: { () -> () }
function M.redraw_all()
	for _, f in M.redrawers do
		f()
	end
end

export type Affine = { a: number, b: number, c: number, d: number, e: number, f: number }

local K = 0.5522847498 -- a quarter circle's cubic handle

-- Colours ---------------------------------------------------------------------

local function hexbyte(s: string, i: number): number
	return tonumber(string.sub(s, i, i + 1), 16) or 0
end

-- "#rrggbbaa" with its alpha times `op`.
local function fade(color: string, op: number): string
	if op >= 0.999 or type(color) ~= "string" or string.sub(color, 1, 1) ~= "#" then
		return color
	end
	local hex = string.sub(color, 2)
	if #hex == 6 then
		hex ..= "ff"
	end
	local a = math.clamp(math.floor(hexbyte(hex, 7) * op + 0.5), 0, 255)
	return "#" .. string.sub(hex, 1, 6) .. string.format("%02x", a)
end
M.fade = fade

local function mix(c1: string, c2: string, t: number): string
	local function ch(i: number): number
		local a = hexbyte(string.sub(c1, 2) .. "ff", i)
		local b = hexbyte(string.sub(c2, 2) .. "ff", i)
		return math.clamp(math.floor(a + (b - a) * t + 0.5), 0, 255)
	end
	return string.format("#%02x%02x%02x%02x", ch(1), ch(3), ch(5), ch(7))
end

-- Affine maps -------------------------------------------------------------------

local function translate(x: number, y: number): Affine
	return { a = 1, b = 0, c = 0, d = 1, e = x, f = y }
end
M.translate = translate

-- a then b: b(a(p)).
local function compose(b: Affine, a: Affine): Affine
	return {
		a = b.a * a.a + b.c * a.b,
		b = b.b * a.a + b.d * a.b,
		c = b.a * a.c + b.c * a.d,
		d = b.b * a.c + b.d * a.d,
		e = b.a * a.e + b.c * a.f + b.e,
		f = b.b * a.e + b.d * a.f + b.f,
	}
end
M.compose = compose

local function invert(m: Affine): Affine
	local det = m.a * m.d - m.b * m.c
	if math.abs(det) < 1e-12 then
		return translate(-m.e, -m.f)
	end
	local ia, ib, ic, id = m.d / det, -m.b / det, -m.c / det, m.a / det
	return { a = ia, b = ib, c = ic, d = id, e = -(ia * m.e + ic * m.f), f = -(ib * m.e + id * m.f) }
end
M.invert = invert

local function apply(m: Affine, x: number, y: number): (number, number)
	return m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f
end
M.apply = apply

-- Turned by `deg` counter-clockwise (the file's sense; y down on screen)
-- about (ox, oy).
local function rotation(deg: number, ox: number, oy: number): Affine
	local r = -math.rad(deg)
	local cs, sn = math.cos(r), math.sin(r)
	return compose(translate(ox, oy), compose({ a = cs, b = sn, c = -sn, d = cs, e = 0, f = 0 }, translate(-ox, -oy)))
end
M.rotation = rotation

local function upright(m: Affine): boolean
	return math.abs(m.b) < 1e-9 and math.abs(m.c) < 1e-9 and math.abs(m.a - 1) < 1e-9 and math.abs(m.d - 1) < 1e-9
end
M.upright = upright

-- An item's local (0..w, 0..h) → Canvas map: its `xf`, or its box's corner.
function M.local_map(it: any): Affine
	local xf = it.xf
	if xf then
		return { a = xf.a, b = xf.b, c = xf.c, d = xf.d, e = xf.e, f = xf.f }
	end
	return translate(it.box.x, it.box.y)
end

-- Paths: a pen through a map -----------------------------------------------------

-- Commands in local space, absolute: { "M", x, y }, { "L", x, y },
-- { "C", x1, y1, x2, y2, x, y }, { "Q", x1, y1, x, y }, { "Z" }.
type Cmd = { any }

local function path_of(cmds: { Cmd }, m: Affine): Path
	local p = ui.path()
	for _, k in cmds do
		local op = k[1]
		if op == "M" then
			p = p:move(apply(m, k[2], k[3]))
		elseif op == "L" then
			p = p:line(apply(m, k[2], k[3]))
		elseif op == "C" then
			local x1, y1 = apply(m, k[2], k[3])
			local x2, y2 = apply(m, k[4], k[5])
			local x, y = apply(m, k[6], k[7])
			p = p:cubic(x1, y1, x2, y2, x, y)
		elseif op == "Q" then
			local x1, y1 = apply(m, k[2], k[3])
			local x, y = apply(m, k[4], k[5])
			p = p:quad(x1, y1, x, y)
		elseif op == "Z" then
			p = p:close()
		end
	end
	return p
end

-- A rounded rectangle x, y, w, h with radii { tl, tr, br, bl }.
local function rrect_cmds(x: number, y: number, w: number, h: number, r: { number }?): { Cmd }
	local tl, tr, br, bl = 0, 0, 0, 0
	if r then
		local m = math.max(0, math.min(w, h) / 2)
		tl, tr, br, bl = math.min(r[1] or 0, m), math.min(r[2] or 0, m), math.min(r[3] or 0, m), math.min(r[4] or 0, m)
	end
	local out: { Cmd } = { { "M", x + tl, y }, { "L", x + w - tr, y } }
	if tr > 0 then
		table.insert(out, { "C", x + w - tr + tr * K, y, x + w, y + tr - tr * K, x + w, y + tr })
	end
	table.insert(out, { "L", x + w, y + h - br })
	if br > 0 then
		table.insert(out, { "C", x + w, y + h - br + br * K, x + w - br + br * K, y + h, x + w - br, y + h })
	end
	table.insert(out, { "L", x + bl, y + h })
	if bl > 0 then
		table.insert(out, { "C", x + bl - bl * K, y + h, x, y + h - bl + bl * K, x, y + h - bl })
	end
	table.insert(out, { "L", x, y + tl })
	if tl > 0 then
		table.insert(out, { "C", x, y + tl - tl * K, x + tl - tl * K, y, x + tl, y })
	end
	table.insert(out, { "Z" })
	return out
end

-- An elliptical arc on the ellipse in (x, y, w, h), from `a0` sweeping `sw`
-- degrees (clockwise on screen), as cubics; `first` starts it with M (else L).
local function arc_cmds(out: { Cmd }, x: number, y: number, w: number, h: number, a0: number, sw: number, first: boolean)
	local cx, cy, rx, ry = x + w / 2, y + h / 2, w / 2, h / 2
	local n = math.max(1, math.ceil(math.abs(sw) / 90))
	local step = math.rad(sw / n)
	local t = math.rad(a0)
	local px, py = cx + rx * math.cos(t), cy + ry * math.sin(t)
	table.insert(out, { if first then "M" else "L", px, py })
	local kk = 4 / 3 * math.tan(step / 4)
	for _ = 1, n do
		local t2 = t + step
		local x2, y2 = cx + rx * math.cos(t2), cy + ry * math.sin(t2)
		table.insert(out, {
			"C",
			px - kk * rx * math.sin(t),
			py + kk * ry * math.cos(t),
			x2 + kk * rx * math.sin(t2),
			y2 - kk * ry * math.cos(t2),
			x2,
			y2,
		})
		t, px, py = t2, x2, y2
	end
end

-- An ellipse shape (with `start`, `sweep`, `inner`) in a w × h box.
local function ellipse_cmds(w: number, h: number, sh: any, inset: number): { Cmd }
	local x, y, ww, hh = inset, inset, w - 2 * inset, h - 2 * inset
	local sweep = sh.sweep or 360
	local start = sh.start or 0
	local inner = sh.inner or 0
	local out: { Cmd } = {}
	if sweep >= 360 and inner <= 0 then
		arc_cmds(out, x, y, ww, hh, 0, 360, true)
		table.insert(out, { "Z" })
		return out
	end
	-- (The file's angles: counter-clockwise from +x; on screen, negated.)
	local a0, sw = -start, -sweep
	if inner > 0 then
		arc_cmds(out, x, y, ww, hh, a0, sw, true)
		local ix, iy = x + ww / 2 * (1 - inner), y + hh / 2 * (1 - inner)
		arc_cmds(out, ix, iy, ww * inner, hh * inner, a0 + sw, -sw, false)
	else
		table.insert(out, { "M", x + ww / 2, y + hh / 2 })
		arc_cmds(out, x, y, ww, hh, a0, sw, false)
	end
	table.insert(out, { "Z" })
	return out
end

-- A regular polygon in a w × h box, its edges moved out by `grow` (in by a
-- negative one: an inside stroke's centre line), each corner where its two
-- moved edges meet.
local function polygon_cmds(w: number, h: number, sides: number, grow: number?): { Cmd }
	local out: { Cmd } = {}
	sides = math.max(3, sides)
	local pts = {}
	for i = 0, sides - 1 do
		local t = -math.pi / 2 + i * 2 * math.pi / sides
		table.insert(pts, { w / 2 + w / 2 * math.cos(t), h / 2 + h / 2 * math.sin(t) })
	end
	local g = grow or 0
	if g ~= 0 then
		-- (Clockwise on screen: an edge's outward normal is (dy, -dx).)
		local moved = {}
		for i = 1, sides do
			local a, b, c = pts[(i - 2) % sides + 1], pts[i], pts[i % sides + 1]
			local function normal(p: { number }, q: { number }): (number, number)
				local dx, dy = q[1] - p[1], q[2] - p[2]
				local len = math.sqrt(dx * dx + dy * dy)
				if len == 0 then
					return 0, 0
				end
				return dy / len, -dx / len
			end
			local n1x, n1y = normal(a, b)
			local n2x, n2y = normal(b, c)
			local bx, by = n1x + n2x, n1y + n2y
			local dot = 1 + n1x * n2x + n1y * n2y
			if dot < 1e-6 then
				table.insert(moved, { b[1] + n1x * g, b[2] + n1y * g })
			else
				table.insert(moved, { b[1] + bx * g / dot, b[2] + by * g / dot })
			end
		end
		pts = moved
	end
	for i, q in pts do
		table.insert(out, { if i == 1 then "M" else "L", q[1], q[2] })
	end
	table.insert(out, { "Z" })
	return out
end

-- SVG path data ---------------------------------------------------------------------

-- An SVG arc (endpoint form) as cubics, appended to `out`.
local function svg_arc(out: { Cmd }, x1: number, y1: number, rx: number, ry: number, phi: number, large: boolean, sweep: boolean, x2: number, y2: number)
	if rx == 0 or ry == 0 then
		table.insert(out, { "L", x2, y2 })
		return
	end
	rx, ry = math.abs(rx), math.abs(ry)
	local cp, sp = math.cos(math.rad(phi)), math.sin(math.rad(phi))
	local dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
	local x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
	local lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
	if lam > 1 then
		local s = math.sqrt(lam)
		rx, ry = rx * s, ry * s
	end
	local num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
	local den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
	local co = math.sqrt(math.max(0, num / den))
	if large == sweep then
		co = -co
	end
	local cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
	local cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2
	local function ang(ux: number, uy: number, vx: number, vy: number): number
		local a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
		return a
	end
	local t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
	local dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
	if not sweep and dt > 0 then
		dt -= 2 * math.pi
	elseif sweep and dt < 0 then
		dt += 2 * math.pi
	end
	local n = math.max(1, math.ceil(math.abs(dt) / (math.pi / 2)))
	local step = dt / n
	local kk = 4 / 3 * math.tan(step / 4)
	local t = t1
	local function pt(tt: number): (number, number, number, number)
		local ex, ey = rx * math.cos(tt), ry * math.sin(tt)
		local px, py = cp * ex - sp * ey + cx, sp * ex + cp * ey + cy
		-- derivative
		local dxx, dyy = -rx * math.sin(tt), ry * math.cos(tt)
		return px, py, cp * dxx - sp * dyy, sp * dxx + cp * dyy
	end
	local px, py, tx, ty = pt(t)
	for _ = 1, n do
		local t2 = t + step
		local qx, qy, ux, uy = pt(t2)
		table.insert(out, { "C", px + kk * tx, py + kk * ty, qx - kk * ux, qy - kk * uy, qx, qy })
		t, px, py, tx, ty = t2, qx, qy, ux, uy
	end
end

local parsed: { [string]: { Cmd } } = {}
local parsed_count = 0

-- SVG path data as absolute commands (kept: icons repeat).
local function parse_svg(d: string): { Cmd }
	local hit = parsed[d]
	if hit then
		return hit
	end
	local out: { Cmd } = {}
	local i, n = 1, #d
	local function skip()
		while i <= n do
			local ch = string.sub(d, i, i)
			if ch == " " or ch == "," or ch == "\n" or ch == "\t" or ch == "\r" then
				i += 1
			else
				break
			end
		end
	end
	local function number(): number?
		skip()
		local s, e = string.find(d, "^[-+]?%d*%.?%d+[eE][-+]?%d+", i)
		if not s then
			s, e = string.find(d, "^[-+]?%d*%.?%d+", i)
		end
		if not s then
			s, e = string.find(d, "^[-+]?%d+%.", i)
		end
		if not s or not e then
			return nil
		end
		local v = tonumber(string.sub(d, s, e))
		i = e + 1
		return v
	end
	local function flag(): boolean
		skip()
		local ch = string.sub(d, i, i)
		i += 1
		return ch == "1"
	end
	local cx, cy, sx, sy = 0, 0, 0, 0
	local lcx: number?, lcy: number? = nil, nil -- last cubic's second control
	local lqx: number?, lqy: number? = nil, nil
	local cmd = "M"
	while true do
		skip()
		if i > n then
			break
		end
		local ch = string.sub(d, i, i)
		if string.find(ch, "[MmLlHhVvCcSsQqTtAaZz]") then
			cmd = ch
			i += 1
		elseif not string.find(ch, "[-+%.%d]") then
			i += 1
			continue
		end
		local rel = string.lower(cmd) == cmd
		local up = string.upper(cmd)
		local ox, oy = if rel then cx else 0, if rel then cy else 0
		if up == "Z" then
			table.insert(out, { "Z" })
			cx, cy = sx, sy
			lcx, lqx = nil, nil
			continue
		end
		local a = number()
		if a == nil then
			i += 1
			continue
		end
		if up == "M" then
			local b = number() or 0
			cx, cy = ox + a, oy + b
			sx, sy = cx, cy
			table.insert(out, { "M", cx, cy })
			cmd = if rel then "l" else "L"
			lcx, lqx = nil, nil
		elseif up == "L" then
			local b = number() or 0
			cx, cy = ox + a, oy + b
			table.insert(out, { "L", cx, cy })
			lcx, lqx = nil, nil
		elseif up == "H" then
			cx = ox + a
			table.insert(out, { "L", cx, cy })
			lcx, lqx = nil, nil
		elseif up == "V" then
			cy = (if rel then cy else 0) + a
			table.insert(out, { "L", cx, cy })
			lcx, lqx = nil, nil
		elseif up == "C" then
			local b, c1, d1, e1, f1 = number() or 0, number() or 0, number() or 0, number() or 0, number() or 0
			table.insert(out, { "C", ox + a, oy + b, ox + c1, oy + d1, ox + e1, oy + f1 })
			lcx, lcy = ox + c1, oy + d1
			cx, cy = ox + e1, oy + f1
			lqx = nil
		elseif up == "S" then
			local b, c1, d1 = number() or 0, number() or 0, number() or 0
			local x1, y1 = cx, cy
			if lcx and lcy then
				x1, y1 = 2 * cx - lcx, 2 * cy - lcy
			end
			table.insert(out, { "C", x1, y1, ox + a, oy + b, ox + c1, oy + d1 })
			lcx, lcy = ox + a, oy + b
			cx, cy = ox + c1, oy + d1
			lqx = nil
		elseif up == "Q" then
			local b, c1, d1 = number() or 0, number() or 0, number() or 0
			table.insert(out, { "Q", ox + a, oy + b, ox + c1, oy + d1 })
			lqx, lqy = ox + a, oy + b
			cx, cy = ox + c1, oy + d1
			lcx = nil
		elseif up == "T" then
			local b = number() or 0
			local x1, y1 = cx, cy
			if lqx and lqy then
				x1, y1 = 2 * cx - lqx, 2 * cy - lqy
			end
			table.insert(out, { "Q", x1, y1, ox + a, oy + b })
			lqx, lqy = x1, y1
			cx, cy = ox + a, oy + b
			lcx = nil
		elseif up == "A" then
			local ry = number() or 0
			local phi = number() or 0
			local large = flag()
			local sweep = flag()
			local x2, y2 = number() or 0, number() or 0
			svg_arc(out, cx, cy, a, ry, phi, large, sweep, ox + x2, oy + y2)
			cx, cy = ox + x2, oy + y2
			lcx, lqx = nil, nil
		end
	end
	if parsed_count > 4000 then
		table.clear(parsed)
		parsed_count = 0
	end
	parsed[d] = out
	parsed_count += 1
	return out
end
M.parse_svg = parse_svg

-- `cmds` in a view box `vb`, fitted into a w × h box as SVG does (`meet`,
-- centred), or stretched.
local function fit_vb(vb: any?, w: number, h: number, stretch: boolean): Affine
	if not vb or not vb.w or vb.w == 0 or vb.h == 0 then
		return translate(0, 0)
	end
	local sx, sy = w / vb.w, h / vb.h
	if not stretch then
		local s = math.min(sx, sy)
		sx, sy = s, s
	end
	local ox, oy = (w - vb.w * sx) / 2, (h - vb.h * sy) / 2
	return { a = sx, b = 0, c = 0, d = sy, e = ox - vb.x * sx, f = oy - vb.y * sy }
end

-- Shapes -----------------------------------------------------------------------------

-- The item's outline in local space, grown by `out` (negative: inset).
local function outline_cmds(it: any, out: number): { Cmd }?
	local sh = it.shape
	local w, h = it.box.w, it.box.h
	if not sh then
		return nil
	end
	if sh.k == "rect" then
		local r = sh.r
		local rr: { number }? = nil
		if r then
			rr = {}
			for i = 1, 4 do
				(rr :: { number })[i] = math.max(0, (r[i] or 0) + out)
			end
		end
		return rrect_cmds(-out, -out, w + 2 * out, h + 2 * out, rr)
	elseif sh.k == "ellipse" then
		return ellipse_cmds(w, h, sh, -out)
	elseif sh.k == "polygon" then
		return polygon_cmds(w, h, sh.sides or 3, out)
	elseif sh.k == "path" then
		local cmds = parse_svg(sh.d or "")
		local f = fit_vb(sh.vb, w, h, true)
		local mapped: { Cmd } = {}
		for _, k in cmds do
			local op = k[1]
			if op == "Z" then
				table.insert(mapped, k)
			else
				local t: Cmd = { op }
				for j = 2, #k, 2 do
					local x, y = apply(f, k[j], k[j + 1])
					t[j], t[j + 1] = x, y
				end
				table.insert(mapped, t)
			end
		end
		return mapped
	end
	return nil
end

-- The outline as a path on the Canvas: zgx's own rect / ellipse where it can
-- (drawn by the GPU as shapes), else through the map.
local function shape_path(it: any, m: Affine, out: number): Path?
	local sh = it.shape
	if not sh then
		return nil
	end
	if upright(m) then
		local x, y, w, h = m.e - out, m.f - out, it.box.w + 2 * out, it.box.h + 2 * out
		if sh.k == "rect" then
			local r = sh.r
			if not r or (r[1] == r[2] and r[2] == r[3] and r[3] == r[4]) then
				local rad = if r then math.max(0, math.min((r[1] or 0) + out, math.max(0, math.min(w, h) / 2))) else 0
				return ui.path():rect(x, y, math.max(0, w), math.max(0, h), rad)
			end
		elseif sh.k == "ellipse" and (sh.sweep or 360) >= 360 and (sh.inner or 0) <= 0 then
			return ui.path():ellipse(x, y, math.max(0, w), math.max(0, h))
		end
	end
	local cmds = outline_cmds(it, out)
	if not cmds then
		return nil
	end
	return path_of(cmds, m)
end
M.shape_path = shape_path

-- Paints --------------------------------------------------------------------------------

local function even_colors(stops: { any }, op: number): { string }
	local n = #stops
	local even = true
	for i, s in stops do
		local want = if n > 1 then (i - 1) / (n - 1) else 0
		if math.abs((s.pos or want) - want) > 0.01 then
			even = false
			break
		end
	end
	local out: { string } = {}
	if even then
		for _, s in stops do
			table.insert(out, fade(s.color, op))
		end
		return out
	end
	local sorted = table.clone(stops)
	table.sort(sorted, function(a: any, b: any): boolean
		return (a.pos or 0) < (b.pos or 0)
	end)
	for k = 0, 8 do
		local t = k / 8
		local c = sorted[1].color
		if t >= (sorted[#sorted].pos or 1) then
			c = sorted[#sorted].color
		else
			for j = 1, #sorted - 1 do
				local a, b = sorted[j], sorted[j + 1]
				if t >= (a.pos or 0) and t <= (b.pos or 1) then
					local span = (b.pos or 1) - (a.pos or 0)
					c = mix(a.color, b.color, if span > 0 then (t - (a.pos or 0)) / span else 0)
					break
				end
			end
		end
		table.insert(out, fade(c, op))
	end
	return out
end

-- Turned by `deg` (the file's sense) about (ox, oy), in a node's own space.
local function Draw_rotation_about(deg: number, ox: number, oy: number): Affine
	return rotation(deg, ox, oy)
end

-- A paint as zgx takes it: a colour, or a brush over the item's box.
local function brush(p: any, it: any, m: Affine, op: number): Paint?
	local o = op * (p.op or 1)
	if p.k == "solid" then
		return fade(p.color, o)
	end
	if p.k == "linear" or p.k == "radial" or p.k == "angular" then
		local stops = p.stops or {}
		if #stops == 0 then
			return nil
		end
		if #stops == 1 then
			return fade(stops[1].color, o)
		end
		local w, h = it.box.w, it.box.h
		local c = p.center or {}
		local cx, cy = c.x or 0.5, c.y or 0.5
		local len = (p.size and (p.size.h or p.size.height)) or 1
		local r = math.rad(p.rot or 0)
		local dx, dy = -math.sin(r), -math.cos(r)
		local matrix = { m.a, m.b, m.c, m.d, m.e, m.f }
		local api: any = ui
		-- (Native's: a radial one fills the ellipse `size` across, centred at
		-- `center`; an angular one starts at the top and sweeps clockwise,
		-- both turned counter-clockwise by `rotation`.)
		if p.k == "radial" and api.radial then
			local sw = (p.size and (p.size.w or p.size.width)) or 1
			local sh = (p.size and (p.size.h or p.size.height)) or 1
			local rx, ry = math.max(0.01, sw * w / 2), math.max(0.01, sh * h / 2)
			local turn = Draw_rotation_about(p.rot or 0, cx * w, cy * h)
			local t = compose(m, turn)
			return api.radial(cx * w, cy * h, rx, even_colors(stops, o), { ry = ry, transform = { t.a, t.b, t.c, t.d, t.e, t.f } })
		elseif p.k == "angular" and api.conic then
			return api.conic(cx * w, cy * h, even_colors(stops, o), { angle = -90 - (p.rot or 0), transform = matrix })
		end
		if p.k ~= "linear" then
			dx, dy, len = 0, 1, 1
		end
		local x1, y1 = apply(m, (cx - dx * len / 2) * w, (cy - dy * len / 2) * h)
		local x2, y2 = apply(m, (cx + dx * len / 2) * w, (cy + dy * len / 2) * h)
		return ui.linear(x1, y1, x2, y2, even_colors(stops, o))
	end
	return nil
end

local function first_color(paints: { any }?, op: number): string?
	if not paints then
		return nil
	end
	for _, p in paints do
		if p.k == "solid" then
			return fade(p.color, op * (p.op or 1))
		elseif p.stops and p.stops[1] then
			return fade(p.stops[1].color, op * (p.op or 1))
		end
	end
	return nil
end

-- One item ---------------------------------------------------------------------------

-- The upright box of the item's corners on the Canvas.
local function canvas_bounds(it: any, m: Affine): (number, number, number, number)
	local w, h = it.box.w, it.box.h
	local x0, y0 = math.huge, math.huge
	local x1, y1 = -math.huge, -math.huge
	for _, p in { { 0, 0 }, { w, 0 }, { w, h }, { 0, h } } do
		local x, y = apply(m, p[1], p[2])
		x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
	end
	return x0, y0, x1 - x0, y1 - y0
end
M.canvas_bounds = canvas_bounds

local function draw_shadows(c: Canvas, it: any, m: Affine, op: number)
	for _, e in it.fx do
		if e.k == "shadow" and not e.inner then
			local path = shape_path(it, m, 0)
			if path then
				c:shadow(path, { x = e.x or 0, y = e.y or 0, blur = e.blur or 0, spread = e.spread or 0, color = fade(e.color or "#00000040", op) })
			end
		end
	end
end

-- `skip_gif`: GIF paints left out (Play shows them as live elements);
-- `past_gif`: only the paints after the first GIF one (what's over it).
local function draw_fill(c: Canvas, it: any, m: Affine, op: number, skip_gif: boolean?, past_gif: boolean?)
	local path: Path? = nil
	local seen_gif = false
	for _, p in it.fill do
		if p.gif and (skip_gif or past_gif) then
			seen_gif = true
			continue
		end
		if past_gif and not seen_gif then
			continue
		end
		if p.k == "image" then
			local x, y, w, h = canvas_bounds(it, m)
			local src = p.src or ""
			local radius = if it.shape and it.shape.k == "rect" and it.shape.r then it.shape.r[1] or 0 else 0
			local fit = if p.mode == "contain" then "contain" elseif p.mode == "stretch" then "fill" else "cover"
			-- (`img:<key>`: a picture kept in zeron.db, decoded once into a
			-- Bitmap (M.images); until then a placeholder, and asked for.)
			local bitmap = nil
			if string.sub(src, 1, 4) == "img:" then
				local key = string.sub(src, 5)
				bitmap = M.images[key]
				if bitmap == nil then
					M.want(key)
				end
			end
			if bitmap and bitmap ~= false then
				local ok, err = pcall(c.image, c, bitmap, x, y, w, h, { fit = fit :: any, radius = radius, opacity = op * (p.op or 1) })
				if not ok and M.on_error then
					M.on_error(`image {src}: {err}`)
				end
			elseif string.sub(src, 1, 8) == "missing:" or string.sub(src, 1, 4) == "img:" or src == ""
				-- (a web url the service hasn't stored yet: the canvas can't
				-- fetch it, and `c:image(url)` would draw nothing at all)
				or string.match(string.lower(src), "^https?://") then
				c:rect(x, y, w, h, fade("#8080801f", op), radius)
				c:line(x, y, x + w, y + h, fade("#80808066", op), 1)
				c:line(x + w, y, x, y + h, fade("#80808066", op), 1)
			else
				-- (A source the host can't fetch is a warning, not a broken Screen.)
				pcall(c.image, c, src, x, y, w, h, { fit = fit :: any, radius = radius, opacity = op * (p.op or 1) })
			end
		else
			local b = brush(p, it, m, op)
			if b then
				path = path or shape_path(it, m, 0)
				if path then
					c:fill(path, b, if it.shape and it.shape.rule == "evenodd" then "evenodd" else nil)
				end
			end
		end
	end
end

local function draw_stroke(c: Canvas, it: any, m: Affine, op: number)
	local s = it.stroke
	local w = s.w or { 1, 1, 1, 1 }
	local paint: Paint? = nil
	for _, p in s.fill or {} do
		paint = brush(p, it, m, op)
		if paint then
			break
		end
	end
	if not paint then
		return
	end
	local t, r, b, l = w[1] or 0, w[2] or 0, w[3] or 0, w[4] or 0
	local same = t == r and r == b and b == l
	local opts: StrokeOptions? = nil
	if s.join or s.cap or s.dash then
		opts = { join = s.join, cap = s.cap, dash = s.dash }
	end
	if same then
		if t <= 0 then
			return
		end
		local grow = if s.align == "inside" then -t / 2 elseif s.align == "outside" then t / 2 else 0
		local path = shape_path(it, m, grow)
		if path then
			c:stroke(path, paint, t, opts)
		end
		return
	end
	-- Sides of their own widths (a border on one side): each side a line,
	-- inside the box.
	local bw, bh = it.box.w, it.box.h
	local function side(x1: number, y1: number, x2: number, y2: number, width: number)
		if width <= 0 then
			return
		end
		local ax, ay = apply(m, x1, y1)
		local bx, by = apply(m, x2, y2)
		c:line(ax, ay, bx, by, paint :: Paint, width, { cap = "butt" })
	end
	side(0, t / 2, bw, t / 2, t)
	side(bw - r / 2, 0, bw - r / 2, bh, r)
	side(0, bh - b / 2, bw, bh - b / 2, b)
	side(l / 2, 0, l / 2, bh, l)
end

local function draw_text(c: Canvas, it: any, m: Affine, op: number, clip: { number }?)
	local t = it.text
	if not t or (t.s or "") == "" then
		return
	end
	local color = first_color(it.fill, op) or fade("#000000ff", op)
	local box = it.box
	-- Wholly outside the clip around it: left out (zgx's clip doesn't cut text).
	if clip then
		local x, y, w, h = canvas_bounds(it, m)
		if x >= clip[1] + clip[3] or y >= clip[2] + clip[4] or x + w <= clip[1] or y + h <= clip[2] then
			return
		end
	end
	local align = t.align or "left"
	local lx = 0
	local za: "start" | "center" | "end" = "start"
	if align == "center" then
		lx, za = box.w / 2, "center"
	elseif align == "right" then
		lx, za = box.w, "end"
	end
	local th = t.th or box.h
	local ly = 0
	if t.valign == "middle" then
		ly = (box.h - th) / 2
	elseif t.valign == "bottom" then
		ly = box.h - th
	end
	local turned = not (math.abs(m.b) < 1e-9 and math.abs(m.c) < 1e-9 and math.abs(m.a - 1) < 1e-9 and math.abs(m.d - 1) < 1e-9)
	local x, y = apply(m, lx, ly)
	local transform: { number }? = nil
	if turned then
		x, y = lx, ly
		transform = { m.a, m.b, m.c, m.d, m.e, m.f }
	end
	c:text(t.s, x, y, {
		transform = transform,
		font = t.font,
		size = t.size or 14,
		weight = t.weight,
		italic = t.italic,
		color = color,
		line_height = t.lh,
		letter_spacing = if t.ls and t.ls ~= 0 then t.ls else nil,
		width = t.wrap,
		align = za,
		baseline = "top",
	})
end

local function draw_icon(c: Canvas, it: any, m: Affine, op: number)
	local ic = it.icon
	local w, h = it.box.w, it.box.h
	local color = fade(ic.color or "#000000ff", op)
	if not ic.parts or #ic.parts == 0 then
		if ic.d then
			ic.parts = { { d = ic.d } }
		else
			local x, y, bw, bh = canvas_bounds(it, m)
			c:rect(x + bw * 0.15, y + bh * 0.15, bw * 0.7, bh * 0.7, fade(color, 0.25), math.min(bw, bh) * 0.15)
			return
		end
	end
	local f = compose(m, fit_vb(ic.vb or { x = 0, y = 0, w = 24, h = 24 }, w, h, false))
	local scale = math.sqrt(math.abs(f.a * f.d - f.b * f.c))
	for _, part in ic.parts do
		local path = path_of(parse_svg(part.d or ""), f)
		local pc = if part.op then fade(color, part.op) else color
		if not part.nofill then
			c:fill(path, pc, if part.rule == "evenodd" then "evenodd" else nil)
		end
		if part.sw then
			c:stroke(path, pc, part.sw * scale, { cap = part.cap or "round", join = part.join or "round" })
		end
	end
end

-- A root ------------------------------------------------------------------------------------

-- `live`: what a drag shows before the service answers: `maps[id]` an
-- affine applied (on the Canvas) to that node and all inside it; `boxes[id]`
-- a new box size for that node alone; `texts[id]` its words as typed;
-- `hide[id]` left out (with what's inside); `paints[id]` its `fill`,
-- `stroke` or `icon` as a colour picker's knob moves (live_paint.luau).
-- (GIF layers, tab/gif.luau) `gifs[id]`: that node's GIF paints left out
-- (Play plays them as elements over the canvas); `after = i`: only what
-- paints over item i's GIF: its later paints, what's inside it, its stroke,
-- what comes after it, and the strokes of what holds it.
export type Live = { maps: { [string]: Affine }?, boxes: { [string]: { w: number, h: number } }?, texts: { [string]: string }?, hide: { [string]: boolean }?, paints: { [string]: any }?, gifs: { [string]: boolean }?, after: number? }

-- Whether a frame's stroke can go down before its children, the pixels the
-- same: no descendant reaches into the band its stroke covers (a margin of
-- its widest side inside the box), none turned, none with effects (shadows
-- spread). zgx keeps a canvas's text in its order in at most 8 layers, and a
-- stroke drawn after its children's texts starts one: a screen of stroked
-- cards ran out, and the texts left went over everything after them (P4: a
-- scrim and a dialog). Drawn early, the stroke needs no layer.
local function stroke_clear(nodes: { any }, i: number, it: any): boolean
	if it.xf then
		return false
	end
	local w = it.stroke.w or { 1, 1, 1, 1 }
	local m = math.max(w[1] or 0, w[2] or 0, w[3] or 0, w[4] or 0)
	local b = it.box
	local x0, y0, x1, y1 = b.x + m, b.y + m, b.x + b.w - m, b.y + b.h - m
	for j = i + 1, i + (it.n or 0) do
		local d = nodes[j]
		local db = d.box
		if d.xf or d.fx or not db or db.x < x0 or db.y < y0 or db.x + db.w > x1 or db.y + db.h > y1 then
			return false
		end
	end
	return true
end

function M.draw_root(c: Canvas, root: any, live_of: any?)
	local nodes = root.nodes
	if not nodes then
		return
	end
	local live: Live? = if live_of ~= nil then live_of else root.live
	if live and (live :: any).v ~= nil and (live :: any).v ~= root.v then
		live = nil
	end
	local maps = live and live.maps
	local sizes = live and live.boxes
	local texts = live and live.texts
	local hide = live and live.hide
	local paints = live and live.paints
	-- (`live` can be `false`: nil then, never `false`)
	local gifs: { [string]: boolean }? = if live then live.gifs else nil
	local after: number? = if live and type(live.after) == "number" then live.after else nil
	-- (only a paint shown live: nothing moves, the strokes go down as ever;
	-- over a GIF every stroke goes last, over what it holds)
	local still = live == nil or (maps == nil and sizes == nil and texts == nil and hide == nil and after == nil)
	-- Open items: what each closes after its descendants (clip, stroke, its
	-- opacity and map for them).
	local stack: { { last: number, it: any, m: Affine, op: number, clip: boolean, map: Affine?, cbox: { number }?, stroked: boolean? } } = {}
	local op = root.op0 or 1
	local carried: Affine? = nil -- the map a live drag gives this branch
	local cbox: { number }? = nil -- the clip around, as an upright box
	local skip_to = 0
	local count = #nodes
	local i = 1
	while i <= count do
		local it = nodes[i]
		if i <= skip_to then
			-- (Inside what's left out.)
		elseif (hide and hide[it.id]) or it.hidden or (after and i < after and i + (it.n or 0) < after) then
			skip_to = i + (it.n or 0)
			-- (Close what ends here, below.)
		else
			-- (over a GIF: what holds it opens (its clip, its stroke later),
			-- paints nothing under it)
			local under = after ~= nil and i < after
			local own = maps and maps[it.id]
			local map = if own then (if carried then compose(own, carried) else own) else carried
			local m = M.local_map(it)
			if map then
				m = compose(map, m)
			end
			local size = sizes and sizes[it.id]
			if size then
				it = table.clone(it)
				it.box = { x = it.box.x, y = it.box.y, w = size.w, h = size.h }
				if it.text and it.text.wrap then
					it.text = table.clone(it.text)
					it.text.wrap = size.w
				end
			end
			local words = texts and texts[it.id]
			if words then
				it = table.clone(it)
				it.text = table.clone(it.text)
				it.text.s = words
			end
			local look = paints and paints[it.id]
			if look then
				it = table.clone(it)
				if look.fill then
					it.fill = look.fill
				end
				if look.stroke then
					it.stroke = look.stroke
				end
				if look.icon then
					it.icon = look.icon
				end
			end
			local my_op = op * (it.op or 1)
			local own_gif = after ~= nil and i == after
			if under then
				-- (nothing of its own)
			elseif own_gif then
				if it.fill then
					draw_fill(c, it, m, my_op, true, true)
				end
			else
				if it.fx then
					draw_shadows(c, it, m, my_op)
				end
				if it.fill and it.t ~= "text" then
					draw_fill(c, it, m, my_op, gifs ~= nil and gifs[it.id] == true)
				end
				if it.t == "text" then
					draw_text(c, it, m, my_op, cbox)
				elseif it.icon then
					draw_icon(c, it, m, my_op)
				end
			end
			local n = it.n or 0
			-- (a live drag moves boxes: then the stroke goes after, as ever)
			local early = n > 0 and it.stroke ~= nil and still and stroke_clear(nodes, i, it)
			if early then
				draw_stroke(c, it, m, my_op)
			end
			if n > 0 then
				local clipping = false
				local was_cbox = cbox
				if it.clip then
					local path = shape_path(it, m, 0)
					if path then
						c:clip(path)
						clipping = true
						local x, y, w, h = canvas_bounds(it, m)
						if cbox then
							local x1 = math.max(x, cbox[1])
							local y1 = math.max(y, cbox[2])
							local x2 = math.min(x + w, cbox[1] + cbox[3])
							local y2 = math.min(y + h, cbox[2] + cbox[4])
							cbox = { x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1) }
						else
							cbox = { x, y, w, h }
						end
					end
				end
				table.insert(stack, { last = i + n, it = it, m = m, op = op, clip = clipping, map = carried, cbox = was_cbox, stroked = early })
				op = my_op
				carried = map
			elseif it.stroke then
				draw_stroke(c, it, m, my_op)
			end
		end
		-- Close every item whose descendants end here.
		while #stack > 0 and stack[#stack].last <= i do
			local top = table.remove(stack) :: any
			if top.clip then
				c:restore()
			end
			op = top.op
			carried = top.map
			cbox = top.cbox
			if top.it.stroke and not top.stroked then
				draw_stroke(c, top.it, top.m, op * (top.it.op or 1))
			end
		end
		i += 1
	end
	while #stack > 0 do
		local top = table.remove(stack) :: any
		if top.clip then
			c:restore()
		end
		if top.it.stroke and not top.stroked then
			draw_stroke(c, top.it, top.m, top.op * (top.it.op or 1))
		end
	end
end

return M
