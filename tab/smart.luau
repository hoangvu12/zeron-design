--!strict
-- Smart Animate (figma-parity.md §3.1, step 3), the pure part Play, the
-- engine's Simulate and lint share: which layers of two Screens match, and
-- the plan that animates them. No state, no ui.
--
-- Matching (Figma's rule): a layer pairs with the layer that has the same
-- name path from its Screen ("Card/Header/Title"). When siblings share a
-- name, the n-th of that name pairs with the n-th. A node's `match` key
-- (scene `mt`) overrides the path ("@hero" pairs with "@hero" anywhere);
-- `match = false` never pairs. The Screens' own roots aren't paired: they
-- are the bases.
--
-- The plan, M0's rule (never animate by rewriting a Screen's canvas):
--   movers  the fewest pieces that carry the motion, each drawn once into
--           its own small element and moved, scaled and faded:
--     group   a pair whose whole subtree only moved, scaled evenly or faded
--             (drawn at its end look and size: exact at the end, soft
--             above ~1.1× before it);
--     redraw  a pair whose own box, colour, radius, stroke or shadow
--             changed (a plate): its own paint, redrawn each frame at the
--             tweened look (small: ≤ MAX_REDRAW of them);
--     xfade   a pair whose look can't tween (new words, another icon or
--             shape): its two looks crossfade while the box tweens;
--     fade    a layer with no pair inside a parent that moves: it fades in
--             (or out) where it is in that parent, following it.
--   bases   each Screen drawn once with its movers left out (hidden, or a
--           plate's own paint stripped). They dissolve, which is Figma's
--           rule for the layers that don't match. A pair that didn't change
--           at all needs no mover: it's the same in both bases.
-- Rects are in viewport units (Canvas units from the viewport's top-left,
-- scroll included): `opts.so(i)` / `opts.sd(i)` give an item's offset.

local M = {}

M.MAX_MOVERS = 40
M.MAX_REDRAW = 8

-- ── matching ──────────────────────────────────────────────────────────────

-- Each item's match key (nil: never matches). Items: scene items (`id`,
-- `p`, `name`, `mt`) in paint order, the Screen first.
function M.keys(nodes: { any }): { [number]: string }
	local out: { [number]: string } = {}
	local at: { [string]: number } = {}
	local path: { [number]: string } = {}
	local seen: { [string]: number } = {} -- parent path + name → count
	for i, it in nodes do
		at[it.id] = i
		if i == 1 then
			path[i] = ""
			continue
		end
		local pi = it.p and at[it.p]
		local pp = if pi then path[pi] else ""
		local name = tostring(it.name or it.t or "?")
		local k = pp .. "\0" .. name
		local n = (seen[k] or 0) + 1
		seen[k] = n
		local own = if pp == "" then name else pp .. "/" .. name
		if n > 1 then
			own ..= "#" .. tostring(n)
		end
		path[i] = own
		if type(it.mt) == "string" then
			out[i] = "@" .. it.mt
		elseif it.mt ~= false then
			out[i] = own
		end
	end
	return out
end

-- The pairs: { d2s = { [dst i] = src i }, s2d, count }.
function M.match(src: { any }, dst: { any }): any
	local ks, kd = M.keys(src), M.keys(dst)
	local by: { [string]: number } = {}
	for i, k in ks do
		if by[k] == nil then
			by[k] = i
		end
	end
	local d2s: { [number]: number } = {}
	local s2d: { [number]: number } = {}
	local count = 0
	for i = 2, #dst do
		local k = kd[i]
		local s = k and by[k]
		if s and not s2d[s] then
			d2s[i] = s
			s2d[s] = i
			count += 1
		end
	end
	return { d2s = d2s, s2d = s2d, count = count, ks = ks, kd = kd }
end

-- ── comparing looks ───────────────────────────────────────────────────────

local function eq(a: any, b: any, depth: number?): boolean
	if a == b then
		return true
	end
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return false
	end
	if ta == "number" then
		return math.abs(a - b) < 1e-3
	end
	if ta ~= "table" or (depth or 0) > 8 then
		return false
	end
	for k, v in a do
		if not eq(v, b[k], (depth or 0) + 1) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
M.eq = eq

local TEXT_KEYS = { "s", "font", "size", "weight", "italic", "lh", "ls", "align", "valign", "under", "strike" }
local function text_eq(a: any, b: any): boolean
	if a == nil or b == nil then
		return a == b
	end
	for _, k in TEXT_KEYS do
		if not eq(a[k], b[k]) then
			return false
		end
	end
	return true
end

-- Same paint, outline, effects, words and icon (not the box, opacity or
-- rotation).
local function look_eq(a: any, b: any): boolean
	if a.t ~= b.t then
		return false
	end
	if not eq(a.fill, b.fill) or not eq(a.stroke, b.stroke) or not eq(a.fx, b.fx) or not eq(a.shape, b.shape) then
		return false
	end
	if not text_eq(a.text, b.text) then
		return false
	end
	if a.icon or b.icon then
		if not a.icon or not b.icon or a.icon.name ~= b.icon.name or a.icon.color ~= b.icon.color then
			return false
		end
	end
	return (a.clip == true) == (b.clip == true)
end
M.look_eq = look_eq

local function has_paint(it: any): boolean
	return it.fill ~= nil or it.stroke ~= nil or it.fx ~= nil or it.text ~= nil or it.icon ~= nil
end

-- ── interpolation ─────────────────────────────────────────────────────────

local function hx(s: string, i: number): number
	return tonumber(string.sub(s, i, i + 1), 16) or 0
end
local function rgba(c: any): (number, number, number, number)
	if type(c) ~= "string" or #c < 7 then
		return 0, 0, 0, 0
	end
	return hx(c, 2), hx(c, 4), hx(c, 6), if #c >= 9 then hx(c, 8) else 255
end
local function lerp(a: number, b: number, p: number): number
	return a + (b - a) * p
end
function M.mix(c1: any, c2: any, p: number): string
	local r1, g1, b1, a1 = rgba(c1)
	local r2, g2, b2, a2 = rgba(c2)
	local q = math.clamp(p, 0, 1)
	local function ch(x: number, y: number): number
		return math.clamp(math.floor(lerp(x, y, q) + 0.5), 0, 255)
	end
	return string.format("#%02X%02X%02X%02X", ch(r1, r2), ch(g1, g2), ch(b1, b2), ch(a1, a2))
end
local function clear(c: any): string
	local r, g, b = rgba(c)
	return string.format("#%02X%02X%02X00", r, g, b)
end

-- Numbers lerp, colours mix, the rest is b's (tables walk together).
local function blend(a: any, b: any, p: number, key: string?): any
	if type(a) == "number" and type(b) == "number" then
		return lerp(a, b, p)
	end
	if type(a) == "string" and type(b) == "string" and string.sub(a, 1, 1) == "#" and string.sub(b, 1, 1) == "#" and (key == "color" or key == nil) then
		return M.mix(a, b, p)
	end
	if type(a) == "table" and type(b) == "table" then
		local out = {}
		for k, v in b do
			out[k] = blend(a[k], v, p, if type(k) == "string" then k else key)
		end
		return out
	end
	return b
end

-- Can two lists of paints / effects tween? (the same kinds, one for one;
-- a missing one tweens from clear)
local function same_shape(a: any, b: any): boolean
	if a == nil or b == nil then
		return true
	end
	if #a ~= #b then
		return false
	end
	for k = 1, #a do
		local x, y = a[k], b[k]
		if x.k ~= y.k then
			return false
		end
		if x.k == "image" and x.src ~= y.src then
			return false
		end
		if x.stops and y.stops and #x.stops ~= #y.stops then
			return false
		end
		if x.k == "shadow" and x.inner ~= y.inner then
			return false
		end
	end
	return true
end
local function faded(list: any): any
	local out = {}
	for k, x in list do
		local c = table.clone(x)
		if c.color then
			c.color = clear(c.color)
		end
		if c.stops then
			local st = {}
			for j, s in c.stops do
				st[j] = { color = clear(s.color), pos = s.pos }
			end
			c.stops = st
		end
		if c.k == "image" then
			c.op = 0
		end
		out[k] = c
	end
	return out
end
local function blend_list(a: any, b: any, p: number): any
	if a == nil and b == nil then
		return nil
	end
	if a == nil then
		a = faded(b)
	elseif b == nil then
		b = faded(a)
	end
	return blend(a, b, p, nil)
end

-- Can this pair's own look tween frame by frame (a plate)?
local function tweenable(a: any, b: any): boolean
	if a.t ~= b.t or a.text or b.text or a.icon or b.icon then
		return false
	end
	local sa, sb = a.shape, b.shape
	if not sa or not sb or sa.k ~= sb.k then
		return false
	end
	if sa.k == "path" and sa.d ~= sb.d then
		return false
	end
	if sa.k == "polygon" and sa.sides ~= sb.sides then
		return false
	end
	if not same_shape(a.fill, b.fill) or not same_shape(a.fx, b.fx) then
		return false
	end
	local ka, kb = a.stroke, b.stroke
	if ka and kb then
		if ka.align ~= kb.align or not same_shape(ka.fill, kb.fill) then
			return false
		end
	end
	return true
end

local function rot_xf(x: number, y: number, rot: number): any
	local r = math.rad(-rot)
	return { a = math.cos(r), b = math.sin(r), c = -math.sin(r), d = math.cos(r), e = x, f = y }
end
-- Is this item's transform only its own rotation (no ancestor turned or
-- flipped it)?
local function own_turn(it: any): boolean
	if not it.xf then
		return true
	end
	local m = rot_xf(it.box.x, it.box.y, it.rot or 0)
	local x = it.xf
	return math.abs(x.a - m.a) < 1e-3 and math.abs(x.b - m.b) < 1e-3 and math.abs(x.c - m.c) < 1e-3 and math.abs(x.d - m.d) < 1e-3
end

-- An item's own look between a and b at progress p, in viewport units
-- (box `r`): a plate redrawn each frame. Opacity comes in `op`.
function M.tween_item(a: any, b: any, r: any, p: number, op: number): any
	local it = table.clone(b)
	it.p, it.d, it.n = nil, 0, 0
	it.ia, it.st, it.sttr, it.src = nil, nil, nil, nil
	it.box = { x = r.x, y = r.y, w = math.max(0, r.w), h = math.max(0, r.h) }
	it.fill = blend_list(a.fill, b.fill, p)
	it.fx = blend_list(a.fx, b.fx, p)
	if a.stroke or b.stroke then
		local sa = a.stroke or { fill = faded(b.stroke.fill), w = b.stroke.w, align = b.stroke.align }
		local sb = b.stroke or { fill = faded(a.stroke.fill), w = a.stroke.w, align = a.stroke.align }
		local s = table.clone(sb)
		s.fill = blend_list(sa.fill, sb.fill, p)
		s.w = blend(sa.w, sb.w, p, nil)
		it.stroke = s
	end
	if a.shape and b.shape then
		it.shape = blend(a.shape, b.shape, p, nil)
		if it.shape.r then
			for k, v in it.shape.r do
				it.shape.r[k] = math.max(0, v)
			end
		end
	end
	local ra, rb = a.rot or 0, b.rot or 0
	local rot = lerp(ra, rb, p)
	it.rot = if rot ~= 0 then rot else nil
	-- (B1) a turn tweens about the layer's centre, as Figma plays it: the
	-- corner `r` (both ends' corners mixed) moves so the centre goes straight
	-- from one end's to the other's; exact at both ends
	local x0, y0 = r.x, r.y
	if ra ~= rb then
		local function half(deg: number): (number, number)
			local q = math.rad(-deg)
			local hx, hy = r.w / 2, r.h / 2
			return math.cos(q) * hx - math.sin(q) * hy, math.sin(q) * hx + math.cos(q) * hy
		end
		local ax, ay = half(ra)
		local bx, by = half(rb)
		local mx, my = half(rot)
		x0 += lerp(ax, bx, p) - mx
		y0 += lerp(ay, by, p) - my
		it.box.x, it.box.y = x0, y0
	end
	it.xf = if math.abs(rot) > 1e-6 then rot_xf(x0, y0, rot) else nil
	it.op = if op < 1 then math.max(0, op) else nil
	return it
end

-- ── the plan ──────────────────────────────────────────────────────────────

-- The last index of item i's subtree.
local function last(nodes: { any }, i: number): number
	return i + (nodes[i].n or 0)
end
-- Item i's direct children (indices).
local function kids(nodes: { any }, i: number): { number }
	local out = {}
	local j = i + 1
	local stop = last(nodes, i)
	while j <= stop do
		table.insert(out, j)
		j = last(nodes, j) + 1
	end
	return out
end
-- Each item's opacity as shown (its own and its ancestors', the Screen's
-- aside: the base carries that).
local function effective(nodes: { any }): { number }
	local out = { 1 }
	local stack: { { number } } = {}
	for i = 2, #nodes do
		while #stack > 0 and stack[#stack][1] < i do
			table.remove(stack)
		end
		local up = if #stack > 0 then stack[#stack][2] else 1
		local mine = up * (nodes[i].op or 1)
		out[i] = mine
		table.insert(stack, { last(nodes, i), mine })
	end
	return out
end
-- How far an item's paint reaches past its box (shadows, outer strokes),
-- over its subtree when `whole`.
local function reach(nodes: { any }, i: number, whole: boolean): number
	local pad = 1
	local stop = if whole then last(nodes, i) else i
	local x0 = nodes[i].box
	for j = i, stop do
		local it = nodes[j]
		for _, e in it.fx or {} do
			if e.k == "shadow" and not e.inner then
				pad = math.max(pad, (e.blur or 0) + math.max(0, e.spread or 0) + math.max(math.abs(e.x or 0), math.abs(e.y or 0)) + 1)
			elseif e.k == "blur" then
				pad = math.max(pad, (e.radius or 0) * 2 + 1)
			end
		end
		if it.stroke and it.stroke.align ~= "inside" then
			local w = it.stroke.w or { 1, 1, 1, 1 }
			pad = math.max(pad, math.max(w[1] or w.t or 0, w[2] or w.r or 0, w[3] or w.b or 0, w[4] or w.l or 0) + 1)
		end
		if j > i and whole then
			-- (descendants past the box: a badge over a corner)
			local b = it.box
			pad = math.max(pad, x0.x - b.x, x0.y - b.y, b.x + b.w - x0.x - x0.w, b.y + b.h - x0.y - x0.h)
		end
		if it.xf then
			pad = math.max(pad, math.max(it.box.w, it.box.h) * 0.5)
		end
	end
	return math.ceil(pad)
end

local function even(a: any, b: any): (boolean, number)
	if a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0 then
		return math.abs(a.w - b.w) < 0.5 and math.abs(a.h - b.h) < 0.5, 1
	end
	local sx, sy = b.w / a.w, b.h / a.h
	return math.abs(sx - sy) <= 0.01 * math.max(sx, sy), sx
end

-- `src`, `dst`: the two Screens' items. opts: { so?, sd? (item → dx, dy:
-- where it's shown, from the scene's box to viewport units), max?, redraw? }.
function M.plan(src: { any }, dst: { any }, opts: any?): any
	opts = opts or {}
	local m = M.match(src, dst)
	local d2s, s2d = m.d2s, m.s2d
	local rs, rd = src[1].box, dst[1].box
	local so = opts.so or function(_i: number): (number, number)
		return -rs.x, -rs.y
	end
	local sd = opts.sd or function(_i: number): (number, number)
		return -rd.x, -rd.y
	end
	local function rect(nodes: { any }, off: (number) -> (number, number), i: number): any
		local b = nodes[i].box
		local dx, dy = off(i)
		return { x = b.x + dx, y = b.y + dy, w = b.w, h = b.h }
	end
	local es, ed = effective(src), effective(dst)
	local max_m = opts.max or M.MAX_MOVERS
	local max_r = opts.redraw or M.MAX_REDRAW
	local plan: any = {
		movers = {},
		src_hide = {} :: { [string]: boolean },
		dst_hide = {} :: { [string]: boolean },
		src_strip = {} :: { [string]: boolean },
		dst_strip = {} :: { [string]: boolean },
		pairs = m.count,
		over = 0,
		redraws = 0,
		match = m,
	}
	local function hide(nodes: { any }, set: any, i: number)
		set[nodes[i].id] = true
	end
	local function full(): boolean
		if #plan.movers >= max_m then
			plan.over += 1
			return true
		end
		return false
	end

	-- A pair whose whole subtree only moved, scaled evenly or faded.
	local function is_group(si: number, di: number): (boolean, number)
		local a, b = src[si], dst[di]
		if (a.n or 0) ~= (b.n or 0) or not look_eq(a, b) or not eq(a.rot, b.rot) then
			return false, 1
		end
		if (a.xf or b.xf) and not (a.xf and b.xf and eq(a.xf.a, b.xf.a) and eq(a.xf.b, b.xf.b) and eq(a.xf.c, b.xf.c) and eq(a.xf.d, b.xf.d)) then
			return false, 1
		end
		local ok, s = even(a.box, b.box)
		if not ok then
			return false, 1
		end
		-- (scrolled content inside: drawn whole it would show unscrolled, so
		-- it goes piece by piece, each where it shows)
		local sx0, sy0 = so(si)
		local dx0, dy0 = sd(di)
		for k = 1, a.n or 0 do
			local x1, y1 = so(si + k)
			local x2, y2 = sd(di + k)
			if math.abs(x1 - sx0) > 0.01 or math.abs(y1 - sy0) > 0.01 or math.abs(x2 - dx0) > 0.01 or math.abs(y2 - dy0) > 0.01 then
				return false, 1
			end
		end
		for k = 1, a.n or 0 do
			local x, y = src[si + k], dst[di + k]
			if d2s[di + k] ~= si + k or not look_eq(x, y) or not eq(x.op, y.op) or not eq(x.rot, y.rot) then
				return false, 1
			end
			local tol = 0.75 + 0.005 * math.max(b.box.w, b.box.h)
			if math.abs((y.box.x - b.box.x) - s * (x.box.x - a.box.x)) > tol or math.abs((y.box.y - b.box.y) - s * (x.box.y - a.box.y)) > tol then
				return false, 1
			end
			if math.abs(y.box.w - s * x.box.w) > tol or math.abs(y.box.h - s * x.box.h) > tol then
				return false, 1
			end
		end
		return true, s
	end
	local function still(ra: any, rb: any, opa: number, opb: number): boolean
		return math.abs(ra.x - rb.x) < 0.01 and math.abs(ra.y - rb.y) < 0.01 and math.abs(ra.w - rb.w) < 0.01 and math.abs(ra.h - rb.h) < 0.01 and math.abs(opa - opb) < 1e-3
	end

	local function add(mv: any)
		mv.n = #plan.movers + 1
		table.insert(plan.movers, mv)
	end

	-- A layer with no pair in a parent that moves: it fades where it is in
	-- that parent. `side`: "src" (fades out) or "dst" (fades in).
	local function fade(side: string, i: number, pa: any, pb: any, z: number)
		if full() then
			return
		end
		local nodes = if side == "src" then src else dst
		local r = rect(nodes, if side == "src" then so else sd, i)
		local e = if side == "src" then es[i] else ed[i]
		-- (its place in the parent, kept as the parent tweens: Figma keeps
		-- its offset from the parent's top-left and its own size, filmed:
		-- the card's description sits 476 pt under the card's top all along)
		local here = if side == "src" then pa else pb
		local there = if side == "src" then pb else pa
		local moved = { x = there.x + (r.x - here.x), y = there.y + (r.y - here.y), w = r.w, h = r.h }
		local mv: any = {
			kind = "fade", side = side, own = false, name = nodes[i].name, z = z,
			a = if side == "src" then r else moved,
			b = if side == "src" then moved else r,
			opa = if side == "src" then e else 0,
			opb = if side == "src" then 0 else e,
			pad = reach(nodes, i, true),
		}
		if side == "src" then
			mv.si = i
			hide(src, plan.src_hide, i)
		else
			mv.di = i
			hide(dst, plan.dst_hide, i)
		end
		add(mv)
	end

	local function visit(di: number, in_plate: boolean)
		local si = d2s[di]
		if not si then
			return
		end
		local a, b = src[si], dst[di]
		local ra, rb = rect(src, so, si), rect(dst, sd, di)
		local group, s = is_group(si, di)
		if group then
			if not in_plate and still(ra, rb, es[si], ed[di]) then
				return -- (the same in both bases)
			end
			if full() then
				return
			end
			add({ kind = "group", own = false, si = si, di = di, a = ra, b = rb, opa = es[si], opb = ed[di], s = s, pad = reach(dst, di, true), name = b.name, z = di })
			hide(src, plan.src_hide, si)
			hide(dst, plan.dst_hide, di)
			return
		end
		-- its own paint (when it changes, or a plate around it moves), then
		-- what's inside
		local plate = false
		local own_still = still(ra, rb, es[si], ed[di]) and look_eq(a, b) and eq(a.rot, b.rot)
		if (has_paint(a) or has_paint(b)) and (in_plate or not own_still) then
			if not full() then
				local kind
				local ok_even, s2 = even(a.box, b.box)
				if look_eq(a, b) and ok_even and eq(a.rot, b.rot) and not a.xf and not b.xf then
					kind = "group"
				elseif tweenable(a, b) and own_turn(a) and own_turn(b) and plan.redraws < max_r then
					kind = "redraw"
					plan.redraws += 1
				else
					kind = "xfade"
				end
				add({
					kind = kind, own = true, si = si, di = di, a = ra, b = rb, opa = es[si], opb = ed[di], s = s2,
					pad = math.max(reach(src, si, false), reach(dst, di, false)), name = b.name, z = di,
				})
				plan.src_strip[a.id] = true
				plan.dst_strip[b.id] = true
				plate = true
			end
		end
		local moves = plate or in_plate or not still(ra, rb, es[si], ed[di])
		-- (layers only one side has: fade out under the ones that pair)
		-- (each in its place among them: over the paired sibling before it,
		-- its subtree too. Figma, filmed (f3c card-close): the card's × stays
		-- over its photo as the card closes; at the parent's own z it went
		-- under the photo's mover)
		if moves then
			local after = di
			for k, sc in kids(src, si) do
				if s2d[sc] then
					after = last(dst, s2d[sc])
				else
					fade("src", sc, ra, rb, after + 0.001 * k)
				end
			end
		end
		for _, dc in kids(dst, di) do
			if d2s[dc] then
				visit(dc, plate or in_plate)
			elseif moves then
				fade("dst", dc, ra, rb, dc)
			end
		end
	end
	for _, dc in kids(dst, 1) do
		visit(dc, false)
	end

	-- Z-order (Figma's, filmed: the Shop's other card stays over the card
	-- that opens). Movers are drawn over the bases, so a layer that should
	-- be over a mover, where they cross, is lifted into a still mover of
	-- its own at its place in the order:
	--   * a layer only the new Screen has keeps its place among the pairs;
	--   * a layer only the old Screen has, above a pair there, is drawn over
	--     the new Screen while it fades ("if we have layers above any
	--     matching layers, Figma will animate them above the destination").
	local travel = {}
	for _, mv in plan.movers do
		local a, b, pad = mv.a, mv.b, mv.pad or 0
		table.insert(travel, {
			z = mv.z or 0,
			x0 = math.min(a.x, b.x) - pad,
			y0 = math.min(a.y, b.y) - pad,
			x1 = math.max(a.x + a.w, b.x + b.w) + pad,
			y1 = math.max(a.y + a.h, b.y + b.h) + pad,
		})
	end
	local function crosses(r: any, pad: number, below: number?): boolean
		for _, t in travel do
			if (below == nil or t.z < below) and r.x - pad < t.x1 and r.x + r.w + pad > t.x0 and r.y - pad < t.y1 and r.y + r.h + pad > t.y0 then
				return true
			end
		end
		return false
	end
	-- (what's already in a mover, or under a lifted layer, stays put)
	local function gone(nodes: { any }, set: any): { [number]: boolean }
		local out: { [number]: boolean } = {}
		local stop = 0
		for i = 2, #nodes do
			if i <= stop then
				out[i] = true
			elseif set[nodes[i].id] then
				out[i] = true
				stop = last(nodes, i)
			end
		end
		return out
	end
	local function lift(side: string, i: number, z: number)
		if full() then
			return
		end
		local nodes = if side == "src" then src else dst
		local r = rect(nodes, if side == "src" then so else sd, i)
		local e = if side == "src" then es[i] else ed[i]
		local mv: any = {
			kind = "fade", side = side, own = false, lifted = true, name = nodes[i].name, z = z,
			a = r, b = r, opa = if side == "src" then e else 0, opb = if side == "src" then 0 else e,
			pad = reach(nodes, i, true),
		}
		if side == "src" then
			mv.si = i
			hide(src, plan.src_hide, i)
		else
			mv.di = i
			hide(dst, plan.dst_hide, i)
		end
		add(mv)
	end
	if #travel > 0 then
		local dgone = gone(dst, plan.dst_hide)
		local i = 2
		while i <= #dst do
			local it = dst[i]
			if not d2s[i] and not dgone[i] and (ed[i] or 0) > 0 then
				-- (a whole unmatched subtree goes up as one)
				if crosses(rect(dst, sd, i), reach(dst, i, true), i) then
					lift("dst", i, i)
				end
				i = last(dst, i) + 1
				continue
			end
			if dgone[i] and it and plan.dst_hide[it.id] then
				i = last(dst, i) + 1
				continue
			end
			i += 1
		end
		local sgone = gone(src, plan.src_hide)
		local paired_below = false
		i = 2
		while i <= #src do
			local it = src[i]
			if s2d[i] then
				paired_below = true
			end
			if paired_below and not s2d[i] and not sgone[i] and (es[i] or 0) > 0 then
				if crosses(rect(src, so, i), reach(src, i, true), nil) then
					lift("src", i, #dst + i)
				end
				i = last(src, i) + 1
				continue
			end
			if sgone[i] and it and plan.src_hide[it.id] then
				i = last(src, i) + 1
				continue
			end
			i += 1
		end
		-- the movers in that order
		local order = table.clone(plan.movers)
		for k, mv in order do
			mv.k0 = k
		end
		table.sort(order, function(x: any, y: any): boolean
			local zx, zy = x.z or 0, y.z or 0
			if zx ~= zy then
				return zx < zy
			end
			return x.k0 < y.k0
		end)
		for k, mv in order do
			mv.n = k
			mv.k0 = nil
		end
		plan.movers = order
	end

	-- Clips: a mover inside a parent that clips (the Screen aside: the
	-- viewport clips) is cut by it all along, as in Figma. `clip.a/.b`: that
	-- parent's rect at each end (viewport units); `resizes` when it grows or
	-- shrinks on the way.
	local function index(nodes: { any }): { [string]: number }
		local at = {}
		for i, it in nodes do
			at[it.id] = i
		end
		return at
	end
	local ats, atd = index(src), index(dst)
	local function clipper(nodes: { any }, at: any, i: number): number?
		local j = nodes[i].p and at[nodes[i].p]
		while j and j > 1 do
			if nodes[j].clip == true then
				return j
			end
			j = nodes[j].p and at[nodes[j].p]
		end
		return nil
	end
	for _, mv in plan.movers do
		local cr: any = nil
		if mv.di then
			local j = clipper(dst, atd, mv.di)
			if j then
				local rb = rect(dst, sd, j)
				local sj = d2s[j]
				cr = { a = if sj then rect(src, so, sj) else rb, b = rb }
			end
		elseif mv.si then
			local j = clipper(src, ats, mv.si)
			if j then
				local ra = rect(src, so, j)
				local dj = s2d[j]
				cr = { a = ra, b = if dj then rect(dst, sd, dj) else ra }
			end
		end
		if cr then
			cr.resizes = math.abs(cr.a.w - cr.b.w) > 0.01 or math.abs(cr.a.h - cr.b.h) > 0.01
			mv.clip = cr
		end
	end
	return plan
end

-- A mover at progress p (eased; a spring may pass 1): its rect (viewport
-- units) and opacity.
function M.at(mv: any, p: number): (any, number)
	local a, b = mv.a, mv.b
	local r = { x = lerp(a.x, b.x, p), y = lerp(a.y, b.y, p), w = math.max(0, lerp(a.w, b.w, p)), h = math.max(0, lerp(a.h, b.h, p)) }
	local q = math.clamp(p, 0, 1)
	return r, lerp(mv.opa, mv.opb, q)
end

-- Does a drag on layer `id` (of the old Screen, `src` its nodes) follow the
-- pointer? Only when that layer itself travels in the plan (4 pt or more),
-- on its own or inside a group that moves. A switch's track doesn't (its
-- knob does): Figma plays that transition through once the drag starts,
-- the pointer held still or not (filmed, pure/anim/f3-figma
-- raw-figma-f3c/switch-hold).
function M.drag_follows(plan: any, src: { any }, id: string): boolean
	local at = nil
	for i, it in src do
		if it.id == id then
			at = i
			break
		end
	end
	if not at then
		return false
	end
	for _, mv in plan.movers do
		local si = mv.si
		if si and (si == at or (mv.kind == "group" and at > si and at <= last(src, si))) then
			local tx, ty = mv.b.x - mv.a.x, mv.b.y - mv.a.y
			if tx * tx + ty * ty >= 16 then
				return true
			end
		end
	end
	return false
end

-- How much of a dissolving drop shadow drawn for box `b` (its reach `pad`)
-- may show when its plate is at `r`, 0..1. Play doesn't stretch a shadow
-- (a blur each raster), so one bigger than the plate stood out round it as
-- a grey slab: the card closing (393×852 down to 164×220) showed a page-sized
-- haze Figma doesn't have (filmed, pure/anim/f3-figma f3c-card-close). It
-- shows only while the plate is within its reach of that size.
function M.shadow_fit(b: any, r: any, pad: number): number
	local over = math.max(0, b.w - r.w, b.h - r.h)
	return math.clamp(1 - over / math.max(1, pad), 0, 1)
end

-- Where a crossfading look with box `b` shows when the pair's box is `r`:
-- (scale, x, y). Text scales evenly to the box's height and sits as it's
-- aligned (Figma, filmed: both looks of the card's title grow together,
-- left-aligned, so they overlap instead of showing twice); anything else
-- fits inside the box.
function M.fit(b: any, r: any, text: any?): (number, number, number)
	if text then
		local s = if b.h > 0 then r.h / b.h else 1
		local ax = if text.align == "center" then 0.5 elseif text.align == "right" then 1 else 0
		return s, r.x + (r.w - b.w * s) * ax, r.y
	end
	local s = math.min(if b.w > 0 then r.w / b.w else 1, if b.h > 0 then r.h / b.h else 1)
	return s, r.x, r.y
end

-- ── what gets drawn ───────────────────────────────────────────────────────

-- A Screen's items as its base: what `hide` holds left out (with what's
-- inside), and what `strip` holds without its own paint (its children
-- stay). The structure stays (ranges, ids), so scrolling and drivers work
-- on it as on the Screen.
function M.base(nodes: { any }, hide: { [string]: boolean }, strip: { [string]: boolean }): { any }
	local out = table.clone(nodes)
	local stop = 0
	for i, it in nodes do
		local gone = i <= stop or hide[it.id] == true
		if hide[it.id] then
			stop = math.max(stop, last(nodes, i))
		end
		if gone or strip[it.id] then
			local c = table.clone(it)
			if (c.n or 0) == 0 then
				c.hidden = true
			else
				c.fill, c.stroke, c.fx, c.text, c.icon = nil, nil, nil, nil, nil
			end
			out[i] = c
		end
	end
	return out
end

-- A mover's items to draw from one side (`own`: the item alone), as a root
-- of its own; its opacity is the element's.
function M.sub(nodes: { any }, i: number, own: boolean): { any }
	local out = {}
	local stop = if own then i else last(nodes, i)
	for j = i, stop do
		local c = table.clone(nodes[j])
		c.ia, c.st, c.sttr, c.src = nil, nil, nil, nil
		if j == i then
			c.p, c.op = nil, nil
			c.d = 0
			if own then
				c.n = 0
			end
		end
		out[#out + 1] = c
	end
	return out
end

-- What a frame at progress p draws, for a renderer that redraws (the
-- engine's Simulate composes it into one root): over the two bases, each
-- mover's pieces as { nodes, map = affine from its side's Canvas units to
-- viewport units, op }.
function M.pieces(plan: any, src: { any }, dst: { any }, p: number): { any }
	local out = {}
	local q = math.clamp(p, 0, 1)
	local function piece(nodes: { any }, i: number, own: boolean, from: any, to: any, op: number)
		-- from: the side's rect in Canvas units (its box); to: where it is now
		local sx = if from.w > 0 then to.w / from.w else 1
		local sy = if from.h > 0 then to.h / from.h else 1
		local s = if from.w > 0 then sx else sy
		table.insert(out, {
			nodes = M.sub(nodes, i, own),
			map = { a = s, b = 0, c = 0, d = s, e = to.x - from.x * s, f = to.y - from.y * s },
			op = op,
		})
	end
	for _, mv in plan.movers do
		local r, op = M.at(mv, p)
		if mv.kind == "group" then
			piece(dst, mv.di, mv.own, dst[mv.di].box, r, op)
		elseif mv.kind == "fade" then
			local nodes = if mv.side == "src" then src else dst
			local i = if mv.side == "src" then mv.si else mv.di
			piece(nodes, i, false, nodes[i].box, r, op)
		elseif mv.kind == "xfade" then
			for side = 1, 2 do
				local nodes = if side == 1 then src else dst
				local i = if side == 1 then mv.si else mv.di
				local b = nodes[i].box
				local s, x, y = M.fit(b, r, nodes[i].text)
				piece(nodes, i, mv.own, b, { x = x, y = y, w = b.w * s, h = b.h * s }, if side == 1 then op * (1 - q) else op * q)
			end
		else
			local it = M.tween_item(src[mv.si], dst[mv.di], r, p, op)
			table.insert(out, { nodes = { it }, map = nil, op = 1 })
		end
	end
	return out
end

-- ── interrupting (F4-int) ─────────────────────────────────────────────────

-- The new Screen's items as a frame at progress p shows them, so a new
-- transition can start from where this one is (CSS's rule: a transition
-- interrupted starts from the current value). Same items, same order and
-- ranges as `dst` (so the dst Screen's scroll and drivers apply); each
-- mover's layers at their tweened box, look and opacity; a layer only the
-- new Screen has, which comes in with its base, at that base's opacity
-- (`base_q`, default p clamped). `od(i)`: dst item i's offset from its
-- Canvas box to viewport units (the plan's `opts.sd`).
-- Approximate (pure/anim/f4int/README.md): a crossfade (new words, another
-- icon) shows its nearer look; a layer only the old Screen has, fading out,
-- isn't there.
function M.snapshot(plan: any, src: { any }, dst: { any }, p: number, od: ((number) -> (number, number))?, base_q: number?): { any }
	local q = math.clamp(p, 0, 1)
	local bq = if base_q then math.clamp(base_q, 0, 1) else q
	local rd = dst[1].box
	local off = od or function(_i: number): (number, number)
		return -rd.x, -rd.y
	end
	local out = table.clone(dst)
	local ed = effective(dst)
	local covered: { [number]: boolean } = {}
	local function cover(i: number, whole: boolean)
		for j = i, if whole then last(dst, i) else i do
			covered[j] = true
		end
	end
	-- (an item's own opacity for an effective one: its ancestors' stays)
	local function own_op(i: number, op: number): number?
		local up = ed[i] / math.max(1e-6, dst[i].op or 1)
		local o = if up > 1e-6 then op / up else op
		return if o < 0.999 then math.clamp(o, 0, 1) else nil
	end
	-- (dst item i's subtree, or i alone, moved and scaled onto `r`, Canvas units)
	local function place(i: number, whole: boolean, r: any, from: { any }?)
		local b = (from or dst)[i].box
		local s = if b.w > 0 then r.w / b.w elseif b.h > 0 then r.h / b.h else 1
		for j = i, if whole then last(dst, i) else i do
			local c = table.clone(out[j])
			local bb = c.box
			c.box = { x = r.x + (bb.x - b.x) * s, y = r.y + (bb.y - b.y) * s, w = bb.w * s, h = bb.h * s }
			if c.xf then
				local x = c.xf
				c.xf = { a = x.a * s, b = x.b * s, c = x.c * s, d = x.d * s, e = r.x + (x.e - b.x) * s, f = r.y + (x.f - b.y) * s }
			end
			if c.text and math.abs(s - 1) > 1e-3 and c.text.size then
				c.text = table.clone(c.text)
				c.text.size = c.text.size * s
			end
			out[j] = c
		end
	end
	local function canvas(i: number, r: any): any
		local dx, dy = off(i)
		return { x = r.x - dx, y = r.y - dy, w = r.w, h = r.h }
	end
	for _, mv in plan.movers do
		local r, op = M.at(mv, p)
		local di = mv.di
		if not di then
			continue -- (a layer only the old Screen has)
		end
		local rc = canvas(di, r)
		if mv.kind == "group" or mv.kind == "fade" then
			local whole = not mv.own
			place(di, whole, rc)
			local c = table.clone(out[di])
			c.op = own_op(di, op)
			out[di] = c
			cover(di, whole)
		elseif mv.kind == "redraw" then
			local b = dst[di]
			local it = M.tween_item(src[mv.si], b, rc, p, 1)
			it.p, it.d, it.n, it.ia, it.st, it.sttr, it.src = b.p, b.d, b.n, b.ia, b.st, b.sttr, b.src
			it.op = own_op(di, op)
			out[di] = it
			cover(di, false)
		else
			-- xfade: the look it's nearer, fitted in the box
			local whole = not mv.own
			local from_src = q < 0.5 and mv.si ~= nil and (mv.own or (src[mv.si].n or 0) == (dst[di].n or 0))
			if from_src then
				local si = mv.si
				for k = 0, if whole then (src[si].n or 0) else 0 do
					local c = table.clone(src[si + k])
					local d = dst[di + k]
					c.id, c.p, c.d, c.n, c.ia, c.st, c.sttr, c.src = d.id, d.p, d.d, d.n, d.ia, d.st, d.sttr, d.src
					out[di + k] = c
				end
			end
			local look = if from_src then src[mv.si] else dst[di]
			local s, x, y = M.fit(look.box, rc, look.text)
			-- (placed by its own box: the look kept may be the old one)
			place(di, whole, { x = x, y = y, w = look.box.w * s, h = look.box.h * s }, out)
			local c = table.clone(out[di])
			c.op = own_op(di, op)
			out[di] = c
			cover(di, whole)
		end
	end
	-- (a layer only the new Screen has, outside every mover, comes in with its base)
	if bq < 1 then
		local d2s = (plan.match or M.match(src, dst)).d2s
		local i = 2
		while i <= #dst do
			if not covered[i] and not d2s[i] and not dst[i].hidden then
				local c = table.clone(out[i])
				local o = (c.op or 1) * bq
				c.op = if o < 0.999 then o else nil
				if o < 0.004 then
					c.hidden = true
				end
				out[i] = c
				i = last(dst, i) + 1
			else
				i += 1
			end
		end
	end
	return out
end

-- The progress velocity (1/s) a new plan's motion starts with so its movers
-- carry on as the old ones moved (least squares over every mover's x, y, w,
-- h): `pv` the old progress velocity; old movers matched to new ones by the
-- new Screen's item (the old plan's `di`, the new plan's `si`, the same item
-- ids, as `snapshot` keeps them). A turn back to the start gives −pv/p.
function M.carry(old: any, new: any, old_dst: { any }, new_src: { any }, pv: number): number
	local vel: { [string]: any } = {}
	for _, mv in old.movers do
		if mv.di then
			vel[old_dst[mv.di].id] = mv
		end
	end
	local num, den = 0, 0
	for _, mv in new.movers do
		local dx, dy, dw, dh = mv.b.x - mv.a.x, mv.b.y - mv.a.y, mv.b.w - mv.a.w, mv.b.h - mv.a.h
		den += dx * dx + dy * dy + dw * dw + dh * dh
		local o = mv.si and vel[new_src[mv.si].id]
		if o then
			num += (o.b.x - o.a.x) * dx + (o.b.y - o.a.y) * dy + (o.b.w - o.a.w) * dw + (o.b.h - o.a.h) * dh
		end
	end
	if den < 1e-6 then
		return 0
	end
	return math.clamp(pv * num / den, -40, 40)
end

-- For CheckSmart: what pairs and what doesn't, by name path.
function M.report(src: { any }, dst: { any }): any
	local m = M.match(src, dst)
	local plan = M.plan(src, dst)
	local paired, only_src, only_dst = {}, {}, {}
	local function path(nodes: { any }, keys: any, i: number): string
		local k = keys[i]
		if k then
			return (string.gsub(k, "^@", "match:"))
		end
		return tostring(nodes[i].name)
	end
	for i = 2, #dst do
		if m.d2s[i] then
			table.insert(paired, path(dst, m.kd, i))
		else
			table.insert(only_dst, path(dst, m.kd, i))
		end
	end
	for i = 2, #src do
		if not m.s2d[i] then
			table.insert(only_src, path(src, m.ks, i))
		end
	end
	local kinds = {}
	for _, mv in plan.movers do
		kinds[mv.kind] = (kinds[mv.kind] or 0) + 1
	end
	return { paired = paired, only_from = only_src, only_to = only_dst, movers = #plan.movers, kinds = kinds, over = plan.over }
end

return M
