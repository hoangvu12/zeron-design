--!strict
-- Prototype links on the Canvas ("noodles", F6 C1): which are drawn, their
-- curves, and what a point or a marquee touches. Pure: no state, no ui.
--
-- Everything is in Canvas units; `zoom` turns the screen-sized parts (the
-- curve's pull, the arrow, the 8 px grab distance) into them, so a noodle
-- looks and grabs the same at any zoom.
--
-- A noodle (`collect`'s entries):
--   { id, k, on, a, kind, go?, ov?, b, tb?, x0, y0, x1, y1, c1x, c1y, c2x, c2y, ex, ey, dir }
--   id: the layer; k: its reaction's place in the scene's `ia` (as drawn);
--   on: the layer (or an ancestor) is selected; a: the scene's reaction;
--   kind: "curve" (to a Screen), "missing" (a broken link: a short stub),
--     "back" / "url" (a badge at the layer's top right, no ends);
--   ov: an Open or Swap overlay's noodle (dashed);
--   (x0, y0) the start, (x1, y1) the arrow's tip, the curve from the start
--   through (c1, c2) to (ex, ey), just short of the tip.
-- A selected interaction is `{ id, k }`; `stored_index` finds it in the
-- layer's stored `interactions`.

local Proto = require("./proto")

local M = {}

M.GRAB = 8 -- screen points
M.MAX = 300 -- noodles drawn at most

-- One curve between a layer's bounds `b` and a Screen's `tb` (both {x, y, w, h}).
function M.curve(e: any, b: { number }, tb: { number }, zoom: number)
	local right = (tb[1] + tb[3] / 2) >= (b[1] + b[3] / 2)
	local dir = if right then 1 else -1
	local x0 = if right then b[1] + b[3] else b[1]
	local y0 = b[2] + b[4] / 2
	local x1 = if right then tb[1] else tb[1] + tb[3]
	local y1 = tb[2] + math.min(tb[4] / 3, 200)
	local k = math.max(40 / zoom, math.abs(x1 - x0) / 2)
	e.kind, e.dir = "curve", dir
	e.x0, e.y0, e.x1, e.y1 = x0, y0, x1, y1
	e.c1x, e.c1y = x0 + dir * k, y0
	e.c2x, e.c2y = x1 - dir * k, y1
	e.ex, e.ey = x1 - dir * 6 / zoom, y1
end

-- A curve from (x0, y0) to a free point (a drag's pointer).
function M.free(x0: number, y0: number, x1: number, y1: number, zoom: number): { number }
	local dir = if x1 >= x0 then 1 else -1
	local k = math.max(30 / zoom, math.abs(x1 - x0) / 2)
	return { x0, y0, x0 + dir * k, y0, x1 - dir * k, y1, x1, y1 }
end

-- The noodles drawn: every link of a selected layer, then with `show_all`
-- everyone else's (so the cap keeps the selected).
-- roots: the scene roots; by: the Canvas index's `by` (bounds, hidden);
-- selected(id): the layer is in the selection's branch.
function M.collect(roots: { any }, by: { [string]: any }, zoom: number, selected: (id: string) -> boolean, show_all: boolean?): { any }
	local out = {}
	for pass = 1, 2 do
		for _, r in roots do
			-- (k: each reaction's place among its layer's, counted before any is left out)
			local seen: { [string]: number } = {}
			for _, l in Proto.of_root(r).links do
				if #out >= M.MAX then
					return out
				end
				local k = (seen[l.id] or 0) + 1
				seen[l.id] = k
				local on = selected(l.id)
				if (pass == 1) ~= on or (not on and not show_all) then
					continue
				end
				local n = by[l.id]
				if not n or n.it.hidden then
					continue
				end
				local a = l.a
				local e: any = { id = l.id, k = k, on = on, a = a, b = n.bounds }
				-- (an Open or Swap overlay: a dashed noodle to that frame; a move wins)
				local ov_go: string? = nil
				if not a.go and not a.url then
					for _, act in a.acts or {} do
						if (act.k == "overlay" or act.k == "swap") and act.go and not ov_go then
							ov_go = act.go
						end
					end
				end
				local go = a.go or ov_go
				local b = n.bounds
				if a.go == "back" or a.url then
					e.kind = if a.url then "url" else "back"
					e.x0, e.y0 = b[1] + b[3], b[2]
				elseif go then
					e.go, e.ov = go, ov_go ~= nil
					local tg = by[go]
					if a.broken or not tg then
						e.kind = "missing"
						e.x0, e.y0 = b[1] + b[3], b[2] + b[4] / 2
						e.x1, e.y1 = e.x0 + 28 / zoom, e.y0
						e.ex, e.ey, e.dir = e.x1, e.y1, 1
					else
						e.tb = tg.bounds
						M.curve(e, b, tg.bounds, zoom)
					end
				else
					continue
				end
				table.insert(out, e)
			end
		end
	end
	return out
end

local function bez(e: any, t: number): (number, number)
	local u = 1 - t
	local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
	return a * e.x0 + b * e.c1x + c * e.c2x + d * e.ex, a * e.y0 + b * e.c1y + c * e.c2y + d * e.ey
end

-- The points along a noodle (a polyline: 24 steps on a curve).
function M.points(e: any): { { number } }
	if e.kind == "curve" then
		local pts = {}
		for s = 0, 24 do
			local x, y = bez(e, s / 24)
			table.insert(pts, { x, y })
		end
		table.insert(pts, { e.x1, e.y1 })
		return pts
	elseif e.kind == "missing" then
		return { { e.x0, e.y0 }, { e.x1, e.y1 } }
	end
	return { { e.x0, e.y0 } }
end

local function seg_dist(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
	local dx, dy = bx - ax, by - ay
	local l2 = dx * dx + dy * dy
	local t = if l2 > 0 then math.clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1) else 0
	local qx, qy = ax + t * dx, ay + t * dy
	return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

local function box_of(e: any): (number, number, number, number)
	if e.kind == "curve" then
		return math.min(e.x0, e.c1x, e.c2x, e.x1), math.min(e.y0, e.c1y, e.c2y, e.y1), math.max(e.x0, e.c1x, e.c2x, e.x1), math.max(e.y0, e.c1y, e.c2y, e.y1)
	elseif e.kind == "missing" then
		return e.x0, e.y0, e.x1, e.y1
	end
	return e.x0, e.y0, e.x0, e.y0
end

-- What's under a Canvas point: { link, part = "start" | "end" | "line" },
-- within 8 screen points. An end beats a line; a selected layer's noodle
-- (`collect` puts them first) beats another's. A badge (back, url) has no
-- ends: "line".
function M.hit(links: { any }, x: number, y: number, zoom: number): any?
	local tol = M.GRAB / zoom
	local best, best_d = nil, math.huge
	for _, e in links do
		local ax, ay, bx, by = box_of(e)
		local pad = if e.kind == "back" or e.kind == "url" then 8 / zoom + tol else tol
		if x < ax - pad or x > bx + pad or y < ay - pad or y > by + pad then
			continue
		end
		if e.kind == "back" or e.kind == "url" then
			if math.sqrt((x - e.x0) ^ 2 + (y - e.y0) ^ 2) <= 8 / zoom + tol / 2 then
				return { link = e, part = "line" }
			end
			continue
		end
		if math.sqrt((x - e.x1) ^ 2 + (y - e.y1) ^ 2) <= tol then
			return { link = e, part = "end" }
		end
		if math.sqrt((x - e.x0) ^ 2 + (y - e.y0) ^ 2) <= tol then
			return { link = e, part = "start" }
		end
		local pts = M.points(e)
		for s = 2, #pts do
			local d = seg_dist(x, y, pts[s - 1][1], pts[s - 1][2], pts[s][1], pts[s][2])
			if d <= tol and d < best_d - 1e-9 then
				best, best_d = e, d
			end
		end
	end
	return if best then { link = best, part = "line" } else nil
end

-- A segment and a box ({x, y, w, h}) meet (Liang–Barsky).
local function seg_meets(ax: number, ay: number, bx: number, by: number, r: { number }): boolean
	local t0, t1 = 0, 1
	local dx, dy = bx - ax, by - ay
	for _, q in { { -dx, ax - r[1] }, { dx, r[1] + r[3] - ax }, { -dy, ay - r[2] }, { dy, r[2] + r[4] - ay } } do
		local p, qq = q[1], q[2]
		if p == 0 then
			if qq < 0 then
				return false
			end
		else
			local t = qq / p
			if p < 0 then
				if t > t1 then
					return false
				end
				t0 = math.max(t0, t)
			else
				if t < t0 then
					return false
				end
				t1 = math.min(t1, t)
			end
		end
	end
	return true
end

-- The noodles a marquee ({x, y, w, h}, Canvas units) crosses or holds.
function M.in_rect(links: { any }, r: { number }): { any }
	local out = {}
	for _, e in links do
		local ax, ay, bx, by = box_of(e)
		if bx < r[1] or ax > r[1] + r[3] or by < r[2] or ay > r[2] + r[4] then
			continue
		end
		local pts = M.points(e)
		local hit = #pts == 1 and seg_meets(pts[1][1], pts[1][2], pts[1][1], pts[1][2], r)
		for s = 2, #pts do
			if hit then
				break
			end
			hit = seg_meets(pts[s - 1][1], pts[s - 1][2], pts[s][1], pts[s][2], r)
		end
		if hit then
			table.insert(out, e)
		end
	end
	return out
end

-- The scene's k-th reaction in a layer's stored `interactions` (the scene
-- leaves out what isn't a reaction with actions).
function M.stored_index(list: any, k: number): number?
	if type(list) ~= "table" then
		return nil
	end
	local n = 0
	for i, r in list do
		if type(r) == "table" and type(r.actions) == "table" and #r.actions > 0 then
			n += 1
			if n == k then
				return i
			end
		end
	end
	return nil
end

-- The action a noodle draws, in a stored reaction: its first move
-- (navigate/back/url), else its first Open or Swap overlay. (j, action) or nil.
function M.action_of(r: any): (number?, any?)
	if type(r) ~= "table" or type(r.actions) ~= "table" then
		return nil, nil
	end
	for j, a in r.actions do
		if type(a) == "table" and (a.action == "navigate" or a.action == "back" or a.action == "url") then
			return j, a
		end
	end
	for j, a in r.actions do
		if type(a) == "table" and (a.action == "overlay" or a.action == "swap") and a.to ~= nil then
			return j, a
		end
	end
	return nil, nil
end

-- A layer's interactions with some of them retargeted or removed.
-- list: the stored list (copied, not changed); ks: the scene indexes;
-- to: a Screen id (retarget: a navigate's / overlay's `to`; a back or url
-- stays), or nil (remove those reactions). Returns the new list and how
-- many it changed.
function M.rewrite(list: any, ks: { number }, to: string?): ({ any }, number)
	local function copy(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local o = {}
		for k, x in v do
			o[k] = copy(x)
		end
		return o
	end
	local out = if type(list) == "table" then copy(list) else {}
	local idxs = {}
	for _, k in ks do
		local i = M.stored_index(out, k)
		if i and not table.find(idxs, i) then
			table.insert(idxs, i)
		end
	end
	local changed = 0
	if to then
		for _, i in idxs do
			local _, a = M.action_of(out[i])
			if a and (a.action == "navigate" or a.action == "overlay" or a.action == "swap") and a.to ~= to then
				a.to = to
				changed += 1
			end
		end
	else
		table.sort(idxs, function(x, y)
			return x > y
		end)
		for _, i in idxs do
			table.remove(out, i)
			changed += 1
		end
	end
	return out, changed
end

return M
