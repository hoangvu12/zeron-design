--!strict
-- Device frames, drawn (step 6, pure/anim/f6/PLAN.md §1 and E1): the shapes
-- of a clean device around a Screen, for Play (a canvas) and the HTML export
-- (SVG). Pure: no requires. tab/device_frame.luau is a byte-for-byte copy
-- (the tab can't require ../engine); tests/device_frame.luau checks it.
--
-- M.shapes(kind, w, h, rotate, model) → {
--   kind, w, h,                -- the screen as played (already rotated)
--   body = { shape },          -- drawn under the screen
--   over = { shape },          -- drawn over it (corner mask, island, hole)
--   inset = { l, t, r, b },    -- how far the frame reaches past the screen
--   radius, radii,             -- the screen's corner radius (max) and per corner
--   color,                     -- the model's body colour
-- }
-- Shapes are in points, relative to the screen's top-left (draw them in
-- list order):
--   { kind = "poly", pts = { x1, y1, x2, y2, … }, bg = true }
--        painted in the page's background, not a colour: the bits of the
--        screen's square box past the body's rounded outline
--   { kind = "rect", x, y, w, h, r = n | { tl, tr, br, bl }, fill }
--   { kind = "circle", x, y, r, fill }            (x, y = centre)
--   { kind = "corners", x, y, w, h, r, o, ro, fill }
--        a ring: the rect (x, y, w, h) grown by o with radii ro, minus the
--        rect itself with radii r. It hides the screen's square corners
--        and stays inside the bezel. (r, ro = n | { tl, tr, br, bl })
-- `rotate` = landscape: the portrait device turned a quarter to the left
-- (its top on the left edge, as Figma).

local M = {}

M.KINDS = { "phone-island", "phone-notch", "phone-home", "android", "tablet", "laptop", "desktop", "tv", "watch" }

-- Model colours per frame kind (name → "#RRGGBB"). A preset lists the
-- names it offers (engine/proto.luau DEVICES[...].models, first = default).
M.MODELS = {
	["phone-island"] = {
		-- iPhone 16
		White = "#F5F5F0", Pink = "#F2C7D3", Teal = "#A6C9C2", Ultramarine = "#7C8EE0", Black = "#3C3C3E",
		-- iPhone 16 Pro / Pro Max
		["Black Titanium"] = "#3B3B3D", ["White Titanium"] = "#F2F1ED", ["Natural Titanium"] = "#C2BCB2", ["Desert Titanium"] = "#C4AB94",
		-- iPhone 17
		Lavender = "#CDBEE0", ["Mist Blue"] = "#A9BCD6", Sage = "#B7C2A5",
		-- iPhone 17 Pro / Pro Max
		["Cosmic Orange"] = "#F07A35", ["Deep Blue"] = "#2F3A4F", Silver = "#E3E4E5",
		-- iPhone Air
		["Space Black"] = "#2B2B2D", ["Cloud White"] = "#F3F3EF", ["Light Gold"] = "#EBD9B8", ["Sky Blue"] = "#CFE2F0",
	},
	["phone-notch"] = { Midnight = "#232A31", Starlight = "#F2EDE4", Blue = "#374A5E", Purple = "#B9B0CC" },
	["phone-home"] = { Midnight = "#1F2228", Starlight = "#F2EDE4", Red = "#C8102E" },
	android = { Obsidian = "#2B2B2E", Porcelain = "#EDE8E1", Hazel = "#8F9488", Rose = "#F2C9C6" },
	tablet = {
		["Space Gray"] = "#5E5F62", Silver = "#E3E4E6", Starlight = "#E8E1D5", Purple = "#CBC3E3", Blue = "#A6C0DB",
		Platinum = "#D9D9D6", Graphite = "#3F4043",
	},
	laptop = { ["Space Gray"] = "#7D7E80", Silver = "#E3E4E5", Starlight = "#E6DFD3", Midnight = "#2E3642", ["Space Black"] = "#2E2E30" },
	desktop = { Silver = "#E3E4E5", Black = "#2B2B2D" },
	tv = { Black = "#1C1C1E" },
	watch = { Midnight = "#2D3038", Starlight = "#E6DED1", Silver = "#E1E2E3", Red = "#C8102E" },
}
-- Each kind's default model.
M.DEFAULT = {
	["phone-island"] = "Black", ["phone-notch"] = "Midnight", ["phone-home"] = "Midnight", android = "Obsidian",
	tablet = "Space Gray", laptop = "Space Gray", desktop = "Silver", tv = "Black", watch = "Midnight",
}

local BEZEL = "#0B0B0C"
local BLACK = "#000000"

-- A colour mixed toward black (k > 0) or white (k < 0).
local function shade(hex: string, k: number): string
	local r, g, b = tonumber(string.sub(hex, 2, 3), 16) or 0, tonumber(string.sub(hex, 4, 5), 16) or 0, tonumber(string.sub(hex, 6, 7), 16) or 0
	local function f(c: number): number
		if k >= 0 then
			return math.floor(c * (1 - k) + 0.5)
		end
		return math.floor(c + (255 - c) * -k + 0.5)
	end
	return string.format("#%02X%02X%02X", f(r), f(g), f(b))
end
M.shade = shade

-- The body colour for a kind and a model (a name, or "#RRGGBB" as is).
function M.color(kind: string, model: any): string
	local t = M.MODELS[kind]
	if type(model) == "string" and string.match(model, "^#%x%x%x%x%x%x$") then
		return string.upper(model)
	end
	if t and type(model) == "string" and t[model] then
		return t[model]
	end
	return if t then t[M.DEFAULT[kind]] else "#3C3C3E"
end

local function rect(x: number, y: number, w: number, h: number, r: any, fill: string): any
	return { kind = "rect", x = x, y = y, w = w, h = h, r = r, fill = fill }
end
local function circle(x: number, y: number, r: number, fill: string): any
	return { kind = "circle", x = x, y = y, r = r, fill = fill }
end
-- The screen's corner mask: a ring `o` wide around the w × h screen, its
-- hole rounded by `r` and its outside by r + o (so it stays inside the
-- bezel and never shows past a rounded body).
local function corners(w: number, h: number, r: any, o: number, fill: string): any
	local ro
	if type(r) == "table" then
		ro = {}
		for i, v in r do
			ro[i] = if v > 0 then v + o else 0
		end
	else
		ro = if r > 0 then r + o else 0
	end
	return { kind = "corners", x = 0, y = 0, w = w, h = h, r = r, o = o, ro = ro, fill = fill }
end

-- The bits of the screen's square box that stick out past the body's
-- rounded outline (outset o, corner radius sr + o): a body corner radius
-- over ~3.4 × its outset leaves the box's corner outside. Each is a
-- polygon `bg = true` painted in the page's background (Play's stage, the
-- export's body), as the screen's content may run into its corners.
local CUT_STEPS = 12
local function cuts(out: { any }, w: number, h: number, sr: number, o: number)
	local R = sr + o
	local d = R - o -- the circle's centre, from the box corner, on each axis
	if math.sqrt(2) * d <= R + 0.01 then
		return
	end
	local e = math.sqrt(R * R - d * d) -- where the circle meets the box's edges
	-- per corner: the box corner, the centre, and the unit directions toward the box's inside
	for _, c in { { 0, 0, 1, 1 }, { w, 0, -1, 1 }, { w, h, -1, -1 }, { 0, h, 1, -1 } } do
		local x0, y0, sx, sy = c[1], c[2], c[3], c[4]
		local cx, cy = x0 + sx * d, y0 + sy * d
		local pts = { x0, y0 }
		-- along the circle from the edge y = y0 to the edge x = x0
		local a1 = math.atan2(y0 - cy, (x0 + sx * (d - e)) - cx)
		local a2 = math.atan2((y0 + sy * (d - e)) - cy, x0 - cx)
		local da = a2 - a1
		if da > math.pi then
			da -= 2 * math.pi
		elseif da < -math.pi then
			da += 2 * math.pi
		end
		for i = 0, CUT_STEPS do
			local a = a1 + da * i / CUT_STEPS
			table.insert(pts, cx + R * math.cos(a))
			table.insert(pts, cy + R * math.sin(a))
		end
		table.insert(out, { kind = "poly", pts = pts, bg = true })
	end
end

-- A rounded body made of nested rings: { outset, radius, fill } from the
-- outside in, all around a w × h screen. `bottom` adds to the bottom
-- outset only (a chin).
local function rings(out: { any }, w: number, h: number, list: { any }, chin: number?)
	for _, g in list do
		local o, r = g[1], g[2]
		local b = o + (if g[4] == false then 0 else (chin or 0))
		table.insert(out, rect(-o, -o, w + 2 * o, h + o + b, r, g[3]))
	end
end

-- The rings again over the screen's corners (each as a ring round the
-- rounded screen hole, outside in), then the cuts: the screen's content
-- under its square corners is covered exactly as the frame looks.
local function face(over: { any }, w: number, h: number, sr: number, list: { any })
	for _, g in list do
		table.insert(over, corners(w, h, sr, g[1], g[3]))
	end
	cuts(over, w, h, sr, list[1][1])
end

-- The portrait shapes of each kind around a pw × ph screen.
local BUILD = {}

BUILD["phone-island"] = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local sr = math.floor(math.min(pw, ph) * 0.14 + 0.5) -- 393 → 55
	local bz, rim = 13, 5
	local o = bz + rim
	-- side buttons first: the body covers their inner part
	local btn = shade(c, 0.12)
	table.insert(body, rect(-o - 3, ph * 0.175, 5, 34, 2, btn)) -- action
	table.insert(body, rect(-o - 3, ph * 0.245, 5, 62, 2, btn)) -- volume up
	table.insert(body, rect(-o - 3, ph * 0.335, 5, 62, 2, btn)) -- volume down
	table.insert(body, rect(pw + o - 2, ph * 0.27, 5, 100, 2, btn)) -- side
	local R = { { o, sr + o, c }, { o - 1.5, sr + o - 1.5, shade(c, 0.18) }, { bz, sr + bz, BEZEL } }
	rings(body, pw, ph, R)
	face(over, pw, ph, sr, R)
	table.insert(over, rect(pw / 2 - 63, 11, 126, 37, 18.5, BLACK)) -- the Dynamic Island
	return { body = body, over = over, inset = { o + 3, o, o + 3, o }, radii = { sr, sr, sr, sr } }
end

BUILD["phone-notch"] = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local sr = math.floor(math.min(pw, ph) * 0.12 + 0.5)
	local bz, rim = 12, 5
	local o = bz + rim
	local btn = shade(c, 0.12)
	table.insert(body, rect(-o - 3, ph * 0.2, 5, 62, 2, btn))
	table.insert(body, rect(-o - 3, ph * 0.29, 5, 62, 2, btn))
	table.insert(body, rect(pw + o - 2, ph * 0.27, 5, 100, 2, btn))
	local R = { { o, sr + o, c }, { o - 1.5, sr + o - 1.5, shade(c, 0.18) }, { bz, sr + bz, BEZEL } }
	rings(body, pw, ph, R)
	face(over, pw, ph, sr, R)
	table.insert(over, rect(pw / 2 - 80, 0, 160, 32, { 0, 0, 20, 20 }, BEZEL)) -- the notch
	return { body = body, over = over, inset = { o + 3, o, o + 3, o }, radii = { sr, sr, sr, sr } }
end

BUILD["phone-home"] = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local side, cap = 22, 108
	local btn = shade(c, 0.12)
	table.insert(body, rect(-side - 3, 92, 5, 30, 2, btn))
	table.insert(body, rect(-side - 3, 150, 5, 56, 2, btn))
	table.insert(body, rect(-side - 3, 216, 5, 56, 2, btn))
	table.insert(body, rect(pw + side - 2, 150, 5, 70, 2, btn))
	table.insert(body, rect(-side, -cap, pw + 2 * side, ph + 2 * cap, 56, c))
	table.insert(body, rect(-side + 4, -cap + 4, pw + 2 * side - 8, ph + 2 * cap - 8, 52, BEZEL))
	table.insert(body, rect(pw / 2 - 28, -cap / 2 - 3, 56, 6, 3, "#2A2A2C")) -- speaker
	table.insert(body, circle(pw / 2 - 46, -cap / 2, 5, "#1E2430")) -- camera
	table.insert(body, circle(pw / 2, ph + cap / 2, 27, "#2A2A2C")) -- home button
	table.insert(body, circle(pw / 2, ph + cap / 2, 25, BEZEL))
	return { body = body, over = over, inset = { side + 3, cap, side + 3, cap }, radii = { 0, 0, 0, 0 } }
end

BUILD.android = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local sr = if math.min(pw, ph) >= 600 then 20 else math.floor(math.min(pw, ph) * 0.085 + 0.5)
	local bz, rim = 10, 4
	local o = bz + rim
	local btn = shade(c, 0.12)
	table.insert(body, rect(pw + o - 2, ph * 0.2, 5, 44, 2, btn)) -- power
	table.insert(body, rect(pw + o - 2, ph * 0.3, 5, 90, 2, btn)) -- volume
	local R = { { o, sr + o, c }, { bz, sr + bz, BEZEL } }
	rings(body, pw, ph, R)
	face(over, pw, ph, sr, R)
	table.insert(over, circle(pw / 2, 20, 7, BLACK)) -- the punch-hole camera
	return { body = body, over = over, inset = { o, o, o + 3, o }, radii = { sr, sr, sr, sr } }
end

BUILD.tablet = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local sr = 18
	local bz, rim = 22, 4
	local o = bz + rim
	local btn = shade(c, 0.12)
	table.insert(body, rect(pw - 90, -o - 3, 60, 5, 2, btn)) -- top button
	table.insert(body, rect(pw + o - 2, 70, 5, 50, 2, btn)) -- volume up
	table.insert(body, rect(pw + o - 2, 130, 5, 50, 2, btn)) -- volume down
	local R = { { o, sr + o, c }, { bz, sr + bz, BEZEL } }
	rings(body, pw, ph, R)
	table.insert(body, circle(pw / 2, -bz / 2, 3.5, "#1E2430")) -- camera, in the bezel
	face(over, pw, ph, sr, R)
	return { body = body, over = over, inset = { o, o + 3, o + 3, o }, radii = { sr, sr, sr, sr } }
end

BUILD.laptop = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local sr = 10
	local side, top, chin, rim = 14, 16, 28, 3
	-- the lid: an aluminium rim, then the black glass
	table.insert(body, rect(-side - rim, -top - rim, pw + 2 * (side + rim), ph + top + chin + 2 * rim, { 22, 22, 6, 6 }, shade(c, 0.1)))
	table.insert(body, rect(-side, -top, pw + 2 * side, ph + top + chin, { 19, 19, 4, 4 }, BEZEL))
	table.insert(body, circle(pw / 2, -top / 2, 3, "#1E2430")) -- camera
	-- the base: wider than the lid, with a thumb groove
	local by = ph + chin + rim
	local over_w = math.floor(pw * 0.08 + 0.5)
	table.insert(body, rect(-side - rim - over_w, by, pw + 2 * (side + rim + over_w), 16, { 2, 2, 12, 12 }, c))
	table.insert(body, rect(-side - rim - over_w, by + 12, pw + 2 * (side + rim + over_w), 4, { 0, 0, 12, 12 }, shade(c, 0.22)))
	table.insert(body, rect(pw / 2 - pw * 0.09, by, pw * 0.18, 6, { 0, 0, 6, 6 }, shade(c, 0.16)))
	table.insert(over, corners(pw, ph, { sr, sr, 0, 0 }, side, BEZEL))
	local l = side + rim + over_w
	return { body = body, over = over, inset = { l, top + rim, l, chin + rim + 16 }, radii = { sr, sr, 0, 0 } }
end

BUILD.desktop = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local bz, rim = 18, 4
	local o = bz + rim
	-- the stand under the monitor
	local neck_w = math.floor(math.min(pw * 0.14, 200) + 0.5)
	local foot_w = math.floor(neck_w * 1.8 + 0.5)
	local neck_h = math.floor(math.min(ph * 0.16, 170) + 0.5)
	table.insert(body, rect(pw / 2 - neck_w / 2, ph + o - 2, neck_w, neck_h + 2, 0, shade(c, 0.12)))
	table.insert(body, rect(pw / 2 - foot_w / 2, ph + o + neck_h, foot_w, 14, { 4, 4, 7, 7 }, c))
	rings(body, pw, ph, { { o, 16, c }, { bz, 13, BEZEL } })
	table.insert(body, circle(pw / 2, -bz / 2, 3, "#1E2430"))
	return { body = body, over = over, inset = { o, o, o, o + neck_h + 14 }, radii = { 0, 0, 0, 0 } }
end

BUILD.tv = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local bz = 10
	local leg = math.floor(math.min(ph * 0.06, 50) + 0.5)
	table.insert(body, rect(pw * 0.12, ph + bz - 2, 14, leg + 2, { 0, 0, 3, 3 }, shade(c, -0.15)))
	table.insert(body, rect(pw * 0.88 - 14, ph + bz - 2, 14, leg + 2, { 0, 0, 3, 3 }, shade(c, -0.15)))
	rings(body, pw, ph, { { bz, 6, c }, { 3, 3, BEZEL } })
	return { body = body, over = over, inset = { bz, bz, bz, bz + leg }, radii = { 0, 0, 0, 0 } }
end

BUILD.watch = function(pw: number, ph: number, c: string): any
	local body, over = {}, {}
	local sr = math.floor(math.min(pw, ph) * 0.22 + 0.5)
	local bz, rim = 11, 9
	local o = bz + rim
	local btn = shade(c, 0.12)
	table.insert(body, rect(pw + o - 4, ph * 0.24, 12, 40, 5, btn)) -- the crown
	table.insert(body, rect(pw + o - 3, ph * 0.52, 6, 52, 3, btn)) -- the side button
	local R = { { o, sr + o, c }, { o - 2, sr + o - 2, shade(c, 0.18) }, { bz, sr + bz, BEZEL } }
	rings(body, pw, ph, R)
	face(over, pw, ph, sr, R)
	return { body = body, over = over, inset = { o, o, o + 8, o }, radii = { sr, sr, sr, sr } }
end

-- ── rotation: a quarter turn to the left (top → left) ───────────────────
-- A portrait point (x, y) on a pw-wide screen → (y, pw - x).
local function turn_radii(r: any): any
	if type(r) ~= "table" then
		return r
	end
	-- portrait tl, tr, br, bl → landscape: tr becomes tl, br → tr, bl → br, tl → bl
	return { r[2], r[3], r[4], r[1] }
end

local function turn(s: any, pw: number): any
	local t = table.clone(s)
	if s.kind == "circle" then
		t.x, t.y = s.y, pw - s.x
	elseif s.kind == "poly" then
		local pts = {}
		for i = 1, #s.pts, 2 do
			pts[i], pts[i + 1] = s.pts[i + 1], pw - s.pts[i]
		end
		t.pts = pts
	else
		t.x, t.y, t.w, t.h = s.y, pw - (s.x + s.w), s.h, s.w
		t.r = turn_radii(s.r)
		if s.ro ~= nil then
			t.ro = turn_radii(s.ro)
		end
	end
	return t
end

-- The frame around a w × h screen (as played: already turned when
-- `rotate`), or nil for an unknown kind.
function M.shapes(kind: string, w: number, h: number, rotate: boolean?, model: any): any?
	local build = BUILD[kind]
	if not build or type(w) ~= "number" or type(h) ~= "number" then
		return nil
	end
	local c = M.color(kind, model)
	local pw, ph = w, h
	if rotate then
		pw, ph = h, w
	end
	local f = build(pw, ph, c)
	local radii = f.radii
	if rotate then
		local body, over = {}, {}
		for _, s in f.body do
			table.insert(body, turn(s, pw))
		end
		for _, s in f.over do
			table.insert(over, turn(s, pw))
		end
		local i = f.inset
		f.body, f.over = body, over
		-- portrait l, t, r, b → landscape: t goes left, r goes top, b right, l bottom
		f.inset = { i[2], i[3], i[4], i[1] }
		radii = turn_radii(radii)
	end
	return {
		kind = kind, w = w, h = h, body = f.body, over = f.over, inset = f.inset,
		radius = math.max(radii[1], radii[2], radii[3], radii[4]), radii = radii, color = c,
	}
end

-- The frame's whole box (screen + insets): x, y (negative), w, h.
function M.bounds(f: any): (number, number, number, number)
	local i = f.inset
	return -i[1], -i[2], f.w + i[1] + i[3], f.h + i[2] + i[4]
end

-- ── SVG (the HTML export) ─────────────────────────────────────────────────

local function n(v: number): string
	local s = string.format("%.2f", v)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return if s == "-0" then "0" else s
end

local function radii4(r: any, w: number, h: number): { number }
	local m = math.min(w, h) / 2
	if type(r) == "table" then
		return { math.min(r[1] or 0, m), math.min(r[2] or 0, m), math.min(r[3] or 0, m), math.min(r[4] or 0, m) }
	end
	local v = math.min(r or 0, m)
	return { v, v, v, v }
end

-- A rounded rect path (clockwise from the top-left).
local function rrect_path(x: number, y: number, w: number, h: number, r: any): string
	local tl, tr, br, bl = table.unpack(radii4(r, w, h))
	return `M{n(x + tl)} {n(y)}H{n(x + w - tr)}`
		.. (if tr > 0 then `A{n(tr)} {n(tr)} 0 0 1 {n(x + w)} {n(y + tr)}` else "")
		.. `V{n(y + h - br)}`
		.. (if br > 0 then `A{n(br)} {n(br)} 0 0 1 {n(x + w - br)} {n(y + h)}` else "")
		.. `H{n(x + bl)}`
		.. (if bl > 0 then `A{n(bl)} {n(bl)} 0 0 1 {n(x)} {n(y + h - bl)}` else "")
		.. `V{n(y + tl)}`
		.. (if tl > 0 then `A{n(tl)} {n(tl)} 0 0 1 {n(x + tl)} {n(y)}` else "")
		.. "Z"
end
M.rrect_path = rrect_path

local function svg_shape(s: any, bg_css: string?): string
	if s.kind == "circle" then
		return `<circle cx="{n(s.x)}" cy="{n(s.y)}" r="{n(s.r)}" fill="{s.fill}"/>`
	elseif s.kind == "corners" then
		local o = s.o or 0
		local outer = rrect_path(s.x - o, s.y - o, s.w + 2 * o, s.h + 2 * o, s.ro or 0)
		return `<path fill-rule="evenodd" d="{outer}{rrect_path(s.x, s.y, s.w, s.h, s.r)}" fill="{s.fill}"/>`
	elseif s.kind == "poly" then
		local d = {}
		for i = 1, #s.pts, 2 do
			table.insert(d, (if i == 1 then "M" else "L") .. n(s.pts[i]) .. " " .. n(s.pts[i + 1]))
		end
		local paint = if s.bg then `style="fill: {bg_css or "#18181b"}"` else `fill="{s.fill}"`
		return `<path d="{table.concat(d)}Z" {paint}/>`
	end
	local r = s.r
	if type(r) == "number" or r == nil then
		local v = math.min(r or 0, s.w / 2, s.h / 2)
		return `<rect x="{n(s.x)}" y="{n(s.y)}" width="{n(s.w)}" height="{n(s.h)}"` .. (if v > 0 then ` rx="{n(v)}"` else "") .. ` fill="{s.fill}"/>`
	end
	return `<path d="{rrect_path(s.x, s.y, s.w, s.h, r)}" fill="{s.fill}"/>`
end

-- Two SVGs for a frame: the body (under the screen) and the over layer
-- (corners and island, over it), each covering the frame's whole box, with
-- a viewBox in points from the frame's top-left. `cls` is the class
-- ("device-frame"), `bg` the CSS colour of the page behind the device (the
-- `bg = true` shapes; "#18181b").
function M.svg(f: any, cls: string?, bg: string?): (string, string)
	local x, y, w, h = M.bounds(f)
	local function one(list: { any }, name: string): string
		local parts = {}
		for _, s in list do
			table.insert(parts, svg_shape(s, bg))
		end
		return `<svg class="{cls or "device-frame"} {name}" xmlns="http://www.w3.org/2000/svg" viewBox="{n(x)} {n(y)} {n(w)} {n(h)}" width="{n(w)}" height="{n(h)}" aria-hidden="true" focusable="false">`
			.. table.concat(parts)
			.. "</svg>"
	end
	return one(f.body, "body"), one(f.over, "over")
end

return M
