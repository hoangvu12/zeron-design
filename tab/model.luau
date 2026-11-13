--!strict
-- What the Canvas knows of a Design's scene, indexed for the pointer: each
-- node's item and map, its parent and children, hit testing and the
-- selection's rules (pen.dev's, as port/web/canvas.js has them), and
-- snapping with smart guides. Pure: the Canvas (canvas.luau) holds state.

local Draw = require("./draw")

local M = {}

export type Node = {
	id: string,
	it: any,
	root: number, -- index of its root in the roots list
	at: number, -- index of its item in the root's nodes
	parent: string, -- "" for a root
	depth: number,
	m: any, -- local → Canvas
	inv: any, -- Canvas → local
	bounds: { number }, -- upright box on the Canvas
	turned: boolean,
}
export type Index = { by: { [string]: Node }, kids: { [string]: { string } }, order: { string } }

-- A node's map (`m`) and its inverse (`inv`), made when first read rather
-- than for every node: a large Design's index held two tables more per
-- node (5.6 MB for 4,184 items), against the window's plugin memory, and
-- only the nodes a person points at, selects or drags need them. A map
-- that turns or scales (`xf`) is kept; a plain one is a move, made again.
local NodeMeta = {
	__index = function(n: any, k: string): any
		-- (What its item says already: not held twice.)
		if k == "id" then
			return n.it.id
		elseif k == "parent" then
			return n.it.p or ""
		elseif k == "depth" then
			return n.it.d or 0
		elseif k == "m" then
			return Draw.local_map(n.it)
		elseif k == "inv" then
			local inv = Draw.invert(n.m)
			rawset(n, "inv", inv)
			return inv
		end
		return nil
	end,
}

-- One root's part of the index: its nodes in order and its children lists.
local function index_root(root: any): any
	local list: { Node } = {}
	local kids: { [string]: { string } } = {}
	for at, it in root.nodes or {} do
		local parent = it.p or ""
		-- (Four keys for most: `m` only where it turns or scales, `turned`
		-- only where true. An item with no `xf` sits at its box: its bounds
		-- are its box, made with no map.)
		local n: Node
		if it.xf then
			local m = Draw.local_map(it)
			local x, y, w, h = Draw.canvas_bounds(it, m)
			local turned = not Draw.upright(m) and not (math.abs(m.b) < 1e-9 and math.abs(m.c) < 1e-9)
			n = setmetatable({
				it = it,
				root = 0,
				at = at,
				bounds = { x, y, w, h },
				m = m,
				turned = if turned then true else nil,
			} :: any, NodeMeta)
		else
			local box = it.box
			n = setmetatable({
				it = it,
				root = 0,
				at = at,
				bounds = { box.x, box.y, box.w, box.h },
			} :: any, NodeMeta)
		end
		table.insert(list, n)
		local l = kids[parent]
		if not l then
			l = {}
			kids[parent] = l
		end
		table.insert(l, it.id)
	end
	return { list = list, kids = kids }
end

-- `cache` (a table with weak keys, kept by the caller) holds each root's part
-- by the root's table: an agent's edit rewrites one root, so only that one is
-- measured again; the rest is put together from the parts.
function M.index(roots: { any }, cache: { [any]: any }?): Index
	local by: { [string]: Node } = {}
	local kids: { [string]: { string } } = { [""] = {} }
	local order: { string } = {}
	local top = kids[""]
	for ri, root in roots do
		local part = if cache then cache[root] else nil
		if not part then
			part = index_root(root)
			if cache then
				cache[root] = part
			end
		end
		for _, n in part.list do
			n.root = ri
			by[n.id] = n
			table.insert(order, n.id)
		end
		for parent, l in part.kids do
			if parent == "" then
				table.move(l, 1, #l, #top + 1, top)
			else
				local had = kids[parent]
				if had then
					-- (A copy: the parts' lists stay as they were.)
					local both = table.clone(had)
					table.move(l, 1, #l, #both + 1, both)
					kids[parent] = both
				else
					kids[parent] = l
				end
			end
		end
	end
	return { by = by, kids = kids, order = order }
end

-- Whether Canvas point (x, y) is inside the node's own box.
function M.inside(n: Node, x: number, y: number): boolean
	if not n.turned then
		-- Upright (moved, maybe mirrored): its box is its bounds.
		local b = n.bounds
		return x >= b[1] and y >= b[2] and x <= b[1] + b[3] and y <= b[2] + b[4]
	end
	local lx, ly = Draw.apply(n.inv, x, y)
	return lx >= 0 and ly >= 0 and lx <= n.it.box.w and ly <= n.it.box.h
end

-- The node's four corners on the Canvas.
function M.corners(n: Node, m: any?): { { number } }
	local mm = m or n.m
	local w, h = n.it.box.w, n.it.box.h
	local out = {}
	for _, p in { { 0, 0 }, { w, 0 }, { w, h }, { 0, h } } do
		local x, y = Draw.apply(mm, p[1], p[2])
		table.insert(out, { x, y })
	end
	return out
end

local function is_inside_instance(id: string): boolean
	return string.find(id, "/", 1, true) ~= nil
end
M.is_inside_instance = is_inside_instance

-- Every node under (x, y), outermost first along one branch (the topmost
-- sibling wins). An Instance's insides only when `inner`.
function M.stack_at(ix: Index, x: number, y: number, inner: boolean): { Node }
	local out: { Node } = {}
	local parent = ""
	while true do
		local best: Node? = nil
		for _, id in ix.kids[parent] or {} do
			local n = ix.by[id]
			if n and not n.it.lock and M.inside(n, x, y) then
				best = n
			end
		end
		if not best then
			return out
		end
		table.insert(out, best)
		if not inner and best.it.inst then
			return out
		end
		parent = best.id
	end
end

-- What a press at (x, y) picks, as pen.dev: a Screen's direct child (or
-- the Screen off them); `deep` the innermost; inside the selection's branch
-- its depth stays; `deeper_than` one deeper (a double click).
function M.hit(ix: Index, x: number, y: number, selected: { string }, deep: boolean, deeper_than: string?): string?
	local s = M.stack_at(ix, x, y, deep or deeper_than ~= nil)
	if #s == 0 then
		return nil
	end
	if deep then
		return s[#s].id
	end
	local function at(id: string): number?
		for i, n in s do
			if n.id == id then
				return i
			end
		end
		return nil
	end
	if deeper_than then
		local i = at(deeper_than)
		if i then
			return (s[i + 1] or s[i]).id
		end
	end
	for _, id in selected do
		local i = at(id)
		if i and s[i + 1] then
			return s[i + 1].id
		end
	end
	for _, id in selected do
		local n = ix.by[id]
		local i = if n and n.parent ~= "" then at(n.parent) else nil
		if i and s[i + 1] then
			return s[i + 1].id
		end
	end
	for _, id in selected do
		local i = at(id)
		if i then
			return s[i].id
		end
	end
	return (s[2] or s[1]).id
end

function M.under(ix: Index, id: string, ancestor: string): boolean
	local n = ix.by[id]
	while n and n.parent ~= "" do
		if n.parent == ancestor then
			return true
		end
		n = ix.by[n.parent]
	end
	return false
end

-- Only the outermost of `ids` (a child moves with its parent).
function M.topmost(ix: Index, ids: { string }): { string }
	local out = {}
	for _, id in ids do
		local inner = false
		for _, o in ids do
			if o ~= id and M.under(ix, id, o) then
				inner = true
				break
			end
		end
		if not inner and ix.by[id] then
			table.insert(out, id)
		end
	end
	return out
end

function M.union(boxes: { { number } }): { number }?
	if #boxes == 0 then
		return nil
	end
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, b in boxes do
		x0, y0 = math.min(x0, b[1]), math.min(y0, b[2])
		x1, y1 = math.max(x1, b[1] + b[3]), math.max(y1, b[2] + b[4])
	end
	return { x0, y0, x1 - x0, y1 - y0 }
end

function M.meets(a: { number }, b: { number }): boolean
	return a[1] < b[1] + b[3] and a[1] + a[3] > b[1] and a[2] < b[2] + b[4] and a[2] + a[4] > b[2]
end

function M.contains(a: { number }, b: { number }): boolean
	return b[1] >= a[1] and b[2] >= a[2] and b[1] + b[3] <= a[1] + a[3] and b[2] + b[4] <= a[2] + a[4]
end

-- Snapping ---------------------------------------------------------------------------

export type Targets = { boxes: { { number } }, parent: { number }? }

-- What `ids` snap to: their siblings' boxes and their parent's (top-level
-- ones: the Screens within `near`).
function M.snap_targets(ix: Index, ids: { string }, near: { number }?): Targets
	local first = ix.by[ids[1]]
	local parent = if first then first.parent else ""
	local skip: { [string]: boolean } = {}
	for _, id in ids do
		skip[id] = true
	end
	local boxes = {}
	for _, id in ix.kids[parent] or {} do
		local n = ix.by[id]
		if n and not skip[id] and (parent ~= "" or not near or M.meets(n.bounds, near)) then
			table.insert(boxes, n.bounds)
		end
	end
	local p = if parent ~= "" then ix.by[parent] else nil
	return { boxes = boxes, parent = if p then p.bounds else nil }
end

local function xs_of(b: { number }): { number }
	return { b[1], b[1] + b[3] / 2, b[1] + b[3] }
end
local function ys_of(b: { number }): { number }
	return { b[2], b[2] + b[4] / 2, b[2] + b[4] }
end
M.xs_of, M.ys_of = xs_of, ys_of

-- The smallest shift (≤ thr) of any of `vals` onto any of `lines`.
function M.snap1(vals: { number }, lines: { number }, thr: number): number?
	local best: number? = nil
	for _, v in vals do
		for _, l in lines do
			local d = l - v
			if math.abs(d) <= thr and (best == nil or math.abs(d) < math.abs(best) - 1e-6) then
				best = d
			end
		end
	end
	return best
end

-- Left edges for `m` that keep a gap to a neighbour equal to another.
local function spacing(m: { number }, boxes: { { number } }): { number }
	local out = {}
	local row = {}
	for _, b in boxes do
		if b[2] < m[2] + m[4] and b[2] + b[4] > m[2] then
			table.insert(row, b)
		end
	end
	table.sort(row, function(a, b)
		return a[1] < b[1]
	end)
	local l, r = nil, nil
	for _, b in row do
		if b[1] + b[3] <= m[1] + m[3] / 2 then
			l = b
		elseif not r and b[1] >= m[1] + m[3] / 2 then
			r = b
		end
	end
	if l and r then
		table.insert(out, (l[1] + l[3] + r[1] - m[3]) / 2)
	end
	for i = 2, #row do
		local g = row[i][1] - (row[i - 1][1] + row[i - 1][3])
		if g > 0 then
			if l then
				table.insert(out, l[1] + l[3] + g)
			end
			if r then
				table.insert(out, r[1] - g - m[3])
			end
		end
	end
	return out
end
local function flip(b: { number }): { number }
	return { b[2], b[1], b[4], b[3] }
end

-- How far to move box `m` so an edge or centre meets one of `t`'s (or an
-- equal gap); `no_x`/`no_y` keep that axis.
function M.snap_box(m: { number }, t: Targets, thr: number, no_x: boolean?, no_y: boolean?): (number, number)
	local lx, ly = {}, {}
	local all = table.clone(t.boxes)
	if t.parent then
		table.insert(all, t.parent)
	end
	for _, b in all do
		for _, v in xs_of(b) do
			table.insert(lx, v)
		end
		for _, v in ys_of(b) do
			table.insert(ly, v)
		end
	end
	local vx, vy = xs_of(m), ys_of(m)
	for _, v in spacing(m, t.boxes) do
		table.insert(lx, v)
	end
	local flipped = {}
	for _, b in t.boxes do
		table.insert(flipped, flip(b))
	end
	for _, v in spacing(flip(m), flipped) do
		table.insert(ly, v)
	end
	-- (Equal spacing gives left edges: compare with the left edge alone.)
	local dx = if no_x then nil else M.snap1(vx, lx, thr)
	local dy = if no_y then nil else M.snap1(vy, ly, thr)
	return dx or 0, dy or 0
end

export type Guides = { lines: { { number } }, gaps: { { number } }, outlines: { { number } }? }

-- The lines box `m` meets where it is, and the equal gaps it keeps.
function M.guides_for(m: { number }, t: Targets, zoom: number): Guides
	local eps = 0.5 / math.max(zoom, 1)
	local lines, gaps = {}, {}
	local all = table.clone(t.boxes)
	if t.parent then
		table.insert(all, t.parent)
	end
	for _, v in xs_of(m) do
		local y0, y1 = m[2], m[2] + m[4]
		local hit = false
		for _, b in all do
			for _, x in xs_of(b) do
				if math.abs(x - v) < eps then
					hit = true
					y0, y1 = math.min(y0, b[2]), math.max(y1, b[2] + b[4])
					break
				end
			end
		end
		if hit then
			table.insert(lines, { v, y0, v, y1 })
		end
	end
	for _, v in ys_of(m) do
		local x0, x1 = m[1], m[1] + m[3]
		local hit = false
		for _, b in all do
			for _, y in ys_of(b) do
				if math.abs(y - v) < eps then
					hit = true
					x0, x1 = math.min(x0, b[1]), math.max(x1, b[1] + b[3])
					break
				end
			end
		end
		if hit then
			table.insert(lines, { x0, v, x1, v })
		end
	end
	-- Equal gaps to the nearest neighbour each way.
	local function nearest(list: { { number } }, f: ({ number }) -> number): { number }?
		local best, bd = nil, math.huge
		for _, b in list do
			local d = f(b)
			if d >= -eps and d < bd then
				best, bd = b, d
			end
		end
		return best
	end
	local row, col = {}, {}
	for _, b in t.boxes do
		if b[2] < m[2] + m[4] and b[2] + b[4] > m[2] then
			table.insert(row, b)
		end
		if b[1] < m[1] + m[3] and b[1] + b[3] > m[1] then
			table.insert(col, b)
		end
	end
	local function cy(b: { number }): number
		return (math.max(m[2], b[2]) + math.min(m[2] + m[4], b[2] + b[4])) / 2
	end
	local function cx(b: { number }): number
		return (math.max(m[1], b[1]) + math.min(m[1] + m[3], b[1] + b[3])) / 2
	end
	local l = nearest(row, function(b)
		return m[1] - (b[1] + b[3])
	end)
	local r = nearest(row, function(b)
		return b[1] - (m[1] + m[3])
	end)
	local u = nearest(col, function(b)
		return m[2] - (b[2] + b[4])
	end)
	local d = nearest(col, function(b)
		return b[2] - (m[2] + m[4])
	end)
	if l and r and math.abs((m[1] - (l[1] + l[3])) - (r[1] - (m[1] + m[3]))) < eps then
		table.insert(gaps, { l[1] + l[3], cy(l), m[1], cy(l) })
		table.insert(gaps, { m[1] + m[3], cy(r), r[1], cy(r) })
	end
	if u and d and math.abs((m[2] - (u[2] + u[4])) - (d[2] - (m[2] + m[4]))) < eps then
		table.insert(gaps, { cx(u), u[2] + u[4], cx(u), m[2] })
		table.insert(gaps, { cx(d), m[2] + m[4], cx(d), d[2] })
	end
	return { lines = lines, gaps = gaps }
end

-- Alt held: distances from `a` to `b`, as pen.dev measures.
function M.distances(a: { number }, b: { number }): Guides
	local gaps, lines = {}, {}
	local ax0, ay0, ax1, ay1 = a[1], a[2], a[1] + a[3], a[2] + a[4]
	local bx0, by0, bx1, by1 = b[1], b[2], b[1] + b[3], b[2] + b[4]
	local acx, acy = ax0 + a[3] / 2, ay0 + a[4] / 2
	if M.contains(b, a) or M.contains(a, b) then
		local i, o = a, b
		if M.contains(a, b) then
			i, o = b, a
		end
		local icx, icy = i[1] + i[3] / 2, i[2] + i[4] / 2
		table.insert(gaps, { o[1], icy, i[1], icy })
		table.insert(gaps, { i[1] + i[3], icy, o[1] + o[3], icy })
		table.insert(gaps, { icx, o[2], icx, i[2] })
		table.insert(gaps, { icx, i[2] + i[4], icx, o[2] + o[4] })
	else
		local yspan = ay0 < by1 and ay1 > by0
		local xspan = ax0 < bx1 and ax1 > bx0
		local y = if yspan then (math.max(ay0, by0) + math.min(ay1, by1)) / 2 else acy
		local x = if xspan then (math.max(ax0, bx0) + math.min(ax1, bx1)) / 2 else acx
		if ax1 <= bx0 then
			table.insert(gaps, { ax1, y, bx0, y })
		elseif bx1 <= ax0 then
			table.insert(gaps, { bx1, y, ax0, y })
		end
		if ay1 <= by0 then
			table.insert(gaps, { x, ay1, x, by0 })
		elseif by1 <= ay0 then
			table.insert(gaps, { x, by1, x, ay0 })
		end
		if not yspan and (ax1 <= bx0 or bx1 <= ax0) then
			table.insert(lines, { math.min(ax0, bx0), y, math.max(ax1, bx1), y })
		end
		if not xspan and (ay1 <= by0 or by1 <= ay0) then
			table.insert(lines, { x, math.min(ay0, by0), x, math.max(ay1, by1) })
		end
		if #gaps == 0 then
			if ax0 ~= bx0 then
				table.insert(gaps, { math.min(ax0, bx0), acy, math.max(ax0, bx0), acy })
			end
			if ay0 ~= by0 then
				table.insert(gaps, { acx, math.min(ay0, by0), acx, math.max(ay0, by0) })
			end
		end
	end
	return { gaps = gaps, lines = lines, outlines = { b } }
end

return M
